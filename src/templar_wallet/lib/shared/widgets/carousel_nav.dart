// Bottom carousel navigation — the mobile shell's answer to the sidebar.
//
// Three items are visible and the centred one is the page. The list is
// circular: after Settings comes Dashboard again. Dragging the bar scrolls
// it, and whichever item snaps to the centre becomes the page, with a haptic
// tick at every crossing. A tap on a side icon jumps there; a tap on the
// centre icon brings the page back to the top.
//
// Ported from the approved prototype (templar-carousel-nav.html) — same
// position model (a continuous `pos`, five rendered slots around
// `round(pos)`), same flick projection with the idle-velocity reset, same
// tap-versus-drag rules, and a cancelled pointer settles without ever
// counting as a tap.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_typography.dart';

/// Which block of the nav an item belongs to. Liquid items take the Liquid
/// teal for their centre plate; everything else takes the accent.
enum CarouselNavGroup { wallet, liquid, system }

/// One entry of the carousel.
class CarouselNavItem {
  const CarouselNavItem({
    required this.id,
    required this.label,
    required this.route,
    required this.icon,
    required this.activeIcon,
    this.group = CarouselNavGroup.wallet,
  });

  /// Stable identity, used to keep the current item when the list is
  /// rebuilt after a gating flag changes.
  final String id;
  final String label;

  /// Route handed to [CarouselNav.onSelect]; also what
  /// [CarouselNav.currentRoute] is matched against.
  final String route;

  /// Outlined glyph, shown on the sides; [activeIcon] is the filled form the
  /// centre crossfades into.
  final IconData icon;
  final IconData activeIcon;
  final CarouselNavGroup group;
}

/// The bar. Three visible slots, five rendered (the outer two are faded out
/// and never hit-testable), infinite in both directions.
///
/// The bar is the only thing that scrolls it: the page above never moves the
/// carousel by touch. When the centred item changes, [onSelect] is called
/// with its route at once — the page switches at the snap crossing, as in
/// the prototype. When [currentRoute] changes from outside (a Send button on
/// the Dashboard), the bar animates to that item by the shortest circular
/// path, unless the user is mid-drag.
class CarouselNav extends StatefulWidget {
  const CarouselNav({
    super.key,
    required this.items,
    required this.currentRoute,
    required this.onSelect,
    this.onCenterTap,
  });

  final List<CarouselNavItem> items;

  /// The route the shell is on, already reduced to an item's route (the
  /// shell maps sub-routes such as `/liquid/issue` to `/liquid`). A route
  /// that matches no item leaves the bar where it is.
  final String currentRoute;

  /// Called with the item's route the moment it becomes the centred one.
  final ValueChanged<String> onSelect;

  /// A tap on the centred icon (or the gap beside it). The shell uses it to
  /// scroll the page back to the top.
  final VoidCallback? onCenterTap;

  /// Bar height on a device with no bottom system inset, at the default
  /// text scale. See [heightFor] for the inset-aware value.
  static const double height =
      _topPad + _slotHeight + _labelHeight + _bottomPadNoInset;

  /// Bar height above a system inset of [inset] dp, inset included. The pad
  /// under the label shrinks when the inset already provides the breathing
  /// room (edge-to-edge gesture or 3-button navigation).
  static double heightFor(double inset) =>
      _topPad + _slotHeight + _labelHeight + _bottomPadFor(inset) + inset;

  @override
  State<CarouselNav> createState() => _CarouselNavState();
}

// ── Geometry & timing ─────────────────────────────────────────────────────────
//
// Trimmed from the prototype's 10/68/20/14 (112 dp before the inset) to
// 6/56/18/6-12 (86-92 dp): the owner found the bar too tall on a phone. Each
// side slot stays a 72 x 56 dp target.

const double _topPad = 6;
const double _slotHeight = 56;
const double _slotWidth = 72;

/// Room for the label at the default text scale; grows with the scale up to
/// the clamp applied in [_CarouselNavState.build].
const double _labelHeight = 18;

