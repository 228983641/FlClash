import '../models/node_metadata.dart';
import '../models/service_anchor.dart';
import '../models/service_group.dart';
import '../models/service_toggle_config.dart';
import 'config_injector.dart';
import 'scoring_engine.dart';
import 'service_access.dart';
import 'subscription_merger.dart';

class AggregationSourceInput {
  const AggregationSourceInput({
    required this.sourceId,
    required this.sourceLabel,
    required this.config,
  });

  final String sourceId;
  final String sourceLabel;
  final Map<String, dynamic> config;
}

class SmartAnchorInput {
  const SmartAnchorInput({
    this.services = const [],
    this.anchors = const {},
    this.metadataByProxy = const {},
    this.accessByService = const {},
    this.aggregationSources = const [],
    this.aggregationMode = AggregationGroupMode.primaryOnly,
    this.sharedLockGroupIds = const [],
  });

  final List<ServiceToggleConfig> services;
  final Map<String, ServiceAnchor> anchors;
  final Map<String, NodeMetadataCache> metadataByProxy;
  final Map<String, Map<String, ServiceAccessResult>> accessByService;
  final List<AggregationSourceInput> aggregationSources;
  final AggregationGroupMode aggregationMode;
  final List<String> sharedLockGroupIds;

  bool get hasWork {
    return services.any((service) => service.isEnabled) ||
        aggregationSources.isNotEmpty;
  }

  SmartAnchorInput copyWith({
    List<ServiceToggleConfig>? services,
    Map<String, ServiceAnchor>? anchors,
    Map<String, NodeMetadataCache>? metadataByProxy,
    Map<String, Map<String, ServiceAccessResult>>? accessByService,
    List<AggregationSourceInput>? aggregationSources,
    AggregationGroupMode? aggregationMode,
    List<String>? sharedLockGroupIds,
  }) {
    return SmartAnchorInput(
      services: services ?? this.services,
      anchors: anchors ?? this.anchors,
      metadataByProxy: metadataByProxy ?? this.metadataByProxy,
      accessByService: accessByService ?? this.accessByService,
      aggregationSources: aggregationSources ?? this.aggregationSources,
      aggregationMode: aggregationMode ?? this.aggregationMode,
      sharedLockGroupIds: sharedLockGroupIds ?? this.sharedLockGroupIds,
    );
  }
}

Map<String, dynamic> buildSmartConfig(
  Map<String, dynamic> rawConfig,
  SmartAnchorInput input,
) {
  if (!input.hasWork) {
    return rawConfig;
  }
  var config = Map<String, dynamic>.from(rawConfig);
  if (input.aggregationSources.isNotEmpty) {
    config = _applyAggregation(config, input);
  }
  final enabled = input.services.where((service) => service.isEnabled);
  if (enabled.isEmpty) {
    return config;
  }
  final proxyNames = _proxyNames(config);
  final tested = <NodeMetadataCache>[];
  for (final name in proxyNames) {
    final metadata = input.metadataByProxy[name];
    if (metadata != null) {
      tested.add(metadata);
    }
  }
  final groupElected = <String, ServiceAnchor?>{};
  final rankedByService = <String, List<String>>{};
  for (final service in enabled) {
    ServiceAnchor? sharedAnchor;
    final group = groupForService(service.serviceId);
    if (group != null && input.sharedLockGroupIds.contains(group.id)) {
      for (final member in group.serviceIds) {
        if (input.anchors[member] != null) {
          sharedAnchor = input.anchors[member];
          break;
        }
      }
      sharedAnchor ??= groupElected.putIfAbsent(group.id, () {
        final first = input.services.firstWhere(
          (candidate) => candidate.serviceId == group.serviceIds.first,
          orElse: () => service,
        );
        final access = input.accessByService[first.serviceId] ?? const {};
        return _electAnchor(tested, first.lockedCountries, access);
      });
    }
    rankedByService[service.serviceId] = _rankForService(
      service,
      proxyNames,
      input,
      sharedAnchor: sharedAnchor,
    );
  }
  return SmartConfigInjector.injectSmartRouting(
    rawConfig: config,
    serviceConfigs: input.services,
    rankedProxiesByService: rankedByService,
  );
}

