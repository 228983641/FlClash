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
    expect(calls, 4);
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
