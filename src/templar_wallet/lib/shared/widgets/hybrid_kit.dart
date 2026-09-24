// Hybrid component kit — the shared building blocks of the chosen design
// language (Obsidian glass shell × Instrument data grammar).
//
// Rules baked in:
//  - One frosted HeroPanel per screen max (GPU budget). Honors the
//    reduce-effects setting and degrades to translucent fill.
//  - Critical data always sits on DataWell (solid, AA-contrast backing).
//  - All motion routes through AppMotion tokens (reduced-motion aware).

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

// ── Page background ───────────────────────────────────────────────────────────

/// Obsidian backdrop with a living "Aurora" field: a depth gradient plus a few
/// slowly drifting color blooms (pure radial gradients — no blur, GPU-cheap).
/// Wrap a screen's body in this. The drift freezes under OS reduced-motion or
/// the in-app reduce-effects setting; the still composition stays on-brand.
class PageBackground extends StatelessWidget {
  /// Brand backdrop: accent gradient plus the drifting aurora. Reserved for the
  /// entry screens (home picker, welcome) — it is the one place the brand gets
  /// to speak.
  const PageBackground({super.key, required this.child}) : _flat = false;

  /// Flat single-colour fill, no gradient and no aurora. Every surface inside
  /// an open wallet uses this: decorative colour behind live balances and
  /// addresses competes with the data for attention.
  const PageBackground.flat({super.key, required this.child}) : _flat = true;

  final Widget child;
  final bool _flat;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    if (_flat) {
      return ColoredBox(color: s.canvas, child: child);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: s.bgGradient,
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: _AuroraField(scheme: s)),
          child,
        ],
      ),
    );
  }
}

/// Animated aurora layer — three drifting blooms. Cheap (radial gradients, no
/// blur) and isolated in a RepaintBoundary so it never repaints the UI above.
class _AuroraField extends StatefulWidget {
  const _AuroraField({required this.scheme});
  final AppScheme scheme;

  @override
  State<_AuroraField> createState() => _AuroraFieldState();
}

class _AuroraFieldState extends State<_AuroraField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 32));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds when reduce-effects flips; reduced-motion is read live too.
    final reduceEffects =
        context.select<AppState, bool>((st) => st.reduceEffects);
    final frozen = AppMotion.reduced(context) || reduceEffects;
    if (frozen) {
      if (_c.isAnimating) _c.stop();
      _c.value = 0.28; // a pleasing fixed composition
    } else if (!_c.isAnimating) {
      _c.repeat();
    }

    final s = widget.scheme;
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _AuroraPainter(
              t: _c.value,
              glow: s.accent,
              intensity: s.isDark ? 0.05 : 0.05,
            ),
          ),
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.t,
    required this.glow,
    required this.intensity,
  });

  final double t;

  /// Single accent hue — monochrome glow, no rainbow. Depth comes from varied
  /// per-blob alpha, not from multiple colors (keeps it serious/premium).
  final Color glow;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    void blob(double cx, double cy, double r, double drift, double mul) {
      final dx = math.cos(a + drift) * 38;
      final dy = math.sin(a * 0.7 + drift) * 24;
      final center = Offset(size.width * cx + dx, size.height * cy + dy);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            glow.withValues(alpha: intensity * mul),
            glow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, paint);
    }

    blob(0.16, 0.08, 460, 0, 1.0);
    blob(0.86, 0.30, 380, 2.1, 0.65);
    blob(0.46, 0.96, 440, 4.2, 0.5);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.t != t || old.glow != glow || old.intensity != intensity;
}

// ── Bottom-sheet surface ──────────────────────────────────────────────────────

/// Rounded-top surface for modal bottom sheets (tx detail, asset/token detail).
///
/// Carries the same backdrop the activity/history pages sit on — the page
/// depth gradient plus a soft static accent bloom — so detail sheets read as
/// part of the same design language instead of a flat panel. Pair with
/// `showModalBottomSheet(backgroundColor: Colors.transparent)`.
class SheetSurface extends StatelessWidget {
  const SheetSurface({super.key, required this.child, this.topMargin = 0});

  final Widget child;

  /// Gap above the sheet (leaves the page peeking at the top, like a card).
  final double topMargin;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      margin: EdgeInsets.only(top: topMargin),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // Flat, like every other in-wallet surface: a sheet opens over live
        // balances and addresses, so it must not reintroduce the brand wash.
        color: s.canvas,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: s.edge),
        boxShadow: s.panelShadow,
      ),
      child: child,
    );
  }
}

