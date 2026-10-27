import 'dart:math' as math;

import '../models/node_metadata.dart';
import '../models/service_anchor.dart';
import 'service_access.dart';

class ScoringEngine {
  static const double earthRadiusKm = 6371.0;

  static bool passesHardFilter(NodeMetadataCache node, String anchorCountry) {
    return passesHardFilterForTarget(node, [anchorCountry]);
  }

  static bool passesHardFilterForTarget(
    NodeMetadataCache node,
    List<String> lockedCountries,
  ) {
    final lock = lockedCountries
        .map((country) => country.toUpperCase())
        .toList();
    return (lock.isEmpty || lock.contains(node.countryCode.toUpperCase())) &&
        node.wafPass &&
        node.purityScore >= 50;
  }

  static List<NodeMetadataCache> filterForTarget(
    List<NodeMetadataCache> nodes,
    List<String> lockedCountries,
  ) {
    return nodes
        .where((node) => passesHardFilterForTarget(node, lockedCountries))
        .toList();
  }

  static String trustTier(double purityScore) {
    if (purityScore >= 70) {
      return 'safe';
    }
    if (purityScore >= 50) {
      return 'watch';
    }
    return 'risky';
  }

  static List<NodeMetadataCache> filterForService(
    List<NodeMetadataCache> nodes,
    List<String> lockedCountries,
    Map<String, ServiceAccessResult> accessByProxy,
  ) {
    return nodes.where((node) {
      if (!passesHardFilterForTarget(node, lockedCountries)) {
        return false;
      }
      final access = accessByProxy[node.proxyName];
      if (access != null && !access.isExpired && access.blocksRanking) {
        return false;
      }
      return true;
    }).toList();
  }

  static List<NodeMetadataCache> rankForService(
    List<NodeMetadataCache> nodes,
    ServiceAnchor anchor,
    List<String> lockedCountries,
    Map<String, ServiceAccessResult> accessByProxy, {
    Map<String, int> delays = const {},
  }) {
    final filtered = filterForService(nodes, lockedCountries, accessByProxy);
    final accessible = <NodeMetadataCache>[];
    final untested = <NodeMetadataCache>[];
    for (final node in filtered) {
      final access = accessByProxy[node.proxyName];
      if (access != null && !access.isExpired && access.isAccessible) {
        accessible.add(node);
      } else {
        untested.add(node);
      }
    }
    return [
      ...rank(accessible, anchor, delays: delays),
      ...rank(untested, anchor, delays: delays),
    ];
  }

  static double purityScore({
    required String ipType,
    required double fraudScore,
    required bool isAbuse,
  }) {
    final typePenalty = switch (ipType) {
      'isp' || 'residential' => 0.0,
      'business' => 10.0,
      'hosting' || 'datacenter' => 30.0,
      _ => 30.0,
    };
    final abusePenalty = isAbuse ? 25.0 : 0.0;
    final score = 100 - typePenalty - fraudScore * 0.5 - abusePenalty;
    return score.clamp(0.0, 100.0);
  }

  static double haversineKm(
    double lat0,
    double lon0,
    double lat1,
    double lon1,
  ) {
    final dLat = _toRad(lat1 - lat0);
    final dLon = _toRad(lon1 - lon0);
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(_toRad(lat0)) *
            math.cos(_toRad(lat1)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _toRad(double deg) => deg * math.pi / 180;

  static double distancePenalty(double distanceKm) {
    return math.min(25.0, 4.0 * math.log(distanceKm / 50.0 + 1));
  }

  static double delayPenalty(int? delayMs) {
    if (delayMs == null || delayMs == 0) {
      return 0.0;
    }
    if (delayMs < 0) {
      return 10.0;
    }
    return math.min(10.0, delayMs / 100.0);
  }

  static double priority(
    NodeMetadataCache node,
    ServiceAnchor anchor, {
    int? delayMs,
  }) {
    final distance = haversineKm(
      anchor.latitude,
      anchor.longitude,
      node.latitude,
      node.longitude,
    );
    var score = node.purityScore - distancePenalty(distance);
    if (node.asn == anchor.asn) score += 15;
    if (node.sameSubnet24(anchor.subnet24)) score += 10;
    return score - delayPenalty(delayMs);
  }

  static List<NodeMetadataCache> rank(
    List<NodeMetadataCache> nodes,
    ServiceAnchor anchor, {
    Map<String, int> delays = const {},
  }) {
    final sorted = List<NodeMetadataCache>.of(nodes);
    sorted.sort(
      (a, b) => priority(
        b,
        anchor,
        delayMs: delays[b.proxyName],
      ).compareTo(priority(a, anchor, delayMs: delays[a.proxyName])),
    );
    return sorted;
  }
}
