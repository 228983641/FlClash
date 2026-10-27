import 'dart:convert';

import 'package:fl_clash/database/database.dart';
import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/models/switch_event.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';

abstract class SmartAnchorRecordStore {
  Future<Map<String, String>> readAll();

  Future<void> write(String key, String payload);

  Future<void> delete(String key);

  Future<void> deleteWithPrefix(String prefix);
}

class DriftSmartAnchorRecordStore implements SmartAnchorRecordStore {
  DriftSmartAnchorRecordStore(this.db);

  final Database db;

  @override
  Future<Map<String, String>> readAll() async {
    final rows = await db.smartAnchorDao.all();
    return {for (final row in rows) row.key: row.payload};
  }

  @override
  Future<void> write(String key, String payload) {
    return db.smartAnchorDao.put(key, payload, DateTime.now());
  }

  @override
  Future<void> delete(String key) {
    return db.smartAnchorDao.remove(key);
  }

  @override
  Future<void> deleteWithPrefix(String prefix) {
    return db.smartAnchorDao.removeWithPrefix(prefix);
  }
}

class InMemorySmartAnchorRecordStore implements SmartAnchorRecordStore {
  final Map<String, String> records = {};

  @override
  Future<Map<String, String>> readAll() async => Map.of(records);

  @override
  Future<void> write(String key, String payload) async {
    records[key] = payload;
  }

  @override
  Future<void> delete(String key) async {
    records.remove(key);
  }

  @override
  Future<void> deleteWithPrefix(String prefix) async {
    records.removeWhere((key, _) => key.startsWith(prefix));
  }
}

class SmartAnchorSnapshot {
  const SmartAnchorSnapshot({
    this.services = const [],
    this.anchors = const {},
    this.metadataByProxy = const {},
    this.accessByService = const {},
    this.sharedLockGroupIds = const [],
    this.autoFailoverEnabled = true,
    this.paths = const {},
    this.aggregationMode = AggregationGroupMode.primaryOnly,
    this.aggregationSources = const [],
    this.switchEvents = const {},
  });

  final List<ServiceToggleConfig> services;
  final Map<String, ServiceAnchor> anchors;
  final Map<String, NodeMetadataCache> metadataByProxy;
  final Map<String, Map<String, ServiceAccessResult>> accessByService;
  final List<String> sharedLockGroupIds;
  final bool autoFailoverEnabled;
  final Map<String, List<AnchorPathPoint>> paths;
  final AggregationGroupMode aggregationMode;
  final List<AggregationSourceInput> aggregationSources;
  final Map<String, List<SwitchEvent>> switchEvents;

  Map<String, dynamic> toJson() {
    return {
      'services': [for (final service in services) service.toJson()],
      'sharedLockGroupIds': sharedLockGroupIds,
      'autoFailoverEnabled': autoFailoverEnabled,
      'anchors': {
        for (final entry in anchors.entries) entry.key: entry.value.toJson(),
      },
      'metadata': {
        for (final entry in metadataByProxy.entries)
          entry.key: entry.value.toJson(),
      },
      'access': {
        for (final entry in accessByService.entries)
          entry.key: {
            for (final inner in entry.value.entries)
              inner.key: inner.value.toJson(),
          },
      },
      'paths': {
        for (final entry in paths.entries)
          entry.key: [for (final point in entry.value) point.toJson()],
      },
      'aggregationMode': aggregationMode.name,
      'aggregationSources': [
        for (final source in aggregationSources)
          {'sourceId': source.sourceId, 'sourceLabel': source.sourceLabel},
      ],
      'switchEvents': {
        for (final entry in switchEvents.entries)
          entry.key: [for (final event in entry.value) event.toJson()],
      },
    };
  }

