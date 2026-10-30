import '../models/node_metadata.dart';
import '../models/service_anchor.dart';
import '../models/service_toggle_config.dart';
import 'profile_wiring.dart';
import 'scoring_engine.dart';
import 'service_access.dart';

/// Minimum geo confidence for a candidate (and, when the reference is a
/// probed node, for the reference too) before city / admin-region
/// equality may place it in the L2 route tier. Below this the node's
/// sub-country geography is treated as unknown and it falls back to the
/// country tiers, per the geo-confidence rule in the redesign spec.
const double candidateCityTierMinGeoConfidence = 0.8;

/// Route tiers in strict precedence order: a candidate in an earlier
/// tier is always preferred over every candidate in a later tier, and
/// the in-tier score only orders candidates inside one tier.
enum RouteTier { l0, l1, l2, l3, l4, l5, l6, l7 }

extension RouteTierLabel on RouteTier {
  String get label => 'L$index';
}

/// Why a candidate was excluded from every tier. The decider reports the
/// first failing check in a fixed precedence — egress, country lock,
/// region list, WAF, access verdict, purity — so the reason a node was
/// rejected is stable across runs for the same inputs, and a policy
/// violation (the lock) is never masked by a softer signal (purity).
enum CandidateRejection {
  missingEgress,
  outsideLock,
  regionExcluded,
  wafFailed,
  accessBlocked,
  purityBelowThreshold,
  unknownCountryStrict,
}

/// What asked for the decision. Echoed into the result so logs can tell
/// a build-time first pick from a failover without a second channel.
enum CandidateDecisionTrigger {
  initialSelection,
  failure,
  regionRestriction,
  manual,
  recovery,
}

/// Everything [decideCandidates] may look at, as one immutable snapshot.
/// The decider reads no global state and causes no side effects: the
/// same input always produces the same decision.
class CandidateDecisionInput {
  const CandidateDecisionInput({
    required this.serviceId,
    required this.restrictionMode,
    required this.lockedCountries,
    required this.candidateNames,
    required this.metadataByProxy,
    this.accessByProxy = const {},
    this.delays = const {},
    this.regionBannedCountries = const {},
    this.regionAllowedCountries,
    this.adjacentCountries = const [],
    this.currentName,
    this.anchor,
    this.trigger = CandidateDecisionTrigger.initialSelection,
    this.serviceOutageSuspected = false,
  });

  final String serviceId;
  final ServiceRestrictionMode restrictionMode;
  final List<String> lockedCountries;
  final List<String> candidateNames;
  final Map<String, NodeMetadataCache> metadataByProxy;

  /// This service's own access verdicts, keyed by proxy name.
  final Map<String, ServiceAccessResult> accessByProxy;
  final Map<String, int> delays;

  /// Countries the region filter bans for this service (explicit
  /// blacklist entries plus the derived unsupported set, already gated
  /// by the caller or by [decideForService]).
  final Set<String> regionBannedCountries;

  /// Whitelist region filter: when non-null, only these countries pass.
  final Set<String>? regionAllowedCountries;

  /// User-approved adjacent countries for the L5 tier. Empty disables
  /// the tier: adjacency is a policy input, never derived from a map.
  final List<String> adjacentCountries;

  final String? currentName;

  /// The service's remembered anchor, when one exists. Used as the
  /// route reference when the current node has no metadata, and as the
  /// reference point for in-tier proximity scoring.
  final ServiceAnchor? anchor;

  final CandidateDecisionTrigger trigger;

  /// The caller's outage-guard verdict, passed through untouched: the
  /// decider is pure and owns no time-window state of its own.
  final bool serviceOutageSuspected;
}

/// The decider's verdict for one candidate: exactly one of [tier] and
/// [rejection] is non-null.
class CandidateAssessment {
  const CandidateAssessment({
    required this.name,
    required this.score,
    required this.confirmedAccessible,
    required this.retainedByHysteresis,
    this.tier,
    this.rejection,
  });

  final String name;
  final RouteTier? tier;
  final CandidateRejection? rejection;

  /// In-tier score from the shared scoring components; meaningless
  /// across tiers and zero for unknown-country candidates.
  final double score;
  final bool confirmedAccessible;

  /// True only for a current node kept solely because its purity sits
  /// in the hysteresis band while every other check passes.
  final bool retainedByHysteresis;

