import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fl_clash/common/common.dart';
import 'package:flutter/rendering.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_group.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
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
    required this.anchorPlace,
  });

  final Color color;
  final List<AnchorPathPoint> points;
  final ({double lat, double lon})? anchor;
  final String? anchorPlace;
}

class _PathPainter extends CustomPainter {
  const _PathPainter({
    required this.members,
    required this.gridColor,
    required this.anchorColor,
    required this.bracketColor,
    required this.backgroundColor,
    required this.anchorTitle,
    required this.labelStyle,
    required this.labelStyleBold,
  });

  final List<_RawMemberPath> members;
  final Color gridColor;
  final Color anchorColor;
  final Color bracketColor;
  final Color backgroundColor;
  final String anchorTitle;
  final TextStyle labelStyle;
  final TextStyle labelStyleBold;

  double _niceStep(double span) {
    const steps = [5.0, 10.0, 15.0, 30.0, 45.0, 60.0, 90.0];
    for (final step in steps) {
      if (span / 4 <= step) {
        return step;
      }
    }
    return 90.0;
  }

  String _lonLabel(double lon) {
    final value = lon.abs();
    final text = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    return lon < 0 ? '$text°W' : '$text°E';
  }

  String _latLabel(double lat) {
    final value = lat.abs();
    final text = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    return lat < 0 ? '$text°S' : '$text°N';
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset offset, {
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: bold ? labelStyleBold : labelStyle,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.drawRect(
      offset & painter.size,
      Paint()..color = backgroundColor.withValues(alpha: 0.7),
    );
    painter.paint(canvas, offset);
  }

  void _drawDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    final total = (to - from).distance;
    if (total == 0) {
      return;
    }
    var drawn = 0.0;
    while (drawn < total) {
      final start = from + (to - from) * (drawn / total);
      final endLength = math.min(drawn + dash, total);
      final end = from + (to - from) * (endLength / total);
      canvas.drawLine(start, end, paint);
      drawn += dash + gap;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
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
    final lonStep = _niceStep(maxLon - minLon);
    var lon = (minLon / lonStep).ceil() * lonStep;
    while (lon <= maxLon) {
      final x = project(minLat, lon).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      _drawLabel(canvas, _lonLabel(lon), Offset(x + 2, size.height - 12));
      lon += lonStep;
    }
    final latStep = _niceStep(maxLat - minLat);
    var lat = (minLat / latStep).ceil() * latStep;
    while (lat <= maxLat) {
      final y = project(lat, minLon).dy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      _drawLabel(canvas, _latLabel(lat), Offset(2, y + 2));
      lat += latStep;
    }
    final bracketPaint = Paint()
      ..color = bracketColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const bracketLen = 14.0;
    const inset = 5.0;
    final corners = [
      (const Offset(inset, inset), const Offset(1, 1)),
      (Offset(size.width - inset, inset), const Offset(-1, 1)),
      (Offset(inset, size.height - inset), const Offset(1, -1)),
      (Offset(size.width - inset, size.height - inset), const Offset(-1, -1)),
    ];
    for (final (origin, direction) in corners) {
      final path = Path()
        ..moveTo(origin.dx + direction.dx * bracketLen, origin.dy)
        ..lineTo(origin.dx, origin.dy)
        ..lineTo(origin.dx, origin.dy + direction.dy * bracketLen);
      canvas.drawPath(path, bracketPaint);
    }
    final compassX = size.width - 20;
    const compassY = 20.0;
    canvas.drawPath(
      Path()
        ..moveTo(compassX, compassY - 7)
        ..lineTo(compassX - 5, compassY + 5)
        ..lineTo(compassX + 5, compassY + 5)
        ..close(),
      Paint()..color = bracketColor,
    );
    _drawLabel(canvas, 'N', Offset(compassX - 3, compassY + 7), bold: true);
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
      if (member.anchor != null && member.points.isNotEmpty) {
        final anchorOffset = project(member.anchor!.lat, member.anchor!.lon);
        final last = member.points.last;
        final lastOffset = project(last.latitude, last.longitude);
        _drawDashedLine(
          canvas,
          anchorOffset,
          lastOffset,
          Paint()
            ..color = anchorColor.withValues(alpha: 0.55)
            ..strokeWidth = 1.5,
        );
      }
      for (var i = 0; i < member.points.length; i++) {
        final point = member.points[i];
        final offset = project(point.latitude, point.longitude);
        final isLast = i == member.points.length - 1;
        if (isLast) {
          canvas.drawCircle(
            offset,
            13,
            Paint()..color = member.color.withValues(alpha: 0.18),
          );
        }
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
          canvas.drawCircle(offset, 2, Paint()..color = backgroundColor);
          final labelX = offset.dx > size.width - 70
              ? offset.dx - 62
              : offset.dx + 10;
          _drawLabel(
            canvas,
            point.placeLabel,
            Offset(labelX, offset.dy - 16),
            bold: true,
          );
        }
      }
      if (member.anchor != null) {
        final offset = project(member.anchor!.lat, member.anchor!.lon);
        canvas.drawCircle(
          offset,
          15,
          Paint()..color = anchorColor.withValues(alpha: 0.18),
        );
        final diamond = Path()
          ..moveTo(offset.dx, offset.dy - 8)
          ..lineTo(offset.dx + 8, offset.dy)
          ..lineTo(offset.dx, offset.dy + 8)
          ..lineTo(offset.dx - 8, offset.dy)
          ..close();
        canvas.drawPath(diamond, Paint()..color = anchorColor);
        canvas.drawCircle(offset, 2.5, Paint()..color = backgroundColor);
        final label = member.anchorPlace == null
            ? anchorTitle
            : '$anchorTitle · ${member.anchorPlace}';
        final labelX = offset.dx > size.width - 90
            ? offset.dx - 84
            : offset.dx + 10;
        _drawLabel(canvas, label, Offset(labelX, offset.dy - 16), bold: true);
      }
    }
  }

  @override
  bool shouldRepaint(_PathPainter oldDelegate) => true;
}

