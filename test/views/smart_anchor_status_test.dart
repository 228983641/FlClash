import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/views/smart_anchor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

class _EmptyPoolSmartAnchor extends SmartAnchor {
  _EmptyPoolSmartAnchor(this.input);

  final SmartAnchorInput input;

  @override
  SmartAnchorInput build() => input;
}

void main() {
  for (final mode in [
    ServiceRestrictionMode.strict,
    ServiceRestrictionMode.relaxed,
  ]) {
    for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
      testWidgets('empty $mode pool shows policy status in $locale', (
        tester,
      ) async {
        final service = defaultServiceToggles.first.copyWith(
          restrictionMode: mode,
          targetCountry: 'US',
          targetCountries: const ['US'],
        );
        final input = SmartAnchorInput(
          services: [
            for (final preset in defaultServiceToggles)
              preset.serviceId == service.serviceId
                  ? service
                  : preset.copyWith(isEnabled: false),
          ],
          metadataByProxy: {
            'outside-lock': NodeMetadataCache(
              proxyName: 'outside-lock',
              entryServer: 'example.test',
              egressIp: '192.0.2.1',
              countryCode: 'JP',
              latitude: 35,
              longitude: 139,
              asn: 'AS64500',
              ipType: 'unknown',
              fraudScore: 0,
              purityScore: 90,
              wafPass: true,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          },
        );
        await tester.pumpWidget(
          TestApp(
            includeNavigatorKey: false,
            locale: locale,
            overrides: [
              smartAnchorProvider.overrideWith(
                () => _EmptyPoolSmartAnchor(input),
              ),
              groupsProvider.overrideWithValue([
                Group(
                  type: GroupType.Selector,
                  name: smartGroupName(service),
                  now: 'outside-lock',
                  all: const [Proxy(name: 'outside-lock', type: 'vless')],
                ),
              ]),
            ],
            child: const SmartAnchorSettingsView(),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            locale.languageCode == 'en'
                ? 'No nodes currently meet the routing policy. Check the probe results.'
                : '暂无满足当前路由策略的节点，请检查探测结果。',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('DIRECT'), findsNothing);
        expect(find.textContaining('回退直连'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
