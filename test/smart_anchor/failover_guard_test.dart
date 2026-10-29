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

FailoverTarget? note(
  FailoverGuard guard, {
  String currentName = 'A',
  ServiceAccessReason? reason = ServiceAccessReason.networkFailed,
  List<String> preferred = const [],
  List<String> fallback = const [],
  Map<String, ServiceAccessResult> accessByProxy = const {},
  int nowMs = 1000,
}) {
  return guard.noteResult(
    serviceId: 'youtube',
    currentName: currentName,
    reason: reason,
    preferred: preferred,
    fallback: fallback,
    accessByProxy: accessByProxy,
    nowMs: nowMs,
  );
}

void main() {
  test('two failures switch once, and a recovered node never pulls back', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B'];
    expect(note(guard, preferred: preferred), isNull);
    final target = note(guard, preferred: preferred, nowMs: 2000);
    expect(target?.name, 'B');
    expect(target?.isFallback, isFalse);
    expect(
      note(
        guard,
        currentName: 'B',
        reason: ServiceAccessReason.accessible,
        preferred: preferred,
        nowMs: 3000,
      ),
      isNull,
    );
  });

  test('ranking changes alone never switch the current node', () {
    final guard = FailoverGuard();
    expect(
      note(
        guard,
        reason: ServiceAccessReason.accessible,
        preferred: ['B', 'A'],
      ),
      isNull,
    );
  });

  test('a manual switch resets the failure count', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B'];
    note(guard, preferred: preferred);
    expect(note(guard, currentName: 'B', preferred: preferred), isNull);
  });

  test('never switches to a region-blocked node', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B'];
    final access = {'B': resultFor('B', ServiceAccessReason.regionBlocked)};
    note(guard, preferred: preferred, accessByProxy: access);
    expect(
      note(guard, preferred: preferred, accessByProxy: access, nowMs: 2000),
      isNull,
    );
  });

  test('a borrowed region block does not bar a candidate', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B'];
    final access = {
      'B': ServiceAccessResult(
        serviceId: 'youtube',
        proxyName: 'B',
        egressIp: '1.2.3.4',
        reason: ServiceAccessReason.regionBlocked,
        checkedAt: DateTime.now().millisecondsSinceEpoch,
        borrowedFrom: 'google',
      ),
    };
    note(guard, preferred: preferred, accessByProxy: access);
    final target = note(
      guard,
      preferred: preferred,
      accessByProxy: access,
      nowMs: 2000,
    );
    expect(target?.name, 'B');
  });

  test('never switches to a built-in target', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'REJECT', 'DIRECT', 'REJECT-DROP', 'B'];
    note(guard, preferred: preferred);
    final target = note(guard, preferred: preferred, nowMs: 2000);
    expect(target?.name, 'B');
    expect(target?.isFallback, isFalse);
  });

  test('no more than three switches in ten minutes, then frozen', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B', 'C', 'D', 'E'];
    var current = 'A';
    var switches = 0;
    for (var cycle = 0; cycle < 8; cycle++) {
      FailoverTarget? target;
      for (var attempt = 0; attempt < 2; attempt++) {
        target = note(
          guard,
          currentName: current,
          preferred: preferred,
          nowMs: 1000 + cycle * 1000,
        );
      }
      if (target != null) {
        switches += 1;
        current = target.name;
      }
    }
    expect(switches, 3);
  });

  test('a service outage never counts as a node failure', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B'];
    note(guard, reason: ServiceAccessReason.serviceDown, preferred: preferred);
    expect(
      note(
        guard,
        reason: ServiceAccessReason.serviceDown,
        preferred: preferred,
        nowMs: 2000,
      ),
      isNull,
    );
  });

  test('preferred candidates win over fallback ones', () {
    final guard = FailoverGuard();
    note(guard, preferred: ['K1'], fallback: ['U1']);
    final target = note(
      guard,
      preferred: ['K1'],
      fallback: ['U1'],
      nowMs: 2000,
    );
    expect(target?.name, 'K1');
    expect(target?.isFallback, isFalse);
  });

  test('fallback is used and flagged when no preferred candidate remains', () {
    final guard = FailoverGuard();
    const fallback = ['U1', 'U2'];
    note(guard, fallback: fallback);
    final target = note(guard, fallback: fallback, nowMs: 2000);
    expect(target?.name, 'U1');
    expect(target?.isFallback, isTrue);
  });

  test('fallback scan skips built-in and region-blocked names too', () {
    final guard = FailoverGuard();
    const fallback = ['DIRECT', 'U-blocked', 'U2'];
    final access = {
      'U-blocked': resultFor('U-blocked', ServiceAccessReason.regionBlocked),
    };
    note(guard, fallback: fallback, accessByProxy: access);
    final target = note(
      guard,
      fallback: fallback,
      accessByProxy: access,
      nowMs: 2000,
    );
    expect(target?.name, 'U2');
    expect(target?.isFallback, isTrue);
  });

  test('a blocked preferred layer falls through to the fallback layer', () {
    final guard = FailoverGuard();
    const preferred = ['K-blocked'];
    const fallback = ['U1'];
    final access = {
      'K-blocked': resultFor('K-blocked', ServiceAccessReason.regionBlocked),
    };
    note(
      guard,
      preferred: preferred,
      fallback: fallback,
      accessByProxy: access,
    );
    final target = note(
      guard,
      preferred: preferred,
      fallback: fallback,
      accessByProxy: access,
      nowMs: 2000,
    );
    expect(target?.name, 'U1');
    expect(target?.isFallback, isTrue);
  });

  test('lastCountedFailures keeps the count that led to a decision', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B'];
    expect(note(guard, preferred: preferred), isNull);
    expect(guard.lastCountedFailures, 1);
    expect(note(guard, preferred: preferred, nowMs: 2000)?.name, 'B');
    expect(guard.lastCountedFailures, 2);
  });

  test('freeze state is readable and lifts with the window', () {
    final guard = FailoverGuard();
    const preferred = ['A', 'B', 'C', 'D', 'E'];
    var current = 'A';
    for (var cycle = 0; cycle < 3; cycle++) {
      FailoverTarget? target;
      for (var attempt = 0; attempt < 2; attempt++) {
        target = note(
          guard,
          currentName: current,
          preferred: preferred,
          nowMs: 1000 + cycle * 1000,
        );
      }
      current = target!.name;
    }
    // Switches landed at 1000, 2000, 3000 per the helper's second call.
    expect(guard.isFrozen('youtube', 3000), isTrue);
    expect(guard.frozenUntilMs('youtube', 3000), 1000 + 10 * 60 * 1000);
    expect(guard.isFrozen('youtube', 1000 + 10 * 60 * 1000 + 1), isFalse);
    expect(guard.frozenUntilMs('youtube', 1000 + 10 * 60 * 1000 + 1), isNull);
    expect(guard.isFrozen('claude', 3000), isFalse);
  });

  test('failures count once per probe across both layers', () {
    final guard = FailoverGuard();
    const preferred = ['K1'];
    const fallback = ['U1'];
    expect(note(guard, preferred: preferred, fallback: fallback), isNull);
    final target = note(
      guard,
      preferred: preferred,
      fallback: fallback,
      nowMs: 2000,
    );
    expect(target?.name, 'K1');
    expect(
      note(guard, currentName: 'K1', preferred: preferred, fallback: fallback),
      isNull,
    );
  });
}
