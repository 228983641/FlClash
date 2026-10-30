import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
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

  test('selection without metadata yields to a known compliant node', () {
    final input = inputWith({'US-1': meta('US-1', 'US', 90)});
    final target = lockReselectTarget(input, usLocked, [
      'US-1',
      'unprobed',
    ], 'unprobed');
    expect(target, 'US-1');
  });

  test('selection without metadata stays while no node is known compliant', () {
    final input = inputWith({'TW-1': meta('TW-1', 'TW', 100)});
    final target = lockReselectTarget(input, usLocked, [
      'TW-1',
      'unprobed',
      'also-unprobed',
    ], 'unprobed');
    expect(target, isNull);
  });

  test('decision reports whether the current selection is untested', () {
    final input = inputWith({
      'US-1': meta('US-1', 'US', 90),
      'TW-1': meta('TW-1', 'TW', 100),
    });
    final unknown = lockReselectDecision(input, usLocked, [
      'US-1',
      'unprobed',
    ], 'unprobed');
    expect(unknown.currentUnknown, isTrue);
    expect(unknown.target, 'US-1');
    final known = lockReselectDecision(input, usLocked, [
      'US-1',
      'TW-1',
    ], 'TW-1');
    expect(known.currentUnknown, isFalse);
    expect(known.target, 'US-1');
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

  group('purity hysteresis', () {
    SmartAnchorInput bandInput(
      double currentPurity, {
      String currentCountry = 'US',
      bool currentBlocked = false,
    }) {
      return SmartAnchorInput(
        services: [usLocked],
        metadataByProxy: {
          'US-cur': meta('US-cur', currentCountry, currentPurity),
          'US-1': meta('US-1', 'US', 90),
        },
        accessByService: {
          if (currentBlocked)
            'gemini': {
              'US-cur': ServiceAccessResult(
                serviceId: 'gemini',
                proxyName: 'US-cur',
                egressIp: '1.2.3.4',
                reason: ServiceAccessReason.regionBlocked,
                checkedAt: DateTime.now().millisecondsSinceEpoch,
              ),
            },
        },
      );
    }

    test('a current node at purity 40 stays', () {
      final target = lockReselectTarget(bandInput(40), usLocked, [
        'US-cur',
        'US-1',
      ], 'US-cur');
      expect(target, isNull);
    });

    test('a current node at purity 30 is reselected', () {
      final target = lockReselectTarget(bandInput(30), usLocked, [
        'US-cur',
        'US-1',
      ], 'US-cur');
      expect(target, 'US-1');
    });

    test('purity 40 with a fresh region block is reselected', () {
      // A second US node on another ASN corroborates the block, so the
      // verdicts derive a US-wide region ban and every US node leaves the
      // ranking; the point is the band does not keep the blocked node.
      ServiceAccessResult block(String proxy) {
        return ServiceAccessResult(
          serviceId: 'gemini',
          proxyName: proxy,
          egressIp: '1.2.3.4',
          reason: ServiceAccessReason.regionBlocked,
          checkedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }

      final input = SmartAnchorInput(
        services: [usLocked],
        metadataByProxy: {
          'US-cur': meta('US-cur', 'US', 40, asn: 'AS100'),
          'US-1': meta('US-1', 'US', 90),
          'US-2': meta('US-2', 'US', 80, asn: 'AS200'),
        },
        accessByService: {
          'gemini': {'US-cur': block('US-cur'), 'US-2': block('US-2')},
        },
      );
      final target = lockReselectTarget(input, usLocked, [
        'US-cur',
        'US-1',
        'US-2',
        'mystery',
      ], 'US-cur');
      expect(target, 'mystery');
    });

    test('purity 40 outside the lock is reselected', () {
      final target = lockReselectTarget(
        bandInput(40, currentCountry: 'TW'),
        usLocked,
        ['US-cur', 'US-1'],
        'US-cur',
      );
      expect(target, 'US-1');
    });
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
