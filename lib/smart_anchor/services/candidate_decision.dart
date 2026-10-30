import '../models/node_metadata.dart';
import '../models/service_anchor.dart';
import '../models/service_toggle_config.dart';
import 'scoring_engine.dart';
import 'service_access.dart';

enum CandidateRouteTier {
  sameEgress,
  sameSubnet,
  sameCity,
  sameAdminRegion,
  sameCountrySameAsn,
  sameCountry,
  otherAllowedCountry,
  unknown,
}

enum CandidateBlockReason {
  unknownCountry,
  countryLock,
  regionPolicy,
  countryDisputed,
  wafBlocked,
  lowPurity,
  serviceBlocked,
}

class CandidateDecision {
  const CandidateDecision({
    required this.qualified,
    required this.fallback,
    required this.blocked,
    required this.ordered,
    required this.tierByProxy,
    required this.blockedReasons,
    required this.target,
    required this.currentCompliant,
    required this.currentUnknown,
  });

  final List<String> qualified;
  final List<String> fallback;
  final List<String> blocked;
  final List<String> ordered;
  final Map<String, CandidateRouteTier> tierByProxy;
  final Map<String, CandidateBlockReason> blockedReasons;
  final String? target;
  final bool currentCompliant;
  final bool currentUnknown;
}

CandidateDecision buildCandidateDecision({
  required ServiceToggleConfig service,
  required List<String> proxyNames,
  required Map<String, NodeMetadataCache> metadataByProxy,
  required Map<String, ServiceAccessResult> accessByProxy,
  ServiceAnchor? anchor,
  String? currentName,
  Map<String, int> delays = const {},
  Set<String> bannedCountries = const {},
  Set<String> allowedCountries = const {},
  double minimumGeoConfidence = 0.7,
}) {
  final lockedCountries = {
    for (final country in service.lockedCountries) country.toUpperCase(),
  };
  final normalizedBanned = {
    for (final country in bannedCountries) country.toUpperCase(),
  };
  final normalizedAllowed = {
    for (final country in allowedCountries) country.toUpperCase(),
  };
  final qualifiedNodes = <NodeMetadataCache>[];
  final fallback = <String>[];
  final blocked = <String>[];
  final blockedReasons = <String, CandidateBlockReason>{};

  void block(String name, CandidateBlockReason reason) {
    blocked.add(name);
    blockedReasons[name] = reason;
  }

  for (final name in proxyNames) {
    final metadata = metadataByProxy[name];
    if (metadata == null || metadata.countryCode.trim().isEmpty) {
      if (service.restrictionMode == ServiceRestrictionMode.strict) {
        block(name, CandidateBlockReason.unknownCountry);
      } else {
        fallback.add(name);
      }
      continue;
    }
    if (metadata.countryDisputed) {
      if (service.restrictionMode == ServiceRestrictionMode.strict) {
        block(name, CandidateBlockReason.countryDisputed);
      } else {
        fallback.add(name);
      }
      continue;
    }
    final country = metadata.countryCode.toUpperCase();
    if (normalizedBanned.contains(country) ||
        (normalizedAllowed.isNotEmpty &&
            !normalizedAllowed.contains(country))) {
      block(name, CandidateBlockReason.regionPolicy);
      continue;
    }
    if (lockedCountries.isNotEmpty && !lockedCountries.contains(country)) {
      block(name, CandidateBlockReason.countryLock);
      continue;
    }
    if (!metadata.wafPass) {
      block(name, CandidateBlockReason.wafBlocked);
      continue;
    }
    if (metadata.purityScore < 50) {
      block(name, CandidateBlockReason.lowPurity);
      continue;
    }
    final access = accessByProxy[name];
    if (access != null && !access.isExpired && access.blocksRanking) {
      block(name, CandidateBlockReason.serviceBlocked);
      continue;
    }
    qualifiedNodes.add(metadata);
  }

  final reference = _routeReference(
    anchor: anchor,
    currentName: currentName,
    metadataByProxy: metadataByProxy,
    candidates: qualifiedNodes,
    accessByProxy: accessByProxy,
    delays: delays,
  );
  final tierByProxy = <String, CandidateRouteTier>{};
  final nodesByTier = <CandidateRouteTier, List<NodeMetadataCache>>{};
  for (final node in qualifiedNodes) {
    final tier = _routeTier(
      node,
      reference,
      minimumGeoConfidence: minimumGeoConfidence,
    );
    tierByProxy[node.proxyName] = tier;
    nodesByTier.putIfAbsent(tier, () => []).add(node);
  }
  for (final name in fallback) {
    tierByProxy[name] = CandidateRouteTier.unknown;
  }

  final rankedQualified = <String>[];
  for (final tier in CandidateRouteTier.values) {
    if (tier == CandidateRouteTier.unknown) {
      continue;
    }
    final nodes = nodesByTier[tier];
    if (nodes == null) {
      continue;
    }
    rankedQualified.addAll(
      _rankWithinTier(
        nodes,
        reference,
        accessByProxy,
        delays,
      ).map((node) => node.proxyName),
    );
  }

  final currentMetadata = currentName == null
      ? null
      : metadataByProxy[currentName];
  final currentUnknown =
      currentName != null &&
      (currentMetadata == null ||
          currentMetadata.countryCode.trim().isEmpty ||
          currentMetadata.countryDisputed);
  final currentCompliant =
      currentName != null && rankedQualified.contains(currentName);
  String? target;
  if (!currentCompliant) {
    if (rankedQualified.isNotEmpty) {
      target = rankedQualified.first;
    } else if (currentName == null || !fallback.contains(currentName)) {
      if (service.restrictionMode != ServiceRestrictionMode.strict &&
          fallback.isNotEmpty) {
        target = fallback.first;
      }
    }
  }

  return CandidateDecision(
    qualified: rankedQualified,
    fallback: fallback,
    blocked: blocked,
    ordered: [...rankedQualified, ...fallback],
    tierByProxy: tierByProxy,
    blockedReasons: blockedReasons,
    target: target,
    currentCompliant: currentCompliant,
    currentUnknown: currentUnknown,
  );
}

