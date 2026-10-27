import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:flutter_test/flutter_test.dart';

AnchorPathPoint point(String name, int at) {
  return AnchorPathPoint(
    serviceId: 'youtube',
    proxyName: name,
    latitude: 34.0522,
    longitude: -118.2437,
    countryCode: 'US',
    city: 'Los Angeles',
    recordedAt: at,
    note: 'start',
  );
}

void main() {
  test('path point round-trips through json', () {
    final restored = AnchorPathPoint.fromJson(point('LA-node', 1000).toJson());
    expect(restored.proxyName, 'LA-node');
    expect(restored.placeLabel, 'Los Angeles');
    expect(restored.recordedAt, 1000);
  });

  test('same node twice in a row is not recorded twice', () {
    final points = appendPathPoint([
      point('LA-node', 1000),
    ], point('LA-node', 2000));
    expect(points.length, 1);
  });

  test('path keeps only the most recent thirty points', () {
    var points = <AnchorPathPoint>[];
    for (var i = 0; i < 35; i++) {
      points = appendPathPoint(points, point('node-$i', i));
    }
    expect(points.length, 30);
    expect(points.first.proxyName, 'node-5');
    expect(points.last.proxyName, 'node-34');
  });
}
