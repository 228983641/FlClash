import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _regionCountryNames = {
  'US': '美国',
  'SG': '新加坡',
  'JP': '日本',
  'HK': '香港',
  'KR': '韩国',
  'TW': '台湾',
  'DE': '德国',
  'GB': '英国',
  'NL': '荷兰',
};

String _regionDisplayName(String code) {
  final name = _regionCountryNames[code];
  return name == null ? code : '$name ($code)';
}

class SmartAnchorRegionView extends ConsumerStatefulWidget {
  const SmartAnchorRegionView({super.key, required this.serviceId});

  final String serviceId;

  @override
  ConsumerState<SmartAnchorRegionView> createState() =>
      _SmartAnchorRegionViewState();
}

class _SmartAnchorRegionViewState extends ConsumerState<SmartAnchorRegionView> {
  late String _mode;
  late Set<String> _checked;

  ServiceToggleConfig? _service(SmartAnchorInput input) {
    final services = effectiveSmartServices(input);
    for (final service in services) {
      if (service.serviceId == widget.serviceId) {
        return service;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final input = ref.read(smartAnchorProvider);
    final service = _service(input);
    _mode = service?.effectiveRegionMode ?? 'blacklist';
    final stored = {
      for (final country in service?.regionCountries ?? const <String>[])
        country.trim().toUpperCase(),
    }..remove('');
    _checked = stored.isNotEmpty
        ? stored
        : _mode == 'blacklist'
        ? detectedUnsupportedRegions(input, widget.serviceId)
        : <String>{};
  }

  void _apply() {
    final service = _service(ref.read(smartAnchorProvider));
    if (service == null) {
      return;
    }
    final countries = _checked.toList()..sort();
    ref
        .read(smartAnchorProvider.notifier)
        .upsertService(
          service.copyWith(regionMode: _mode, regionCountries: countries),
        );
    ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
  }

  void _reset() {
    final input = ref.read(smartAnchorProvider);
    setState(() {
      _mode = 'blacklist';
      _checked = detectedUnsupportedRegions(input, widget.serviceId);
    });
    final service = _service(input);
    if (service == null) {
      return;
    }
    ref
        .read(smartAnchorProvider.notifier)
        .upsertService(
          service.copyWith(regionMode: 'blacklist', regionCountries: const []),
        );
    ref.read(setupActionProvider.notifier).applyProfileDebounce(silence: true);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final service = _service(input);
    if (service == null) {
      return CommonScaffold(
        title: appLocalizations.smartAnchorRegionFilter,
        body: const SizedBox.shrink(),
      );
    }
    final detected = detectedUnsupportedRegions(input, widget.serviceId);
    final candidates = <String>{};
    for (final metadata in input.metadataByProxy.values) {
      if (metadata.countryCode.isNotEmpty) {
        candidates.add(metadata.countryCode);
      }
    }
    candidates.addAll(detected);
    candidates.addAll(service.lockedCountries);
    candidates.addAll(_checked);
    final ordered = candidates.toList()
      ..sort((a, b) {
        final aBad = detected.contains(a) ? 0 : 1;
        final bBad = detected.contains(b) ? 0 : 1;
        if (aBad != bBad) {
          return aBad - bBad;
        }
        return a.compareTo(b);
      });
    return CommonScaffold(
      title: appLocalizations.smartAnchorRegionFilter,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: service.displayName,
            items: [
              ListItem<String>.options(
                title: Text(appLocalizations.smartAnchorRegionFilter),
                options: const ['blacklist', 'whitelist'],
                textBuilder: (mode) => mode == 'whitelist'
                    ? appLocalizations.smartAnchorRegionWhitelist
                    : appLocalizations.smartAnchorRegionBlacklist,
                value: _mode,
                onChanged: (mode) {
                  setState(() {
                    _mode = mode;
                    _checked = mode == 'blacklist'
                        ? detectedUnsupportedRegions(input, widget.serviceId)
                        : <String>{};
                  });
                  _apply();
                },
              ),
            ],
            footer: _mode == 'whitelist'
                ? appLocalizations.smartAnchorRegionWhitelistDesc
                : appLocalizations.smartAnchorRegionBlacklistDesc,
          ),
          const SizedBox(height: 16),
          generateSection(
            title: appLocalizations.smartAnchorRegionFilter,
            items: [
              if (ordered.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Text(
                    appLocalizations.smartAnchorRegionEmpty,
                    style: AppTextStyle.footnote.of(context),
                  ),
                ),
              for (final code in ordered)
                CheckboxListTile(
                  title: Text(_regionDisplayName(code)),
                  subtitle: detected.contains(code)
                      ? Text(appLocalizations.smartAnchorRegionUnsupported)
                      : null,
                  value: _checked.contains(code),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      if (value) {
                        _checked.add(code);
                      } else {
                        _checked.remove(code);
                      }
                    });
                    _apply();
                  },
                ),
            ],
            footer: appLocalizations.smartAnchorRegionFootnote,
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _reset,
            child: Text(appLocalizations.smartAnchorRegionReset),
          ),
        ],
      ),
    );
  }
}
