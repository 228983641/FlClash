import '../models/anchor_path.dart';
import '../models/node_metadata.dart';
import '../models/switch_event.dart';
import '../models/service_anchor.dart';
import '../models/service_group.dart';
import '../models/service_toggle_config.dart';
import 'candidate_decision.dart';
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
  SmartAnchorInput input, {
  Map<String, int> delays = const {},
}) {
  return buildSmartConfigWithRanking(rawConfig, input, delays: delays).config;
}

typedef MergeSummary = ({
  int sources,
  int proxiesIn,
  int proxiesOut,
  int pruned,
});

/// [buildSmartConfig] plus the per-service rankings it computed, so the
/// setup path can sanitize persisted selections against the same ranking
/// the config was built with instead of discarding it. The merge summary
/// and the ambiguous stripped names ride along for the caller's logging:
/// this layer stays pure, so what the build did is reported, not printed.
({
  Map<String, dynamic> config,
  Map<String, List<String>> rankedByService,
  MergeSummary? mergeSummary,
  List<({String name, int candidates})> ambiguousStripped,
})
buildSmartConfigWithRanking(
  Map<String, dynamic> rawConfig,
  SmartAnchorInput input, {
  Map<String, int> delays = const {},
}) {
  if (!input.hasWork) {
    return (
      config: rawConfig,
      rankedByService: const {},
      mergeSummary: null,
      ambiguousStripped: const [],
    );
  }
  var config = Map<String, dynamic>.from(rawConfig);
  var effectiveInput = input;
  MergeSummary? mergeSummary;
  var ambiguousStripped = const <({String name, int candidates})>[];
  if (input.aggregationEnabled && input.aggregationSources.isNotEmpty) {
    final applied = _applyAggregation(config, input);
    config = applied.config;
    mergeSummary = applied.summary;
    ambiguousStripped = _ambiguousStrippedNames(input, _proxyNames(config));
    effectiveInput = _remapInputForMergedConfig(input, _proxyNames(config));
    _orderUnifiedGroup(config, effectiveInput);
  }
  final enabled = input.services.where((service) => service.isEnabled);
  if (enabled.isEmpty) {
    return (
      config: config,
      rankedByService: const {},
      mergeSummary: mergeSummary,
      ambiguousStripped: ambiguousStripped,
    );
  }
  final proxyNames = _proxyNames(config);
  final remappedDelays = <String, int>{};
  for (final name in proxyNames) {
    final delay = delays[name] ?? delays[_strippedProxyName(name)];
    if (delay != null) {
      remappedDelays[name] = delay;
    }
  }
  final rankedByService = <String, List<String>>{};
  for (final service in enabled) {
    rankedByService[service.serviceId] = rankedProxiesForService(
      effectiveInput,
      service,
      proxyNames,
      delays: remappedDelays,
    );
  }
  final injected = SmartConfigInjector.injectSmartRouting(
    rawConfig: config,
    serviceConfigs: effectiveInput.services,
    rankedProxiesByService: rankedByService,
  );
  _moveUnifiedGroupFirst(injected);
  return (
    config: injected,
    rankedByService: rankedByService,
    mergeSummary: mergeSummary,
    ambiguousStripped: ambiguousStripped,
  );
}

// Stripped names shared by several merged nodes while a metadata or
// access record exists under the stripped name: the merged-config remap
// skips the fallback for those (the record belongs to one unknown
// source's node), which is worth one log line per build.
List<({String name, int candidates})> _ambiguousStrippedNames(
  SmartAnchorInput input,
  List<String> proxyNames,
) {
  final counts = <String, int>{};
  final fromPrefixed = <String>{};
  for (final name in proxyNames) {
    final stripped = _strippedProxyName(name);
    counts[stripped] = (counts[stripped] ?? 0) + 1;
    if (stripped != name) {
      fromPrefixed.add(stripped);
    }
  }
  final result = <({String name, int candidates})>[];
  for (final entry in counts.entries) {
    if (entry.value < 2 || !fromPrefixed.contains(entry.key)) {
      continue;
    }
    final hasRecord =
        input.metadataByProxy.containsKey(entry.key) ||
        input.accessByService.values.any(
          (byProxy) => byProxy.containsKey(entry.key),
        );
    if (hasRecord) {
      result.add((name: entry.key, candidates: entry.value));
    }
  }
  result.sort((a, b) => a.name.compareTo(b.name));
  return result;
}

