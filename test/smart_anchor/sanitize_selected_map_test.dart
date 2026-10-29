import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceToggleConfig service(String id, {bool enabled = true}) {
  return ServiceToggleConfig(
    serviceId: id,
    displayName: id,
    isEnabled: enabled,
    targetCountry: 'US',
    matchRules: ['GEOSITE,$id'],
    dnsDomains: ['$id.example'],
  );
}

void main() {
  final gemini = service('gemini');
  final claude = service('claude');
  final geminiGroup = smartGroupName(gemini);
  final claudeGroup = smartGroupName(claude);

  test('a selection outside the ranking is rewritten to the ranked head', () {
    final input = {geminiGroup: 'TW-1', 'Proxy': 'TW-1'};
    final result = sanitizeSelectedMap(
      [gemini],
      const {
        'gemini': ['US-1', 'US-2'],
      },
      input,
    );
    expect(result[geminiGroup], 'US-1');
    expect(result['Proxy'], 'TW-1');
    expect(input[geminiGroup], 'TW-1');
  });

  test('a compliant selection is kept, even below the ranked head', () {
    final input = {geminiGroup: 'US-2'};
    final result = sanitizeSelectedMap(
      [gemini],
      const {
        'gemini': ['US-1', 'US-2'],
      },
      input,
    );
    expect(result, same(input));
    expect(result[geminiGroup], 'US-2');
  });

  test('an empty or missing ranking keeps the persisted selection', () {
    final input = {geminiGroup: 'TW-1', claudeGroup: 'TW-2'};
    final result = sanitizeSelectedMap(
      [gemini, claude],
      const {'gemini': <String>[]},
      input,
    );
    expect(result, same(input));
  });

  test('a group with no persisted selection stays without one', () {
    final result = sanitizeSelectedMap(
      [gemini],
      const {
        'gemini': ['US-1'],
      },
      const {},
    );
    expect(result, isEmpty);
  });

  test('a disabled service is never rewritten', () {
    final off = service('gemini', enabled: false);
    final input = {geminiGroup: 'TW-1'};
    final result = sanitizeSelectedMap(
      [off],
      const {
        'gemini': ['US-1'],
      },
      input,
    );
    expect(result, same(input));
  });
}
