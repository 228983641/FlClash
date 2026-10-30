import 'dart:async';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/function.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/switch_event.dart';
import 'package:fl_clash/smart_anchor/services/api_pool.dart';
import 'package:fl_clash/smart_anchor/models/service_group.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:fl_clash/smart_anchor/services/probing.dart';
import 'package:fl_clash/smart_anchor/services/sa_log.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
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
  int? _lastProbeProfileId;
  final Map<String, int> _lastProbeAttempt = {};
  bool _probeRunning = false;

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
    var anchorsCleared = 0;
    if (changed) {
      // Drop the targets' anchors in the same update: the save it triggers
      // then carries no stale anchor, instead of a separate delete racing
      // that save's write phase and resurrecting the anchor on restart.
      final anchors = Map.of(next.anchors);
      for (final id in targets) {
        if (anchors.remove(id) != null) {
          anchorsCleared++;
        }
      }
      if (anchorsCleared > 0) {
        next = next.copyWith(anchors: anchors);
      }
    }
    update(next);
    if (changed) {
      commonPrint.log(
        saLockChangeLine(
          serviceId: serviceId,
          services: targets.length,
          anchorsCleared: anchorsCleared,
          countries: normalized,
        ),
      );
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
    if (_probeRunning || !ref.mounted) return 0;
    var profileChanged = false;
    final profileSubscription = ref.listen(currentProfileIdProvider, (_, _) {
      profileChanged = true;
      _lastProbeAt = null;
      _lastProbeAttempt.clear();
    });
    _probeRunning = true;
    try {
      final profileId = ref.read(currentProfileIdProvider);
      final enabled = state.services.where((service) => service.isEnabled);
      if (enabled.isEmpty) {
        return 0;
      }
      final now = DateTime.now();
      if (!force &&
          _lastProbeProfileId == profileId &&
          _lastProbeAt != null &&
          now.difference(_lastProbeAt!) < const Duration(minutes: 10)) {
        return 0;
      }
      if (updateThrottle) {
        _lastProbeProfileId = profileId;
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
      final wafOutcomeByNode = <String, String>{};
      final prober = SmartAnchorProber(
        egressLookup: (name) async =>
            parseOutboundIp(await lookupOutboundIp(core, name)),
        serviceCheckLookup: (name, targets) async => checkServices(
          core,
          proxyName: name,
          targets: targets,
          scope: serviceCheckScopeProbe,
        ),
        geoLookup: geoLookupFromService(geoService),
        wafLookup: (name) async {
          final result = await core.probe(
            ProbeParams(
              url: cloudflareTraceUrl,
              proxyName: name,
              headers: const {'User-Agent': browserUa},
              timeout: outboundIpTimeoutDuration.inMilliseconds,
              maxBody: 4096,
            ),
          );
          final pass = wafPassFromTraceProbe(result);
          wafOutcomeByNode[name] = result == null || result.error != null
              ? 'unknown'
              : (pass ? 'pass' : 'fail');
          return pass;
        },
      );
      final rankByProxy = <String, int>{};
      final standby = <String>[];
      final currentSet = {currentProxyName, ...currentProxyNames};
      final availableNames = {...proxyNames, ...currentSet};
      _lastProbeAttempt.removeWhere(
        (name, _) => !availableNames.contains(name),
      );
      for (final service in enabled) {
        final ranked = rankedProxiesForService(
          state,
          service,
          proxyNames,
          delays: delays,
        );
        standby.addAll(
          ranked.where((name) => !currentSet.contains(name)).take(2),
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
        standbyProxyNames: standby,
        lastAttemptByProxy: _lastProbeAttempt,
      );
      final serviceIds = [for (final service in enabled) service.serviceId];
      final metadata = Map.of(state.metadataByProxy);
      final access = <String, Map<String, ServiceAccessResult>>{
        for (final entry in state.accessByService.entries)
          entry.key: Map.of(entry.value),
      };
      var changed = false;
      final reasonCounts = <ServiceAccessReason, int>{};
      final currentNames = {currentProxyName, ...currentProxyNames};
      var metaOk = 0;
      var noEgress = 0;
      var geoFailed = 0;
      var wafPassCount = 0;
      var wafFailCount = 0;
      var wafUnknownCount = 0;
      final fanoutByDonor =
          <String, ({Set<String> borrowers, Set<String> nodes})>{};
      const probeConcurrency = 4;
      for (var i = 0; i < targets.length; i += probeConcurrency) {
        if (!ref.mounted || profileChanged) {
          return 0;
        }
        final end = i + probeConcurrency < targets.length
            ? i + probeConcurrency
            : targets.length;
        final chunk = targets.sublist(i, end);
        final outcomes = await Future.wait(
          chunk.map((name) async {
            _lastProbeAttempt[name] = DateTime.now().millisecondsSinceEpoch;
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
          final failure = result.metadataFailure;
          if (result.metadata != null) {
            metaOk++;
            if (currentNames.contains(outcome.key)) {
              final previous = metadata[outcome.key];
              if (previous != null) {
                final fromTier = ScoringEngine.trustTier(previous.purityScore);
                final toTier = ScoringEngine.trustTier(
                  result.metadata!.purityScore,
                );
                if (fromTier != toTier) {
                  commonPrint.log(
                    saPurityTierLine(
                      node: outcome.key,
                      fromTier: fromTier,
                      toTier: toTier,
                      score: result.metadata!.purityScore,
                    ),
                  );
                }
              }
            }
            metadata[outcome.key] = result.metadata!;
            updated++;
            changed = true;
          } else if (failure != null) {
            if (failure == 'no-egress') {
              noEgress++;
            } else {
              geoFailed++;
            }
            commonPrint.log(saMetaFailLine(node: outcome.key, reason: failure));
          }
          if (failure == 'no-egress') {
            wafUnknownCount++;
          } else {
            switch (wafOutcomeByNode[outcome.key]) {
              case 'pass':
                wafPassCount++;
              case 'fail':
                wafFailCount++;
              default:
                wafUnknownCount++;
            }
          }
          for (final entry in result.accessByService.entries) {
            (access[entry.key] ??= {})[outcome.key] = entry.value;
            reasonCounts[entry.value.reason] =
                (reasonCounts[entry.value.reason] ?? 0) + 1;
            changed = true;
            final donor = entry.value.borrowedFrom;
            if (donor != null) {
              final fanout = fanoutByDonor[donor] ??= (
                borrowers: <String>{},
                nodes: <String>{},
              );
              fanout.borrowers.add(entry.key);
              fanout.nodes.add(outcome.key);
            }
          }
        }
      }
      if (targets.isNotEmpty) {
        commonPrint.log(
          saProbeRoundLine(
            nodes: targets.length,
            metaUpdated: updated,
            reasonCounts: reasonCounts,
          ),
        );
        commonPrint.log(
          saMetaRoundLine(
            probed: targets.length,
            metaOk: metaOk,
            metaFailed: noEgress + geoFailed,
            noEgress: noEgress,
            geoFailed: geoFailed,
            wafPass: wafPassCount,
            wafFail: wafFailCount,
            wafUnknown: wafUnknownCount,
          ),
        );
        final donors = fanoutByDonor.keys.toList()..sort();
        for (final donor in donors) {
          final fanout = fanoutByDonor[donor]!;
          commonPrint.log(
            saBorrowFanoutLine(
              donor: donor,
              borrowers: fanout.borrowers.toList(),
              nodes: fanout.nodes.length,
            ),
          );
        }
        final remaining = proxyNames
            .where((name) => probeMetadataStale(metadata[name]))
            .length;
        commonPrint.log(
          saProbeQueueLine(
            probed: targets.length,
            remaining: remaining,
            total: proxyNames.length,
          ),
        );
      }
      if (!ref.mounted || profileChanged) return 0;
      if (changed) {
        final nextInput = state.copyWith(
          metadataByProxy: metadata,
          accessByService: access,
        );
        for (final service in enabled) {
          final before = derivedRegionEvidence(state, service.serviceId);
          final after = derivedRegionEvidence(nextInput, service.serviceId);
          final blockedChanged =
              before.blocked.length != after.blocked.length ||
              !before.blocked.containsAll(after.blocked);
          var heldChanged = before.heldBack.length != after.heldBack.length;
          if (!heldChanged) {
            for (final entry in after.heldBack.entries) {
              if (before.heldBack[entry.key] != entry.value) {
                heldChanged = true;
                break;
              }
            }
          }
          if (!blockedChanged && !heldChanged) {
            continue;
          }
          commonPrint.log(
            saDerivedRegionsLine(
              serviceId: service.serviceId,
              blockedBefore: before.blocked,
              blockedAfter: after.blocked,
              heldBack: after.heldBack,
            ),
          );
          for (final country in after.blocked.difference(before.blocked)) {
            final serviceAccess = access[service.serviceId] ?? const {};
            for (final entry in serviceAccess.entries) {
              final verdict = entry.value;
              if (verdict.borrowedFrom != null &&
                  verdict.reason == ServiceAccessReason.regionBlocked &&
                  !verdict.isExpired &&
                  metadata[entry.key]?.countryCode == country) {
                commonPrint.log(
                  saBorrowExcludeLine(
                    serviceId: service.serviceId,
                    node: entry.key,
                    donor: verdict.borrowedFrom!,
                    via: 'region',
                  ),
                );
                break;
              }
            }
          }
        }
        update(nextInput);
      }
      return updated;
    } finally {
      profileSubscription.close();
      _probeRunning = false;
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
