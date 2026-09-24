// The phone's list grammar — one card, hairline-separated rows, each with a
// tinted glyph on an inset tile.
//
// The Dashboard's assets and activity and the Settings root are all the same
// object: a labelled group of rows. Sharing the widgets keeps a row meaning
// the same thing wherever it appears, and keeps the two screens from drifting
// a pixel apart (design.md — "compose repeated things as one object").
//
// Desktop screens keep their own panels; nothing here is used there.

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Card inset and icon column — the dividers start where the text does.
const double kListPad = AppSpacing.cardPaddingSmall;
const double kListTile = 40;
const double kListGap = 12;
const double kListTextInset = kListPad + kListTile + kListGap;

/// The uppercase label over a group, with the group's one way in on the
/// right ("ASSETS … Liquid →"). Navigation lives here so the rows below can
/// stay data.
class ListSectionLabel extends StatelessWidget {
  const ListSectionLabel({
    super.key,
    required this.label,
    this.actionLabel,
    this.onAction,
  });

  final String label;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final action = actionLabel;
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: AppTypography.navSection.copyWith(
                color: s.inkFaint,
                letterSpacing: 1.3,
              ),
            ),
          ),
          if (action != null && onAction != null)
            Semantics(
              button: true,
              label: action,
              excludeSemantics: true,
              child: InkWell(
                onTap: onAction,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                child: Container(
                  // The one way into a section is a control, so it clears the
                  // touch floor even though the words are small.
                  constraints: const BoxConstraints(
                    minHeight: AppLayout.minTouchTarget,
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        action,
                        style: AppTypography.label.copyWith(
                          fontSize: 12.5,
                          color: s.inkSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 14,
                        color: s.inkSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The card a run of [ListRow]s sits on.
class ListCard extends StatelessWidget {
  const ListCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.panel,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, color: s.edge, indent: kListTextInset),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// The glyph tile at the head of a row: one inset square, one coloured glyph.
/// Colour identifies the thing; it never fills the tile (design.md).
class ListIconTile extends StatelessWidget {
  const ListIconTile({
    super.key,
    required this.icon,
    required this.tint,
    this.size = kListTile,
  });

  final IconData icon;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: s.panelInset,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(icon, size: size * 0.52, color: tint),
    );
  }
}

/// One row: glyph, title, one line saying what it is, and whatever states or
/// operates it on the right.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.icon,
    required this.tint,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
    this.chevron = false,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String? subtitle;

  /// Overrides the subtitle ink — for a state that is not merely descriptive
  /// (an unavailable chain, an unconfirmed transaction).
  final Color? subtitleColor;

  /// The right-hand side: an amount column, a switch, a value. A [chevron]
  /// is drawn after it.
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final sub = subtitle;
    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kListPad,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          ListIconTile(icon: icon, tint: tint),
          const SizedBox(width: kListGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: AppTypography.body.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: s.ink,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: AppTypography.caption.copyWith(
                      fontSize: 12.5,
                      color: subtitleColor ?? s.inkSecondary,
                      height: 1.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
          if (chevron) ...[
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.chevron_right_rounded, size: 22, color: s.inkFaint),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return Semantics(
        label: sub == null ? title : '$title. $sub',
        child: body,
      );
    }
    // Merged, not excluded: excluding the children silenced the trailing
    // widget, so a screen reader announced the row's name and not its amount.
    return Semantics(
      button: true,
      child: MergeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(onTap: onTap, child: body),
        ),
      ),
    );
  }
}

/// The right-hand figure of a data row: the number, and its unit under it.
class ListAmount extends StatelessWidget {
  const ListAmount({
    super.key,
    required this.value,
    this.unit,
    this.valueColor,
    this.unitColor,
    this.maxWidth = 150,
  });

  final String value;
  final String? unit;
  final Color? valueColor;
  final Color? unitColor;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final u = unit;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.numericSmall.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: valueColor ?? s.ink,
              height: 1.2,
            ),
          ),
          if (u != null) ...[
            const SizedBox(height: 1),
            Text(
              u,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(
                fontSize: 11.5,
                color: unitColor ?? s.inkFaint,
                height: 1.2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The switch used in a row. White thumb on the Action colour when on —
/// the one place a filled accent appears outside a primary button.
class ListSwitch extends StatelessWidget {
  const ListSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Semantics(
      label: semanticLabel,
      toggled: value,
      child: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.white,
        activeTrackColor: s.accent,
        inactiveThumbColor: s.isDark ? AppColors.textPrimaryDark : Colors.white,
        inactiveTrackColor: s.panelInset,
        trackOutlineColor: WidgetStatePropertyAll(s.edge),
        materialTapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }
}
