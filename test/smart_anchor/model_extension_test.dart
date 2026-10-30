import 'dart:convert';

import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:flutter_test/flutter_test.dart';

const legacyMetadataJson = {
  'proxyName': 'US-01',
  'entryServer': 'entry.example',
  'egressIp': '1.2.3.4',
  'countryCode': 'US',
  'latitude': 34.0522,
  'longitude': -118.2437,
  'asn': 'AS20057',
  'ipType': 'residential',
  'fraudScore': 0.0,
  'purityScore': 90.0,
  'wafPass': true,
  'updatedAt': 1700000000000,
  'ttlHours': 72,
  'sourceCount': 2,
  'countryDisputed': false,
};

Map<String, dynamic> legacyToggleJson({
  required String targetCountry,
  List<String> targetCountries = const [],
}) {
  return {
    'serviceId': 'legacy',
    'displayName': 'Legacy',
    'isEnabled': true,
    'targetCountry': targetCountry,
    'matchRules': ['DOMAIN-SUFFIX,example.com'],
    'dnsDomains': ['example.com'],
    'targetCountries': targetCountries,
    'officialName': '',
    'regionMode': 'blacklist',
    'regionCountries': <String>[],
  };
}

void main() {
  group('NodeMetadataCache geo confidence fields', () {
    test('new fields default to unknown, never to a fabricated place', () {
      final restored = NodeMetadataCache.fromJson(
        jsonDecode(jsonEncode(legacyMetadataJson)) as Map<String, dynamic>,
      );
      expect(restored.countryCode, 'US');
      expect(restored.adminRegion, isNull);
      expect(restored.city, isNull);
      expect(restored.geoConfidence, isNull);
      expect(restored.asnConfidence, isNull);
    });

    test('new fields round-trip through json', () {
      const node = NodeMetadataCache(
        proxyName: 'US-01',
        entryServer: 'entry.example',
        egressIp: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0522,
        longitude: -118.2437,
        asn: 'AS20057',
        ipType: 'residential',
        fraudScore: 0,
        purityScore: 90,
        wafPass: true,
        updatedAt: 1700000000000,
        adminRegion: 'California',
        city: 'Los Angeles',
        geoConfidence: 0.9,
        asnConfidence: 0.75,
      );
      final restored = NodeMetadataCache.fromJson(
        jsonDecode(jsonEncode(node.toJson())) as Map<String, dynamic>,
      );
      expect(restored.adminRegion, 'California');
      expect(restored.city, 'Los Angeles');
      expect(restored.geoConfidence, 0.9);
      expect(restored.asnConfidence, 0.75);
      expect(restored.countryCode, 'US');
    });
  });

  group('ServiceToggleConfig restrictionMode', () {
    test('legacy json for a locked service degrades to relaxed', () {
      final restored = ServiceToggleConfig.fromJson(
        legacyToggleJson(targetCountry: 'US', targetCountries: ['US']),
      );
      expect(restored.restrictionMode, ServiceRestrictionMode.relaxed);
    });

    test('legacy json for an unlocked service degrades to unrestricted', () {
      final restored = ServiceToggleConfig.fromJson(
        legacyToggleJson(targetCountry: ''),
      );
      expect(restored.restrictionMode, ServiceRestrictionMode.unrestricted);
    });

    test('an explicit strict mode round-trips through json', () {
      const config = ServiceToggleConfig(
        serviceId: 'claude',
        displayName: 'Claude',
        isEnabled: true,
        targetCountry: 'US',
        matchRules: [],
        dnsDomains: [],
        restrictionMode: ServiceRestrictionMode.strict,
      );
      final restored = ServiceToggleConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(restored.restrictionMode, ServiceRestrictionMode.strict);
    });

    test('an unrecognized stored mode falls back to the derived default', () {
      final json = legacyToggleJson(
        targetCountry: 'US',
        targetCountries: ['US'],
      )..['restrictionMode'] = 'extreme';
      final restored = ServiceToggleConfig.fromJson(json);
      expect(restored.restrictionMode, ServiceRestrictionMode.relaxed);
    });

    test('copyWith preserves the mode unless it is replaced', () {
      const config = ServiceToggleConfig(
        serviceId: 'google',
        displayName: 'Google',
        isEnabled: true,
        targetCountry: '',
        matchRules: [],
        dnsDomains: [],
        restrictionMode: ServiceRestrictionMode.unrestricted,
      );
      expect(
        config.copyWith(isEnabled: false).restrictionMode,
        ServiceRestrictionMode.unrestricted,
      );
      expect(
        config
            .copyWith(restrictionMode: ServiceRestrictionMode.relaxed)
            .restrictionMode,
        ServiceRestrictionMode.relaxed,
      );
    });
  });
}