Map<String, dynamic> _applyAggregation(
  Map<String, dynamic> config,
  SmartAnchorInput input,
) {
  final primary = SubscriptionSourceResult(
    sourceId: 'primary',
    sourceLabel: '主订阅',
    ok: true,
    proxies: _proxyMaps(config),
    proxyGroups: _groupMaps(config),
    rules: _ruleStrings(config),
  );
  final sources = [
    primary,
    for (final source in input.aggregationSources)
      SubscriptionSourceResult(
        sourceId: source.sourceId,
        sourceLabel: source.sourceLabel,
        ok: true,
        proxies: _proxyMaps(source.config),
        proxyGroups: _groupMaps(source.config),
        rules: _ruleStrings(source.config),
      ),
  ];
  final merged = SubscriptionMerger.merge(sources, mode: input.aggregationMode);
  final result = Map<String, dynamic>.from(config);
  result['proxies'] = merged.proxies;
  result['proxy-groups'] = merged.proxyGroups;
  result['rules'] = merged.rules;
  return result;
}

List<String> _proxyNames(Map<String, dynamic> config) {
  return [
    for (final proxy in _proxyMaps(config))
      if (proxy['name'] is String) proxy['name'] as String,
  ];
}

List<Map<String, dynamic>> _proxyMaps(Map<String, dynamic> config) {
  final proxies = config['proxies'];
  if (proxies is! List) {
    return const [];
  }
  return [
    for (final proxy in proxies)
      if (proxy is Map) Map<String, dynamic>.from(proxy),
  ];
}

List<Map<String, dynamic>> _groupMaps(Map<String, dynamic> config) {
  final groups = config['proxy-groups'];
  if (groups is! List) {
    return const [];
  }
  return [
    for (final group in groups)
      if (group is Map) Map<String, dynamic>.from(group),
  ];
}

List<String> _ruleStrings(Map<String, dynamic> config) {
  final rules = config['rules'];
  if (rules is! List) {
    return const [];
  }
  return [for (final rule in rules) rule.toString()];
}

List<String> _rankForService(
  ServiceToggleConfig service,
  List<String> proxyNames,
  SmartAnchorInput input, {
  ServiceAnchor? sharedAnchor,
}) {
  final tested = <NodeMetadataCache>[];
  final untested = <String>[];
  for (final name in proxyNames) {
    final metadata = input.metadataByProxy[name];
    if (metadata == null) {
      untested.add(name);
    } else {
      tested.add(metadata);
    }
  }
  final access = input.accessByService[service.serviceId] ?? const {};
  final lock = service.lockedCountries;
  var anchor = sharedAnchor ?? input.anchors[service.serviceId];
  anchor ??= _electAnchor(tested, lock, access);
  if (anchor == null) {
    return [...tested.map((node) => node.proxyName), ...untested];
  }
  final ranked = ScoringEngine.rankForService(tested, anchor, lock, access);
  return [...ranked.map((node) => node.proxyName), ...untested];
}

ServiceAnchor? _electAnchor(
  List<NodeMetadataCache> tested,
  List<String> lock,
  Map<String, ServiceAccessResult> access,
) {
  final eligible = ScoringEngine.filterForService(tested, lock, access);
  if (eligible.isEmpty) {
    return null;
  }
  eligible.sort((a, b) => b.purityScore.compareTo(a.purityScore));
  final best = eligible.first;
  return ServiceAnchor(
    serviceTag: '',
    countryCode: best.countryCode,
    lastProxyName: best.proxyName,
    egressIp: best.egressIp,
    subnet24: best.egressIp.contains('.')
        ? best.egressIp.split('.').take(3).join('.')
        : '',
    asn: best.asn,
    isp: '',
    latitude: best.latitude,
    longitude: best.longitude,
    city: '',
    confirmedAt: 0,
  );
}
