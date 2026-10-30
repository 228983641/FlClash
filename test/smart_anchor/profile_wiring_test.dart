import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/candidate_decision.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache meta(String name, double lat, double lon, double purity) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: '1.2.3.4',
    countryCode: 'US',
    latitude: lat,
    longitude: lon,
    asn: 'AS20057',
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

const anchor = ServiceAnchor(
  serviceTag: 'claude',
  countryCode: 'US',
  lastProxyName: 'US-near',
  egressIp: '1.2.3.4',
  subnet24: '1.2.3',
  asn: 'AS20057',
  isp: 'Example',
  latitude: 34.0522,
  longitude: -118.2437,
  city: 'Los Angeles',
  confirmedAt: 0,
);

const claude = ServiceToggleConfig(
  serviceId: 'claude',
  displayName: 'Claude',
  isEnabled: true,
  targetCountry: 'US',
  matchRules: ['DOMAIN-SUFFIX,claude.ai'],
  dnsDomains: ['claude.ai'],
);

Map<String, dynamic> baseConfig() {
  return {
    'proxies': [
      {'name': 'US-near', 'type': 'vless', 'server': 'a.example'},
      {'name': 'US-far', 'type': 'vless', 'server': 'b.example'},
      {'name': 'US-blocked', 'type': 'vless', 'server': 'c.example'},
      {'name': 'US-unknown', 'type': 'vless', 'server': 'd.example'},
    ],
    'proxy-groups': [
      {
        'name': '手动选择',
        'type': 'select',
        'proxies': ['US-near'],
      },
    ],
    'rules': ['MATCH,手动选择'],
  };
}

