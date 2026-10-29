import 'service_access.dart';

// Structured one-line records for the smart-anchor engine, all prefixed
// [SA] so a captured app log can be grepped per concern. These are pure
// formatters; call sites emit them through commonPrint at info level and
// own the volume discipline (one line per decision or per round, never
// per node per service).

String saComplianceDecisionLine({
  required String serviceId,
  required String groupName,
  required String currentName,
  required String target,
  required List<String> rankedTop,
}) {
  return '[SA] compliance service=$serviceId group=$groupName '
      'current=$currentName -> $target reason=lock-change '
      'rankedTop=${rankedTop.join(',')}';
}

String saComplianceSummaryLine({
  required int checked,
  required int reselected,
  required int noCandidate,
}) {
  return '[SA] compliance-summary checked=$checked '
      'reselected=$reselected noCandidate=$noCandidate';
}

String saSwitchSkipLine({
  required String serviceId,
  required String groupName,
  required String target,
  required String why,
}) {
  return '[SA] switch-skip service=$serviceId group=$groupName '
      'target=$target why=$why';
}

String saFailoverCountLine({
  required String serviceId,
  required String node,
  required ServiceAccessReason reason,
  required int count,
  required bool borrowed,
}) {
  return '[SA] failover-count service=$serviceId node=$node '
      'reason=${reason.name} count=$count borrowed=$borrowed';
}

String saFailoverSwitchLine({
  required String serviceId,
  required String from,
  required String to,
  required String reason,
  required bool isFallback,
}) {
  return '[SA] failover-switch service=$serviceId from=$from to=$to '
      'reason=$reason fallback=$isFallback';
}

String saSwitchFailedLine({
  required String groupName,
  required String target,
  required bool inGroup,
  required int memberCount,
}) {
  return '[SA] switch-failed group=$groupName target=$target '
      'inGroup=$inGroup memberCount=$memberCount';
}

String saProbeRoundLine({
  required int nodes,
  required int metaUpdated,
  required Map<ServiceAccessReason, int> reasonCounts,
}) {
  int count(ServiceAccessReason reason) => reasonCounts[reason] ?? 0;
  return '[SA] probe-round nodes=$nodes metaUpdated=$metaUpdated '
      'accessible=${count(ServiceAccessReason.accessible)} '
      'regionBlocked=${count(ServiceAccessReason.regionBlocked)} '
      'networkFailed=${count(ServiceAccessReason.networkFailed)} '
      'unknown=${count(ServiceAccessReason.unknown)}';
}

String saProbeQueueLine({
  required int probed,
  required int remaining,
  required int total,
}) {
  return '[SA] probe-queue probed=$probed remaining=$remaining total=$total';
}

String saPanelCheckLine({
  required String serviceId,
  required String via,
  required String status,
  required int? delayMs,
}) {
  return '[SA] panel-check service=$serviceId via=$via status=$status '
      'delay=${delayMs ?? -1}';
}

String saPanelRoundLine({
  required int checked,
  required int available,
  required int failed,
  required int blocked,
  required int cancelled,
  required int other,
}) {
  return '[SA] panel-round checked=$checked available=$available '
      'failed=$failed blocked=$blocked cancelled=$cancelled other=$other';
}

String saAnchorSetLine({
  required String serviceId,
  required String node,
  required String countryCode,
}) {
  return '[SA] anchor-set service=$serviceId node=$node '
      'country=$countryCode';
}

String saAnchorRejectLine({
  required String serviceId,
  required String node,
  required String why,
}) {
  return '[SA] anchor-reject service=$serviceId node=$node reason=$why';
}
