import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
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
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _lockCountries = ['US', 'SG', 'JP', 'HK', 'KR', 'TW', 'DE', 'GB', 'NL'];

String _lockSummary(List<String> lockedCountries, String noneLabel) {
  return lockedCountries.isEmpty ? noneLabel : lockedCountries.join(', ');
}

String _countryName(AppLocalizations appLocalizations, String code) {
  switch (code) {
    case 'US':
      return appLocalizations.smartAnchorCountryUS;
    case 'SG':
      return appLocalizations.smartAnchorCountrySG;
    case 'JP':
      return appLocalizations.smartAnchorCountryJP;
    case 'HK':
      return appLocalizations.smartAnchorCountryHK;
    case 'KR':
      return appLocalizations.smartAnchorCountryKR;
    case 'TW':
      return appLocalizations.smartAnchorCountryTW;
    case 'DE':
      return appLocalizations.smartAnchorCountryDE;
    case 'GB':
      return appLocalizations.smartAnchorCountryGB;
    case 'NL':
      return appLocalizations.smartAnchorCountryNL;
    default:
      return code;
  }
}

class SmartAnchorSettingsView extends ConsumerWidget {
  const SmartAnchorSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final services = effectiveSmartServices(input);
    final groups = ref.watch(groupsProvider);
    final groupNames = {for (final group in groups) group.name};
    final proxyNames = <String>[];
    for (final group in groups) {
      for (final proxy in group.all) {
        if (!groupNames.contains(proxy.name) &&
            !proxyNames.contains(proxy.name)) {
          proxyNames.add(proxy.name);
        }
      }
    }
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
                        ? [
                            if (input.anchors[service.serviceId] != null)
                              input.anchors[service.serviceId]!.city.isEmpty
                                  ? input
                                        .anchors[service.serviceId]!
                                        .countryCode
                                  : input.anchors[service.serviceId]!.city,
                            if (serviceHasNoUsableNodes(
                              input,
                              service,
                              proxyNames,
                            ))
                              appLocalizations.smartAnchorNoUsableNodes,
                          ].join(' · ')
                        : appLocalizations.turnOff,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TonalButton(
                        size: TonalButtonSize.compact,
                        label: _lockSummary(
                          service.lockedCountries,
                          appLocalizations.countryLockNone,
                        ),
                        onPressed: service.isEnabled
                            ? () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        SmartAnchorCountryPickerView(
                                          serviceId: service.serviceId,
                                        ),
                                  ),
                                );
                              }
                            : null,
                      ),
                      const SizedBox(width: 8),
                      CommonSwitch(
                        value: service.isEnabled,
                        onChanged: (value) {
                          ref
                              .read(smartAnchorProvider.notifier)
                              .updateService(
                                service.serviceId,
                                isEnabled: value,
                              );
                          ref
                              .read(setupActionProvider.notifier)
                              .applyProfileDebounce(silence: true);
                        },
                      ),
                    ],
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
              DecorationListItem(
                leading: const GlyphIcon(AppGlyphs.add),
                title: Text(
                  '${appLocalizations.add} ${appLocalizations.smartAnchorServices}',
                ),
                onPressed: () async {
                  final created = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const SmartAnchorServiceEditView(),
                    ),
                  );
                  if (created == true) {
                    dialogs.showNotifier(
                      appLocalizations.smartAnchorServiceAddedHint,
                    );
                  }
                },
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
                      '${group.displayName} ${appLocalizations.smartAnchorSharedLock} '
                      '(${group.serviceIds.map((id) => services.firstWhere((service) => service.serviceId == id).displayName).join(', ')})',
                    ),
                    subtitle: Text(appLocalizations.smartAnchorSharedLockDesc),
                    trailing: CommonSwitch(
                      value: input.sharedLockGroupIds.contains(group.id),
                      onChanged: (value) async {
                        if (value) {
                          final confirmed = await dialogs.showMessage(
                            title: appLocalizations.smartAnchorSharedLock,
                            message: TextSpan(
                              text:
                                  appLocalizations.smartAnchorSharedLockConfirm,
                            ),
                            destructive: true,
                          );
                          if (confirmed != true) {
                            return;
                          }
                        }
                        ref
                            .read(smartAnchorProvider.notifier)
                            .setSharedLockGroup(group.id, value);
                        ref
                            .read(setupActionProvider.notifier)
                            .applyProfileDebounce(silence: true);
                      },
                    ),
                  ),
              ],
            ],
            footer: appLocalizations.smartAnchorLockDesc,
          ),
          generateSection(
            title: appLocalizations.smartAnchorDiagnostics,
            items: [
              _ProbeNowRow(groups: groups),
              for (final service in services)
                if (input.anchors[service.serviceId] case final anchor?)
                  DecorationListItem(
                    title: Text(service.displayName),
                    subtitle: Text(
                      '${anchor.city.isEmpty ? anchor.countryCode : anchor.city} · '
                      '${anchor.asn} · '
                      '${_trustTierLabel(appLocalizations, input, service.serviceId)}',
                    ),
                    trailing: FilledButton(
                      onPressed: () async {
                        final confirmed = await dialogs.showMessage(
                          title: appLocalizations.smartAnchorResetAnchor,
                          message: TextSpan(
                            text:
                                appLocalizations.smartAnchorResetAnchorConfirm,
                          ),
                          destructive: true,
                        );
                        if (confirmed != true) {
                          return;
                        }
                        ref
                            .read(smartAnchorProvider.notifier)
                            .clearAnchor(service.serviceId);
                      },
                      child: Text(appLocalizations.smartAnchorResetAnchor),
                    ),
                  ),
              for (final service in services)
                if (input.anchors[service.serviceId] == null)
                  DecorationListItem(
                    title: Text(service.displayName),
                    subtitle: Text(appLocalizations.smartAnchorNoAnchor),
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
    Future<void> apply(List<String> next) async {
      if (next.length == selected.length && next.every(selected.contains)) {
        return;
      }
      if (next.isEmpty && selected.isNotEmpty) {
        final confirmed = await dialogs.showMessage(
          title: appLocalizations.countryLock,
          message: TextSpan(text: appLocalizations.smartAnchorUnlockConfirm),
          destructive: true,
        );
        if (confirmed != true) {
          return;
        }
      }
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
                trailing: selected.isEmpty
                    ? GlyphIcon(
                        AppGlyphs.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onPressed: () => apply(const []),
              ),
              for (final code in _lockCountries)
                DecorationListItem(
                  title: Text(
                    '${_countryName(appLocalizations, code)} ($code)',
                  ),
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
            footer:
                '${appLocalizations.smartAnchorLockDesc}\n${appLocalizations.smartAnchorCountryPickerFootnote}',
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

double? _anchorPurity(SmartAnchorInput input, String serviceId) {
  final anchor = input.anchors[serviceId];
  if (anchor == null) {
    return null;
  }
  return input.metadataByProxy[anchor.lastProxyName]?.purityScore;
}

String _trustTierLabel(
  AppLocalizations appLocalizations,
  SmartAnchorInput input,
  String serviceId,
) {
  final purity = _anchorPurity(input, serviceId);
  if (purity == null) {
    return appLocalizations.smartAnchorUnknown;
  }
  return switch (ScoringEngine.trustTier(purity)) {
    'safe' => appLocalizations.smartAnchorTrustSafe,
    'watch' => appLocalizations.smartAnchorTrustWatch,
    _ => appLocalizations.smartAnchorTrustRisky,
  };
}

class _ProbeNowRow extends ConsumerStatefulWidget {
  const _ProbeNowRow({required this.groups});

  final List<Group> groups;

  @override
  ConsumerState<_ProbeNowRow> createState() => _ProbeNowRowState();
}

class _ProbeNowRowState extends ConsumerState<_ProbeNowRow> {
  var _probing = false;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return DecorationListItem(
      title: Text(appLocalizations.smartAnchorProbeNow),
      subtitle: _probing ? Text(appLocalizations.smartAnchorProbing) : null,
      trailing: _probing ? const CommonCircleLoading(size: 20) : null,
      onPressed: _probing
          ? null
          : () async {
              setState(() {
                _probing = true;
              });
              try {
                final groupNames = {
                  for (final group in widget.groups) group.name,
                };
                final names = <String>{};
                var current = '';
                for (final group in widget.groups) {
                  if (group.name.startsWith('🎯 Smart-') && group.now != null) {
                    current = group.now!;
                  }
                  for (final proxy in group.all) {
                    if (!groupNames.contains(proxy.name)) {
                      names.add(proxy.name);
                    }
                  }
                }
                final updated = await ref
                    .read(smartAnchorProvider.notifier)
                    .probeNodes(
                      proxyNames: names.toList(),
                      currentProxyName: current,
                      force: true,
                    );
                if (context.mounted) {
                  dialogs.showNotifier(
                    appLocalizations.smartAnchorProbeDone(updated),
                  );
                }
              } finally {
                if (mounted) {
                  setState(() {
                    _probing = false;
                  });
                }
              }
            },
    );
  }
}
