import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Tactile shell shared by every button: presses compress slightly, hover
/// lifts with a soft glow. Purely decorative — hit-testing and semantics stay
/// on the wrapped Material button. No-ops when disabled or reduced-motion.
class _Tactile extends StatefulWidget {
  const _Tactile({required this.child, required this.enabled, this.glow});

  final Widget child;
  final bool enabled;

  /// Hover glow color; null = shadow-only lift (secondary/ghost buttons).
  final Color? glow;

  @override
  State<_Tactile> createState() => _TactileState();
}

class _TactileState extends State<_Tactile> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final reduced = AppMotion.reduced(context);
    final phone = AppLayout.isPhone(context);
    final scale = _down ? 0.97 : 1.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _down = true),
        onPointerUp: (_) => setState(() => _down = false),
        onPointerCancel: (_) => setState(() => _down = false),
        child: AnimatedScale(
          scale: reduced ? 1.0 : scale,
          duration: AppMotion.of(context, AppMotion.instant),
          curve: AppMotion.settle,
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.quick),
            curve: AppMotion.settle,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                phone ? AppSpacing.radiusPhoneControl : AppSpacing.radiusSm,
              ),
              // A phone has no pointer, so the glow that the desktop earns on
              // hover is simply on: it is the app's one shadow, under its one
              // filled action.
              boxShadow: (_hover || phone) && widget.glow != null
                  ? [
                      BoxShadow(
                        color: widget.glow!.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : const [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Icon + label for the solid buttons. The label is Flexible so a narrow
/// host (a two-up Row on a phone) ellipsises it instead of throwing.
Widget _iconLabel(IconData? icon, String label, {double size = 16}) {
  final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
  if (icon == null) return text;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: size),
      const SizedBox(width: AppSpacing.sm),
      Flexible(child: text),
    ],
  );
}

/// The wallet-tile material, shrunk to button size.
///
/// The home gallery tile is the app's calmest interactive object: a translucent
/// card surface, a hairline border, and a hover that only steps the surface up
/// and firms the hairline — no fill, no glow, no colour. Every secondary action
/// in the app reuses exactly that material, because the loud outlined-accent
/// button it replaced made "Copy descriptor" shout as loudly as "Send".
///
/// [quiet] drops it one more step (no resting surface, no resting border) for
/// tertiary actions, where the control should be nearly invisible until the
/// pointer finds it.
///
/// A PHONE INVERTS THE GRAMMAR (design.md): there the tile is filled, not
/// outlined, and carries no border at all — accent is a crimson slab with
/// white ink and the app's one glow, plain is the inset grey, quiet is a
/// 4.5% wash. It stands [AppSpacing.phoneControlHeight] (54 dp) tall at
/// [AppSpacing.radiusPhoneControl], or 44 dp when [dense] is set for a run
/// of inline actions. The desktop metrics and the hover choreography above
/// are unchanged.
class _TileButton extends StatefulWidget {
  const _TileButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.isFullWidth = false,
    this.quiet = false,
    this.accent = false,
    this.dense = false,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isFullWidth;
  final bool quiet;

  /// Work is running: the icon slot becomes a spinner and the tile goes
  /// inert. The caller keeps owning the label ("Reading…"), because only it
  /// knows what the wait is for.
  final bool isLoading;

  /// A phone-only smaller slab — 44 dp, tighter padding, one radius step
  /// down. For a run of inline actions that must share a row: at the full 54
  /// dp the three under an address field wrapped onto two lines. Desktop
  /// ignores it, where the tile was always this size.
  final bool dense;

  /// The tile in brand colours: accent hairline, accent icon, accent label,
  /// on the same surface as every other tile. This is what "the primary
  /// action" looks like now — the old solid crimson slab shouted next to the
  /// quiet controls it sat beside, and on Home it made "New Wallet" louder
  /// than the wallets.
  final bool accent;

  @override
  State<_TileButton> createState() => _TileButtonState();
}

