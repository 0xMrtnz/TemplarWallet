// Shared UTXO rendering widgets — used by the UTXO (coin control) screen and
// by the send wizard's manual input selection step, so picking coins looks
// and feels identical everywhere.

import 'package:flutter/material.dart';
import '../../features/utxos/models/utxo.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'asset_logo.dart';
import 'badges.dart';
import 'hybrid_kit.dart';
import 'privacy.dart';
import 'utxo_details.dart';

/// State chip for a coin, or null when there is nothing worth saying.
///
/// "Available" is the default state of every coin on the screen, so a green
/// badge on almost every row is noise that buries the three states that
/// actually change what you can do with a coin. Frozen is neutral, not the
/// accent: it is a coin put to rest, and the crimson belongs to actions.
(BadgeVariant, String, IconData?)? utxoStateBadge(UtxoState state) =>
    switch (state) {
      UtxoState.available => null,
      UtxoState.frozen => (BadgeVariant.neutral, 'Frozen', kFrozenIcon),
      UtxoState.dusty => (BadgeVariant.warning, 'Dust', null),
      UtxoState.unconfirmed => (BadgeVariant.neutral, 'Pending', null),
    };

/// The glyph a frozen coin wears — on its chip, in its tile, on the button
/// that freezes it.
const IconData kFrozenIcon = Icons.ac_unit_rounded;

/// [StatusBadge] for [utxoStateBadge]'s record.
Widget utxoStateChip((BadgeVariant, String, IconData?) badge) =>
    StatusBadge(label: badge.$2, variant: badge.$1, icon: badge.$3);

// ── Tiers ─────────────────────────────────────────────────────────────────────

/// Banknote denomination tiers — bigger coin → bigger note.
///
/// The two ends are fixed amounts of the chain's own coin: at or under
/// [kDustSats] is dust whatever the wallet holds, and [kWhaleSats] or more is
/// a whale whatever the wallet holds. Everything in between is sized by its
/// share of that asset's holdings, so the percentage the list draws and the
/// size of the note on the wall are the same fact.
enum BanknoteTier { dust, small, big, huge, whale }

/// A coin of this many satoshis or fewer is dust — the relay floor, below
/// which spending it costs more than it is worth.
const int kDustSats = 546;

/// A coin of this many satoshis or more is a whale: one whole coin.
const int kWhaleSats = 100000000;

/// Share of holdings at or above which a coin is Huge.
const double kHugeShare = 0.25;

/// Share of holdings at or above which a coin is Big.
const double kBigShare = 0.05;

/// The tier of [u] given its [share] of the asset's holdings.
BanknoteTier utxoTier(Utxo u, double share) {
  if (u.isBtcLike) {
    if (u.amount <= kDustSats) return BanknoteTier.dust;
    if (u.amount >= kWhaleSats) return BanknoteTier.whale;
  }
  if (share >= kHugeShare) return BanknoteTier.huge;
  if (share >= kBigShare) return BanknoteTier.big;
  return BanknoteTier.small;
}

/// [utxoTier] with the share computed from [totals] (see [utxoAssetTotals]).
BanknoteTier utxoTierIn(Utxo u, Map<String, int> totals) =>
    utxoTier(u, utxoShareOf(u, totals));

// ── Shared share/tier math (single source for screen + picker) ────────────────

/// Groups UTXOs of the same asset (Liquid) or chain (BTC) together.
String utxoAssetKey(Utxo u) => u.assetId ?? u.ticker ?? 'BTC';

/// Per-asset totals — the denominator of every share-of-holdings ratio.
Map<String, int> utxoAssetTotals(List<Utxo> utxos) {
  final totals = <String, int>{};
  for (final u in utxos) {
    totals[utxoAssetKey(u)] = (totals[utxoAssetKey(u)] ?? 0) + u.amount;
  }
  return totals;
}

double utxoShareOf(Utxo u, Map<String, int> totals) {
  final total = totals[utxoAssetKey(u)] ?? 0;
  return total > 0 ? u.amount / total : 0.0;
}

/// `42%` from a tenth up, `4.2%` under it, `<0.1%` for crumbs — one decimal
/// of precision where it changes the reading and none where it would not.
String utxoShareText(double share) {
  final pct = share * 100;
  if (pct <= 0) return '0%';
  if (pct < 0.05) return '<0.1%';
  // Round to a tenth first, so 9.99 reads "10%" and not "10.0%".
  final tenths = (pct * 10).round() / 10;
  if (tenths >= 10) return '${tenths.round()}%';
  return '${tenths.toStringAsFixed(1)}%';
}

