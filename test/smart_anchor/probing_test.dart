import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
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

NodeMetadataCache metadataFor(String name, {required bool fresh}) {
  return NodeMetadataCache(
    proxyName: name,
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
    updatedAt: fresh ? DateTime.now().millisecondsSinceEpoch : 0,
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
    expect(
      accessReasonFromStatus(ServiceProbeStatus.cancelled),
      ServiceAccessReason.unknown,
    );
  });

  test('service ids map to core targets, unknown services map to null', () {
    expect(serviceTargetForServiceId('openai'), ServiceTarget.chatgpt);
    expect(serviceTargetForServiceId('claude'), ServiceTarget.claude);
    expect(serviceTargetForServiceId('cloudflare'), isNull);
    expect(serviceTargetForServiceId('x'), isNull);
  });

  test('disney maps to the disneyPlus target the core already offers', () {
    expect(defaultServiceToggles, hasLength(17));
    expect(
      defaultServiceToggles.map((service) => service.serviceId),
      contains('disney'),
    );
    expect(serviceTargetForServiceId('disney'), ServiceTarget.disneyPlus);
  });

  group('probe queue', () {
    test('puts current nodes first, even when their metadata is fresh', () {
      final targets = selectProbeQueue(
        proxyNames: ['A', 'B', 'C'],
        currentProxyNames: ['C'],
        metadataByProxy: {'C': metadataFor('C', fresh: true)},
        rankByProxy: const {},
      );
      expect(targets, ['C', 'A', 'B']);
    });

    test('skips fresh nodes outside the current set', () {
      final targets = selectProbeQueue(
        proxyNames: ['A', 'B', 'C'],
        currentProxyNames: const [],
        metadataByProxy: {
          'A': metadataFor('A', fresh: true),
          'B': metadataFor('B', fresh: false),
        },
        rankByProxy: const {},
      );
      expect(targets, ['B', 'C']);
    });

    test('orders stale nodes by best rank, then by list order', () {
      final targets = selectProbeQueue(
        proxyNames: ['A', 'B', 'C', 'D'],
        currentProxyNames: const [],
        metadataByProxy: const {},
        rankByProxy: {'C': 0, 'A': 2},
      );
      expect(targets, ['C', 'A', 'B', 'D']);
    });

    test('budget trims the tail but never a current node', () {
      final targets = selectProbeQueue(
        proxyNames: ['A', 'B', 'C', 'D'],
        currentProxyNames: ['D'],
        metadataByProxy: const {},
        rankByProxy: const {},
        budget: 2,
      );
      expect(targets, ['D', 'A']);
      final currentsOnly = selectProbeQueue(
        proxyNames: ['A', 'B'],
        currentProxyNames: ['A', 'B'],
        metadataByProxy: const {},
        rankByProxy: const {},
        budget: 1,
      );
      expect(currentsOnly, ['A', 'B']);
    });

    test('repeated rounds walk the queue to full coverage', () {
      const names = ['A', 'B', 'C', 'D', 'E', 'F'];
      final metadata = <String, NodeMetadataCache>{};
      const ranks = {'E': 0, 'C': 1, 'A': 2};
      final covered = <String>[];
      for (var round = 0; round < 3; round++) {
        final targets = selectProbeQueue(
          proxyNames: names,
          currentProxyNames: const [],
          metadataByProxy: metadata,
          rankByProxy: ranks,
          budget: 2,
        );
        covered.addAll(targets);
        for (final name in targets) {
          metadata[name] = metadataFor(name, fresh: true);
        }
      }
      expect(covered, ['E', 'C', 'A', 'B', 'D', 'F']);
      expect(
        selectProbeQueue(
          proxyNames: names,
          currentProxyNames: const [],
          metadataByProxy: metadata,
          rankByProxy: ranks,
          budget: 2,
        ),
        isEmpty,
      );
    });
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

  test('probeNode records nothing for a cancelled service check', () async {
    final prober = SmartAnchorProber(
      egressLookup: (_) async => const IpInfo(ip: '1.2.3.4', countryCode: 'US'),
      serviceCheckLookup: (_, _) async {
        return {
          ServiceTarget.claude: const ServiceCheck(
            ServiceProbeStatus.cancelled,
          ),
          ServiceTarget.gemini: const ServiceCheck(
            ServiceProbeStatus.available,
          ),
        };
      },
      geoLookup:
          ({required ip, required proxyName, required entryServer}) async =>
              fakeNode(),
    );
    final outcome = await prober.probeNode(
      proxyName: 'US-01',
      entryServer: '',
      serviceIds: ['claude', 'gemini'],
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(outcome.accessByService.containsKey('claude'), isFalse);
    expect(
      outcome.accessByService['gemini']?.reason,
      ServiceAccessReason.accessible,
    );
  });
}