class _TileButtonState extends State<_TileButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final enabled = widget.onPressed != null && !widget.isLoading;
    final motion = AppMotion.of(context, AppMotion.quick);
    final reduced = AppMotion.reduced(context);
    final phone = AppLayout.isPhone(context);
    final dense = phone && widget.dense;
    final active = enabled && _hover;

    // The phone's grammar is fill, the desktop's is outline (design.md).
    // Every desktop expression below is the one that was always there.
    final fill = phone
        ? (!enabled
            ? s.panelInset
            : widget.accent
                ? s.accent
                : widget.quiet
                    ? s.ink.withValues(alpha: 0.045)
                    : s.panelInset)
        : !enabled
        ? Colors.transparent
        : widget.accent
        ? (active
              ? s.accent.withValues(alpha: s.isDark ? 0.22 : 0.16)
              : s.accentSoft)
        : widget.quiet
        ? (active ? s.cardBase : Colors.transparent)
        : (active ? s.cardHover : s.cardBase);

    final border = phone
        ? Colors.transparent
        : !enabled
        ? s.edge
        : widget.accent
        ? s.accent.withValues(alpha: active ? 0.95 : 0.6)
        : widget.quiet
        ? (active ? s.edge : Colors.transparent)
        : (active ? s.edgeStrong : s.edge);

    final ink = phone
        ? (!enabled
            ? s.inkFaint
            : widget.accent
                ? Colors.white
                : widget.quiet
                    ? s.inkSecondary
                    : s.ink)
        : !enabled
        ? s.inkFaint
        : widget.accent
        ? s.accent
        : widget.quiet && !active
        ? s.inkSecondary
        : s.ink;

    // The tile's one flash of brand: on the gallery it is a red rule under the
    // headline, here it is the icon. On a plain tile the text stays ink so the
    // button never reads as a primary action; an accent tile is the primary
    // action, so everything on it goes red together.
    final iconColor =
        phone ? ink : (widget.accent ? s.accent : (active ? s.accent : ink));

    final content = Row(
      mainAxisSize: widget.isFullWidth ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.isLoading) ...[
          SizedBox(
            width: phone && !dense ? 18 : 14,
            height: phone && !dense ? 18 : 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(ink),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
        ] else if (widget.icon != null) ...[
          Icon(widget.icon, size: phone && !dense ? 20 : 16, color: iconColor),
          const SizedBox(width: AppSpacing.sm),
        ],
        // Flexible + ellipsis: a narrow host shortens the label rather than
        // striping the button. Costs nothing while the label fits.
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.body.copyWith(
              fontSize: phone && !dense ? 16.5 : 14.5,
              fontWeight: phone && !dense ? FontWeight.w700 : FontWeight.w600,
              color: ink,
            ),
          ),
        ),
      ],
    );

    final padding = EdgeInsets.symmetric(
      horizontal: phone
          ? (dense ? AppSpacing.md : AppSpacing.lg)
          : (widget.quiet ? AppSpacing.md : AppSpacing.lg),
      vertical: phone ? AppSpacing.md : AppSpacing.md - 1,
    );
    final decoration = BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(
        phone
            ? (dense ? AppSpacing.radiusLg : AppSpacing.radiusPhoneControl)
            : AppSpacing.radiusMd,
      ),
      border: Border.all(color: border),
      // The same glow _Tactile gives the solid buttons, so an accent tile and
      // a PrimaryButton bloom identically on a phone.
      boxShadow: phone && widget.accent && enabled
          ? [
              BoxShadow(
                color: s.accent.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ]
          : null,
    );

    final Widget tile;
    if (phone) {
      // Ripple inside the decorated box (so it shows over the fill) and a
      // 48 dp floor; the GestureDetector's job moves to the InkWell.
      tile = AnimatedContainer(
        duration: motion,
        curve: AppMotion.settle,
        width: widget.isFullWidth ? double.infinity : null,
        constraints: BoxConstraints(
          minHeight: dense
              ? AppLayout.minTouchTarget - 4
              : AppSpacing.phoneControlHeight,
        ),
        decoration: decoration,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? widget.onPressed : null,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            child: Padding(padding: padding, child: content),
          ),
        ),
      );
    } else {
      tile = AnimatedContainer(
        duration: motion,
        curve: AppMotion.settle,
        width: widget.isFullWidth ? double.infinity : null,
        padding: padding,
        decoration: decoration,
        child: content,
      );
    }

    final scaled = AnimatedScale(
      scale: reduced || !enabled || !_down ? 1.0 : 0.97,
      duration: AppMotion.of(context, AppMotion.instant),
      curve: AppMotion.settle,
      child: tile,
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _down = true),
        onPointerUp: (_) => setState(() => _down = false),
        onPointerCancel: (_) => setState(() => _down = false),
        // Desktop keeps the detector outside the scale, exactly as before;
        // on a phone the InkWell inside the tile owns the tap.
        child: phone
            ? scaled
            : GestureDetector(
                onTap: enabled ? widget.onPressed : null,
                behavior: HitTestBehavior.opaque,
                child: scaled,
              ),
      ),
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.isFullWidth = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final bool isFullWidth;

  @override
  Widget build(BuildContext context) {
    final Widget child = isLoading
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          )
        : _iconLabel(icon, label,
            size: AppLayout.isPhone(context) ? 20 : 16);

    final btn = _Tactile(
      enabled: onPressed != null && !isLoading,
      glow: AppColors.accent,
      // Height, corner and text size on a phone come from the theme overlay
      // (AppTheme.phoneBuilder), so they are stated once for every Material
      // button in the app, this one included.
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        child: child,
      ),
    );

    return isFullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// Secondary action — the wallet-tile material at button scale.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isFullWidth = false,
    this.dense = false,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isFullWidth;

  /// See [_TileButton.dense] — a 44 dp slab for a row of inline actions.
  final bool dense;

  /// See [_TileButton.isLoading] — spinner in the icon slot, tile inert.
  final bool isLoading;

  @override
  Widget build(BuildContext context) => _TileButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    isFullWidth: isFullWidth,
    dense: dense,
    isLoading: isLoading,
  );
}