  bool get isRejected => rejection != null;
}

/// The unified candidate decision the redesign spec asks every consumer
/// (config build, startup recovery, lock compliance, failover, UI) to
/// share. Produced by [decideCandidates]; nothing consumes it yet.
class CandidateDecision {
  const CandidateDecision({
    required this.serviceId,
    required this.qualified,
    required this.fallback,
    required this.blocked,
    required this.ordered,
    required this.target,
    required this.tier,
    required this.trigger,
    required this.currentUnknown,
    required this.hasServiceOutage,
    required this.assessments,
    required this.countsByTier,
    required this.rejectionCounts,
    required this.explanation,
    required this.evidence,
  });

  final String serviceId;

  /// Known-country candidates that passed every hard check, in tier
  /// order and in-tier score order. The current node, when it is kept,
  /// leads the list at tier L0.
  final List<String> qualified;

  /// Unknown-country candidates. Non-empty only outside strict mode:
  /// an emergency pool, selectable only when [qualified] is empty.
  final List<String> fallback;

  /// Rejected candidates, in input order; [assessments] carries each
  /// one's reason.
  final List<String> blocked;

  /// Display order: [qualified] followed by [fallback].
  final List<String> ordered;

  /// The node the current trigger may select: the kept current node,
  /// else the head of [qualified], else the head of [fallback].
  final String? target;

  /// [target]'s route tier, null when there is no target.
  final RouteTier? tier;

  final CandidateDecisionTrigger trigger;

  /// The current selection has no metadata record (or an empty
  /// country), so nothing about its route is known.
  final bool currentUnknown;

  final bool hasServiceOutage;

  final Map<String, CandidateAssessment> assessments;
  final Map<RouteTier, int> countsByTier;
  final Map<CandidateRejection, int> rejectionCounts;

  /// One-line route explanation for logs and debugging.
  final String explanation;

  /// The exact access-evidence snapshot the decision was made from
  /// (the map instance passed in the input, not a copy).
  final Map<String, ServiceAccessResult> evidence;

  bool isCompliant(String name) => qualified.contains(name);
}

Set<String> _countrySet(Iterable<String> countries) {
  return {for (final country in countries) country.trim().toUpperCase()}
    ..remove('');
}

String _subnet24Of(String egressIp) {
  final parts = egressIp.split('.');
  if (parts.length != 4) {
    return '';
  }
  return parts.take(3).join('.');
}

ServiceAnchor _anchorFromMeta(String serviceId, NodeMetadataCache node) {
  return ServiceAnchor(
    serviceTag: serviceId,
    countryCode: node.countryCode,
    lastProxyName: node.proxyName,
    egressIp: node.egressIp,
    subnet24: _subnet24Of(node.egressIp),
    asn: node.asn,
    isp: '',
    latitude: node.latitude,
    longitude: node.longitude,
    city: node.city ?? '',
    confirmedAt: 0,
  );
}

/// The route a decision tries to stay close to: the current node's
/// metadata when it has one, otherwise the remembered anchor. An anchor
/// carries no geo confidence, so a city-tier match against it rests on
/// the candidate's confidence alone.
class _RouteReference {
  const _RouteReference({
    required this.country,
    required this.egressIp,
    required this.subnet24,
    required this.asn,
    required this.city,
    required this.adminRegion,
    required this.geoConfidence,
  });

  final String country;
  final String egressIp;
  final String subnet24;
  final String asn;
  final String? city;
  final String? adminRegion;
  final double? geoConfidence;

  static _RouteReference? of(
    CandidateDecisionInput input,
    NodeMetadataCache? currentMeta,
  ) {
    if (currentMeta != null && currentMeta.countryCode.trim().isNotEmpty) {
      return _RouteReference(
        country: currentMeta.countryCode.trim().toUpperCase(),
        egressIp: currentMeta.egressIp,
        subnet24: _subnet24Of(currentMeta.egressIp),
        asn: currentMeta.asn,
        city: currentMeta.city,
        adminRegion: currentMeta.adminRegion,
        geoConfidence: currentMeta.geoConfidence,
      );
    }
    final anchor = input.anchor;
    if (anchor == null) {
      return null;
    }
    return _RouteReference(
      country: anchor.countryCode.trim().toUpperCase(),
      egressIp: anchor.egressIp,
      subnet24: anchor.subnet24,
      asn: anchor.asn,
      city: anchor.city,
      adminRegion: null,
      geoConfidence: null,
    );
  }
}

