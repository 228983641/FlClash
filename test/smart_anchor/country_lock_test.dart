import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/country_lock.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache node(String country) {
  return NodeMetadataCache(
    proxyName: '$country-01',
    entryServer: 'entry.example',
    egressIp: '1.2.3.4',
    countryCode: country,
    latitude: 34.0,
    longitude: -118.0,
    asn: 'AS20057',
    ipType: 'residential',
    fraudScore: 0,
    purityScore: 90,
    wafPass: true,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  test('empty lock passes every country, single lock passes only itself', () {
    expect(CountryLock.passes('US', []), true);
    expect(CountryLock.passes('SG', []), true);
    expect(CountryLock.passes('US', ['US']), true);
    expect(CountryLock.passes('SG', ['US']), false);
    expect(CountryLock.normalize([' us ', 'US', 'sg']), ['US', 'SG']);
  });

  test('hard filter follows the user lock, not the anchor country', () {
    final nodes = [node('US'), node('SG'), node('JP')];
    expect(
      ScoringEngine.filterForTarget(nodes, []).map((n) => n.countryCode),
      ['US', 'SG', 'JP'],
    );
    expect(
      ScoringEngine.filterForTarget(nodes, ['SG']).map((n) => n.countryCode),
      ['SG'],
    );
    expect(
      ScoringEngine.passesHardFilterForTarget(node('SG'), ['US']),
      false,
    );
    expect(ScoringEngine.passesHardFilter(node('US'), 'US'), true);
  });

  test('toggle config exposes an empty lock for a blank country', () {
    const config = ServiceToggleConfig(
      serviceId: 'claude',
      displayName: 'Claude',
      isEnabled: true,
      targetCountry: '',
      matchRules: [],
      dnsDomains: [],
    );
    expect(config.lockedCountries, isEmpty);
    expect(CountryLock.description(config.lockedCountries), contains('不限国家'));
    expect(CountryLock.description(['US']), contains('单国锁'));
    expect(
      CountryLock.description(['US']),
      contains('改锁国会清空旧锚点'),
    );
  });

  test('toggle config reads a stored country list', () {
    final config = ServiceToggleConfig.fromJson({
      'serviceId': 'claude',
      'displayName': 'Claude',
      'isEnabled': true,
      'targetCountry': 'US',
      'targetCountries': ['SG'],
      'matchRules': <String>[],
      'dnsDomains': <String>[],
    });
    expect(config.lockedCountries, ['SG']);
  });
}
