import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/smart_anchor/services/probing.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:fl_clash/smart_anchor/services/sticky_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (status, kind, expected) in [
    ('unavailable', 'service', ServiceAccessReason.serviceDown),
    ('failed', 'unknown', ServiceAccessReason.unknown),
    ('failed', '', ServiceAccessReason.unknown),
    ('failed', 'network', ServiceAccessReason.networkFailed),
    ('timeout', 'unknown', ServiceAccessReason.unknown),
    ('timeout', 'network', ServiceAccessReason.networkFailed),
    ('available', 'service', ServiceAccessReason.accessible),
    ('unsupported-region', 'service', ServiceAccessReason.regionBlocked),
    ('failed', 'future-kind', ServiceAccessReason.unknown),
  ]) {
    test('real check envelope preserves $status/$kind evidence', () async {
      final prober = SmartAnchorProber(
        egressLookup: (_) async => null,
        geoLookup:
            ({
              required ip,
              required proxyName,
              required entryServer,
              required wafPass,
            }) async => null,
        serviceCheckLookup: (_, _) async => {
          ServiceTarget.claude: ServiceCheck.of(
            ServiceCheckItem.fromJson({
              'name': 'claude',
              'status': status,
              'failure-kind': kind,
              'checked-at': 1000,
            }),
          ),
        },
      );
      final result = await prober.probeNode(
        proxyName: 'A',
        entryServer: '',
        serviceIds: ['claude'],
        nowMs: 1000,
      );
      expect(result.accessByService['claude']?.reason, expected);
    });
  }

  final now = DateTime.now().millisecondsSinceEpoch;
  ServiceAccessResult peer({
    int age = 0,
    String? borrowedFrom,
    ServiceAccessReason reason = ServiceAccessReason.accessible,
  }) => ServiceAccessResult(
    serviceId: 'claude',
    proxyName: 'B',
    egressIp: '192.0.2.2',
    reason: reason,
    checkedAt: now - age,
    borrowedFrom: borrowedFrom,
  );

  FailoverTarget? twice(Map<String, ServiceAccessResult> peers) {
    final guard = FailoverGuard();
    FailoverTarget? answer;
    for (final at in [now - 1000, now]) {
      answer = guard.noteResult(
        serviceId: 'claude',
        currentName: 'A',
        reason: ServiceAccessReason.networkFailed,
        preferred: ['B'],
        fallback: ['C'],
        accessByProxy: peers,
        nowMs: now,
        probeAtMs: at,
      );
    }
    return answer;
  }

  test('local outage cannot move to an untested candidate', () {
    expect(twice({}), isNull);
  });
  test('a prior positive check cannot disprove a new local outage', () {
    expect(twice({'B': peer(age: 1)}), isNull);
  });
  test('borrowed success cannot justify a transport failover', () {
    expect(twice({'B': peer(borrowedFrom: 'openai')}), isNull);
  });
  test('shared service outage cannot move to an untested fallback', () {
    expect(twice({'B': peer(reason: ServiceAccessReason.serviceDown)}), isNull);
  });
  test('two distinct failures may move to a freshly working peer', () {
    expect(twice({'B': peer()})?.name, 'B');
  });
}
