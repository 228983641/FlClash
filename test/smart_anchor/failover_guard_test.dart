import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:fl_clash/smart_anchor/services/sticky_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

ServiceAccessResult resultFor(String name, ServiceAccessReason reason) {
  return ServiceAccessResult(
    serviceId: 'youtube',
    proxyName: name,
    egressIp: '1.2.3.4',
    reason: reason,
    checkedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  test('two failures switch once, and a recovered node never pulls back', () {
    final guard = FailoverGuard();
    const ranked = ['A', 'B'];
    final access = <String, ServiceAccessResult>{};
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'A',
        reason: ServiceAccessReason.networkFailed,
        ranked: ranked,
        accessByProxy: access,
        nowMs: 1000,
      ),
      isNull,
    );
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'A',
        reason: ServiceAccessReason.networkFailed,
        ranked: ranked,
        accessByProxy: access,
        nowMs: 2000,
      ),
      'B',
    );
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'B',
        reason: ServiceAccessReason.accessible,
        ranked: ranked,
        accessByProxy: access,
        nowMs: 3000,
      ),
      isNull,
    );
  });

  test('ranking changes alone never switch the current node', () {
    final guard = FailoverGuard();
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'A',
        reason: ServiceAccessReason.accessible,
        ranked: ['B', 'A'],
        accessByProxy: {},
        nowMs: 1000,
      ),
      isNull,
    );
  });

  test('a manual switch resets the failure count', () {
    final guard = FailoverGuard();
    const ranked = ['A', 'B'];
    guard.noteResult(
      serviceId: 'youtube',
      currentName: 'A',
      reason: ServiceAccessReason.networkFailed,
      ranked: ranked,
      accessByProxy: {},
      nowMs: 1000,
    );
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'B',
        reason: ServiceAccessReason.networkFailed,
        ranked: ranked,
        accessByProxy: {},
        nowMs: 2000,
      ),
      isNull,
    );
  });

  test('never switches to a region-blocked node', () {
    final guard = FailoverGuard();
    const ranked = ['A', 'B'];
    final access = {'B': resultFor('B', ServiceAccessReason.regionBlocked)};
    guard.noteResult(
      serviceId: 'youtube',
      currentName: 'A',
      reason: ServiceAccessReason.networkFailed,
      ranked: ranked,
      accessByProxy: access,
      nowMs: 1000,
    );
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'A',
        reason: ServiceAccessReason.networkFailed,
        ranked: ranked,
        accessByProxy: access,
        nowMs: 2000,
      ),
      isNull,
    );
  });

  test('no more than three switches in ten minutes, then frozen', () {
    final guard = FailoverGuard();
    const ranked = ['A', 'B', 'C', 'D', 'E'];
    var current = 'A';
    var switches = 0;
    for (var cycle = 0; cycle < 8; cycle++) {
      var next;
      for (var attempt = 0; attempt < 2; attempt++) {
        next = guard.noteResult(
          serviceId: 'youtube',
          currentName: current,
          reason: ServiceAccessReason.networkFailed,
          ranked: ranked,
          accessByProxy: {},
          nowMs: 1000 + cycle * 1000,
        );
      }
      if (next != null) {
        switches += 1;
        current = next;
      }
    }
    expect(switches, 3);
  });

  test('a service outage never counts as a node failure', () {
    final guard = FailoverGuard();
    const ranked = ['A', 'B'];
    guard.noteResult(
      serviceId: 'youtube',
      currentName: 'A',
      reason: ServiceAccessReason.serviceDown,
      ranked: ranked,
      accessByProxy: {},
      nowMs: 1000,
    );
    expect(
      guard.noteResult(
        serviceId: 'youtube',
        currentName: 'A',
        reason: ServiceAccessReason.serviceDown,
        ranked: ranked,
        accessByProxy: {},
        nowMs: 2000,
      ),
      isNull,
    );
  });
}
