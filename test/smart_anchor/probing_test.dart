import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/services/probing.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache fakeNode() {
  return NodeMetadataCache(
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
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  test('core service statuses map to access reasons', () {
    expect(
      accessReasonFromStatus(ServiceProbeStatus.available),
      ServiceAccessReason.accessible,
    );
    for (final status in [
      ServiceProbeStatus.unsupportedRegion,
      ServiceProbeStatus.restricted,
      ServiceProbeStatus.disallowedIsp,
      ServiceProbeStatus.blocked,
    ]) {
      expect(accessReasonFromStatus(status), ServiceAccessReason.regionBlocked);
    }
    for (final status in [
      ServiceProbeStatus.timeout,
      ServiceProbeStatus.failed,
    ]) {
      expect(accessReasonFromStatus(status), ServiceAccessReason.networkFailed);
    }
    expect(
      accessReasonFromStatus(ServiceProbeStatus.unavailable),
      ServiceAccessReason.unknown,
    );
  });

  test('service ids map to core targets, unknown services map to null', () {
    expect(serviceTargetForServiceId('openai'), ServiceTarget.chatgpt);
    expect(serviceTargetForServiceId('claude'), ServiceTarget.claude);
    expect(serviceTargetForServiceId('cloudflare'), isNull);
    expect(serviceTargetForServiceId('x'), isNull);
  });

  test('probe targets put the current node first and cap at top-k', () {
    final targets = selectProbeTargets(
      ranked: ['A', 'B', 'C', 'D'],
      current: 'C',
      topK: 2,
    );
    expect(targets, ['C', 'A', 'B']);
  });

  test('full probe targets keep nodes faster than the median delay', () {
    final targets = selectFullProbeTargets(
      proxyNames: ['A', 'B', 'C', 'D'],
      current: 'C',
      delays: {'A': 100, 'B': 200, 'C': 300, 'D': 400},
    );
    expect(targets, ['C', 'A', 'B']);
  });

  test('full probe targets ignore outliers the mean would include', () {
    final targets = selectFullProbeTargets(
      proxyNames: ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'],
      current: '',
      delays: {
        'A': 50,
        'B': 60,
        'C': 70,
        'D': 80,
        'E': 90,
        'F': 100,
        'G': 200,
        'H': 300,
        'I': 400,
        'J': 5000,
      },
    );
    expect(targets, ['A', 'B', 'C', 'D', 'E']);
  });

  test('full probe targets use the middle value for odd counts', () {
    final targets = selectFullProbeTargets(
      proxyNames: ['A', 'B', 'C'],
      current: '',
      delays: {'A': 100, 'B': 200, 'C': 300},
    );
    expect(targets, ['A', 'B']);
  });

  test('full probe targets ignore unmeasured and timed out nodes', () {
    final targets = selectFullProbeTargets(
      proxyNames: ['A', 'B', 'C'],
      current: '',
      delays: {'A': 100, 'B': -1},
    );
    expect(targets, ['A']);
  });

  test('full probe targets are empty without measured delays', () {
    expect(
      selectFullProbeTargets(proxyNames: ['A'], current: 'A', delays: {}),
      isEmpty,
    );
  });

  test('probeNode combines egress, geo and service checks', () async {
    final prober = SmartAnchorProber(
      egressLookup: (_) async => const IpInfo(ip: '1.2.3.4', countryCode: 'US'),
      serviceCheckLookup: (_, targets) async {
        return {
          for (final target in targets)
            target: const ServiceCheck(ServiceProbeStatus.available),
        };
      },
      geoLookup:
          ({required ip, required proxyName, required entryServer}) async =>
              fakeNode(),
    );
    final outcome = await prober.probeNode(
      proxyName: 'US-01',
      entryServer: 'entry.example',
      serviceIds: ['claude', 'cloudflare'],
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(outcome.metadata?.egressIp, '1.2.3.4');
    expect(
      outcome.accessByService['claude']?.reason,
      ServiceAccessReason.accessible,
    );
    expect(outcome.accessByService.containsKey('cloudflare'), isFalse);
  });

  test('probeNode without egress still reports service checks', () async {
    final prober = SmartAnchorProber(
      egressLookup: (_) async => null,
      serviceCheckLookup: (_, _) async {
        return {
          ServiceTarget.claude: const ServiceCheck(ServiceProbeStatus.timeout),
        };
      },
      geoLookup:
          ({required ip, required proxyName, required entryServer}) async =>
              null,
    );
    final outcome = await prober.probeNode(
      proxyName: 'US-01',
      entryServer: '',
      serviceIds: ['claude'],
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(outcome.metadata, isNull);
    expect(
      outcome.accessByService['claude']?.reason,
      ServiceAccessReason.networkFailed,
    );
  });
}