/// Pad under the label: 12 dp on a device with no bottom inset, 6 dp when the
/// gesture bar or button nav already pads the bottom edge.
const double _bottomPadNoInset = 12;
const double _bottomPadWithInset = 6;
double _bottomPadFor(double inset) =>
    inset > 0 ? _bottomPadWithInset : _bottomPadNoInset;

const double _plateSize = 48;
const double _iconSize = 24;

/// Largest text scale the bar honours; beyond it the label would need more
/// than the slot row and the bar would grow past its budget.
const double _maxTextScale = 1.3;

/// A press held longer than this is a release, not a tap, even if it never
/// moved.
const int _tapMaxMs = 400;

/// A finger that rested this long before lifting carries no flick.
const int _flickIdleMs = 80;

/// How far ahead a flick is projected, in milliseconds of travel.
const double _flickProjectionMs = 150;

/// A flick never lands more than this many slots past where the finger let go.
const int _maxFlickSlots = 3;

int _mod(int a, int n) => ((a % n) + n) % n;

/// Live drag bookkeeping, from the first update to the release.
class _DragSession {
  _DragSession({required this.x0, required this.p0, required this.t0})
    : lastX = x0,
      lastT = t0;

  final double x0;
  final double p0;
  final int t0;
  double lastX;
  int lastT;

  /// Smoothed horizontal velocity, logical px per ms.
  double v = 0;
}

