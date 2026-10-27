import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache meta(String name, String ipType, double purity) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '',
    egressIp: '1.2.3.4',
    countryCode: 'US',
    latitude: 37.0,
    longitude: -122.0,
    asn: 'AS1234',
    ipType: ipType,
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: 0,
  );
}

void main() {
  test('smart group name uses the official spelling', () {
    const annotated = ServiceToggleConfig(
      serviceId: 'claude',
      displayName: 'Claude (克劳德)',
      isEnabled: true,
      targetCountry: 'US',
      matchRules: [],
      dnsDomains: [],
    );
    expect(smartGroupName(annotated), '🎯 Smart-Claude (克劳德)');
    const official = ServiceToggleConfig(
      serviceId: 'claude',
      displayName: 'Claude (克劳德)',
      isEnabled: true,
      targetCountry: 'US',
      matchRules: [],
      dnsDomains: [],
      officialName: 'Claude',
    );
    expect(smartGroupName(official), '🎯 Smart-Claude');
    expect(
      smartGroupNameForId('claude', {'claude': official}),
      '🎯 Smart-Claude',
    );
    expect(smartGroupNameForId('missing', {}), '🎯 Smart-MISSING');
    expect(
      defaultServiceToggles
          .firstWhere((service) => service.serviceId == 'claude')
          .groupLabel,
      'Claude',
    );
  });

  test('metadata lookup survives aggregation renames', () {
    final input = SmartAnchorInput(
      metadataByProxy: {'US-near': meta('US-near', 'residential', 88)},
    );
    expect(metadataForDisplayProxy(input, 'US-near')?.purityScore, 88);
    expect(metadataForDisplayProxy(input, '[主订阅] US-near')?.purityScore, 88);
    expect(metadataForDisplayProxy(input, '[B] unknown'), isNull);
  });

  test('node remark shows score and ip type label', () {
    expect(smartNodeRemark(meta('a', 'residential', 88.4)), '纯净度 88 · 家宽');
    expect(smartNodeRemark(meta('b', 'isp', 76)), '纯净度 76 · 家宽');
    expect(smartNodeRemark(meta('c', 'hosting', 40)), '纯净度 40 · 机房');
    expect(smartNodeRemark(meta('d', 'datacenter', 40)), '纯净度 40 · 机房');
    expect(smartNodeRemark(meta('e', 'business', 65)), '纯净度 65 · 商业');
    expect(smartNodeRemark(meta('f', 'weird-type', 65)), '纯净度 65');
    expect(smartNodeRemark(null), '');
  });
}
