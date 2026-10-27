import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_group.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache node({
  required String name,
  required String country,
  required double lat,
  required double lon,
  required double purity,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: '1.2.3.4',
    countryCode: country,
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

ServiceAnchor anchor({required double lat, required double lon}) {
  return ServiceAnchor(
    serviceTag: 'google',
    countryCode: 'US',
    lastProxyName: 'LA-node',
    egressIp: '1.2.3.4',
    subnet24: '1.2.3',
    asn: 'AS20057',
    isp: '',
    latitude: lat,
    longitude: lon,
    city: 'Los Angeles',
    confirmedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

ServiceToggleConfig service(String id, List<String> countries) {
  return ServiceToggleConfig(
    serviceId: id,
    displayName: id,
    isEnabled: true,
    targetCountry: countries.isEmpty ? '' : countries.first,
    targetCountries: countries,
    matchRules: ['GEOSITE,$id'],
    dnsDomains: ['$id.example'],
  );
}

void main() {
  test('multi-country lock normalizes and keeps order', () {
    const config = ServiceToggleConfig(
      serviceId: 'google',
      displayName: 'Google',
      isEnabled: true,
      targetCountry: 'US',
      matchRules: [],
      dnsDomains: [],
      targetCountries: ['us', 'JP', 'us', ''],
    );
    expect(config.lockedCountries, ['US', 'JP']);
  });

  test('multi-country lock round-trips through json', () {
    final config = service('google', ['US', 'JP']);
    final restored = ServiceToggleConfig.fromJson(config.toJson());
    expect(restored.lockedCountries, ['US', 'JP']);
    expect(restored.targetCountry, 'US');
  });

  test('google family services belong to one group', () {
    expect(groupForService('youtube')?.id, 'google-group');
    expect(groupForService('google')?.id, 'google-group');
    expect(groupForService('gemini')?.id, 'gemini-group');
    expect(groupForService('claude')?.id, 'anthropic-group');
    expect(groupForService('openai')?.id, 'openai-group');
  });

  test('shared group ranks members by the group anchor', () {
    final config = {
      'proxies': [
        {'name': 'LA-node', 'type': 'vless', 'server': 'la.example'},
        {'name': 'NY-node', 'type': 'vless', 'server': 'ny.example'},
      ],
      'proxy-groups': [],
      'rules': [],
    };
    final metadata = {
      'LA-node': node(
        name: 'LA-node',
        country: 'US',
        lat: 34.0522,
        lon: -118.2437,
        purity: 90,
      ),
      'NY-node': node(
        name: 'NY-node',
        country: 'US',
        lat: 40.7128,
        lon: -74.0060,
        purity: 95,
      ),
    };
    final input = SmartAnchorInput(
      services: [
        service('google', ['US']),
        service('youtube', ['US']),
      ],
      anchors: {'google': anchor(lat: 34.0522, lon: -118.2437)},
      metadataByProxy: metadata,
      sharedLockGroupIds: const ['google-group'],
    );
    final result = buildSmartConfig(config, input);
    final groups = result['proxy-groups'] as List;
    final youtubeGroup =
        groups.firstWhere(
              (group) => (group as Map)['name'] == '🎯 Smart-YOUTUBE',
            )
            as Map;
    final members = (youtubeGroup['proxies'] as List).cast<String>();
    expect(members.first, 'LA-node');
  });
}
