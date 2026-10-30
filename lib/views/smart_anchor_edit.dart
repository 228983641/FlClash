import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/views/smart_anchor_region.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SmartAnchorServiceEditView extends ConsumerStatefulWidget {
  const SmartAnchorServiceEditView({super.key, this.service});

  final ServiceToggleConfig? service;

  @override
  ConsumerState<SmartAnchorServiceEditView> createState() =>
      _SmartAnchorServiceEditViewState();
}

class _SmartAnchorServiceEditViewState
    extends ConsumerState<SmartAnchorServiceEditView> {
  late final TextEditingController _nameController;
  late final TextEditingController _rulesController;
  late final TextEditingController _dnsController;
  late final TextEditingController _lockController;
  late ServiceRestrictionMode _restrictionMode;

  @override
  void initState() {
    super.initState();
    final service = widget.service;
    _restrictionMode =
        service?.restrictionMode ??
        defaultServiceRestrictionMode(service?.lockedCountries ?? const []);
    _nameController = TextEditingController(text: service?.displayName ?? '');
    _rulesController = TextEditingController(
      text: (service?.matchRules ?? []).join('\n'),
    );
    _dnsController = TextEditingController(
      text: (service?.dnsDomains ?? []).join('\n'),
    );
    _lockController = TextEditingController(
      text: (service?.lockedCountries ?? []).join(','),
    );
    _nameController.addListener(_refresh);
    _rulesController.addListener(_refresh);
    _lockController.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _rulesController.dispose();
    _dnsController.dispose();
    _lockController.dispose();
    super.dispose();
  }

  List<String> _lines(TextEditingController controller) {
    return [
      for (final line in controller.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  List<String> _countries() {
    return [
      for (final part in _lockController.text.split(','))
        if (part.trim().isNotEmpty) part.trim().toUpperCase(),
    ];
  }

  bool _countryValid(String code) {
    return RegExp(r'^[A-Z]{2}$').hasMatch(code);
  }

  bool get _countriesValid {
    return _countries().every(_countryValid);
  }

  bool get _rulesValid {
    return _lines(_rulesController).every(isValidMatchRule);
  }

  bool get _isPreset {
    final service = widget.service;
    if (service == null) {
      return false;
    }
    return defaultServiceToggles.any(
      (preset) => preset.serviceId == service.serviceId,
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    final rules = _lines(_rulesController);
    if (name.isEmpty || rules.isEmpty || !_countriesValid || !_rulesValid) {
      return;
    }
    final countries = _countries();
    final existing = widget.service;
    final lockChanged =
        existing != null &&
        (existing.lockedCountries.length != countries.length ||
            !countries.every(existing.lockedCountries.contains));
    final serviceId =
        existing?.serviceId ??
        'custom_${DateTime.now().millisecondsSinceEpoch}';
    ref
        .read(smartAnchorProvider.notifier)
        .upsertService(
          ServiceToggleConfig(
            serviceId: serviceId,
            displayName: name,
            isEnabled: existing?.isEnabled ?? false,
            targetCountry: countries.isEmpty ? '' : countries.first,
            targetCountries: countries,
            matchRules: rules,
            dnsDomains: _lines(_dnsController),
            officialName: existing?.officialName ?? '',
            regionMode: existing?.regionMode ?? 'blacklist',
            regionCountries: existing?.regionCountries ?? const [],
            restrictionMode: _restrictionMode,
          ),
        );
    if (lockChanged) {
      ref.read(smartAnchorProvider.notifier).clearAnchor(serviceId);
    }
    ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
    Navigator.of(context).pop(existing == null);
  }

  String _regionSummary(
    ServiceToggleConfig current,
    AppLocalizations appLocalizations,
  ) {
    final stored = current.regionCountries;
    if (stored.isNotEmpty) {
      return current.effectiveRegionMode == 'whitelist'
          ? appLocalizations.smartAnchorRegionCountWhitelist(stored.length)
          : appLocalizations.smartAnchorRegionCountBlacklist(stored.length);
    }
    return current.effectiveRegionMode == 'whitelist'
        ? appLocalizations.smartAnchorRegionWhitelist
        : appLocalizations.smartAnchorRegionAuto;
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final service = widget.service;
    return CommonScaffold(
      title: service == null
          ? '${appLocalizations.add} ${appLocalizations.smartAnchorServices}'
          : '${appLocalizations.edit} ${service.displayName}',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: appLocalizations.smartAnchorServices,
            items: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                  controller: _nameController,
                  decoration: InputDecoration(labelText: appLocalizations.name),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                  controller: _rulesController,
                  maxLines: 6,
                  decoration: InputDecoration(
                    labelText: appLocalizations.rules,
                    helperText: 'GEOSITE,openai',
                    errorText: _rulesValid
                        ? null
                        : appLocalizations.smartAnchorInvalidRule,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                  controller: _dnsController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: appLocalizations.domain,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                  controller: _lockController,
                  decoration: InputDecoration(
                    labelText: appLocalizations.countryLock,
                    helperText: 'US,JP',
                    errorText: _countriesValid
                        ? null
                        : appLocalizations.smartAnchorInvalidCountryCode,
                  ),
                ),
              ),
              DecorationListItem(
                title: Text(appLocalizations.smartAnchorStrictMode),
                subtitle: Text(appLocalizations.smartAnchorStrictModeDesc),
                trailing: CommonSwitch(
                  value: _restrictionMode == ServiceRestrictionMode.strict,
                  onChanged: (value) {
                    setState(() {
                      _restrictionMode = value
                          ? ServiceRestrictionMode.strict
                          : defaultServiceRestrictionMode(_countries());
                    });
                  },
                ),
              ),
            ],
          ),
          if (service != null) ...[
            const SizedBox(height: 16),
            generateSection(
              title: appLocalizations.smartAnchorRegionFilter,
              items: [
                DecorationListItem(
                  title: Text(appLocalizations.smartAnchorRegionFilter),
                  subtitle: Text(
                    _regionSummary(
                      effectiveSmartServices(
                        ref.watch(smartAnchorProvider),
                      ).firstWhere(
                        (candidate) => candidate.serviceId == service.serviceId,
                        orElse: () => service,
                      ),
                      appLocalizations,
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            SmartAnchorRegionView(serviceId: service.serviceId),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed:
                _nameController.text.trim().isEmpty ||
                    _lines(_rulesController).isEmpty ||
                    !_countriesValid ||
                    !_rulesValid
                ? null
                : _save,
            child: Text(appLocalizations.save),
          ),
          if (service != null && !_isPreset) ...[
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: context.colorScheme.error,
                foregroundColor: context.colorScheme.onError,
              ),
              onPressed: () async {
                final confirmed = await dialogs.showMessage(
                  title: appLocalizations.delete,
                  message: TextSpan(
                    text: appLocalizations.smartAnchorDeleteConfirm,
                  ),
                  destructive: true,
                );
                if (confirmed != true) {
                  return;
                }
                if (!context.mounted) {
                  return;
                }
                ref
                    .read(smartAnchorProvider.notifier)
                    .deleteService(service.serviceId);
                ref
                    .read(setupActionProvider.notifier)
                    .applyProfileDebounce(silence: true);
                Navigator.of(context).pop();
              },
              child: Text(appLocalizations.delete),
            ),
          ],
        ],
      ),
    );
  }
}
