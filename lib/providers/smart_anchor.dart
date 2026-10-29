import 'dart:async';

import 'package:fl_clash/common/function.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/switch_event.dart';
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

  // Saves and anchor deletes share one queue: save() writes a full
  // snapshot, so an unserialized earlier save landing after a later change
  // could resurrect state (e.g. a cleared anchor) it still contains.
  final _storeScheduler = SerialTaskScheduler();

  DateTime? _lastProbeAt;

  @override
  SmartAnchorInput build() {
    return const SmartAnchorInput(
      services: [...defaultServiceToggles],
      sharedLockGroupIds: ['google-group'],
    );
  }

  void update(SmartAnchorInput next) {
    state = next;
    unawaited(_storeScheduler.run(() => _store.save(next)));
  }

  Future<void> restore() async {
    SmartAnchorSnapshot? snapshot;
    try {
      snapshot = await _store.load();
    } catch (_) {
      // A failed restore keeps the built-in defaults instead of failing
      // startup; the next save rewrites the record.
      return;
    }
    if (snapshot == null) {
      return;
    }
    final mergedServices = snapshot.services.isEmpty
        ? null
        : [
            for (final def in defaultServiceToggles)
              snapshot.services.firstWhere(
                (service) => service.serviceId == def.serviceId,
                orElse: () => def,
              ),
            for (final service in snapshot.services)
              if (!defaultServiceToggles.any(
                (def) => def.serviceId == service.serviceId,
              ))
                service,
          ];
    state = state.copyWith(
      services: mergedServices,
      anchors: snapshot.anchors,
      metadataByProxy: snapshot.metadataByProxy,
      accessByService: snapshot.accessByService,
      sharedLockGroupIds: snapshot.sharedLockGroupIds,
      autoFailoverEnabled: snapshot.autoFailoverEnabled,
      paths: snapshot.paths,
      aggregationEnabled: snapshot.aggregationEnabled,
      aggregationMode: snapshot.aggregationMode,
      aggregationSources: snapshot.aggregationSources,
      switchEvents: snapshot.switchEvents,
    );
  }

  Future<SmartAnchorInput> refreshAggregationSources() async {
    if (!state.aggregationEnabled) {
      return state;
    }
    final stubs = [
      for (final source in state.aggregationSources)
        if (source.config.isEmpty) source,
    ];
    if (stubs.isEmpty) {
      return state;
    }
    final core = ref.read(coreHandlerProvider);
    final sources = <AggregationSourceInput>[];
    var changed = false;
    for (final source in state.aggregationSources) {
      if (!stubs.contains(source)) {
        sources.add(source);
        continue;
      }
      final sourceId = source.sourceId;
      if (!sourceId.startsWith('profile:')) {
        sources.add(source);
        continue;
      }
      final profileId = int.tryParse(sourceId.substring('profile:'.length));
      if (profileId == null) {
        sources.add(source);
        continue;
      }
      try {
        final config = await core.getConfig(profileId);
        sources.add(
          AggregationSourceInput(
            sourceId: source.sourceId,
            sourceLabel: source.sourceLabel,
            config: config,
          ),
        );
        changed = true;
      } catch (_) {
        changed = true;
      }
    }
    if (!changed) {
      return state;
    }
    final next = state.copyWith(aggregationSources: sources);
    update(next);
    return next;
  }

  void setAutoFailover(bool enabled) {
    update(state.copyWith(autoFailoverEnabled: enabled));
  }

  List<ServiceToggleConfig> _mergedServices(
    Map<String, ServiceToggleConfig> byId,
  ) {
    final defaultIds = {
      for (final service in defaultServiceToggles) service.serviceId,
    };
    return [
      for (final service in defaultServiceToggles) byId[service.serviceId]!,
      for (final service in state.services)
        if (!defaultIds.contains(service.serviceId))
          byId[service.serviceId] ?? service,
    ];
  }

  void upsertService(ServiceToggleConfig config) {
    final byId = {
      for (final service in defaultServiceToggles) service.serviceId: service,
      for (final service in state.services) service.serviceId: service,
    };
    byId[config.serviceId] = config;
    update(state.copyWith(services: _mergedServices(byId)));
  }

  void deleteService(String serviceId) {
    if (defaultServiceToggles.any(
      (service) => service.serviceId == serviceId,
    )) {
      return;
    }
    update(
      state.copyWith(
        services: [
          for (final service in state.services)
            if (service.serviceId != serviceId) service,
        ],
      ),
    );
    clearAnchor(serviceId);
    clearPath(serviceId);
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
      update(state.copyWith(services: _mergedServices(byId)));
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
    var next = state.copyWith(services: _mergedServices(byId));
    if (changed) {
      // Drop the targets' anchors in the same update: the save it triggers
      // then carries no stale anchor, instead of a separate delete racing
      // that save's write phase and resurrecting the anchor on restart.
      final anchors = Map.of(next.anchors);
      var removed = false;
      for (final id in targets) {
        removed = anchors.remove(id) != null || removed;
      }
      if (removed) {
        next = next.copyWith(anchors: anchors);
      }
    }
    update(next);
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

  void setAggregationEnabled(bool enabled) {
    update(state.copyWith(aggregationEnabled: enabled));
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
    unawaited(_storeScheduler.run(() => _store.deleteAnchor(serviceId)));
  }

  void setAnchor(String serviceId, ServiceAnchor anchor) {
    update(state.copyWith(anchors: {...state.anchors, serviceId: anchor}));
  }

  void recordSwitchEvent(SwitchEvent event) {
    final events = Map.of(state.switchEvents);
    events[event.serviceId] = appendSwitchEvent(
      events[event.serviceId] ?? const [],
      event,
    );
    update(state.copyWith(switchEvents: events));
  }

  void recordPathPoint(AnchorPathPoint point) {
    final paths = Map.of(state.paths);
    paths[point.serviceId] = appendPathPoint(
      paths[point.serviceId] ?? const [],
      point,
    );
    update(state.copyWith(paths: paths));
  }

  void clearPath(String serviceId) {
    final paths = Map.of(state.paths)..remove(serviceId);
    update(state.copyWith(paths: paths));
  }

  Future<int> probeNodes({
    required List<String> proxyNames,
    required String currentProxyName,
    List<String> currentProxyNames = const [],
    Map<String, String> entryServers = const {},
    Map<String, int> delays = const {},
    bool force = false,
    bool updateThrottle = true,
  }) async {
    final enabled = state.services.where((service) => service.isEnabled);
    if (enabled.isEmpty) {
      return 0;
    }
    final now = DateTime.now();
    if (!force &&
        _lastProbeAt != null &&
        now.difference(_lastProbeAt!) < const Duration(minutes: 10)) {
      return 0;
    }
    if (updateThrottle) {
      _lastProbeAt = now;
    }
    var updated = 0;
    final core = ref.read(coreHandlerProvider);
    final geoCache = GeoIpCache();
    for (final entry in state.metadataByProxy.values) {
      geoCache.put(entry);
    }
    final geoService = GeoIpService(
      cache: geoCache,
      fetcher: _dioGeoFetcher,
      keyPools: const {},
    );
    final prober = SmartAnchorProber(
      egressLookup: (name) async =>
          parseOutboundIp(await lookupOutboundIp(core, name)),
      serviceCheckLookup: (name, targets) async => checkServices(
        core,
        proxyName: name,
        targets: targets,
        scope: serviceCheckScopeProbe,
      ),
      geoLookup: geoLookupFromService(geoService, true),
    );
    final rankByProxy = <String, int>{};
    for (final service in enabled) {
      final ranked = rankedProxiesForService(
        state,
        service,
        proxyNames,
        delays: delays,
      );
      for (var index = 0; index < ranked.length; index++) {
        final best = rankByProxy[ranked[index]];
        if (best == null || index < best) {
          rankByProxy[ranked[index]] = index;
        }
      }
    }
    final targets = selectProbeQueue(
      proxyNames: proxyNames,
      currentProxyNames: [currentProxyName, ...currentProxyNames],
      metadataByProxy: state.metadataByProxy,
      rankByProxy: rankByProxy,
    );
    final serviceIds = [for (final service in enabled) service.serviceId];
    final metadata = Map.of(state.metadataByProxy);
    final access = <String, Map<String, ServiceAccessResult>>{
      for (final entry in state.accessByService.entries)
        entry.key: Map.of(entry.value),
    };
    var changed = false;
    const probeConcurrency = 4;
    for (var i = 0; i < targets.length; i += probeConcurrency) {
      final end = i + probeConcurrency < targets.length
          ? i + probeConcurrency
          : targets.length;
      final chunk = targets.sublist(i, end);
      final outcomes = await Future.wait(
        chunk.map((name) async {
          try {
            return MapEntry(
              name,
              await prober.probeNode(
                proxyName: name,
                entryServer: entryServers[name] ?? '',
                serviceIds: serviceIds,
                nowMs: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          } catch (_) {
            return null;
          }
        }),
      );
      for (final outcome in outcomes) {
        if (outcome == null) {
          continue;
        }
        final result = outcome.value;
        if (result.metadata != null) {
          metadata[outcome.key] = result.metadata!;
          updated++;
          changed = true;
        }
        for (final entry in result.accessByService.entries) {
          (access[entry.key] ??= {})[outcome.key] = entry.value;
          changed = true;
        }
      }
    }
    if (changed) {
      update(
        state.copyWith(metadataByProxy: metadata, accessByService: access),
      );
    }
    return updated;
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
    'ipwho.is' => 'https://ipwho.is/$ip',
    'freeipapi' => 'https://freeipapi.com/api/json/$ip',
    'geojs' => 'https://get.geojs.io/v1/ip/geo/$ip.json',
    'ipapi.co' => 'https://ipapi.co/$ip/json/',
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
