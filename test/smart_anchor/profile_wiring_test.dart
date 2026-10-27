import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
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
    expect(groups.first['name'], '🎯 Smart-CLAUDE');
    expect(groups.first['proxies'], ['US-near', 'US-far', 'US-unknown']);
    final rules = result['rules'] as List;
    expect(rules.first, 'DOMAIN-SUFFIX,claude.ai,🎯 Smart-CLAUDE');
    final dns = result['dns'] as Map;
    expect(
      (dns['nameserver-policy'] as Map)['claude.ai'],
      'https://1.1.1.1/dns-query#🎯 Smart-CLAUDE',
    );
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
      (group) => group['name'] == '🎯 Smart-CLAUDE',
    );
    expect(smart['proxies'], [
      '[主订阅] US-near',
      '[B] B-01',
      '[主订阅] US-far',
      '[主订阅] US-unknown',
    ]);
  });
}
