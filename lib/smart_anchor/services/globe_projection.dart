import 'dart:math' as math;

/// A point on the unit sphere. Earth-frame vectors come from
/// [GlobeVector.fromLatLon]; view-frame vectors come from
/// [GlobeProjection.view], where the visible hemisphere is z >= 0.
class GlobeVector {
  const GlobeVector(this.x, this.y, this.z);

  factory GlobeVector.fromLatLon(double lat, double lon) {
    final phi = lat * math.pi / 180;
    final lambda = lon * math.pi / 180;
    return GlobeVector(
      math.cos(phi) * math.sin(lambda),
      math.sin(phi),
      math.cos(phi) * math.cos(lambda),
    );
  }

  final double x;
  final double y;
  final double z;

  double dot(GlobeVector other) => x * other.x + y * other.y + z * other.z;

  bool get visible => z >= 0;
}

/// Orthographic globe projection. Ring vertices are converted once to
/// earth-frame vectors, so per-frame work is two rotations per vertex and
/// no trigonometry. Disc points use y down, matching canvas coordinates.
class GlobeProjection {
  const GlobeProjection({required this.centerLon, required this.centerLat});

  final double centerLon;
  final double centerLat;

  GlobeVector view(GlobeVector earth) {
    final lon0 = centerLon * math.pi / 180;
    final lat0 = centerLat * math.pi / 180;
    final cosLon = math.cos(lon0);
    final sinLon = math.sin(lon0);
    final x = earth.x * cosLon - earth.z * sinLon;
    final z = earth.x * sinLon + earth.z * cosLon;
    final cosLat = math.cos(lat0);
    final sinLat = math.sin(lat0);
    return GlobeVector(
      x,
      earth.y * cosLat - z * sinLat,
      earth.y * sinLat + z * cosLat,
    );
  }

  /// Disc coordinates, or null when the point is on the far side.
  (double, double)? project(double lat, double lon) {
    final v = view(GlobeVector.fromLatLon(lat, lon));
    if (!v.visible) {
      return null;
    }
    return (v.x, -v.y);
  }

  /// Great-circle interpolation between two sphere points.
  static GlobeVector slerp(GlobeVector a, GlobeVector b, double t) {
    final omega = math.acos(a.dot(b).clamp(-1.0, 1.0));
    if (omega < 1e-9) {
      return a;
    }
    final sinOmega = math.sin(omega);
    final wa = math.sin((1 - t) * omega) / sinOmega;
    final wb = math.sin(t * omega) / sinOmega;
    return GlobeVector(
      wa * a.x + wb * b.x,
      wa * a.y + wb * b.y,
      wa * a.z + wb * b.z,
    );
  }

  /// The limb crossing on the great circle between two points on opposite
  /// sides of the visible hemisphere.
  static GlobeVector limbCrossing(GlobeVector a, GlobeVector b) {
    final omega = math.acos(a.dot(b).clamp(-1.0, 1.0));
    if (omega < 1e-9) {
      return a;
    }
    final aPositive = a.z >= 0;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if ((slerp(a, b, mid).z >= 0) == aPositive) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return slerp(a, b, (lo + hi) / 2);
  }

  /// Clips a closed ring of earth-frame vectors to the visible hemisphere,
  /// interpolating crossings along great circles so the clipped polygon
  /// stays closed and correctly oriented. An empty list means fully hidden.
  List<(double, double)> clipRing(List<GlobeVector> ring) {
    if (ring.isEmpty) {
      return [];
    }
    final vectors = [for (final v in ring) view(v)];
    final clipped = <GlobeVector>[];
    var s = vectors.last;
    for (final e in vectors) {
      if (e.visible) {
        if (!s.visible) {
          clipped.add(limbCrossing(s, e));
        }
        clipped.add(e);
      } else if (s.visible) {
        clipped.add(limbCrossing(s, e));
      }
      s = e;
    }
    return [for (final v in clipped) (v.x, -v.y)];
  }

  /// Samples the great circle between two lat/lon points, split into
  /// visible runs of disc coordinates.
  List<List<(double, double)>> greatCircleRuns(
    double fromLat,
    double fromLon,
    double toLat,
    double toLon,
  ) {
    final a = view(GlobeVector.fromLatLon(fromLat, fromLon));
    final b = view(GlobeVector.fromLatLon(toLat, toLon));
    final omega = math.acos(a.dot(b).clamp(-1.0, 1.0));
    final steps = (omega * 180 / math.pi / 3).ceil().clamp(8, 120);
    final runs = <List<(double, double)>>[];
    var run = <(double, double)>[];
    for (var i = 0; i <= steps; i++) {
      final v = slerp(a, b, i / steps);
      if (v.visible) {
        run.add((v.x, -v.y));
      } else if (run.isNotEmpty) {
        runs.add(run);
        run = <(double, double)>[];
      }
    }
    if (run.isNotEmpty) {
      runs.add(run);
    }
    return runs;
  }
}
