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
  required bool currentUnknown,
  required List<String> rankedTop,
  String? decisionExplanation,
}) {
  final line =
      '[SA] compliance service=$serviceId group=$groupName '
      'current=$currentName -> $target reason=lock-change '
      'currentUnknown=$currentUnknown rankedTop=${rankedTop.join(',')}';
  if (decisionExplanation == null) {
    return line;
  }
  return '$line decision=$decisionExplanation';
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
  String? tier,
  int? failureCount,
  String? decisionExplanation,
  int? cooldownUntilMs,
  int? switchesInWindow,
}) {
  final buffer = StringBuffer(
    '[SA] failover-switch service=$serviceId from=$from to=$to '
    'reason=$reason fallback=$isFallback',
  );
  if (tier != null) {
    buffer.write(' tier=$tier');
  }
  if (failureCount != null) {
    buffer.write(' failures=$failureCount');
  }
  if (switchesInWindow != null) {
    buffer.write(' switchesInWindow=$switchesInWindow');
  }
  if (cooldownUntilMs != null) {
    buffer.write(' cooldownUntil=$cooldownUntilMs');
  }
  if (decisionExplanation != null) {
    buffer.write(' decision=$decisionExplanation');
  }
  return buffer.toString();
}

String saServiceOutageLine({
  required String serviceId,
  required int evidenceCount,
  required int windowMs,
}) {
  return '[SA] service-outage service=$serviceId evidence=$evidenceCount '
      'windowMs=$windowMs action=hold-current';
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
      'ispBlocked=${count(ServiceAccessReason.ispBlocked)} '
      'restricted=${count(ServiceAccessReason.restricted)} '
      'blocked=${count(ServiceAccessReason.blocked)} '
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

String saAnchorReplaceLine({
  required String serviceId,
  required String from,
  required String to,
  required String why,
}) {
  return '[SA] anchor-replace service=$serviceId from=$from to=$to '
      'reason=$why';
}

String saRankAnchorsLine({required Map<String, String> anchors}) {
  final services = anchors.keys.toList()..sort();
  final pairs = [
    for (final serviceId in services) '$serviceId=${anchors[serviceId]}',
  ];
  return '[SA] rank-anchors ${pairs.join(' ')}';
}

String saDelayRoundLine({
  required int targets,
  required int screenAnswered,
  required int refined,
  required int ok,
  required int timeout,
  required int failed,
  required int unmeasured,
  required int durationMs,
  required bool usedFallback,
  String? fallbackReason,
}) {
  final mode = usedFallback ? 'fallback' : 'batch';
  final reason = fallbackReason == null
      ? ''
      : ' fallbackReason=$fallbackReason';
  return '[SA] delay-round targets=$targets screenAnswered=$screenAnswered '
      'refined=$refined ok=$ok timeout=$timeout failed=$failed '
      'unmeasured=$unmeasured durationMs=$durationMs mode=$mode$reason';
}

String saMetaFailLine({required String node, required String reason}) {
  return '[SA] meta-fail node=$node reason=$reason';
}

String saMetaRoundLine({
  required int probed,
  required int metaOk,
  required int metaFailed,
  required int noEgress,
  required int geoFailed,
  required int wafPass,
  required int wafFail,
  required int wafUnknown,
}) {
  return '[SA] meta-round probed=$probed ok=$metaOk failed=$metaFailed '
      'noEgress=$noEgress geoFailed=$geoFailed wafPass=$wafPass '
      'wafFail=$wafFail wafUnknown=$wafUnknown';
}

String saPurityTierLine({
  required String node,
  required String fromTier,
  required String toTier,
  required double score,
}) {
  return '[SA] purity-tier node=$node from=$fromTier to=$toTier '
      'score=${score.round()}';
}

String saBorrowFanoutLine({
  required String donor,
  required List<String> borrowers,
  required int nodes,
}) {
  final sorted = List.of(borrowers)..sort();
  return '[SA] borrow-fanout donor=$donor borrowers=${sorted.join(',')} '
      'nodes=$nodes';
}

String saBorrowExcludeLine({
  required String serviceId,
  required String node,
  required String donor,
  required String via,
}) {
  return '[SA] borrow-exclude service=$serviceId node=$node donor=$donor '
      'via=$via';
}

String saDerivedRegionsLine({
  required String serviceId,
  required Set<String> blockedBefore,
  required Set<String> blockedAfter,
  Map<String, ({int proxies, int asns})> heldBack = const {},
}) {
  String render(Set<String> countries) {
    final sorted = countries.toList()..sort();
    return '{${sorted.join(',')}}';
  }

  final line =
      '[SA] derived-regions service=$serviceId '
      'blocked=${render(blockedBefore)}->${render(blockedAfter)}';
  if (heldBack.isEmpty) {
    return line;
  }
  final countries = heldBack.keys.toList()..sort();
  final tallies = countries
      .map((country) {
        final tally = heldBack[country]!;
        return '$country:${tally.proxies}/${tally.asns}';
      })
      .join(',');
  return '$line held={$tallies}';
}

String saFailoverFreezeLine({required String serviceId, required int untilMs}) {
  return '[SA] failover-freeze service=$serviceId until=$untilMs';
}

String saFailoverFreezeEndLine({required String serviceId}) {
  return '[SA] failover-freeze-end service=$serviceId';
}

String saMergeSummaryLine({
  required int sources,
  required int proxiesIn,
  required int proxiesOut,
  required int pruned,
}) {
  return '[SA] merge-summary sources=$sources proxiesIn=$proxiesIn '
      'proxiesOut=$proxiesOut pruned=$pruned';
}

String saSanitizeLine({
  required String groupName,
  required String from,
  required String to,
}) {
  return '[SA] sanitize group=$groupName old=$from new=$to '
      'reason=not-in-ranking';
}

String saSanitizeKeepLine({
  required String groupName,
  required String current,
  required String reason,
}) {
  return '[SA] sanitize-keep group=$groupName current=$current '
      'reason=$reason';
}

String saBuildDecisionLine({
  required String serviceId,
  required String explanation,
}) {
  return '[SA] build-decision service=$serviceId $explanation';
}

String saNoCandidateLine({
  required String serviceId,
  required String groupName,
  required String mode,
}) {
  return '[SA] no-candidate service=$serviceId group=$groupName '
      'mode=$mode fallback=REJECT';
}

String saStrippedAmbiguousLine({
  required String name,
  required int candidates,
}) {
  return '[SA] stripped-ambiguous name=$name candidates=$candidates';
}

String saLockChangeLine({
  required String serviceId,
  required int services,
  required int anchorsCleared,
  required List<String> countries,
}) {
  final codes = countries.isEmpty ? 'none' : countries.join(',');
  return '[SA] lock-change service=$serviceId services=$services '
      'anchorsCleared=$anchorsCleared countries=$codes';
}

String saTickLine({
  required int anchors,
  required int compliance,
  required int probeUpdated,
  required int failover,
}) {
  return '[SA] tick anchors=$anchors compliance=$compliance '
      'probeUpdated=$probeUpdated failover=$failover';
}

String saReprobeLine({required String source}) {
  return '[SA] reprobe source=$source';
}
