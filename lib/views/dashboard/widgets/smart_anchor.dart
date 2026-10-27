import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/smart_anchor.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'card.dart';

Future<void> _showSmartAnchorSettings(BuildContext context) {
  return showSheet(
    context: context,
    builder: (_) => const SmartAnchorSettingsView(),
  );
}

class SmartAnchorCard extends ConsumerWidget {
  const SmartAnchorCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final services = effectiveSmartServices(input);
    final enabled = services.where((service) => service.isEnabled).toList();
    final anchors = input.anchors;
    final firstAnchor = enabled.isEmpty
        ? null
        : anchors[enabled.first.serviceId];
    return DashboardCard(
      semanticLabel: appLocalizations.smartAnchor,
      onTap: () => _showSmartAnchorSettings(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.verified,
            title: appLocalizations.smartAnchor,
            chevron: true,
          ),
          const SizedBox(height: 12),
          Text(
            enabled.isEmpty
                ? appLocalizations.turnOff
                : '${enabled.length} ${appLocalizations.smartAnchorServices}',
            style: AppTextStyle.subheadline.of(context),
          ),
          if (firstAnchor != null) ...[
            const SizedBox(height: 6),
            Text(
              '${firstAnchor.city.isEmpty ? firstAnchor.countryCode : firstAnchor.city} · ${firstAnchor.asn}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.footnote.of(context),
            ),
          ],
        ],
      ),
    );
  }
}

class AggregationCard extends ConsumerWidget {
  const AggregationCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final hasSources = input.aggregationSources.isNotEmpty;
    return DashboardCard(
      semanticLabel: appLocalizations.subscriptionAggregation,
      onTap: () => _showSmartAnchorSettings(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.layers,
            title: appLocalizations.subscriptionAggregation,
            chevron: true,
          ),
          const SizedBox(height: 12),
          Text(
            !hasSources
                ? appLocalizations.turnOff
                : input.aggregationMode == AggregationGroupMode.primaryOnly
                ? appLocalizations.aggregationPrimaryOnly
                : appLocalizations.aggregationMergeAll,
            style: AppTextStyle.subheadline.of(context),
          ),
          if (hasSources) ...[
            const SizedBox(height: 6),
            const Text(
              '🔗 聚合全部节点',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