/// The lead action on a screen, built from the same tile as everything around
/// it and separated only by colour. Use where [PrimaryButton]'s solid slab
/// broke the row it sat in — "New Wallet" on Home, "Send" on the balance hero.
class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isFullWidth = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isFullWidth;

  @override
  Widget build(BuildContext context) => _TileButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    isFullWidth: isFullWidth,
    accent: true,
  );
}

class DangerButton extends StatelessWidget {
  const DangerButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isFullWidth = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isFullWidth;

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final btn = _Tactile(
      enabled: onPressed != null,
      glow: AppColors.danger,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.danger,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize:
              phone ? const Size(64, AppSpacing.phoneControlHeight) : null,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              phone ? AppSpacing.radiusPhoneControl : AppSpacing.radiusSm,
            ),
          ),
        ),
        child: _iconLabel(icon, label, size: phone ? 20 : 16),
      ),
    );

    return isFullWidth ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

/// Tertiary action — the same material, one step quieter still: nothing but
/// the label until the pointer lands on it (on a phone: a resting hairline,
/// since nothing lands).
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isFullWidth = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isFullWidth;

  @override
  Widget build(BuildContext context) => _TileButton(
        label: label,
        onPressed: onPressed,
        icon: icon,
        quiet: true,
        isFullWidth: isFullWidth,
      );
}

