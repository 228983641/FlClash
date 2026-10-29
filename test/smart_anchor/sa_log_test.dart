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
        rankedTop: const ['US-1', 'US-2', 'JP-1'],
      ),
      '[SA] compliance service=claude group=🎯 Smart-Claude '
      'current=TW-1 -> US-1 reason=lock-change rankedTop=US-1,US-2,JP-1',
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
      'regionBlocked=3 networkFailed=0 unknown=0',
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
}
