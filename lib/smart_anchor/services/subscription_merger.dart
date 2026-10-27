enum AggregationGroupMode { primaryOnly, mergeAll }

class SubscriptionSourceResult {
  const SubscriptionSourceResult({
    required this.sourceId,
    required this.sourceLabel,
    required this.ok,
    required this.proxies,
    this.proxyGroups = const [],
    this.rules = const [],
    this.error,
  });

  final String sourceId;
  final String sourceLabel;
  final bool ok;
  final List<Map<String, dynamic>> proxies;
  final List<Map<String, dynamic>> proxyGroups;
  final List<String> rules;
  final String? error;
}

class MergedSubscription {
  const MergedSubscription({
    required this.proxies,
    required this.sources,
    required this.proxyGroups,
    required this.rules,
    required this.mode,
    required this.unifiedGroupName,
  });

  final List<Map<String, dynamic>> proxies;
  final List<SubscriptionSourceResult> sources;
  final List<Map<String, dynamic>> proxyGroups;
  final List<String> rules;
  final AggregationGroupMode mode;
  final String unifiedGroupName;

  bool get degraded => sources.any((source) => !source.ok);
  bool get empty => proxies.isEmpty;
}

const unifiedAggregationGroupName = '🔗 聚合全部节点';

class SubscriptionMerger {
  static MergedSubscription merge(
    List<SubscriptionSourceResult> sources, {
    AggregationGroupMode mode = AggregationGroupMode.primaryOnly,
    String? primarySourceId,
    String unifiedGroupName = unifiedAggregationGroupName,
  }) {
    final merged = <Map<String, dynamic>>[];
    final proxyNameByKey = <String, String>{};
    final proxyNameByDedup = <String, String>{};
    for (final source in sources) {
      for (final proxy in source.proxies) {
        final originalName = proxy['name']?.toString() ?? 'proxy';
        final key = _dedupKey(proxy);
        final existing = proxyNameByDedup[key];
        if (existing != null) {
          proxyNameByKey['${source.sourceId}\x00$originalName'] = existing;
          continue;
        }
        final renamed = '[${source.sourceLabel}] $originalName';
        proxyNameByDedup[key] = renamed;
        proxyNameByKey['${source.sourceId}\x00$originalName'] = renamed;
        final copy = Map<String, dynamic>.from(proxy);
        copy['name'] = renamed;
        merged.add(copy);
      }
    }
    final primary = sources.isEmpty
        ? null
        : sources.firstWhere(
            (source) => source.sourceId == primarySourceId,
            orElse: () => sources.first,
          );
    final groupRenameByKey = <String, String>{};
    if (mode == AggregationGroupMode.mergeAll) {
      final typesByFinalName = <String, Set<String>>{};
      for (final source in sources) {
        for (final group in source.proxyGroups) {
          final name = group['name']?.toString() ?? '';
          final type = group['type']?.toString() ?? '';
          var finalName = name;
          final seenTypes = typesByFinalName[finalName];
          if (seenTypes != null && !seenTypes.contains(type)) {
            finalName = '[${source.sourceLabel}] $name';
            var suffix = 2;
            while (typesByFinalName.containsKey(finalName)) {
              finalName = '[${source.sourceLabel}] $name ($suffix)';
              suffix++;
            }
          }
          typesByFinalName.putIfAbsent(finalName, () => <String>{}).add(type);
          groupRenameByKey['${source.sourceId}\x00$name'] = finalName;
        }
      }
    }
    List<String> remapMembers(
      SubscriptionSourceResult source,
      List<dynamic>? members,
    ) {
      if (members == null) {
        return const [];
      }
      final result = <String>[];
      for (final member in members) {
        final text = member.toString();
        final asProxy = proxyNameByKey['${source.sourceId}\x00$text'];
        if (asProxy != null) {
          if (!result.contains(asProxy)) {
            result.add(asProxy);
          }
          continue;
        }
        final asGroup = groupRenameByKey['${source.sourceId}\x00$text'];
        result.add(asGroup ?? text);
      }
      return result;
    }

    final mergedGroups = <Map<String, dynamic>>[];
    if (mode == AggregationGroupMode.primaryOnly) {
      if (primary != null) {
        for (final group in primary.proxyGroups) {
          final copy = Map<String, dynamic>.from(group);
          final members = group['proxies'];
          if (members is List) {
            copy['proxies'] = remapMembers(primary, members);
          }
          mergedGroups.add(copy);
        }
      }
    } else {
      final indexByKey = <String, int>{};
      for (final source in sources) {
        for (final group in source.proxyGroups) {
          final name = group['name']?.toString() ?? '';
          final type = group['type']?.toString() ?? '';
          final finalName =
              groupRenameByKey['${source.sourceId}\x00$name'] ?? name;
          final key = '$finalName\x00$type';
          final members = group['proxies'];
          final remapped = members is List
              ? remapMembers(source, members)
              : <String>[];
          final existingIndex = indexByKey[key];
          if (existingIndex != null) {
            final existingGroup = mergedGroups[existingIndex];
            final existingMembers = List<String>.from(
              existingGroup['proxies'] as List? ?? [],
            );
            for (final member in remapped) {
              if (!existingMembers.contains(member)) {
                existingMembers.add(member);
              }
            }
            existingGroup['proxies'] = existingMembers;
          } else {
            final copy = Map<String, dynamic>.from(group);
            copy['name'] = finalName;
            if (members is List) {
              copy['proxies'] = remapped;
            }
            indexByKey[key] = mergedGroups.length;
            mergedGroups.add(copy);
          }
        }
      }
    }
    final groupNames = mergedGroups
        .map((group) => group['name']?.toString() ?? '')
        .toSet();
    var unifiedName = unifiedGroupName;
    var suffix = 2;
    while (groupNames.contains(unifiedName)) {
      unifiedName = '$unifiedGroupName ($suffix)';
      suffix++;
    }
    final mergedProxyNames = [
      for (final proxy in merged) proxy['name']?.toString() ?? '',
    ];
    if (mergedProxyNames.isNotEmpty) {
      mergedGroups.insert(0, {
        'name': unifiedName,
        'type': 'select',
        'proxies': mergedProxyNames,
      });
    }
    final mergedRules = <String>[];
    final ruleSources = mode == AggregationGroupMode.primaryOnly
        ? (primary == null ? const <SubscriptionSourceResult>[] : [primary])
        : sources;
    for (final source in ruleSources) {
      for (final rule in source.rules) {
        var text = rule;
        if (mode == AggregationGroupMode.mergeAll) {
          final parts = rule.split(',');
          if (parts.length >= 2) {
            final target = parts.last;
            final renamed = groupRenameByKey['${source.sourceId}\x00$target'];
            if (renamed != null && renamed != target) {
              parts[parts.length - 1] = renamed;
              text = parts.join(',');
            }
          }
        }
        if (!mergedRules.contains(text)) {
          mergedRules.add(text);
        }
      }
    }
    return MergedSubscription(
      proxies: merged,
      sources: sources,
      proxyGroups: mergedGroups,
      rules: mergedRules,
      mode: mode,
      unifiedGroupName: unifiedName,
    );
  }

  static String _dedupKey(Map<String, dynamic> proxy) {
    final parts = <String>[];
    for (final field in const [
      'type',
      'server',
      'port',
      'uuid',
      'password',
      'username',
      'alterId',
      'cipher',
      'network',
      'tls',
    ]) {
      final value = proxy[field];
      if (value != null) {
        parts.add('$field=$value');
      }
    }
    if (parts.isEmpty) {
      parts.add('name=${proxy['name']}');
    }
    return parts.join('|');
  }
}
