// Value chart — the hero portfolio sparkline.
//
// Pure presentation: it takes points in and renders them. No bridge, service
// or feature imports; every number it shows comes from [ValueChart.formatValue].
//
// Interpolation is monotone cubic (Fritsch–Carlson). This is a correctness
// guardrail, not a style choice: a plain Catmull-Rom spline overshoots between
// samples and would draw a balance the wallet never held.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One sample of a value series.
class ChartPoint {
  const ChartPoint(this.time, this.value);
  final DateTime time;
  final double value;
}

/// Smooth area chart with an interactive cursor, sized to sit inside the
/// frosted hero panel (no axes, no gridlines — the cursor carries the numbers).
///
/// Pointer model: with a mouse the cursor follows the hover and clears on
/// exit. On a touch platform ([AppLayout.isMobilePlatform]) there is no hover,
/// so a tap pins the cursor where the finger landed, a horizontal drag moves
/// it, and it stays after the finger lifts until the same sample is tapped
/// again — a read-out that vanished the instant the finger left the glass was
/// unreadable, because the finger was covering it. The chip is then drawn on
/// the far side of the chart from the hairline so the hand never hides it.
class ValueChart extends StatefulWidget {
  const ValueChart({
    super.key,
    required this.points,
    required this.formatValue,
    this.height = 132,
    this.lineColor,
    this.emptyMessage,
    this.animationKey,
    this.gridLines = 0,
    this.markLatest = false,
  });

  /// Ascending by time. May be empty.
  final List<ChartPoint> points;

  /// Formats a value for the cursor readout (fiat or coin units).
  final String Function(double) formatValue;

  final double height;

  /// Defaults to the runtime accent.
  final Color? lineColor;

  /// Shown centered when [points] is empty. Nothing is drawn when null.
  final String? emptyMessage;

  /// Identifies "a different chart" for the entry animation. When set, the
  /// sweep replays only if this changes — so a refreshed series (new data for
  /// the same view) redraws without re-animating. Null = replay on any change.
  final Object? animationKey;

  /// Faint horizontal rules behind the line, evenly spaced across the drawing
  /// band. A bare line on a phone hero reads as decoration; two or three rules
  /// behind it say "this is a chart" without spending a single label. 0 = none.
  final int gridLines;

  /// Drop a dot on the newest sample as the sweep lands — "you are here".
  final bool markLatest;

  @override
  State<ValueChart> createState() => _ValueChartState();
}