// ── Panels ────────────────────────────────────────────────────────────────────

/// Frosted glass hero — THE Obsidian signature. Use at most once per screen,
/// for the element that matters most (balance, quorum). Frosting is skipped
/// when the user enables "reduce effects" (translucent fill remains).
class HeroPanel extends StatelessWidget {
  const HeroPanel({super.key, required this.child, this.padding = const EdgeInsets.all(AppSpacing.cardPadding)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final reduceEffects =
        context.select<AppState, bool>((st) => st.reduceEffects);

    final phone = AppLayout.isPhone(context);
    final body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: phone
            ? s.panel
            : reduceEffects
                ? s.surfaceSolid.withValues(alpha: 0.92)
                : s.surfaceGlass,
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        border: Border.all(color: s.edge),
        // A BoxDecoration paints its gradient in place of its colour, so the
        // specular sheen IS the fill wherever it is set. On the desktop that
        // is the intent — glass over the page gradient. On a phone the ground
        // is flat black: the sheen faded the hero to near-black by a third of
        // the way down and the card lost its edge. Flat fill there.
        gradient: phone
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: s.specular,
                stops: const [0.0, 0.35],
              ),
        // No shadow on chrome (design.md): on a black ground it renders
        // nothing and costs a blur pass on every scroll frame.
        boxShadow: phone ? null : s.panelShadow,
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        border: Border(top: BorderSide(color: s.edgeBright)),
      ),
      child: child,
    );

    // On a phone the hero sits on a flat canvas, so the backdrop blur has
    // nothing to blur — it only costs a full-viewport readback per scroll
    // frame. The translucent fill reads identically without it.
    if (reduceEffects || AppLayout.isMobilePlatform) return body;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: body,
      ),
    );
  }
}

/// Solid panel with a colored accent rail header — the Instrument signature.
/// Rail color codes domain: scheme.accent (app), bitcoin, liquid, warning.
class RailPanel extends StatelessWidget {
  const RailPanel({
    super.key,
    required this.title,
    required this.child,
    this.rail,
    this.trailing,
    this.padding,
  });

  final String title;
  final Widget child;
  final Color? rail;
  final Widget? trailing;

  /// Body padding. Pass EdgeInsets.zero for flush content (tables, rows).
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: s.surfaceGlass,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
        boxShadow: s.panelShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: s.surfaceRaised,
              border: Border(left: BorderSide(color: rail ?? s.accent, width: 3)),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.sm + 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: AppTypography.navSection
                        .copyWith(color: s.inkSecondary, letterSpacing: 1.1),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          Divider(height: 1, color: s.edge),
          Padding(
            padding: padding ??
                EdgeInsets.all(AppLayout.isPhone(context)
                    ? AppSpacing.cardPaddingSmall
                    : AppSpacing.cardPadding),
            child: child,
          ),
        ],
      ),
    );
  }
}

// ── Data display ──────────────────────────────────────────────────────────────

/// Solid, AA-contrast backing for critical data (addresses, outpoints,
/// descriptors, amounts). Never translucent — guardrail, not a style choice.
class DataWell extends StatelessWidget {
  const DataWell({super.key, required this.child, this.padding = const EdgeInsets.all(AppSpacing.md + 2)});
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd - 2),
        border: Border.all(color: s.edge),
      ),
      child: child,
    );
  }
}

/// Key/value row for technical data: fixed-width label, full selectable mono
/// value that wraps. Never truncates.
///
/// On a phone a long value (an outpoint, an address) stacks under its label
/// so it gets the whole column instead of the ~250 dp left of the label.
class KvRow extends StatelessWidget {
  const KvRow({super.key, required this.label, required this.value, this.labelWidth = 86});
  final String label;
  final String value;
  final double labelWidth;

  /// Values longer than this stack on a phone; shorter ones (fees, counts,
  /// network names) keep the two-column shape, which scans faster.
  static const int _stackOver = 20;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final labelText = Text(
      label.toUpperCase(),
      style: AppTypography.navSection.copyWith(color: s.inkFaint, fontSize: 10),
    );
    final valueText = SelectableText(
      value,
      style: AppTypography.monoSmall.copyWith(color: s.ink),
    );
    if (AppLayout.isPhone(context) && value.length > _stackOver) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [labelText, const SizedBox(height: 2), valueText],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: labelWidth, child: labelText),
          Expanded(child: valueText),
        ],
      ),
    );
  }
}