/// The selection map setup should push to the Core, with [lockReselectTarget]'s
/// rule applied at build time: a persisted smart-group selection that falls
/// outside the ranking the current lock produces is replaced by the top
/// ranked node, so the Core's ForceSet cannot serve a locked-out country
/// until the runtime compliance check gets to run. Compliant selections,
/// groups without a ranking, and non-smart entries pass through untouched;
/// the input map is never mutated.
Map<String, String> sanitizeSelectedMap(
  List<ServiceToggleConfig> services,
  Map<String, List<String>> rankedByService,
  Map<String, String> selectedMap,
) {
  if (rankedByService.isEmpty || selectedMap.isEmpty) {
    return selectedMap;
  }
  var sanitized = selectedMap;
  for (final service in services) {
    if (!service.isEnabled) {
      continue;
    }
    final ranked = rankedByService[service.serviceId];
    if (ranked == null || ranked.isEmpty) {
      continue;
    }
    final groupName = smartGroupName(service);
    final current = selectedMap[groupName];
    if (current == null || ranked.contains(current)) {
      continue;
    }
    if (identical(sanitized, selectedMap)) {
      sanitized = Map.of(selectedMap);
    }
    sanitized[groupName] = ranked.first;
  }
  return sanitized;
}

void _moveUnifiedGroupFirst(Map<String, dynamic> config) {
  final groups = config['proxy-groups'];
  if (groups is! List) {
    return;
  }
  final index = groups.indexWhere(
    (group) =>
        group is Map &&
        (group['name'] == unifiedAggregationGroupName ||
            (group['name'] is String &&
                (group['name'] as String).startsWith(
                  '$unifiedAggregationGroupName (',
                ))),
  );
  if (index <= 0) {
    return;
  }
  final unified = groups.removeAt(index);
  groups.insert(0, unified);
}

