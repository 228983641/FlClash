import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/candidate_decision.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

const usStrict = ServiceToggleConfig(
  serviceId: 'claude',
  displayName: 'Claude',
  isEnabled: true,
  targetCountry: 'US',
  targetCountries: ['US'],
  matchRules: [],
  dnsDomains: [],
  restrictionMode: ServiceRestrictionMode.strict,
);

const usRelaxed = ServiceToggleConfig(
  serviceId: 'claude',
  displayName: 'Claude',
  isEnabled: true,
  targetCountry: 'US',
  targetCountries: ['US'],
  matchRules: [],
  dnsDomains: [],
  restrictionMode: ServiceRestrictionMode.relaxed,
);

const multiCountryStrict = ServiceToggleConfig(
  serviceId: 'claude',
  displayName: 'Claude',
  isEnabled: true,
  targetCountry: 'US',
  targetCountries: ['US', 'JP'],
  matchRules: [],
  dnsDomains: [],
  restrictionMode: ServiceRestrictionMode.strict,
);

const anchor = ServiceAnchor(
  serviceTag: 'claude',
  countryCode: 'US',
  lastProxyName: 'current',
  egressIp: '10.0.0.1',
  subnet24: '10.0.0',
  asn: 'AS-US',
  isp: 'Example',
  latitude: 34.0522,
  longitude: -118.2437,
  city: 'Los Angeles',
  confirmedAt: 0,
);

NodeMetadataCache node(
  String name, {
  String country = 'US',
  String egressIp = '20.0.0.1',
  String asn = 'AS-OTHER',
  String? city = 'San Francisco',
  String? adminRegion = 'California',
  double? geoConfidence = 0.95,
  double latitude = 37.7749,
  double longitude = -122.4194,
  double purity = 90,
  bool wafPass = true,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: egressIp,
    countryCode: country,
    latitude: latitude,
    longitude: longitude,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: wafPass,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    city: city,
    adminRegion: adminRegion,
    geoConfidence: geoConfidence,
    asnConfidence: 0.9,
  );
}