/// One option in a row of choices — the app's chip, and a [SegmentedSwitch]
/// that ran out of room.
///
/// Where a control has three to five options with real names, a joined track
/// overflows the 640 dp wizard column and Material's own `SegmentedButton` /
/// `ChoiceChip` each bring their own palette, radius and height into a screen
/// built from tiles. This is the material everything else here is made of: a
/// hairline chip on the desktop, a filled `panelInset` slab on a phone, and
/// the accent reserved for the one option that is chosen.
class ChoiceTile extends StatefulWidget {
  const ChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    this.icon,
    this.onSelected,
    this.tooltip,
  });

  final String label;
  final IconData? icon;
  final bool selected;

  /// null = an option the user can see but not take. Keeping it in place
  /// rather than dropping it leaves the control the same shape on every
  /// screen; put the reason in [tooltip].
  final VoidCallback? onSelected;

  final String? tooltip;

  @override
  State<ChoiceTile> createState() => _ChoiceTileState();
}

class _ChoiceTileState extends State<ChoiceTile> {
  bool _hover = false;
  bool _down = false;

  /// Phone stand-in for the hover tooltip on a dimmed chip.
  void _explainDisabled() {
    final tip = widget.tooltip;
    if (tip == null) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tip)));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final enabled = widget.onSelected != null;
    final selected = widget.selected;
    final active = enabled && _hover;

    // Phone fills, desktop outlines — the same split every other control in
    // the app makes (design.md, "The phone's controls").
    final fill = phone
        ? (selected
            ? s.accent.withValues(alpha: s.isDark ? 0.24 : 0.16)
            : s.panelInset)
        : !enabled
        ? Colors.transparent
        : selected
        ? s.accentSoft
        : active
        ? s.cardHover
        : s.cardBase;

    final border = phone
        ? Colors.transparent
        : selected
        ? s.accent.withValues(alpha: active ? 0.95 : 0.65)
        : !enabled
        ? s.edge
        : active
        ? s.edgeStrong
        : s.edge;

    final ink = !enabled
        ? s.inkFaint.withValues(alpha: 0.6)
        : selected
        ? s.accent
        : phone || active
        ? s.ink
        : s.inkSecondary;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: phone ? 17 : 15, color: ink),
          const SizedBox(width: AppSpacing.sm - 2),
        ],
        Text(
          widget.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTypography.bodySmall.copyWith(
            color: ink,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );

    final padding = EdgeInsets.symmetric(
      horizontal: phone ? AppSpacing.md + 2 : AppSpacing.lg - 2,
      vertical: phone ? AppSpacing.md : AppSpacing.sm + 1,
    );
    final decoration = BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(
        phone ? AppSpacing.radiusLg : AppSpacing.radiusMd,
      ),
      border: Border.all(color: border),
    );

    final Widget chip;
    if (phone) {
      // Ripple inside the decorated box so it shows over the fill, and a
      // 48 dp floor for the touch target.
      chip = AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.settle,
        constraints: const BoxConstraints(minHeight: AppLayout.minTouchTarget),
        decoration: decoration,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? widget.onSelected : _explainDisabled,
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            child: Padding(padding: padding, child: content),
          ),
        ),
      );
    } else {
      chip = AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.settle,
        padding: padding,
        decoration: decoration,
        child: content,
      );
    }

    final scaled = AnimatedScale(
      scale: AppMotion.reduced(context) || !enabled || !_down ? 1.0 : 0.97,
      duration: AppMotion.of(context, AppMotion.instant),
      curve: AppMotion.settle,
      child: chip,
    );

    final tappable = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _down = true),
        onPointerUp: (_) => setState(() => _down = false),
        onPointerCancel: (_) => setState(() => _down = false),
        child: phone
            ? scaled
            : GestureDetector(
                onTap: enabled ? widget.onSelected : null,
                behavior: HitTestBehavior.opaque,
                child: scaled,
              ),
      ),
    );

    final tip = widget.tooltip;
    if (tip == null) return tappable;
    // A phone tap on a dimmed chip already explains it; a long-press tooltip
    // would only add a second, undiscoverable path.
    if (phone) return Semantics(label: tip, child: tappable);
    return Tooltip(message: tip, child: tappable);
  }
}
