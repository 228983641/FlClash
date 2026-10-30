import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache integrationNode(
  String name, {
  required String country,
  required String city,
  required double latitude,
  required double longitude,
  String egressIp = '2.2.2.2',
  String asn = 'AS200',
  double purity = 90,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '',
    egressIp: egressIp,
    countryCode: country,
    latitude: latitude,
    longitude: longitude,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    city: city,
    geoConfidence: 0.95,
  );
}

ServiceToggleConfig integrationService(ServiceRestrictionMode mode) {
  return ServiceToggleConfig(
    serviceId: 'gemini',
    displayName: 'Gemini',
    isEnabled: true,
    targetCountry: 'US',
    targetCountries: const ['US'],
    restrictionMode: mode,
    matchRules: const [],
    dnsDomains: const [],
  );
}

const losAngelesAnchor = ServiceAnchor(
  serviceTag: 'gemini',
  countryCode: 'US',
  lastProxyName: 'old',
  egressIp: '1.1.1.1',
  subnet24: '1.1.1',
  asn: 'AS100',
  isp: '',
  latitude: 34.0522,
  longitude: -118.2437,
  city: 'Los Angeles',
  confirmedAt: 0,
);

void main() {
  test('profile ranking keeps route tier ahead of latency', () {
    final service = integrationService(ServiceRestrictionMode.strict);
    final input = SmartAnchorInput(
      services: [service],
      anchors: const {'gemini': losAngelesAnchor},
      metadataByProxy: {
        'near-slow': integrationNode(
          'near-slow',
          country: 'US',
          city: 'Los Angeles',
          latitude: 34.0522,
          longitude: -118.2437,
          egressIp: '2.2.2.2',
          purity: 70,
        ),
        'far-fast': integrationNode(
          'far-fast',
          country: 'US',
          city: 'New York',
          latitude: 40.7128,
          longitude: -74.0060,
          egressIp: '3.3.3.3',
          purity: 100,
        ),
      },
    );

    final ranked = rankedProxiesForService(
      input,
      service,
      const ['far-fast', 'near-slow'],
      delays: const {'far-fast': 20, 'near-slow': 900},
    );

    expect(ranked, ['near-slow', 'far-fast']);
  });

  test('strict lock never reselects an unknown-country fallback', () {
    final service = integrationService(ServiceRestrictionMode.strict);
    final input = SmartAnchorInput(
      services: [service],
      metadataByProxy: {
        'violator': integrationNode(
          'violator',
          country: 'TW',
          city: 'Taipei',
          latitude: 25.0330,
          longitude: 121.5654,
        ),
      },
    );

    final decision = lockReselectDecision(input, service, const [
      'violator',
      'unknown',
    ], 'violator');

    expect(decision.ranked, isEmpty);
    expect(decision.target, 'REJECT');
  });

  test('relaxed lock exposes unknown nodes only after qualified nodes', () {
    final service = integrationService(ServiceRestrictionMode.relaxed);
    final input = SmartAnchorInput(
      services: [service],
      metadataByProxy: {
        'known': integrationNode(
          'known',
          country: 'US',
          city: 'Los Angeles',
          latitude: 34.0522,
          longitude: -118.2437,
        ),
      },
    );

    expect(
      rankedProxiesForService(input, service, const ['unknown', 'known']),
      ['known', 'unknown'],
    );
  });

  test(
    'setup sanitization matches runtime compliance for relaxed fallback',
    () {
      final service = integrationService(ServiceRestrictionMode.relaxed);
      final input = SmartAnchorInput(
        services: [service],
        metadataByProxy: {
          'known': integrationNode(
            'known',
            country: 'US',
            city: 'Los Angeles',
            latitude: 34.0522,
            longitude: -118.2437,
          ),
        },
      );
      final runtime = lockReselectDecision(input, service, const [
        'unknown',
        'known',
      ], 'unknown');

      final sanitized = sanitizeSelectedMap(
        [service],
        {'gemini': runtime.ranked},
        {smartGroupName(service): 'unknown'},
        qualifiedByService: const {
          'gemini': ['known'],
        },
      );

      expect(runtime.target, 'known');
      expect(sanitized[smartGroupName(service)], runtime.target);
    },
  );
}
