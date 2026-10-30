import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/config_injector.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
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

    test('distance affinity spans 5 and saturates at 3000 km', () {
      expect(ScoringEngine.distanceAffinity(0), 5);
      expect(ScoringEngine.distanceAffinity(1500), 2.5);
      expect(ScoringEngine.distanceAffinity(3000), 0);
      expect(ScoringEngine.distanceAffinity(100000), 0);
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

    test('delay penalty spans 30 and ignores unknown delays', () {
      expect(ScoringEngine.delayPenalty(null), 0);
      expect(ScoringEngine.delayPenalty(0), 0);
      expect(ScoringEngine.delayPenalty(-1), 30);
      expect(ScoringEngine.delayPenalty(100), 5);
      expect(ScoringEngine.delayPenalty(400), 20);
      expect(ScoringEngine.delayPenalty(5000), 30);
    });

    test('purity compresses into a 0 to 12 range', () {
      expect(ScoringEngine.purityCompressed(50), 0);
      expect(ScoringEngine.purityCompressed(90), 9.6);
      expect(ScoringEngine.purityCompressed(100), 12);
      expect(ScoringEngine.purityCompressed(30), 0);
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

    test('mergeAll dedups rules primary first, order kept', () {
      final merged = SubscriptionMerger.merge([
        sourceA(),
        sourceB(),
      ], mode: AggregationGroupMode.mergeAll);
      expect(merged.rules, [
        'GEOSITE,google,美国',
        'MATCH,DIRECT',
        'GEOSITE,youtube,美国',
      ]);
    });

    test('dialer-proxy follows its renamed chain target', () {
      const chained = SubscriptionSourceResult(
        sourceId: 'a',
        sourceLabel: 'A',
        ok: true,
        proxies: [
          {
            'name': 'TW-01',
            'type': 'vmess',
            'server': '1.1.1.1',
            'port': 443,
            'dialer-proxy': 'HK-01',
          },
          {'name': 'HK-01', 'type': 'vmess', 'server': '2.2.2.2', 'port': 443},
        ],
      );
      final merged = SubscriptionMerger.merge([chained]);
      final chain = merged.proxies.firstWhere(
        (proxy) => proxy['name'] == '[A] TW-01',
      );
      expect(chain['dialer-proxy'], '[A] HK-01');
    });

    test('unresolvable dialer-proxy drops the node', () {
      const chained = SubscriptionSourceResult(
        sourceId: 'a',
        sourceLabel: 'A',
        ok: true,
        proxies: [
          {
            'name': 'TW-01',
            'type': 'vmess',
            'server': '1.1.1.1',
            'port': 443,
            'dialer-proxy': 'MISSING',
          },
          {'name': 'HK-01', 'type': 'vmess', 'server': '2.2.2.2', 'port': 443},
        ],
      );
      final merged = SubscriptionMerger.merge([chained]);
      expect(merged.proxies.map((proxy) => proxy['name']), ['[A] HK-01']);
      final unified = merged.proxyGroups.first;
      expect(unified['proxies'], ['[A] HK-01']);
    });

    test('duplicate renamed names get unique suffixes', () {
      const first = SubscriptionSourceResult(
        sourceId: 'a',
        sourceLabel: 'A',
        ok: true,
        proxies: [
          {'name': 'X', 'type': 'vmess', 'server': '1.1.1.1', 'port': 443},
        ],
        proxyGroups: [
          {
            'name': 'GA',
            'type': 'select',
            'proxies': ['X'],
          },
        ],
      );
      const second = SubscriptionSourceResult(
        sourceId: 'b',
        sourceLabel: 'A',
        ok: true,
        proxies: [
          {'name': 'X', 'type': 'vmess', 'server': '2.2.2.2', 'port': 443},
        ],
        proxyGroups: [
          {
            'name': 'GB',
            'type': 'select',
            'proxies': ['X'],
          },
        ],
      );
      final merged = SubscriptionMerger.merge([
        first,
        second,
      ], mode: AggregationGroupMode.mergeAll);
      expect(merged.proxies.map((proxy) => proxy['name']), [
        '[A] X',
        '[A] X (2)',
      ]);
      final ga = merged.proxyGroups.firstWhere(
        (group) => group['name'] == 'GA',
      );
      final gb = merged.proxyGroups.firstWhere(
        (group) => group['name'] == 'GB',
      );
      expect(ga['proxies'], ['[A] X']);
      expect(gb['proxies'], ['[A] X (2)']);
    });

    test('prune drops dangling members, groups and rules', () {
      const primary = SubscriptionSourceResult(
        sourceId: 'a',
        sourceLabel: 'A',
        ok: true,
        proxies: [
          {'name': 'GOOD', 'type': 'vmess', 'server': '1.1.1.1', 'port': 443},
        ],
        proxyGroups: [
          {
            'name': 'G',
            'type': 'select',
            'proxies': ['GOOD', 'GHOST'],
          },
          {
            'name': 'EMPTY',
            'type': 'select',
            'proxies': ['GHOST'],
          },
        ],
        rules: [
          'DOMAIN,example.com,G',
          'DOMAIN,other.com,GHOST',
          'RULE-SET,missing,DIRECT',
          'RULE-SET,lan,DIRECT',
          'MATCH,DIRECT',
        ],
        ruleProviders: {
          'lan': {
            'type': 'http',
            'behavior': 'classical',
            'url': 'https://a.example/lan.yaml',
            'path': './lan.yaml',
            'interval': 86400,
          },
        },
      );
      final merged = SubscriptionMerger.merge([
        primary,
      ], mode: AggregationGroupMode.mergeAll);
      final g = merged.proxyGroups.firstWhere((group) => group['name'] == 'G');
      expect(g['proxies'], ['[A] GOOD']);
      expect(
        merged.proxyGroups.map((group) => group['name']),
        isNot(contains('EMPTY')),
      );
      expect(merged.rules, [
        'DOMAIN,example.com,G',
        'RULE-SET,lan,DIRECT',
        'MATCH,DIRECT',
      ]);
    });

    test('dialer-proxy follows a renamed group target in mergeAll', () {
      const chained = SubscriptionSourceResult(
        sourceId: 'b',
        sourceLabel: 'B',
        ok: true,
        proxies: [
          {
            'name': 'B-01',
            'type': 'vmess',
            'server': '3.3.3.3',
            'port': 443,
            'dialer-proxy': '自动',
          },
        ],
        proxyGroups: [
          {
            'name': '自动',
            'type': 'select',
            'proxies': ['B-01'],
          },
        ],
      );
      final merged = SubscriptionMerger.merge([
        sourceA(),
        chained,
      ], mode: AggregationGroupMode.mergeAll);
      final chain = merged.proxies.firstWhere(
        (proxy) => proxy['name'] == '[B] B-01',
      );
      expect(chain['dialer-proxy'], '[B] 自动');
    });

    SubscriptionSourceResult providerPrimary() {
      return const SubscriptionSourceResult(
        sourceId: 'a',
        sourceLabel: 'A',
        ok: true,
        proxies: [],
        rules: ['RULE-SET,lan,DIRECT'],
        ruleProviders: {
          'lan': {
            'type': 'http',
            'behavior': 'classical',
            'url': 'https://a.example/lan.yaml',
            'path': './lan.yaml',
            'interval': 86400,
          },
          'shared': {
            'type': 'http',
            'behavior': 'domain',
            'url': 'https://a.example/shared.yaml',
            'path': './shared.yaml',
            'interval': 86400,
          },
        },
        proxyProviders: {
          'nodes': {
            'type': 'http',
            'url': 'https://a.example/nodes.yaml',
            'path': './nodes.yaml',
            'interval': 3600,
          },
        },
      );
    }

    SubscriptionSourceResult providerOther() {
      return const SubscriptionSourceResult(
        sourceId: 'b',
        sourceLabel: 'B',
        ok: true,
        proxies: [],
        rules: ['RULE-SET,lancidr,DIRECT'],
        ruleProviders: {
          'lancidr': {
            'type': 'http',
            'behavior': 'ipcidr',
            'url': 'https://b.example/lancidr.yaml',
            'path': './lancidr.yaml',
            'interval': 86400,
          },
          'shared': {
            'type': 'http',
            'behavior': 'domain',
            'url': 'https://b.example/shared.yaml',
            'path': './shared.yaml',
            'interval': 86400,
          },
        },
      );
    }

    test('mergeAll merges providers from every source', () {
      final merged = SubscriptionMerger.merge([
        providerPrimary(),
        providerOther(),
      ], mode: AggregationGroupMode.mergeAll);
      expect(merged.ruleProviders.keys, containsAll(['lan', 'lancidr']));
      expect(merged.rules, contains('RULE-SET,lancidr,DIRECT'));
      expect(merged.proxyProviders.keys, contains('nodes'));
    });

    test('same-name provider keeps the first definition', () {
      final merged = SubscriptionMerger.merge([
        providerPrimary(),
        providerOther(),
      ], mode: AggregationGroupMode.mergeAll);
      final shared = merged.ruleProviders['shared'] as Map;
      expect(shared['url'], 'https://a.example/shared.yaml');
    });

    test('primaryOnly keeps only primary providers', () {
      final merged = SubscriptionMerger.merge([
        providerPrimary(),
        providerOther(),
      ]);
      expect(merged.ruleProviders.keys, contains('lan'));
      expect(merged.ruleProviders.keys, isNot(contains('lancidr')));
      expect(merged.rules, isNot(contains('RULE-SET,lancidr,DIRECT')));
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
        expect(groups.first['name'], '🎯 Smart-Claude');
        final rules = result['rules'] as List;
        expect(rules.first, 'GEOSITE,anthropic,🎯 Smart-Claude');
        expect(rules, contains('MATCH,DIRECT'));
        final policy = (result['dns'] as Map)['nameserver-policy'] as Map;
        expect(policy.containsKey('claude.ai'), isTrue);
        expect(policy.containsKey('netflix.com'), isFalse);
      },
    );
  });
}
