import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/asset_palette.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

enum BadgeVariant { success, warning, danger, accent, neutral }

/// Small tinted status pill. Shrink-wrapped, and when a Row hands it less
/// than it needs the label ellipsises instead of striping (the phone history
/// row, where "Bitcoin" sits beside a full-width amount).
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.variant = BadgeVariant.neutral,
    this.icon,
    this.dot = false,
  });

  final String label;
  final BadgeVariant variant;
  final IconData? icon;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (variant) {
      BadgeVariant.success => (AppColors.successLight, AppColors.success),
      BadgeVariant.warning => (AppColors.warningLight, AppColors.warning),
      BadgeVariant.danger => (AppColors.dangerLight, AppColors.danger),
      BadgeVariant.accent => (AppColors.accentLight, AppColors.accentDark),
      BadgeVariant.neutral => (
          Theme.of(context).brightness == Brightness.dark
              ? AppColors.surfaceDark2
              : AppColors.borderMuted,
          Theme.of(context).brightness == Brightness.dark
              ? AppColors.textSecondaryDark
              : AppColors.textSecondary,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: fg,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
          ] else if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: AppSpacing.xs),
          ],
          // A loose Flexible in a min-size Row is a no-op while the label
          // fits and is legal under unbounded width, so the badge can sit in
          // a header scroller as well as a tight Row.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.label.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

class AssetBadge extends StatelessWidget {
  const AssetBadge({super.key, required this.ticker, this.isNative = false});

  final String ticker;

  /// Retained for API compatibility; color now derives from the chain
  /// (BTC → orange, every Liquid asset → green).
  final bool isNative;

  @override
  Widget build(BuildContext context) {
    final p = AssetPalette.forTicker(ticker);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: p.light,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: p.muted, width: 0.5),
      ),
      child: Text(
        ticker.toUpperCase(),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: AppTypography.label.copyWith(
          color: p.dark,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class AssetChip extends StatelessWidget {
  const AssetChip({
    super.key,
    required this.ticker,
    required this.amount,
    this.isSelected = false,
    this.onTap,
  });

  final String ticker;
  final String amount;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accent
              : isDark
                  ? AppColors.surfaceDark2
                  : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
          border: Border.all(
            color: isSelected
                ? AppColors.accent
                : isDark
                    ? AppColors.borderDark
                    : AppColors.borderLight,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ticker,
              style: AppTypography.label.copyWith(
                color: isSelected
                    ? Colors.white
                    : isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              amount,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodySmall.copyWith(
                color: isSelected ? Colors.white70 : null,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