/// Every hard check [node] fails, in the precedence
/// [CandidateRejection] documents; an empty list means qualified.
List<CandidateRejection> _failures(
  NodeMetadataCache node,
  ServiceAccessResult? access,
  Set<String> lock,
  Set<String> banned,
  Set<String>? allowed,
) {
  final failures = <CandidateRejection>[];
  if (node.egressIp.isEmpty) {
    failures.add(CandidateRejection.missingEgress);
  }
  final country = node.countryCode.trim().toUpperCase();
  if (lock.isNotEmpty && !lock.contains(country)) {
    failures.add(CandidateRejection.outsideLock);
  }
  if ((allowed != null && !allowed.contains(country)) ||
      banned.contains(country)) {
    failures.add(CandidateRejection.regionExcluded);
  }
  if (!node.wafPass) {
    failures.add(CandidateRejection.wafFailed);
  }
  if (access != null && !access.isExpired && access.blocksRanking) {
    failures.add(CandidateRejection.accessBlocked);
  }
  if (node.purityScore < 50) {
    failures.add(CandidateRejection.purityBelowThreshold);
  }
  return failures;
}

bool _confirmedAccessible(CandidateDecisionInput input, String name) {
  final access = input.accessByProxy[name];
  return access != null &&
      !access.isExpired &&
      access.isAccessible &&
      access.borrowedFrom == null;
}

double _score(
  NodeMetadataCache node,
  CandidateDecisionInput input,
  ServiceAnchor? scoringAnchor,
) {
  final delay = input.delays[node.proxyName];
  if (scoringAnchor != null) {
    return ScoringEngine.priority(node, scoringAnchor, delayMs: delay);
  }
  return ScoringEngine.purityCompressed(node.purityScore) -
      ScoringEngine.delayPenalty(delay);
}

List<String> _sortWithinTier(
  List<String> names,
  CandidateDecisionInput input,
  ServiceAnchor? scoringAnchor,
) {
  if (names.length < 2) {
    return names;
  }
  if (scoringAnchor != null) {
    final nodes = [for (final name in names) input.metadataByProxy[name]!];
    return [
      for (final node in ScoringEngine.rank(
        nodes,
        scoringAnchor,
        delays: input.delays,
      ))
        node.proxyName,
    ];
  }
  final sorted = List<String>.of(names);
  sorted.sort((a, b) {
    final aDelay = input.delays[a];
    final bDelay = input.delays[b];
    if ((aDelay == null) != (bDelay == null)) {
      return aDelay == null ? 1 : -1;
    }
    final byScore = _score(
      input.metadataByProxy[b]!,
      input,
      null,
    ).compareTo(_score(input.metadataByProxy[a]!, input, null));
    if (byScore != 0) {
      return byScore;
    }
    return a.compareTo(b);
  });
  return sorted;
}

bool _cityTier(NodeMetadataCache node, _RouteReference ref) {
  final confidence = node.geoConfidence;
  if (confidence == null || confidence < candidateCityTierMinGeoConfidence) {
    return false;
  }
  final refConfidence = ref.geoConfidence;
  if (refConfidence != null &&
      refConfidence < candidateCityTierMinGeoConfidence) {
    return false;
  }
  bool samePlace(String? a, String? b) {
    final x = (a ?? '').trim().toLowerCase();
    final y = (b ?? '').trim().toLowerCase();
    return x.isNotEmpty && x == y;
  }

  return samePlace(node.city, ref.city) ||
      samePlace(node.adminRegion, ref.adminRegion);
}

RouteTier _tierFor(
  NodeMetadataCache node,
  _RouteReference? ref,
  Set<String> adjacent,
) {
  if (ref == null) {
    return RouteTier.l6;
  }
  if (node.egressIp.isNotEmpty && node.egressIp == ref.egressIp) {
    return RouteTier.l1;
  }
  if (ref.subnet24.isNotEmpty && node.sameSubnet24(ref.subnet24)) {
    return RouteTier.l1;
  }
  final country = node.countryCode.trim().toUpperCase();
  if (country == ref.country) {
    if (_cityTier(node, ref)) {
      return RouteTier.l2;
    }
    if (node.asn.isNotEmpty && node.asn == ref.asn) {
      return RouteTier.l3;
    }
    return RouteTier.l4;
  }
  if (adjacent.contains(country)) {
    return RouteTier.l5;
  }
  return RouteTier.l6;
}

