enum AggregationGroupMode { primaryOnly, mergeAll }

class SubscriptionSourceResult {
  const SubscriptionSourceResult({
    required this.sourceId,
    required this.sourceLabel,
    required this.ok,
    required this.proxies,
    this.proxyGroups = const [],
    this.rules = const [],
    this.ruleProviders = const {},
    this.proxyProviders = const {},
    this.error,
  });

  final String sourceId;
  final String sourceLabel;
  final bool ok;
  final List<Map<String, dynamic>> proxies;
  final List<Map<String, dynamic>> proxyGroups;
  final List<String> rules;
  final Map<String, dynamic> ruleProviders;
  final Map<String, dynamic> proxyProviders;
  final String? error;
}

class MergedSubscription {
  const MergedSubscription({
    required this.proxies,
    required this.sources,
    required this.proxyGroups,
    required this.rules,
    required this.ruleProviders,
    required this.proxyProviders,
    required this.mode,
    required this.unifiedGroupName,
    this.prunedReferences = 0,
  });

  final List<Map<String, dynamic>> proxies;
  final List<SubscriptionSourceResult> sources;
  final List<Map<String, dynamic>> proxyGroups;
  final List<String> rules;
  final Map<String, dynamic> ruleProviders;
  final Map<String, dynamic> proxyProviders;
  final AggregationGroupMode mode;
  final String unifiedGroupName;

  /// References the pruning pass dropped because their target does not
  /// exist in the merged config (dangling dialer proxies, group members,
  /// provider uses, emptied groups, and rules pointing nowhere).
  final int prunedReferences;

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
    final mergedSourceIds = <String>[];
    final mergedOriginalNames = <String>[];
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
        mergedSourceIds.add(source.sourceId);
        mergedOriginalNames.add(originalName);
      }
    }
    final seenNames = <String>{};
    for (var i = 0; i < merged.length; i++) {
      var name = merged[i]['name']?.toString() ?? '';
      if (!seenNames.add(name)) {
        var suffix = 2;
        while (!seenNames.add('$name ($suffix)')) {
          suffix++;
        }
        name = '$name ($suffix)';
        merged[i]['name'] = name;
        proxyNameByKey['${mergedSourceIds[i]}\x00${mergedOriginalNames[i]}'] =
            name;
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
    for (var i = 0; i < merged.length; i++) {
      final dialer = merged[i]['dialer-proxy'];
      if (dialer is! String || dialer.isEmpty) {
        continue;
      }
      final remapped =
          proxyNameByKey['${mergedSourceIds[i]}\x00$dialer'] ??
          groupRenameByKey['${mergedSourceIds[i]}\x00$dialer'];
      if (remapped != null && remapped != dialer) {
        merged[i]['dialer-proxy'] = remapped;
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
    final seenRules = <String>{};
    final ruleSources = mode == AggregationGroupMode.primaryOnly
        ? (primary == null ? const <SubscriptionSourceResult>[] : [primary])
        : sources;
    final mergedRuleProviders = <String, dynamic>{};
    final mergedProxyProviders = <String, dynamic>{};
    for (final source in ruleSources) {
      for (final entry in source.ruleProviders.entries) {
        mergedRuleProviders.putIfAbsent(
          entry.key,
          () => entry.value is Map
              ? Map<String, dynamic>.from(entry.value as Map)
              : entry.value,
        );
      }
      for (final entry in source.proxyProviders.entries) {
        mergedProxyProviders.putIfAbsent(
          entry.key,
          () => entry.value is Map
              ? Map<String, dynamic>.from(entry.value as Map)
              : entry.value,
        );
      }
    }
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
        if (seenRules.add(text)) {
          mergedRules.add(text);
        }
      }
    }
    Set<String> currentNames() {
      return {
        'DIRECT',
        'REJECT',
        'REJECT-DROP',
        'GLOBAL',
        for (final proxy in merged) proxy['name']?.toString() ?? '',
        for (final group in mergedGroups) group['name']?.toString() ?? '',
      };
    }

    var prunedReferences = 0;
    var changed = true;
    while (changed) {
      changed = false;
      var names = currentNames();
      final proxyCount = merged.length;
      merged.removeWhere((proxy) {
        final dialer = proxy['dialer-proxy'];
        return dialer is String && dialer.isNotEmpty && !names.contains(dialer);
      });
      prunedReferences += proxyCount - merged.length;
      changed |= merged.length != proxyCount;
      names = currentNames();
      final groupCount = mergedGroups.length;
      mergedGroups.removeWhere((group) {
        final members = group['proxies'];
        if (members is List) {
          final memberCount = members.length;
          members.removeWhere((member) => !names.contains(member.toString()));
          prunedReferences += memberCount - members.length;
        }
        final use = group['use'];
        if (use is List) {
          group['use'] = [
            for (final entry in use)
              if (mergedProxyProviders.containsKey(entry.toString())) entry,
          ];
          prunedReferences += use.length - (group['use'] as List).length;
        }
        final remainingMembers = (group['proxies'] as List?) ?? const [];
        final remainingUse = (group['use'] as List?) ?? const [];
        return remainingMembers.isEmpty && remainingUse.isEmpty;
      });
      prunedReferences += groupCount - mergedGroups.length;
      changed |= mergedGroups.length != groupCount;
      names = currentNames();
      final ruleCount = mergedRules.length;
      mergedRules.removeWhere((rule) {
        var text = rule;
        if (text.endsWith(',no-resolve')) {
          text = text.substring(0, text.length - ',no-resolve'.length);
        }
        final parts = text.split(',');
        if (parts.isNotEmpty && parts.first == 'RULE-SET') {
          if (parts.length < 3 || !mergedRuleProviders.containsKey(parts[1])) {
            return true;
          }
        }
        final idx = text.lastIndexOf(',');
        final target = idx < 0 ? text : text.substring(idx + 1);
        return !names.contains(target);
      });
      prunedReferences += ruleCount - mergedRules.length;
      changed |= mergedRules.length != ruleCount;
    }
    return MergedSubscription(
      proxies: merged,
      sources: sources,
      proxyGroups: mergedGroups,
      rules: mergedRules,
      ruleProviders: mergedRuleProviders,
      proxyProviders: mergedProxyProviders,
      mode: mode,
      unifiedGroupName: unifiedName,
      prunedReferences: prunedReferences,
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
