import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/models/switch_event.dart';
import 'package:fl_clash/smart_anchor/services/config_injector.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

SwitchEvent eventAt(String to, int at) {
  return SwitchEvent(
    serviceId: 'youtube',
    fromProxy: 'A',
    toProxy: to,
    reason: 'networkFailed',
    switchedAt: at,
  );
}

NodeMetadataCache node(String name, String country) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '1.2.3.4',
    egressIp: '1.2.3.4',
    countryCode: country,
    latitude: 37.0,
    longitude: -122.0,
    asn: 'AS1234',
    ipType: 'residential',
    fraudScore: 0,
    purityScore: 90,
    wafPass: true,
    updatedAt: now,
  );
}

const service = ServiceToggleConfig(
  serviceId: 'youtube',
  displayName: 'YouTube',
  isEnabled: true,
  targetCountry: 'US',
  matchRules: [],
  dnsDomains: [],
);

void main() {
  test('append caps the history at ten events', () {
    var events = <SwitchEvent>[];
    for (var i = 0; i < 12; i++) {
      events = appendSwitchEvent(events, eventAt('N$i', i));
    }
    expect(events.length, 10);
    expect(events.first.toProxy, 'N2');
    expect(events.last.toProxy, 'N11');
  });

  test('three switches inside ten minutes count as frozen', () {
    const now = 1000000000;
    expect(
      isSwitchFrozen([
        eventAt('B', now - 9 * 60 * 1000),
        eventAt('C', now - 5 * 60 * 1000),
        eventAt('D', now),
      ], now),
      isTrue,
    );
    expect(
      isSwitchFrozen([
        eventAt('B', now - 11 * 60 * 1000),
        eventAt('C', now - 5 * 60 * 1000),
        eventAt('D', now),
      ], now),
      isFalse,
    );
    expect(isSwitchFrozen([eventAt('B', now)], now), isFalse);
  });

  test('a service with no ranked node reports no usable nodes', () {
    final input = SmartAnchorInput(
      services: [service],
      metadataByProxy: {'A': node('A', 'US')},
    );
    expect(serviceHasNoUsableNodes(input, service, ['A']), isFalse);
    const lockedJp = ServiceToggleConfig(
      serviceId: 'youtube',
      displayName: 'YouTube',
      isEnabled: true,
      targetCountry: 'JP',
      matchRules: [],
      dnsDomains: [],
    );
    expect(serviceHasNoUsableNodes(input, lockedJp, ['A']), isTrue);
    expect(serviceHasNoUsableNodes(input, lockedJp, []), isFalse);
    const disabled = ServiceToggleConfig(
      serviceId: 'youtube',
      displayName: 'YouTube',
      isEnabled: false,
      targetCountry: 'JP',
      matchRules: [],
      dnsDomains: [],
    );
    expect(serviceHasNoUsableNodes(input, disabled, ['A']), isFalse);
  });

  test('an empty ranked list injects DIRECT instead of an empty group', () {
    final result = SmartConfigInjector.injectSmartRouting(
      rawConfig: {},
      serviceConfigs: [service],
      rankedProxiesByService: {'youtube': []},
    );
    final groups = result['proxy-groups'] as List;
    expect(groups.length, 1);
    expect((groups.first as Map)['proxies'], ['DIRECT']);
  });
}
