import 'package:fl_clash/common/perf_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(PerfTrace.clear);

  test('log line omits empty counters', () {
    const plain = PerfTraceEvent(
      action: 'switch-proxy-core',
      durationMs: 5,
      jankFrames: 0,
      severeFrames: 0,
      detail: '',
      recordedAtMs: 0,
    );
    expect(plain.toLogLine(), '[PERF] switch-proxy-core 5ms');
    const framed = PerfTraceEvent(
      action: 'switch-proxy-core',
      durationMs: 120,
      jankFrames: 3,
      severeFrames: 1,
      detail: 'tap G -> N',
      recordedAtMs: 0,
    );
    expect(
      framed.toLogLine(),
      '[PERF] switch-proxy-core 120ms jank=3 severe=1 tap G -> N',
    );
  });

  test('record caps the buffer at 200 events', () {
    for (var i = 0; i < 250; i++) {
      PerfTrace.record(
        action: 'tap',
        duration: Duration.zero,
        detail: 'event-$i',
      );
    }
    expect(PerfTrace.events.length, 200);
    expect(PerfTrace.events.first.detail, 'event-50');
    expect(PerfTrace.events.last.detail, 'event-249');
  });

  test('time returns the work result and records its duration', () async {
    final result = await PerfTrace.time('work', () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return 42;
    });
    expect(result, 42);
    expect(PerfTrace.events.length, 1);
    final event = PerfTrace.events.single;
    expect(event.action, 'work');
    expect(event.durationMs >= 20, isTrue);
  });

  test('time records even when the work throws', () async {
    await expectLater(
      PerfTrace.time('work', () async => throw StateError('boom')),
      throwsStateError,
    );
    expect(PerfTrace.events.length, 1);
    expect(PerfTrace.events.single.action, 'work');
  });
}
