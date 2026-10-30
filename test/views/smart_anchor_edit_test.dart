import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/smart_anchor_edit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

class _MemorySmartAnchor extends SmartAnchor {
  _MemorySmartAnchor(this.service);

  final ServiceToggleConfig service;

  @override
  SmartAnchorInput build() => SmartAnchorInput(services: [service]);

  @override
  void update(SmartAnchorInput next) => state = next;
}

class _RecordingSetup extends SetupAction {
  int applies = 0;

  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) =>
      applies++;
}

void main() {
  for (final initialMode in [
    ServiceRestrictionMode.relaxed,
    ServiceRestrictionMode.strict,
  ]) {
    testWidgets('strict mode edits are saved explicitly from $initialMode', (
      tester,
    ) async {
      final service = defaultServiceToggles.first.copyWith(
        restrictionMode: initialMode,
      );
      final setup = _RecordingSetup();
      final container = ProviderContainer(
        overrides: [
          smartAnchorProvider.overrideWith(() => _MemorySmartAnchor(service)),
          setupActionProvider.overrideWith(() => setup),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            includeNavigatorKey: false,
            locale: const Locale('en'),
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SmartAnchorServiceEditView(service: service),
                  ),
                ),
                child: const Text('edit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(CommonSwitch),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<CommonSwitch>(find.byType(CommonSwitch)).value,
        initialMode == ServiceRestrictionMode.strict,
      );
      await tester.tap(find.byType(CommonSwitch));
      await tester.pumpAndSettle();
      expect(
        container.read(smartAnchorProvider).services.single.restrictionMode,
        initialMode,
      );
      expect(setup.applies, 0);
      await tester.scrollUntilVisible(
        find.text('Save'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final expected = initialMode == ServiceRestrictionMode.strict
          ? ServiceRestrictionMode.relaxed
          : ServiceRestrictionMode.strict;
      final saved = container
          .read(smartAnchorProvider)
          .services
          .firstWhere((candidate) => candidate.serviceId == service.serviceId);
      expect(saved.restrictionMode, expected);
      expect(saved.lockedCountries, service.lockedCountries);
      expect(setup.applies, 1);
      expect(find.byType(SmartAnchorServiceEditView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