class _ValueChartState extends State<ValueChart>
    with SingleTickerProviderStateMixin {
  /// Upper bound on rendered samples — a 1-year daily series is well under it,
  /// a per-transaction series of a busy wallet is not.
  static const int _maxRendered = 180;

  static const double _topPad = 10;
  static const double _bottomPad = 8;
  static const double _sidePad = 5;

  late final AnimationController _sweep =
      AnimationController(vsync: this, duration: AppMotion.standard);

  List<ChartPoint> _sampled = const [];
  int? _cursor;

  /// Touch only: the cursor was placed by a tap or drag and survives the
  /// finger lifting. Never set with a mouse, so desktop behaviour is untouched.
  bool _pinned = false;
  bool _started = false;

  /// Layout-derived geometry, cached from the last paint pass so pointer
  /// hit-testing maps to exactly the pixels on screen.
  _ChartGeometry? _geom;

  @override
  void initState() {
    super.initState();
    _sampled = _downsample(widget.points, _maxRendered);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _startSweep();
    }
  }

  @override
  void didUpdateWidget(ValueChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.points, widget.points)) {
      _sampled = _downsample(widget.points, _maxRendered);
      _geom = null;
      // A pinned touch read-out rides through the per-minute data refresh;
      // the sample index is only approximate across the new list, but the
      // next tap corrects it and a vanishing chip is worse.
      if (!_pinned || (_cursor ?? 0) >= _sampled.length) _cursor = null;
      if (_cursor == null) _pinned = false;
      // With an animationKey the caller decides what counts as a new chart, so
      // a periodic data refresh updates the line without replaying the sweep.
      final k = widget.animationKey;
      if (k == null || k != oldWidget.animationKey) _startSweep();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  void _startSweep() {
    // Duration.zero under reduced motion — forward() then lands on 1 at once.
    _sweep.duration = AppMotion.of(context, AppMotion.standard);
    _sweep.forward(from: 0);
  }

  // ── Cursor ──────────────────────────────────────────────────────────────────

  void _moveCursor(Offset local) {
    final g = _geom;
    if (g == null || g.xs.isEmpty) return;
    final i = g.nearestByX(local.dx);
    if (i != _cursor) setState(() => _cursor = i);
  }

  void _clearCursor() {
    if (_cursor != null || _pinned) {
      setState(() {
        _cursor = null;
        _pinned = false;
      });
    }
  }

  /// Touch: place (or move) the pinned cursor; tapping the sample that is
  /// already pinned releases it.
  void _tapCursor(Offset local) {
    final g = _geom;
    if (g == null || g.xs.isEmpty) return;
    final i = g.nearestByX(local.dx);
    if (_pinned && i == _cursor) {
      _clearCursor();
      return;
    }
    setState(() {
      _cursor = i;
      _pinned = true;
    });
  }

  void _dragCursor(Offset local) {
    final g = _geom;
    if (g == null || g.xs.isEmpty) return;
    final i = g.nearestByX(local.dx);
    if (i != _cursor || !_pinned) {
      setState(() {
        _cursor = i;
        _pinned = true;
      });
    }
  }

  // ── Down-sampling ───────────────────────────────────────────────────────────

  /// Keeps first and last, and picks the sample nearest each interior time
  /// bucket — preserving the shape of long ranges without drawing 5k points.
  static List<ChartPoint> _downsample(List<ChartPoint> pts, int max) {
    if (pts.length <= max) return pts;

    double ms(int i) => pts[i].time.millisecondsSinceEpoch.toDouble();
    final t0 = ms(0);
    final span = ms(pts.length - 1) - t0;

    final out = <ChartPoint>[pts.first];
    var last = 0;

    if (span <= 0) {
      // Degenerate time axis (all samples share a timestamp): stride by index.
      final stride = pts.length / (max - 1);
      for (var b = 1; b < max - 1; b++) {
        final i = math.min((b * stride).floor(), pts.length - 1);
        if (i != last) {
          out.add(pts[i]);
          last = i;
        }
      }
    } else {
      final buckets = max - 2;
      var scan = 0;
      for (var b = 1; b <= buckets; b++) {
        final target = t0 + span * b / (buckets + 1);
        while (scan + 1 < pts.length && ms(scan + 1) <= target) {
          scan++;
        }
        var best = scan;
        if (scan + 1 < pts.length &&
            (ms(scan + 1) - target).abs() < (target - ms(scan)).abs()) {
          best = scan + 1;
        }
        if (best != last) {
          out.add(pts[best]);
          last = best;
        }
      }
    }

    if (last != pts.length - 1) out.add(pts.last);
    return out;
  }

  // ── Labels ──────────────────────────────────────────────────────────────────

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatStamp(DateTime dt, bool withClock) {
    final date = '${dt.day} ${_months[dt.month - 1]}';
    if (!withClock) return date;
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$date  $h:$m';
  }

  bool get _spanIsShort {
    if (_sampled.length < 2) return true;
    final span = _sampled.last.time.difference(_sampled.first.time);
    return span.inHours <= 48;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final line = widget.lineColor ?? s.accent;

    if (_sampled.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: widget.emptyMessage == null
            ? null
            : Center(
                child: Text(
                  widget.emptyMessage!,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(color: s.inkFaint),
                ),
              ),
      );
    }

    final cursor = _cursor;
    final active = cursor != null && cursor < _sampled.length;
    final touch = AppLayout.isMobilePlatform;
    // A finger reads the chip from further away than a pointer does.
    final valueStyle = touch
        ? AppTypography.numeric.copyWith(color: s.ink, fontSize: 14)
        : AppTypography.numericSmall.copyWith(color: s.ink);
    final stampStyle = AppTypography.caption
        .copyWith(color: s.inkFaint, fontSize: touch ? 12 : 11, height: 1.2);

    return Semantics(
      label: 'Value chart, ${_sampled.length} points, latest '
          '${widget.formatValue(_sampled.last.value)}',
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth.isFinite ? c.maxWidth : 0.0;
            final h = c.maxHeight.isFinite ? c.maxHeight : widget.height;
            if (w <= 0 || h <= 0) {
              _geom = null;
              return const SizedBox.shrink();
            }

            final geom = _ChartGeometry.build(
              _sampled,
              Size(w, h),
              topPad: _topPad,
              bottomPad: _bottomPad,
              sidePad: _sidePad,
            );
            _geom = geom;

            final Widget gestures;
            if (touch) {
              gestures = GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _tapCursor(d.localPosition),
                // Horizontal-only so the dashboard's vertical scroll still
                // wins; no long-press recognizer, which would hold the list
                // still while a finger rests on the chart. The cursor stays
                // where the drag ended.
                onHorizontalDragStart: (d) => _dragCursor(d.localPosition),
                onHorizontalDragUpdate: (d) => _dragCursor(d.localPosition),
                child: _paint(geom, w, h, line, s, active, cursor, valueStyle,
                    stampStyle, farSideChip: true),
              );
            } else {
              gestures = MouseRegion(
                onHover: (e) => _moveCursor(e.localPosition),
                onExit: (_) => _clearCursor(),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Horizontal-only so the dashboard's vertical scroll still wins.
                  onHorizontalDragStart: (d) => _moveCursor(d.localPosition),
                  onHorizontalDragUpdate: (d) => _moveCursor(d.localPosition),
                  onHorizontalDragEnd: (_) => _clearCursor(),
                  onHorizontalDragCancel: _clearCursor,
                  onLongPressStart: (d) => _moveCursor(d.localPosition),
                  onLongPressMoveUpdate: (d) => _moveCursor(d.localPosition),
                  onLongPressEnd: (_) => _clearCursor(),
                  onLongPressCancel: _clearCursor,
                  child: _paint(geom, w, h, line, s, active, cursor, valueStyle,
                      stampStyle),
                ),
              );
            }
            return gestures;
          },
        ),
      ),
    );
  }

  Widget _paint(
    _ChartGeometry geom,
    double w,
    double h,
    Color line,
    AppScheme s,
    bool active,
    int? cursor,
    TextStyle valueStyle,
    TextStyle stampStyle, {
    bool farSideChip = false,
  }) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _sweep,
        builder: (_, _) => CustomPaint(
          size: Size(w, h),
          painter: _ValueChartPainter(
            geom: geom,
            progress: _sweep.value,
            line: line,
            baseline: s.edge,
            // Faint on purpose: the rules are there to be felt, not read.
            // Derived from the page's own ink, so it follows a re-theme.
            grid: s.ink.withValues(alpha: 0.07),
            gridLines: widget.gridLines,
            markLatest: widget.markLatest,
            hairline: s.inkFaint.withValues(alpha: 0.5),
            chipFill: s.surfaceSolid,
            chipEdge: s.edge,
            cursor: active ? cursor : null,
            cursorValue:
                active ? widget.formatValue(_sampled[cursor!].value) : null,
            cursorStamp: active
                ? _formatStamp(_sampled[cursor!].time, _spanIsShort)
                : null,
            valueStyle: valueStyle,
            stampStyle: stampStyle,
            isDark: s.isDark,
            farSideChip: farSideChip,
          ),
        ),
      ),
    );
  }
}