({Map<String, dynamic> config, MergeSummary summary}) _applyAggregation(
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
  var proxiesIn = 0;
  for (final source in sources) {
    proxiesIn += source.proxies.length;
  }
  return (
    config: result,
    summary: (
      sources: sources.length,
      proxiesIn: proxiesIn,
      proxiesOut: merged.proxies.length,
      pruned: merged.prunedReferences,
    ),
  );
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
  // A stripped (pre-merge) name shared by several merged nodes cannot be
  // attributed to just one of them: the record under it was probed against
  // a single source's node, so the fallback must not fan it out to all.
  final strippedCounts = <String, int>{};
  for (final name in proxyNames) {
    final stripped = _strippedProxyName(name);
    strippedCounts[stripped] = (strippedCounts[stripped] ?? 0) + 1;
  }
  String? unambiguousStripped(String name) {
    final stripped = _strippedProxyName(name);
    return strippedCounts[stripped] == 1 ? stripped : null;
  }

  final metadataByProxy = <String, NodeMetadataCache>{};
  for (final name in proxyNames) {
    final stripped = unambiguousStripped(name);
    final meta =
        input.metadataByProxy[name] ??
        (stripped == null ? null : input.metadataByProxy[stripped]);
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
      adminRegion: meta.adminRegion,
      city: meta.city,
      geoConfidence: meta.geoConfidence,
      asnConfidence: meta.asnConfidence,
    );
  }
  final accessByService = <String, Map<String, ServiceAccessResult>>{};
  for (final entry in input.accessByService.entries) {
    final remapped = <String, ServiceAccessResult>{};
    for (final name in proxyNames) {
      final stripped = unambiguousStripped(name);
      final access =
          entry.value[name] ??
          (stripped == null ? null : entry.value[stripped]);
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
        borrowedFrom: access.borrowedFrom,
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
  String displayName, {
  List<String> poolNames = const [],
}) {
  final exact = input.metadataByProxy[displayName];
  if (exact != null) {
    return exact;
  }
  final stripped = _strippedProxyName(displayName);
  if (stripped == displayName) {
    return null;
  }
  // Same attribution guard as the merged-config remap: when several pool
  // nodes strip to this name, the record under it belongs to one unknown
  // source's node and must not be shown for all of them.
  if (poolNames.isNotEmpty &&
      poolNames.where((name) => _strippedProxyName(name) == stripped).length >
          1) {
    return null;
  }
  return input.metadataByProxy[stripped];
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

/// The outcome of weighing a service's fresh region-block evidence per
/// country: the countries the derivation gate in [derivedRegionEvidence]
/// let through, and the countries it held back with the tally that fell
/// short. A country with a fresh accessible verdict is vetoed above the
/// gate and appears in neither collection.
class DerivedRegionEvidence {
  const DerivedRegionEvidence({required this.blocked, required this.heldBack});

  final Set<String> blocked;
  final Map<String, ({int proxies, int asns})> heldBack;
}

// Adjustable priors, not measured truths: a single node's region verdict
// once blacklisted its whole country, which let one bad probe empty a
// country's candidate pool. Derivation now needs corroboration from a
// second node on a second ASN, anchored by at least one verdict the
// service measured itself rather than borrowed.
const _regionGateMinProxies = 2;
const _regionGateMinAsns = 2;

DerivedRegionEvidence derivedRegionEvidence(
  SmartAnchorInput input,
  String serviceId,
) {
  final access = input.accessByService[serviceId] ?? const {};
  final working = <String>{};
  final proxiesByCountry = <String, Set<String>>{};
  final asnsByCountry = <String, Set<String>>{};
  final ownCountries = <String>{};
  for (final entry in access.entries) {
    final verdict = entry.value;
    if (verdict.isExpired) {
      continue;
    }
    final metadata = input.metadataByProxy[entry.key];
    final country = metadata?.countryCode;
    if (country == null || country.isEmpty) {
      continue;
    }
    if (verdict.isAccessible) {
      working.add(country);
    }
    if (!verdict.derivesRegionBlock) {
      continue;
    }
    proxiesByCountry.putIfAbsent(country, () => {}).add(entry.key);
    final asn = metadata?.asn;
    if (asn != null && asn.isNotEmpty) {
      asnsByCountry.putIfAbsent(country, () => {}).add(asn);
    }
    if (verdict.borrowedFrom == null) {
      ownCountries.add(country);
    }
  }
  final blocked = <String>{};
  final heldBack = <String, ({int proxies, int asns})>{};
  for (final country in proxiesByCountry.keys) {
    if (working.contains(country)) {
      continue;
    }
    final proxies = proxiesByCountry[country]!.length;
    final asns = asnsByCountry[country]?.length ?? 0;
    if (proxies >= _regionGateMinProxies &&
        asns >= _regionGateMinAsns &&
        ownCountries.contains(country)) {
      blocked.add(country);
    } else {
      heldBack[country] = (proxies: proxies, asns: asns);
    }
  }
  return DerivedRegionEvidence(blocked: blocked, heldBack: heldBack);
}

Set<String> detectedUnsupportedRegions(
  SmartAnchorInput input,
  String serviceId,
) {
  return derivedRegionEvidence(input, serviceId).blocked;
}

List<String> applyRegionFilter(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames,
) {
  final policy = _regionPolicyForService(input, service);
  if (policy.banned.isEmpty && policy.allowed.isEmpty) {
    return proxyNames;
  }
  return [
    for (final name in proxyNames)
      if (_regionPasses(
        input.metadataByProxy[name]?.countryCode,
        policy.banned.isEmpty ? null : policy.banned,
        policy.allowed.isEmpty ? null : policy.allowed,
      ))
        name,
  ];
}

({Set<String> banned, Set<String> allowed}) _regionPolicyForService(
  SmartAnchorInput input,
  ServiceToggleConfig service,
) {
  final stored = {
    for (final country in service.regionCountries) country.trim().toUpperCase(),
  }..remove('');
  if (service.effectiveRegionMode == 'whitelist') {
    return (banned: const <String>{}, allowed: stored);
  }
  return (
    banned: stored.isNotEmpty
        ? stored
        : detectedUnsupportedRegions(input, service.serviceId),
    allowed: const <String>{},
  );
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
  return _rankedPartsForService(
    input,
    service,
    proxyNames,
    delays: delays,
  ).ranked;
}

/// The merged ranking plus its qualified segment: the tested nodes that
/// passed [ScoringEngine.filterForService], in ranked order, ahead of the
/// untested tail. Compliance decisions need the segment on its own — an
/// untested name appearing in the merged list is a fallback pool member,
/// not a node known to comply.
({List<String> ranked, List<String> qualified}) _rankedPartsForService(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames, {
  Map<String, int> delays = const {},
}) {
  final result = _candidateDecisionForService(
    input,
    service,
    proxyNames,
    delays: delays,
  );
  return (
    ranked: result.decision.ordered,
    qualified: result.decision.qualified,
  );
}

({CandidateDecision decision, SmartAnchorInput effective})
_candidateDecisionForService(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames, {
  String? currentName,
  Map<String, int> delays = const {},
}) {
  input = _remapInputForMergedConfig(input, proxyNames);
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
      return _electAnchor(
        tested,
        first.lockedCountries,
        access,
        delays: delays,
      );
    }();
  }
  final policy = _regionPolicyForService(input, service);
  return (
    decision: buildCandidateDecision(
      service: service,
      proxyNames: proxyNames,
      metadataByProxy: input.metadataByProxy,
      accessByProxy: input.accessByService[service.serviceId] ?? const {},
      anchor: sharedAnchor ?? input.anchors[service.serviceId],
      currentName: currentName,
      delays: delays,
      bannedCountries: policy.banned,
      allowedCountries: policy.allowed,
    ),
    effective: input,
  );
}

