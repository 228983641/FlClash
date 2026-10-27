import 'service_access.dart';

class FailoverGuard {
  final Map<String, int> _failures = {};
  final Map<String, String?> _lastCurrent = {};
  final Map<String, List<int>> _switchTimes = {};

  String? noteResult({
    required String serviceId,
    required String currentName,
    required ServiceAccessReason? reason,
    required List<String> ranked,
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
    for (final name in ranked) {
      if (name == currentName) {
        continue;
      }
      if (accessByProxy[name]?.reason == ServiceAccessReason.regionBlocked) {
        continue;
      }
      _switchTimes[serviceId] = [...recent, nowMs];
      return name;
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
