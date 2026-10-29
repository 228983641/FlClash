import 'dart:async';

import 'package:fl_clash/common/mixin.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/common/service_probe.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/smart_anchor/services/sa_log.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'config.dart';
import 'core.dart';
import 'route_state.dart';
import 'routed_probe.dart';

part 'generated/service_status.g.dart';

@Riverpod(keepAlive: true)
class ServiceStatus extends _$ServiceStatus
    with RoutedProbe<ServiceTarget, ServiceCheck> {
  // Results of the sweep currently landing, flushed as one summary line
  // once the sweep goes quiet; failures also log a detail line at once.
  final Map<ServiceTarget, ServiceProbeStatus> _panelRound = {};
  Timer? _panelRoundTimer;

  @override
  RoutedProbeState<ServiceTarget, ServiceCheck> build() {
    ref.onDispose(() => _panelRoundTimer?.cancel());
    return buildProbe();
  }

  @override
  bool isFailure(ServiceCheck value) =>
      value.status == ServiceProbeStatus.timeout ||
      value.status == ServiceProbeStatus.failed ||
      value.status == ServiceProbeStatus.cancelled;

  @override
  Future<Map<ServiceTarget, ProbeAnswer<ServiceCheck>>> probe(
    ServiceTarget target,
    RouteState route,
  ) async {
    final checks = await checkServices(
      ref.read(coreHandlerProvider),
      proxyName: route.proxied ? '' : directOutbound,
      targets: [target],
      scope: serviceCheckScopePanel,
    );
    final check = checks[target];
    if (check != null) {
      _notePanelResult(target, check, route);
    }
    return {
      if (check != null)
        target: ProbeAnswer(
          value: check,
          coreEpoch: check.coreEpoch,
          routeVersion: check.routeVersion,
          hits: check.hits,
        ),
    };
  }

  static const _panelDetailStatuses = {
    ServiceProbeStatus.timeout,
    ServiceProbeStatus.failed,
    ServiceProbeStatus.unsupportedRegion,
    ServiceProbeStatus.restricted,
    ServiceProbeStatus.disallowedIsp,
    ServiceProbeStatus.blocked,
  };

  void _notePanelResult(
    ServiceTarget target,
    ServiceCheck check,
    RouteState route,
  ) {
    final status = check.status;
    if (status != ServiceProbeStatus.cancelled &&
        _panelDetailStatuses.contains(status)) {
      commonPrint.log(
        saPanelCheckLine(
          serviceId: target.id,
          via: check.node ?? (route.proxied ? 'routed' : directOutbound),
          status: status.id,
          delayMs: check.delay,
        ),
      );
    }
    _panelRound[target] = status;
    _panelRoundTimer?.cancel();
    _panelRoundTimer = Timer(
      const Duration(milliseconds: 600),
      _flushPanelRound,
    );
  }

  void _flushPanelRound() {
    if (_panelRound.isEmpty) {
      return;
    }
    var available = 0;
    var failed = 0;
    var blocked = 0;
    var cancelled = 0;
    var other = 0;
    for (final status in _panelRound.values) {
      switch (status) {
        case ServiceProbeStatus.available:
          available++;
        case ServiceProbeStatus.timeout:
        case ServiceProbeStatus.failed:
          failed++;
        case ServiceProbeStatus.unsupportedRegion:
        case ServiceProbeStatus.restricted:
        case ServiceProbeStatus.disallowedIsp:
        case ServiceProbeStatus.blocked:
          blocked++;
        case ServiceProbeStatus.cancelled:
          cancelled++;
        default:
          other++;
      }
    }
    commonPrint.log(
      saPanelRoundLine(
        checked: _panelRound.length,
        available: available,
        failed: failed,
        blocked: blocked,
        cancelled: cancelled,
        other: other,
      ),
    );
    _panelRound.clear();
  }
}

/// How many of [enabledServiceTargets] the dashboard card has room for, which
/// its sheet marks as shown there.
@Riverpod(keepAlive: true)
class ShownServiceCount extends _$ShownServiceCount
    with AutoDisposeNotifierMixin {
  @override
  int build() => 2;
}

@riverpod
List<ServiceTarget> serviceTargets(Ref ref) {
  final order = ref.watch(
    appSettingProvider.select((state) => SelectValue(state.serviceOrder)),
  );
  return orderServiceTargets(order.value);
}

@riverpod
List<ServiceTarget> enabledServiceTargets(Ref ref) {
  final targets = ref.watch(serviceTargetsProvider);
  final disabled = ref.watch(
    appSettingProvider.select((state) => SelectValue(state.disabledServices)),
  );
  final enabled = [
    for (final target in targets)
      if (!disabled.value.contains(target.id)) target,
  ];
  return enabled.isEmpty ? targets : enabled;
}
