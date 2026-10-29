import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache meta(String name, String country, double purity) {
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

const unlocked = ServiceToggleConfig(
  serviceId: 'gemini',
  displayName: 'Gemini',
  isEnabled: true,
  targetCountry: '',
  matchRules: [],
  dnsDomains: [],
);

final usLocked = unlocked.copyWith(
  targetCountry: 'US',
  targetCountries: ['US'],
);

SmartAnchorInput inputWith(Map<String, NodeMetadataCache> metadata) {
  return SmartAnchorInput(services: [usLocked], metadataByProxy: metadata);
}

void main() {
  test('selection outside the new lock moves to the top compliant node', () {
    final input = inputWith({
      'TW-1': meta('TW-1', 'TW', 100),
      'US-1': meta('US-1', 'US', 90),
      'US-2': meta('US-2', 'US', 80),
    });
    final target = lockReselectTarget(input, usLocked, [
      'TW-1',
      'US-1',
      'US-2',
    ], 'TW-1');
    expect(target, 'US-1');
  });

  test('compliant selection stays even when it is not top ranked', () {
    final input = inputWith({
      'TW-1': meta('TW-1', 'TW', 100),
      'US-1': meta('US-1', 'US', 90),
      'US-2': meta('US-2', 'US', 80),
    });
    final target = lockReselectTarget(input, usLocked, [
      'TW-1',
      'US-1',
      'US-2',
    ], 'US-2');
    expect(target, isNull);
  });

  test('selection without metadata stays because its country is unknown', () {
    final input = inputWith({'US-1': meta('US-1', 'US', 90)});
    final target = lockReselectTarget(input, usLocked, [
      'US-1',
      'unprobed',
    ], 'unprobed');
    expect(target, isNull);
  });

  test('known violator falls back to an unprobed node', () {
    final input = inputWith({'TW-1': meta('TW-1', 'TW', 100)});
    final target = lockReselectTarget(input, usLocked, [
      'TW-1',
      'unprobed',
    ], 'TW-1');
    expect(target, 'unprobed');
  });

  test('no compliant or unprobed node keeps the current selection', () {
    final input = inputWith({
      'TW-1': meta('TW-1', 'TW', 100),
      'HK-1': meta('HK-1', 'HK', 90),
    });
    final target = lockReselectTarget(input, usLocked, [
      'TW-1',
      'HK-1',
    ], 'TW-1');
    expect(target, isNull);
  });

  test('without a lock every known selection complies', () {
    final input = SmartAnchorInput(
      services: [unlocked],
      metadataByProxy: {
        'TW-1': meta('TW-1', 'TW', 100),
        'US-1': meta('US-1', 'US', 90),
      },
    );
    final target = lockReselectTarget(input, unlocked, [
      'TW-1',
      'US-1',
    ], 'TW-1');
    expect(target, isNull);
  });
}
