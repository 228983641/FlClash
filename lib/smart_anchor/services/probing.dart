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

List<String> selectFullProbeTargets({
  required List<String> proxyNames,
  required String current,
  required Map<String, int> delays,
}) {
  final measured = <String, int>{};
  for (final name in proxyNames) {
    final delay = delays[name];
    if (delay != null && delay > 0) {
      measured[name] = delay;
    }
  }
  if (measured.isEmpty) {
    return [];
  }
  final sorted = measured.values.toList()..sort();
  final middle = sorted.length ~/ 2;
  final median = sorted.length.isOdd
      ? sorted[middle].toDouble()
      : (sorted[middle - 1] + sorted[middle]) / 2;
  final aboveMedian =
      measured.entries
          .where((entry) => entry.value <= median)
          .map((entry) => entry.key)
          .toList()
        ..sort((a, b) => measured[a]!.compareTo(measured[b]!));
  final targets = <String>[];
  if (current.isNotEmpty && !targets.contains(current)) {
    targets.add(current);
  }
  for (final name in aboveMedian) {
    if (!targets.contains(name)) {
      targets.add(name);
    }
  }
  return targets;
}

List<String> selectProbeTargets({
  required List<String> ranked,
  required String current,
  int topK = 20,
}) {
  final targets = <String>[];
  if (current.isNotEmpty && !targets.contains(current)) {
    targets.add(current);
  }
  for (final name in ranked) {
    if (targets.length >= topK + (current.isNotEmpty ? 1 : 0)) {
      break;
    }
    if (!targets.contains(name)) {
      targets.add(name);
    }
  }
  return targets;
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
