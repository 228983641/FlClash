import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
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

  @override
  void initState() {
    super.initState();
    final service = widget.service;
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
    if (name.isEmpty || rules.isEmpty) {
      return;
    }
    final countries = _countries();
    final existing = widget.service;
    ref
        .read(smartAnchorProvider.notifier)
        .upsertService(
          ServiceToggleConfig(
            serviceId:
                existing?.serviceId ??
                'custom_${DateTime.now().millisecondsSinceEpoch}',
            displayName: name,
            isEnabled: existing?.isEnabled ?? false,
            targetCountry: countries.isEmpty ? '' : countries.first,
            targetCountries: countries,
            matchRules: rules,
            dnsDomains: _lines(_dnsController),
          ),
        );
    ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
    Navigator.of(context).pop();
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
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed:
                _nameController.text.trim().isEmpty ||
                    _lines(_rulesController).isEmpty
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
              onPressed: () {
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
