import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _lockCountries = [
  '',
  'US',
  'SG',
  'JP',
  'HK',
  'KR',
  'TW',
  'DE',
  'GB',
  'NL',
];

List<ServiceToggleConfig> effectiveSmartServices(SmartAnchorInput input) {
  final byId = {
    for (final service in defaultServiceToggles) service.serviceId: service,
    for (final service in input.services) service.serviceId: service,
  };
  return [
    for (final service in defaultServiceToggles) byId[service.serviceId]!,
  ];
}

class SmartAnchorSettingsView extends ConsumerWidget {
  const SmartAnchorSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final services = effectiveSmartServices(input);
    final groups = ref.watch(groupsProvider);
    return CommonScaffold(
      title: appLocalizations.smartAnchor,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: appLocalizations.smartAnchorServices,
            items: [
              for (final service in services) ...[
                DecorationListItem(
                  title: Text(service.displayName),
                  subtitle: Text(
                    service.isEnabled
                        ? '${appLocalizations.countryLock}: '
                              '${service.targetCountry.isEmpty ? appLocalizations.countryLockNone : service.targetCountry}'
                        : appLocalizations.turnOff,
                  ),
                  trailing: CommonSwitch(
                    value: service.isEnabled,
                    onChanged: (value) {
                      ref
                          .read(smartAnchorProvider.notifier)
                          .updateService(service.serviceId, isEnabled: value);
                    },
                  ),
                ),
                ListItem<String>.options(
                  title: Text(
                    '${service.displayName} ${appLocalizations.countryLock}',
                  ),
                  options: _lockCountries,
                  textBuilder: (code) =>
                      code.isEmpty ? appLocalizations.countryLockNone : code,
                  value: service.targetCountry,
                  onChanged: (code) {
                    ref
                        .read(smartAnchorProvider.notifier)
                        .updateService(service.serviceId, targetCountry: code);
                  },
                ),
              ],
            ],
            footer: appLocalizations.smartAnchorLockDesc,
          ),
          generateSection(
            title: appLocalizations.subscriptionAggregation,
            items: [
              ListItem<AggregationGroupMode>.options(
                title: Text(appLocalizations.aggregationMode),
                options: AggregationGroupMode.values,
                textBuilder: (mode) => mode == AggregationGroupMode.primaryOnly
                    ? appLocalizations.aggregationPrimaryOnly
                    : appLocalizations.aggregationMergeAll,
                value: input.aggregationMode,
                onChanged: (mode) {
                  ref
                      .read(smartAnchorProvider.notifier)
                      .setAggregationMode(mode);
                },
              ),
              DecorationListItem(
                title: Text(appLocalizations.smartAnchorProbeNow),
                onPressed: () {
                  final groupNames = {for (final group in groups) group.name};
                  final names = <String>{};
                  var current = '';
                  for (final group in groups) {
                    if (group.name.startsWith('🎯 Smart-') &&
                        group.now != null) {
                      current = group.now!;
                    }
                    for (final proxy in group.all) {
                      if (!groupNames.contains(proxy.name)) {
                        names.add(proxy.name);
                      }
                    }
                  }
                  ref
                      .read(smartAnchorProvider.notifier)
                      .probeNodes(
                        proxyNames: names.toList(),
                        currentProxyName: current,
                        force: true,
                      );
                },
              ),
            ],
            footer: appLocalizations.smartAnchorAggregationDesc,
          ),
          generateSection(
            title: appLocalizations.smartAnchorDiagnostics,
            items: [
              for (final service in services)
                if (input.anchors[service.serviceId] case final anchor?)
                  DecorationListItem(
                    title: Text(service.displayName),
                    subtitle: Text(
                      '${anchor.city.isEmpty ? anchor.countryCode : anchor.city} · '
                      '${anchor.asn} · '
                      '${ScoringEngine.trustTier(_anchorPurity(input, service.serviceId))}',
                    ),
                    trailing: FilledButton(
                      onPressed: () {
                        ref
                            .read(smartAnchorProvider.notifier)
                            .clearAnchor(service.serviceId);
                      },
                      child: Text(appLocalizations.smartAnchorResetAnchor),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

double _anchorPurity(SmartAnchorInput input, String serviceId) {
  final anchor = input.anchors[serviceId];
  if (anchor == null) {
    return 0;
  }
  return input.metadataByProxy[anchor.lastProxyName]?.purityScore ?? 0;
}