class _RouteReference {
  const _RouteReference({
    required this.countryCode,
    required this.egressIp,
    required this.subnet24,
    required this.asn,
    required this.latitude,
    required this.longitude,
    required this.city,
    required this.adminRegion,
    required this.geoConfidence,
  });

  final String countryCode;
  final String egressIp;
  final String subnet24;
  final String asn;
  final double latitude;
  final double longitude;
  final String? city;
  final String? adminRegion;
  final double? geoConfidence;

  ServiceAnchor get scoringAnchor => ServiceAnchor(
    serviceTag: '',
    countryCode: countryCode,
    lastProxyName: '',
    egressIp: egressIp,
    subnet24: subnet24,
    asn: asn,
    isp: '',
    latitude: latitude,
    longitude: longitude,
    city: city ?? '',
    confirmedAt: 0,
  );
}

_RouteReference? _routeReference({
  required ServiceAnchor? anchor,
  required String? currentName,
  required Map<String, NodeMetadataCache> metadataByProxy,
  required List<NodeMetadataCache> candidates,
  required Map<String, ServiceAccessResult> accessByProxy,
  required Map<String, int> delays,
}) {
  if (anchor != null) {
    return _RouteReference(
      countryCode: anchor.countryCode.toUpperCase(),
      egressIp: anchor.egressIp,
      subnet24: anchor.subnet24,
      asn: anchor.asn,
      latitude: anchor.latitude,
      longitude: anchor.longitude,
      city: anchor.city.isEmpty ? null : anchor.city,
      adminRegion: null,
      geoConfidence: 1,
    );
  }
  final current = currentName == null ? null : metadataByProxy[currentName];
  if (current != null) {
    return _referenceFromNode(current);
  }
  if (candidates.isEmpty) {
    return null;
  }
  final seed = List<NodeMetadataCache>.of(candidates)
    ..sort((a, b) {
      final aAccessible = _confirmedAccessible(a.proxyName, accessByProxy);
      final bAccessible = _confirmedAccessible(b.proxyName, accessByProxy);
      if (aAccessible != bAccessible) {
        return aAccessible ? -1 : 1;
      }
      final byPurity = b.purityScore.compareTo(a.purityScore);
      if (byPurity != 0) {
        return byPurity;
      }
      final aDelay = delays[a.proxyName];
      final bDelay = delays[b.proxyName];
      if (aDelay != bDelay) {
        if (aDelay == null || aDelay < 0) return 1;
        if (bDelay == null || bDelay < 0) return -1;
        return aDelay.compareTo(bDelay);
      }
      return a.proxyName.compareTo(b.proxyName);
    });
  return _referenceFromNode(seed.first);
}

