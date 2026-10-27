import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot round-trips aggregation mode and source stubs', () {
    const snapshot = SmartAnchorSnapshot(
      aggregationMode: AggregationGroupMode.mergeAll,
      aggregationSources: [
        AggregationSourceInput(
          sourceId: 'profile:3',
          sourceLabel: '备用订阅',
          config: {'proxies': []},
        ),
        AggregationSourceInput(
          sourceId: 'profile:7',
          sourceLabel: '',
          config: {'proxies': []},
        ),
      ],
    );
    final restored = SmartAnchorSnapshot.fromJson(snapshot.toJson());
    expect(restored.aggregationMode, AggregationGroupMode.mergeAll);
    expect(
      [for (final source in restored.aggregationSources) source.sourceId],
      ['profile:3', 'profile:7'],
    );
    expect(
      [for (final source in restored.aggregationSources) source.sourceLabel],
      ['备用订阅', ''],
    );
    expect(
      restored.aggregationSources.every((source) => source.config.isEmpty),
      isTrue,
    );
  });

  test('missing or unknown aggregation fields fall back to defaults', () {
    final missing = SmartAnchorSnapshot.fromJson({});
    expect(missing.aggregationMode, AggregationGroupMode.primaryOnly);
    expect(missing.aggregationSources, isEmpty);
    final unknown = SmartAnchorSnapshot.fromJson({
      'aggregationMode': 'noSuchMode',
      'aggregationSources': [
        {'sourceId': '', 'sourceLabel': 'x'},
      ],
    });
    expect(unknown.aggregationMode, AggregationGroupMode.primaryOnly);
    expect(unknown.aggregationSources, isEmpty);
  });
}
