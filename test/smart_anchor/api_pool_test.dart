import 'package:fl_clash/smart_anchor/services/api_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('key pool round robins and skips cooled keys', () {
    final pool = ApiKeyPool(['k1', 'k2'], cooldownMs: 1000);
    expect(pool.nextKey(0), 'k1');
    expect(pool.nextKey(0), 'k2');
    expect(pool.nextKey(0), 'k1');
    pool.markRateLimited('k1', 10);
    expect(pool.isCooled('k1', 11), true);
    expect(pool.isCooled('k1', 2000), false);
    expect(pool.nextKey(11), 'k2');
  });

  test('cache returns fresh entries and drops expired ones', () {
    final cache = GeoIpCache();
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh =
        parseIpApi({
          'status': 'success',
          'query': '1.2.3.4',
          'countryCode': 'US',
          'lat': 34.0,
          'lon': -118.0,
          'as': 'AS20057 Example',
          'hosting': false,
          'mobile': false,
          'proxy': false,
        })!.toNodeMetadata(
          proxyName: 'US-01',
          entryServer: 'entry.example',
          wafPass: true,
          updatedAt: now,
        );
    cache.put(fresh);
    expect(cache.lookup('1.2.3.4')?.countryCode, 'US');
    final stale =
        parseIpApi({
          'status': 'success',
          'query': '5.6.7.8',
          'countryCode': 'SG',
          'lat': 1.0,
          'lon': 104.0,
          'as': 'AS9999 Example',
          'hosting': true,
          'mobile': false,
          'proxy': false,
        })!.toNodeMetadata(
          proxyName: 'SG-01',
          entryServer: 'entry.example',
          wafPass: true,
          updatedAt: now - 73 * 3600 * 1000,
        );
    cache.put(stale);
    expect(cache.lookup('5.6.7.8'), isNull);
  });

  test('three source parsers produce geo and asn', () {
    final ipApi = parseIpApi({
      'status': 'success',
      'query': '1.2.3.4',
      'countryCode': 'US',
      'lat': 34.0,
      'lon': -118.0,
      'as': 'AS20057 Example',
      'hosting': true,
      'mobile': false,
      'proxy': true,
    })!;
    expect(ipApi.asn, 'AS20057');
    expect(ipApi.ipType, 'hosting');
    expect(ipApi.isAbuse, true);
    final ipInfo = parseIpInfo({
      'ip': '1.2.3.4',
      'country': 'US',
      'loc': '34.0522,-118.2437',
      'org': 'AS20057 Example',
    })!;
    expect(ipInfo.latitude, 34.0522);
    final ipSb = parseIpSb({
      'ip': '1.2.3.4',
      'country_code': 'SG',
      'latitude': 1.35,
      'longitude': 103.82,
      'asn': 9999,
    })!;
    expect(ipSb.asn, 'AS9999');
    expect(ipSb.countryCode, 'SG');
  });

  test('service uses cache and falls over to next key on 429', () async {
    final cache = GeoIpCache();
    var calls = 0;
    final service = GeoIpService(
      cache: cache,
      sourceOrder: const ['ip-api'],
      keyPools: {
        'ip-api': ApiKeyPool(['k1', 'k2'], cooldownMs: 60000),
      },
      fetcher: (ip, key, sourceId) async {
        calls++;
        if (key == 'k1') {
          throw const GeoIpRateLimited('ip-api');
        }
        return {
          'status': 'success',
          'query': ip,
          'countryCode': 'US',
          'lat': 34.0,
          'lon': -118.0,
          'as': 'AS20057 Example',
          'hosting': false,
          'mobile': false,
          'proxy': false,
        };
      },
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final first = await service.lookup(
      ip: '1.2.3.4',
      proxyName: 'US-01',
      entryServer: 'entry.example',
      wafPass: true,
      nowMs: now,
    );
    expect(first?.asn, 'AS20057');
    expect(first?.purityScore, 100);
    final second = await service.lookup(
      ip: '1.2.3.4',
      proxyName: 'US-01',
      entryServer: 'entry.example',
      wafPass: true,
      nowMs: now,
    );
    expect(second, first);
    expect(calls, 2);
  });

  test('new free source parsers produce geo and asn', () {
    final ipWhoIs = parseIpWhoIs({
      'ip': '8.8.8.8',
      'success': true,
      'country_code': 'US',
      'latitude': 37.3393939,
      'longitude': -121.8949553,
      'connection': {'asn': 15169, 'org': 'Google LLC'},
    })!;
    expect(ipWhoIs.asn, 'AS15169');
    expect(ipWhoIs.countryCode, 'US');
    expect(parseIpWhoIs({'success': false, 'country_code': 'US'}), isNull);
    final freeIpApi = parseFreeIpApi({
      'ipAddress': '8.8.8.8',
      'countryCode': 'US',
      'latitude': 37.422,
      'longitude': -122.085,
      'asn': '15169',
      'isProxy': true,
    })!;
    expect(freeIpApi.asn, 'AS15169');
    expect(freeIpApi.isAbuse, true);
    expect(parseFreeIpApi({'countryCode': ''}), isNull);
    final ipApiCo = parseIpApiCo({
      'ip': '8.8.8.8',
      'country_code': 'US',
      'latitude': 37.42301,
      'longitude': -122.083352,
      'asn': 'AS15169',
    })!;
    expect(ipApiCo.asn, 'AS15169');
    expect(ipApiCo.countryCode, 'US');
    expect(parseIpApiCo({'country_code': ''}), isNull);
    final geoJs = parseGeoJs({
      'ip': '8.8.8.8',
      'country_code': 'US',
      'latitude': '37.751',
      'longitude': '-97.822',
      'asn': 15169,
    })!;
    expect(geoJs.asn, 'AS15169');
    expect(geoJs.latitude, 37.751);
    expect(parseGeoJs({'country_code': ''}), isNull);
  });

  test('service rotates three sources per lookup', () async {
    final seen = <List<String>>[];
    var current = <String>[];
    final service = GeoIpService(
      cache: GeoIpCache(),
      keyPools: const {},
      fetcher: (ip, key, sourceId) async {
        current.add(sourceId);
        return {
          'status': 'success',
          'query': ip,
          'countryCode': 'US',
          'lat': 34.0,
          'lon': -118.0,
          'as': 'AS20057 Example',
          'hosting': false,
          'mobile': false,
          'proxy': false,
          'ip': ip,
          'country': 'US',
          'loc': '34.0,-118.0',
          'org': 'AS20057 Example',
          'country_code': 'US',
          'latitude': 34.0,
          'longitude': -118.0,
          'asn': 20057,
          'success': true,
          'connection': {'asn': 20057},
          'ipAddress': ip,
        };
      },
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    Future<void> probe(String ip) async {
      current = [];
      final result = await service.lookup(
        ip: ip,
        proxyName: 'P-$ip',
        entryServer: 'entry.example',
        wafPass: true,
        nowMs: now,
      );
      expect(result?.sourceCount, 3);
      seen.add(current);
    }

    await probe('1.1.1.1');
    await probe('2.2.2.2');
    expect(seen[0], ['ip-api', 'ipinfo', 'ip.sb']);
    expect(seen[1], ['ipinfo', 'ip.sb', 'ipwho.is']);
  });

  test('service aggregates six sources by majority country', () async {
    final service = GeoIpService(
      cache: GeoIpCache(),
      sourcesPerLookup: 6,
      keyPools: const {},
      fetcher: (ip, key, sourceId) async {
        return switch (sourceId) {
          'ip-api' => {
            'status': 'success',
            'query': ip,
            'countryCode': 'US',
            'lat': 34.0,
            'lon': -118.0,
            'as': 'AS20057 Example',
            'hosting': false,
            'mobile': false,
            'proxy': false,
          },
          'ipinfo' => {
            'ip': ip,
            'country': 'US',
            'loc': '34.0522,-118.2437',
            'org': 'AS20057 Example',
          },
          'ip.sb' => {
            'ip': ip,
            'country_code': 'SG',
            'latitude': 1.35,
            'longitude': 103.82,
            'asn': 9999,
          },
          'ipwho.is' => {
            'ip': ip,
            'success': true,
            'country_code': 'SG',
            'latitude': 1.35,
            'longitude': 103.82,
            'connection': {'asn': 9999},
          },
          'freeipapi' => {
            'ipAddress': ip,
            'countryCode': 'SG',
            'latitude': 1.35,
            'longitude': 103.82,
            'asn': '9999',
            'isProxy': false,
          },
          'geojs' => {
            'ip': ip,
            'country_code': 'SG',
            'latitude': '1.35',
            'longitude': '103.82',
            'asn': 9999,
          },
          _ => null,
        };
      },
    );
    final result = await service.lookup(
      ip: '1.2.3.4',
      proxyName: 'SG-01',
      entryServer: 'entry.example',
      wafPass: true,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(result?.countryCode, 'SG');
    expect(result?.sourceCount, 6);
    expect(result?.countryDisputed, true);
    expect(result?.asn, 'AS9999');
  });

  test('service aggregates three sources by majority country', () async {
    final service = GeoIpService(
      cache: GeoIpCache(),
      keyPools: const {},
      fetcher: (ip, key, sourceId) async {
        return switch (sourceId) {
          'ip-api' => {
            'status': 'success',
            'query': ip,
            'countryCode': 'US',
            'lat': 34.0,
            'lon': -118.0,
            'as': 'AS20057 Example',
            'hosting': true,
            'mobile': false,
            'proxy': false,
          },
          'ipinfo' => {
            'ip': ip,
            'country': 'US',
            'loc': '34.0522,-118.2437',
            'org': 'AS20057 Example',
          },
          'ip.sb' => {
            'ip': ip,
            'country_code': 'SG',
            'latitude': 1.35,
            'longitude': 103.82,
            'asn': 9999,
          },
          _ => null,
        };
      },
    );
    final result = await service.lookup(
      ip: '1.2.3.4',
      proxyName: 'US-01',
      entryServer: 'entry.example',
      wafPass: true,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(result?.countryCode, 'US');
    expect(result?.sourceCount, 3);
    expect(result?.countryDisputed, true);
    expect(result?.asn, 'AS20057');
    expect(result?.ipType, 'hosting');
    expect(result?.purityScore, 70);
    expect(result!.latitude, closeTo(34.0261, 0.0001));
  });

  test('aggregation takes worst type and max fraud score', () {
    final aggregated = aggregateGeoResults([
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS1',
        ipType: 'isp',
        fraudScore: 10,
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.1,
        longitude: -118.1,
        asn: 'AS1',
        ipType: 'hosting',
        fraudScore: 40,
      ),
    ])!;
    expect(aggregated.countryDisputed, false);
    expect(aggregated.sourceCount, 2);
    expect(aggregated.ipType, 'hosting');
    expect(aggregated.fraudScore, 40);
    expect(aggregated.latitude, closeTo(34.05, 0.0001));
  });

  test('parsers keep the city and region their payloads already carry', () {
    final ipApi = parseIpApi({
      'status': 'success',
      'query': '1.2.3.4',
      'countryCode': 'US',
      'lat': 34.0,
      'lon': -118.0,
      'as': 'AS20057 Example',
      'hosting': false,
      'mobile': false,
      'proxy': false,
      'city': 'Los Angeles',
      'regionName': 'California',
    })!;
    expect(ipApi.city, 'Los Angeles');
    expect(ipApi.adminRegion, 'California');
    final ipInfo = parseIpInfo({
      'ip': '1.2.3.4',
      'country': 'US',
      'loc': '34.0522,-118.2437',
      'org': 'AS20057 Example',
      'city': 'Los Angeles',
      'region': 'California',
    })!;
    expect(ipInfo.city, 'Los Angeles');
    expect(ipInfo.adminRegion, 'California');
    final ipWhoIs = parseIpWhoIs({
      'ip': '8.8.8.8',
      'success': true,
      'country_code': 'US',
      'latitude': 37.3393939,
      'longitude': -121.8949553,
      'connection': {'asn': 15169, 'org': 'Google LLC'},
      'city': 'Mountain View',
      'region': 'California',
    })!;
    expect(ipWhoIs.city, 'Mountain View');
    expect(ipWhoIs.adminRegion, 'California');
    final freeIpApi = parseFreeIpApi({
      'ipAddress': '8.8.8.8',
      'countryCode': 'US',
      'latitude': 37.422,
      'longitude': -122.085,
      'asn': '15169',
      'isProxy': false,
      'cityName': 'Mountain View',
      'regionName': 'California',
    })!;
    expect(freeIpApi.city, 'Mountain View');
    expect(freeIpApi.adminRegion, 'California');
    final bare = parseIpApi({
      'status': 'success',
      'query': '1.2.3.4',
      'countryCode': 'US',
      'lat': 34.0,
      'lon': -118.0,
      'as': 'AS20057 Example',
      'hosting': false,
      'mobile': false,
      'proxy': false,
    })!;
    expect(bare.city, isNull);
    expect(bare.adminRegion, isNull);
  });

  test('aggregation fills city, region and confidences from the winner', () {
    final aggregated = aggregateGeoResults([
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS1',
        ipType: 'isp',
        city: 'Los Angeles',
        adminRegion: 'California',
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.1,
        longitude: -118.1,
        asn: 'AS1',
        ipType: 'isp',
        city: 'Los Angeles',
        adminRegion: 'California',
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.2,
        longitude: -118.2,
        asn: 'AS1',
        ipType: 'isp',
        city: 'San Francisco',
        adminRegion: 'California',
      ),
    ])!;
    expect(aggregated.city, 'Los Angeles');
    expect(aggregated.adminRegion, 'California');
    expect(aggregated.geoConfidence, 0.9);
    expect(aggregated.asnConfidence, 0.9);
    final metadata = aggregated.toNodeMetadata(
      proxyName: 'US-01',
      entryServer: 'entry.example',
      wafPass: true,
      updatedAt: 0,
    );
    expect(metadata.city, 'Los Angeles');
    expect(metadata.adminRegion, 'California');
    expect(metadata.geoConfidence, 0.9);
    expect(metadata.asnConfidence, 0.9);
  });

  test('aggregation discounts confidence when the country is disputed', () {
    final aggregated = aggregateGeoResults([
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS1',
        ipType: 'isp',
        city: 'Los Angeles',
        adminRegion: 'California',
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.1,
        longitude: -118.1,
        asn: 'AS1',
        ipType: 'isp',
        city: 'Los Angeles',
        adminRegion: 'California',
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'SG',
        latitude: 1.35,
        longitude: 103.82,
        asn: 'AS2',
        ipType: 'isp',
        city: 'Singapore',
        adminRegion: '',
      ),
    ])!;
    expect(aggregated.countryCode, 'US');
    expect(aggregated.countryDisputed, true);
    expect(aggregated.city, 'Los Angeles');
    expect(aggregated.geoConfidence, 0.55);
    expect(aggregated.asnConfidence, 0.9);
  });

  test('a single aggregated source earns only low confidence', () {
    final aggregated = aggregateGeoResults([
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS1',
        ipType: 'isp',
        city: 'Los Angeles',
        adminRegion: 'California',
      ),
    ])!;
    expect(aggregated.geoConfidence, 0.4);
    expect(aggregated.asnConfidence, 0.5);
    expect(aggregated.city, 'Los Angeles');
  });

  test('aggregation splits asn confidence when sources disagree', () {
    final aggregated = aggregateGeoResults([
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS1',
        ipType: 'isp',
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS1',
        ipType: 'isp',
      ),
      const GeoIpResult(
        ip: '1.2.3.4',
        countryCode: 'US',
        latitude: 34.0,
        longitude: -118.0,
        asn: 'AS2',
        ipType: 'isp',
      ),
    ])!;
    expect(aggregated.asn, 'AS1');
    expect(aggregated.asnConfidence, closeTo(0.4 + 0.4 * 2 / 3, 0.0001));
  });

  test('service lookup writes city and confidence into the metadata', () async {
    final service = GeoIpService(
      cache: GeoIpCache(),
      keyPools: const {},
      fetcher: (ip, key, sourceId) async {
        return switch (sourceId) {
          'ip-api' => {
            'status': 'success',
            'query': ip,
            'countryCode': 'US',
            'lat': 34.0,
            'lon': -118.0,
            'as': 'AS20057 Example',
            'hosting': false,
            'mobile': false,
            'proxy': false,
            'city': 'Los Angeles',
            'regionName': 'California',
          },
          'ipinfo' => {
            'ip': ip,
            'country': 'US',
            'loc': '34.0522,-118.2437',
            'org': 'AS20057 Example',
            'city': 'Los Angeles',
            'region': 'California',
          },
          'ip.sb' => {
            'ip': ip,
            'country_code': 'US',
            'latitude': 34.0,
            'longitude': -118.0,
            'asn': 20057,
            'city': 'Los Angeles',
            'region': 'California',
          },
          _ => null,
        };
      },
    );
    final result = await service.lookup(
      ip: '1.2.3.4',
      proxyName: 'US-01',
      entryServer: 'entry.example',
      wafPass: true,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(result?.city, 'Los Angeles');
    expect(result?.adminRegion, 'California');
    expect(result?.geoConfidence, 0.9);
    expect(result?.asnConfidence, 0.9);
  });

  test('service returns null when every source fails', () async {
    final service = GeoIpService(
      cache: GeoIpCache(),
      keyPools: const {},
      fetcher: (ip, key, sourceId) async => null,
    );
    final result = await service.lookup(
      ip: '9.9.9.9',
      proxyName: 'X-01',
      entryServer: 'entry.example',
      wafPass: true,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    expect(result, isNull);
  });
}
