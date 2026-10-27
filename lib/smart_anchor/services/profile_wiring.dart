import '../models/anchor_path.dart';
import '../models/node_metadata.dart';
import '../models/switch_event.dart';
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
    this.autoFailoverEnabled = true,
    this.paths = const {},
    this.switchEvents = const {},
  });

  final List<ServiceToggleConfig> services;
  final Map<String, ServiceAnchor> anchors;
  final Map<String, NodeMetadataCache> metadataByProxy;
  final Map<String, Map<String, ServiceAccessResult>> accessByService;
  final List<AggregationSourceInput> aggregationSources;
  final AggregationGroupMode aggregationMode;
  final List<String> sharedLockGroupIds;
  final bool autoFailoverEnabled;
  final Map<String, List<AnchorPathPoint>> paths;
  final Map<String, List<SwitchEvent>> switchEvents;

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
    bool? autoFailoverEnabled,
    Map<String, List<AnchorPathPoint>>? paths,
    Map<String, List<SwitchEvent>>? switchEvents,
  }) {
    return SmartAnchorInput(
      services: services ?? this.services,
      anchors: anchors ?? this.anchors,
      metadataByProxy: metadataByProxy ?? this.metadataByProxy,
      accessByService: accessByService ?? this.accessByService,
      aggregationSources: aggregationSources ?? this.aggregationSources,
      aggregationMode: aggregationMode ?? this.aggregationMode,
      sharedLockGroupIds: sharedLockGroupIds ?? this.sharedLockGroupIds,
      autoFailoverEnabled: autoFailoverEnabled ?? this.autoFailoverEnabled,
      paths: paths ?? this.paths,
      switchEvents: switchEvents ?? this.switchEvents,
    );
  }
}

bool serviceHasNoUsableNodes(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames,
) {
  if (!service.isEnabled || proxyNames.isEmpty) {
    return false;
  }
  return rankedProxiesForService(input, service, proxyNames).isEmpty;
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
  final rankedByService = <String, List<String>>{};
  for (final service in enabled) {
    rankedByService[service.serviceId] = rankedProxiesForService(
      input,
      service,
      proxyNames,
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

List<String> rankedProxiesForService(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames, {
  Map<String, int> delays = const {},
}) {
  final tested = <NodeMetadataCache>[];
  for (final name in proxyNames) {
    final metadata = input.metadataByProxy[name];
    if (metadata != null) {
      tested.add(metadata);
    }
  }
  ServiceAnchor? sharedAnchor;
  final group = groupForService(service.serviceId);
  if (group != null && input.sharedLockGroupIds.contains(group.id)) {
    for (final member in group.serviceIds) {
      if (input.anchors[member] != null) {
        sharedAnchor = input.anchors[member];
        break;
      }
    }
    sharedAnchor ??= () {
      final first = input.services.firstWhere(
        (candidate) => candidate.serviceId == group.serviceIds.first,
        orElse: () => service,
      );
      final access = input.accessByService[first.serviceId] ?? const {};
      return _electAnchor(tested, first.lockedCountries, access);
    }();
  }
  return _rankForService(
    service,
    proxyNames,
    input,
    sharedAnchor: sharedAnchor,
    delays: delays,
  );
}

List<String> _rankForService(
  ServiceToggleConfig service,
  List<String> proxyNames,
  SmartAnchorInput input, {
  ServiceAnchor? sharedAnchor,
  Map<String, int> delays = const {},
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
    // No node passes the lock, so no known node may serve this service.
    // Only nodes without metadata stay as the emergency pool.
    return untested;
  }
  final ranked = ScoringEngine.rankForService(
    tested,
    anchor,
    lock,
    access,
    delays: delays,
  );
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

const _matchRuleTypes = {
  'DOMAIN',
  'DOMAIN-SUFFIX',
  'DOMAIN-KEYWORD',
  'DOMAIN-REGEX',
  'IP-CIDR',
  'IP-CIDR6',
  'IP-ASN',
  'SRC-IP-CIDR',
  'SRC-IP-CIDR6',
  'DST-PORT',
  'SRC-PORT',
  'PROCESS-NAME',
  'PROCESS-PATH',
  'GEOIP',
  'GEOSITE',
  'FINAL',
  'MATCH',
  'AND',
  'OR',
  'NOT',
  'RULE-SET',
};

bool isValidMatchRule(String line) {
  final comma = line.indexOf(',');
  if (comma <= 0) {
    return false;
  }
  final type = line.substring(0, comma).trim().toUpperCase();
  if (!_matchRuleTypes.contains(type)) {
    return false;
  }
  return line.substring(comma + 1).trim().isNotEmpty;
}
