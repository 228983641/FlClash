import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_group.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/views/smart_anchor_edit.dart';
import 'package:fl_clash/smart_anchor/services/cloudflare_trace.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/service_status.dart';
import 'package:fl_clash/smart_anchor/services/subscription_merger.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _lockCountries = ['US', 'SG', 'JP', 'HK', 'KR', 'TW', 'DE', 'GB', 'NL'];

String _lockSummary(List<String> lockedCountries, String noneLabel) {
  return lockedCountries.isEmpty ? noneLabel : lockedCountries.join(', ');
}

List<ServiceToggleConfig> effectiveSmartServices(SmartAnchorInput input) {
  final byId = {
    for (final service in defaultServiceToggles) service.serviceId: service,
    for (final service in input.services) service.serviceId: service,
  };
  final defaultIds = {
    for (final service in defaultServiceToggles) service.serviceId,
  };
  return [
    for (final service in defaultServiceToggles) byId[service.serviceId]!,
    for (final service in input.services)
      if (!defaultIds.contains(service.serviceId))
        byId[service.serviceId] ?? service,
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
    final profiles = ref.watch(profilesProvider);
    final currentProfileId = ref.watch(currentProfileProvider)?.id;
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
              DecorationListItem(
                title: Text(appLocalizations.smartAnchorAutoFailover),
                subtitle: Text(appLocalizations.smartAnchorAutoFailoverDesc),
                trailing: CommonSwitch(
                  value: input.autoFailoverEnabled,
                  onChanged: (value) {
                    ref
                        .read(smartAnchorProvider.notifier)
                        .setAutoFailover(value);
                  },
                ),
              ),
              for (final service in services)
                DecorationListItem(
                  title: Text(service.displayName),
                  subtitle: Text(
                    service.isEnabled
                        ? '${appLocalizations.countryLock}: '
                              '${_lockSummary(service.lockedCountries, appLocalizations.countryLockNone)}'
                              '${input.anchors[service.serviceId] == null ? '' : ' · ${input.anchors[service.serviceId]!.city.isEmpty ? input.anchors[service.serviceId]!.countryCode : input.anchors[service.serviceId]!.city}'}'
                        : appLocalizations.turnOff,
                  ),
                  trailing: CommonSwitch(
                    value: service.isEnabled,
                    onChanged: (value) {
                      ref
                          .read(smartAnchorProvider.notifier)
                          .updateService(service.serviceId, isEnabled: value);
                      ref
                          .read(setupActionProvider.notifier)
                          .applyProfileDebounce(silence: true);
                    },
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            SmartAnchorServiceEditView(service: service),
                      ),
                    );
                  },
                ),
              ListItem.open(
                leading: const GlyphIcon(AppGlyphs.add),
                title: Text(
                  '${appLocalizations.add} ${appLocalizations.smartAnchorServices}',
                ),
                widget: const SmartAnchorServiceEditView(),
              ),
            ],
          ),
          generateSection(
            title: appLocalizations.countryLock,
            items: [
              for (final group in defaultServiceGroups) ...[
                if (group.serviceIds.length > 1)
                  DecorationListItem(
                    title: Text(
                      '${group.displayName} ${appLocalizations.smartAnchorSharedLock}',
                    ),
                    subtitle: Text(
                      group.serviceIds
                          .map(
                            (id) => services
                                .firstWhere(
                                  (service) => service.serviceId == id,
                                )
                                .displayName,
                          )
                          .join(', '),
                    ),
                    trailing: CommonSwitch(
                      value: input.sharedLockGroupIds.contains(group.id),
                      onChanged: (value) {
                        ref
                            .read(smartAnchorProvider.notifier)
                            .setSharedLockGroup(group.id, value);
                        ref
                            .read(setupActionProvider.notifier)
                            .applyProfileDebounce(silence: true);
                      },
                    ),
                  ),
                if (group.serviceIds.length == 1 ||
                    input.sharedLockGroupIds.contains(group.id))
                  ListItem.open(
                    title: Text(
                      '${group.displayName} ${appLocalizations.countryLock}',
                    ),
                    subtitle: Text(
                      _lockSummary(
                        services
                            .firstWhere(
                              (service) =>
                                  service.serviceId == group.serviceIds.first,
                            )
                            .lockedCountries,
                        appLocalizations.countryLockNone,
                      ),
                    ),
                    widget: SmartAnchorCountryPickerView(
                      serviceId: group.serviceIds.first,
                    ),
                  ),
                if (group.serviceIds.length > 1 &&
                    !input.sharedLockGroupIds.contains(group.id))
                  for (final memberId in group.serviceIds)
                    ListItem.open(
                      title: Text(
                        '${services.firstWhere((service) => service.serviceId == memberId).displayName} ${appLocalizations.countryLock}',
                      ),
                      subtitle: Text(
                        _lockSummary(
                          services
                              .firstWhere(
                                (service) => service.serviceId == memberId,
                              )
                              .lockedCountries,
                          appLocalizations.countryLockNone,
                        ),
                      ),
                      widget: SmartAnchorCountryPickerView(serviceId: memberId),
                    ),
                for (final service in services)
                  if (groupForService(service.serviceId) == null)
                    ListItem.open(
                      title: Text(
                        '${service.displayName} ${appLocalizations.countryLock}',
                      ),
                      subtitle: Text(
                        _lockSummary(
                          service.lockedCountries,
                          appLocalizations.countryLockNone,
                        ),
                      ),
                      widget: SmartAnchorCountryPickerView(
                        serviceId: service.serviceId,
                      ),
                    ),
              ],
            ],
            footer: appLocalizations.smartAnchorLockDesc,
          ),
          generateSection(
            title: appLocalizations.subscriptionAggregation,
            items: [
              for (final profile in profiles)
                if (profile.id != currentProfileId &&
                    profile.type != ProfileType.custom)
                  DecorationListItem(
                    title: Text(
                      profile.label.isEmpty ? profile.url : profile.label,
                    ),
                    trailing: CommonSwitch(
                      value: input.aggregationSources.any(
                        (source) => source.sourceId == 'profile:${profile.id}',
                      ),
                      onChanged: (value) async {
                        if (!value) {
                          ref
                              .read(smartAnchorProvider.notifier)
                              .setAggregationSource(
                                sourceId: 'profile:${profile.id}',
                                sourceLabel: profile.label.isEmpty
                                    ? profile.url
                                    : profile.label,
                                config: const {},
                                enabled: false,
                              );
                        } else {
                          try {
                            final config = await ref
                                .read(coreHandlerProvider)
                                .getConfig(profile.id);
                            ref
                                .read(smartAnchorProvider.notifier)
                                .setAggregationSource(
                                  sourceId: 'profile:${profile.id}',
                                  sourceLabel: profile.label.isEmpty
                                      ? profile.url
                                      : profile.label,
                                  config: config,
                                  enabled: true,
                                );
                          } catch (_) {
                            return;
                          }
                        }
                        ref
                            .read(setupActionProvider.notifier)
                            .applyProfileDebounce(silence: true);
                      },
                    ),
                  ),
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
              const _CloudflareEdgeRow(),
              for (final entry in officialStatusEndpoints.entries)
                _OfficialStatusRow(
                  serviceId: entry.key,
                  endpoint: entry.value,
                  displayName: services
                      .firstWhere(
                        (service) => service.serviceId == entry.key,
                        orElse: () => defaultServiceToggles.first,
                      )
                      .displayName,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class SmartAnchorCountryPickerView extends ConsumerWidget {
  const SmartAnchorCountryPickerView({super.key, required this.serviceId});

  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final services = effectiveSmartServices(input);
    final service = services.firstWhere(
      (candidate) => candidate.serviceId == serviceId,
    );
    final selected = service.lockedCountries;
    void apply(List<String> next) {
      ref.read(smartAnchorProvider.notifier).setLockCountries(serviceId, next);
      ref
          .read(setupActionProvider.notifier)
          .applyProfileDebounce(silence: true);
    }

    return CommonScaffold(
      title: '${service.displayName} ${appLocalizations.countryLock}',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: appLocalizations.countryLock,
            items: [
              DecorationListItem(
                title: Text(appLocalizations.countryLockNone),
                trailing: CommonSwitch(
                  value: selected.isEmpty,
                  onChanged: (value) {
                    if (value) {
                      apply(const []);
                    }
                  },
                ),
              ),
              for (final code in _lockCountries)
                DecorationListItem(
                  title: Text(code),
                  trailing: CommonSwitch(
                    value: selected.contains(code),
                    onChanged: (value) {
                      final next = [
                        for (final country in selected)
                          if (country != code) country,
                      ];
                      if (value) {
                        next.add(code);
                      }
                      apply(next);
                    },
                  ),
                ),
            ],
            footer: appLocalizations.smartAnchorLockDesc,
          ),
        ],
      ),
    );
  }
}

