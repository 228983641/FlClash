import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/candidate_decision.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache meta(
  String name,
  String country,
  double purity, {
  String asn = 'AS100',
  String ip = '1.2.3.4',
  bool waf = true,
  String? city,
  String? adminRegion,
  double? geoConfidence,
  double lat = 35.0,
  double lon = 139.0,
}) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: '',
    egressIp: ip,
    countryCode: country,
    latitude: lat,
    longitude: lon,
    asn: asn,
    ipType: 'residential',
    fraudScore: 0,
    purityScore: purity,
    wafPass: waf,
    updatedAt: 0,
    city: city,
    adminRegion: adminRegion,
    geoConfidence: geoConfidence,
  );
}

ServiceAccessResult verdict(
  String proxy,
  ServiceAccessReason reason, {
  String? borrowedFrom,
  bool stale = false,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return ServiceAccessResult(
    serviceId: 'claude',
    proxyName: proxy,
    egressIp: '1.2.3.4',
    reason: reason,
    checkedAt: stale ? now - 25 * 3600 * 1000 : now,
    borrowedFrom: borrowedFrom,
  );
}

ServiceAnchor anchorFrom(NodeMetadataCache node) {
  return ServiceAnchor(
    serviceTag: 'claude',
    countryCode: node.countryCode,
    lastProxyName: node.proxyName,
    egressIp: node.egressIp,
    subnet24: node.egressIp.split('.').take(3).join('.'),
    asn: node.asn,
    isp: '',
    latitude: node.latitude,
    longitude: node.longitude,
    city: node.city ?? '',
    confirmedAt: 0,
  );
}

CandidateDecisionInput buildInput({
  ServiceRestrictionMode mode = ServiceRestrictionMode.relaxed,
  List<String> lock = const ['TW'],
  required List<String> names,
  Map<String, NodeMetadataCache> metadata = const {},
  Map<String, ServiceAccessResult> access = const {},
  Map<String, int> delays = const {},
  Set<String> banned = const {},
  Set<String>? allowed,
  List<String> adjacent = const [],
  String? current,
  ServiceAnchor? anchor,
  bool outage = false,
}) {
  return CandidateDecisionInput(
    serviceId: 'claude',
    restrictionMode: mode,
    lockedCountries: lock,
    candidateNames: names,
    metadataByProxy: metadata,
    accessByProxy: access,
    delays: delays,
    regionBannedCountries: banned,
    regionAllowedCountries: allowed,
    adjacentCountries: adjacent,
    currentName: current,
    anchor: anchor,
    serviceOutageSuspected: outage,
  );
}

void main() {
  group('qualification', () {
    test('strict rejects unknown-country candidates outright', () {
      final decision = decideCandidates(
        buildInput(
          mode: ServiceRestrictionMode.strict,
          names: ['TW-1', 'mystery'],
          metadata: {'TW-1': meta('TW-1', 'TW', 90)},
          delays: {'mystery': 5, 'TW-1': 500},
        ),
      );
      expect(
        decision.assessments['mystery']!.rejection,
        CandidateRejection.unknownCountryStrict,
      );
      expect(decision.blocked, contains('mystery'));
      expect(decision.fallback, isEmpty);
      expect(decision.qualified, ['TW-1']);
      expect(decision.target, 'TW-1');
    });

    test('relaxed parks unknown candidates in the L7 fallback pool', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-1', 'mystery'],
          metadata: {'TW-1': meta('TW-1', 'TW', 90)},
          delays: {'mystery': 5, 'TW-1': 500},
        ),
      );
      expect(decision.fallback, ['mystery']);
      expect(decision.assessments['mystery']!.tier, RouteTier.l7);
      expect(decision.qualified, ['TW-1']);
      expect(decision.target, 'TW-1');
      expect(decision.tier, isNot(RouteTier.l7));
    });

    test('relaxed uses the fallback only when nothing qualifies', () {
      final decision = decideCandidates(
        buildInput(
          names: ['US-1', 'mystery'],
          metadata: {'US-1': meta('US-1', 'US', 90)},
        ),
      );
      expect(
        decision.assessments['US-1']!.rejection,
        CandidateRejection.outsideLock,
      );
      expect(decision.qualified, isEmpty);
      expect(decision.target, 'mystery');
      expect(decision.tier, RouteTier.l7);
    });

    test('strict returns no target when nothing qualifies', () {
      final decision = decideCandidates(
        buildInput(
          mode: ServiceRestrictionMode.strict,
          names: ['US-1', 'mystery'],
          metadata: {'US-1': meta('US-1', 'US', 90)},
        ),
      );
      expect(decision.qualified, isEmpty);
      expect(decision.fallback, isEmpty);
      expect(decision.target, isNull);
      expect(decision.tier, isNull);
    });

    test('an unknown current node is kept when nothing qualifies', () {
      final decision = decideCandidates(
        buildInput(
          names: ['other-unknown', 'mystery'],
          metadata: const {},
          current: 'mystery',
        ),
      );
      expect(decision.currentUnknown, isTrue);
      expect(decision.fallback, ['mystery', 'other-unknown']);
      expect(decision.target, 'mystery');
      expect(decision.tier, RouteTier.l7);
    });

    test('hard checks reject with specific reasons', () {
      final names = [
        'no-egress',
        'waf',
        'low-purity',
        'verdict',
        'borrowed-verdict',
        'stale-verdict',
        'out-of-lock',
        'clean',
      ];
      final decision = decideCandidates(
        buildInput(
          names: names,
          metadata: {
            'no-egress': meta('no-egress', 'TW', 90, ip: ''),
            'waf': meta('waf', 'TW', 90, waf: false),
            'low-purity': meta('low-purity', 'TW', 49),
            'verdict': meta('verdict', 'TW', 90),
            'borrowed-verdict': meta('borrowed-verdict', 'TW', 90),
            'stale-verdict': meta('stale-verdict', 'TW', 90),
            'out-of-lock': meta('out-of-lock', 'US', 90),
            'clean': meta('clean', 'TW', 90),
          },
          access: {
            'verdict': verdict('verdict', ServiceAccessReason.regionBlocked),
            'borrowed-verdict': verdict(
              'borrowed-verdict',
              ServiceAccessReason.ispBlocked,
              borrowedFrom: 'gemini',
            ),
            'stale-verdict': verdict(
              'stale-verdict',
              ServiceAccessReason.regionBlocked,
              stale: true,
            ),
          },
        ),
      );
      CandidateRejection? reason(String name) =>
          decision.assessments[name]!.rejection;
      expect(reason('no-egress'), CandidateRejection.missingEgress);
      expect(reason('waf'), CandidateRejection.wafFailed);
      expect(reason('low-purity'), CandidateRejection.purityBelowThreshold);
      expect(reason('verdict'), CandidateRejection.accessBlocked);
      expect(reason('borrowed-verdict'), CandidateRejection.accessBlocked);
      expect(reason('out-of-lock'), CandidateRejection.outsideLock);
      expect(reason('stale-verdict'), isNull);
      expect(decision.qualified, containsAll(['stale-verdict', 'clean']));
      expect(decision.rejectionCounts[CandidateRejection.accessBlocked], 2);
    });

    test('region blacklist and whitelist reject with regionExcluded', () {
      final bannedDecision = decideCandidates(
        buildInput(
          lock: const [],
          names: ['HK-1', 'US-1'],
          metadata: {
            'HK-1': meta('HK-1', 'HK', 90),
            'US-1': meta('US-1', 'US', 90),
          },
          banned: {'HK'},
        ),
      );
      expect(
        bannedDecision.assessments['HK-1']!.rejection,
        CandidateRejection.regionExcluded,
      );
      expect(bannedDecision.qualified, ['US-1']);

      final whitelistDecision = decideCandidates(
        buildInput(
          lock: const [],
          names: ['JP-1', 'US-1'],
          metadata: {
            'JP-1': meta('JP-1', 'JP', 90),
            'US-1': meta('US-1', 'US', 90),
          },
          allowed: {'US'},
        ),
      );
      expect(
        whitelistDecision.assessments['JP-1']!.rejection,
        CandidateRejection.regionExcluded,
      );
      expect(whitelistDecision.qualified, ['US-1']);
    });

    test('unrestricted mode allows any known country', () {
      final decision = decideCandidates(
        buildInput(
          mode: ServiceRestrictionMode.unrestricted,
          lock: const [],
          names: ['US-1', 'JP-1', 'mystery'],
          metadata: {
            'US-1': meta('US-1', 'US', 90),
            'JP-1': meta('JP-1', 'JP', 90),
          },
        ),
      );
      expect(decision.qualified, containsAll(['US-1', 'JP-1']));
      expect(decision.fallback, ['mystery']);
      expect(decision.blocked, isEmpty);
    });
  });

  group('current node and L0', () {
    test('a healthy current node is kept over a faster candidate', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-cur', 'TW-fast'],
          metadata: {
            'TW-cur': meta('TW-cur', 'TW', 80, ip: '1.2.3.4'),
            'TW-fast': meta('TW-fast', 'TW', 100, ip: '9.9.9.9'),
          },
          delays: {'TW-cur': 300, 'TW-fast': 10},
          current: 'TW-cur',
        ),
      );
      expect(decision.target, 'TW-cur');
      expect(decision.tier, RouteTier.l0);
      expect(decision.assessments['TW-cur']!.tier, RouteTier.l0);
      expect(decision.qualified.first, 'TW-cur');
    });

    test('a current node with a fresh blocking verdict loses L0', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-cur', 'TW-1'],
          metadata: {
            'TW-cur': meta('TW-cur', 'TW', 90),
            'TW-1': meta('TW-1', 'TW', 90),
          },
          access: {
            'TW-cur': verdict('TW-cur', ServiceAccessReason.regionBlocked),
          },
          current: 'TW-cur',
        ),
      );
      expect(
        decision.assessments['TW-cur']!.rejection,
        CandidateRejection.accessBlocked,
      );
      expect(decision.target, 'TW-1');
    });

    test('purity hysteresis keeps a current node inside the band', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-cur', 'TW-best'],
          metadata: {
            'TW-cur': meta('TW-cur', 'TW', 42),
            'TW-best': meta('TW-best', 'TW', 100),
          },
          current: 'TW-cur',
        ),
      );
      final current = decision.assessments['TW-cur']!;
      expect(current.rejection, isNull);
      expect(current.retainedByHysteresis, isTrue);
      expect(current.tier, RouteTier.l0);
      expect(decision.target, 'TW-cur');
    });

    test('hysteresis does not apply to non-current candidates', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-cur', 'TW-mid'],
          metadata: {
            'TW-cur': meta('TW-cur', 'TW', 90),
            'TW-mid': meta('TW-mid', 'TW', 42),
          },
          current: 'TW-cur',
        ),
      );
      expect(
        decision.assessments['TW-mid']!.rejection,
        CandidateRejection.purityBelowThreshold,
      );
      expect(decision.assessments['TW-mid']!.retainedByHysteresis, isFalse);
    });

    test('hysteresis does not keep a current node below the floor', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-cur', 'TW-1'],
          metadata: {
            'TW-cur': meta('TW-cur', 'TW', 30),
            'TW-1': meta('TW-1', 'TW', 90),
          },
          current: 'TW-cur',
        ),
      );
      expect(
        decision.assessments['TW-cur']!.rejection,
        CandidateRejection.purityBelowThreshold,
      );
      expect(decision.target, 'TW-1');
    });

    test('hysteresis does not excuse a lock violation', () {
      final decision = decideCandidates(
        buildInput(
          names: ['US-cur', 'TW-1'],
          metadata: {
            'US-cur': meta('US-cur', 'US', 42),
            'TW-1': meta('TW-1', 'TW', 90),
          },
          current: 'US-cur',
        ),
      );
      expect(
        decision.assessments['US-cur']!.rejection,
        CandidateRejection.outsideLock,
      );
      expect(decision.assessments['US-cur']!.retainedByHysteresis, isFalse);
      expect(decision.target, 'TW-1');
    });
  });

  group('route tiers', () {
    test('tier order beats in-tier score: L1 before L3 before L4', () {
      final decision = decideCandidates(
        buildInput(
          lock: const ['JP'],
          names: ['JP-cur', 'JP-far', 'JP-asn', 'JP-24'],
          metadata: {
            'JP-cur': meta('JP-cur', 'JP', 90, ip: '10.0.0.5'),
            'JP-24': meta('JP-24', 'JP', 55, asn: 'AS200', ip: '10.0.0.9'),
            'JP-asn': meta('JP-asn', 'JP', 60, asn: 'AS100', ip: '10.9.0.1'),
            'JP-far': meta('JP-far', 'JP', 100, asn: 'AS300', ip: '10.8.0.1'),
          },
          access: {
            'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
          },
          delays: {'JP-24': 900, 'JP-asn': 800, 'JP-far': 10},
          current: 'JP-cur',
        ),
      );
      expect(decision.qualified, ['JP-24', 'JP-asn', 'JP-far']);
      expect(decision.target, 'JP-24');
      expect(decision.tier, RouteTier.l1);
      expect(decision.assessments['JP-asn']!.tier, RouteTier.l3);
      expect(decision.assessments['JP-far']!.tier, RouteTier.l4);
      expect(decision.countsByTier[RouteTier.l1], 1);
      expect(decision.countsByTier[RouteTier.l3], 1);
      expect(decision.countsByTier[RouteTier.l4], 1);
    });

    test('same country beats another allowed country at any score', () {
      final decision = decideCandidates(
        buildInput(
          lock: const ['JP', 'US'],
          names: ['JP-cur', 'US-fast', 'JP-plain'],
          metadata: {
            'JP-cur': meta('JP-cur', 'JP', 90, ip: '10.0.0.5'),
            'JP-plain': meta(
              'JP-plain',
              'JP',
              55,
              asn: 'AS300',
              ip: '10.8.0.1',
            ),
            'US-fast': meta('US-fast', 'US', 100, asn: 'AS400', ip: '8.8.8.8'),
          },
          access: {
            'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
          },
          delays: {'JP-plain': 900, 'US-fast': 10},
          current: 'JP-cur',
        ),
      );
      expect(decision.target, 'JP-plain');
      expect(decision.tier, RouteTier.l4);
      expect(decision.assessments['US-fast']!.tier, RouteTier.l6);
      expect(decision.qualified, ['JP-plain', 'US-fast']);
    });

    test('the city tier needs geo confidence on the candidate', () {
      final decision = decideCandidates(
        buildInput(
          lock: const ['JP'],
          names: ['JP-cur', 'JP-nocity', 'JP-city-lowconf', 'JP-city'],
          metadata: {
            'JP-cur': meta(
              'JP-cur',
              'JP',
              90,
              ip: '10.0.0.5',
              city: 'Osaka',
              adminRegion: 'Osaka',
              geoConfidence: 0.9,
            ),
            'JP-city': meta(
              'JP-city',
              'JP',
              80,
              asn: 'AS200',
              ip: '10.9.0.1',
              city: 'Osaka',
              adminRegion: 'Osaka',
              geoConfidence: 0.95,
            ),
            'JP-city-lowconf': meta(
              'JP-city-lowconf',
              'JP',
              80,
              asn: 'AS100',
              ip: '10.9.0.2',
              city: 'Osaka',
              adminRegion: 'Osaka',
              geoConfidence: 0.3,
            ),
            'JP-nocity': meta(
              'JP-nocity',
              'JP',
              80,
              asn: 'AS300',
              ip: '10.9.0.3',
            ),
          },
          access: {
            'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
          },
          current: 'JP-cur',
        ),
      );
      expect(decision.assessments['JP-city']!.tier, RouteTier.l2);
      expect(decision.assessments['JP-city-lowconf']!.tier, RouteTier.l3);
      expect(decision.assessments['JP-nocity']!.tier, RouteTier.l4);
      expect(decision.target, 'JP-city');
      expect(decision.tier, RouteTier.l2);
    });

    test('adjacent countries form L5 only when the table lists them', () {
      CandidateDecision decide(List<String> adjacent) => decideCandidates(
        buildInput(
          lock: const ['JP', 'KR', 'US'],
          names: ['JP-cur', 'KR-1', 'US-1'],
          metadata: {
            'JP-cur': meta('JP-cur', 'JP', 90, ip: '10.0.0.5'),
            'KR-1': meta('KR-1', 'KR', 80, asn: 'AS200', ip: '10.9.0.1'),
            'US-1': meta('US-1', 'US', 100, asn: 'AS300', ip: '8.8.8.8'),
          },
          access: {
            'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
          },
          adjacent: adjacent,
          current: 'JP-cur',
        ),
      );
      final withTable = decide(const ['KR']);
      expect(withTable.assessments['KR-1']!.tier, RouteTier.l5);
      expect(withTable.assessments['US-1']!.tier, RouteTier.l6);
      expect(withTable.target, 'KR-1');

      final withoutTable = decide(const []);
      expect(withoutTable.assessments['KR-1']!.tier, RouteTier.l6);
    });

    test('ASN only raises priority inside the same country', () {
      final decision = decideCandidates(
        buildInput(
          lock: const ['JP', 'US'],
          names: ['JP-cur', 'US-sameasn', 'JP-diffasn'],
          metadata: {
            'JP-cur': meta('JP-cur', 'JP', 90, asn: 'AS100', ip: '10.0.0.5'),
            'US-sameasn': meta(
              'US-sameasn',
              'US',
              100,
              asn: 'AS100',
              ip: '8.8.8.8',
            ),
            'JP-diffasn': meta(
              'JP-diffasn',
              'JP',
              60,
              asn: 'AS999',
              ip: '10.9.0.1',
            ),
          },
          access: {
            'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
          },
          current: 'JP-cur',
        ),
      );
      expect(decision.assessments['US-sameasn']!.tier, RouteTier.l6);
      expect(decision.assessments['JP-diffasn']!.tier, RouteTier.l4);
      expect(decision.qualified, ['JP-diffasn', 'US-sameasn']);
    });

    test('with no reference, known candidates land in L6', () {
      final decision = decideCandidates(
        buildInput(
          lock: const ['US'],
          names: ['US-1', 'US-2'],
          metadata: {
            'US-1': meta('US-1', 'US', 100),
            'US-2': meta('US-2', 'US', 60),
          },
          delays: {'US-1': 100, 'US-2': 10},
        ),
      );
      expect(decision.assessments['US-1']!.tier, RouteTier.l6);
      expect(decision.assessments['US-2']!.tier, RouteTier.l6);
      expect(decision.target, 'US-1');
    });
  });

  group('in-tier scoring consistency', () {
    test('same-tier order matches rankForService on the same inputs', () {
      final anchorNode = meta('anchor-node', 'JP', 90, ip: '1.2.3.4');
      final anchor = anchorFrom(anchorNode);
      final candidates = [
        meta('A', 'JP', 90, ip: '5.5.5.1', lat: 35.7, lon: 139.7),
        meta('B', 'JP', 70, ip: '5.5.5.2'),
        meta('C', 'JP', 95, ip: '5.5.5.3'),
      ];
      final access = <String, ServiceAccessResult>{
        'B': verdict('B', ServiceAccessReason.accessible),
      };
      final delays = {'A': 50, 'B': 20, 'C': 400};
      final legacy = ScoringEngine.rankForService(
        candidates,
        anchor,
        const ['JP'],
        access,
        delays: delays,
      ).map((node) => node.proxyName).toList();
      final decision = decideCandidates(
        buildInput(
          lock: const ['JP'],
          names: ['A', 'B', 'C'],
          metadata: {for (final node in candidates) node.proxyName: node},
          access: access,
          delays: delays,
          anchor: anchor,
        ),
      );
      expect(decision.qualified, legacy);
      expect(decision.qualified, ['B', 'A', 'C']);
      expect(
        decision.assessments.values.every((a) => a.tier == RouteTier.l3),
        isTrue,
      );
    });

    test('tier split deliberately diverges from the legacy total score', () {
      final cur = meta('JP-cur', 'JP', 90, asn: 'AS100', ip: '10.0.0.5');
      final sameAsn = meta(
        'JP-sameasn',
        'JP',
        55,
        asn: 'AS100',
        ip: '10.9.0.1',
      );
      final diffAsn = meta(
        'JP-diffasn',
        'JP',
        100,
        asn: 'AS999',
        ip: '10.8.0.1',
      );
      final delays = {'JP-sameasn': 900, 'JP-diffasn': 10};
      final legacy = ScoringEngine.rankForService(
        [sameAsn, diffAsn],
        anchorFrom(cur),
        const ['JP'],
        const {},
        delays: delays,
      ).map((node) => node.proxyName).toList();
      // The legacy total score prefers the fast, pure node across what
      // the redesign treats as a tier boundary.
      expect(legacy, ['JP-diffasn', 'JP-sameasn']);

      final decision = decideCandidates(
        buildInput(
          lock: const ['JP'],
          names: ['JP-cur', 'JP-diffasn', 'JP-sameasn'],
          metadata: {
            'JP-cur': cur,
            'JP-sameasn': sameAsn,
            'JP-diffasn': diffAsn,
          },
          access: {
            'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
          },
          delays: delays,
          current: 'JP-cur',
        ),
      );
      expect(decision.qualified, ['JP-sameasn', 'JP-diffasn']);
      expect(decision.target, 'JP-sameasn');
      expect(decision.tier, RouteTier.l3);
    });
  });

  group('decision shape', () {
    test('counts, explanation and evidence snapshot are carried', () {
      final access = <String, ServiceAccessResult>{
        'JP-cur': verdict('JP-cur', ServiceAccessReason.regionBlocked),
      };
      final decision = decideCandidates(
        buildInput(
          lock: const ['JP'],
          names: ['JP-cur', 'JP-24', 'mystery', 'US-out'],
          metadata: {
            'JP-cur': meta('JP-cur', 'JP', 90, ip: '10.0.0.5'),
            'JP-24': meta('JP-24', 'JP', 80, asn: 'AS200', ip: '10.0.0.9'),
            'US-out': meta('US-out', 'US', 90),
          },
          access: access,
          current: 'JP-cur',
        ),
      );
      var tierTotal = 0;
      decision.countsByTier.forEach((_, count) => tierTotal += count);
      expect(tierTotal, decision.qualified.length + decision.fallback.length);
      var rejectionTotal = 0;
      decision.rejectionCounts.forEach((_, count) => rejectionTotal += count);
      expect(rejectionTotal, decision.blocked.length);
      expect(decision.blocked, containsAll(['JP-cur', 'US-out']));
      expect(decision.ordered, [...decision.qualified, ...decision.fallback]);
      expect(decision.explanation, contains('JP-24'));
      expect(decision.explanation, contains('L1'));
      expect(decision.evidence, same(access));
      expect(decision.currentUnknown, isFalse);
    });

    test('the outage flag passes through without suppressing the target', () {
      final decision = decideCandidates(
        buildInput(
          names: ['TW-1'],
          metadata: {'TW-1': meta('TW-1', 'TW', 90)},
          outage: true,
        ),
      );
      expect(decision.hasServiceOutage, isTrue);
      expect(decision.target, 'TW-1');
    });

    test('an empty pool yields no target', () {
      final decision = decideCandidates(buildInput(names: const []));
      expect(decision.target, isNull);
      expect(decision.tier, isNull);
      expect(decision.ordered, isEmpty);
    });
  });

  group('adapter', () {
    const gemini = ServiceToggleConfig(
      serviceId: 'gemini',
      displayName: 'Gemini',
      isEnabled: true,
      targetCountry: '',
      matchRules: [],
      dnsDomains: [],
    );

    test('the gated derived region set excludes the whole country', () {
      final input = SmartAnchorInput(
        services: [gemini],
        metadataByProxy: {
          'HK-1': meta('HK-1', 'HK', 90, asn: 'AS100'),
          'HK-2': meta('HK-2', 'HK', 90, asn: 'AS200'),
          'HK-3': meta('HK-3', 'HK', 90, asn: 'AS300'),
          'US-1': meta('US-1', 'US', 90),
        },
        accessByService: {
          'gemini': {
            'HK-1': ServiceAccessResult(
              serviceId: 'gemini',
              proxyName: 'HK-1',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.regionBlocked,
              checkedAt: DateTime.now().millisecondsSinceEpoch,
            ),
            'HK-2': ServiceAccessResult(
              serviceId: 'gemini',
              proxyName: 'HK-2',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.regionBlocked,
              checkedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          },
        },
      );
      final decision = decideForService(input, gemini, [
        'HK-1',
        'HK-2',
        'HK-3',
        'US-1',
      ]);
      expect(
        decision.assessments['HK-3']!.rejection,
        CandidateRejection.regionExcluded,
      );
      expect(decision.qualified, ['US-1']);
      expect(decision.target, 'US-1');
    });

    test('a single region verdict does not ban its country', () {
      final input = SmartAnchorInput(
        services: [gemini],
        metadataByProxy: {
          'HK-1': meta('HK-1', 'HK', 90, asn: 'AS100'),
          'HK-2': meta('HK-2', 'HK', 90, asn: 'AS200'),
        },
        accessByService: {
          'gemini': {
            'HK-1': ServiceAccessResult(
              serviceId: 'gemini',
              proxyName: 'HK-1',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.regionBlocked,
              checkedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          },
        },
      );
      final decision = decideForService(input, gemini, ['HK-1', 'HK-2']);
      expect(
        decision.assessments['HK-1']!.rejection,
        CandidateRejection.accessBlocked,
      );
      expect(decision.assessments['HK-2']!.rejection, isNull);
      expect(decision.qualified, ['HK-2']);
    });

    test(
      'the adapter applies the service lock and keeps a healthy current',
      () {
        const claude = ServiceToggleConfig(
          serviceId: 'claude',
          displayName: 'Claude',
          isEnabled: true,
          targetCountry: 'TW',
          matchRules: [],
          dnsDomains: [],
        );
        final input = SmartAnchorInput(
          services: [claude],
          metadataByProxy: {
            'TW-cur': meta('TW-cur', 'TW', 90),
            'US-1': meta('US-1', 'US', 90),
          },
        );
        final decision = decideForService(input, claude, [
          'TW-cur',
          'US-1',
        ], currentName: 'TW-cur');
        expect(decision.target, 'TW-cur');
        expect(decision.tier, RouteTier.l0);
        expect(
          decision.assessments['US-1']!.rejection,
          CandidateRejection.outsideLock,
        );
      },
    );
  });
}
