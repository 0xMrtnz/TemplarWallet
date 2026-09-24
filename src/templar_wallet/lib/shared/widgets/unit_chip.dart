import 'package:flutter/material.dart';

import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// The unit beside an amount field. Plain text for a token; on a BTC/L-BTC
/// row with a live price it is a target that flips the field to the other
/// unit ([other]) — the ⇅ glyph says it can, the label says which unit the
/// number in the box is in right now.
class UnitChip extends StatelessWidget {
  const UnitChip({super.key, required this.label, this.other, this.onTap});

  final String label;

  /// The unit a tap switches to; null when the chip is only a label.
  final String? other;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.only(left: AppSpacing.sm, right: AppSpacing.md),
        child: Text(
          label,
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
      );
    }
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTypography.caption.copyWith(
            color: s.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 2),
        Icon(Icons.swap_vert_rounded, size: 17, color: s.accent),
      ],
    );
    final tip = 'Enter the amount in $other';
    // Phone: the chip stands on the same inset grey as every other small
    // phone control. Bare text and a glyph on a filled field read as part of
    // the number instead of as a target. The pill keeps its own size inside
    // the 48 dp slot — the slot is what taps, not the pill.
    final Widget pill = phone
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: s.panelInset,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: chip,
            ),
          )
        : chip;
    final body = Semantics(
      button: true,
      label: tip,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(
            phone ? AppSpacing.radiusMd : AppSpacing.radiusSm),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: phone ? AppLayout.minTouchTarget : 0,
            minHeight: phone ? AppLayout.minTouchTarget : 0,
          ),
          child: Padding(
            padding: phone
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
            child: Center(child: pill),
          ),
        ),
      ),
    );
    // Touch has no tooltip; the semantics label above names the action.
    if (phone) {
      return Padding(
        padding: const EdgeInsets.only(right: AppSpacing.xs),
        child: body,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, right: AppSpacing.sm),
      child: Tooltip(message: tip, child: body),
    );
  }
}
