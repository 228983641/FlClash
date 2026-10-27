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