CandidateDecision decideCandidates(CandidateDecisionInput input) {
  final lock = _countrySet(input.lockedCountries);
  final adjacent = _countrySet(input.adjacentCountries);
  final banned = _countrySet(input.regionBannedCountries);
  final allowed = input.regionAllowedCountries == null
      ? null
      : _countrySet(input.regionAllowedCountries!);

  final names = <String>[];
  final seen = <String>{};
  for (final name in input.candidateNames) {
    if (seen.add(name)) {
      names.add(name);
    }
  }

  final currentName = input.currentName;
  final currentMeta = currentName == null
      ? null
      : input.metadataByProxy[currentName];
  final currentUnknown =
      currentName != null &&
      (currentMeta == null || currentMeta.countryCode.trim().isEmpty);
  final ref = _RouteReference.of(input, currentMeta);
  final scoringAnchor =
      input.anchor ??
      (currentMeta == null
          ? null
          : _anchorFromMeta(input.serviceId, currentMeta));

  final assessments = <String, CandidateAssessment>{};
  final blocked = <String>[];
  final fallback = <String>[];
  final byTier = <RouteTier, List<String>>{
    for (final tier in RouteTier.values) tier: [],
  };

  for (final name in names) {
    final meta = input.metadataByProxy[name];
    final access = input.accessByProxy[name];
    if (meta == null || meta.countryCode.trim().isEmpty) {
      if (input.restrictionMode == ServiceRestrictionMode.strict) {
        assessments[name] = CandidateAssessment(
          name: name,
          score: 0,
          confirmedAccessible: false,
          retainedByHysteresis: false,
          rejection: CandidateRejection.unknownCountryStrict,
        );
        blocked.add(name);
      } else {
        assessments[name] = CandidateAssessment(
          name: name,
          score: 0,
          confirmedAccessible: false,
          retainedByHysteresis: false,
          tier: RouteTier.l7,
        );
        fallback.add(name);
      }
      continue;
    }
    var failures = _failures(meta, access, lock, banned, allowed);
    var retained = false;
    if (failures.length == 1 &&
        failures.first == CandidateRejection.purityBelowThreshold &&
        name == currentName &&
        ScoringEngine.failsOnlyPurityWithinBand(
          meta,
          input.lockedCountries,
          access,
        )) {
      failures = const [];
      retained = true;
    }
    if (failures.isNotEmpty) {
      assessments[name] = CandidateAssessment(
        name: name,
        score: _score(meta, input, scoringAnchor),
        confirmedAccessible: _confirmedAccessible(input, name),
        retainedByHysteresis: false,
        rejection: failures.first,
      );
      blocked.add(name);
      continue;
    }
    final tier = name == currentName
        ? RouteTier.l0
        : _tierFor(meta, ref, adjacent);
    assessments[name] = CandidateAssessment(
      name: name,
      score: _score(meta, input, scoringAnchor),
      confirmedAccessible: _confirmedAccessible(input, name),
      retainedByHysteresis: retained,
      tier: tier,
    );
    byTier[tier]!.add(name);
  }

  final qualified = <String>[];
  for (final tier in RouteTier.values) {
    if (tier == RouteTier.l7) {
      continue;
    }
    final bucket = byTier[tier]!;
    final confirmed = [
      for (final name in bucket)
        if (_confirmedAccessible(input, name)) name,
    ];
    final rest = [
      for (final name in bucket)
        if (!_confirmedAccessible(input, name)) name,
    ];
    qualified.addAll(_sortWithinTier(confirmed, input, scoringAnchor));
    qualified.addAll(_sortWithinTier(rest, input, scoringAnchor));
  }
  fallback.sort((a, b) {
    if ((a == currentName) != (b == currentName)) {
      return a == currentName ? -1 : 1;
    }
    return a.compareTo(b);
  });

  String? target;
  RouteTier? targetTier;
  if (currentName != null && assessments[currentName]?.tier == RouteTier.l0) {
    target = currentName;
    targetTier = RouteTier.l0;
  } else if (qualified.isNotEmpty) {
    target = qualified.first;
    targetTier = assessments[target]!.tier;
  } else if (fallback.isNotEmpty) {
    target = fallback.first;
    targetTier = RouteTier.l7;
  }

  final countsByTier = <RouteTier, int>{
    for (final tier in RouteTier.values)
      if ((tier == RouteTier.l7 ? fallback.length : byTier[tier]!.length) > 0)
        tier: tier == RouteTier.l7 ? fallback.length : byTier[tier]!.length,
  };
  final rejectionCounts = <CandidateRejection, int>{};
  for (final name in blocked) {
    final reason = assessments[name]!.rejection!;
    rejectionCounts[reason] = (rejectionCounts[reason] ?? 0) + 1;
  }

  return CandidateDecision(
    serviceId: input.serviceId,
    qualified: qualified,
    fallback: fallback,
    blocked: blocked,
    ordered: [...qualified, ...fallback],
    target: target,
    tier: targetTier,
    trigger: input.trigger,
    currentUnknown: currentUnknown,
    hasServiceOutage: input.serviceOutageSuspected,
    assessments: assessments,
    countsByTier: countsByTier,
    rejectionCounts: rejectionCounts,
    explanation: _explain(
      input: input,
      target: target,
      tier: targetTier,
      qualified: qualified,
      fallback: fallback,
      blocked: blocked,
      countsByTier: countsByTier,
      rejectionCounts: rejectionCounts,
      lock: lock,
      currentUnknown: currentUnknown,
    ),
    evidence: input.accessByProxy,
  );
}

