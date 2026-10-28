part of '../action.dart';

class _DelayTestTarget {
  const _DelayTestTarget({
    required this.proxyName,
    required this.testUrl,
    required this.key,
  });

  final String proxyName;
  final String testUrl;
  final String key;
}

typedef _DelayTestBatch = ({List<Proxy> proxies, String? testUrl});

class _DelayTestJob {
  _DelayTestJob(Iterable<String> keys, this.timeout) : held = keys.toSet();

  final Set<String> held;
  final Duration timeout;
  final Set<String> startedOnDispatch = {};
  bool cancelled = false;
}

@Riverpod(keepAlive: true)
class ProxiesAction extends _$ProxiesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final TaskPool _delayTestPool = TaskPool(maxConcurrentDelayTests);

  final List<_DelayTestJob> _delayTestJobs = [];

  final List<Delay> _bufferedDelays = [];

  final List<String> _bufferedStarts = [];

  final List<String> _bufferedFinishes = [];

  Timer? _delayFlushTimer;

  final Map<String, String> _pendingSelectedRollback = {};

  @override
  void build() {
    ref.onDispose(() {
      _delayFlushTimer?.cancel();
      _smartAnchorMonitorTimer?.cancel();
    });
    ref.listen(isStartProvider, (_, started) {
      if (started) {
        _smartAnchorMonitorTimer ??= Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(smartAnchorMonitorTick()),
        );
      } else {
        _smartAnchorMonitorTimer?.cancel();
        _smartAnchorMonitorTimer = null;
      }
    }, fireImmediately: true);
    ref.listen(coreStatusProvider, (_, next) {
      if (next != CoreStatus.connected) {
        cancelDelayTests();
      }
    });
  }

  void cancelDelayTests() {
    for (final job in _delayTestJobs) {
      job.cancelled = true;
      job.held.clear();
    }
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    _bufferedDelays.clear();
    _bufferedStarts.clear();
    _bufferedFinishes.clear();
    ref.read(pendingDelayTestsProvider.notifier).clear();
  }

  void _scheduleDelayFlush() {
    _delayFlushTimer ??= Timer(renderThrottleDuration, _flushDelayResults);
  }

  void _flushDelayResults() {
    _delayFlushTimer?.cancel();
    _delayFlushTimer = null;
    if (_bufferedDelays.isNotEmpty) {
      final delays = List.of(_bufferedDelays);
      _bufferedDelays.clear();
      ref.read(delayDataSourceProvider.notifier).setDelays(delays);
    }
    if (_bufferedStarts.isNotEmpty || _bufferedFinishes.isNotEmpty) {
      final started = List.of(_bufferedStarts);
      final finished = List.of(_bufferedFinishes);
      _bufferedStarts.clear();
      _bufferedFinishes.clear();
      ref
          .read(pendingDelayTestsProvider.notifier)
          .apply(started: started, finished: finished);
    }
  }

  void updateGroupsDebounce([Duration? duration]) {
    debouncer.call(FunctionTag.updateGroups, updateGroups, duration: duration);
  }

  void changeProxyDebounce(
    String groupName,
    String proxyName, {
    String trigger = 'tap',
  }) {
    _pendingSelectedRollback.putIfAbsent(
      groupName,
      () => _currentSelectedName(groupName),
    );
    ref
        .read(profilesActionProvider.notifier)
        .updateCurrentSelectedMap(groupName, proxyName);
    debouncer.call((FunctionTag.changeProxy, groupName), (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(
        groupName: groupName,
        proxyName: proxyName,
        trigger: trigger,
      );
      updateGroupsDebounce();
    }, args: [groupName, proxyName]);
  }

  String _currentSelectedName(String groupName) {
    return ref.read(currentProfileProvider)?.selectedMap[groupName] ?? '';
  }

  Future<void> updateGroups() async {
    try {
      ref.read(groupsProvider.notifier).value = await retry(
        task: () async {
          final sortType = ref.read(
            proxiesStyleSettingProvider.select((state) => state.sortType),
          );
          final delayMap = ref.read(delayDataSourceProvider);
          final testUrl = ref.read(
            patchClashConfigProvider.select((state) => state.testUrl),
          );
          final selectedMap = ref.read(
            currentProfileProvider.select((state) => state?.selectedMap ?? {}),
          );
          try {
            return await _core.getProxiesGroups(
              selectedMap: selectedMap,
              sortType: sortType,
              delayMap: delayMap,
              defaultTestUrl: testUrl,
            );
          } catch (e) {
            commonPrint.log(
              'updateGroups error: $e',
              logLevel: coreFailureLogLevel(e),
            );
            return [];
          }
        },
        retryIf: (res) => res.isEmpty,
      );
    } catch (e) {
      // The Core failure path already runs inside the retry task above; a
      // throw here only means ref.read hit a disposed container or the
      // groupsProvider write itself failed.
      commonPrint.log(
        'updateGroups failed: $e',
        logLevel: coreFailureLogLevel(e),
      );
    }
    final smart = ref.read(smartAnchorProvider);
    if (smart.services.any((service) => service.isEnabled)) {
      final groups = ref.read(groupsProvider);
      final groupNames = {for (final group in groups) group.name};
      final names = <String>{};
      var current = '';
      for (final group in groups) {
        if (group.name.startsWith('🎯 Smart-') && group.now != null) {
          current = group.now!;
        }
        for (final proxy in group.all) {
          if (!groupNames.contains(proxy.name)) {
            names.add(proxy.name);
          }
        }
      }
      unawaited(
        ref
            .read(smartAnchorProvider.notifier)
            .probeNodes(proxyNames: names.toList(), currentProxyName: current)
            .then((_) => smartAnchorFailoverCheck()),
      );
    }
  }

  final FailoverGuard _failoverGuard = FailoverGuard();

  Timer? _smartAnchorMonitorTimer;
  bool _smartAnchorMonitorRunning = false;
  final Map<String, String> _lastObservedCurrent = {};
  final Map<String, String> _pendingAutoSwitch = {};
  final Map<String, String> _pendingAutoReason = {};
  final Map<String, (String, int)> _anchorStableSince = {};

  Map<String, int> _flattenDelays(DelayMap delayMap) {
    final delays = <String, int>{};
    for (final byProxy in delayMap.values) {
      for (final entry in byProxy.entries) {
        final value = entry.value;
        if (value == null) {
          continue;
        }
        final existing = delays[entry.key];
        if (existing == null ||
            (value >= 0 && (existing < 0 || value < existing))) {
          delays[entry.key] = value;
        }
      }
    }
    return delays;
  }

  void _observePathPoints(
    SmartAnchorInput smart,
    List<Group> groups,
    int nowMs,
  ) {
    for (final service in smart.services.where(
      (service) => service.isEnabled,
    )) {
      final groupName = smartGroupName(service);
      final group = groups.getGroup(groupName);
      final currentName = group?.now;
      if (currentName == null) {
        continue;
      }
      final currentMeta = smart.metadataByProxy[currentName];
      if (_lastObservedCurrent[service.serviceId] != currentName &&
          currentMeta != null) {
        final pendingReason = _pendingAutoReason[service.serviceId];
        final note = _pendingAutoSwitch[service.serviceId] == currentName
            ? 'auto:${pendingReason ?? 'unknown'}'
            : _lastObservedCurrent[service.serviceId] == null
            ? 'start'
            : 'manual';
        ref
            .read(smartAnchorProvider.notifier)
            .recordPathPoint(
              AnchorPathPoint(
                serviceId: service.serviceId,
                proxyName: currentName,
                latitude: currentMeta.latitude,
                longitude: currentMeta.longitude,
                countryCode: currentMeta.countryCode,
                city: '',
                recordedAt: nowMs,
                note: note,
              ),
            );
        _lastObservedCurrent[service.serviceId] = currentName;
      }
    }
  }

  void smartAnchorFailoverCheck() {
    final smart = ref.read(smartAnchorProvider);
    final groups = ref.read(groupsProvider);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _observePathPoints(smart, groups, nowMs);
    if (!smart.autoFailoverEnabled) {
      return;
    }
    final groupNames = {for (final group in groups) group.name};
    final names = <String>[];
    for (final group in groups) {
      for (final proxy in group.all) {
        if (!groupNames.contains(proxy.name) && !names.contains(proxy.name)) {
          names.add(proxy.name);
        }
      }
    }
    final delays = _flattenDelays(ref.read(delayDataSourceProvider));
    for (final service in smart.services.where(
      (service) => service.isEnabled,
    )) {
      final groupName = smartGroupName(service);
      final group = groups.getGroup(groupName);
      final currentName = group?.now;
      if (currentName == null) {
        continue;
      }
      _pendingAutoSwitch.remove(service.serviceId);
      _pendingAutoReason.remove(service.serviceId);
      final ranked = rankedProxiesForService(
        smart,
        service,
        names,
        delays: delays,
      );
      final currentReason =
          smart.accessByService[service.serviceId]?[currentName]?.reason;
      final next = _failoverGuard.noteResult(
        serviceId: service.serviceId,
        currentName: currentName,
        reason: currentReason,
        ranked: ranked,
        accessByProxy: smart.accessByService[service.serviceId] ?? const {},
        nowMs: nowMs,
      );
      if (next != null) {
        ref
            .read(smartAnchorProvider.notifier)
            .recordSwitchEvent(
              SwitchEvent(
                serviceId: service.serviceId,
                fromProxy: currentName,
                toProxy: next,
                reason: currentReason?.name ?? 'unknown',
                switchedAt: nowMs,
              ),
            );
        _pendingAutoSwitch[service.serviceId] = next;
        _pendingAutoReason[service.serviceId] =
            currentReason?.name ?? 'unknown';
        changeProxyDebounce(groupName, next, trigger: 'auto-failover');
      }
    }
  }

  void _trackAnchorStability(SmartAnchorInput smart) {
    final groups = ref.read(groupsProvider);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final service in smart.services.where((s) => s.isEnabled)) {
      final current = groups.getGroup(smartGroupName(service))?.now;
      if (current == null) {
        _anchorStableSince.remove(service.serviceId);
        continue;
      }
      final tracked = _anchorStableSince[service.serviceId];
      if (tracked == null || tracked.$1 != current) {
        _anchorStableSince[service.serviceId] = (current, nowMs);
        continue;
      }
      final existing = smart.anchors[service.serviceId];
      if (existing != null && existing.lastProxyName == current) {
        continue;
      }
      final meta = smart.metadataByProxy[current];
      if (meta == null) {
        continue;
      }
      if (nowMs - tracked.$2 >= 10 * 60 * 1000) {
        ref
            .read(smartAnchorProvider.notifier)
            .setAnchor(
              service.serviceId,
              ServiceAnchor(
                serviceTag: service.serviceId,
                countryCode: meta.countryCode,
                lastProxyName: current,
                egressIp: meta.egressIp,
                subnet24: meta.egressIp.contains('.')
                    ? meta.egressIp.split('.').take(3).join('.')
                    : '',
                asn: meta.asn,
                isp: '',
                latitude: meta.latitude,
                longitude: meta.longitude,
                city: '',
                confirmedAt: nowMs,
              ),
            );
      }
    }
  }

  Future<void> smartAnchorMonitorTick() async {
    if (_smartAnchorMonitorRunning) {
      return;
    }
    _smartAnchorMonitorRunning = true;
    try {
      if (!ref.read(isStartProvider)) {
        return;
      }
      final smart = ref.read(smartAnchorProvider);
      _trackAnchorStability(smart);
      final groups = ref.read(groupsProvider);
      _observePathPoints(smart, groups, DateTime.now().millisecondsSinceEpoch);
      if (!smart.autoFailoverEnabled) {
        return;
      }
      final probed = <String>{};
      for (final service in smart.services.where((s) => s.isEnabled)) {
        final current = groups.getGroup(smartGroupName(service))?.now;
        if (current == null || !probed.add(current)) {
          continue;
        }
        await ref
            .read(smartAnchorProvider.notifier)
            .probeNodes(
              proxyNames: [current],
              currentProxyName: current,
              force: true,
              updateThrottle: false,
            );
      }
      smartAnchorFailoverCheck();
    } catch (_) {
    } finally {
      _smartAnchorMonitorRunning = false;
    }
  }

  void updateCurrentGroupName(String groupName) {
    final profile = ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) return;
    ref
        .read(profilesProvider.notifier)
        .put(profile.copyWith(currentGroupName: groupName));
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    ref
        .read(profilesProvider.notifier)
        .put(currentProfile.copyWith(unfoldSet: value));
  }

  void setDelay(Delay delay) {
    _bufferedDelays.add(delay);
    _scheduleDelayFlush();
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
    String trigger = 'tap',
  }) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    final rollbackName =
        _pendingSelectedRollback.remove(groupName) ??
        _currentSelectedName(groupName);
    profilesAction.updateCurrentSelectedMap(groupName, proxyName);
    final ChangeProxyResult result;
    try {
      result = await PerfTrace.time(
        'switch-proxy-core',
        () => _core.changeProxy(
          ChangeProxyParams(groupName: groupName, proxyName: proxyName),
        ),
        detail: '$trigger $groupName -> $proxyName',
      );
      if (result.message.isNotEmpty) {
        throw MessageException(result.message);
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
      profilesAction.updateCurrentSelectedMap(groupName, rollbackName);
      dialogs.showNotifier(
        currentAppLocalizations.changeProxyFailedTip,
        level: MessageLevel.error,
      );
      return;
    }
    if (!result.changed) {
      return;
    }
    try {
      if (ref.read(appSettingProvider).closeConnections) {
        await PerfTrace.time(
          'switch-proxy-reset',
          () => _core.closeConnections(),
          detail: '$trigger $groupName -> $proxyName',
        );
      } else {
        await PerfTrace.time(
          'switch-proxy-reset',
          () => _core.resetConnections(),
          detail: '$trigger $groupName -> $proxyName',
        );
      }
    } catch (error) {
      commonPrint.log(
        'changeProxy($groupName -> $proxyName) connection reset failed: $error',
        logLevel: coreFailureLogLevel(error),
      );
    }
  }

  Future<String> updateProvider(
    ExternalProvider provider, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final clashProvidersAction = ref.read(
        clashProvidersActionProvider.notifier,
      );
      final ruleSet = await clashProvidersAction.remoteProviderOf(provider);
      if (ruleSet != null && !await clashProvidersAction.syncRemote(ruleSet)) {
        return '';
      }
      final message = await _core.updateExternalProvider(
        providerName: provider.name,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<String> sideLoadExternalProvider(
    ExternalProvider provider,
    String data, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref
              .read(updatingKeysProvider.notifier)
              .start(provider.updatingKey, scope: UpdatingScope.core)
        : null;
    try {
      final message = await _core.sideLoadExternalProvider(
        providerName: provider.name,
        data: data,
      );
      if (message.isNotEmpty) return message;
      ref
          .read(providersProvider.notifier)
          .setProvider(await _core.getExternalProvider(provider.name));
      return '';
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(provider.updatingKey, operation);
      }
    }
  }

  Future<void> addToLocalProxies(String proxyName) async {
    final appLocalizations = currentAppLocalizations;
    final definition = await _core.getProxyDefinition(proxyName);
    if (definition == null) {
      throw MessageException(
        appLocalizations.customIssueMissingProxies(proxyName),
      );
    }
    final (proxies, groupNames) = await (
      database.customProxiesDao.query().get(),
      database.proxyGroupsDao.names().get(),
    ).wait;
    final (:name, :added) = importProxy(
      definition,
      existing: [for (final proxy in proxies) proxy.definition],
      groupNames: groupNames.toSet(),
    );
    if (added == null) {
      dialogs.showNotifier(appLocalizations.alreadyInLocalProxies(name));
      return;
    }
    final order = indexing.generateKeyBetween(
      proxies.map((proxy) => proxy.order).nonNulls.lastOrNull,
      null,
    );
    await database.customProxies.put(
      CustomProxy.fromDefinition(added).copyWith(order: order).toCompanion(),
    );
    dialogs.showNotifier(appLocalizations.addedToLocalProxies(name));
  }

  Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) {
    return _runDelayTests([
      (proxies: [proxy], testUrl: testUrl),
    ]);
  }

  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    await _runDelayTests([(proxies: proxies, testUrl: testUrl)]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestGroups(List<Group> groups) async {
    await _runDelayTests([
      for (final group in groups) (proxies: group.all, testUrl: group.testUrl),
    ]);
    ref.read(sortNumProvider.notifier).add();
  }

  Future<void> delayTestPageGroup(
    String groupName, {
    bool matchSearch = true,
  }) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null) {
      return;
    }
    final testing = ref.read(delayTestingGroupsProvider.notifier);
    if (!testing.start(groupName)) {
      return;
    }
    try {
      final query = SearchQuery(
        matchSearch ? ref.read(queryProvider(QueryTag.proxies)) : '',
      );
      await delayTest(
        group.all.whereMatches(query, (proxy) => proxy.searchFields).toList(),
        group.testUrl,
      );
    } finally {
      testing.stop(groupName);
    }
  }

  List<_DelayTestTarget> _resolveDelayTestTargets(
    List<_DelayTestBatch> batches,
  ) {
    final groups = ref.read(groupsProvider);
    final selectedMap = ref.read(
      currentProfileProvider.select((state) => state?.selectedMap ?? {}),
    );
    final seen = <String>{};
    final targets = <_DelayTestTarget>[];
    for (final batch in batches) {
      final fallbackTestUrl = ref.read(realTestUrlProvider(batch.testUrl));
      for (final proxy in batch.proxies) {
        final state = computeRealSelectedProxyState(
          proxy.name,
          groups: groups,
          selectedMap: selectedMap,
        );
        if (state.proxyName.isEmpty) {
          continue;
        }
        final currentTestUrl = state.testUrl.takeFirstValid([fallbackTestUrl]);
        final key = delayTestKey(currentTestUrl, state.proxyName);
        if (!seen.add(key)) {
          continue;
        }
        targets.add(
          _DelayTestTarget(
            proxyName: state.proxyName,
            testUrl: currentTestUrl,
            key: key,
          ),
        );
      }
    }
    return targets;
  }

  Future<void> _runDelayTests(List<_DelayTestBatch> batches) async {
    final targets = _resolveDelayTestTargets(batches);
    if (targets.isEmpty) {
      return;
    }
    final pending = ref.read(pendingDelayTestsProvider.notifier);
    final job = _DelayTestJob(
      targets.map((target) => target.key),
      Duration(milliseconds: ref.read(appSettingProvider).delayTestTimeout),
    );
    _delayTestJobs.add(job);
    // TaskPool.run starts a task synchronously while it has an idle slot.
    job.startedOnDispatch.addAll(
      targets.take(_delayTestPool.idleSlots).map((target) => target.key),
    );
    pending.apply(acquired: job.held, started: job.startedOnDispatch);
    try {
      await Future.wait(
        targets.map(
          (target) => _delayTestPool.run(() => _runDelayTest(job, target)),
        ),
      );
    } finally {
      _delayTestJobs.remove(job);
      _flushDelayResults();
      final abandoned = job.held.toList();
      job.held.clear();
      pending.apply(
        finished: abandoned.where(job.startedOnDispatch.contains),
        released: abandoned.where(
          (key) => !job.startedOnDispatch.contains(key),
        ),
      );
    }
  }

  Future<void> _runDelayTest(_DelayTestJob job, _DelayTestTarget target) async {
    if (job.cancelled) {
      return;
    }
    if (!job.startedOnDispatch.contains(target.key)) {
      _bufferedStarts.add(target.key);
      _scheduleDelayFlush();
    }
    try {
      final delay = await _core.getDelay(
        target.testUrl,
        target.proxyName,
        job.timeout,
      );
      if (delay != null && !job.cancelled) {
        setDelay(delay);
      }
    } catch (error) {
      if (error is CoreMethodException && error.isCoreUnavailable) {
        job.cancelled = true;
      }
      commonPrint.log(
        'Delay test failed for ${target.proxyName}: $error',
        logLevel: coreFailureLogLevel(error),
      );
    } finally {
      if (job.held.remove(target.key)) {
        _bufferedFinishes.add(target.key);
        _scheduleDelayFlush();
      }
    }
  }
}
