import 'service_access.dart';

class FailoverTarget {
  const FailoverTarget(this.name, {required this.isFallback});

  final String name;
  final bool isFallback;
}

class FailoverGuard {
  final Map<String, int> _failures = {};
  final Map<String, String?> _lastCurrent = {};
  final Map<String, List<int>> _switchTimes = {};
  int _lastCountedFailures = 0;

  /// The failure count the most recent [noteResult] call accumulated to,
  /// kept after a decision resets the running count so callers can log
  /// the count that led to it.
  int get lastCountedFailures => _lastCountedFailures;

  static const int _freezeWindowMs = 10 * 60 * 1000;
  static const int _freezeSwitchLimit = 3;

  List<int> _recentSwitches(String serviceId, int nowMs) {
    return (_switchTimes[serviceId] ?? [])
        .where((time) => nowMs - time <= _freezeWindowMs)
        .toList();
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

  FailoverTarget? noteResult({
    required String serviceId,
    required String currentName,
    required ServiceAccessReason? reason,
    required List<String> preferred,
    required List<String> fallback,
    required Map<String, ServiceAccessResult> accessByProxy,
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
      return null;
    }
    final count = (_failures[serviceId] ?? 0) + 1;
    _failures[serviceId] = count;
    _lastCountedFailures = count;
    if (count < 2) {
      return null;
    }
    _failures[serviceId] = 0;
    final recent = (_switchTimes[serviceId] ?? [])
        .where((time) => nowMs - time <= 10 * 60 * 1000)
        .toList();
    if (recent.length >= 3) {
      _switchTimes[serviceId] = recent;
      return null;
    }
    for (final (candidates, isFallback) in [
      (preferred, false),
      (fallback, true),
    ]) {
      for (final name in candidates) {
        if (name == currentName) {
          continue;
        }
        if (name == 'DIRECT' || name == 'REJECT' || name == 'REJECT-DROP') {
          continue;
        }
        final candidateAccess = accessByProxy[name];
        if (candidateAccess != null &&
            candidateAccess.borrowedFrom == null &&
            candidateAccess.blocksRanking) {
          continue;
        }
        _switchTimes[serviceId] = [...recent, nowMs];
        return FailoverTarget(name, isFallback: isFallback);
      }
    }
    return null;
  }
}

class StickyMonitor {
  StickyMonitor({required List<String> ranked, int initialIndex = 0})
    : _ranked = List<String>.of(ranked),
      _currentIndex = initialIndex;

  final List<String> _ranked;
  int _currentIndex;
  int _consecutiveFailures = 0;
  int? _switchedAtMs;
  final List<int> _switchTimesMs = [];
  bool _anchorFrozen = false;

  String? get current => _ranked.isEmpty ? null : _ranked[_currentIndex];
  int get currentIndex => _currentIndex;
  bool get anchorFrozen => _anchorFrozen;
  bool get exhausted => _ranked.isEmpty || _currentIndex >= _ranked.length - 1;

  void updateRanked(List<String> ranked) {
    final currentName = current;
    _ranked
      ..clear()
      ..addAll(ranked);
    if (currentName == null) {
      _currentIndex = 0;
      return;
    }
    final index = _ranked.indexOf(currentName);
    _currentIndex = index == -1 ? 0 : index;
  }

  String? recordProbe({required bool success, required int nowMs}) {
    if (success) {
      _consecutiveFailures = 0;
      return null;
    }
    _consecutiveFailures += 1;
    if (_consecutiveFailures < 2 || exhausted) {
      return null;
    }
    _consecutiveFailures = 0;
    _currentIndex += 1;
    _switchedAtMs = nowMs;
    _switchTimesMs.add(nowMs);
    _switchTimesMs.removeWhere((time) => nowMs - time > 10 * 60 * 1000);
    if (_switchTimesMs.length >= 3) {
      _anchorFrozen = true;
    }
    return current;
  }

  bool shouldConfirmAnchor(int nowMs) {
    if (_anchorFrozen || _switchedAtMs == null) {
      return false;
    }
    return nowMs - _switchedAtMs! >= 10 * 60 * 1000;
  }

  void confirmAnchor() {
    _switchedAtMs = null;
  }
}
