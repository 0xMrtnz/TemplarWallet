import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One entry of a [ChoiceList].
class ChoiceListOption<T> {
  const ChoiceListOption({
    required this.value,
    required this.label,
    required this.icon,
    this.note,
    this.enabled = true,
    this.disabledReason,
  });

  final T value;
  final String label;
  final IconData icon;

  /// A two-word qualifier after the label — "signs here" — for what choosing
  /// this changes about the wallet. Not a description: the row is a choice,
  /// and a choice is read at a glance.
  final String? note;

  /// A choice the user can see but not make. It stays in place, dimmed, with
  /// [disabledReason] under it, so the list is the same shape every time.
  final bool enabled;
  final String? disabledReason;
}

/// A grouped list of options with one selected: the wizard's "pick one of
/// these" once there are more than two or three of them and a row of chips
/// would wrap.
///
/// One inset panel, one row per option, hairlines between them, a radio disc
/// on the right — the same disc a [SelectableOptionCard] carries, so a chosen
/// row and a chosen card read the same. Desktop rows tint under the pointer
/// the way every row in the app does; phone rows ripple.
class ChoiceList<T> extends StatelessWidget {
  const ChoiceList({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<ChoiceListOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.panelInset,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) Divider(height: 1, color: s.edge, indent: kChoiceTextInset),
            ChoiceListRow<T>(
              option: options[i],
              selected: options[i].value == selected,
              onTap: options[i].enabled ? () => onChanged(options[i].value) : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// Where a row's text starts — the hairlines between rows start there too,
/// so the icon column reads as one column and not as five gaps.
const double kChoiceTextInset = AppSpacing.lg + 18 + AppSpacing.md;

/// One row of a [ChoiceList].
class ChoiceListRow<T> extends StatefulWidget {
  const ChoiceListRow({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ChoiceListOption<T> option;
  final bool selected;

  /// Null for a disabled option: it keeps its row, loses its cursor.
  final VoidCallback? onTap;

  @override
  State<ChoiceListRow<T>> createState() => _ChoiceListRowState<T>();
}

class _ChoiceListRowState<T> extends State<ChoiceListRow<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final o = widget.option;
    final enabled = widget.onTap != null;
    final selected = widget.selected;
    final active = enabled && _hover && !phone;

    final ink = !enabled
        ? s.inkFaint
        : selected
            ? s.accent
            : active
                ? s.ink
                : s.inkSecondary;
    final fill = selected
        ? s.accentSoft
        : active
            ? s.hover
            : Colors.transparent;
    final reason = o.disabledReason;

    final body = AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.settle,
      color: fill,
      constraints: BoxConstraints(
        minHeight: phone ? AppLayout.minTouchTarget : 44,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm + 2,
      ),
      child: Row(
        children: [
          Icon(o.icon, size: 18, color: ink),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    text: o.label,
                    style: AppTypography.bodySmall.copyWith(
                      color: ink,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                    children: [
                      if (o.note != null)
                        TextSpan(
                          text: '  ·  ${o.note}',
                          style: AppTypography.caption.copyWith(
                            color: enabled ? s.inkFaint : ink,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!enabled && reason != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    reason,
                    style: AppTypography.caption.copyWith(color: s.inkFaint),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          _RadioDisc(selected: selected, enabled: enabled),
        ],
      ),
    );

    final row = Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      child: MergeSemantics(
        child: phone
            ? Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: widget.onTap, child: body),
              )
            : MouseRegion(
                cursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: GestureDetector(
                  onTap: widget.onTap,
                  behavior: HitTestBehavior.opaque,
                  child: body,
                ),
              ),
      ),
    );
    return row;
  }
}

/// The 18 dp disc at the end of a row: filled with a check when chosen, a
/// hairline ring otherwise — the option card's disc, one size down.
class _RadioDisc extends StatelessWidget {
  const _RadioDisc({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.settle,
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? s.accent : Colors.transparent,
        border: Border.all(
          color: selected
              ? s.accent
              : enabled
                  ? s.edgeStrong
                  : s.edge,
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 11, color: Colors.white)
          : null,
    );
  }
}