// ── Geometry ──────────────────────────────────────────────────────────────────

/// Screen-space projection of a series. Built once per layout pass and shared
/// by the painter and by pointer hit-testing.
class _ChartGeometry {
  _ChartGeometry._(
    this.xs,
    this.ys,
    this.pathXs,
    this.pathYs,
    this.size,
    this.top,
    this.bottom,
  );

  final List<double> xs;
  final List<double> ys;

  /// The drawing band the samples were projected into — what the grid rules
  /// are spaced across.
  final double top;
  final double bottom;

  /// Strictly-x-increasing subset used for the spline (duplicate x positions
  /// would divide by zero in the slope limiter).
  final List<double> pathXs;
  final List<double> pathYs;

  final Size size;

  factory _ChartGeometry.build(
    List<ChartPoint> pts,
    Size size, {
    required double topPad,
    required double bottomPad,
    required double sidePad,
  }) {
    final n = pts.length;
    final left = sidePad;
    final right = math.max(sidePad, size.width - sidePad);
    final top = topPad;
    final bottom = math.max(topPad, size.height - bottomPad);

    final values = List<double>.generate(
      n,
      (i) => pts[i].value.isFinite ? pts[i].value : 0.0,
    );

    var minV = values[0];
    var maxV = values[0];
    for (final v in values) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final range = maxV - minV;

    final t0 = pts.first.time.millisecondsSinceEpoch.toDouble();
    final span = pts.last.time.millisecondsSinceEpoch.toDouble() - t0;

    final xs = List<double>.filled(n, 0);
    final ys = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final double fx;
      if (n == 1) {
        fx = 0.5;
      } else if (span > 0) {
        fx = ((pts[i].time.millisecondsSinceEpoch.toDouble() - t0) / span)
            .clamp(0.0, 1.0);
      } else {
        fx = i / (n - 1);
      }
      xs[i] = left + fx * (right - left);
      // Flat series sits on the centre line instead of dividing by zero.
      final fy = range > 0 ? (values[i] - minV) / range : 0.5;
      ys[i] = bottom - fy * (bottom - top);
    }