String _explain({
  required CandidateDecisionInput input,
  required String? target,
  required RouteTier? tier,
  required List<String> qualified,
  required List<String> fallback,
  required List<String> blocked,
  required Map<RouteTier, int> countsByTier,
  required Map<CandidateRejection, int> rejectionCounts,
  required Set<String> lock,
  required bool currentUnknown,
}) {
  return [
    if (target != null) 'target=$target tier=${tier!.label}' else 'no target',
    'qualified=${qualified.length} fallback=${fallback.length} blocked=${blocked.length}',
    if (countsByTier.isNotEmpty)
      'tiers ${[for (final tier in RouteTier.values)
        if (countsByTier[tier] != null) '${tier.label}:${countsByTier[tier]}'].join(' ')}',
    if (rejectionCounts.isNotEmpty)
      'rejected ${[for (final reason in CandidateRejection.values)
        if (rejectionCounts[reason] != null) '${reason.name}:${rejectionCounts[reason]}'].join(' ')}',
    'mode=${input.restrictionMode.name} lock=${lock.isEmpty ? '-' : (lock.toList()..sort()).join('/')}',
    if (currentUnknown) 'currentUnknown',
    if (input.serviceOutageSuspected) 'serviceOutage',
  ].join('; ');
}

/// Adapts the wiring layer's [SmartAnchorInput] to a decision for one
/// service. The region sets mirror `applyRegionFilter`: a whitelist
/// with entries restricts to them, a blacklist uses its entries or,
/// when empty, the gated derived unsupported set from batch A2. The
/// merged-config name remap stays the caller's job, exactly as it is
/// for the ranking path today.
CandidateDecision decideForService(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames, {
  String? currentName,
  Map<String, int> delays = const {},
  CandidateDecisionTrigger trigger = CandidateDecisionTrigger.initialSelection,
  bool serviceOutageSuspected = false,
  List<String> adjacentCountries = const [],
}) {
  final stored = _countrySet(service.regionCountries);
  var banned = const <String>{};
  Set<String>? allowed;
  if (service.effectiveRegionMode == 'whitelist') {
    if (stored.isNotEmpty) {
      allowed = stored;
    }
  } else {
    banned = stored.isNotEmpty
        ? stored
        : derivedRegionEvidence(input, service.serviceId).blocked;
  }
  return decideCandidates(
    CandidateDecisionInput(
      serviceId: service.serviceId,
      restrictionMode: service.restrictionMode,
      lockedCountries: service.lockedCountries,
      candidateNames: proxyNames,
      metadataByProxy: input.metadataByProxy,
      accessByProxy: input.accessByService[service.serviceId] ?? const {},
      delays: delays,
      regionBannedCountries: banned,
      regionAllowedCountries: allowed,
      currentName: currentName,
      anchor: input.anchors[service.serviceId],
      trigger: trigger,
      serviceOutageSuspected: serviceOutageSuspected,
      adjacentCountries: adjacentCountries,
    ),
  );
}
