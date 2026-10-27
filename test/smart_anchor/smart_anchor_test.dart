import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/config_injector.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/sticky_monitor.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache node({
  required String name,
  String country = 'US',
  double lat = 34.0522,
  double lon = -118.2437,
  String asn = 'AS20057',
  String egressIp = '1.2.3.4',
  double purity = 90,
  bool waf = true,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: egressIp,
    countryCode: country,
    latitude: lat,
    longitude: lon,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: waf,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

ServiceAnchor anchor() {
  return const ServiceAnchor(
    serviceTag: 'claude',
    countryCode: 'US',
    lastProxyName: 'US-01',
    egressIp: '1.2.3.4',
    subnet24: '1.2.3',
    asn: 'AS20057',
    isp: 'Example ISP',
    latitude: 34.0522,
    longitude: -118.2437,
    city: 'Los Angeles',
    confirmedAt: 0,
  );
}

void main() {
  group('ScoringEngine', () {
    test('purity applies type, fraud and abuse penalties', () {
      expect(
        ScoringEngine.purityScore(
          ipType: 'hosting',
          fraudScore: 20,
          isAbuse: true,
        ),
        35,
      );
      expect(
        ScoringEngine.purityScore(
          ipType: 'residential',
          fraudScore: 0,
          isAbuse: false,
        ),
        100,
      );
    });

    test('hard filter vetoes country, WAF and low purity', () {
      expect(ScoringEngine.passesHardFilter(node(name: 'a'), 'US'), isTrue);
      expect(
        ScoringEngine.passesHardFilter(node(name: 'a', country: 'SG'), 'US'),
        isFalse,
      );
      expect(
        ScoringEngine.passesHardFilter(node(name: 'a', waf: false), 'US'),
        isFalse,
      );
      expect(
        ScoringEngine.passesHardFilter(node(name: 'a', purity: 49), 'US'),
        isFalse,
      );
    });

    test('distance penalty is log-capped at 25', () {
      expect(ScoringEngine.distancePenalty(0), 0);
      expect(ScoringEngine.distancePenalty(100000), 25);
    });

    test('same ASN and subnet bonuses lift priority', () {
      final a = anchor();
      final same = node(name: 'same');
      final far = node(
        name: 'far',
        lat: 40.7128,
        lon: -74.0060,
        asn: 'AS99999',
        egressIp: '9.9.9.9',
      );
      expect(
        ScoringEngine.priority(same, a) > ScoringEngine.priority(far, a),
        isTrue,
      );
      final ranked = ScoringEngine.rank([far, same], a);
      expect(ranked.first.proxyName, 'same');
    });

    test('equal quality and location prefers lower delay', () {
      final a = anchor();
      final fast = node(name: 'fast');
      final slow = node(name: 'slow');
      expect(
        ScoringEngine.priority(fast, a, delayMs: 60) >
            ScoringEngine.priority(slow, a, delayMs: 900),
        isTrue,
      );
      final ranked = ScoringEngine.rank(
        [slow, fast],
        a,
        delays: {'fast': 60, 'slow': 900},
      );
      expect(ranked.first.proxyName, 'fast');
    });

    test('delay penalty caps and ignores unknown delays', () {
      expect(ScoringEngine.delayPenalty(null), 0);
      expect(ScoringEngine.delayPenalty(0), 0);
      expect(ScoringEngine.delayPenalty(-1), 10);
      expect(ScoringEngine.delayPenalty(100), 1);
      expect(ScoringEngine.delayPenalty(5000), 10);
    });
  });

  group('StickyMonitor', () {
    test('one failure holds, two failures advance once, never back', () {
      final monitor = StickyMonitor(ranked: ['a', 'b', 'c']);
      expect(monitor.recordProbe(success: false, nowMs: 0), isNull);
      expect(monitor.recordProbe(success: false, nowMs: 1000), 'b');
      expect(monitor.current, 'b');
      expect(monitor.recordProbe(success: true, nowMs: 2000), isNull);
      expect(monitor.recordProbe(success: false, nowMs: 3000), isNull);
      expect(monitor.recordProbe(success: false, nowMs: 4000), 'c');
    });

    test('three switches in ten minutes freeze anchor updates', () {
      final monitor = StickyMonitor(ranked: ['a', 'b', 'c', 'd', 'e']);
      for (var i = 0; i < 3; i++) {
        monitor.recordProbe(success: false, nowMs: i * 1000);
        monitor.recordProbe(success: false, nowMs: i * 1000 + 500);
      }
      expect(monitor.anchorFrozen, isTrue);
      expect(monitor.shouldConfirmAnchor(20 * 60 * 1000), isFalse);
    });

    test('anchor confirms only after ten stable minutes', () {
      final monitor = StickyMonitor(ranked: ['a', 'b']);
      monitor.recordProbe(success: false, nowMs: 0);
      monitor.recordProbe(success: false, nowMs: 1000);
      expect(monitor.shouldConfirmAnchor(9 * 60 * 1000), isFalse);
      expect(monitor.shouldConfirmAnchor(11 * 60 * 1000), isTrue);
    });
  });

  group('SubscriptionMerger', () {
    SubscriptionSourceResult sourceA() {
      return const SubscriptionSourceResult(
        sourceId: 'a',
        sourceLabel: 'A',
        ok: true,
        proxies: [
          {'name': 'US-01', 'type': 'vmess', 'server': '1.1.1.1', 'port': 443},
        ],
        proxyGroups: [
          {
            'name': '美国',
            'type': 'select',
            'proxies': ['US-01'],
          },
          {
            'name': '自动',
            'type': 'url-test',
            'proxies': ['US-01'],
          },
        ],
        rules: ['GEOSITE,google,美国', 'MATCH,DIRECT'],
      );
    }

    SubscriptionSourceResult sourceB() {
      return const SubscriptionSourceResult(
        sourceId: 'b',
        sourceLabel: 'B',
        ok: true,
        proxies: [
          {'name': 'US-01', 'type': 'vmess', 'server': '2.2.2.2', 'port': 443},
        ],
        proxyGroups: [
          {
            'name': '美国',
            'type': 'select',
            'proxies': ['US-01'],
          },
          {
            'name': '自动',
            'type': 'select',
            'proxies': ['US-01'],
          },
        ],
        rules: ['GEOSITE,youtube,美国', 'GEOSITE,google,美国'],
      );
    }

    test('primaryOnly keeps only primary groups and rules', () {
      final merged = SubscriptionMerger.merge([sourceA(), sourceB()]);
      expect(merged.mode, AggregationGroupMode.primaryOnly);
      expect(merged.proxyGroups.first['name'], '🔗 聚合全部节点');
      expect(
        merged.proxyGroups.map((group) => group['name']),
        containsAll(['美国', '自动']),
      );
      expect(merged.rules, ['GEOSITE,google,美国', 'MATCH,DIRECT']);
    });

    test('mergeAll merges same type and renames type conflicts', () {
      final merged = SubscriptionMerger.merge([
        sourceA(),
        sourceB(),
      ], mode: AggregationGroupMode.mergeAll);
      final us = merged.proxyGroups.firstWhere(
        (group) => group['name'] == '美国',
      );
      expect((us['proxies'] as List).length, 2);
      expect(
        merged.proxyGroups.map((group) => group['name']),
        contains('[B] 自动'),
      );
      expect(merged.rules, contains('GEOSITE,youtube,美国'));
    });
  });

  group('SmartConfigInjector', () {
    test(
      'enabled service injects group, rules and DNS; disabled is skipped',
      () {
        const enabled = ServiceToggleConfig(
          serviceId: 'claude',
          displayName: 'Claude',
          isEnabled: true,
          targetCountry: 'US',
          matchRules: ['GEOSITE,anthropic'],
          dnsDomains: ['claude.ai'],
        );
        const disabled = ServiceToggleConfig(
          serviceId: 'netflix',
          displayName: 'Netflix',
          isEnabled: false,
          targetCountry: 'SG',
          matchRules: ['GEOSITE,netflix'],
          dnsDomains: ['netflix.com'],
        );
        final result = SmartConfigInjector.injectSmartRouting(
          rawConfig: {
            'proxy-groups': [
              {
                'name': '原有组',
                'type': 'select',
                'proxies': ['DIRECT'],
              },
            ],
            'rules': ['MATCH,DIRECT'],
            'dns': {'nameserver-policy': <String, dynamic>{}},
          },
          serviceConfigs: [enabled, disabled],
          rankedProxiesByService: {
            'claude': ['[A] US-01'],
          },
        );
        final groups = result['proxy-groups'] as List;
        expect(groups.first['name'], '🎯 Smart-CLAUDE');
        final rules = result['rules'] as List;
        expect(rules.first, 'GEOSITE,anthropic,🎯 Smart-CLAUDE');
        expect(rules, contains('MATCH,DIRECT'));
        final policy = (result['dns'] as Map)['nameserver-policy'] as Map;
        expect(policy.containsKey('claude.ai'), isTrue);
        expect(policy.containsKey('netflix.com'), isFalse);
      },
    );
  });
}