/// The node a service group must move to when its current selection falls
/// outside the ranking the current lock produces, or null when the
/// selection still complies (or nothing compliant is known). Setup
/// reapplies the previously saved selection and the failover check never
/// moves a node that still works, so without this a group keeps serving a
/// country the user just locked out.
String? lockReselectTarget(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames,
  String currentName, {
  Map<String, int> delays = const {},
}) {
  return lockReselectDecision(
    input,
    service,
    proxyNames,
    currentName,
    delays: delays,
  ).target;
}

/// [lockReselectTarget] plus the ranking it decided from, so the runtime
/// compliance check can log (and membership-check) the same decision the
/// setup-time sanitizer makes through [lockReselectTarget].
///
/// A selection complies only inside the ranking's qualified segment: an
/// untested selection appears in the merged ranking as fallback pool,
/// which used to count as compliance and pinned services on nodes whose
/// country was never known. It now yields to any known qualified node
/// and stays only while none is known.
({String? target, List<String> ranked, bool currentUnknown})
lockReselectDecision(
  SmartAnchorInput input,
  ServiceToggleConfig service,
  List<String> proxyNames,
  String currentName, {
  Map<String, int> delays = const {},
}) {
  final result = _candidateDecisionForService(
    input,
    service,
    proxyNames,
    currentName: currentName,
    delays: delays,
  );
  final decision = result.decision;
  final ranked = decision.ordered;
  final effective = result.effective;
  final currentMeta = effective.metadataByProxy[currentName];
  final currentUnknown = decision.currentUnknown;
  // Purity hysteresis: a current node whose only disqualification is a
  // purity score inside the band stays — re-probe noise around the
  // threshold must not tear a working service off its node. Every other
  // disqualification (lock, WAF, region block, region filter) still
  // forces the move.
  if (currentMeta != null &&
      decision.blockedReasons[currentName] == CandidateBlockReason.lowPurity &&
      ScoringEngine.failsOnlyPurityWithinBand(
        currentMeta,
        service.lockedCountries,
        effective.accessByService[service.serviceId]?[currentName],
      )) {
    return (target: null, ranked: ranked, currentUnknown: currentUnknown);
  }
  return (
    target: decision.target,
    ranked: ranked,
    currentUnknown: currentUnknown,
  );
}

ServiceAnchor? _electAnchor(
  List<NodeMetadataCache> tested,
  List<String> lock,
  Map<String, ServiceAccessResult> access, {
  Map<String, int> delays = const {},
}) {
  final eligible = ScoringEngine.filterForService(tested, lock, access);
  if (eligible.isEmpty) {
    return null;
  }
  int effectiveDelay(NodeMetadataCache node) {
    final delay = delays[node.proxyName];
    if (delay == null || delay < 0) {
      return 1 << 30;
    }
    return delay;
  }

  eligible.sort((a, b) {
    final purity = b.purityScore.compareTo(a.purityScore);
    if (purity != 0) {
      return purity;
    }
    return effectiveDelay(a).compareTo(effectiveDelay(b));
  });
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
