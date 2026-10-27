import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache regionMeta(String name, String country, double purity) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '',
    egressIp: '1.2.3.4',
    countryCode: country,
    latitude: 37.0,
    longitude: -122.0,
    asn: 'AS1234',
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: 0,
  );
}

ServiceAccessResult blocked(String proxy) {
  return ServiceAccessResult(
    serviceId: 'gemini',
    proxyName: proxy,
    egressIp: '1.2.3.4',
    reason: ServiceAccessReason.regionBlocked,
    checkedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

const gemini = ServiceToggleConfig(
  serviceId: 'gemini',
  displayName: 'Gemini',
  isEnabled: true,
  targetCountry: '',
  matchRules: [],
  dnsDomains: [],
);

void main() {
  test('blacklist default bans detected unsupported regions', () {
    final input = SmartAnchorInput(
      services: [gemini],
      metadataByProxy: {
        'US-1': regionMeta('US-1', 'US', 90),
        'HK-1': regionMeta('HK-1', 'HK', 90),
        'HK-2': regionMeta('HK-2', 'HK', 85),
      },
      accessByService: {
        'gemini': {'HK-1': blocked('HK-1')},
      },
    );
    expect(detectedUnsupportedRegions(input, 'gemini'), {'HK'});
    final ranked = rankedProxiesForService(input, gemini, [
      'US-1',
      'HK-1',
      'HK-2',
      'unprobed',
    ]);
    expect(ranked, contains('US-1'));
    expect(ranked, isNot(contains('HK-1')));
    expect(ranked, isNot(contains('HK-2')));
    expect(ranked, contains('unprobed'));
  });

  test('explicit blacklist overrides the detected default', () {
    final input = SmartAnchorInput(
      services: [
        gemini.copyWith(regionCountries: ['JP']),
      ],
      metadataByProxy: {
        'US-1': regionMeta('US-1', 'US', 90),
        'HK-1': regionMeta('HK-1', 'HK', 90),
        'HK-2': regionMeta('HK-2', 'HK', 88),
        'JP-1': regionMeta('JP-1', 'JP', 90),
      },
      accessByService: {
        'gemini': {'HK-1': blocked('HK-1')},
      },
    );
    expect(detectedUnsupportedRegions(input, 'gemini'), {'HK'});
    final ranked = rankedProxiesForService(
      input,
      gemini.copyWith(regionCountries: ['JP']),
      ['US-1', 'HK-2', 'JP-1'],
    );
    expect(ranked, contains('US-1'));
    expect(ranked, contains('HK-2'));
    expect(ranked, isNot(contains('JP-1')));
  });

  test('whitelist keeps only checked regions plus unprobed nodes', () {
    final service = gemini.copyWith(
      regionMode: 'whitelist',
      regionCountries: ['US'],
    );
    final input = SmartAnchorInput(
      services: [service],
      metadataByProxy: {
        'US-1': regionMeta('US-1', 'US', 90),
        'SG-1': regionMeta('SG-1', 'SG', 90),
      },
    );
    final ranked = rankedProxiesForService(input, service, [
      'US-1',
      'SG-1',
      'unprobed',
    ]);
    expect(ranked, contains('US-1'));
    expect(ranked, isNot(contains('SG-1')));
    expect(ranked, contains('unprobed'));
  });

  test('empty whitelist means no restriction', () {
    final service = gemini.copyWith(regionMode: 'whitelist');
    final input = SmartAnchorInput(
      services: [service],
      metadataByProxy: {
        'US-1': regionMeta('US-1', 'US', 90),
        'SG-1': regionMeta('SG-1', 'SG', 90),
      },
    );
    final ranked = rankedProxiesForService(input, service, ['US-1', 'SG-1']);
    expect(ranked, containsAll(['US-1', 'SG-1']));
  });

  test('region fields round-trip through json', () {
    const config = ServiceToggleConfig(
      serviceId: 'gemini',
      displayName: 'Gemini',
      isEnabled: true,
      targetCountry: '',
      matchRules: [],
      dnsDomains: [],
      officialName: 'Gemini',
      regionMode: 'whitelist',
      regionCountries: ['US', 'SG'],
    );
    final restored = ServiceToggleConfig.fromJson(config.toJson());
    expect(restored.officialName, 'Gemini');
    expect(restored.regionMode, 'whitelist');
    expect(restored.regionCountries, ['US', 'SG']);
    expect(restored.effectiveRegionMode, 'whitelist');
    expect(
      const ServiceToggleConfig(
        serviceId: 'x',
        displayName: 'X',
        isEnabled: false,
        targetCountry: '',
        matchRules: [],
        dnsDomains: [],
        regionMode: 'bogus',
      ).effectiveRegionMode,
      'blacklist',
    );
  });
}
