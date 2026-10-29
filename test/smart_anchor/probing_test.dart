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
          ({
            required ip,
            required proxyName,
            required entryServer,
            required wafPass,
          }) async => fakeNode(),
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
    // Cloudflare has no target of its own; it borrows Google's verdict.
    expect(
      outcome.accessByService['cloudflare']?.reason,
      ServiceAccessReason.accessible,
    );
    expect(outcome.accessByService['cloudflare']?.borrowedFrom, 'google');
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
          ({
            required ip,
            required proxyName,
            required entryServer,
            required wafPass,
          }) async => null,
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
          ({
            required ip,
            required proxyName,
            required entryServer,
            required wafPass,
          }) async => fakeNode(),
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

  group('borrowed probing', () {
    test(
      'every checker-less preset service has a donor, natives have none',
      () {
        const borrowers = {
          'cloudflare',
          'x',
          'copilot',
          'meta-ai',
          'grok',
          'perplexity',
          'mistral',
          'poe',
          'appletv',
          'muse',
        };
        for (final service in defaultServiceToggles) {
          final id = service.serviceId;
          if (serviceTargetForServiceId(id) != null) {
            expect(fallbackProbeServiceId(id), isNull, reason: id);
          } else {
            expect(borrowers, contains(id), reason: id);
            expect(fallbackProbeServiceId(id), isNotNull, reason: id);
          }
        }
        expect(fallbackProbeServiceId('disney'), isNull);
        expect(fallbackProbeServiceId('meta-ai'), 'claude');
        expect(fallbackProbeServiceId('grok'), 'openai');
        expect(fallbackProbeServiceId('x'), 'google');
        expect(fallbackProbeServiceId('cloudflare'), 'google');
        expect(fallbackProbeServiceId('appletv'), 'netflix');
      },
    );

    test(
      'one donor probe fans out to its borrowers, stamped as borrowed',
      () async {
        final requested = <ServiceTarget>[];
        final prober = SmartAnchorProber(
          egressLookup: (_) async =>
              const IpInfo(ip: '1.2.3.4', countryCode: 'US'),
          serviceCheckLookup: (_, targets) async {
            requested.addAll(targets);
            return {
              for (final target in targets)
                target: const ServiceCheck(ServiceProbeStatus.available),
            };
          },
          geoLookup:
              ({
                required ip,
                required proxyName,
                required entryServer,
                required wafPass,
              }) async => fakeNode(),
        );
        final outcome = await prober.probeNode(
          proxyName: 'US-01',
          entryServer: '',
          serviceIds: ['claude', 'grok', 'meta-ai', 'x', 'appletv'],
          nowMs: DateTime.now().millisecondsSinceEpoch,
        );
        expect(requested.toSet(), {
          ServiceTarget.claude,
          ServiceTarget.chatgpt,
          ServiceTarget.google,
          ServiceTarget.netflix,
        });
        expect(outcome.accessByService['claude']?.borrowedFrom, isNull);
        expect(outcome.accessByService['grok']?.borrowedFrom, 'openai');
        expect(outcome.accessByService['meta-ai']?.borrowedFrom, 'claude');
        expect(outcome.accessByService['x']?.borrowedFrom, 'google');
        expect(outcome.accessByService['appletv']?.borrowedFrom, 'netflix');
        for (final id in ['grok', 'meta-ai', 'x', 'appletv']) {
          expect(
            outcome.accessByService[id]?.reason,
            ServiceAccessReason.accessible,
            reason: id,
          );
        }
      },
    );

    test(
      'borrowing works while the donor service itself is disabled',
      () async {
        final prober = SmartAnchorProber(
          egressLookup: (_) async => null,
          serviceCheckLookup: (_, targets) async {
            return {
              for (final target in targets)
                target: const ServiceCheck(ServiceProbeStatus.blocked),
            };
          },
          geoLookup:
              ({
                required ip,
                required proxyName,
                required entryServer,
                required wafPass,
              }) async => null,
        );
        final outcome = await prober.probeNode(
          proxyName: 'US-01',
          entryServer: '',
          serviceIds: ['grok'],
          nowMs: DateTime.now().millisecondsSinceEpoch,
        );
        expect(outcome.accessByService.containsKey('openai'), isFalse);
        expect(
          outcome.accessByService['grok']?.reason,
          ServiceAccessReason.regionBlocked,
        );
        expect(outcome.accessByService['grok']?.borrowedFrom, 'openai');
      },
    );

    test('a cancelled donor check records nothing for its borrowers', () async {
      final prober = SmartAnchorProber(
        egressLookup: (_) async => null,
        serviceCheckLookup: (_, _) async {
          return {
            ServiceTarget.chatgpt: const ServiceCheck(
              ServiceProbeStatus.cancelled,
            ),
          };
        },
        geoLookup:
            ({
              required ip,
              required proxyName,
              required entryServer,
              required wafPass,
            }) async => null,
      );
      final outcome = await prober.probeNode(
        proxyName: 'US-01',
        entryServer: '',
        serviceIds: ['openai', 'grok'],
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(outcome.accessByService, isEmpty);
    });

    test(
      'the borrowed stamp survives a json round trip, old data has none',
      () {
        const borrowed = ServiceAccessResult(
          serviceId: 'grok',
          proxyName: 'US-01',
          egressIp: '1.2.3.4',
          reason: ServiceAccessReason.regionBlocked,
          checkedAt: 42,
          borrowedFrom: 'openai',
        );
        final restored = ServiceAccessResult.fromJson(borrowed.toJson());
        expect(restored.borrowedFrom, 'openai');
        final legacy = ServiceAccessResult.fromJson({
          'serviceId': 'grok',
          'proxyName': 'US-01',
          'egressIp': '1.2.3.4',
          'reason': 'accessible',
          'checkedAt': 42,
          'ttlHours': 24,
        });
        expect(legacy.borrowedFrom, isNull);
      },
    );
  });

  group('waf probe', () {
    test('only positive block evidence fails the node', () {
      expect(wafPassFromTraceProbe(null), isTrue);
      expect(
        wafPassFromTraceProbe(const ProbeResult(error: 'timeout')),
        isTrue,
      );
      expect(
        wafPassFromTraceProbe(
          const ProbeResult(statusCode: 200, body: 'ip=1.2.3.4\nloc=US\n'),
        ),
        isTrue,
      );
      expect(
        wafPassFromTraceProbe(const ProbeResult(statusCode: 403)),
        isFalse,
      );
      expect(
        wafPassFromTraceProbe(
          const ProbeResult(
            statusCode: 503,
            body: '<title>Just a moment...</title>',
          ),
        ),
        isFalse,
      );
      expect(wafPassFromTraceProbe(const ProbeResult(statusCode: 500)), isTrue);
    });

    test('the prober feeds the waf verdict into the geo lookup', () async {
      bool? seenWaf;
      final prober = SmartAnchorProber(
        egressLookup: (_) async =>
            const IpInfo(ip: '1.2.3.4', countryCode: 'US'),
        serviceCheckLookup: (_, _) async => const {},
        geoLookup:
            ({
              required ip,
              required proxyName,
              required entryServer,
              required wafPass,
            }) async {
              seenWaf = wafPass;
              return fakeNode();
            },
        wafLookup: (_) async => false,
      );
      await prober.probeNode(
        proxyName: 'US-01',
        entryServer: '',
        serviceIds: const [],
        nowMs: 0,
      );
      expect(seenWaf, isFalse);
    });

    test('without a waf lookup the geo lookup defaults to pass', () async {
      bool? seenWaf;
      final prober = SmartAnchorProber(
        egressLookup: (_) async =>
            const IpInfo(ip: '1.2.3.4', countryCode: 'US'),
        serviceCheckLookup: (_, _) async => const {},
        geoLookup:
            ({
              required ip,
              required proxyName,
              required entryServer,
              required wafPass,
            }) async {
              seenWaf = wafPass;
              return fakeNode();
            },
      );
      await prober.probeNode(
        proxyName: 'US-01',
        entryServer: '',
        serviceIds: const [],
        nowMs: 0,
      );
      expect(seenWaf, isTrue);
    });
  });
}
