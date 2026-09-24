import 'package:flutter/material.dart';

import '../../features/dashboard/models/dashboard_data.dart';
import '../../services/asset_registry_service.dart';
import '../../services/issued_asset_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../theme/asset_palette.dart';
import 'asset_logo.dart';
import 'badges.dart';
import 'glass_card.dart';
import 'privacy.dart';

/// The RT pill drawn on an asset card that owns a reissuance token. Small and
/// non-interactive — the token's details live in the detail sheet.
class _ReissuancePill extends StatelessWidget {
  const _ReissuancePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.liquid.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.liquid.withValues(alpha: 0.40)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.refresh, size: 9, color: AppColors.liquidDark),
          const SizedBox(width: 2),
          Text(
            'RT',
            style: AppTypography.caption.copyWith(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: AppColors.liquidDark,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// A parent asset together with its optional reissuance token (nested inside).
class AssetGroup {
  const AssetGroup({required this.main, this.reissuanceToken});
  final AssetBalance main;
  final AssetBalance? reissuanceToken;
}

/// Groups a flat asset list so reissuance tokens nest under their parent asset.
/// [issued] supplies the parent→token relationship for locally issued assets.
List<AssetGroup> groupAssets(
  List<AssetBalance> assets,
  Map<String, IssuedAssetEntry> issued,
) {
  // token_id → parent asset_id (from the local issued-asset store).
  final tokenToParent = <String, String>{};
  for (final e in issued.values) {
    if (e.tokenId != null) tokenToParent[e.tokenId!] = e.assetId;
  }

  final used = <String>{};
  final groups = <AssetGroup>[];

  for (final asset in assets) {
    if (used.contains(asset.assetId)) continue;
    // Skip tokens that belong to a parent we will render.
    if (tokenToParent.containsKey(asset.assetId)) continue;

    AssetBalance? tokenAsset;
    final entry = issued[asset.assetId];
    if (entry?.tokenId != null) {
      tokenAsset =
          assets.where((a) => a.assetId == entry!.tokenId).firstOrNull;
      if (tokenAsset != null) used.add(tokenAsset.assetId);
    }
    used.add(asset.assetId);
    groups.add(AssetGroup(main: asset, reissuanceToken: tokenAsset));
  }

  // Orphan reissuance tokens (parent not present on-chain).
  for (final asset in assets) {
    if (!used.contains(asset.assetId)) {
      groups.add(AssetGroup(main: asset));
    }
  }

  return groups;
}

/// Glassy, chain-tinted card for an [AssetGroup]. Shows only the parent asset.
/// If the group has a reissuance token, a small RT indicator pill appears;
/// full RT details are revealed inside the bottom-sheet opened by [onTap].
class GroupedAssetCard extends StatelessWidget {
  const GroupedAssetCard({
    super.key,
    required this.group,
    required this.isHidden,
    required this.onTap,
    this.showFiat,
    this.amountOverride,
    this.compact = false,
  });

  final AssetGroup group;
  final bool isHidden;

  /// One full-width row instead of the vertical grid tile: logo, name and
  /// ticker on the left, the amount right-aligned. For a phone column, where
  /// a 190-px grid cell stretched to the full width is mostly empty space.
  /// The amount ellipsises rather than pushing the name off the row.
  final bool compact;

  /// Replaces the backend-formatted amount string (used to honor the BTC/sats
  /// unit preference for native coins). Null → show [AssetBalance.displayAmount].
  final String? amountOverride;

  /// Opens the asset detail sheet (which includes the RT if present).
  /// Null where no sheet exists — the card then renders non-interactive
  /// (no tap cursor, no dead affordance).
  final VoidCallback? onTap;

  /// Optional fiat string rendered under the amount (BTC / LBTC only).
  final String? showFiat;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = group.main;
    final hasToken = group.reissuanceToken != null;
    final palette = AssetPalette.forTicker(asset.ticker);
    final info = AssetRegistryService.instance.get(asset.assetId);
    final displayName = info?.name ?? asset.name;
    final displayTicker = info?.ticker ?? asset.ticker;
    final mutedText =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final primaryText =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;

    if (compact) {
      return GlassCard(
        tint: palette.base,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
              minHeight: AppLayout.minTouchTarget - 2 * (AppSpacing.sm + 2)),
          child: Row(
            children: [
              AssetLogo(ticker: asset.ticker, size: 28),
              const SizedBox(width: AppSpacing.sm + 2),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            style: AppTypography.bodySmall.copyWith(
                              fontWeight: FontWeight.w600,
                              color: isHidden ? mutedText : primaryText,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isHidden) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Icon(Icons.visibility_off,
                              size: 14, color: mutedText),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        AssetBadge(ticker: displayTicker),
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: Text(
                            info?.domain ??
                                '${asset.utxoCount} UTXO'
                                    '${asset.utxoCount == 1 ? '' : 's'}',
                            style: AppTypography.caption
                                .copyWith(color: mutedText),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Amount(
                      amountOverride ?? asset.displayAmount,
                      style: AppTypography.balanceMedium.copyWith(
                        fontSize: 16,
                        color: isHidden ? mutedText : primaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                    if (showFiat != null)
                      Amount(showFiat!,
                          style: AppTypography.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end),
                    if (hasToken) ...[
                      const SizedBox(height: 2),
                      const _ReissuancePill(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return GlassCard(
      tint: palette.base,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.cardPaddingSmall),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: logo + ticker badge + hidden indicator.
          Row(
            children: [
              AssetLogo(ticker: asset.ticker, size: 28),
              const SizedBox(width: AppSpacing.sm),
              Flexible(child: AssetBadge(ticker: displayTicker)),
              const Spacer(),
              if (isHidden)
                Icon(Icons.visibility_off, size: 14, color: mutedText),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            displayName,
            style: AppTypography.bodySmall.copyWith(
              fontWeight: FontWeight.w600,
              color: isHidden
                  ? mutedText
                  : (isDark ? AppColors.textPrimaryDark : AppColors.textPrimary),
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (info?.domain != null)
            Text(info!.domain!,
                style: AppTypography.caption, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.xs),
          Amount(
            amountOverride ?? asset.displayAmount,
            style: AppTypography.balanceMedium.copyWith(
              fontSize: 17,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (showFiat != null)
            Amount(showFiat!,
                style: AppTypography.caption, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Text(
                '${asset.utxoCount} UTXO${asset.utxoCount == 1 ? '' : 's'}',
                style: AppTypography.caption.copyWith(color: mutedText),
              ),
              if (hasToken) ...[
                const SizedBox(width: AppSpacing.sm),
                // Small non-interactive pill — RT details live in the sheet.
                const _ReissuancePill(),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

