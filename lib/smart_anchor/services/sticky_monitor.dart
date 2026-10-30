import 'candidate_decision.dart';
import 'service_access.dart';

class FailoverTarget {
  const FailoverTarget(this.name, {required this.isFallback, this.tier});

  final String name;
  final bool isFallback;

  /// The route tier the unified decision placed [name] in. Only the
  /// decision-driven path knows it; the legacy list path leaves it null.
  final RouteTier? tier;
}

class FailoverGuard {
  final Map<String, int> _failures = {};
  final Map<String, String?> _lastCurrent = {};
  final Map<String, List<int>> _switchTimes = {};
  final Map<String, int> _lastSwitchAtMs = {};
  int _lastCountedFailures = 0;

  /// The failure count the most recent counting call accumulated to,
  /// kept after a decision resets the running count so callers can log
  /// the count that led to it.
  int get lastCountedFailures => _lastCountedFailures;

  static const int failureThreshold = 2;
  static const int _freezeWindowMs = 10 * 60 * 1000;
  static const int _freezeSwitchLimit = 3;

  /// Minimum hold after a guard-driven switch: inside it the guard
  /// refuses every further switch for the service, so a flapping
  /// replacement cannot chain switches or bounce straight back to the
  /// node just left. Two minutes covers several 30-second monitor
  /// ticks, giving the new node a full probe and confirmation cycle.
  static const int switchCooldownMs = 2 * 60 * 1000;

  List<int> _recentSwitches(String serviceId, int nowMs) {
    return (_switchTimes[serviceId] ?? [])
        .where((time) => nowMs - time <= _freezeWindowMs)
        .toList();
  }

  int switchesInWindow(String serviceId, int nowMs) {
    return _recentSwitches(serviceId, nowMs).length;
  }

  /// Whether [noteResult] currently refuses switches for [serviceId]
  /// because it already switched at the limit inside the window.
  bool isFrozen(String serviceId, int nowMs) {
    return _recentSwitches(serviceId, nowMs).length >= _freezeSwitchLimit;
  }

  /// When the freeze lifts: the moment the switch that keeps the window
  /// at the limit ages out of it. Null while not frozen.
  int? frozenUntilMs(String serviceId, int nowMs) {
    final recent = _recentSwitches(serviceId, nowMs)..sort();
    if (recent.length < _freezeSwitchLimit) {
      return null;
    }
    return recent[recent.length - _freezeSwitchLimit] + _freezeWindowMs;
  }

  bool isCoolingDown(String serviceId, int nowMs) {
    final last = _lastSwitchAtMs[serviceId];
    return last != null && nowMs - last < switchCooldownMs;
  }

  /// When the current cooldown ends, whether or not it has yet. Null
  /// when the guard has never switched the service.
  int? cooldownUntilMs(String serviceId) {
    final last = _lastSwitchAtMs[serviceId];
    return last == null ? null : last + switchCooldownMs;
  }

  void _recordSwitch(String serviceId, int nowMs) {
    final recent = _recentSwitches(serviceId, nowMs);
    _switchTimes[serviceId] = [...recent, nowMs];
    _lastSwitchAtMs[serviceId] = nowMs;
  }

  /// The shared "when to switch" gate: counts one independent failure
  /// for [currentName] and answers whether this call may switch. A
  /// changed current resets the count (a manual move or an earlier
  /// switch restarts confirmation), a non-failure verdict resets it,
  /// and reaching the threshold consumes the count even when the
  /// freeze or the cooldown then refuses the switch.
  bool _failureConfirmed({
    required String serviceId,
    required String currentName,
    required ServiceAccessReason? reason,
    required int nowMs,
  }) {
    if (_lastCurrent[serviceId] != currentName) {
      _failures[serviceId] = 0;
      _lastCurrent[serviceId] = currentName;
    }
    if (reason == null ||
        reason == ServiceAccessReason.accessible ||
        reason == ServiceAccessReason.unknown ||
        reason == ServiceAccessReason.serviceDown) {
      _failures[serviceId] = 0;
      return false;
    }
    final count = (_failures[serviceId] ?? 0) + 1;
    _failures[serviceId] = count;
    _lastCountedFailures = count;
    if (count < failureThreshold) {
      return false;
    }
    _failures[serviceId] = 0;
    if (isFrozen(serviceId, nowMs) || isCoolingDown(serviceId, nowMs)) {
      return false;
    }
    return true;
  }

  static bool _isBuiltin(String name) {
    return name == 'DIRECT' || name == 'REJECT' || name == 'REJECT-DROP';
  }

  /// Decision-driven failover: the guard decides only *when* to switch;
  /// *where to* is the decision's own order — its target when the
  /// current node is out of it, otherwise the next ordered candidate
  /// after the current one. A suspected service outage is not the
  /// node's fault, so it clears the count instead of feeding it.
  FailoverTarget? noteDecisionResult({
    required String serviceId,
    required String currentName,
    required ServiceAccessReason? reason,
    required CandidateDecision decision,
    required int nowMs,
  }) {
    if (decision.hasServiceOutage) {
      _failures[serviceId] = 0;
      _lastCurrent[serviceId] = currentName;
      return null;
    }
    if (!_failureConfirmed(
      serviceId: serviceId,
      currentName: currentName,
      reason: reason,
      nowMs: nowMs,
    )) {
      return null;
    }
    for (final name in decision.ordered) {
      if (name == currentName || _isBuiltin(name)) {
        continue;
      }
      _recordSwitch(serviceId, nowMs);
      return FailoverTarget(
        name,
        isFallback: decision.fallback.contains(name),
        tier: decision.assessments[name]?.tier,
      );
    }
    return null;
  }

  /// Compatibility entry point for callers still holding two bare
  /// candidate lists: [preferred] maps to the decision's qualified
  /// segment and [fallback] to its L7 fallback segment, in order.
  /// New callers use [noteDecisionResult] so the target comes from
  /// the unified decision itself.
  FailoverTarget? noteResult({
    required String serviceId,
    required String currentName,
    required ServiceAccessReason? reason,
    required List<String> preferred,
    required List<String> fallback,
    required Map<String, ServiceAccessResult> accessByProxy,
    required int nowMs,
  }) {
    if (!_failureConfirmed(
      serviceId: serviceId,
      currentName: currentName,
      reason: reason,
      nowMs: nowMs,
    )) {
      return null;
    }
    for (final (candidates, isFallback) in [
      (preferred, false),
      (fallback, true),
    ]) {
      for (final name in candidates) {
        if (name == currentName || _isBuiltin(name)) {
          continue;
        }
        final candidateAccess = accessByProxy[name];
        if (candidateAccess != null &&
            candidateAccess.borrowedFrom == null &&
            candidateAccess.blocksRanking) {
          continue;
        }
        _recordSwitch(serviceId, nowMs);
        return FailoverTarget(name, isFallback: isFallback);
      }
    }
    return null;
  }
}