ServiceAccessResult blocked(String name) {
  return ServiceAccessResult(
    serviceId: 'claude',
    proxyName: name,
    egressIp: '20.0.0.1',
    reason: ServiceAccessReason.regionBlocked,
    checkedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  test('unknown-country fallback cannot bypass fresh blocking evidence', () {
    final decision = buildCandidateDecision(
      service: usRelaxed,
      proxyNames: const ['unknown'],
      metadataByProxy: const {},
      accessByProxy: {'unknown': blocked('unknown')},
    );
    expect(decision.ordered, isEmpty);
    expect(
      decision.blockedReasons['unknown'],
      CandidateBlockReason.serviceBlocked,
    );
  });

  test('an old exit verdict does not condemn a newly measured exit', () {
    final decision = buildCandidateDecision(
      service: usStrict,
      proxyNames: const ['changed'],
      metadataByProxy: {'changed': node('changed', egressIp: '30.0.0.1')},
      accessByProxy: {'changed': blocked('changed')},
    );
    expect(decision.qualified, ['changed']);
  });

  test('expired geography is unknown under a strict lock', () {
    final expired = NodeMetadataCache.fromJson({
      ...node('expired').toJson(),
      'updatedAt': 0,
    });
    final decision = buildCandidateDecision(
      service: usStrict,
      proxyNames: const ['expired'],
      metadataByProxy: {'expired': expired},
      accessByProxy: const {},
    );
    expect(decision.qualified, isEmpty);
  });

  test(
    'strict mode blocks an unknown-country node instead of using fallback',
    () {
      final decision = buildCandidateDecision(
        service: usStrict,
        proxyNames: const ['known', 'unknown'],
        metadataByProxy: {'known': node('known')},
        accessByProxy: const {},
        anchor: anchor,
      );

      expect(decision.qualified, ['known']);
      expect(decision.fallback, isEmpty);
      expect(decision.blocked, ['unknown']);
      expect(
        decision.blockedReasons['unknown'],
        CandidateBlockReason.unknownCountry,
      );
    },
  );

  test(
    'relaxed mode keeps an unknown-country node as an explicit fallback',
    () {
      final decision = buildCandidateDecision(
        service: usRelaxed,
        proxyNames: const ['unknown', 'known'],
        metadataByProxy: {'known': node('known')},
        accessByProxy: const {},
        anchor: anchor,
      );

      expect(decision.qualified, ['known']);
      expect(decision.fallback, ['unknown']);
      expect(decision.ordered, ['known', 'unknown']);
    },
  );

  test(
    'a compliant current node stays selected despite a faster candidate',
    () {
      final decision = buildCandidateDecision(
        service: usStrict,
        proxyNames: const ['current', 'faster'],
        metadataByProxy: {
          'current': node(
            'current',
            egressIp: '10.0.0.1',
            asn: 'AS-US',
            city: 'Los Angeles',
            latitude: 34.0522,
            longitude: -118.2437,
          ),
          'faster': node(
            'faster',
            city: 'New York',
            adminRegion: 'New York',
            latitude: 40.7128,
            longitude: -74.0060,
          ),
        },
        accessByProxy: const {},
        anchor: anchor,
        currentName: 'current',
        delays: const {'current': 900, 'faster': 30},
      );

      expect(decision.currentCompliant, isTrue);
      expect(decision.target, isNull);
    },
  );

  test('route tier wins over delay when the current node must move', () {
    final decision = buildCandidateDecision(
      service: usStrict,
      proxyNames: const ['current', 'same-city', 'same-asn', 'fast-far'],
      metadataByProxy: {
        'current': node('current', country: 'TW'),
        'same-city': node(
          'same-city',
          city: 'Los Angeles',
          adminRegion: 'California',
          latitude: 34.05,
          longitude: -118.24,
        ),
        'same-asn': node(
          'same-asn',
          asn: 'AS-US',
          city: 'Seattle',
          adminRegion: 'Washington',
          latitude: 47.6062,
          longitude: -122.3321,
        ),
        'fast-far': node(
          'fast-far',
          city: 'New York',
          adminRegion: 'New York',
          latitude: 40.7128,
          longitude: -74.0060,
        ),
      },
      accessByProxy: const {},
      anchor: anchor,
      currentName: 'current',
      delays: const {'same-city': 800, 'same-asn': 100, 'fast-far': 20},
    );

    expect(decision.qualified, ['same-city', 'same-asn', 'fast-far']);
    expect(decision.target, 'same-city');
    expect(decision.tierByProxy['same-city'], CandidateRouteTier.sameCity);
  });

  test('the same ASN in another country never becomes a same-country tier', () {
    final decision = buildCandidateDecision(
      service: multiCountryStrict,
      proxyNames: const ['jp-same-asn', 'us-other-asn'],
      metadataByProxy: {
        'jp-same-asn': node(
          'jp-same-asn',
          country: 'JP',
          asn: 'AS-US',
          city: 'Tokyo',
          adminRegion: 'Tokyo',
          latitude: 35.6762,
          longitude: 139.6503,
        ),
        'us-other-asn': node(
          'us-other-asn',
          city: 'New York',
          adminRegion: 'New York',
          latitude: 40.7128,
          longitude: -74.0060,
        ),
      },
      accessByProxy: const {},
      anchor: anchor,
      delays: const {'jp-same-asn': 10, 'us-other-asn': 500},
    );

    expect(decision.qualified, ['us-other-asn', 'jp-same-asn']);
    expect(
      decision.tierByProxy['jp-same-asn'],
      CandidateRouteTier.otherAllowedCountry,
    );
  });

  test('fresh service blocking evidence excludes only the affected node', () {
    final decision = buildCandidateDecision(
      service: usStrict,
      proxyNames: const ['blocked', 'working'],
      metadataByProxy: {'blocked': node('blocked'), 'working': node('working')},
      accessByProxy: {'blocked': blocked('blocked')},
      anchor: anchor,
    );

    expect(decision.qualified, ['working']);
    expect(decision.blocked, ['blocked']);
    expect(
      decision.blockedReasons['blocked'],
      CandidateBlockReason.serviceBlocked,
    );
  });

  test('strict mode returns no target when no compliant node exists', () {
    final decision = buildCandidateDecision(
      service: usStrict,
      proxyNames: const ['tw', 'unknown'],
      metadataByProxy: {'tw': node('tw', country: 'TW')},
      accessByProxy: const {},
      anchor: anchor,
      currentName: 'tw',
    );

    expect(decision.qualified, isEmpty);
    expect(decision.fallback, isEmpty);
    expect(decision.target, isNull);
  });
}