/// Size-tier palette — value reads at a glance in BOTH views: banknote paper,
/// border and labels, and the list row's tile/selection/meter all take the
/// tier hue. Five hues, one per tier, neutral slate for dust rising to gold
/// for whales; asset identity stays on the [AssetLogo].
extension TierColors on BanknoteTier {
  /// Main hue: borders, tiles, meters, shadows, paper blends.
  Color base(bool isDark) => switch (this) {
        BanknoteTier.dust => isDark ? const Color(0xFF8B93A7) : const Color(0xFF7A8496),
        BanknoteTier.small => isDark ? const Color(0xFF35B8AC) : const Color(0xFF0E9488),
        BanknoteTier.big => isDark ? const Color(0xFF5D9BE8) : const Color(0xFF3B82D6),
        BanknoteTier.huge => isDark ? const Color(0xFFA78BFA) : const Color(0xFF8B5CF6),
        BanknoteTier.whale => isDark ? const Color(0xFFE8B54A) : const Color(0xFFD99A26),
      };

  /// Readable text shade on the tinted paper (labels, serials).
  Color text(bool isDark) => switch (this) {
        BanknoteTier.dust => isDark ? const Color(0xFFB6BEC9) : const Color(0xFF4B5563),
        BanknoteTier.small => isDark ? const Color(0xFF6FD6CB) : const Color(0xFF0A6E66),
        BanknoteTier.big => isDark ? const Color(0xFF8FBEF2) : const Color(0xFF1D5FB0),
        BanknoteTier.huge => isDark ? const Color(0xFFC0A6F9) : const Color(0xFF6D3FD1),
        BanknoteTier.whale => isDark ? const Color(0xFFF2C86B) : const Color(0xFF9A6A00),
      };
}

extension TierSpec on BanknoteTier {
  // (width, height) of the note.
  Size get size => switch (this) {
        BanknoteTier.dust => const Size(150, 92),
        BanknoteTier.small => const Size(188, 108),
        BanknoteTier.big => const Size(228, 124),
        BanknoteTier.huge => const Size(272, 144),
        BanknoteTier.whale => const Size(330, 172),
      };

  String get label => switch (this) {
        BanknoteTier.dust => 'DUST',
        BanknoteTier.small => 'SMALL',
        BanknoteTier.big => 'BIG',
        BanknoteTier.huge => 'HUGE',
        BanknoteTier.whale => 'WHALE',
      };

  /// The rule that put a coin in this tier, for the details sheet.
  String get rule => switch (this) {
        BanknoteTier.dust => 'At or under $kDustSats sats — costs more to '
            'spend than it is worth',
        BanknoteTier.small => 'Under ${(kBigShare * 100).round()}% of what '
            'you hold in this asset',
        BanknoteTier.big => '${(kBigShare * 100).round()}–'
            '${(kHugeShare * 100).round()}% of what you hold in this asset',
        BanknoteTier.huge => 'Over ${(kHugeShare * 100).round()}% of what '
            'you hold in this asset',
        BanknoteTier.whale => 'A whole coin or more',
      };

  double get amountFontSize => switch (this) {
        BanknoteTier.dust => 14,
        BanknoteTier.small => 16,
        BanknoteTier.big => 19,
        BanknoteTier.huge => 22,
        BanknoteTier.whale => 26,
      };
}

// ── Small shared pieces ───────────────────────────────────────────────────────

