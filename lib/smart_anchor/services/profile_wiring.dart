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

List<ServiceToggleConfig> effectiveSmartServices(SmartAnchorInput input) {
  final byId = {
    for (final service in defaultServiceToggles) service.serviceId: service,
    for (final service in input.services) service.serviceId: service,
  };
  final defaultIds = {
    for (final service in defaultServiceToggles) service.serviceId,
  };
  return [
    for (final service in defaultServiceToggles) byId[service.serviceId]!,
    for (final service in input.services)
      if (!defaultIds.contains(service.serviceId))
        byId[service.serviceId] ?? service,
  ];
}

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
    this.aggregationEnabled = false,
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
  final bool aggregationEnabled;
  final List<AggregationSourceInput> aggregationSources;
  final AggregationGroupMode aggregationMode;
  final List<String> sharedLockGroupIds;
  final bool autoFailoverEnabled;
  final Map<String, List<AnchorPathPoint>> paths;
  final Map<String, List<SwitchEvent>> switchEvents;

  bool get hasWork {
    return services.any((service) => service.isEnabled) ||
        (aggregationEnabled && aggregationSources.isNotEmpty);
  }

  SmartAnchorInput copyWith({
    List<ServiceToggleConfig>? services,
    Map<String, ServiceAnchor>? anchors,
    Map<String, NodeMetadataCache>? metadataByProxy,
    Map<String, Map<String, ServiceAccessResult>>? accessByService,
    bool? aggregationEnabled,
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
      aggregationEnabled: aggregationEnabled ?? this.aggregationEnabled,
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
  var effectiveInput = input;
  if (input.aggregationEnabled && input.aggregationSources.isNotEmpty) {
    config = _applyAggregation(config, input);
    effectiveInput = _remapInputForMergedConfig(input, _proxyNames(config));
    _orderUnifiedGroup(config, effectiveInput);
  }
  final enabled = input.services.where((service) => service.isEnabled);
  if (enabled.isEmpty) {
    return config;
  }
  final proxyNames = _proxyNames(config);
  final rankedByService = <String, List<String>>{};
  for (final service in enabled) {
    rankedByService[service.serviceId] = rankedProxiesForService(
      effectiveInput,
      service,
      proxyNames,
    );
  }
  return SmartConfigInjector.injectSmartRouting(
    rawConfig: config,
    serviceConfigs: effectiveInput.services,
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
    ruleProviders: _providerMap(config, 'rule-providers'),
    proxyProviders: _providerMap(config, 'proxy-providers'),
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
        ruleProviders: _providerMap(source.config, 'rule-providers'),
        proxyProviders: _providerMap(source.config, 'proxy-providers'),
      ),
  ];
  final merged = SubscriptionMerger.merge(sources, mode: input.aggregationMode);
  final result = Map<String, dynamic>.from(config);
  result['proxies'] = merged.proxies;
  result['proxy-groups'] = merged.proxyGroups;
  result['rules'] = merged.rules;
  result['rule-providers'] = merged.ruleProviders;
  result['proxy-providers'] = merged.proxyProviders;
  return result;
}