void main() {
  test('no work returns the config untouched', () {
    final config = baseConfig();
    expect(buildSmartConfig(config, const SmartAnchorInput()), same(config));
  });

  test('wiring injects a ranked smart group and filters blocked nodes', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = buildSmartConfig(
      baseConfig(),
      SmartAnchorInput(
        services: [claude],
        anchors: {'claude': anchor},
        metadataByProxy: {
          'US-near': meta('US-near', 34.0522, -118.2437, 90),
          'US-far': meta('US-far', 40.7128, -74.0060, 90),
          'US-blocked': meta('US-blocked', 34.0522, -118.2437, 95),
        },
        accessByService: {
          'claude': {
            'US-near': ServiceAccessResult(
              serviceId: 'claude',
              proxyName: 'US-near',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.accessible,
              checkedAt: now,
            ),
            'US-blocked': ServiceAccessResult(
              serviceId: 'claude',
              proxyName: 'US-blocked',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.regionBlocked,
              checkedAt: now,
            ),
          },
        },
      ),
    );
    final groups = result['proxy-groups'] as List;
    expect(groups.first['name'], '🎯 Smart-Claude');
    expect(groups.first['proxies'], ['US-near', 'US-far', 'US-unknown']);
    final rules = result['rules'] as List;
    expect(rules.first, 'DOMAIN-SUFFIX,claude.ai,🎯 Smart-Claude');
    final dns = result['dns'] as Map;
    expect(
      (dns['nameserver-policy'] as Map)['claude.ai'],
      'https://1.1.1.1/dns-query#🎯 Smart-Claude',
    );
  });

  test('config ranking uses delays and elects the fastest anchor on ties', () {
    final result = buildSmartConfig(
      {
        'proxies': [
          {'name': 'S', 'type': 'vless', 'server': 's.example'},
          {'name': 'F', 'type': 'vless', 'server': 'f.example'},
        ],
        'proxy-groups': [],
        'rules': [],
      },
      SmartAnchorInput(
        services: [claude],
        metadataByProxy: {'S': meta('S', 0, 0, 90), 'F': meta('F', 0, 30, 90)},
      ),
      delays: {'S': 900, 'F': 100},
    );
    final groups = result['proxy-groups'] as List;
    expect(groups.first['name'], '🎯 Smart-Claude');
    expect(groups.first['proxies'], ['F', 'S']);
  });

  test('wiring merges an aggregation source before smart injection', () {
    final result = buildSmartConfig(
      baseConfig(),
      SmartAnchorInput(
        services: [claude.copyWith(isEnabled: false)],
        aggregationEnabled: true,
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final proxies = result['proxies'] as List;
    expect(proxies.length, 5);
    final groups = result['proxy-groups'] as List;
    expect(groups.first['name'], '🔗 聚合全部节点');
  });

  test('unified aggregation group stays first when smart groups inject', () {
    final result = buildSmartConfig(
      baseConfig(),
      const SmartAnchorInput(
        services: [claude],
        aggregationEnabled: true,
        aggregationSources: [
          AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final groups = result['proxy-groups'] as List;
    expect(groups.first['name'], '🔗 聚合全部节点');
    expect(groups[1]['name'], '🎯 Smart-Claude');
  });

  test('unified aggregation group orders nodes by engine purity', () {
    final result = buildSmartConfig(
      baseConfig(),
      SmartAnchorInput(
        services: [claude.copyWith(isEnabled: false)],
        aggregationEnabled: true,
        metadataByProxy: {
          'US-far': meta('US-far', 40.7128, -74.0060, 70),
          'US-near': meta('US-near', 34.0522, -118.2437, 90),
          'B-01': meta('B-01', 34.0522, -118.2437, 80),
        },
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final groups = result['proxy-groups'] as List;
    final unified = groups.firstWhere((group) => group['name'] == '🔗 聚合全部节点');
    expect(unified['proxies'], [
      '[主订阅] US-near',
      '[B] B-01',
      '[主订阅] US-far',
      '[主订阅] US-blocked',
      '[主订阅] US-unknown',
    ]);
  });

  test('disabled aggregation leaves the config unmerged', () {
    final result = buildSmartConfig(
      baseConfig(),
      SmartAnchorInput(
        services: [claude.copyWith(isEnabled: false)],
        aggregationEnabled: false,
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final proxies = result['proxies'] as List;
    expect(proxies.length, 4);
    final groups = result['proxy-groups'] as List;
    expect(groups.any((group) => group['name'] == '🔗 聚合全部节点'), isFalse);
  });

  test('smart ranking survives aggregation renames', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = buildSmartConfig(
      baseConfig(),
      SmartAnchorInput(
        services: [claude],
        aggregationEnabled: true,
        anchors: {'claude': anchor},
        metadataByProxy: {
          'US-near': meta('US-near', 34.0522, -118.2437, 90),
          'US-far': meta('US-far', 40.7128, -74.0060, 90),
          'US-blocked': meta('US-blocked', 34.0522, -118.2437, 95),
          'B-01': meta('B-01', 34.0522, -118.2437, 80),
        },
        accessByService: {
          'claude': {
            'US-near': ServiceAccessResult(
              serviceId: 'claude',
              proxyName: 'US-near',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.accessible,
              checkedAt: now,
            ),
            'US-blocked': ServiceAccessResult(
              serviceId: 'claude',
              proxyName: 'US-blocked',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.regionBlocked,
              checkedAt: now,
            ),
          },
        },
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final groups = result['proxy-groups'] as List;
    final smart = groups.firstWhere(
      (group) => group['name'] == '🎯 Smart-Claude',
    );
    expect(smart['proxies'], [
      '[主订阅] US-near',
      '[B] B-01',
      '[主订阅] US-far',
      '[主订阅] US-unknown',
    ]);
  });

  test('a stripped fallback never leaks across same-named sources', () {
    final result = buildSmartConfig(
      {
        'proxies': [
          {'name': 'US-near', 'type': 'vless', 'server': 'a.example'},
          {'name': 'X-01', 'type': 'vless', 'server': 'x.example'},
        ],
        'proxy-groups': <dynamic>[],
        'rules': <dynamic>[],
      },
      SmartAnchorInput(
        services: [claude],
        aggregationEnabled: true,
        anchors: {'claude': anchor},
        metadataByProxy: {
          'US-near': meta('US-near', 34.0522, -118.2437, 90),
          'X-01': meta('X-01', 34.0522, -118.2437, 99),
        },
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'X-01', 'type': 'vless', 'server': 'y.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final groups = result['proxy-groups'] as List;
    final smart = groups.firstWhere(
      (group) => group['name'] == '🎯 Smart-Claude',
    );
    // Both X-01 nodes stay in the unknown fallback (neither inherits the
    // stripped record); the fallback segment orders alphabetically, as
    // the candidate decider sorts it, not by pool position.
    expect(smart['proxies'], ['[主订阅] US-near', '[B] X-01', '[主订阅] X-01']);
  });

  group('candidate decision build', () {
    NodeMetadataCache metaCc(
      String name,
      String country,
      double purity, {
      String asn = 'AS100',
      String ip = '1.2.3.4',
    }) {
      return NodeMetadataCache(
        proxyName: name,
        entryServer: 'entry.example',
        egressIp: ip,
        countryCode: country,
        latitude: 35.0,
        longitude: 139.0,
        asn: asn,
        ipType: 'residential',
        fraudScore: 0,
        purityScore: purity,
        wafPass: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }

    Map<String, dynamic> configFor(List<String> names) {
      return {
        'proxies': [
          for (final name in names)
            {'name': name, 'type': 'vless', 'server': 's.example'},
        ],
        'proxy-groups': <dynamic>[],
        'rules': <dynamic>[],
      };
    }

    List<String> smartMembers(Map<String, dynamic> result, String label) {
      final groups = result['proxy-groups'] as List;
      final group =
          groups.firstWhere(
                (entry) => (entry as Map)['name'] == '🎯 Smart-$label',
              )
              as Map;
      return (group['proxies'] as List).cast<String>();
    }

    test('rankedByService mirrors the decision order per service', () {
      final built = buildSmartConfigWithRanking(
        baseConfig(),
        SmartAnchorInput(
          services: [claude],
          anchors: {'claude': anchor},
          metadataByProxy: {
            'US-near': meta('US-near', 34.0522, -118.2437, 90),
            'US-far': meta('US-far', 40.7128, -74.0060, 90),
          },
        ),
      );
      final decision = built.decisionsByService['claude']!;
      expect(built.rankedByService['claude'], decision.ordered);
      expect(built.rankedByService['claude'], [
        ...decision.qualified,
        ...decision.fallback,
      ]);
      expect(built.proxyNames, [
        'US-near',
        'US-far',
        'US-blocked',
        'US-unknown',
      ]);
      expect(smartMembers(built.config, 'Claude'), decision.ordered);
    });

    test('group order follows route tiers over the legacy total score', () {
      const jpAnchor = ServiceAnchor(
        serviceTag: 'claude',
        countryCode: 'JP',
        lastProxyName: 'JP-cur',
        egressIp: '10.0.0.5',
        subnet24: '10.0.0',
        asn: 'AS100',
        isp: '',
        latitude: 35.0,
        longitude: 139.0,
        city: '',
        confirmedAt: 0,
      );
      const jpClaude = ServiceToggleConfig(
        serviceId: 'claude',
        displayName: 'Claude',
        isEnabled: true,
        targetCountry: 'JP',
        matchRules: ['DOMAIN-SUFFIX,claude.ai'],
        dnsDomains: ['claude.ai'],
      );
      final built = buildSmartConfigWithRanking(
        configFor(['JP-diffasn', 'JP-sameasn']),
        SmartAnchorInput(
          services: [jpClaude],
          anchors: {'claude': jpAnchor},
          metadataByProxy: {
            'JP-sameasn': metaCc('JP-sameasn', 'JP', 55, ip: '10.9.0.1'),
            'JP-diffasn': metaCc(
              'JP-diffasn',
              'JP',
              100,
              asn: 'AS999',
              ip: '10.8.0.1',
            ),
          },
        ),
        delays: {'JP-sameasn': 900, 'JP-diffasn': 10},
      );
      expect(smartMembers(built.config, 'Claude'), [
        'JP-sameasn',
        'JP-diffasn',
      ]);
      final decision = built.decisionsByService['claude']!;
      expect(decision.assessments['JP-sameasn']!.tier, RouteTier.l3);
      expect(decision.assessments['JP-diffasn']!.tier, RouteTier.l4);
      expect(decision.explanation, contains('qualified=2'));
    });

    test('strict groups exclude unknown nodes, relaxed park them last', () {
      final strict = claude.copyWith(
        restrictionMode: ServiceRestrictionMode.strict,
      );
      final names = ['US-1', 'mystery'];
      final metadata = {'US-1': metaCc('US-1', 'US', 90)};
      final strictBuilt = buildSmartConfigWithRanking(
        configFor(names),
        SmartAnchorInput(services: [strict], metadataByProxy: metadata),
      );
      expect(smartMembers(strictBuilt.config, 'Claude'), ['US-1']);
      expect(
        strictBuilt
            .decisionsByService['claude']!
            .assessments['mystery']!
            .rejection,
        CandidateRejection.unknownCountryStrict,
      );

      final relaxedBuilt = buildSmartConfigWithRanking(
        configFor(names),
        SmartAnchorInput(services: [claude], metadataByProxy: metadata),
      );
      expect(smartMembers(relaxedBuilt.config, 'Claude'), ['US-1', 'mystery']);
      expect(relaxedBuilt.decisionsByService['claude']!.fallback, ['mystery']);
    });

    test('a restricted service with no candidate fails closed on REJECT', () {
      final built = buildSmartConfigWithRanking(
        configFor(['US-1']),
        SmartAnchorInput(
          services: [claude],
          metadataByProxy: {'US-1': metaCc('US-1', 'JP', 90)},
        ),
      );
      final members = smartMembers(built.config, 'Claude');
      expect(members, ['REJECT']);
      expect(members, isNot(contains('DIRECT')));
      expect(built.decisionsByService['claude']!.ordered, isEmpty);
      expect(built.rankedByService['claude'], isEmpty);
    });

    test('an unrestricted service with no ranking keeps the DIRECT group', () {
      const google = ServiceToggleConfig(
        serviceId: 'google',
        displayName: 'Google',
        isEnabled: true,
        targetCountry: '',
        restrictionMode: ServiceRestrictionMode.unrestricted,
        matchRules: ['GEOSITE,google'],
        dnsDomains: ['google.com'],
      );
      final built = buildSmartConfigWithRanking(
        configFor(['US-1']),
        SmartAnchorInput(
          services: [google],
          metadataByProxy: {'US-1': metaCc('US-1', 'JP', 90)},
        ),
      );
      // Unrestricted decisions still list known nodes; empty the pool by
      // building with no proxies at all for the DIRECT case.
      expect(smartMembers(built.config, 'Google'), ['US-1']);
      final empty = buildSmartConfigWithRanking(
        configFor(const []),
        const SmartAnchorInput(services: [google]),
      );
      expect(smartMembers(empty.config, 'Google'), ['DIRECT']);
    });

    test('merged decisions are computed on the remapped names', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final built = buildSmartConfigWithRanking(
        baseConfig(),
        SmartAnchorInput(
          services: [claude],
          aggregationEnabled: true,
          anchors: {'claude': anchor},
          metadataByProxy: {
            'US-near': meta('US-near', 34.0522, -118.2437, 90),
            'US-far': meta('US-far', 40.7128, -74.0060, 90),
            'US-blocked': meta('US-blocked', 34.0522, -118.2437, 95),
          },
          accessByService: {
            'claude': {
              'US-blocked': ServiceAccessResult(
                serviceId: 'claude',
                proxyName: 'US-blocked',
                egressIp: '1.2.3.4',
                reason: ServiceAccessReason.regionBlocked,
                checkedAt: now,
              ),
            },
          },
          aggregationSources: [
            const AggregationSourceInput(
              sourceId: 'extra',
              sourceLabel: 'B',
              config: {
                'proxies': [
                  {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
                ],
                'proxy-groups': [],
                'rules': [],
              },
            ),
          ],
        ),
      );
      final decision = built.decisionsByService['claude']!;
      expect(decision.blocked, contains('[主订阅] US-blocked'));
      expect(decision.ordered, built.rankedByService['claude']);
      expect(decision.ordered, isNot(contains('US-near')));
      expect(decision.ordered.first, '[主订阅] US-near');
    });
  });

  test('merged remap keeps city and geo confidence for tiering', () {
    NodeMetadataCache geoMeta(
      String name, {
      String? city,
      double? geoConfidence,
      required String asn,
      required String ip,
    }) {
      return NodeMetadataCache(
        proxyName: name,
        entryServer: 'entry.example',
        egressIp: ip,
        countryCode: 'US',
        latitude: 34.0522,
        longitude: -118.2437,
        asn: asn,
        ipType: 'residential',
        fraudScore: 0,
        purityScore: 90,
        wafPass: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        city: city,
        adminRegion: city,
        geoConfidence: geoConfidence,
      );
    }

    final result = buildSmartConfig(
      {
        'proxies': [
          {'name': 'US-asn', 'type': 'vless', 'server': 'a.example'},
          {'name': 'US-city', 'type': 'vless', 'server': 'b.example'},
        ],
        'proxy-groups': <dynamic>[],
        'rules': <dynamic>[],
      },
      SmartAnchorInput(
        services: [claude],
        aggregationEnabled: true,
        anchors: {'claude': anchor},
        metadataByProxy: {
          'US-city': geoMeta(
            'US-city',
            city: 'Los Angeles',
            geoConfidence: 0.95,
            asn: 'AS999',
            ip: '9.9.9.9',
          ),
          'US-asn': geoMeta('US-asn', asn: 'AS20057', ip: '8.8.8.8'),
        },
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'B-01', 'type': 'vless', 'server': 'e.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final groups = result['proxy-groups'] as List;
    final smart = groups.firstWhere(
      (group) => group['name'] == '🎯 Smart-Claude',
    );
    expect(smart['proxies'], ['[主订阅] US-city', '[主订阅] US-asn', '[B] B-01']);
  });

  test('a stripped fallback still applies when the name is unique', () {
    final result = buildSmartConfig(
      {
        'proxies': [
          {'name': 'US-near', 'type': 'vless', 'server': 'a.example'},
        ],
        'proxy-groups': <dynamic>[],
        'rules': <dynamic>[],
      },
      SmartAnchorInput(
        services: [claude],
        aggregationEnabled: true,
        anchors: {'claude': anchor},
        metadataByProxy: {
          'US-near': meta('US-near', 34.0522, -118.2437, 90),
          'X-01': meta('X-01', 34.0522, -118.2437, 99),
        },
        aggregationSources: [
          const AggregationSourceInput(
            sourceId: 'extra',
            sourceLabel: 'B',
            config: {
              'proxies': [
                {'name': 'X-01', 'type': 'vless', 'server': 'y.example'},
              ],
              'proxy-groups': [],
              'rules': [],
            },
          ),
        ],
      ),
    );
    final groups = result['proxy-groups'] as List;
    final smart = groups.firstWhere(
      (group) => group['name'] == '🎯 Smart-Claude',
    );
    expect(smart['proxies'], ['[B] X-01', '[主订阅] US-near']);
  });
}
