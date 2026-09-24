import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One choice in a [SegmentedSwitch].
class SegOption<T> {
  const SegOption({
    required this.value,
    required this.label,
    this.icon,
    this.color,
    this.tooltip,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;

  /// Colour this segment adopts when selected. Defaults to the app accent;
  /// pass the chain colour where the choice *is* the chain, so BTC and Liquid
  /// are told apart by hue and not only by position.
  final Color? color;

  final String? tooltip;

  /// A choice the user can see but not make — the chain this wallet does not
  /// have, say. Drawn dimmed and inert; put the reason in [tooltip]. Keeping
  /// the segment in place (rather than dropping it) leaves the control the
  /// same shape on every screen.
  final bool enabled;
}

/// A labelled switch built from the app's tile material.
///
/// Replaces the two places where a choice was drawn as bare icons or as
/// Material `ChoiceChip`s: an icon-only segment makes the user hover to learn
/// what it does, and chips next to a page title read as filters rather than as
/// the mode the whole screen is in. Here the options sit in one bordered
/// track, always carry their name, and the selected one is filled in its own
/// colour.
///
/// On a phone every segment is a 48 dp touch row, the track shrinks (labels
/// ellipsised) instead of overflowing when the row is tighter than it, taps
/// ripple, and a disabled segment explains itself with a snack bar since there
/// is no hover to surface the tooltip. Desktop metrics are untouched.
class SegmentedSwitch<T> extends StatelessWidget {
  const SegmentedSwitch({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.dense = false,
    this.expand = false,
    this.iconOnly = false,
  });

  final List<SegOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Tighter padding, for track placement inside a dense header row.
  final bool dense;

  /// Fill the available width, every segment the same share. Needs a bounded
  /// width (a Column child, a SizedBox) — inside a horizontal scroller leave
  /// it false and the track keeps its intrinsic width.
  final bool expand;

  /// Draw only the icons; the label moves into the tooltip. For the rare
  /// track that has to share one phone row with other controls. Options
  /// without an icon keep their label.
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Container(
      // The phone's track is the field's grammar: filled grey, no border,
      // radius 14 — and 14 − 4 dp of padding leaves the pill concentric.
      padding: EdgeInsets.all(phone ? 4 : 3),
      decoration: BoxDecoration(
        color: phone ? s.panelInset : s.cardBase,
        borderRadius: BorderRadius.circular(
          phone ? AppSpacing.radiusLg : AppSpacing.radiusMd,
        ),
        border: phone ? null : Border.all(color: s.edge),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final o in options)
            _wrap(
              phone,
              _Segment<T>(
                option: o,
                selected: o.value == selected,
                dense: dense,
                phone: phone,
                expand: expand,
                iconOnly: iconOnly && o.icon != null,
                onTap: () => onChanged(o.value),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wrap(bool phone, Widget segment) {
    if (expand) return Expanded(child: segment);
    // A loose Flexible in a min-size Row costs nothing while the track fits
    // and caps each segment at an equal share when it does not — and, unlike
    // Expanded, it is legal under unbounded width (the page header's
    // horizontal scroller on a phone).
    if (phone) return Flexible(child: segment);
    return segment;
  }
}

class _Segment<T> extends StatefulWidget {
  const _Segment({
    required this.option,
    required this.selected,
    required this.dense,
    required this.phone,
    required this.expand,
    required this.iconOnly,
    required this.onTap,
  });

  final SegOption<T> option;
  final bool selected;
  final bool dense;
  final bool phone;
  final bool expand;
  final bool iconOnly;
  final VoidCallback onTap;

  @override
  State<_Segment<T>> createState() => _SegmentState<T>();
}

class _SegmentState<T> extends State<_Segment<T>> {
  bool _hover = false;

  /// Phone stand-in for the hover tooltip on a dimmed segment.
  void _explainDisabled() {
    final tip = widget.option.tooltip;
    if (tip == null) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tip)));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final color = widget.option.color ?? s.accent;
    final selected = widget.selected;
    final enabled = widget.option.enabled;
    final phone = widget.phone;
    final ink = !enabled
        ? s.inkSecondary.withValues(alpha: 0.45)
        : selected
        ? color
        : _hover
        ? s.ink
        : s.inkSecondary;

    final labelStyle = AppTypography.bodySmall.copyWith(
      color: ink,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    );
    final label = phone || widget.expand
        // Capped segments (phone Flexible / expand) ellipsise the label
        // instead of painting past the track.
        ? Flexible(
            child: Text(
              widget.option.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          )
        : Text(widget.option.label, style: labelStyle);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.option.icon != null) ...[
          Icon(widget.option.icon, size: phone ? 17 : 15, color: ink),
          if (!widget.iconOnly) const SizedBox(width: AppSpacing.sm - 2),
        ],
        if (!widget.iconOnly) label,
      ],
    );

    final padding = EdgeInsets.symmetric(
      horizontal: phone
          ? (widget.dense || widget.iconOnly
                ? AppSpacing.sm + 2
                : AppSpacing.md)
          : (widget.dense ? AppSpacing.md : AppSpacing.lg),
      vertical: phone
          ? AppSpacing.md
          : (widget.dense ? AppSpacing.sm - 1 : AppSpacing.sm + 1),
    );

    final decoration = BoxDecoration(
      color: selected
          // One step brighter on a phone: the outline that used to carry the
          // selection is gone, and the track under it is lighter.
          ? color.withValues(
              alpha: phone
                  ? (s.isDark ? 0.24 : 0.16)
                  : (s.isDark ? 0.18 : 0.12),
            )
          : _hover && enabled
          ? s.cardHover
          : Colors.transparent,
      borderRadius: BorderRadius.circular(
        phone ? AppSpacing.radiusMd : AppSpacing.radiusSm,
      ),
      border: phone
          ? null
          : Border.all(
              color:
                  selected ? color.withValues(alpha: 0.65) : Colors.transparent,
            ),
    );

    final Widget body;
    if (phone) {
      // 42 dp inside the track's 3 dp padding makes a 48 dp touch row. The
      // ink sits inside the decorated box so the ripple shows over the fill.
      body = AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.settle,
        constraints: BoxConstraints(
          // 54 dp when the track owns its row, so it lines up with the
          // buttons stacked with it; 48 when it shares a header row.
          minHeight: (widget.expand
                  ? AppSpacing.phoneControlHeight
                  : AppLayout.minTouchTarget) -
              8,
        ),
        decoration: decoration,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? widget.onTap : _explainDisabled,
            // Follows the pill above, or the ripple squares off its corners.
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            child: Padding(
              padding: padding,
              child: Center(child: content),
            ),
          ),
        ),
      );
    } else {
      body = AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.settle,
        padding: padding,
        decoration: decoration,
        child: content,
      );
    }

    final tappable = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: phone
          ? body
          : GestureDetector(
              onTap: enabled ? widget.onTap : null,
              behavior: HitTestBehavior.opaque,
              child: body,
            ),
    );

    final tip =
        widget.option.tooltip ?? (widget.iconOnly ? widget.option.label : null);
    if (tip == null) return tappable;
    // On a phone the tap on a disabled segment already explains it and an
    // icon-only segment is named for the screen reader; a long-press tooltip
    // would only add a second, undiscoverable path.
    if (phone) return Semantics(label: tip, child: tappable);
    return Tooltip(message: tip, child: tappable);
  }
}