// The unified aggregation group is the feature's own list, so its member
// order follows the engine's quality ranking: probed nodes by purity
// descending, unprobed nodes after in pool order. The group has no service
// anchor, so distance and subnet bonuses do not apply here, and delays are
// not known yet at profile build time. Subscription groups keep their own
// order, and per-service smart groups keep their full engine ranking.
void _orderUnifiedGroup(Map<String, dynamic> config, SmartAnchorInput input) {
  final groups = config['proxy-groups'];
  if (groups is! List) {
    return;
  }
  for (final group in groups) {
    if (group is! Map) {
      continue;
    }
    final name = group['name']?.toString() ?? '';
    if (name != unifiedAggregationGroupName &&
        !name.startsWith('$unifiedAggregationGroupName (')) {
      continue;
    }
    final members = group['proxies'];
    if (members is! List) {
      continue;
    }
    final tested = <String>[];
    final untested = <String>[];
    for (final member in members) {
      final proxyName = member.toString();
      if (input.metadataByProxy.containsKey(proxyName)) {
        tested.add(proxyName);
      } else {
        untested.add(proxyName);
      }
    }
    tested.sort(
      (a, b) => input.metadataByProxy[b]!.purityScore.compareTo(
        input.metadataByProxy[a]!.purityScore,
      ),
    );
    group['proxies'] = [...tested, ...untested];
  }
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

Map<String, dynamic> _providerMap(Map<String, dynamic> config, String key) {
  final providers = config[key];
  if (providers is! Map) {
    return const {};
  }
  return {
    for (final entry in providers.entries)
      entry.key.toString(): entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : entry.value,
  };
}

// Aggregation renames every node to "[<sourceLabel>] <original>", but
// metadata and access records are keyed by the name the node had when
// probed. Translate those maps to the merged names (exact matches win, so
// records probed after aggregation keep working) so ranking, access
// filtering and unified ordering see the same names as the merged config.
// Without this, every aggregated node looks untested and the engine ranking
// silently degrades to pool order.
SmartAnchorInput _remapInputForMergedConfig(
  SmartAnchorInput input,
  List<String> proxyNames,
) {
  final metadataByProxy = <String, NodeMetadataCache>{};
  for (final name in proxyNames) {
    final meta =
        input.metadataByProxy[name] ??
        input.metadataByProxy[_strippedProxyName(name)];
    if (meta == null) {
      continue;
    }
    metadataByProxy[name] = NodeMetadataCache(
      proxyName: name,
      entryServer: meta.entryServer,
      egressIp: meta.egressIp,
      countryCode: meta.countryCode,
      latitude: meta.latitude,
      longitude: meta.longitude,
      asn: meta.asn,
      ipType: meta.ipType,
      fraudScore: meta.fraudScore,
      purityScore: meta.purityScore,
      wafPass: meta.wafPass,
      updatedAt: meta.updatedAt,
      ttlHours: meta.ttlHours,
      sourceCount: meta.sourceCount,
      countryDisputed: meta.countryDisputed,
    );
  }
  final accessByService = <String, Map<String, ServiceAccessResult>>{};
  for (final entry in input.accessByService.entries) {
    final remapped = <String, ServiceAccessResult>{};
    for (final name in proxyNames) {
      final access = entry.value[name] ?? entry.value[_strippedProxyName(name)];
      if (access == null) {
        continue;
      }
      remapped[name] = ServiceAccessResult(
        serviceId: access.serviceId,
        proxyName: name,
        egressIp: access.egressIp,
        reason: access.reason,
        checkedAt: access.checkedAt,
        ttlHours: access.ttlHours,
      );
    }
    if (remapped.isNotEmpty) {
      accessByService[entry.key] = remapped;
    }
  }
  return input.copyWith(
    metadataByProxy: metadataByProxy,
    accessByService: accessByService,
  );
}

NodeMetadataCache? metadataForDisplayProxy(
  SmartAnchorInput input,
  String displayName,
) {
  return input.metadataByProxy[displayName] ??
      input.metadataByProxy[_strippedProxyName(displayName)];
}

String smartNodeRemark(NodeMetadataCache? metadata) {
  if (metadata == null) {
    return '';
  }
  final typeLabel = switch (metadata.ipType) {
    'residential' || 'isp' || 'mobile' => '家宽',
    'business' => '商业',
    'hosting' || 'datacenter' => '机房',
    _ => '',
  };
  final score = '纯净度 ${metadata.purityScore.round()}';
  return typeLabel.isEmpty ? score : '$score · $typeLabel';
}

String _strippedProxyName(String name) {
  if (!name.startsWith('[')) {
    return name;
  }
  final close = name.indexOf('] ');
  if (close < 0) {
    return name;
  }
  return name.substring(close + 2);
}

Set<String> detectedUnsupportedRegions(
  SmartAnchorInput input,
  String serviceId,
) {
  final access = input.accessByService[serviceId] ?? const {};
  final blocked = <String>{};
  final working = <String>{};
  for (final entry in access.entries) {
    final country = input.metadataByProxy[entry.key]?.countryCode;
    if (country == null || country.isEmpty) {
      continue;
    }
    if (entry.value.blocksRanking) {
      blocked.add(country);
    } else if (entry.value.isAccessible) {
      working.add(country);
    }
  }
  return blocked.difference(working);
}

List<String> applyRegionFilter(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames,
) {
  final stored = {
    for (final country in service.regionCountries) country.trim().toUpperCase(),
  }..remove('');
  Set<String>? banned;
  Set<String>? allowed;
  if (service.effectiveRegionMode == 'whitelist') {
    if (stored.isNotEmpty) {
      allowed = stored;
    }
  } else {
    banned = stored.isNotEmpty
        ? stored
        : detectedUnsupportedRegions(input, service.serviceId);
  }
  if (banned == null && allowed == null) {
    return proxyNames;
  }
  return [
    for (final name in proxyNames)
      if (_regionPasses(
        input.metadataByProxy[name]?.countryCode,
        banned,
        allowed,
      ))
        name,
  ];
}

bool _regionPasses(String? country, Set<String>? banned, Set<String>? allowed) {
  if (country == null || country.isEmpty) {
    return true;
  }
  if (banned != null) {
    return !banned.contains(country);
  }
  if (allowed != null) {
    return allowed.contains(country);
  }
  return true;
}

List<String> rankedProxiesForService(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames, {
  Map<String, int> delays = const {},
}) {
  input = _remapInputForMergedConfig(input, proxyNames);
  proxyNames = applyRegionFilter(input, service, proxyNames);
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
