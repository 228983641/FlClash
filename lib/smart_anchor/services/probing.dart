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
    case 'disney':
      return ServiceTarget.disneyPlus;
    case 'youtube':
      return ServiceTarget.youtube;
    case 'google':
      return ServiceTarget.google;
    default:
      return null;
  }
}

/// Donor service for a preset service the core has no checker for: the
/// donor's probe verdict is recorded under the borrower's id as well,
/// stamped with the donor so downstream consumers can weigh it. Donors
/// follow the shape of each service's region policy: the broad consumer
/// AI services track OpenAI's supported-country list, Meta AI's short
/// curated rollout list is closest to Anthropic's, the platform services
/// follow Google's reachability, and Apple TV+ follows Netflix's
/// streaming region model.
const fallbackProbeDonorByService = <String, String>{
  'grok': 'openai',
  'perplexity': 'openai',
  'copilot': 'openai',
  'poe': 'openai',
  'mistral': 'openai',
  'muse': 'openai',
  'meta-ai': 'claude',
  'x': 'google',
  'cloudflare': 'google',
  'appletv': 'netflix',
};

String? fallbackProbeServiceId(String serviceId) =>
    fallbackProbeDonorByService[serviceId];

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
  String? borrowedFrom,
}) {
  return ServiceAccessResult(
    serviceId: serviceId,
    proxyName: proxyName,
    egressIp: egressIp,
    reason: accessReasonFromStatus(status),
    checkedAt: checkedAt,
    borrowedFrom: borrowedFrom,
  );
}

/// WAF verdict from one node's own Cloudflare trace fetch. Only positive
/// evidence fails a node — a 403 or a challenge page — because a block is
/// what the verdict exists to catch; a fetch that never got an answer
/// (no probe slot, a transport error, a timeout) says nothing about the
/// WAF, so the node keeps the benefit of the doubt.
bool wafPassFromTraceProbe(ProbeResult? result) {
  if (result == null || result.error != null) {
    return true;
  }
  final body = result.body.toLowerCase();
  if (body.contains('just a moment') ||
      body.contains('challenge') ||
      body.contains('attention required')) {
    return false;
  }
  return result.statusCode != 403;
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
  const ProbeOutcome({
    this.metadata,
    this.accessByService = const {},
    this.metadataFailure,
  });

  final NodeMetadataCache? metadata;
  final Map<String, ServiceAccessResult> accessByService;

  /// Why this node produced no metadata: 'no-egress' when no exit IP
  /// could be measured (a timeout lands here too), 'geo-failed' when an
  /// exit IP was measured but every GeoIP source failed. Null when
  /// metadata was produced.
  final String? metadataFailure;
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
      required bool wafPass,
    });

typedef WafLookup = Future<bool> Function(String proxyName);

class SmartAnchorProber {
  SmartAnchorProber({
    required this.egressLookup,
    required this.serviceCheckLookup,
    required this.geoLookup,
    this.wafLookup,
  });

  final EgressLookup egressLookup;
  final CoreServiceCheckLookup serviceCheckLookup;
  final GeoLookup geoLookup;
  final WafLookup? wafLookup;

  Future<ProbeOutcome> probeNode({
    required String proxyName,
    required String entryServer,
    required List<String> serviceIds,
    required int nowMs,
  }) async {
    final egress = await egressLookup(proxyName);
    NodeMetadataCache? metadata;
    String? metadataFailure;
    if (egress == null) {
      metadataFailure = 'no-egress';
    } else {
      final wafPass = await wafLookup?.call(proxyName) ?? true;
      metadata = await geoLookup(
        ip: egress.ip,
        proxyName: proxyName,
        entryServer: entryServer,
        wafPass: wafPass,
      );
      if (metadata == null) {
        metadataFailure = 'geo-failed';
      }
    }
    // Services without a core checker borrow their donor's target; the
    // donor is probed once and its verdict fans out to every borrower.
    final nativeByTarget = <ServiceTarget, List<String>>{};
    final borrowersByTarget = <ServiceTarget, Map<String, String>>{};
    for (final serviceId in serviceIds) {
      final target = serviceTargetForServiceId(serviceId);
      if (target != null) {
        (nativeByTarget[target] ??= []).add(serviceId);
        continue;
      }
      final donor = fallbackProbeServiceId(serviceId);
      final donorTarget = donor == null
          ? null
          : serviceTargetForServiceId(donor);
      if (donor != null && donorTarget != null) {
        (borrowersByTarget[donorTarget] ??= {})[serviceId] = donor;
      }
    }
    final targets = {...nativeByTarget.keys, ...borrowersByTarget.keys};
    final access = <String, ServiceAccessResult>{};
    if (targets.isNotEmpty) {
      final checks = await serviceCheckLookup(proxyName, targets.toList());
      for (final entry in checks.entries) {
        // A check cancelled because a newer request from this same caller
        // replaced it says nothing about the node; recording an outcome
        // for it would read as a node failure downstream.
        if (entry.value.status == ServiceProbeStatus.cancelled) {
          continue;
        }
        for (final serviceId in nativeByTarget[entry.key] ?? const <String>[]) {
          access[serviceId] = accessResultFromStatus(
            serviceId: serviceId,
            proxyName: proxyName,
            egressIp: egress?.ip ?? '',
            status: entry.value.status,
            checkedAt: nowMs,
          );
        }
        final borrowers =
            borrowersByTarget[entry.key] ?? const <String, String>{};
        for (final borrower in borrowers.entries) {
          access[borrower.key] = accessResultFromStatus(
            serviceId: borrower.key,
            proxyName: proxyName,
            egressIp: egress?.ip ?? '',
            status: entry.value.status,
            checkedAt: nowMs,
            borrowedFrom: borrower.value,
          );
        }
      }
    }
    return ProbeOutcome(
      metadata: metadata,
      accessByService: access,
      metadataFailure: metadataFailure,
    );
  }
}

GeoLookup geoLookupFromService(GeoIpService service) {
  return ({
    required String ip,
    required String proxyName,
    required String entryServer,
    required bool wafPass,
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
