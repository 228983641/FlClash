import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/candidate_decision.dart';
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

NodeMetadataCache metaFor(
  String name, {
  String ip = '10.0.0.9',
  String asn = 'AS200',
  double purity = 80,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '',
    egressIp: ip,
    countryCode: 'US',
    latitude: 37.0,
    longitude: -122.0,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: 0,
  );
}

CandidateDecision decisionFor({
  required List<String> names,
  required Map<String, NodeMetadataCache> metadata,
  Map<String, ServiceAccessResult> access = const {},
  String? current,
  bool outage = false,
}) {
  return decideCandidates(
    CandidateDecisionInput(
      serviceId: 'youtube',
      restrictionMode: ServiceRestrictionMode.relaxed,
      lockedCountries: const ['US'],
      candidateNames: names,
      metadataByProxy: metadata,
      accessByProxy: access,
      currentName: current,
      trigger: CandidateDecisionTrigger.failure,
      serviceOutageSuspected: outage,
    ),
  );
}

FailoverTarget? noteDecision(
  FailoverGuard guard, {
  required CandidateDecision decision,
  String currentName = 'A',
  ServiceAccessReason? reason = ServiceAccessReason.networkFailed,
  int nowMs = 1000,
}) {
  return guard.noteDecisionResult(
    serviceId: 'youtube',
    currentName: currentName,
    reason: reason,
    decision: decision,
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

  test('split blocking verdicts count toward failover like regionBlocked', () {
    for (final reason in [
      ServiceAccessReason.ispBlocked,
      ServiceAccessReason.restricted,
      ServiceAccessReason.blocked,
    ]) {
      final guard = FailoverGuard();
      const preferred = ['A', 'B'];
      expect(note(guard, reason: reason, preferred: preferred), isNull);
      final target = note(
        guard,
        reason: reason,
        preferred: preferred,
        nowMs: 2000,
      );
      expect(target?.name, 'B', reason: '$reason');
    }
  });

  test('never switches to a node carrying a split blocking verdict', () {
    for (final reason in [
      ServiceAccessReason.ispBlocked,
      ServiceAccessReason.restricted,
      ServiceAccessReason.blocked,
    ]) {
      final guard = FailoverGuard();
      const preferred = ['A', 'B'];
      final access = {'B': resultFor('B', reason)};
      note(guard, preferred: preferred, accessByProxy: access);
      expect(
        note(guard, preferred: preferred, accessByProxy: access, nowMs: 2000),
        isNull,
        reason: '$reason',
      );
    }
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
    // Cycles are spaced past the post-switch cooldown (2 minutes) so the
    // limit being exercised here is the freeze, not the cooldown.
    for (var cycle = 0; cycle < 4; cycle++) {
      FailoverTarget? target;
      for (var attempt = 0; attempt < 2; attempt++) {
        target = note(
          guard,
          currentName: current,
          preferred: preferred,
          nowMs: 1000 + cycle * 121000 + attempt * 1000,
        );
      }
      if (target != null) {
        switches += 1;
        current = target.name;
      }
    }
    expect(switches, 3);
    expect(guard.isFrozen('youtube', 1000 + 3 * 121000 + 1000), isTrue);
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
          nowMs: 1000 + cycle * 121000 + attempt * 1000,
        );
      }
      current = target!.name;
    }
    // Switches landed at 2000, 123000, 244000 (each cycle's second call,
    // spaced past the post-switch cooldown).
    expect(guard.isFrozen('youtube', 244000), isTrue);
    expect(guard.frozenUntilMs('youtube', 244000), 2000 + 10 * 60 * 1000);
    expect(guard.isFrozen('youtube', 2000 + 10 * 60 * 1000 + 1), isFalse);
    expect(guard.frozenUntilMs('youtube', 2000 + 10 * 60 * 1000 + 1), isNull);
    expect(guard.isFrozen('claude', 244000), isFalse);
  });

  group('decision-driven targets', () {
    test('the target is the decision target, tier before total score', () {
      final guard = FailoverGuard();
      final decision = decisionFor(
        names: ['A', 'B', 'C'],
        metadata: {
          'A': metaFor('A', ip: '10.0.0.5', asn: 'AS100', purity: 90),
          'B': metaFor('B', ip: '10.0.0.9', asn: 'AS200', purity: 55),
          'C': metaFor('C', ip: '10.9.0.1', asn: 'AS300', purity: 100),
        },
        access: {'A': resultFor('A', ServiceAccessReason.regionBlocked)},
        current: 'A',
      );
      expect(decision.target, 'B');
      expect(noteDecision(guard, decision: decision), isNull);
      final target = noteDecision(guard, decision: decision, nowMs: 2000);
      expect(target?.name, decision.target);
      expect(target?.name, 'B');
      expect(target?.tier, RouteTier.l1);
      expect(target?.isFallback, isFalse);
    });

    test('an unknown-country target is flagged as the L7 fallback', () {
      final guard = FailoverGuard();
      final decision = decisionFor(
        names: ['A', 'mystery'],
        metadata: {'A': metaFor('A', ip: '10.0.0.5', asn: 'AS100')},
        access: {'A': resultFor('A', ServiceAccessReason.regionBlocked)},
        current: 'A',
      );
      expect(decision.target, 'mystery');
      expect(noteDecision(guard, decision: decision), isNull);
      final target = noteDecision(guard, decision: decision, nowMs: 2000);
      expect(target?.name, 'mystery');
      expect(target?.isFallback, isTrue);
      expect(target?.tier, RouteTier.l7);
    });

    test('a suspected service outage never counts as a node failure', () {
      final guard = FailoverGuard();
      final metadata = {
        'A': metaFor('A', ip: '10.0.0.5', asn: 'AS100'),
        'B': metaFor('B'),
      };
      final outageDecision = decisionFor(
        names: ['A', 'B'],
        metadata: metadata,
        current: 'A',
        outage: true,
      );
      expect(
        noteDecision(guard, decision: outageDecision, nowMs: 1000),
        isNull,
      );
      expect(
        noteDecision(guard, decision: outageDecision, nowMs: 2000),
        isNull,
      );
      expect(guard.lastCountedFailures, 0);
      final clearDecision = decisionFor(
        names: ['A', 'B'],
        metadata: metadata,
        current: 'A',
      );
      expect(noteDecision(guard, decision: clearDecision, nowMs: 3000), isNull);
      expect(
        noteDecision(guard, decision: clearDecision, nowMs: 4000)?.name,
        'B',
      );
    });

    test('cooldown blocks consecutive switches and any switch-back', () {
      final guard = FailoverGuard();
      final metadata = {
        'A': metaFor('A', ip: '10.0.0.5', asn: 'AS100', purity: 90),
        'B': metaFor('B', ip: '10.0.0.9', asn: 'AS200', purity: 80),
        'C': metaFor('C', ip: '10.9.0.1', asn: 'AS300', purity: 70),
      };
      final fromA = decisionFor(
        names: ['A', 'B', 'C'],
        metadata: metadata,
        access: {'A': resultFor('A', ServiceAccessReason.regionBlocked)},
        current: 'A',
      );
      expect(noteDecision(guard, decision: fromA, nowMs: 9000), isNull);
      final first = noteDecision(guard, decision: fromA, nowMs: 10000);
      expect(first?.name, 'B');
      expect(guard.isCoolingDown('youtube', 10000), isTrue);
      expect(
        guard.cooldownUntilMs('youtube'),
        10000 + FailoverGuard.switchCooldownMs,
      );
      // B now fails with A (recovered) as the decision's best alternative:
      // inside the cooldown the guard neither switches on nor back.
      final fromB = decisionFor(
        names: ['B', 'A', 'C'],
        metadata: metadata,
        access: {'B': resultFor('B', ServiceAccessReason.regionBlocked)},
        current: 'B',
      );
      expect(
        noteDecision(guard, decision: fromB, currentName: 'B', nowMs: 40000),
        isNull,
      );
      expect(
        noteDecision(guard, decision: fromB, currentName: 'B', nowMs: 70000),
        isNull,
      );
      expect(guard.switchesInWindow('youtube', 70000), 1);
    });

    test('after the cooldown, reconfirmed failure may re-choose the '
        'recovered node, but recovery alone never does', () {
      final guard = FailoverGuard();
      final metadata = {
        'A': metaFor('A', ip: '10.0.0.5', asn: 'AS100', purity: 90),
        'B': metaFor('B', ip: '10.0.0.9', asn: 'AS200', purity: 80),
      };
      final fromA = decisionFor(
        names: ['A', 'B'],
        metadata: metadata,
        access: {'A': resultFor('A', ServiceAccessReason.regionBlocked)},
        current: 'A',
      );
      expect(noteDecision(guard, decision: fromA, nowMs: 9000), isNull);
      expect(noteDecision(guard, decision: fromA, nowMs: 10000)?.name, 'B');
      const afterCooldown = 10000 + FailoverGuard.switchCooldownMs + 10000;
      // A is healthy again and B is healthy too: no failure, no move,
      // however much later the check runs.
      final bothHealthy = decisionFor(
        names: ['B', 'A'],
        metadata: metadata,
        current: 'B',
      );
      expect(
        noteDecision(
          guard,
          decision: bothHealthy,
          currentName: 'B',
          reason: ServiceAccessReason.accessible,
          nowMs: afterCooldown,
        ),
        isNull,
      );
      // B fails twice, independently confirmed past the cooldown: the
      // guard may now fail over, and the decision's target is A.
      final fromB = decisionFor(
        names: ['B', 'A'],
        metadata: metadata,
        access: {'B': resultFor('B', ServiceAccessReason.regionBlocked)},
        current: 'B',
      );
      expect(
        noteDecision(
          guard,
          decision: fromB,
          currentName: 'B',
          nowMs: afterCooldown + 1000,
        ),
        isNull,
      );
      final back = noteDecision(
        guard,
        decision: fromB,
        currentName: 'B',
        nowMs: afterCooldown + 2000,
      );
      expect(back?.name, 'A');
    });
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
