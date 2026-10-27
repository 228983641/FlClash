import 'package:fl_clash/smart_anchor/services/globe_projection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('center point projects to the disc center, antipode hides', () {
    const projection = GlobeProjection(centerLon: 10, centerLat: 20);
    final center = projection.project(20, 10);
    expect(center, isNotNull);
    expect(center!.$1, closeTo(0, 1e-9));
    expect(center.$2, closeTo(0, 1e-9));
    expect(projection.project(-20, -170), isNull);
  });

  test('a fully visible ring keeps every vertex', () {
    const projection = GlobeProjection(centerLon: 0, centerLat: 0);
    final ring = [
      for (final point in [
        (-10.0, -10.0),
        (10.0, -10.0),
        (10.0, 10.0),
        (-10.0, 10.0),
      ])
        GlobeVector.fromLatLon(point.$2, point.$1),
    ];
    final clipped = projection.clipRing(ring);
    expect(clipped.length, 4);
    expect(
      clipped.every((point) => point.$1 * point.$1 + point.$2 * point.$2 <= 1),
      isTrue,
    );
  });

  test('a fully hidden ring clips to nothing', () {
    const projection = GlobeProjection(centerLon: 0, centerLat: 0);
    final ring = [
      for (final point in [
        (170.0, -10.0),
        (190.0, -10.0),
        (190.0, 10.0),
        (170.0, 10.0),
      ])
        GlobeVector.fromLatLon(point.$2, point.$1),
    ];
    expect(projection.clipRing(ring), isEmpty);
  });

  test(
    'a straddling ring clips to the limb without chords across the disc',
    () {
      const projection = GlobeProjection(centerLon: 0, centerLat: 0);
      final ring = [
        for (final point in [
          (-100.0, -10.0),
          (50.0, -10.0),
          (50.0, 10.0),
          (-100.0, 10.0),
        ])
          GlobeVector.fromLatLon(point.$2, point.$1),
      ];
      final clipped = projection.clipRing(ring);
      expect(clipped.length, 4);
      for (final point in clipped) {
        expect(
          point.$1 * point.$1 + point.$2 * point.$2,
          lessThanOrEqualTo(1.000001),
        );
      }
      final onLimb = clipped.where(
        (point) => (point.$1 * point.$1 + point.$2 * point.$2 - 1).abs() < 1e-6,
      );
      expect(onLimb.length, 2);
    },
  );

  test('great circle runs stop at the limb', () {
    const projection = GlobeProjection(centerLon: 0, centerLat: 0);
    final partial = projection.greatCircleRuns(0, -100, 0, 0);
    expect(partial.length, 1);
    expect(partial.first.length, greaterThan(2));
    final hidden = projection.greatCircleRuns(0, -170, 0, -100);
    expect(hidden, isEmpty);
  });
}