  factory SmartAnchorSnapshot.fromJson(Map<String, dynamic> json) {
    final services = <ServiceToggleConfig>[];
    for (final item in json['services'] as List? ?? []) {
      if (item is Map) {
        services.add(
          ServiceToggleConfig.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    final anchors = <String, ServiceAnchor>{};
    for (final entry in (json['anchors'] as Map? ?? {}).entries) {
      if (entry.value is Map) {
        anchors[entry.key.toString()] = ServiceAnchor.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }
    final metadata = <String, NodeMetadataCache>{};
    for (final entry in (json['metadata'] as Map? ?? {}).entries) {
      if (entry.value is Map) {
        final node = NodeMetadataCache.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (!node.isExpired) {
          metadata[entry.key.toString()] = node;
        }
      }
    }
    final access = <String, Map<String, ServiceAccessResult>>{};
    for (final entry in (json['access'] as Map? ?? {}).entries) {
      if (entry.value is! Map) {
        continue;
      }
      final inner = <String, ServiceAccessResult>{};
      for (final item in (entry.value as Map).entries) {
        if (item.value is Map) {
          final result = ServiceAccessResult.fromJson(
            Map<String, dynamic>.from(item.value as Map),
          );
          if (!result.isExpired) {
            inner[item.key.toString()] = result;
          }
        }
      }
      if (inner.isNotEmpty) {
        access[entry.key.toString()] = inner;
      }
    }
    final shared = json['sharedLockGroupIds'];
    final modeRaw = json['aggregationMode'];
    final mode = AggregationGroupMode.values.firstWhere(
      (candidate) => candidate.name == modeRaw,
      orElse: () => AggregationGroupMode.primaryOnly,
    );
    final sources = <AggregationSourceInput>[];
    for (final item in json['aggregationSources'] as List? ?? []) {
      if (item is Map) {
        final map = Map<String, dynamic>.from(item);
        final sourceId = map['sourceId'];
        if (sourceId is String && sourceId.isNotEmpty) {
          sources.add(
            AggregationSourceInput(
              sourceId: sourceId,
              sourceLabel: map['sourceLabel']?.toString() ?? '',
              config: const {},
            ),
          );
        }
      }
    }
    final switchEvents = <String, List<SwitchEvent>>{};
    for (final entry in (json['switchEvents'] as Map? ?? {}).entries) {
      if (entry.value is! List) {
        continue;
      }
      final events = <SwitchEvent>[];
      for (final item in entry.value as List) {
        if (item is Map) {
          events.add(SwitchEvent.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      if (events.isNotEmpty) {
        switchEvents[entry.key.toString()] = events;
      }
    }
    final paths = <String, List<AnchorPathPoint>>{};
    for (final entry in (json['paths'] as Map? ?? {}).entries) {
      if (entry.value is! List) {
        continue;
      }
      final points = <AnchorPathPoint>[];
      for (final item in entry.value as List) {
        if (item is Map) {
          points.add(AnchorPathPoint.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      if (points.isNotEmpty) {
        paths[entry.key.toString()] = points;
      }
    }
    return SmartAnchorSnapshot(
      services: services,
      anchors: anchors,
      metadataByProxy: metadata,
      accessByService: access,
      sharedLockGroupIds: shared is List
          ? [for (final id in shared) id.toString()]
          : const [],
      autoFailoverEnabled: json['autoFailoverEnabled'] as bool? ?? true,
      paths: paths,
      aggregationMode: mode,
      aggregationSources: sources,
      switchEvents: switchEvents,
    );
  }

  SmartAnchorInput toInput() {
    return SmartAnchorInput(
      services: services,
      anchors: anchors,
      metadataByProxy: metadataByProxy,
      accessByService: accessByService,
      sharedLockGroupIds: sharedLockGroupIds,
      autoFailoverEnabled: autoFailoverEnabled,
      paths: paths,
      aggregationMode: aggregationMode,
      aggregationSources: aggregationSources,
      switchEvents: switchEvents,
    );
  }
}

class SmartAnchorStore {
  SmartAnchorStore(this.records);

  factory SmartAnchorStore.drift() {
    return SmartAnchorStore(DriftSmartAnchorRecordStore(database));
  }

  final SmartAnchorRecordStore records;

  static String anchorKey(String serviceId) => 'anchor:$serviceId';

  static String nodeKey(String proxyName) => 'node:$proxyName';

  static String accessKey(String serviceId, String proxyName) =>
      'access:$serviceId:$proxyName';

  static const servicesKey = 'config:services';

  static const sharedGroupsKey = 'config:sharedGroups';

  static const autoFailoverKey = 'config:autoFailover';

  static const aggregationModeKey = 'config:aggregationMode';

  static const aggregationSourcesKey = 'config:aggregationSources';

  static String pathKey(String serviceId) => 'path:$serviceId';

  static String switchKey(String serviceId) => 'switch:$serviceId';

  Future<SmartAnchorSnapshot?> load() async {
    final all = await records.readAll();
    if (all.isEmpty) {
      return null;
    }
    final services = <ServiceToggleConfig>[];
    final servicesRaw = all[servicesKey];
    if (servicesRaw != null) {
      final decoded = json.decode(servicesRaw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            services.add(
              ServiceToggleConfig.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      }
    }
    final anchors = <String, ServiceAnchor>{};
    final metadata = <String, NodeMetadataCache>{};
    final access = <String, Map<String, ServiceAccessResult>>{};
    final paths = <String, List<AnchorPathPoint>>{};
    final switchEvents = <String, List<SwitchEvent>>{};
    final autoFailoverRaw = all[autoFailoverKey];
    var autoFailoverEnabled = true;
    if (autoFailoverRaw != null) {
      final decoded = json.decode(autoFailoverRaw);
      if (decoded is bool) {
        autoFailoverEnabled = decoded;
      }
    }
    var aggregationMode = AggregationGroupMode.primaryOnly;
    final modeRaw = all[aggregationModeKey];
    if (modeRaw != null) {
      final decoded = json.decode(modeRaw);
      if (decoded is String) {
        aggregationMode = AggregationGroupMode.values.firstWhere(
          (candidate) => candidate.name == decoded,
          orElse: () => AggregationGroupMode.primaryOnly,
        );
      }
    }
    final aggregationSources = <AggregationSourceInput>[];
    final sourcesRaw = all[aggregationSourcesKey];
    if (sourcesRaw != null) {
      final decoded = json.decode(sourcesRaw);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final sourceId = map['sourceId'];
            if (sourceId is String && sourceId.isNotEmpty) {
              aggregationSources.add(
                AggregationSourceInput(
                  sourceId: sourceId,
                  sourceLabel: map['sourceLabel']?.toString() ?? '',
                  config: const {},
                ),
              );
            }
          }
        }
      }
    }
    final sharedRaw = all[sharedGroupsKey];
    final sharedIds = <String>[];
    if (sharedRaw == null) {
      sharedIds.add('google-group');
    } else {
      final decoded = json.decode(sharedRaw);
      if (decoded is List) {
        for (final id in decoded) {
          sharedIds.add(id.toString());
        }
      }
    }
    for (final entry in all.entries) {
      final key = entry.key;
      final decoded = json.decode(entry.value);
      if (key.startsWith('path:')) {
        if (decoded is List) {
          final points = <AnchorPathPoint>[];
          for (final item in decoded) {
            if (item is Map) {
              points.add(
                AnchorPathPoint.fromJson(Map<String, dynamic>.from(item)),
              );
            }
          }
          if (points.isNotEmpty) {
            paths[key.substring('path:'.length)] = points;
          }
        }
        continue;
      }
      if (key.startsWith('switch:')) {
        if (decoded is List) {
          final events = <SwitchEvent>[];
          for (final item in decoded) {
            if (item is Map) {
              events.add(SwitchEvent.fromJson(Map<String, dynamic>.from(item)));
            }
          }
          if (events.isNotEmpty) {
            switchEvents[key.substring('switch:'.length)] = events;
          }
        }
        continue;
      }
      if (decoded is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (key.startsWith('anchor:')) {
        anchors[key.substring('anchor:'.length)] = ServiceAnchor.fromJson(map);
      } else if (key.startsWith('node:')) {
        final node = NodeMetadataCache.fromJson(map);
        if (!node.isExpired) {
          metadata[key.substring('node:'.length)] = node;
        }
      } else if (key.startsWith('access:')) {
        final rest = key.substring('access:'.length);
        final split = rest.indexOf(':');
        if (split <= 0) {
          continue;
        }
        final result = ServiceAccessResult.fromJson(map);
        if (result.isExpired) {
          continue;
        }
        final serviceId = rest.substring(0, split);
        final proxyName = rest.substring(split + 1);
        (access[serviceId] ??= {})[proxyName] = result;
      }
    }
    return SmartAnchorSnapshot(
      services: services,
      anchors: anchors,
      metadataByProxy: metadata,
      accessByService: access,
      sharedLockGroupIds: sharedIds,
      autoFailoverEnabled: autoFailoverEnabled,
      paths: paths,
      aggregationMode: aggregationMode,
      aggregationSources: aggregationSources,
      switchEvents: switchEvents,
    );
  }

  Future<void> save(SmartAnchorInput input) async {
    final fresh = <String, String>{};
    fresh[servicesKey] = json.encode([
      for (final service in input.services) service.toJson(),
    ]);
    fresh[sharedGroupsKey] = json.encode(input.sharedLockGroupIds);
    fresh[autoFailoverKey] = json.encode(input.autoFailoverEnabled);
    fresh[aggregationModeKey] = json.encode(input.aggregationMode.name);
    if (input.aggregationSources.isNotEmpty) {
      fresh[aggregationSourcesKey] = json.encode([
        for (final source in input.aggregationSources)
          {'sourceId': source.sourceId, 'sourceLabel': source.sourceLabel},
      ]);
    }
    for (final entry in input.anchors.entries) {
      fresh[anchorKey(entry.key)] = json.encode(entry.value.toJson());
    }
    for (final entry in input.metadataByProxy.entries) {
      if (entry.value.isExpired) {
        continue;
      }
      fresh[nodeKey(entry.key)] = json.encode(entry.value.toJson());
    }
    for (final entry in input.accessByService.entries) {
      for (final inner in entry.value.entries) {
        if (inner.value.isExpired) {
          continue;
        }
        fresh[accessKey(entry.key, inner.key)] = json.encode(
          inner.value.toJson(),
        );
      }
    }
    for (final entry in input.paths.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      fresh[pathKey(entry.key)] = json.encode([
        for (final point in entry.value) point.toJson(),
      ]);
    }
    for (final entry in input.switchEvents.entries) {
      if (entry.value.isEmpty) {
        continue;
      }
      fresh[switchKey(entry.key)] = json.encode([
        for (final event in entry.value) event.toJson(),
      ]);
    }
    final existing = await records.readAll();
    for (final key in existing.keys) {
      if (!fresh.containsKey(key)) {
        await records.delete(key);
      }
    }
    for (final entry in fresh.entries) {
      await records.write(entry.key, entry.value);
    }
  }

  Future<void> deleteAnchor(String serviceId) {
    return records.delete(anchorKey(serviceId));
  }
}