/// Small outlined tag — YOURS / CHANGE / RECIPIENT / status markers.
/// Ellipsises rather than overflows when the parent is tighter than the
/// label; 11 pt on a phone (9.5 is unreadable at arm's length).
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.65)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.navSection.copyWith(
          color: color,
          fontSize: phone ? 11 : 9.5,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Testnet badge — Home only.
///
/// It used to sit in every screen header, which in a testnet-only build meant
/// the same word repeated on eight pages: read once, then invisible. Stated
/// once, on the dashboard the user lands on after unlocking, it is still the
/// answer to "which network am I on" and is no longer wallpaper.
class TestnetBadge extends StatelessWidget {
  const TestnetBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Semantics(
      label: 'Testnet network — no mainnet funds',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: s.testnet.withValues(alpha: 0.12),
          border: Border.all(color: s.testnet.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'TESTNET',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.navSection
              .copyWith(color: s.testnet, fontSize: 10, letterSpacing: 1.2),
        ),
      ),
    );
  }
}

// ── Motion helpers ────────────────────────────────────────────────────────────

/// Staggered rise-and-settle entrance (Obsidian motion signature).
/// No-op under OS reduced motion.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.delay = 0});
  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    // On a phone the entrance is composited from a cached raster of the
    // child: a QR CustomPaint or a blurred card inside would otherwise be
    // repainted through a saveLayer on every one of the ~20 frames.
    final content = AppLayout.isMobilePlatform
        ? RepaintBoundary(child: child)
        : child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.emphasized + Duration(milliseconds: 70 * delay),
      curve: AppMotion.enter,
      builder: (_, t, c) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: c),
      ),
      child: content,
    );
  }
}

/// Springy pop-in (scale + fade) for delight moments — the Aurora motion
/// signature. No-op under reduced motion. Use sparingly; never on streaming
/// data, only on hero/brand elements.
class Pop extends StatelessWidget {
  const Pop({super.key, required this.child, this.delay = 0});
  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.emphasized + Duration(milliseconds: 90 * delay),
      curve: AppMotion.spring,
      builder: (_, t, c) => Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.scale(scale: 0.96 + 0.04 * t, child: c),
      ),
      child: child,
    );
  }
}

/// Sheened text — a restrained, premium vertical sheen on titles/numerals
/// (top bright, fading down). Monochrome by default (no hue), so it reads
/// serious; pass [colors] to override. Sizing/weight come from [style].
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    required this.style,
    this.colors,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle style;
  final List<Color>? colors;
  final TextAlign? textAlign;

  /// Passed straight to the inner [Text]; a hero numeral usually wants
  /// `maxLines: 1` with a `FittedBox` around it so it scales, never wraps.
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final grad = colors ?? [s.ink, s.ink.withValues(alpha: 0.66)];
    return ShaderMask(
      shaderCallback: (r) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: grad,
      ).createShader(r),
      blendMode: BlendMode.srcIn,
      child: Text(
        text,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
        style: style.copyWith(color: Colors.white),
      ),
    );
  }
}

/// Hover-aware row tint (Instrument grammar) for table/list rows.
///
/// [trailing] is an action that belongs to the row (copy, open) and on
/// desktop fades in on hover; a phone has no hover, so there it is simply
/// always shown. Leave it null and the row is exactly what it was.
class HoverRow extends StatefulWidget {
  const HoverRow({
    super.key,
    required this.child,
    this.zebra = false,
    this.onTap,
    this.trailing,
  });
  final Widget child;
  final bool zebra;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  State<HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<HoverRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    Widget content = widget.child;
    final trailing = widget.trailing;
    if (trailing != null) {
      final alwaysShown = AppLayout.isPhone(context);
      content = Row(
        children: [
          Expanded(child: content),
          AnimatedOpacity(
            duration: AppMotion.of(context, AppMotion.instant),
            opacity: alwaysShown || _h ? 1 : 0,
            child: trailing,
          ),
        ],
      );
    }
    final row = MouseRegion(
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.instant),
        color: _h && widget.onTap != null
            ? s.hover
            : (widget.zebra ? s.zebra : Colors.transparent),
        child: content,
      ),
    );
    if (widget.onTap == null) return row;
    return InkWell(onTap: widget.onTap, child: row);
  }
}
