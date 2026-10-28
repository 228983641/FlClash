import 'package:fl_clash/common/print.dart';
import 'package:flutter/scheduler.dart';

class PerfTraceEvent {
  const PerfTraceEvent({
    required this.action,
    required this.durationMs,
    required this.jankFrames,
    required this.severeFrames,
    required this.detail,
    required this.recordedAtMs,
  });

  final String action;
  final int durationMs;
  final int jankFrames;
  final int severeFrames;
  final String detail;
  final int recordedAtMs;

  String toLogLine() {
    final buffer = StringBuffer('[PERF] $action ${durationMs}ms');
    if (jankFrames > 0) {
      buffer.write(' jank=$jankFrames');
    }
    if (severeFrames > 0) {
      buffer.write(' severe=$severeFrames');
    }
    if (detail.isNotEmpty) {
      buffer.write(' $detail');
    }
    return buffer.toString();
  }
}

class PerfFrameSampler {
  var _jankFrames = 0;
  var _severeFrames = 0;
  var _active = false;
  var _registered = false;

  void start() {
    if (_active) {
      return;
    }
    _active = true;
    _jankFrames = 0;
    _severeFrames = 0;
    _registered = false;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _registered = true;
    } catch (_) {
      // No binding yet: durations still record, frame counts stay zero.
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_active) {
      return;
    }
    for (final timing in timings) {
      final total = timing.buildDuration + timing.rasterDuration;
      if (total > const Duration(milliseconds: 100)) {
        _severeFrames++;
        _jankFrames++;
      } else if (total > const Duration(milliseconds: 16)) {
        _jankFrames++;
      }
    }
  }

  (int, int) stop() {
    if (!_active) {
      return (0, 0);
    }
    _active = false;
    if (_registered) {
      _registered = false;
      try {
        SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      } catch (_) {
        // The binding went away mid-trace; counts already collected stand.
      }
    }
    return (_jankFrames, _severeFrames);
  }
}

class PerfTrace {
  static const _cap = 200;
  static final _events = <PerfTraceEvent>[];

  static List<PerfTraceEvent> get events => List.unmodifiable(_events);

  static void clear() {
    _events.clear();
  }

  static void record({
    required String action,
    required Duration duration,
    String detail = '',
    int jankFrames = 0,
    int severeFrames = 0,
  }) {
    final event = PerfTraceEvent(
      action: action,
      durationMs: duration.inMilliseconds,
      jankFrames: jankFrames,
      severeFrames: severeFrames,
      detail: detail,
      recordedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _events.add(event);
    if (_events.length > _cap) {
      _events.removeRange(0, _events.length - _cap);
    }
    commonPrint.log(event.toLogLine());
  }

  static Future<T> time<T>(
    String action,
    Future<T> Function() work, {
    String detail = '',
  }) async {
    final sampler = PerfFrameSampler()..start();
    final stopwatch = Stopwatch()..start();
    try {
      return await work();
    } finally {
      stopwatch.stop();
      final (jank, severe) = sampler.stop();
      record(
        action: action,
        duration: stopwatch.elapsed,
        detail: detail,
        jankFrames: jank,
        severeFrames: severe,
      );
    }
  }
}
