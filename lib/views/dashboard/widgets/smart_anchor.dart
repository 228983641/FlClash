import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:fl_clash/smart_anchor/models/service_group.dart';
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

String _hhmm(int ms) {
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}

class _RawMemberPath {
  const _RawMemberPath({
    required this.color,
    required this.points,
    required this.anchor,
  });

  final Color color;
  final List<AnchorPathPoint> points;
  final ({double lat, double lon})? anchor;
}

class _PathPainter extends CustomPainter {
  const _PathPainter({
    required this.members,
    required this.gridColor,
    required this.anchorColor,
  });

  final List<_RawMemberPath> members;
  final Color gridColor;
  final Color anchorColor;

  @override
  void paint(Canvas canvas, Size size) {
    final lats = <double>[];
    final lons = <double>[];
    for (final member in members) {
      for (final point in member.points) {
        lats.add(point.latitude);
        lons.add(point.longitude);
      }
      if (member.anchor != null) {
        lats.add(member.anchor!.lat);
        lons.add(member.anchor!.lon);
      }
    }
    if (lats.isEmpty) {
      return;
    }
    var minLat = lats.reduce(math.min);
    var maxLat = lats.reduce(math.max);
    var minLon = lons.reduce(math.min);
    var maxLon = lons.reduce(math.max);
    if (maxLat - minLat < 10) {
      final mid = (minLat + maxLat) / 2;
      minLat = mid - 5;
      maxLat = mid + 5;
    }
    if (maxLon - minLon < 10) {
      final mid = (minLon + maxLon) / 2;
      minLon = mid - 5;
      maxLon = mid + 5;
    }
    minLat -= 2;
    maxLat += 2;
    minLon -= 2;
    maxLon += 2;
    Offset project(double lat, double lon) {
      return Offset(
        (lon - minLon) / (maxLon - minLon) * size.width,
        size.height - (lat - minLat) / (maxLat - minLat) * size.height,
      );
    }

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var i = 1; i < 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = gridColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (final member in members) {
      if (member.points.length > 1) {
        final path = Path();
        for (var i = 0; i < member.points.length; i++) {
          final offset = project(
            member.points[i].latitude,
            member.points[i].longitude,
          );
          if (i == 0) {
            path.moveTo(offset.dx, offset.dy);
          } else {
            path.lineTo(offset.dx, offset.dy);
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = member.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round,
        );
      }
      for (var i = 0; i < member.points.length; i++) {
        final point = member.points[i];
        final offset = project(point.latitude, point.longitude);
        final isLast = i == member.points.length - 1;
        canvas.drawCircle(
          offset,
          isLast ? 6 : 3.5,
          Paint()..color = member.color,
        );
        if (isLast) {
          canvas.drawCircle(
            offset,
            9,
            Paint()
              ..color = member.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
      }
      if (member.anchor != null) {
        final offset = project(member.anchor!.lat, member.anchor!.lon);
        final diamond = Path()
          ..moveTo(offset.dx, offset.dy - 7)
          ..lineTo(offset.dx + 7, offset.dy)
          ..lineTo(offset.dx, offset.dy + 7)
          ..lineTo(offset.dx - 7, offset.dy)
          ..close();
        canvas.drawPath(diamond, Paint()..color = anchorColor);
      }
    }
  }

  @override
  bool shouldRepaint(_PathPainter oldDelegate) {
    return oldDelegate.members != members;
  }
}

class SmartAnchorPathCard extends ConsumerStatefulWidget {
  const SmartAnchorPathCard({super.key});

  @override
  ConsumerState<SmartAnchorPathCard> createState() =>
      _SmartAnchorPathCardState();
}

class _SmartAnchorPathCardState extends ConsumerState<SmartAnchorPathCard> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final input = ref.watch(smartAnchorProvider);
    final groups = ref.watch(groupsProvider);
    final services = effectiveSmartServices(input);
    final serviceById = {
      for (final service in services) service.serviceId: service,
    };
    final entries = <({String id, String label, List<String> members})>[
      for (final group in defaultServiceGroups)
        (id: group.id, label: group.displayName, members: group.serviceIds),
      for (final service in services)
        if (groupForService(service.serviceId) == null)
          (
            id: 'custom:${service.serviceId}',
            label: service.displayName,
            members: [service.serviceId],
          ),
    ];
    final selected =
        entries.where((entry) => entry.id == _selectedId).firstOrNull ??
        entries.firstOrNull;
    final palette = [
      context.colorScheme.primary,
      context.colorScheme.tertiary,
      context.colorScheme.error,
      context.colorScheme.secondary,
    ];
    final members = <_RawMemberPath>[];
    if (selected != null) {
      for (var i = 0; i < selected.members.length; i++) {
        final memberId = selected.members[i];
        final anchor = input.anchors[memberId];
        members.add(
          _RawMemberPath(
            color: palette[i % palette.length],
            points: input.paths[memberId] ?? const [],
            anchor:
                anchor == null ||
                    (anchor.latitude == 0 && anchor.longitude == 0)
                ? null
                : (lat: anchor.latitude, lon: anchor.longitude),
          ),
        );
      }
    }
    final hasPoints = members.any((member) => member.points.isNotEmpty);
    final recent = [
      for (final member in members)
        for (final point in member.points) point,
    ]..sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
    String? backToAnchorGroup;
    String? backToAnchorProxy;
    if (selected != null) {
      for (final memberId in selected.members) {
        final anchor = input.anchors[memberId];
        if (anchor == null) {
          continue;
        }
        final group = groups.getGroup('🎯 Smart-${memberId.toUpperCase()}');
        if (group == null) {
          continue;
        }
        if (group.all.any((proxy) => proxy.name == anchor.lastProxyName)) {
          backToAnchorGroup = group.name;
          backToAnchorProxy = anchor.lastProxyName;
          break;
        }
      }
    }
    return DashboardCard(
      semanticLabel: appLocalizations.smartAnchorPath,
      onTap: () => _showSmartAnchorSettings(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.pin,
            title: appLocalizations.smartAnchorPath,
            chevron: true,
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(entry.label),
                      selected: selected?.id == entry.id,
                      onSelected: (_) {
                        setState(() {
                          _selectedId = entry.id;
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (!hasPoints)
            Text(
              appLocalizations.smartAnchorPathEmpty,
              style: AppTextStyle.footnote.of(context),
            )
          else ...[
            SizedBox(
              height: 170,
              width: double.infinity,
              child: CustomPaint(
                painter: _PathPainter(
                  members: members,
                  gridColor: context.colorScheme.outlineVariant,
                  anchorColor: context.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < (selected?.members.length ?? 0); i++) ...[
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: palette[i % palette.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      serviceById[selected!.members[i]]?.displayName ??
                          selected.members[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.footnote.of(context),
                    ),
                  ),
                  Text(
                    members[i].points.isEmpty
                        ? '—'
                        : '${members[i].points.last.placeLabel} '
                              '${_hhmm(members[i].points.last.recordedAt)}',
                    style: AppTextStyle.footnote.of(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            for (final point in recent.take(5))
              Text(
                '${_hhmm(point.recordedAt)} ${point.placeLabel} '
                '${point.proxyName} · ${switch (point.note) {
                  'auto' => appLocalizations.smartAnchorPathAuto,
                  'manual' => appLocalizations.smartAnchorPathManual,
                  _ => appLocalizations.smartAnchorPathStart,
                }}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.footnote.of(context),
              ),
          ],
          if (backToAnchorGroup != null || selected != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (backToAnchorGroup != null)
                  FilledButton.tonal(
                    onPressed: () {
                      ref
                          .read(proxiesActionProvider.notifier)
                          .changeProxyDebounce(
                            backToAnchorGroup!,
                            backToAnchorProxy!,
                          );
                    },
                    child: Text(appLocalizations.smartAnchorBackToAnchor),
                  ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    if (selected == null) {
                      return;
                    }
                    for (final memberId in selected.members) {
                      ref
                          .read(smartAnchorProvider.notifier)
                          .clearPath(memberId);
                    }
                  },
                  child: Text(appLocalizations.smartAnchorPathClear),
                ),
              ],
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