    final pathXs = <double>[];
    final pathYs = <double>[];
    for (var i = 0; i < n; i++) {
      if (pathXs.isEmpty || xs[i] > pathXs.last) {
        pathXs.add(xs[i]);
        pathYs.add(ys[i]);
      } else {
        pathYs[pathYs.length - 1] = ys[i];
      }
    }

    return _ChartGeometry._(xs, ys, pathXs, pathYs, size, top, bottom);
  }

  double get baselineY => size.height - 0.5;

  int nearestByX(double x) {
    if (xs.length == 1) return 0;
    var lo = 0;
    var hi = xs.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (xs[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo > 0 && (x - xs[lo - 1]).abs() <= (xs[lo] - x).abs()) return lo - 1;
    return lo;
  }
}

// ── Painter ───────────────────────────────────────────────────────────────────

class _ValueChartPainter extends CustomPainter {
  _ValueChartPainter({
    required this.geom,
    required this.progress,
    required this.line,
    required this.baseline,
    required this.grid,
    required this.gridLines,
    required this.markLatest,
    required this.hairline,
    required this.chipFill,
    required this.chipEdge,
    required this.cursor,
    required this.cursorValue,
    required this.cursorStamp,
    required this.valueStyle,
    required this.stampStyle,
    required this.isDark,
    this.farSideChip = false,
  });

  final _ChartGeometry geom;
  final double progress;
  final Color line;
  final Color baseline;
  final Color grid;

  /// See [ValueChart.gridLines] / [ValueChart.markLatest].
  final int gridLines;
  final bool markLatest;
  final Color hairline;
  final Color chipFill;
  final Color chipEdge;
  final int? cursor;
  final String? cursorValue;
  final String? cursorStamp;
  final TextStyle valueStyle;
  final TextStyle stampStyle;
  final bool isDark;

