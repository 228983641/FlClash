import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache meta(
  String name,
  String country,
  double purity, {
  String asn = 'AS1234',
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '',
    egressIp: '1.2.3.4',
    countryCode: country,
    latitude: 37.0,
    longitude: -122.0,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: 0,
  );
}

const grok = ServiceToggleConfig(
  serviceId: 'grok',
  displayName: 'Grok',
  isEnabled: true,
  targetCountry: '',
  matchRules: [],
  dnsDomains: [],
);

ServiceAccessResult access(
  String serviceId,
  String proxy,
  ServiceAccessReason reason, {
  String? borrowedFrom,
}) {
  return ServiceAccessResult(
    serviceId: serviceId,
    proxyName: proxy,
    egressIp: '1.2.3.4',
    reason: reason,
    checkedAt: DateTime.now().millisecondsSinceEpoch,
    borrowedFrom: borrowedFrom,
  );
}

void main() {
  test('a borrowed region block feeds the derived region blacklist', () {
    final input = SmartAnchorInput(
      services: [grok],
      metadataByProxy: {
        'US-1': meta('US-1', 'US', 90),
        'HK-1': meta('HK-1', 'HK', 90, asn: 'AS100'),
        'HK-2': meta('HK-2', 'HK', 85, asn: 'AS200'),
      },
      accessByService: {
        'grok': {
          'HK-1': access(
            'grok',
            'HK-1',
            ServiceAccessReason.regionBlocked,
            borrowedFrom: 'openai',
          ),
          'HK-2': access('grok', 'HK-2', ServiceAccessReason.regionBlocked),
        },
      },
    );
    expect(detectedUnsupportedRegions(input, 'grok'), {'HK'});
    final ranked = rankedProxiesForService(input, grok, [
      'US-1',
      'HK-1',
      'HK-2',
    ]);
    expect(ranked, contains('US-1'));
    expect(ranked, isNot(contains('HK-1')));
    expect(ranked, isNot(contains('HK-2')));
  });

  test('compliance moves a borrower off a node its donor calls blocked', () {
    final input = SmartAnchorInput(
      services: [grok],
      metadataByProxy: {
        'US-1': meta('US-1', 'US', 90),
        'HK-1': meta('HK-1', 'HK', 90),
      },
      accessByService: {
        'grok': {
          'HK-1': access(
            'grok',
            'HK-1',
            ServiceAccessReason.regionBlocked,
            borrowedFrom: 'openai',
          ),
        },
      },
    );
    final target = lockReselectTarget(input, grok, ['US-1', 'HK-1'], 'HK-1');
    expect(target, 'US-1');
  });

  test('a borrowed accessible never enters the confirmed bucket', () {
    const anchor = ServiceAnchor(
      serviceTag: 'grok',
      countryCode: 'US',
      lastProxyName: 'own',
      egressIp: '1.2.3.4',
      subnet24: '1.2.3',
      asn: 'AS1234',
      isp: '',
      latitude: 37.0,
      longitude: -122.0,
      city: '',
      confirmedAt: 0,
    );
    final own = meta('own', 'US', 55);
    final borrowed = meta('borrowed', 'US', 100);
    final ranked = ScoringEngine.rankForService(
      [borrowed, own],
      anchor,
      const [],
      {
        'own': access('grok', 'own', ServiceAccessReason.accessible),
        'borrowed': access(
          'grok',
          'borrowed',
          ServiceAccessReason.accessible,
          borrowedFrom: 'openai',
        ),
      },
    );
    expect(ranked.map((node) => node.proxyName), ['own', 'borrowed']);
  });

  test('the merged-config remap keeps the borrowed stamp', () {
    const anchor = ServiceAnchor(
      serviceTag: 'grok',
      countryCode: 'US',
      lastProxyName: '[A] US-near',
      egressIp: '1.2.3.4',
      subnet24: '1.2.3',
      asn: 'AS1234',
      isp: '',
      latitude: 37.0,
      longitude: -122.0,
      city: '',
      confirmedAt: 0,
    );
    final input = SmartAnchorInput(
      services: [grok],
      anchors: {'grok': anchor},
      metadataByProxy: {
        '[A] US-near': meta('[A] US-near', 'US', 100),
        '[A] US-far': meta('[A] US-far', 'US', 50),
      },
      accessByService: {
        'grok': {
          'US-far': access(
            'grok',
            'US-far',
            ServiceAccessReason.accessible,
            borrowedFrom: 'openai',
          ),
        },
      },
    );
    // US-far's borrowed accessible must not promote it over US-near: with
    // the stamp lost in the remap it would land in the confirmed bucket
    // and rank first despite the weaker score.
    final ranked = rankedProxiesForService(input, grok, [
      '[A] US-near',
      '[A] US-far',
    ]);
    expect(ranked, ['[A] US-near', '[A] US-far']);
  });
}
