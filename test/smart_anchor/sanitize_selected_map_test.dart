import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache meta(
  String name,
  String country,
  double purity, {
  String asn = 'AS100',
  bool waf = true,
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
    wafPass: waf,
    updatedAt: 0,
  );
}

ServiceToggleConfig service(
  String id, {
  bool enabled = true,
  String lock = 'US',
  ServiceRestrictionMode mode = ServiceRestrictionMode.relaxed,
}) {
  return ServiceToggleConfig(
    serviceId: id,
    displayName: id,
    isEnabled: enabled,
    targetCountry: lock,
    matchRules: ['GEOSITE,$id'],
    dnsDomains: ['$id.example'],
    restrictionMode: mode,
  );
}

void main() {
  final gemini = service('gemini');
  final claude = service('claude');
  final geminiGroup = smartGroupName(gemini);
  final claudeGroup = smartGroupName(claude);
  const pool = ['US-1', 'US-2', 'TW-1'];

  SmartAnchorInput inputFor(
    List<ServiceToggleConfig> services,
    Map<String, NodeMetadataCache> metadata, {
    Map<String, Map<String, ServiceAccessResult>> access = const {},
  }) {
    return SmartAnchorInput(
      services: services,
      metadataByProxy: metadata,
      accessByService: access,
    );
  }

  final usMeta = {
    'US-1': meta('US-1', 'US', 90),
    'US-2': meta('US-2', 'US', 80),
    'TW-1': meta('TW-1', 'TW', 100),
  };

  test('a selection outside the lock is rewritten to the decision target', () {
    final input = {geminiGroup: 'TW-1', 'Proxy': 'TW-1'};
    final result = sanitizeSelectedMap(inputFor([gemini], usMeta), pool, input);
    expect(result.selectedMap[geminiGroup], 'US-1');
    expect(result.selectedMap['Proxy'], 'TW-1');
    expect(result.dispositions[geminiGroup], SanitizeDisposition.replaced);
    expect(input[geminiGroup], 'TW-1');
  });

  test('a compliant selection is kept, even below the qualified head', () {
    final input = {geminiGroup: 'US-2'};
    final result = sanitizeSelectedMap(inputFor([gemini], usMeta), pool, input);
    expect(result.selectedMap, same(input));
    expect(result.selectedMap[geminiGroup], 'US-2');
    expect(result.dispositions[geminiGroup], SanitizeDisposition.compliant);
  });

  test('an unknown selection yields to a qualified node', () {
    final input = {geminiGroup: 'mystery'};
    final result = sanitizeSelectedMap(inputFor([gemini], usMeta), [
      ...pool,
      'mystery',
    ], input);
    expect(result.selectedMap[geminiGroup], 'US-1');
    expect(result.dispositions[geminiGroup], SanitizeDisposition.replaced);
  });

  test('an unknown selection stays while nothing qualifies', () {
    final input = {geminiGroup: 'mystery'};
    final result = sanitizeSelectedMap(
      inputFor([gemini], {'TW-1': meta('TW-1', 'TW', 100)}),
      ['TW-1', 'mystery', 'also-unknown'],
      input,
    );
    expect(result.selectedMap, same(input));
    expect(
      result.dispositions[geminiGroup],
      SanitizeDisposition.unverifiableKept,
    );
  });

  test('a known-violating selection falls back to an unknown node', () {
    final input = {geminiGroup: 'TW-1'};
    final result = sanitizeSelectedMap(
      inputFor([gemini], {'TW-1': meta('TW-1', 'TW', 100)}),
      ['TW-1', 'mystery'],
      input,
    );
    expect(result.selectedMap[geminiGroup], 'mystery');
    expect(result.dispositions[geminiGroup], SanitizeDisposition.replaced);
  });

  test('a known-violating selection with no candidate is kept apart', () {
    final input = {geminiGroup: 'TW-1'};
    final result = sanitizeSelectedMap(
      inputFor([gemini], usMeta),
      ['TW-1', 'US-1'],
      {...input},
    );
    // US-1 qualifies here, so use a pool where nothing can serve.
    final noCandidate = sanitizeSelectedMap(
      inputFor(
        [gemini],
        {'TW-1': meta('TW-1', 'TW', 100), 'HK-1': meta('HK-1', 'HK', 90)},
      ),
      ['TW-1', 'HK-1'],
      input,
    );
    expect(result.selectedMap[geminiGroup], 'US-1');
    expect(noCandidate.selectedMap, same(input));
    expect(
      noCandidate.dispositions[geminiGroup],
      SanitizeDisposition.noCandidateKept,
    );
  });

  test('purity hysteresis keeps a current node inside the band', () {
    final input = {geminiGroup: 'US-cur'};
    final result = sanitizeSelectedMap(
      inputFor(
        [gemini],
        {'US-cur': meta('US-cur', 'US', 42), 'US-1': meta('US-1', 'US', 90)},
      ),
      ['US-cur', 'US-1'],
      input,
    );
    expect(result.selectedMap, same(input));
    expect(result.dispositions[geminiGroup], SanitizeDisposition.hysteresis);
  });

  test('strict never replaces an unknown selection with another unknown', () {
    final strict = service('gemini', mode: ServiceRestrictionMode.strict);
    final input = {geminiGroup: 'mystery'};
    final result = sanitizeSelectedMap(
      inputFor([strict], {'TW-1': meta('TW-1', 'TW', 100)}),
      ['TW-1', 'mystery'],
      input,
    );
    expect(result.selectedMap, same(input));
    expect(
      result.dispositions[geminiGroup],
      SanitizeDisposition.unverifiableKept,
    );
  });

  test('strict moves an unknown selection to a qualified node', () {
    final strict = service('gemini', mode: ServiceRestrictionMode.strict);
    final input = {geminiGroup: 'mystery'};
    final result = sanitizeSelectedMap(inputFor([strict], usMeta), [
      ...pool,
      'mystery',
    ], input);
    expect(result.selectedMap[geminiGroup], 'US-1');
    expect(result.dispositions[geminiGroup], SanitizeDisposition.replaced);
  });

  test('a group with no persisted selection gets no disposition', () {
    final result = sanitizeSelectedMap(
      inputFor([gemini], usMeta),
      pool,
      const {},
    );
    expect(result.selectedMap, isEmpty);
    expect(result.dispositions, isEmpty);
  });

  test('a disabled service is never rewritten', () {
    final off = service('gemini', enabled: false);
    final input = {geminiGroup: 'TW-1'};
    final result = sanitizeSelectedMap(inputFor([off], usMeta), pool, input);
    expect(result.selectedMap, same(input));
    expect(result.dispositions, isEmpty);
  });

  test('an empty pool keeps the persisted selection unverifiable', () {
    final input = {geminiGroup: 'TW-1', claudeGroup: 'TW-2'};
    final result = sanitizeSelectedMap(
      inputFor([gemini, claude], usMeta),
      const [],
      input,
    );
    expect(result.selectedMap, same(input));
    expect(result.dispositions, isEmpty);
  });

  group('consistency with lockReselectDecision', () {
    void checkConsistency({
      required SmartAnchorInput input,
      required ServiceToggleConfig svc,
      required List<String> names,
      required String current,
    }) {
      final group = smartGroupName(svc);
      final lockTarget = lockReselectTarget(input, svc, names, current);
      final result = sanitizeSelectedMap(input, names, {group: current});
      if (lockTarget == null) {
        expect(
          result.selectedMap[group],
          current,
          reason: 'lock keeps $current, sanitize must not move it',
        );
      } else {
        expect(
          result.selectedMap[group],
          lockTarget,
          reason: 'lock moves $current to $lockTarget, sanitize must agree',
        );
      }
    }

    test('move and keep verdicts agree across the core scenarios', () {
      final scenarios =
          <
            ({
              Map<String, NodeMetadataCache> metadata,
              List<String> names,
              String current,
            })
          >[
            (metadata: usMeta, names: pool, current: 'TW-1'),
            (metadata: usMeta, names: pool, current: 'US-2'),
            (
              metadata: {'US-1': meta('US-1', 'US', 90)},
              names: ['US-1', 'unprobed'],
              current: 'unprobed',
            ),
            (
              metadata: {'TW-1': meta('TW-1', 'TW', 100)},
              names: ['TW-1', 'unprobed'],
              current: 'unprobed',
            ),
            (
              metadata: {'TW-1': meta('TW-1', 'TW', 100)},
              names: ['TW-1', 'unprobed'],
              current: 'TW-1',
            ),
            (
              metadata: {
                'US-cur': meta('US-cur', 'US', 42),
                'US-1': meta('US-1', 'US', 90),
              },
              names: ['US-cur', 'US-1'],
              current: 'US-cur',
            ),
            (
              metadata: {
                'US-cur': meta('US-cur', 'US', 30),
                'US-1': meta('US-1', 'US', 90),
              },
              names: ['US-cur', 'US-1'],
              current: 'US-cur',
            ),
          ];
      for (final scenario in scenarios) {
        checkConsistency(
          input: inputFor([gemini], scenario.metadata),
          svc: gemini,
          names: scenario.names,
          current: scenario.current,
        );
      }
    });
  });
}