  /// Touch: draw the chip at the chart edge opposite the hairline instead of
  /// beside it, so the finger that placed the cursor is not covering it.
  final bool farSideChip;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0 || geom.xs.isEmpty) return;

    // Grid first, so the line and its fill always sit over it.
    if (gridLines > 0) {
      final band = geom.bottom - geom.top;
      final paint = Paint()
        ..color = grid
        ..strokeWidth = 1;
      for (var i = 1; i <= gridLines; i++) {
        final y = geom.bottom - band * i / (gridLines + 1);
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }

    canvas.drawLine(
      Offset(0, geom.baselineY),
      Offset(size.width, geom.baselineY),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );

    if (geom.pathXs.length < 2) {
      // Single sample: a dot is the honest rendering — a line would imply a
      // history that isn't there.
      _drawDot(canvas, Offset(geom.xs.first, geom.ys.first));
      _drawCursorChip(canvas, size);
      return;
    }

    final path = _monotonePath(geom.pathXs, geom.pathYs);

    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, 0, size.width * progress.clamp(0.0, 1.0), size.height),
    );

    final fill = Path.from(path)
      ..lineTo(geom.pathXs.last, geom.baselineY)
      ..lineTo(geom.pathXs.first, geom.baselineY)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [line.withValues(alpha: 0.28), line.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = line,
    );
    canvas.restore();

    // "Now", marked as the sweep reaches it: the line arrives and the dot
    // lands with it. Painted outside the clip, so it is never half a circle.
    if (markLatest) {
      final t = ((progress - 0.75) / 0.25).clamp(0.0, 1.0);
      if (t > 0) {
        final at = Offset(geom.xs.last, geom.ys.last);
        canvas.drawCircle(
          at,
          8 * t,
          Paint()..color = line.withValues(alpha: 0.20 * t),
        );
        canvas.drawCircle(at, 3.5 * t, Paint()..color = line);
      }
    }

    _drawCursorChip(canvas, size);
  }

  /// Fritsch–Carlson monotone cubic through the samples, emitted as cubic
  /// Béziers. Guarantees every drawn y stays within the neighbouring samples'
  /// values — no phantom peaks or dips.
  Path _monotonePath(List<double> xs, List<double> ys) {
    final n = xs.length;
    final secant = List<double>.filled(n - 1, 0);
    for (var i = 0; i < n - 1; i++) {
      secant[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]);
    }

    final m = List<double>.filled(n, 0);
    m[0] = secant[0];
    m[n - 1] = secant[n - 2];
    for (var i = 1; i < n - 1; i++) {
      m[i] = (secant[i - 1] + secant[i]) / 2;
    }

    for (var i = 0; i < n - 1; i++) {
      if (secant[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
        continue;
      }
      var a = m[i] / secant[i];
      var b = m[i + 1] / secant[i];
      if (a < 0) {
        m[i] = 0;
        a = 0;
      }
      if (b < 0) {
        m[i + 1] = 0;
        b = 0;
      }
      final norm = a * a + b * b;
      if (norm > 9) {
        final tau = 3 / math.sqrt(norm);
        m[i] = tau * a * secant[i];
        m[i + 1] = tau * b * secant[i];
      }
    }

    final path = Path()..moveTo(xs[0], ys[0]);
    for (var i = 0; i < n - 1; i++) {
      final h = (xs[i + 1] - xs[i]) / 3;
      path.cubicTo(
        xs[i] + h,
        ys[i] + m[i] * h,
        xs[i + 1] - h,
        ys[i + 1] - m[i + 1] * h,
        xs[i + 1],
        ys[i + 1],
      );
    }
    return path;
  }

  void _drawDot(Canvas canvas, Offset at) {
    canvas.drawCircle(at, 5.5, Paint()..color = chipFill);
    canvas.drawCircle(at, 3.5, Paint()..color = line);
  }

  void _drawCursorChip(Canvas canvas, Size size) {
    final i = cursor;
    final value = cursorValue;
    if (i == null || value == null || i >= geom.xs.length) return;

    final x = geom.xs[i];
    final y = geom.ys[i];

    canvas.drawLine(
      Offset(x, 0),
      Offset(x, geom.baselineY),
      Paint()
        ..color = hairline
        ..strokeWidth = 1,
    );
    _drawDot(canvas, Offset(x, y));

    final vp = _text(value, valueStyle, size.width);
    final sp = cursorStamp == null
        ? null
        : _text(cursorStamp!, stampStyle, size.width);

    const padH = 8.0;
    const padV = 5.0;
    const gap = 1.0;
    final w = math.max(vp.width, sp?.width ?? 0) + padH * 2;
    final h = vp.height + (sp == null ? 0 : sp.height + gap) + padV * 2;

    double left;
    if (farSideChip) {
      // Opposite half of the chart from the hairline: clear of the finger.
      left = x < size.width / 2 ? size.width - w - 1 : 1.0;
    } else {
      // Flip to the left of the hairline when the chip would clip the right
      // edge.
      left = x + 10;
      if (left + w > size.width - 1) left = x - 10 - w;
    }
    left = math.min(math.max(left, 1.0), math.max(1.0, size.width - w - 1));
    const top = 1.0;

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, w, h),
      const Radius.circular(AppSpacing.radiusSm),
    );
    canvas.drawRRect(rect, Paint()..color = chipFill);
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = chipEdge,
    );

    vp.paint(canvas, Offset(left + padH, top + padV));
    sp?.paint(canvas, Offset(left + padH, top + padV + vp.height + gap));
  }

  TextPainter _text(String text, TextStyle style, double maxWidth) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(0, maxWidth - 24));

  @override
  bool shouldRepaint(_ValueChartPainter old) =>
      !identical(old.geom, geom) ||
      old.progress != progress ||
      old.gridLines != gridLines ||
      old.markLatest != markLatest ||
      old.grid != grid ||
      old.cursor != cursor ||
      old.cursorValue != cursorValue ||
      old.farSideChip != farSideChip ||
      // Theme flips rebuild with new colors but identical data.
      old.line != line ||
      old.isDark != isDark;
}