class _CarouselNavState extends State<CarouselNav>
    with TickerProviderStateMixin {
  late List<CarouselNavItem> _items;

  /// Continuous carousel position, unbounded while moving; normalised back
  /// into `0..n` once it comes to rest.
  double _pos = 0;

  /// Index of the centred item (`round(pos) mod n`).
  int _idx = 0;

  /// Distance between neighbouring slots. Measured from the bar width.
  double _slot = 104;
  double _width = 0;

  late final AnimationController _anim;
  double _animFrom = 0;
  double _animTo = 0;

  /// The centre plate's landing pop — the bar's one reward for arriving
  /// somewhere. Fires with the haptic, never on an external route change,
  /// and not at all under reduced motion.
  late final AnimationController _pop;

  /// True while the bar is catching up with a route change made elsewhere.
  /// Crossings during that motion must not navigate — the page is already
  /// where the router put it.
  bool _external = false;

  /// The last route this bar asked the router for. `widget.currentRoute`
  /// lags one frame behind an `onSelect` (router setState → next build), so
  /// crossings are compared against this when it is pending.
  String? _requested;

  _DragSession? _drag;
  final Stopwatch _clock = Stopwatch()..start();
  int _downAt = 0;
  bool _reducedMotion = false;

  int get _now => _clock.elapsedMilliseconds;

  @override
  void initState() {
    super.initState();
    // Created here, not lazily: a bar disposed before it ever moved would
    // otherwise create its ticker during unmount.
    _anim = AnimationController(vsync: this)
      ..addListener(_onTick)
      ..addStatusListener(_onAnimStatus);
    _pop = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _items = widget.items;
    final j = _indexOfRoute(widget.currentRoute);
    _idx = j < 0 ? 0 : j;
    _pos = _idx.toDouble();
  }

  @override
  void didUpdateWidget(CarouselNav old) {
    super.didUpdateWidget(old);
    if (!_sameItems(old.items, widget.items)) {
      _rebuildItems();
      return;
    }
    // The router caught up with our own request.
    if (_requested != null && widget.currentRoute == _requested) {
      _requested = null;
    }
    if (old.currentRoute == widget.currentRoute) return;
    // Our own crossings echo back as route changes: by then the centred item
    // already matches. A user-driven snap still in flight is left alone too.
    if (_drag != null || (_anim.isAnimating && !_external)) return;
    final j = _indexOfRoute(widget.currentRoute);
    if (j >= 0 && j != _idx) _goTo(j, external: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    _pop.dispose();
    super.dispose();
  }

  // ── Items ───────────────────────────────────────────────────────────────────

  static bool _sameItems(List<CarouselNavItem> a, List<CarouselNavItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  int _indexOfRoute(String route) =>
      _items.indexWhere((it) => it.route == route);

  /// Gating flags changed. Keep the current item if it survived, otherwise
  /// the one the router is on, otherwise the first. No motion, no haptic.
  void _rebuildItems() {
    final keepId = _items.isEmpty ? null : _items[_idx].id;
    _items = widget.items;
    _anim.stop();
    _drag = null;
    _external = false;
    var j = _items.indexWhere((it) => it.id == keepId);
    if (j < 0) j = _indexOfRoute(widget.currentRoute);
    _idx = j < 0 ? 0 : j;
    _pos = _idx.toDouble();
    setState(() {});
  }

  // ── Position ────────────────────────────────────────────────────────────────

  /// Recompute the centred item from `pos` and repaint. A change of centred
  /// item under the user's finger ticks the haptic and switches the page; a
  /// crossing during an external catch-up (a Dashboard shortcut, a deep
  /// link) does neither — the user did not touch the bar, and a buzz per
  /// slot crossed would read as an error rattle.
  void _render() {
    if (!mounted) return;
    final n = _items.length;
    final ni = _mod(_pos.round(), n);
    if (ni != _idx) {
      _idx = ni;
      if (!_external) {
        HapticFeedback.selectionClick();
        if (!_reducedMotion) _pop.forward(from: 0);
        _select(_items[ni].route);
      }
    }
    setState(() {});
  }

  /// Ask the router for [route] unless it is already there (or on its way).
  void _select(String route) {
    if (route == (_requested ?? widget.currentRoute)) return;
    _requested = route;
    widget.onSelect(route);
  }

  /// At rest after user-driven motion the page must show the centred item:
  /// a crossing lost to a same-frame jitter, or a touch that interrupted an
  /// external catch-up, would otherwise leave bar and page apart.
  void _reconcile() {
    if (_items.isEmpty) return;
    _select(_items[_idx].route);
  }

  void _normalize() {
    final n = _items.length;
    _pos = _pos % n; // Dart's % is non-negative for a positive divisor.
    _idx = _mod(_pos.round(), n);
  }

  void _animateTo(double target) {
    _anim.stop();
    final from = _pos;
    final dist = (target - from).abs();
    if (_reducedMotion || dist < 0.002) {
      _pos = target;
      _render();
      _normalize();
      final wasExternal = _external;
      _external = false;
      if (!wasExternal) _reconcile();
      return;
    }
    _animFrom = from;
    _animTo = target;
    _anim.duration = Duration(
      milliseconds: (200 + dist * 90).clamp(220, 420).round(),
    );
    _anim.forward(from: 0);
  }

  void _onTick() {
    _pos =
        _animFrom +
        (_animTo - _animFrom) * Curves.easeOutCubic.transform(_anim.value);
    _render();
  }

  void _onAnimStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _pos = _animTo;
    _render();
    _normalize();
    final wasExternal = _external;
    _external = false;
    if (!wasExternal) _reconcile();
  }

  /// Animate to item [j] by the shortest way round the circle.
  void _goTo(int j, {required bool external}) {
    final n = _items.length;
    final base = _pos.round();
    var d = _mod(j - _mod(base, n), n); // forward distance 0..n-1
    if (d > n / 2) d -= n; // shortest signed path
    _external = external;
    _animateTo((base + d).toDouble());
  }

  // ── Pointer ─────────────────────────────────────────────────────────────────
  //
  // The bar is a sibling of the page, never inside a scrollable, so there is
  // no parent gesture to compete with: a horizontal drag here can only be
  // ours, and a vertical one cannot scroll the page (the page's scrollables
  // are not under the pointer). The raw Listener handles what the arena
  // cannot: freezing a snap the instant the bar is touched, and settling a
  // half-way position after a press that no recognizer claimed.

  void _onPointerDown(PointerDownEvent event) {
    if (_drag != null) return;
    _downAt = _now;
    _interruptExternal();
    _anim.stop();
    _external = false;
  }

  /// Touching the bar while it is catching up with an outside route change:
  /// the router is already on the target, so the target becomes the logical
  /// centre — settling anywhere else then counts as a crossing.
  void _interruptExternal() {
    if (_external && _anim.isAnimating && _items.isNotEmpty) {
      _idx = _mod(_animTo.round(), _items.length);
    }
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    // A drag the recognizer already accepted is ENDED, not cancelled, when
    // the system takes the pointer — flick included, from whatever speed the
    // finger last had. This listener sees the cancel first, so it is where
    // "no flick" is kept (see _onDragCancel).
    if (event is PointerCancelEvent) _onDragCancel();
    scheduleMicrotask(_settleIfIdle);
  }

  /// After every release: if neither a tap nor a drag took over and the bar
  /// sits between two slots, snap to the nearest one.
  void _settleIfIdle() {
    if (!mounted || _drag != null || _anim.isAnimating) return;
    final nearest = _pos.roundToDouble();
    if (_pos != nearest) {
      _animateTo(nearest);
    } else if (!_external) {
      _reconcile();
    }
  }

  void _onDragStart(DragStartDetails details) {
    _interruptExternal();
    _anim.stop();
    _external = false;
    // DragStartBehavior.down: this is where the finger first touched, and
    // the first update carries the whole distance travelled since.
    _drag = _DragSession(x0: details.localPosition.dx, p0: _pos, t0: _now);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final d = _drag;
    if (d == null) return;
    final x = details.localPosition.dx;
    final now = _now;
    final dt = now - d.lastT;
    if (dt > 0) d.v = 0.7 * d.v + 0.3 * ((x - d.lastX) / dt);
    d.lastX = x;
    d.lastT = now;
    _pos = d.p0 - (x - d.x0) / _slot;
    _render();
  }

  void _onDragEnd(DragEndDetails details) {
    final d = _drag;
    if (d == null) return;
    _drag = null;
    // Project the flick (none if the finger rested), snap to the nearest
    // slot, never more than three beyond where the finger let go.
    final idle = _now - d.lastT;
    final v = idle > _flickIdleMs ? 0.0 : d.v;
    final projected = _pos - (v * _flickProjectionMs) / _slot;
    final here = _pos.round();
    final target = projected.round().clamp(
      here - _maxFlickSlots,
      here + _maxFlickSlots,
    );
    _animateTo(target.toDouble());
  }

  /// The system took the pointer (an edge gesture, a palm): settle where we
  /// are. No tap, no flick. Reached from the recognizer before a drag is
  /// accepted, and from the pointer listener after.
  void _onDragCancel() {
    if (_drag == null) return;
    _drag = null;
    _animateTo(_pos.roundToDouble());
  }

  void _onTapUp(TapUpDetails details) {
    if (_drag != null) return;
    final base = _pos.round();
    if (_now - _downAt >= _tapMaxMs) {
      _animateTo(base.toDouble());
      return;
    }
    final k = _slotAt(details.localPosition.dx);
    if (k != null && k != 0) {
      _animateTo((base + k).toDouble());
      return;
    }
    _animateTo(base.toDouble());
    widget.onCenterTap?.call();
  }

  /// Which rendered slot sits under [x], or null for a gap. Slots that are
  /// faded out of view are not hit-testable.
  int? _slotAt(double x) {
    final base = _pos.round();
    final cx = _width / 2;
    for (var k = -2; k <= 2; k++) {
      final off = (base + k) - _pos;
      if (off.abs() >= 1.5) continue;
      if ((x - (cx + off * _slot)).abs() <= _slotWidth / 2) return k;
    }
    return null;
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final reduceEffects = context.select<AppState, bool>(
      (st) => st.reduceEffects,
    );
    _reducedMotion = AppMotion.reduced(context);
    final inset = MediaQuery.viewPaddingOf(context).bottom;

    // One step off the page, with a hairline on top and nothing else — the
    // bar is chrome and chrome recedes (design.md). It used to be a 74%
    // black over black, which on an OLED screen was a hole rather than a
    // surface: the icons floated with no bar under them.
    final fill = s.chrome;
    final hairline = s.edge;

    final labelStyle = AppTypography.label.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.25,
      color: s.ink,
      height: 1.2,
    );
    // The label row grows with the (clamped) system text scale so descenders
    // are never clipped by the fixed-height slot below the icons.
    final textScale = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: _maxTextScale).scale(1);
    final labelHeight = math.max(
      _labelHeight,
      (labelStyle.fontSize! * labelStyle.height! * textScale).ceilToDouble(),
    );

    Widget bar = LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        _slot = (_width * 0.27).clamp(84.0, 118.0);
        // The bar clips as a whole so the centre glow may bleed into the top
        // pad and the label row but never above the hairline or over the
        // page; the slot Stack itself must not clip, or the halo is cut
        // flat at the slot row's edges.
        return ClipRect(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              _topPad,
              0,
              _bottomPadFor(inset) + inset,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: _slotHeight,
                  width: double.infinity,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: _slots(s, reduceEffects),
                  ),
                ),
                SizedBox(
                  height: labelHeight,
                  child: Center(
                    child: _CenterLabel(
                      text: _items.isEmpty ? '' : _items[_idx].label,
                      style: labelStyle,
                      reducedMotion: _reducedMotion,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    bar = Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUpOrCancel,
      onPointerCancel: _onPointerUpOrCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onTapUp: _onTapUp,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _onDragCancel,
        child: bar,
      ),
    );

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        border: Border(top: BorderSide(color: hairline)),
      ),
      child: bar,
    );

    // No BackdropFilter: the bar is a Scaffold slot, nothing scrolls under
    // it, so a blur would only re-sample the flat canvas on every drag frame.
    // The translucent tint keeps the glass look on its own.
    final body = MediaQuery.withClampedTextScaling(
      maxScaleFactor: _maxTextScale,
      child: surface,
    );

    return RepaintBoundary(child: Semantics(container: true, child: body));
  }

  List<Widget> _slots(AppScheme s, bool reduceEffects) {
    if (_items.isEmpty) return const [];
    final n = _items.length;
    final base = _pos.round();
    final cx = _width / 2;
    final out = <Widget>[];
    for (var k = -2; k <= 2; k++) {
      final item = _items[_mod(base + k, n)];
      final off = (base + k) - _pos; // -2.5 .. 2.5
      final a = off.abs();
      final c = (1 - a).clamp(0.0, 1.0); // centredness 0..1
      // 0.9 at the sides, 1.12 centred: a 48-dp plate reads 53.8 dp inside
      // the 56-dp slot row, the glyph 26.9 dp; side glyphs sit at 21.6 dp.
      // 0.9 at the sides, 1.12 centred, plus the landing pop where it is
      // running — a half sine, so it swells and settles back.
      final pop = _pop.isAnimating
          ? 0.07 * math.sin(math.pi * _pop.value) * c
          : 0.0;
      final scale = 0.9 + 0.22 * c + pop;
      final opacity = a < 1 ? 1.0 : (1 - (a - 1) * 1.6).clamp(0.0, 1.0);
      final hidden = a >= 1.5;
      final tint = item.group == CarouselNavGroup.liquid
          ? (s.isDark ? AppColors.liquidMuted : AppColors.liquid)
          : AppColors.accent;
      out.add(
        Positioned(
          left: cx + off * _slot - _slotWidth / 2,
          top: 0,
          width: _slotWidth,
          height: _slotHeight,
          child: ExcludeSemantics(
            excluding: hidden,
            child: Semantics(
              button: true,
              selected: k == 0,
              label: item.label,
              onTap: hidden ? null : () => _animateTo((base + k).toDouble()),
              // No Opacity widget: the fade is folded into the paint colours
              // (see _SlotVisual), which needs no saveLayer per slot per
              // drag frame. Transform.scale is a matrix, not a layer.
              child: Transform.scale(
                scale: scale,
                child: _SlotVisual(
                  item: item,
                  centredness: c,
                  opacity: opacity,
                  tint: tint,
                  scheme: s,
                  glow: !reduceEffects,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return out;
  }
}

// ── Slot ──────────────────────────────────────────────────────────────────────

/// One icon with its plate. Everything is driven by centredness: the plate
/// and its glow fade in, the glyph fills in and takes the tint. [opacity]
/// is the slot's own fade at the edge of the bar. Both are painted as colour
/// alpha rather than through Opacity widgets, so a drag frame costs no
/// saveLayers.
class _SlotVisual extends StatelessWidget {
  const _SlotVisual({
    required this.item,
    required this.centredness,
    required this.opacity,
    required this.tint,
    required this.scheme,
    required this.glow,
  });

  final CarouselNavItem item;
  final double centredness;
  final double opacity;
  final Color tint;
  final AppScheme scheme;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final c = centredness;
    // The side glyphs start from the readable ink, not the faint one: they
    // are the two places the bar can take you next.
    final color = Color.lerp(scheme.inkSecondary, tint, c)!;
    final plateAlpha = c * opacity;
    return Stack(
      alignment: Alignment.center,
      children: [
        // A filled disc with a crisp ring and a contained glow. The old plate
        // spread its shadow into a red cloud twice the width of the icon,
        // which read as a smudge rather than as "you are here".
        if (plateAlpha > 0)
          Container(
            width: _plateSize,
            height: _plateSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tint.withValues(
                alpha: (scheme.isDark ? 0.18 : 0.13) * plateAlpha,
              ),
              border: Border.all(
                color: tint.withValues(alpha: 0.55 * plateAlpha),
              ),
              boxShadow: glow
                  ? [
                      BoxShadow(
                        color: tint.withValues(
                          alpha: (scheme.isDark ? 0.34 : 0.22) * plateAlpha,
                        ),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
          ),
        if (c < 1)
          Icon(
            item.icon,
            size: _iconSize,
            color: color.withValues(alpha: color.a * (1 - c) * opacity),
          ),
        if (c > 0)
          Icon(
            item.activeIcon,
            size: _iconSize,
            color: color.withValues(alpha: color.a * c * opacity),
          ),
      ],
    );
  }
}

// ── Label ─────────────────────────────────────────────────────────────────────

/// The name under the centred icon. On change it fades out, swaps, and
/// fades back in; instant under reduced motion.
class _CenterLabel extends StatefulWidget {
  const _CenterLabel({
    required this.text,
    required this.style,
    required this.reducedMotion,
  });

  final String text;
  final TextStyle style;
  final bool reducedMotion;

  @override
  State<_CenterLabel> createState() => _CenterLabelState();
}

class _CenterLabelState extends State<_CenterLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  late String _shown = widget.text;
  String? _pending;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
      value: 1,
    );
  }

  @override
  void didUpdateWidget(_CenterLabel old) {
    super.didUpdateWidget(old);
    if (widget.text == (_pending ?? _shown)) return;
    if (widget.reducedMotion) {
      _pending = null;
      _shown = widget.text;
      _fade.value = 1;
      return;
    }
    final wasFading = _pending != null;
    _pending = widget.text;
    if (wasFading) return; // the running fade-out will pick up the new text
    _fade.animateBack(0).then((_) {
      if (!mounted) return;
      final next = _pending;
      if (next == null) return;
      setState(() {
        _shown = next;
        _pending = null;
      });
      _fade.forward();
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: Text(
        _shown,
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }
}
