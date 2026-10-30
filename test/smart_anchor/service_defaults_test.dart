import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every preset service is enabled by default', () {
    expect(defaultServiceToggles, isNotEmpty);
    for (final service in defaultServiceToggles) {
      expect(
        service.isEnabled,
        isTrue,
        reason: '${service.serviceId} should be on by default',
      );
    }
  });

  test('locks default on only for region-restricted services', () {
    const unlocked = {'google', 'youtube', 'x'};
    for (final service in defaultServiceToggles) {
      if (unlocked.contains(service.serviceId)) {
        expect(
          service.lockedCountries,
          isEmpty,
          reason: '${service.serviceId} has no regional restriction',
        );
      } else {
        expect(
          service.lockedCountries,
          isNotEmpty,
          reason: '${service.serviceId} should start locked',
        );
      }
    }
    expect(
      defaultServiceToggles
          .firstWhere((service) => service.serviceId == 'netflix')
          .lockedCountries,
      ['SG'],
    );
  });

  test(
    'restriction defaults follow lock participation and are never strict',
    () {
      for (final service in defaultServiceToggles) {
        final expected = service.lockedCountries.isEmpty
            ? ServiceRestrictionMode.unrestricted
            : ServiceRestrictionMode.relaxed;
        expect(
          service.restrictionMode,
          expected,
          reason: '${service.serviceId} should default to $expected',
        );
      }
    },
  );

  test('provider build uses the preset defaults', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final services = container.read(smartAnchorProvider).services;
    expect(
      services.map((service) => service.serviceId),
      defaultServiceToggles.map((service) => service.serviceId),
    );
    expect(services.every((service) => service.isEnabled), isTrue);
    expect(
      services
          .firstWhere((service) => service.serviceId == 'google')
          .lockedCountries,
      isEmpty,
    );
  });
}
