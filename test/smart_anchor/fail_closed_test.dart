import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/config_injector.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

import 'profile_decision_integration_test.dart' show integrationNode;

const service = ServiceToggleConfig(
  serviceId: 'claude',
  displayName: 'Claude',
  isEnabled: true,
  targetCountry: 'US',
  matchRules: ['DOMAIN-SUFFIX,claude.ai'],
  dnsDomains: ['claude.ai'],
  restrictionMode: ServiceRestrictionMode.strict,
);

void main() {
  test('a newly verified candidate requests a config rebuild for recovery', () {
    const before = SmartAnchorInput(services: [service]);
    final after = before.copyWith(
      metadataByProxy: {
        'US-1': integrationNode(
          'US-1',
          country: 'US',
          city: 'Boston',
          latitude: 42.36,
          longitude: -71.06,
        ),
      },
    );
    expect(smartCandidatePoolsChanged(before, after, ['US-1']), isTrue);
    expect(smartCandidatePoolsChanged(after, after, ['US-1']), isFalse);
  });
  test('strict empty pool rejects traffic including service DNS', () {
    final config = SmartConfigInjector.injectSmartRouting(
      rawConfig: const {},
      serviceConfigs: const [service],
      rankedProxiesByService: const {'claude': []},
    );
    final group = (config['proxy-groups'] as List).single as Map;
    expect(group['proxies'], ['REJECT']);
    expect(config['rules'], [
      'DOMAIN-SUFFIX,claude.ai,${smartGroupName(service)}',
    ]);
    final dns = config['dns'] as Map;
    expect(
      (dns['nameserver-policy'] as Map)['claude.ai'],
      'https://1.1.1.1/dns-query#${smartGroupName(service)}',
    );
  });

  test('strict populated pool keeps a runtime rejection target last', () {
    final config = SmartConfigInjector.injectSmartRouting(
      rawConfig: const {},
      serviceConfigs: const [service],
      rankedProxiesByService: const {
        'claude': ['US-1'],
      },
    );
    expect((config['proxy-groups'] as List).single['proxies'], [
      'US-1',
      'REJECT',
    ]);
  });

  test('empty strict pool overwrites an unsafe persisted selection', () {
    final selected = {smartGroupName(service): 'TW-1', 'Proxy': 'TW-1'};
    final result = sanitizeSelectedMap(
      [service],
      const {'claude': []},
      selected,
    );
    expect(result[smartGroupName(service)], 'REJECT');
    expect(result['Proxy'], 'TW-1');
    expect(selected[smartGroupName(service)], 'TW-1');
  });

  test('strict startup explicitly selects reject without a saved choice', () {
    expect(sanitizeSelectedMap([service], const {'claude': []}, const {}), {
      smartGroupName(service): 'REJECT',
    });
  });

  test('runtime closes a strict pool with no qualified members', () {
    final decision = lockReselectDecision(
      const SmartAnchorInput(services: [service]),
      service,
      const ['unknown', 'REJECT'],
      'unknown',
    );
    expect(decision.target, 'REJECT');
    expect(decision.ranked, isEmpty);
  });

  test('an already rejected strict pool does not resubmit the switch', () {
    final decision = lockReselectDecision(
      const SmartAnchorInput(services: [service]),
      service,
      const ['REJECT'],
      'REJECT',
    );
    expect(decision.target, isNull);
    expect(decision.ranked, isEmpty);
  });
}
