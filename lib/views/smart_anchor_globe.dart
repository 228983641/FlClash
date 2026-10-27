import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/smart_anchor/models/anchor_path.dart';
import 'package:fl_clash/smart_anchor/services/globe_projection.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

class GlobeTrack {
  const GlobeTrack({
    required this.label,
    required this.color,
    required this.points,
    this.anchorLat,
    this.anchorLon,
    this.anchorPlace,
  });

  final String label;
  final Color color;
  final List<AnchorPathPoint> points;
  final double? anchorLat;
  final double? anchorLon;
  final String? anchorPlace;
}

Future<List<List<GlobeVector>>> _loadLandRings() async {
  try {
    final raw = await rootBundle.loadString('assets/data/globe_land.json');
    final decoded = json.decode(raw) as Map<String, dynamic>;
    final rings = decoded['rings'] as List;
    return [
      for (final ring in rings)
        [
          for (final point in ring as List)
            GlobeVector.fromLatLon(
              (point[1] as num).toDouble(),
              (point[0] as num).toDouble(),
            ),
        ],
    ];
  } catch (_) {
    return const [];
  }
}

class SmartAnchorGlobeView extends StatefulWidget {
  const SmartAnchorGlobeView({
    super.key,
    required this.title,
    required this.tracks,
  });

  final String title;
  final List<GlobeTrack> tracks;

  @override
  State<SmartAnchorGlobeView> createState() => _SmartAnchorGlobeViewState();
}

class _SmartAnchorGlobeViewState extends State<SmartAnchorGlobeView> {
  late Future<List<List<GlobeVector>>> _rings;
  late double _centerLon;
  late double _centerLat;

