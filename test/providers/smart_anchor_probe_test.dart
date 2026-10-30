import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

class _MemorySmartAnchor extends SmartAnchor {
  @override
  SmartAnchorInput build() => SmartAnchorInput(
    services: [defaultServiceToggles.first.copyWith(isEnabled: true)],
  );

  @override
  void update(SmartAnchorInput next) => state = next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MockCore core;
  late ProviderContainer container;
  late SmartAnchor notifier;

  setUpAll(() {
    registerFallbackValue(const OutboundIpParams(timeout: 1));
    registerFallbackValue(const ServiceCheckParams(timeout: 1));
  });

  setUp(() {
    core = _MockCore();
    when(() => core.outboundIp(any())).thenAnswer((_) async => null);
    when(() => core.serviceCheck(any())).thenAnswer(
      (_) async => [const ServiceCheckItem(name: 'claude', status: 'timeout')],
    );
    container = ProviderContainer(
      overrides: [
        coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        smartAnchorProvider.overrideWith(_MemorySmartAnchor.new),
      ],
    );
    container.listen(currentProfileIdProvider, (_, _) {});
    notifier = container.read(smartAnchorProvider.notifier);
  });

  tearDown(() => container.dispose());

  Future<int> probe({List<String> names = const ['A']}) => notifier.probeNodes(
    proxyNames: names,
    currentProxyName: 'A',
    force: true,
    updateThrottle: false,
  );

  test('overlapping rounds do not issue duplicate requests', () async {
    final pending = Completer<OutboundIpResult?>();
    when(() => core.outboundIp(any())).thenAnswer((_) => pending.future);
    final first = probe();
    expect(await probe(), 0);
    verify(() => core.outboundIp(any())).called(1);
    pending.complete(null);
    await first;
    expect(
      container.read(smartAnchorProvider).accessByService['claude'],
      contains('A'),
    );
    await probe();
    verify(() => core.outboundIp(any())).called(1);
  });

  test('a profile change discards results and stops later chunks', () async {
    final pending = Completer<OutboundIpResult?>();
    when(() => core.outboundIp(any())).thenAnswer((_) => pending.future);
    final first = probe(names: ['A', 'B', 'C', 'D', 'E']);
    container.read(currentProfileIdProvider.notifier).value = 2;
    pending.complete(null);
    expect(await first, 0);
    verify(() => core.outboundIp(any())).called(4);
    expect(container.read(smartAnchorProvider).accessByService, isEmpty);
  });

  test('a failed lookup does not keep the round permanently busy', () async {
    when(() => core.outboundIp(any())).thenThrow(StateError('probe failed'));
    expect(await probe(), 0);
    when(() => core.outboundIp(any())).thenAnswer((_) async => null);
    await probe();
    expect(
      container.read(smartAnchorProvider).accessByService['claude'],
      contains('A'),
    );
  });

  test(
    'switching away and back still invalidates the in-flight round',
    () async {
      final pending = Completer<OutboundIpResult?>();
      when(() => core.outboundIp(any())).thenAnswer((_) => pending.future);
      final first = probe();
      container.read(currentProfileIdProvider.notifier).value = 2;
      container.read(currentProfileIdProvider.notifier).value = 1;
      pending.complete(null);
      expect(await first, 0);
      expect(container.read(smartAnchorProvider).accessByService, isEmpty);
    },
  );

  test('changing profiles does not inherit the previous throttle', () async {
    Future<int> throttled() =>
        notifier.probeNodes(proxyNames: ['A'], currentProxyName: 'A');
    await throttled();
    await throttled();
    verify(() => core.outboundIp(any())).called(1);
    container.read(currentProfileIdProvider.notifier).value = 2;
    await throttled();
    verify(() => core.outboundIp(any())).called(1);
  });
}