class SmartAnchorPathCard extends ConsumerStatefulWidget {
  const SmartAnchorPathCard({super.key});

  @override
  ConsumerState<SmartAnchorPathCard> createState() =>
      _SmartAnchorPathCardState();
}

String _formatKm(double km) {
  if (km >= 100) {
    return '${km.round()} km';
  }
  return '${km.toStringAsFixed(1)} km';
}

class _SmartAnchorPathCardState extends ConsumerState<SmartAnchorPathCard> {
  String? _selectedId;
  final _diagramKey = GlobalKey();

  Future<void> _exportDiagram() async {
    final boundary =
        _diagramKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return;
    }
    final image = await boundary.toImage(pixelRatio: 3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final png = bytes?.buffer.asUint8List();
    if (png == null) {
      return;
    }
    await Picker().saveFile('smart-anchor-path.png', png);
  }

  void _setAnchor(String serviceId, NodeMetadataCache meta, String proxyName) {
    ref
        .read(smartAnchorProvider.notifier)
        .setAnchor(
          serviceId,
          ServiceAnchor(
            serviceTag: serviceId,
            countryCode: meta.countryCode,
            lastProxyName: proxyName,
            egressIp: meta.egressIp,
            subnet24: meta.egressIp.contains('.')
                ? meta.egressIp.split('.').take(3).join('.')
                : '',
            asn: meta.asn,
            isp: '',
            latitude: meta.latitude,
            longitude: meta.longitude,
            city: '',
            confirmedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

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
            anchorPlace: anchor == null
                ? null
                : anchor.city.isEmpty
                ? anchor.countryCode
                : anchor.city,
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
    String? setAnchorServiceId;
    NodeMetadataCache? setAnchorMeta;
    String? setAnchorProxy;
    if (selected != null) {
      for (final memberId in selected.members) {
        final group = groups.getGroup('🎯 Smart-${memberId.toUpperCase()}');
        final current = group?.now;
        final meta = current == null ? null : input.metadataByProxy[current];
        if (current != null && meta != null) {
          setAnchorServiceId = memberId;
          setAnchorMeta = meta;
          setAnchorProxy = current;
          break;
        }
      }
    }
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
            RepaintBoundary(
              key: _diagramKey,
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: CustomPaint(
                  painter: _PathPainter(
                    members: members,
                    gridColor: context.colorScheme.outlineVariant,
                    anchorColor: context.colorScheme.tertiary,
                    bracketColor: context.colorScheme.primary,
                    backgroundColor: context.colorScheme.surfaceContainerLow,
                    anchorTitle: appLocalizations.smartAnchorPathAnchor,
                    labelStyle: AppTextStyle.footnote.of(context).copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                    labelStyleBold: AppTextStyle.footnote
                        .of(context, emphasized: true)
                        .copyWith(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                  ),
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
                              '${_hhmm(members[i].points.last.recordedAt)}'
                              '${members[i].anchor == null ? '' : ' · ${appLocalizations.smartAnchorPathFromAnchor} ${_formatKm(ScoringEngine.haversineKm(members[i].anchor!.lat, members[i].anchor!.lon, members[i].points.last.latitude, members[i].points.last.longitude))}'}',
                    style: AppTextStyle.footnote.of(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
            for (final point in recent.take(5))
              Builder(
                builder: (context) {
                  String noteLabel;
                  if (point.note.startsWith('auto:')) {
                    final reason = point.note.substring(5);
                    final reasonLabel = reason == 'regionBlocked'
                        ? appLocalizations.smartAnchorReasonRegionBlocked
                        : reason == 'networkFailed'
                        ? appLocalizations.smartAnchorReasonNetworkFailed
                        : '';
                    noteLabel = reasonLabel.isEmpty
                        ? appLocalizations.smartAnchorPathAuto
                        : '${appLocalizations.smartAnchorPathAuto}（$reasonLabel）';
                  } else if (point.note == 'manual') {
                    noteLabel = appLocalizations.smartAnchorPathManual;
                  } else {
                    noteLabel = appLocalizations.smartAnchorPathStart;
                  }
                  String moveLabel = '';
                  for (final member in members) {
                    final index = member.points.indexOf(point);
                    if (index < 0) {
                      continue;
                    }
                    if (index > 0) {
                      final prev = member.points[index - 1];
                      moveLabel =
                          ' · +${_formatKm(ScoringEngine.haversineKm(prev.latitude, prev.longitude, point.latitude, point.longitude))}';
                    } else if (member.anchor != null) {
                      moveLabel =
                          ' · +${_formatKm(ScoringEngine.haversineKm(member.anchor!.lat, member.anchor!.lon, point.latitude, point.longitude))}';
                    }
                    break;
                  }
                  final meta = input.metadataByProxy[point.proxyName];
                  return InkWell(
                    onTap: meta == null
                        ? null
                        : () => _setAnchor(
                            point.serviceId,
                            meta,
                            point.proxyName,
                          ),
                    child: Text(
                      '${_hhmm(point.recordedAt)} ${point.placeLabel} '
                      '${point.proxyName} · $noteLabel$moveLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.footnote.of(context),
                    ),
                  );
                },
              ),
            Text(
              appLocalizations.smartAnchorPathTapHint,
              style: AppTextStyle.footnote.of(context),
            ),
          ],
          if (selected != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
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
                if (setAnchorServiceId != null)
                  FilledButton.tonal(
                    onPressed: () => _setAnchor(
                      setAnchorServiceId!,
                      setAnchorMeta!,
                      setAnchorProxy!,
                    ),
                    child: Text(appLocalizations.smartAnchorSetAnchor),
                  ),
                FilledButton.tonal(
                  onPressed: _exportDiagram,
                  child: Text(appLocalizations.smartAnchorPathExport),
                ),
                TextButton(
                  onPressed: () {
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