_RouteReference _referenceFromNode(NodeMetadataCache node) {
  final parts = node.egressIp.split('.');
  final subnet24 = parts.length == 4 ? parts.sublist(0, 3).join('.') : '';
  return _RouteReference(
    countryCode: node.countryCode.toUpperCase(),
    egressIp: node.egressIp,
    subnet24: subnet24,
    asn: node.asn,
    latitude: node.latitude,
    longitude: node.longitude,
    city: node.city,
    adminRegion: node.adminRegion,
    geoConfidence: node.geoConfidence,
  );
}

CandidateRouteTier _routeTier(
  NodeMetadataCache node,
  _RouteReference? reference, {
  required double minimumGeoConfidence,
}) {
  if (reference == null) {
    return CandidateRouteTier.otherAllowedCountry;
  }
  if (node.egressIp.isNotEmpty && node.egressIp == reference.egressIp) {
    return CandidateRouteTier.sameEgress;
  }
  if (reference.subnet24.isNotEmpty && node.sameSubnet24(reference.subnet24)) {
    return CandidateRouteTier.sameSubnet;
  }
  final sameCountry = node.countryCode.toUpperCase() == reference.countryCode;
  final trustedGeo =
      sameCountry &&
      (node.geoConfidence ?? 0) >= minimumGeoConfidence &&
      (reference.geoConfidence ?? 0) >= minimumGeoConfidence;
  if (trustedGeo && _sameNonEmpty(node.city, reference.city)) {
    return CandidateRouteTier.sameCity;
  }
  if (trustedGeo && _sameNonEmpty(node.adminRegion, reference.adminRegion)) {
    return CandidateRouteTier.sameAdminRegion;
  }
  if (sameCountry && node.asn.isNotEmpty && node.asn == reference.asn) {
    return CandidateRouteTier.sameCountrySameAsn;
  }
  if (sameCountry) {
    return CandidateRouteTier.sameCountry;
  }
  return CandidateRouteTier.otherAllowedCountry;
}

bool _sameNonEmpty(String? left, String? right) {
  final a = left?.trim().toLowerCase();
  final b = right?.trim().toLowerCase();
  return a != null && a.isNotEmpty && b != null && b.isNotEmpty && a == b;
}

List<NodeMetadataCache> _rankWithinTier(
  List<NodeMetadataCache> nodes,
  _RouteReference? reference,
  Map<String, ServiceAccessResult> accessByProxy,
  Map<String, int> delays,
) {
  final confirmed = <NodeMetadataCache>[];
  final unconfirmed = <NodeMetadataCache>[];
  for (final node in nodes) {
    (_confirmedAccessible(node.proxyName, accessByProxy)
            ? confirmed
            : unconfirmed)
        .add(node);
  }
  List<NodeMetadataCache> rank(List<NodeMetadataCache> values) {
    if (reference == null) {
      return values;
    }
    return ScoringEngine.rank(values, reference.scoringAnchor, delays: delays);
  }

  return [...rank(confirmed), ...rank(unconfirmed)];
}

bool _confirmedAccessible(
  String proxyName,
  Map<String, ServiceAccessResult> accessByProxy,
) {
  final access = accessByProxy[proxyName];
  return access != null &&
      !access.isExpired &&
      access.isAccessible &&
      access.borrowedFrom == null;
}
