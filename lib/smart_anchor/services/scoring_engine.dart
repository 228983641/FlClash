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

  /// A re-probe can push a working node's purity under the candidate
  /// threshold on measurement noise alone. Inside this band the node is
  /// not a candidate for anyone, but a service already using it is not
  /// torn off it either; below the band the cliff applies as usual.
  static const double purityHysteresisFloor = 35;

  /// Whether [node]'s only hard-filter failure is a purity score inside
  /// the hysteresis band: country lock, WAF and a fresh region-block
  /// verdict must all pass, so the band never excuses a real violation.
  static bool failsOnlyPurityWithinBand(
    NodeMetadataCache node,
    List<String> lockedCountries,
    ServiceAccessResult? access,
  ) {
    if (node.purityScore < purityHysteresisFloor || node.purityScore >= 50) {
      return false;
    }
    final lock = lockedCountries
        .map((country) => country.toUpperCase())
        .toList();
    if (lock.isNotEmpty && !lock.contains(node.countryCode.toUpperCase())) {
      return false;
    }
    if (!node.wafPass) {
      return false;
    }
    if (access != null && !access.isExpired && access.blocksRanking) {
      return false;
    }
    return true;
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

  /// Whether [node] may become the remembered anchor for a service: the
  /// same qualification the ranking applies, so a node the lock rules out
  /// (or a fresh region-block verdict condemns) never anchors a service.
  static bool anchorEligible(
    NodeMetadataCache node,
    List<String> lockedCountries,
    Map<String, ServiceAccessResult> accessByProxy,
  ) {
    return filterForService([node], lockedCountries, accessByProxy).isNotEmpty;
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
      // Only the service's own probe confirms reachability; a borrowed
      // verdict says the donor answered, not that this service did.
      if (access != null &&
          !access.isExpired &&
          access.isAccessible &&
          access.borrowedFrom == null) {
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

  static double purityCompressed(double purityScore) {
    return ((purityScore - 50) * 0.24).clamp(0.0, 12.0);
  }

  static double delayPenalty(int? delayMs) {
    if (delayMs == null) {
      return 0.0;
    }
    if (delayMs < 0) {
      return 30.0;
    }
    return math.min(30.0, delayMs / 20.0);
  }

  static double distanceAffinity(double distanceKm) {
    final capped = math.min(distanceKm, 3000.0);
    return 5.0 * (1 - capped / 3000.0);
  }

  static double proximityBonus(NodeMetadataCache node, ServiceAnchor anchor) {
    var bonus = distanceAffinity(
      haversineKm(
        anchor.latitude,
        anchor.longitude,
        node.latitude,
        node.longitude,
      ),
    );
    if (node.asn == anchor.asn) bonus += 6;
    if (node.sameSubnet24(anchor.subnet24)) bonus += 4;
    return bonus;
  }

  static double priority(
    NodeMetadataCache node,
    ServiceAnchor anchor, {
    int? delayMs,
  }) {
    return purityCompressed(node.purityScore) +
        proximityBonus(node, anchor) -
        delayPenalty(delayMs);
  }

  static List<NodeMetadataCache> rank(
    List<NodeMetadataCache> nodes,
    ServiceAnchor anchor, {
    Map<String, int> delays = const {},
  }) {
    double distanceOf(NodeMetadataCache node) {
      return haversineKm(
        anchor.latitude,
        anchor.longitude,
        node.latitude,
        node.longitude,
      );
    }

    final sorted = List<NodeMetadataCache>.of(nodes);
    sorted.sort((a, b) {
      final aDelay = delays[a.proxyName];
      final bDelay = delays[b.proxyName];
      if ((aDelay == null) != (bDelay == null)) {
        return aDelay == null ? 1 : -1;
      }
      final byScore = priority(
        b,
        anchor,
        delayMs: bDelay,
      ).compareTo(priority(a, anchor, delayMs: aDelay));
      if (byScore != 0) {
        return byScore;
      }
      final byDistance = distanceOf(a).compareTo(distanceOf(b));
      if (byDistance != 0) {
        return byDistance;
      }
      return a.proxyName.compareTo(b.proxyName);
    });
    return sorted;
  }
}
