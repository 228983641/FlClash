import 'dart:async';

import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/smart_anchor/services/api_pool.dart';
import 'package:fl_clash/smart_anchor/models/service_group.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:fl_clash/smart_anchor/services/probing.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
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
    return SmartAnchorInput(
      services: [
        for (final service in defaultServiceToggles)
          service.copyWith(isEnabled: false),
      ],
      sharedLockGroupIds: const ['google-group'],
    );
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
      sharedLockGroupIds: snapshot.sharedLockGroupIds,
    );
  }

  void updateService(
    String serviceId, {
    bool? isEnabled,
    String? targetCountry,
  }) {
    if (isEnabled != null) {
      final byId = {
        for (final service in defaultServiceToggles) service.serviceId: service,
        for (final service in state.services) service.serviceId: service,
      };
      final current = byId[serviceId];
      if (current == null) {
        return;
      }
      byId[serviceId] = current.copyWith(isEnabled: isEnabled);
      update(
        state.copyWith(
          services: [
            for (final service in defaultServiceToggles)
              byId[service.serviceId]!,
          ],
        ),
      );
    }
    if (targetCountry != null) {
      setLockCountries(
        serviceId,
        targetCountry.isEmpty ? const [] : [targetCountry],
      );
    }
  }

  void setLockCountries(String serviceId, List<String> countries) {
    final normalized = <String>[];
    for (final country in countries) {
      final code = country.trim().toUpperCase();
      if (code.isNotEmpty && !normalized.contains(code)) {
        normalized.add(code);
      }
    }
    final byId = {
      for (final service in defaultServiceToggles) service.serviceId: service,
      for (final service in state.services) service.serviceId: service,
    };
    final group = groupForService(serviceId);
    final targets = group != null && state.sharedLockGroupIds.contains(group.id)
        ? group.serviceIds
        : [serviceId];
    var changed = false;
    for (final id in targets) {
      final member = byId[id];
      if (member == null) {
        continue;
      }
      if (member.lockedCountries.join(',') != normalized.join(',')) {
        changed = true;
      }
      byId[id] = member.copyWith(
        targetCountries: normalized,
        targetCountry: normalized.isEmpty ? '' : normalized.first,
      );
    }
    update(
      state.copyWith(
        services: [
          for (final service in defaultServiceToggles) byId[service.serviceId]!,
        ],
      ),
    );
    if (changed) {
      for (final id in targets) {
        clearAnchor(id);
      }
    }
  }

  void setSharedLockGroup(String groupId, bool enabled) {
    final ids = [
      for (final id in state.sharedLockGroupIds)
        if (id != groupId) id,
    ];
    if (enabled) {
      ids.add(groupId);
    }
    update(state.copyWith(sharedLockGroupIds: ids));
    if (!enabled) {
      return;
    }
    ServiceGroup? group;
    for (final candidate in defaultServiceGroups) {
      if (candidate.id == groupId) {
        group = candidate;
      }
    }
    if (group == null || group.serviceIds.isEmpty) {
      return;
    }
    final first = state.services.firstWhere(
      (service) => service.serviceId == group!.serviceIds.first,
      orElse: () => defaultServiceToggles.first,
    );
    setLockCountries(first.serviceId, first.lockedCountries);
  }

  void setAggregationMode(AggregationGroupMode mode) {
    update(state.copyWith(aggregationMode: mode));
  }

  void setAggregationSource({
    required String sourceId,
    required String sourceLabel,
    required Map<String, dynamic> config,
    required bool enabled,
  }) {
    final sources = [
      for (final source in state.aggregationSources)
        if (source.sourceId != sourceId) source,
    ];
    if (enabled) {
      sources.add(
        AggregationSourceInput(
          sourceId: sourceId,
          sourceLabel: sourceLabel,
          config: config,
        ),
      );
    }
    update(state.copyWith(aggregationSources: sources));
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