/// The "i" on every coin: a way to the details sheet that does not toggle
/// the selection. A 48 dp square on a phone, a compact glyph on desktop.
class UtxoInfoButton extends StatelessWidget {
  const UtxoInfoButton({super.key, required this.onPressed, this.color});

  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final tint = color ?? s.inkFaint;
    return Semantics(
      button: true,
      label: 'Coin details',
      child: Tooltip(
        message: 'Details',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: phone ? AppLayout.minTouchTarget : 28,
              height: phone ? AppLayout.minTouchTarget : 28,
              child: Icon(
                Icons.info_outline_rounded,
                size: phone ? 20 : 16,
                color: tint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The share-of-holdings bar — the one figure this screen was asked to
/// make loud. Tier-coloured fill on a faint track; never thinner than a
/// sliver so a crumb still reads as "a little", not "nothing".
class ShareMeter extends StatelessWidget {
  const ShareMeter({
    super.key,
    required this.share,
    required this.color,
    this.height = 4,
  });

  final double share;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: s.edgeStrong.withValues(alpha: 0.45)),
            AnimatedFractionallySizedBox(
              duration: AppMotion.of(context, AppMotion.emphasized),
              curve: AppMotion.settle,
              alignment: Alignment.centerLeft,
              widthFactor: share.clamp(0.02, 1.0),
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// `BIG · 12%` — the tier and the share it comes from, in the tier's ink.
/// One tag rather than two: the size of the note and the percentage are the
/// same fact, and reading them apart invited the question "why is this big?".
class TierTag extends StatelessWidget {
  const TierTag({
    super.key,
    required this.tier,
    required this.share,
    required this.color,
    this.fontSize = 9,
  });

  final BanknoteTier tier;
  final double share;
  final Color color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: tier.label),
          TextSpan(
            text: ' · ${utxoShareText(share)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: color.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.caption.copyWith(
        color: color,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.0,
        fontSize: fontSize,
      ),
    );
  }
}

// ── Provisional notes ─────────────────────────────────────────────────────────

/// The grey note that stands in for money that is not settled yet: a
/// consolidation waiting for its block, or a payment that has reached the
/// mempool and not the chain. Deliberately colourless — a tier colour would
/// claim a settled coin of that size, and until a block says so there is no
/// such coin.
class ProvisionalNote extends StatelessWidget {
  const ProvisionalNote({
    super.key,
    required this.title,
    required this.displayAmount,
    required this.caption,
    required this.serial,
    this.size = const Size(272, 144),
    this.onInfo,
  });

  /// What is happening: "Consolidating", "Incoming".
  final String title;
  final String displayAmount;

  /// One line under the amount saying what it waits for.
  final String caption;

  /// The txid or outpoint, shortened.
  final String serial;
  final Size size;

  /// Opens the details sheet, when there is one to open.
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final grey = s.isDark ? const Color(0xFF8B8B93) : const Color(0xFF7A7A84);

    return Container(
      width: size.width,
      constraints: BoxConstraints(minHeight: size.height),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: s.isDark
            ? Color.alphaBlend(grey.withValues(alpha: 0.10), AppColors.surfaceDark)
            : Color.alphaBlend(grey.withValues(alpha: 0.10), Colors.white),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        // Dashed would be truer to "not settled yet", but Flutter has no dashed
        // border primitive; a muted solid hairline reads as provisional next to
        // the confident double borders on real notes.
        border: Border.all(color: grey.withValues(alpha: 0.45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(grey),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: AppTypography.navSection.copyWith(color: grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onInfo != null) UtxoInfoButton(onPressed: onInfo!, color: grey),
            ],
          ),
          // NOT a Spacer: this Column is mainAxisSize.min inside a container
          // that sets minHeight, so the incoming height is unbounded and any
          // flex child asserts ("non-zero flex but incoming height constraints
          // are unbounded"). UtxoBanknote has the same shape for the same
          // reason — the note grows with its content.
          const SizedBox(height: AppSpacing.md),
          Amount(
            displayAmount,
            style: AppTypography.numericLarge.copyWith(color: s.inkSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            caption,
            style: AppTypography.caption.copyWith(color: s.inkFaint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            serial,
            style: AppTypography.monoSmall.copyWith(color: s.inkFaint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// The placeholder that stands in for coins being merged.
///
/// The moment a consolidation is broadcast the coins it spends are gone as far
/// as the user's intent is concerned, so the wall shows one grey note where
/// they were rather than N notes that are already spent.
class ConsolidatingNote extends StatelessWidget {
  const ConsolidatingNote({
    super.key,
    required this.count,
    required this.displayAmount,
    required this.txid,
    this.size = const Size(272, 144),
  });

  /// How many coins are being merged into this one.
  final int count;

  /// Sum of the inputs — shown as an approximation, since the fee comes out of
  /// it and the exact figure only exists once the transaction confirms.
  final String displayAmount;

  final String txid;
  final Size size;

  @override
  Widget build(BuildContext context) => ProvisionalNote(
        title: 'Consolidating',
        displayAmount: displayAmount,
        caption: '$count coins → 1 · waiting for confirmation',
        serial: txid.length > 12 ? '${txid.substring(0, 12)}…' : txid,
        size: size,
      );
}

/// An incoming coin the chain has not confirmed: the same grey note a
/// consolidation in flight gets, because it is the same situation — money
/// on its way that no block has counted yet.
class PendingCoinNote extends StatelessWidget {
  const PendingCoinNote({
    super.key,
    required this.utxo,
    required this.share,
    this.size = const Size(228, 124),
    this.compact = false,
  });

  final Utxo utxo;
  final double share;
  final Size size;

  /// Full-width phone note.
  final bool compact;

  @override
  Widget build(BuildContext context) => ProvisionalNote(
        title: 'Incoming',
        displayAmount: utxo.displayAmount,
        caption: 'Waiting for confirmation',
        serial: compact ? utxo.midOutpoint : utxo.shortOutpoint,
        size: compact ? const Size(double.infinity, 84) : size,
        onInfo: () => showUtxoDetails(
          context,
          utxo: utxo,
          share: share,
          tier: utxoTier(utxo, share),
        ),
      );
}

// ── Banknote ──────────────────────────────────────────────────────────────────

/// One UTXO rendered as a banknote — size follows its tier.
class UtxoBanknote extends StatelessWidget {
  const UtxoBanknote({
    super.key,
    required this.utxo,
    required this.tier,
    required this.onTap,
    this.share = 0,
    this.compact = false,
    this.onToggleFrozen,
  });
  final Utxo utxo;
  final BanknoteTier tier;
  final VoidCallback onTap;

  /// Freezes or unfreezes this coin from its details sheet. Only the coin
  /// screen passes it; a picker shows the sheet without the button.
  final VoidCallback? onToggleFrozen;

  /// Share of the asset's holdings — printed next to the tier and drawn as
  /// the meter under the amount.
  final double share;

  /// Phone rendering: every note is a full-width card of the same shape, and
  /// the denomination tier is carried by a coloured left rail, the tier label
  /// and the amount size instead of by the note's width. Proportional
  /// banknotes (150–330 dp) only make sense on a wall wide enough to hold
  /// several per row; in a 379 dp column they become a ragged single column
  /// with up to 150 dp of dead space per row.
  final bool compact;

  void _details(BuildContext context) => showUtxoDetails(
        context,
        utxo: utxo,
        share: share,
        tier: tier,
        onToggleFrozen: onToggleFrozen,
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelected = utxo.isSelected;
    final size = tier.size;

    // Banknote paper colour follows the SIZE tier (dust slate → whale gold);
    // the asset stays identified by its logo.
    final base = tier.base(isDark);
    final textColor = tier.text(isDark);

    final stateBadge = utxoStateBadge(utxo.state);

    final paper = isDark
        ? [
            Color.alphaBlend(base.withValues(alpha: 0.18), AppColors.surfaceDark),
            Color.alphaBlend(base.withValues(alpha: 0.06), AppColors.surfaceDark2),
          ]
        : [
            Color.alphaBlend(base.withValues(alpha: 0.10), Colors.white),
            Color.alphaBlend(base.withValues(alpha: 0.22), Colors.white),
          ];

    if (compact) {
      return _compact(
        context,
        base: base,
        textColor: textColor,
        paper: paper,
        stateBadge: stateBadge,
        isDark: isDark,
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size.width,
        // Minimum height keeps the banknote proportions but lets the card grow
        // rather than overflow when content is taller (e.g. small/dust notes).
        constraints: BoxConstraints(minHeight: size.height),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: paper,
          ),
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          // Double border evokes a banknote frame.
          border: Border.all(
            color: isSelected ? base : base.withValues(alpha: 0.55),
            width: isSelected ? 2.5 : 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: base.withValues(alpha: isSelected ? 0.30 : 0.12),
              blurRadius: isSelected ? 16 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: denomination + share, logo, details, select check.
            Row(
              children: [
                Expanded(
                  child: TierTag(tier: tier, share: share, color: textColor),
                ),
                const SizedBox(width: AppSpacing.xs),
                AssetLogo(ticker: utxo.ticker ?? 'BTC', size: 20),
                const SizedBox(width: 2),
                UtxoInfoButton(
                  onPressed: () => _details(context),
                  color: textColor.withValues(alpha: 0.8),
                ),
                if (isSelected) ...[
                  const SizedBox(width: 2),
                  Icon(Icons.check_circle, size: 16, color: base),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // Centre: denomination amount.
            Amount(
              utxo.displayAmount,
              style: AppTypography.balanceMedium.copyWith(
                fontSize: tier.amountFontSize,
                fontWeight: FontWeight.w800,
                color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.sm),
            // The share, drawn: the same bar the list has, so the two views
            // agree on how much of the wallet this note is.
            ShareMeter(share: share, color: base, height: 3),
            const SizedBox(height: AppSpacing.sm),
            // Bottom: serial number (outpoint) + state.
            Row(
              children: [
                Expanded(
                  child: Text(
                    utxo.shortOutpoint,
                    style: AppTypography.monoSmall.copyWith(
                      color: textColor.withValues(alpha: 0.8),
                      letterSpacing: 0.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (stateBadge != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  utxoStateChip(stateBadge),
                ],
              ],
            ),
            // The user's own tag, on every tier: the same chip the list row
            // wears, in the note's ink, so a note and its row read alike.
            if (utxo.label case final label?)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs + 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TagChip(label: label, color: base),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Full-width phone note: tier rail on the left, amount fitted (never
  /// ellipsised — it is the one figure the card exists for), serial and
  /// label wrapping beneath. The whole card is the tap target (≥ 64 dp);
  /// the details button on the right is its own 48 dp target.
  Widget _compact(
    BuildContext context, {
    required Color base,
    required Color textColor,
    required List<Color> paper,
    required (BadgeVariant, String, IconData?)? stateBadge,
    required bool isDark,
  }) {
    final isSelected = utxo.isSelected;
    final amountSize = switch (tier) {
      BanknoteTier.dust => 15.0,
      BanknoteTier.small => 16.0,
      BanknoteTier.big => 18.0,
      BanknoteTier.huge => 20.0,
      BanknoteTier.whale => 22.0,
    };
    return Semantics(
      button: true,
      selected: isSelected,
      label: '${tier.label} coin ${utxo.displayAmount}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: double.infinity,
            constraints:
                const BoxConstraints(minHeight: AppLayout.minTouchTarget + 16),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: paper,
              ),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(
                color: isSelected ? base : base.withValues(alpha: 0.55),
                width: isSelected ? 2 : 1.2,
              ),
            ),
            child: Stack(
              children: [
                // Tier rail — stands in for the width the desktop note has.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 5,
                  child: ColoredBox(
                    color: base.withValues(alpha: isSelected ? 1.0 : 0.7),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: TierTag(
                                    tier: tier,
                                    share: share,
                                    color: textColor,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                AssetLogo(
                                    ticker: utxo.ticker ?? 'BTC', size: 18),
                              ],
                            ),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Amount(
                                utxo.displayAmount,
                                style: AppTypography.balanceMedium.copyWith(
                                  fontSize: amountSize,
                                  fontWeight: FontWeight.w800,
                                  color: isDark
                                      ? AppColors.textPrimaryDark
                                      : AppColors.textPrimary,
                                ),
                                maxLines: 1,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ShareMeter(share: share, color: base, height: 3),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  utxo.midOutpoint,
                                  style: AppTypography.monoSmall.copyWith(
                                    color: textColor.withValues(alpha: 0.85),
                                  ),
                                ),
                                if (stateBadge != null)
                                  utxoStateChip(stateBadge),
                                if (utxo.label != null)
                                  TagChip(label: utxo.label!, color: base),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UtxoInfoButton(
                            onPressed: () => _details(context),
                            color: textColor.withValues(alpha: 0.8),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Icon(
                            isSelected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 22,
                            color: isSelected
                                ? base
                                : textColor.withValues(alpha: 0.5),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── List ──────────────────────────────────────────────────────────────────────

/// Fixed desktop column widths, shared by the rows and the header above
/// them so the two never drift apart.
abstract final class CoinColumns {
  static const double check = 22;
  static const double tile = 34;
  static const double state = 96;
  static const double share = 118;
  static const double amount = 150;
  static const double info = 28;

  /// Where the text starts, past the check and the tile — the dividers are
  /// indented to here so the card reads as one object with a glyph column.
  static const double textInset =
      AppSpacing.lg + check + AppSpacing.md + tile + AppSpacing.md;
}

/// The card a run of [CoinRow]s sits on: one panel, hairlines between rows,
/// indented past the glyph column. Repeated things are one object
/// (design.md); a stack of bordered cards was a stack of objects.
class CoinListCard extends StatelessWidget {
  const CoinListCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: phone ? s.panel : s.surfaceSolid,
        borderRadius: BorderRadius.circular(
          phone ? AppSpacing.radiusLg : AppSpacing.radiusMd,
        ),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: s.edge,
                indent: phone ? _phoneTextInset : CoinColumns.textInset,
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Phone: card inset + check + tile + gaps.
const double _phoneTextInset =
    AppSpacing.cardPaddingSmall + 22 + AppSpacing.sm + 40 + AppSpacing.md;

/// One coin in the list view — a row of the [CoinListCard]: check, tier
/// glyph tile, outpoint and tag, state, share (bold, with its meter), amount,
/// and the details button.
///
/// A pending coin draws as a row of the same shape with a spinner in its
/// tile and no check: it is listed so the wallet shows what is on its way,
/// and it cannot be picked until a block includes it.
class CoinRow extends StatefulWidget {
  const CoinRow({
    super.key,
    required this.utxo,
    required this.share,
    required this.onTap,
    this.showShare = true,
    this.compact,
    this.allowPending = false,
    this.lockFrozen = false,
    this.onToggleFrozen,
  });

  final Utxo utxo;
  final double share;
  final VoidCallback onTap;

  /// A frozen coin cannot be picked. On where picking means spending (the
  /// send wizard's coin picker); off on the coin screen, where a frozen coin
  /// is selected to be tagged or unfrozen.
  final bool lockFrozen;

  /// Freezes or unfreezes this coin from its details sheet (coin screen
  /// only).
  final VoidCallback? onToggleFrozen;

  /// Let a pending coin be selected. Off by default — the coin screen
  /// waits for a block — and on where the engine really can spend an
  /// unconfirmed output (the LiquiDEX offer flow, whose "create exact coin"
  /// lands unconfirmed and must be pickable at once). The row still wears
  /// its spinner and Pending chip either way.
  final bool allowPending;

  /// Hide the share meter + percentage (Liquid rows: shares across mixed
  /// assets read as noise).
  final bool showShare;

  /// Two-line stacked row instead of the fixed-column row. The desktop row
  /// carries fixed columns, which no phone column can hold; the stacked row
  /// has no fixed widths at all. `null` (the default) resolves from
  /// [AppLayout.isPhone], so every caller — including the send wizard's
  /// picker inside a 337 dp FormCard — gets the right layout without
  /// changes; desktop always gets the row.
  final bool? compact;

  @override
  State<CoinRow> createState() => _CoinRowState();
}

class _CoinRowState extends State<CoinRow> {
  bool _hover = false;

  Utxo get u => widget.utxo;
  bool get pending => u.isPending;

  /// No check, no tap: pending and not allowed, or frozen where picking
  /// would mean spending.
  bool get locked =>
      (pending && !widget.allowPending) || (widget.lockFrozen && u.isFrozen);
  BanknoteTier get tier => utxoTier(u, widget.share);

  void _details() => showUtxoDetails(
        context,
        utxo: u,
        share: widget.share,
        tier: tier,
        onToggleFrozen: widget.onToggleFrozen,
      );

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final base = pending ? s.inkFaint : tier.base(s.isDark);
    final stateBadge = utxoStateBadge(u.state);

    if (widget.compact ?? AppLayout.isPhone(context)) {
      return _compactRow(context, s: s, base: base, stateBadge: stateBadge);
    }
    return _desktopRow(context, s: s, base: base, stateBadge: stateBadge);
  }

  /// The tier glyph tile: one inset square, one coloured glyph — the list
  /// grammar every other row in the app follows. A pending coin gets a
  /// spinner instead of the glyph, a frozen one the snowflake.
  Widget _tile(AppScheme s, Color base, double size) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: s.panelInset,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: pending
          ? SizedBox(
              width: size * 0.42,
              height: size * 0.42,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(base),
              ),
            )
          : Icon(
              u.isFrozen ? kFrozenIcon : Icons.toll_rounded,
              size: size * 0.52,
              color: base,
            ),
    );
  }

  Widget _check(AppScheme s, Color base, double size) {
    final selected = u.isSelected;
    if (locked) return SizedBox(width: size);
    return SizedBox(
      width: size,
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, AppMotion.quick),
        switchInCurve: AppMotion.spring,
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: Icon(
          selected ? Icons.check_circle : Icons.radio_button_unchecked,
          key: ValueKey(selected),
          size: size,
          color: selected ? base : s.inkFaint,
        ),
      ),
    );
  }

  Widget _desktopRow(
    BuildContext context, {
    required AppScheme s,
    required Color base,
    required (BadgeVariant, String, IconData?)? stateBadge,
  }) {
    final selected = u.isSelected;
    final shareText = utxoShareText(widget.share);
    final row = Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          _check(s, base, CoinColumns.check),
          const SizedBox(width: AppSpacing.md),
          _tile(s, base, CoinColumns.tile),
          const SizedBox(width: AppSpacing.md),
          // Coin: outpoint + optional label chip, or "Incoming" for a coin
          // still on its way.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (pending)
                  Text(
                    'Incoming · waiting for confirmation',
                    style: AppTypography.bodySmall.copyWith(
                      color: s.inkSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                Text(
                  u.shortOutpoint,
                  style: AppTypography.monoSmall.copyWith(
                    color: pending ? s.inkFaint : s.ink,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (u.label != null) ...[
                  const SizedBox(height: 3),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TagChip(label: u.label!, color: base),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // State chip — only for the states that matter (frozen / dust /
          // pending). The column keeps its width either way so amounts stay
          // on one axis.
          SizedBox(
            width: CoinColumns.state,
            child: Align(
              alignment: Alignment.centerLeft,
              child: stateBadge == null
                  ? const SizedBox.shrink()
                  : utxoStateChip(stateBadge),
            ),
          ),
          // Share of holdings — the figure this list leads with: the
          // percentage in the tier's ink, its bar under it.
          SizedBox(
            width: CoinColumns.share,
            child: widget.showShare
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        shareText,
                        style: AppTypography.numericSmall.copyWith(
                          color: pending ? s.inkFaint : base,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 5),
                      ShareMeter(share: widget.share, color: base),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: AppSpacing.lg),
          SizedBox(
            width: CoinColumns.amount,
            child: Amount(
              u.displayAmount,
              textAlign: TextAlign.end,
              style: AppTypography.numericSmall.copyWith(
                color: pending ? s.inkSecondary : s.ink,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: CoinColumns.info,
            child: UtxoInfoButton(onPressed: _details),
          ),
        ],
      ),
    );

    final selectedTint = Color.alphaBlend(base.withValues(alpha: 0.10), s.surfaceSolid);
    return MouseRegion(
      onEnter: locked ? null : (_) => setState(() => _hover = true),
      onExit: locked ? null : (_) => setState(() => _hover = false),
      cursor: locked ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: locked ? null : widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.quick),
          curve: AppMotion.settle,
          decoration: BoxDecoration(
            // Selection is a wash of the tier's colour across the row and a
            // rail on its edge — state, not decoration.
            color: selected
                ? selectedTint
                : (_hover ? s.hover : Colors.transparent),
            border: Border(
              left: BorderSide(
                color: selected ? base : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: row,
        ),
      ),
    );
  }

  /// Phone row. Line 1: check, tier tile, amount (fitted, never ellipsised).
  /// Line 2: middle-ellipsised outpoint, state chip. Then the share bar
  /// across the row with the percentage at its end, and the label chip. No
  /// hover state — the ripple is the press feedback, and the whole row
  /// (≥ 56 dp) is the hit area of its checkbox; the details button is its
  /// own 48 dp target.
  Widget _compactRow(
    BuildContext context, {
    required AppScheme s,
    required Color base,
    required (BadgeVariant, String, IconData?)? stateBadge,
  }) {
    final selected = u.isSelected;
    final shareText = utxoShareText(widget.share);
    final body = Container(
      constraints: const BoxConstraints(minHeight: AppLayout.minTouchTarget + 8),
      color: selected
          ? Color.alphaBlend(base.withValues(alpha: 0.10), Colors.transparent)
          : Colors.transparent,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.cardPaddingSmall,
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _check(s, base, 22),
          const SizedBox(width: AppSpacing.sm),
          _tile(s, base, 40),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Amount(
                    u.displayAmount,
                    style: AppTypography.numeric.copyWith(
                      color: pending ? s.inkSecondary : s.ink,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      pending ? 'Incoming · ${u.midOutpoint}' : u.midOutpoint,
                      style: AppTypography.monoSmall.copyWith(
                        color: s.inkSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                    if (stateBadge != null) utxoStateChip(stateBadge),
                    if (u.label != null) TagChip(label: u.label!, color: base),
                  ],
                ),
                if (widget.showShare) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: ShareMeter(
                          share: widget.share,
                          color: base,
                          height: 4,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        shareText,
                        style: AppTypography.numericSmall.copyWith(
                          color: pending ? s.inkFaint : base,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          UtxoInfoButton(onPressed: _details),
        ],
      ),
    );
    return Semantics(
      button: !locked,
      selected: selected,
      label: pending
          ? 'Incoming coin ${u.displayAmount}, waiting for confirmation'
          : u.isFrozen
              ? 'Frozen coin ${u.displayAmount}'
              : 'Coin ${u.displayAmount}',
      child: Material(
        type: MaterialType.transparency,
        child: locked ? body : InkWell(onTap: widget.onTap, child: body),
      ),
    );
  }
}

/// Embeddable coin-control picker: banknotes/list toggle + selection stats.
/// The send wizard uses this for manual input selection; state (which coins
/// are selected) lives in the parent via [Utxo.isSelected] + [onToggle].
class UtxoPicker extends StatefulWidget {
  const UtxoPicker({
    super.key,
    required this.utxos,
    required this.onToggle,
    this.maxHeight = 420,
    this.allowPending = false,
  });

  /// The coins to pick from, selection carried by [Utxo.isSelected]. Frozen
  /// coins are shown so the total adds up, but cannot be picked.
  final List<Utxo> utxos;

  /// Called with the index (into [utxos]) of the tapped coin.
  final void Function(int index) onToggle;

  final double maxHeight;

  /// See [CoinRow.allowPending]. With it on, a pending coin is drawn as a
  /// banknote wearing a Pending chip rather than the grey provisional note.
  final bool allowPending;

  @override
  State<UtxoPicker> createState() => _UtxoPickerState();
}

class _UtxoPickerState extends State<UtxoPicker> {
  bool _notesView = false;

  /// Indices of [UtxoPicker.utxos] ordered biggest-first, so both views read
  /// as a value hierarchy (whale notes first). Selection callbacks still use
  /// the original indices.
  List<int> get _sortedIndices {
    final idx = List<int>.generate(widget.utxos.length, (i) => i);
    idx.sort((a, b) => widget.utxos[b].amount.compareTo(widget.utxos[a].amount));
    return idx;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final utxos = widget.utxos;
    final totals = utxoAssetTotals(utxos);
    final order = _sortedIndices;
    final phone = AppLayout.isPhone(context);
    final frozenCount = utxos.where((u) => u.isFrozen).length;

    // Icon-only segments explain themselves through a hover tooltip, which
    // a phone does not have; a phone gets the words. Both callers embed the
    // picker in a StepFlowScaffold, whose body already scrolls, so on a phone
    // the list sizes to its content instead of nesting a second scroll region
    // inside the page.
    final toggle = SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: false,
          icon: const Icon(Icons.view_list_outlined, size: 16),
          label: phone ? const Text('List') : null,
          tooltip: 'List',
        ),
        ButtonSegment(
          value: true,
          icon: const Icon(Icons.payments_outlined, size: 16),
          label: phone ? const Text('Notes') : null,
          tooltip: 'Banknotes',
        ),
      ],
      selected: {_notesView},
      onSelectionChanged: (v) => setState(() => _notesView = v.first),
      showSelectedIcon: false,
    );

    Widget note(int i) {
      final share = utxoShareOf(utxos[i], totals);
      if (utxos[i].isPending && !widget.allowPending) {
        return PendingCoinNote(utxo: utxos[i], share: share, compact: phone);
      }
      return UtxoBanknote(
        utxo: utxos[i],
        tier: utxoTier(utxos[i], share),
        share: share,
        onTap: utxos[i].isFrozen ? () {} : () => widget.onToggle(i),
        compact: phone,
      );
    }

    final list = CoinListCard(
      children: [
        for (final i in order)
          CoinRow(
            utxo: utxos[i],
            share: utxoShareOf(utxos[i], totals),
            onTap: () => widget.onToggle(i),
            compact: phone,
            allowPending: widget.allowPending,
            lockFrozen: true,
          ),
      ],
    );

    final Widget body;
    if (phone) {
      body = _notesView
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var n = 0; n < order.length; n++) ...[
                  if (n > 0) const SizedBox(height: AppSpacing.sm),
                  note(order[n]),
                ],
              ],
            )
          : list;
    } else {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: SingleChildScrollView(
          child: _notesView
              ? Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.lg,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [for (final i in order) note(i)],
                )
              : list,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              frozenCount > 0
                  ? '${utxos.length} coins · $frozenCount frozen'
                  : '${utxos.length} coins',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
            const Spacer(),
            toggle,
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        body,
      ],
    );
  }
}