class _CloudflareEdgeRow extends StatefulWidget {
  const _CloudflareEdgeRow();

  @override
  State<_CloudflareEdgeRow> createState() => _CloudflareEdgeRowState();
}

class _CloudflareEdgeRowState extends State<_CloudflareEdgeRow> {
  CloudflareEdgeInfo? _info;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await request.dio.get<String>(
        'https://www.cloudflare.com/cdn-cgi/trace',
      );
      final info = response.data == null
          ? null
          : parseCloudflareTrace(response.data!);
      if (!mounted) {
        return;
      }
      setState(() {
        _info = info;
        _failed = info == null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final info = _info;
    return DecorationListItem(
      title: const Text('Cloudflare'),
      subtitle: Text(
        info == null
            ? _failed
                  ? appLocalizations.serviceFailed
                  : appLocalizations.loading
            : '${info.colo} · ${info.countryCode} · '
                  '${info.warpOn ? 'WARP on' : 'WARP off'} · ${info.httpProtocol}',
      ),
    );
  }
}

class _OfficialStatusRow extends StatefulWidget {
  const _OfficialStatusRow({
    required this.serviceId,
    required this.endpoint,
    required this.displayName,
  });

  final String serviceId;
  final String endpoint;
  final String displayName;

  @override
  State<_OfficialStatusRow> createState() => _OfficialStatusRowState();
}

class _OfficialStatusRowState extends State<_OfficialStatusRow> {
  OfficialServiceStatus? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final response = await request.dio.get<Map<String, dynamic>>(
        widget.endpoint,
      );
      if (!mounted || response.data == null) {
        return;
      }
      setState(() => _status = parseStatuspageStatus(response.data!));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _status = OfficialServiceStatus.unknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final status = _status;
    return DecorationListItem(
      title: Text(widget.displayName),
      subtitle: Text(switch (status) {
        null => appLocalizations.loading,
        OfficialServiceStatus.operational => appLocalizations.serviceAvailable,
        OfficialServiceStatus.outage => appLocalizations.serviceUnavailable,
        _ => appLocalizations.unknown,
      }),
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
