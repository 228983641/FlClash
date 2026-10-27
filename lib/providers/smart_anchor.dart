import 'dart:async';

import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/smart_anchor/services/api_pool.dart';
import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:fl_clash/smart_anchor/services/probing.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/smart_anchor.g.dart';

@Riverpod(keepAlive: true)
class SmartAnchor extends _$SmartAnchor {
  SmartAnchorStore get _store => SmartAnchorStore.drift();

  DateTime? _lastProbeAt;

  @override
  SmartAnchorInput build() {
    return const SmartAnchorInput();
  }

  void update(SmartAnchorInput next) {
    state = next;
    unawaited(_store.save(next));
  }

  Future<void> restore() async {
    final snapshot = await _store.load();
    if (snapshot == null) {
      return;
    }
    state = state.copyWith(
      services: snapshot.services.isEmpty ? null : snapshot.services,
      anchors: snapshot.anchors,
      metadataByProxy: snapshot.metadataByProxy,
      accessByService: snapshot.accessByService,
    );
  }

  void clearAnchor(String serviceId) {
    final anchors = Map.of(state.anchors)..remove(serviceId);
    state = state.copyWith(anchors: anchors);
    unawaited(_store.deleteAnchor(serviceId));
  }

  Future<void> probeNodes({
    required List<String> proxyNames,
    required String currentProxyName,
    Map<String, String> entryServers = const {},
    bool force = false,
  }) async {
    final enabled = state.services.where((service) => service.isEnabled);
    if (enabled.isEmpty) {
      return;
    }
    final now = DateTime.now();
    if (!force &&
        _lastProbeAt != null &&
        now.difference(_lastProbeAt!) < const Duration(minutes: 10)) {
      return;
    }
    _lastProbeAt = now;
    final core = ref.read(coreHandlerProvider);
    final geoService = GeoIpService(
      cache: GeoIpCache(),
      fetcher: _dioGeoFetcher,
      keyPools: const {},
    );
    final prober = SmartAnchorProber(
      egressLookup: (name) async =>
          parseOutboundIp(await lookupOutboundIp(core, name)),
      serviceCheckLookup: (name, targets) async =>
          checkServices(core, proxyName: name, targets: targets),
      geoLookup: geoLookupFromService(geoService, true),
    );
    final targets = selectProbeTargets(
      ranked: proxyNames,
      current: currentProxyName,
    );
    final serviceIds = [for (final service in enabled) service.serviceId];
    for (final name in targets) {
      final outcome = await prober.probeNode(
        proxyName: name,
        entryServer: entryServers[name] ?? '',
        serviceIds: serviceIds,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      final metadata = Map.of(state.metadataByProxy);
      if (outcome.metadata != null) {
        metadata[name] = outcome.metadata!;
      }
      final access = <String, Map<String, ServiceAccessResult>>{};
      for (final entry in state.accessByService.entries) {
        access[entry.key] = Map.of(entry.value);
      }
      for (final entry in outcome.accessByService.entries) {
        (access[entry.key] ??= {})[name] = entry.value;
      }
      update(
        state.copyWith(metadataByProxy: metadata, accessByService: access),
      );
    }
  }
}

Future<Map<String, dynamic>?> _dioGeoFetcher(
  String ip,
  String? apiKey,
  String sourceId,
) async {
  final url = switch (sourceId) {
    'ip-api' => 'http://ip-api.com/json/$ip',
    'ipinfo' => 'https://ipinfo.io/$ip/json',
    'ip.sb' => 'https://api.ip.sb/geoip/$ip',
    _ => null,
  };
  if (url == null) {
    return null;
  }
  try {
    final response = await request.dio.get<Map<String, dynamic>>(url);
    return response.data;
  } catch (_) {
    return null;
  }
}
