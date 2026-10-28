import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String _profileHost(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.isEmpty ? url : host;
}

Future<void> toggleAggregationSource(
  WidgetRef ref,
  AppLocalizations appLocalizations,
  Profile profile,
  bool enable,
) async {
  final label = profile.label.isEmpty
      ? _profileHost(profile.url)
      : profile.label;
  final notifier = ref.read(smartAnchorProvider.notifier);
  if (!enable) {
    notifier.setAggregationSource(
      sourceId: 'profile:${profile.id}',
      sourceLabel: label,
      config: const {},
      enabled: false,
    );
  } else {
    try {
      final config = await ref.read(coreHandlerProvider).getConfig(profile.id);
      notifier.setAggregationSource(
        sourceId: 'profile:${profile.id}',
        sourceLabel: label,
        config: config,
        enabled: true,
      );
    } catch (_) {
      dialogs.showNotifier(
        appLocalizations.smartAnchorAggregationLoadFailed,
        level: MessageLevel.error,
      );
      return;
    }
  }
  ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
}

/// Subscription aggregation, managed where the profiles live: one switch
/// turns it on, and the profiles in the list below each get a checkbox.
/// The current profile stays the primary one; checked profiles only
/// contribute nodes.
class SmartAnchorAggregationCard extends ConsumerWidget {
  const SmartAnchorAggregationCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final current = ref.watch(currentProfileProvider);
    final enabled = input.aggregationEnabled;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: generateSection(
        title: appLocalizations.subscriptionAggregation,
        items: [
          DecorationListItem(
            title: Text(
              appLocalizations.subscriptionAggregation,
              style: AppTextStyle.body.of(context),
            ),
            subtitle: Text(
              appLocalizations.smartAnchorAggregationDesc,
              style: AppTextStyle.footnote
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
            trailing: CommonSwitch(
              value: enabled,
              onChanged: (value) {
                ref
                    .read(smartAnchorProvider.notifier)
                    .setAggregationEnabled(value);
                ref
                    .read(setupActionProvider.notifier)
                    .applyProfileDebounce(silence: true);
              },
            ),
          ),
          if (enabled && current != null)
            DecorationListItem(
              title: Text(
                '${appLocalizations.smartAnchorPrimarySubscription}: '
                '${current.label.isEmpty ? _profileHost(current.url) : current.label}',
                style: AppTextStyle.body.of(context),
              ),
            ),
          if (enabled)
            ListItem<AggregationGroupMode>.options(
              title: Text(appLocalizations.aggregationMode),
              options: AggregationGroupMode.values,
              textBuilder: (mode) => mode == AggregationGroupMode.primaryOnly
                  ? appLocalizations.aggregationPrimaryOnly
                  : appLocalizations.aggregationMergeAll,
              value: input.aggregationMode,
              onChanged: (mode) {
                ref.read(smartAnchorProvider.notifier).setAggregationMode(mode);
                ref
                    .read(setupActionProvider.notifier)
                    .applyProfileDebounce(silence: true);
              },
            ),
        ],
        footer: enabled
            ? input.aggregationMode == AggregationGroupMode.primaryOnly
                  ? appLocalizations.aggregationPrimaryOnlyDesc
                  : appLocalizations.aggregationMergeAllDesc
            : null,
      ),
    );
  }
}
