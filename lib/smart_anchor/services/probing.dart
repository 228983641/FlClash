import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/services/api_pool.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';

ServiceTarget? serviceTargetForServiceId(String serviceId) {
  switch (serviceId) {
    case 'claude':
      return ServiceTarget.claude;
    case 'openai':
      return ServiceTarget.chatgpt;
    case 'gemini':
      return ServiceTarget.gemini;
    case 'netflix':
      return ServiceTarget.netflix;
    case 'youtube':
      return ServiceTarget.youtube;
    case 'google':
      return ServiceTarget.google;
    default:
      return null;
  }
}

ServiceAccessReason accessReasonFromStatus(ServiceProbeStatus status) {
  switch (status) {
    case ServiceProbeStatus.available:
      return ServiceAccessReason.accessible;
    case ServiceProbeStatus.unsupportedRegion:
    case ServiceProbeStatus.restricted:
    case ServiceProbeStatus.disallowedIsp:
    case ServiceProbeStatus.blocked:
      return ServiceAccessReason.regionBlocked;
    case ServiceProbeStatus.timeout:
    case ServiceProbeStatus.failed:
      return ServiceAccessReason.networkFailed;
    case ServiceProbeStatus.unavailable:
    case ServiceProbeStatus.originalsOnly:
    case ServiceProbeStatus.comingSoon:
    case ServiceProbeStatus.cancelled:
      return ServiceAccessReason.unknown;
  }
}

ServiceAccessResult accessResultFromStatus({
  required String serviceId,
  required String proxyName,
  required String egressIp,
  required ServiceProbeStatus status,
  required int checkedAt,
}) {
  return ServiceAccessResult(
    serviceId: serviceId,
    proxyName: proxyName,
    egressIp: egressIp,
    reason: accessReasonFromStatus(status),
    checkedAt: checkedAt,
  );
}

/// How many nodes one probe round may cover. Rounds are triggered by
/// setup and by the monitor tick, so a bounded round still walks the whole
/// queue over time instead of truncating coverage by list position.
const int probeRoundBudget = 32;

/// Whether a node with this metadata should be (re)probed once the queue
/// reaches it: no metadata yet, or metadata past its TTL.
bool probeMetadataStale(NodeMetadataCache? metadata) =>
    metadata == null || metadata.isExpired;

/// One round of probe targets, best first:
///
/// 1. the node each enabled service group is currently using — its access
///    results feed the failover check, so it is probed even when its
///    metadata is still fresh, and currents are never cut by the budget;
/// 2. nodes with missing or expired metadata, best rank first —
///    [rankByProxy] carries each node's best (lowest) rank across the
///    enabled services' rankings;
/// 3. the remaining stale nodes in [proxyNames] order.
///
/// Fresh nodes outside the current set are skipped; they re-enter the
/// queue when their metadata expires. A node probed this round drops out
/// of the stale set, so the next round resumes where this one stopped and
/// repeated rounds cover every node.
List<String> selectProbeQueue({
  required List<String> proxyNames,
  required List<String> currentProxyNames,
  required Map<String, NodeMetadataCache> metadataByProxy,
  required Map<String, int> rankByProxy,
  int budget = probeRoundBudget,
}) {
  final targets = <String>[];
  final seen = <String>{};
  void add(String name) {
    if (name.isNotEmpty && seen.add(name)) {
      targets.add(name);
    }
  }

  var currents = 0;
  for (final name in currentProxyNames) {
    if (name.isNotEmpty && !seen.contains(name)) {
      currents++;
    }
    add(name);
  }
  final order = {
    for (var index = 0; index < proxyNames.length; index++)
      proxyNames[index]: index,
  };
  final stale = [
    for (final name in proxyNames)
      if (probeMetadataStale(metadataByProxy[name])) name,
  ];
  final ranked =
      [
        for (final name in stale)
          if (rankByProxy.containsKey(name)) name,
      ]..sort((a, b) {
        final byRank = rankByProxy[a]!.compareTo(rankByProxy[b]!);
        return byRank != 0 ? byRank : order[a]!.compareTo(order[b]!);
      });
  for (final name in ranked) {
    add(name);
  }
  for (final name in stale) {
    add(name);
  }
  final limit = budget > currents ? budget : currents;
  return targets.take(limit).toList();
}

class ProbeOutcome {
  const ProbeOutcome({this.metadata, this.accessByService = const {}});

  final NodeMetadataCache? metadata;
  final Map<String, ServiceAccessResult> accessByService;
}

typedef EgressLookup = Future<IpInfo?> Function(String proxyName);

typedef CoreServiceCheckLookup =
    Future<Map<ServiceTarget, ServiceCheck>> Function(
      String proxyName,
      List<ServiceTarget> targets,
    );

typedef GeoLookup =
    Future<NodeMetadataCache?> Function({
      required String ip,
      required String proxyName,
      required String entryServer,
    });

class SmartAnchorProber {
  SmartAnchorProber({
    required this.egressLookup,
    required this.serviceCheckLookup,
    required this.geoLookup,
  });

  final EgressLookup egressLookup;
  final CoreServiceCheckLookup serviceCheckLookup;
  final GeoLookup geoLookup;

  Future<ProbeOutcome> probeNode({
    required String proxyName,
    required String entryServer,
    required List<String> serviceIds,
    required int nowMs,
  }) async {
    final egress = await egressLookup(proxyName);
    NodeMetadataCache? metadata;
    if (egress != null) {
      metadata = await geoLookup(
        ip: egress.ip,
        proxyName: proxyName,
        entryServer: entryServer,
      );
    }
    final targets = <ServiceTarget, String>{};
    for (final serviceId in serviceIds) {
      final target = serviceTargetForServiceId(serviceId);
      if (target != null) {
        targets[target] = serviceId;
      }
    }
    final access = <String, ServiceAccessResult>{};
    if (targets.isNotEmpty) {
      final checks = await serviceCheckLookup(proxyName, targets.keys.toList());
      for (final entry in checks.entries) {
        final serviceId = targets[entry.key];
        if (serviceId == null) {
          continue;
        }
        // A check cancelled because a newer request from this same caller
        // replaced it says nothing about the node; recording an outcome
        // for it would read as a node failure downstream.
        if (entry.value.status == ServiceProbeStatus.cancelled) {
          continue;
        }
        access[serviceId] = accessResultFromStatus(
          serviceId: serviceId,
          proxyName: proxyName,
          egressIp: egress?.ip ?? '',
          status: entry.value.status,
          checkedAt: nowMs,
        );
      }
    }
    return ProbeOutcome(metadata: metadata, accessByService: access);
  }
}

GeoLookup geoLookupFromService(GeoIpService service, bool wafPass) {
  return ({
    required String ip,
    required String proxyName,
    required String entryServer,
  }) {
    return service.lookup(
      ip: ip,
      proxyName: proxyName,
      entryServer: entryServer,
      wafPass: wafPass,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  };
}
