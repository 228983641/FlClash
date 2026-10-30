import 'package:fl_clash/smart_anchor/services/sa_log.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compliance decision line carries the switch context', () {
    expect(
      saComplianceDecisionLine(
        serviceId: 'claude',
        groupName: '🎯 Smart-Claude',
        currentName: 'TW-1',
        target: 'US-1',
        currentUnknown: false,
        rankedTop: const ['US-1', 'US-2', 'JP-1'],
      ),
      '[SA] compliance service=claude group=🎯 Smart-Claude '
      'current=TW-1 -> US-1 reason=lock-change '
      'currentUnknown=false rankedTop=US-1,US-2,JP-1',
    );
  });

  test('compliance decision line marks an untested current node', () {
    expect(
      saComplianceDecisionLine(
        serviceId: 'claude',
        groupName: '🎯 Smart-Claude',
        currentName: 'bestcf',
        target: 'TW-1',
        currentUnknown: true,
        rankedTop: const ['TW-1'],
      ),
      '[SA] compliance service=claude group=🎯 Smart-Claude '
      'current=bestcf -> TW-1 reason=lock-change '
      'currentUnknown=true rankedTop=TW-1',
    );
  });

  test('switch failed line carries the membership verdict', () {
    expect(
      saSwitchFailedLine(
        groupName: '🎯 Smart-Claude',
        target: 'US-03',
        inGroup: false,
        memberCount: 2,
      ),
      '[SA] switch-failed group=🎯 Smart-Claude target=US-03 '
      'inGroup=false memberCount=2',
    );
  });

  test('failover count line carries the borrowed marker', () {
    expect(
      saFailoverCountLine(
        serviceId: 'grok',
        node: 'US-1',
        reason: ServiceAccessReason.networkFailed,
        count: 0,
        borrowed: true,
      ),
      '[SA] failover-count service=grok node=US-1 '
      'reason=networkFailed count=0 borrowed=true',
    );
  });

  test('probe round line tallies reasons with zeroes filled in', () {
    expect(
      saProbeRoundLine(
        nodes: 32,
        metaUpdated: 5,
        reasonCounts: const {
          ServiceAccessReason.accessible: 40,
          ServiceAccessReason.regionBlocked: 3,
        },
      ),
      '[SA] probe-round nodes=32 metaUpdated=5 accessible=40 '
      'regionBlocked=3 ispBlocked=0 restricted=0 blocked=0 '
      'networkFailed=0 unknown=0',
    );
  });

  test('panel check line renders a missing delay as -1', () {
    expect(
      saPanelCheckLine(
        serviceId: 'youtube',
        via: 'US-1',
        status: 'unsupported-region',
        delayMs: null,
      ),
      '[SA] panel-check service=youtube via=US-1 '
      'status=unsupported-region delay=-1',
    );
  });

  test('delay round line marks the per-node fallback with its reason', () {
    expect(
      saDelayRoundLine(
        targets: 120,
        screenAnswered: 40,
        refined: 40,
        ok: 38,
        timeout: 50,
        failed: 30,
        unmeasured: 2,
        durationMs: 4200,
        usedFallback: true,
        fallbackReason: 'method not found',
      ),
      '[SA] delay-round targets=120 screenAnswered=40 refined=40 ok=38 '
      'timeout=50 failed=30 unmeasured=2 durationMs=4200 mode=fallback '
      'fallbackReason=method not found',
    );
    expect(
      saDelayRoundLine(
        targets: 3,
        screenAnswered: 3,
        refined: 3,
        ok: 3,
        timeout: 0,
        failed: 0,
        unmeasured: 0,
        durationMs: 900,
        usedFallback: false,
      ),
      '[SA] delay-round targets=3 screenAnswered=3 refined=3 ok=3 '
      'timeout=0 failed=0 unmeasured=0 durationMs=900 mode=batch',
    );
  });

  test('meta round line tallies failures by cause and waf outcomes', () {
    expect(
      saMetaRoundLine(
        probed: 32,
        metaOk: 20,
        metaFailed: 12,
        noEgress: 9,
        geoFailed: 3,
        wafPass: 18,
        wafFail: 2,
        wafUnknown: 12,
      ),
      '[SA] meta-round probed=32 ok=20 failed=12 noEgress=9 geoFailed=3 '
      'wafPass=18 wafFail=2 wafUnknown=12',
    );
    expect(
      saMetaFailLine(node: 'US-1', reason: 'no-egress'),
      '[SA] meta-fail node=US-1 reason=no-egress',
    );
    expect(
      saPurityTierLine(
        node: 'US-1',
        fromTier: 'safe',
        toTier: 'watch',
        score: 62.4,
      ),
      '[SA] purity-tier node=US-1 from=safe to=watch score=62',
    );
  });

  test('borrow lines name the donor and the exclusion path', () {
    expect(
      saBorrowFanoutLine(
        donor: 'openai',
        borrowers: const ['poe', 'grok'],
        nodes: 12,
      ),
      '[SA] borrow-fanout donor=openai borrowers=grok,poe nodes=12',
    );
    expect(
      saBorrowExcludeLine(
        serviceId: 'grok',
        node: 'SG-1',
        donor: 'openai',
        via: 'region',
      ),
      '[SA] borrow-exclude service=grok node=SG-1 donor=openai via=region',
    );
  });

  test('derived regions line renders both sets sorted', () {
    expect(
      saDerivedRegionsLine(
        serviceId: 'openai',
        blockedBefore: const {'JP', 'US'},
        blockedAfter: const {'US'},
      ),
      '[SA] derived-regions service=openai blocked={JP,US}->{US}',
    );
    expect(
      saDerivedRegionsLine(
        serviceId: 'openai',
        blockedBefore: const {},
        blockedAfter: const {'SG'},
      ),
      '[SA] derived-regions service=openai blocked={}->{SG}',
    );
    expect(
      saDerivedRegionsLine(
        serviceId: 'openai',
        blockedBefore: const {},
        blockedAfter: const {},
        heldBack: const {'HK': (proxies: 1, asns: 1)},
      ),
      '[SA] derived-regions service=openai blocked={}->{} held={HK:1/1}',
    );
    expect(
      saDerivedRegionsLine(
        serviceId: 'openai',
        blockedBefore: const {},
        blockedAfter: const {'JP'},
        heldBack: const {
          'JP': (proxies: 2, asns: 1),
          'HK': (proxies: 1, asns: 1),
        },
      ),
      '[SA] derived-regions service=openai blocked={}->{JP} '
      'held={HK:1/1,JP:2/1}',
    );
  });

  test('rank anchors line sorts services and anchor replace names both', () {
    expect(
      saRankAnchorsLine(anchors: const {'openai': 'JP-2', 'claude': 'US-1'}),
      '[SA] rank-anchors claude=US-1 openai=JP-2',
    );
    expect(
      saAnchorReplaceLine(
        serviceId: 'claude',
        from: 'US-1',
        to: 'US-9',
        why: 'stability',
      ),
      '[SA] anchor-replace service=claude from=US-1 to=US-9 '
      'reason=stability',
    );
  });

  test('freeze lines bracket the frozen window', () {
    expect(
      saFailoverFreezeLine(serviceId: 'youtube', untilMs: 1700000600000),
      '[SA] failover-freeze service=youtube until=1700000600000',
    );
    expect(
      saFailoverFreezeEndLine(serviceId: 'youtube'),
      '[SA] failover-freeze-end service=youtube',
    );
  });

  test('build lines cover merge, sanitize, ambiguity and lock changes', () {
    expect(
      saMergeSummaryLine(
        sources: 3,
        proxiesIn: 320,
        proxiesOut: 298,
        pruned: 14,
      ),
      '[SA] merge-summary sources=3 proxiesIn=320 proxiesOut=298 pruned=14',
    );
    expect(
      saSanitizeLine(groupName: '🎯 Smart-Claude', from: 'TW-1', to: 'US-1'),
      '[SA] sanitize group=🎯 Smart-Claude old=TW-1 new=US-1 '
      'reason=not-in-ranking',
    );
    expect(
      saStrippedAmbiguousLine(name: 'US-1', candidates: 3),
      '[SA] stripped-ambiguous name=US-1 candidates=3',
    );
    expect(
      saLockChangeLine(
        serviceId: 'claude',
        services: 5,
        anchorsCleared: 2,
        countries: const ['US', 'JP'],
      ),
      '[SA] lock-change service=claude services=5 anchorsCleared=2 '
      'countries=US,JP',
    );
    expect(
      saLockChangeLine(
        serviceId: 'claude',
        services: 1,
        anchorsCleared: 0,
        countries: const [],
      ),
      '[SA] lock-change service=claude services=1 anchorsCleared=0 '
      'countries=none',
    );
  });

  test('build decision, no-candidate and sanitize-keep lines', () {
    expect(
      saBuildDecisionLine(
        serviceId: 'claude',
        explanation: 'target=US-1 tier=L1; qualified=2 fallback=1 blocked=0',
      ),
      '[SA] build-decision service=claude target=US-1 tier=L1; '
      'qualified=2 fallback=1 blocked=0',
    );
    expect(
      saNoCandidateLine(
        serviceId: 'claude',
        groupName: '🎯 Smart-Claude',
        mode: 'strict',
      ),
      '[SA] no-candidate service=claude group=🎯 Smart-Claude '
      'mode=strict fallback=REJECT',
    );
    expect(
      saSanitizeKeepLine(
        groupName: '🎯 Smart-Claude',
        current: 'mystery',
        reason: 'unverifiableKept',
      ),
      '[SA] sanitize-keep group=🎯 Smart-Claude current=mystery '
      'reason=unverifiableKept',
    );
    expect(
      saSanitizeKeepLine(
        groupName: '🎯 Smart-Claude',
        current: 'TW-1',
        reason: 'noCandidateKept',
      ),
      '[SA] sanitize-keep group=🎯 Smart-Claude current=TW-1 '
      'reason=noCandidateKept',
    );
  });

  test('failover switch line carries the decision context when given', () {
    expect(
      saFailoverSwitchLine(
        serviceId: 'claude',
        from: 'JP-cur',
        to: 'JP-24',
        reason: 'regionBlocked',
        isFallback: false,
        tier: 'L1',
        failureCount: 2,
        decisionExplanation: 'target=JP-24 tier=L1; qualified=2',
        cooldownUntilMs: 1700000120000,
        switchesInWindow: 1,
      ),
      '[SA] failover-switch service=claude from=JP-cur to=JP-24 '
      'reason=regionBlocked fallback=false tier=L1 failures=2 '
      'switchesInWindow=1 cooldownUntil=1700000120000 '
      'decision=target=JP-24 tier=L1; qualified=2',
    );
    expect(
      saFailoverSwitchLine(
        serviceId: 'claude',
        from: 'JP-cur',
        to: 'JP-24',
        reason: 'regionBlocked',
        isFallback: false,
      ),
      '[SA] failover-switch service=claude from=JP-cur to=JP-24 '
      'reason=regionBlocked fallback=false',
    );
  });

  test('compliance line appends the decision explanation when given', () {
    expect(
      saComplianceDecisionLine(
        serviceId: 'claude',
        groupName: '🎯 Smart-Claude',
        currentName: 'TW-1',
        target: 'US-1',
        currentUnknown: false,
        rankedTop: const ['US-1'],
        decisionExplanation: 'target=US-1 tier=L6; qualified=1',
      ),
      '[SA] compliance service=claude group=🎯 Smart-Claude '
      'current=TW-1 -> US-1 reason=lock-change '
      'currentUnknown=false rankedTop=US-1 '
      'decision=target=US-1 tier=L6; qualified=1',
    );
  });

  test('service outage line names the evidence and the hold action', () {
    expect(
      saServiceOutageLine(
        serviceId: 'claude',
        evidenceCount: 3,
        windowMs: 300000,
      ),
      '[SA] service-outage service=claude evidence=3 windowMs=300000 '
      'action=hold-current',
    );
  });

  test('tick and reprobe lines stay one-liners', () {
    expect(
      saTickLine(anchors: 1, compliance: 2, probeUpdated: 5, failover: 1),
      '[SA] tick anchors=1 compliance=2 probeUpdated=5 failover=1',
    );
    expect(
      saReprobeLine(source: 'profile-refresh'),
      '[SA] reprobe source=profile-refresh',
    );
  });
}
