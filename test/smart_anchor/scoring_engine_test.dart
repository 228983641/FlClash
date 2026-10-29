import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache node({
  required String name,
  double lat = 34.0522,
  double lon = -118.2437,
  String asn = 'AS20057',
  String egressIp = '1.2.3.4',
  double purity = 90,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: egressIp,
    countryCode: 'US',
    latitude: lat,
    longitude: lon,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: true,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

const anchor = ServiceAnchor(
  serviceTag: 'claude',
  countryCode: 'US',
  lastProxyName: 'US-01',
  egressIp: '1.2.3.4',
  subnet24: '1.2.3',
  asn: 'AS20057',
  isp: 'Example ISP',
  latitude: 34.0522,
  longitude: -118.2437,
  city: 'Los Angeles',
  confirmedAt: 0,
);

List<String> names(List<NodeMetadataCache> nodes) {
  return nodes.map((node) => node.proxyName).toList();
}

void main() {
  test('delay range outweighs proximity: fast far node beats slow twin', () {
    final twin = node(name: 'twin');
    final far = node(
      name: 'far',
      lat: 40.7128,
      lon: -74.0060,
      asn: 'AS99999',
      egressIp: '9.9.9.9',
    );
    final ranked = ScoringEngine.rankForService(
      [twin, far],
      anchor,
      const [],
      const {},
      delays: {'twin': 900, 'far': 100},
    );
    expect(names(ranked), ['far', 'twin']);
  });

  test('a 40 point purity gap compresses away and loses to latency', () {
    final pure = node(name: 'pure', purity: 90);
    final fast = node(name: 'fast', purity: 50);
    final ranked = ScoringEngine.rankForService(
      [pure, fast],
      anchor,
      const [],
      const {},
      delays: {'pure': 500, 'fast': 100},
    );
    expect(names(ranked), ['fast', 'pure']);
    expect(
      ScoringEngine.purityCompressed(90) - ScoringEngine.purityCompressed(50),
      closeTo(9.6, 0.001),
    );
  });

  test('proximity bonus caps at 15', () {
    expect(ScoringEngine.proximityBonus(node(name: 'twin'), anchor), 15);
    expect(
      ScoringEngine.proximityBonus(
        node(name: 'near', asn: 'AS99999', egressIp: '9.9.9.9'),
        anchor,
      ),
      5,
    );
    expect(
      ScoringEngine.proximityBonus(
        node(
          name: 'far',
          lat: 40.7128,
          lon: -74.0060,
          asn: 'AS99999',
          egressIp: '9.9.9.9',
        ),
        anchor,
      ),
      0,
    );
  });

  test('confirmed accessible outranks a stronger unconfirmed node', () {
    final acc = node(name: 'acc', purity: 50);
    final unk = node(name: 'unk', purity: 100);
    final access = {
      'acc': ServiceAccessResult(
        serviceId: 'claude',
        proxyName: 'acc',
        egressIp: '1.2.3.4',
        reason: ServiceAccessReason.accessible,
        checkedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    };
    final ranked = ScoringEngine.rankForService(
      [unk, acc],
      anchor,
      const [],
      access,
      delays: {'acc': 900, 'unk': 50},
    );
    expect(names(ranked), ['acc', 'unk']);
  });

  test('a node without delay data ranks after one with data', () {
    final nodata = node(name: 'nodata', purity: 100);
    final slow = node(name: 'slow', purity: 50);
    final ranked = ScoringEngine.rankForService(
      [nodata, slow],
      anchor,
      const [],
      const {},
      delays: {'slow': 5000},
    );
    expect(names(ranked), ['slow', 'nodata']);
  });

  test('ties resolve by distance, then by name, deterministically', () {
    final ny = node(
      name: 'zzz-ny',
      lat: 40.7128,
      lon: -74.0060,
      asn: 'AS99999',
      egressIp: '9.9.9.9',
    );
    final london = node(
      name: 'aaa-london',
      lat: 51.5074,
      lon: -0.1278,
      asn: 'AS88888',
      egressIp: '8.8.8.8',
    );
    final byDistance = ScoringEngine.rank(
      [london, ny],
      anchor,
      delays: {'zzz-ny': 100, 'aaa-london': 100},
    );
    expect(names(byDistance), ['zzz-ny', 'aaa-london']);

    final bTwin = node(name: 'b-twin');
    final aTwin = node(name: 'a-twin');
    const delays = {'a-twin': 100, 'b-twin': 100};
    expect(names(ScoringEngine.rank([bTwin, aTwin], anchor, delays: delays)), [
      'a-twin',
      'b-twin',
    ]);
    expect(names(ScoringEngine.rank([aTwin, bTwin], anchor, delays: delays)), [
      'a-twin',
      'b-twin',
    ]);
  });
}