  @override
  void initState() {
    super.initState();
    _rings = _loadLandRings();
    var lon = 0.0;
    var lat = 20.0;
    for (final track in widget.tracks) {
      if (track.anchorLat != null && track.anchorLon != null) {
        lon = track.anchorLon!;
        lat = track.anchorLat!;
        break;
      }
      if (track.points.isNotEmpty) {
        lon = track.points.last.longitude;
        lat = track.points.last.latitude;
        break;
      }
    }
    _centerLon = lon;
    _centerLat = lat.clamp(-70, 70);
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    return CommonScaffold(
      title: widget.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: FutureBuilder<List<List<GlobeVector>>>(
              future: _rings,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CommonCircleLoading());
                }
                return GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      _centerLon =
                          (_centerLon - details.delta.dx * 0.3 + 540) % 360 -
                          180;
                      _centerLat = (_centerLat + details.delta.dy * 0.3).clamp(
                        -70,
                        70,
                      );
                    });
                  },
                  child: CustomPaint(
                    painter: _GlobePainter(
                      rings: snapshot.data!,
                      tracks: widget.tracks,
                      centerLon: _centerLon,
                      centerLat: _centerLat,
                      labelStyle: AppTextStyle.footnote
                          .of(context)
                          .copyWith(color: Colors.white),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final track in widget.tracks)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: track.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        track.label,
                        style: AppTextStyle.footnote.of(context),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: 16 + context.bottomInset,
            ),
            child: Text(
              appLocalizations.smartAnchorGlobeHint,
              style: AppTextStyle.footnote.of(context),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlobePainter extends CustomPainter {
  const _GlobePainter({
    required this.rings,
    required this.tracks,
    required this.centerLon,
    required this.centerLat,
    required this.labelStyle,
  });

  final List<List<GlobeVector>> rings;
  final List<GlobeTrack> tracks;
  final double centerLon;
  final double centerLat;
  final TextStyle labelStyle;

  static const _oceanInner = Color(0xFF1D4E79);
  static const _oceanOuter = Color(0xFF0A1E33);
  static const _land = Color(0xFF5E8C6A);
  static const _graticule = Color(0x26FFFFFF);
  static const _limb = Color(0x33FFFFFF);

  Offset _toOffset((double, double) disc, Offset center, double radius) {
    return Offset(center.dx + disc.$1 * radius, center.dy + disc.$2 * radius);
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset at,
    TextDirection direction,
  ) {
    if (text.isEmpty) {
      return;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: direction,
    )..layout();
    painter.paint(
      canvas,
      Offset(at.dx - painter.width / 2, at.dy - painter.height - 8),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    if (radius <= 0) {
      return;
    }
    final projection = GlobeProjection(
      centerLon: centerLon,
      centerLat: centerLat,
    );
    final ocean = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.35, -0.35),
        radius: 1.15,
        colors: [_oceanInner, _oceanOuter],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, ocean);
    final graticulePaint = Paint()
      ..color = _graticule
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    void drawRuns(Paint paint, List<List<(double, double)>> runs) {
      for (final run in runs) {
        if (run.length < 2) {
          continue;
        }
        final path = Path()
          ..moveTo(
            center.dx + run.first.$1 * radius,
            center.dy + run.first.$2 * radius,
          );
        for (final point in run.skip(1)) {
          path.lineTo(
            center.dx + point.$1 * radius,
            center.dy + point.$2 * radius,
          );
        }
        canvas.drawPath(path, paint);
      }
    }

    for (final lat in [-60.0, -30.0, 0.0, 30.0, 60.0]) {
      final samples = <(double, double)?>[];
      for (var lon = -180.0; lon <= 180.0; lon += 6) {
        samples.add(projection.project(lat, lon));
      }
      final runs = <List<(double, double)>>[];
      var run = <(double, double)>[];
      for (final sample in samples) {
        if (sample == null) {
          if (run.isNotEmpty) {
            runs.add(run);
            run = <(double, double)>[];
          }
        } else {
          run.add(sample);
        }
      }
      if (run.isNotEmpty) {
        runs.add(run);
      }
      drawRuns(graticulePaint, runs);
    }
    for (var lon = -150.0; lon <= 150.0; lon += 30) {
      final samples = <(double, double)?>[];
      for (var lat = -90.0; lat <= 90.0; lat += 6) {
        samples.add(projection.project(lat, lon));
      }
      final runs = <List<(double, double)>>[];
      var run = <(double, double)>[];
      for (final sample in samples) {
        if (sample == null) {
          if (run.isNotEmpty) {
            runs.add(run);
            run = <(double, double)>[];
          }
        } else {
          run.add(sample);
        }
      }
      if (run.isNotEmpty) {
        runs.add(run);
      }
      drawRuns(graticulePaint, runs);
    }
    final landPath = Path()..fillType = PathFillType.evenOdd;
    for (final ring in rings) {
      final clipped = projection.clipRing(ring);
      if (clipped.length < 3) {
        continue;
      }
      landPath.moveTo(
        center.dx + clipped.first.$1 * radius,
        center.dy + clipped.first.$2 * radius,
      );
      for (final point in clipped.skip(1)) {
        landPath.lineTo(
          center.dx + point.$1 * radius,
          center.dy + point.$2 * radius,
        );
      }
      landPath.close();
    }
    canvas.drawPath(landPath, Paint()..color = _land);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = _limb
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final labels = <(String, Offset)>[];
    for (final track in tracks) {
      final linePaint = Paint()
        ..color = track.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      for (var i = 1; i < track.points.length; i++) {
        final prev = track.points[i - 1];
        final point = track.points[i];
        if (prev.latitude == point.latitude &&
            prev.longitude == point.longitude) {
          continue;
        }
        drawRuns(
          linePaint,
          projection.greatCircleRuns(
            prev.latitude,
            prev.longitude,
            point.latitude,
            point.longitude,
          ),
        );
      }
      canvas.save();
      canvas.clipPath(
        Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
      );
      if (track.anchorLat != null && track.anchorLon != null) {
        final at = projection.project(track.anchorLat!, track.anchorLon!);
        if (at != null) {
          final offset = _toOffset(at, center, radius);
          final glow = Paint()..color = track.color.withValues(alpha: 0.25);
          canvas.drawCircle(offset, 14, glow);
          final diamond = Path()
            ..moveTo(offset.dx, offset.dy - 8)
            ..lineTo(offset.dx + 8, offset.dy)
            ..lineTo(offset.dx, offset.dy + 8)
            ..lineTo(offset.dx - 8, offset.dy)
            ..close();
          canvas.drawPath(diamond, Paint()..color = track.color);
          labels.add((track.anchorPlace ?? '', offset));
        }
      }
      for (var i = 0; i < track.points.length; i++) {
        final point = track.points[i];
        final at = projection.project(point.latitude, point.longitude);
        if (at == null) {
          continue;
        }
        final offset = _toOffset(at, center, radius);
        canvas.drawCircle(offset, 4.5, Paint()..color = Colors.white);
        canvas.drawCircle(offset, 3, Paint()..color = track.color);
        if (i == track.points.length - 1) {
          canvas.drawCircle(
            offset,
            8,
            Paint()
              ..color = track.color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
          labels.add((point.placeLabel, offset));
        }
      }
      canvas.restore();
    }
    for (final label in labels) {
      _drawLabel(canvas, label.$1, label.$2, TextDirection.ltr);
    }
  }

  @override
  bool shouldRepaint(_GlobePainter oldDelegate) {
    return oldDelegate.centerLon != centerLon ||
        oldDelegate.centerLat != centerLat ||
        oldDelegate.rings != rings ||
        oldDelegate.tracks != tracks;
  }
}
