import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../features/dashboard/models/dashboard_data.dart';
import '../../services/asset_registry_service.dart';
import '../../services/issued_asset_store.dart';
import '../../shared/widgets/asset_card.dart';
import '../../shared/widgets/asset_logo.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/privacy.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
// The phone's Issue/Reissue/Burn rows live with the Asset Operations screen so
// both entry points show one object; the desktop card here stays local.
import 'asset_operations_screen.dart';

// ── Screen ───────────────────────────────────────────────────────────────────

class LiquidScreen extends StatefulWidget {
  const LiquidScreen({super.key});

  @override
  State<LiquidScreen> createState() => _LiquidScreenState();
}

class _LiquidScreenState extends State<LiquidScreen> {
  final _bridge = walletBridge;

  List<AssetBalance> _liquidAssets = [];
  Map<String, IssuedAssetEntry> _issuedAssets = {};
  List<String> _hiddenAssets = [];
  bool _showHidden = false;
  bool _loading = true;
  String? _error;
  int _lastSyncVersion = 0;
  String? _lastWalletId;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _appState = context.read<AppState>();
        _lastSyncVersion = _appState!.syncVersion;
        _lastWalletId = _appState!.activeWalletId;
        _appState!.addListener(_onAppStateChanged);
      }
    });
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    super.dispose();
  }

  void _onAppStateChanged() {
    final newVersion = _appState?.syncVersion ?? 0;
    final newWalletId = _appState?.activeWalletId;
    if ((newVersion != _lastSyncVersion || newWalletId != _lastWalletId) && mounted) {
      _lastSyncVersion = newVersion;
      _lastWalletId = newWalletId;
      setState(() => _loading = true);
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (context.read<AppState>().syncState == SyncState.syncing) return;
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    try {
      final data = await _bridge.getWalletSummary(walletId);
      // All Liquid assets: everything except native BTC
      final liquidAssets = data.assets.where((a) => a.ticker != 'BTC').toList();

      // Load local issued-asset store (scoped per wallet) + hidden list.
      final issued = await IssuedAssetStore.instance.getIssuedAssets(walletId);
      final hidden = await IssuedAssetStore.instance.getHiddenAssets();

      if (mounted) {
        setState(() {
          _liquidAssets = liquidAssets;
          _issuedAssets = issued;
          _hiddenAssets = hidden;
          _loading = false;
          _error = null;
        });
      }

      // Fetch Blockstream metadata in the background — doesn't block the screen.
      // Cache is never cleared so this only fetches IDs not already known.
      final ids = liquidAssets
          .where((a) => a.ticker != 'LBTC')
          .map((a) => a.assetId)
          .toList();
      if (ids.isNotEmpty) {
        AssetRegistryService.instance.prefetchAll(ids).then((_) {
          if (mounted) setState(() {}); // Re-render once metadata arrives
        });
      }
    } catch (e) {
      // A failed load is NOT "no assets" — keep the error so the balances
      // section shows a retry card instead of a lying empty state.
      if (mounted) {
        setState(() { _loading = false; _error = e.toString(); });
      }
    }
  }

  Future<void> _hideAsset(String assetId) async {
    await IssuedAssetStore.instance.hideAsset(assetId);
    final hidden = await IssuedAssetStore.instance.getHiddenAssets();
    if (mounted) setState(() => _hiddenAssets = hidden);
  }

  Future<void> _unhideAsset(String assetId) async {
    await IssuedAssetStore.instance.unhideAsset(assetId);
    final hidden = await IssuedAssetStore.instance.getHiddenAssets();
    if (mounted) setState(() => _hiddenAssets = hidden);
  }

  void _showDetail(AssetGroup group, {bool isRt = false}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Root navigator on a phone: the sheet must cover the carousel nav,
      // not stop above it inside the shell's nested navigator.
      useRootNavigator: AppLayout.isPhone(context),
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AssetDetailSheet(
        asset: group.main,
        isRt: isRt,
        reissuanceToken: group.reissuanceToken,
        blockstreamInfo: AssetRegistryService.instance.get(group.main.assetId),
        isHidden: _hiddenAssets.contains(group.main.assetId),
        onHide: () { Navigator.pop(context); _hideAsset(group.main.assetId); },
        onUnhide: () { Navigator.pop(context); _unhideAsset(group.main.assetId); },
        onTapToken: group.reissuanceToken != null
            ? () {
                Navigator.pop(context);
                _showDetail(AssetGroup(main: group.reissuanceToken!), isRt: true);
              }
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupAssets(_liquidAssets, _issuedAssets);
    final visible = _showHidden
        ? groups
        : groups.where((g) => !_hiddenAssets.contains(g.main.assetId)).toList();
    final hiddenCount = _hiddenAssets
        .where((id) => groups.any((g) => g.main.assetId == id))
        .length;

    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Scaffold(
      body: PageBackground.flat(
        child: ListView(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        children: [
          const PageHeader(
            title: 'Liquid',
            subtitle: 'Asset management on the Liquid Network',
            actions: [PrivacyToggle()],
          ),
          // Confidentiality signal — core property of Liquid, surfaced openly.
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: Row(
              children: [
                Icon(Icons.visibility_off_outlined,
                    size: 14, color: s.liquid),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Liquid uses confidential transactions: amounts and asset '
                    'types are blinded on-chain and visible only to this wallet.',
                    style: AppTypography.caption.copyWith(color: s.inkSecondary),
                  ),
                ),
              ],
            ),
          ),
          // ── Asset operations row ───────────────────────────────────────────
          _AssetOpsRow(),
          const SizedBox(height: AppSpacing.xl),
          // ── Liquid asset balances ──────────────────────────────────────────
          if (phone)
            // The label carries its own bottom padding; the show-hidden
            // toggle moves into the card below, where it survives every
            // asset being hidden and gets a full row to be tapped on.
            const ListSectionLabel(label: 'Liquid assets')
          else ...[
            Row(
              children: [
                Text(
                  'Liquid Assets',
                  style: AppTypography.sectionTitle.copyWith(color: s.ink),
                ),
                const Spacer(),
                if (hiddenCount > 0)
                  InkWell(
                    onTap: () => setState(() => _showHidden = !_showHidden),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs, vertical: 2),
                      child: Text(
                        _showHidden ? 'Hide hidden ($hiddenCount)' : 'Show hidden ($hiddenCount)',
                        style: AppTypography.caption.copyWith(color: s.liquid),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            _LoadError(
              message: _error!,
              onRetry: () {
                setState(() { _loading = true; _error = null; });
                _load();
              },
            )
          else if (phone)
            _phoneAssetList(context, visible, hiddenCount)
          else if (visible.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('No Liquid assets found', style: AppTypography.caption),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                // One column on a phone: a 183 dp card ellipsises balances.
                final minCols = AppLayout.isPhone(context) ? 1 : 2;
                final cols =
                    (constraints.maxWidth / 240).floor().clamp(minCols, 5);
                final cardWidth = (constraints.maxWidth - (cols - 1) * AppSpacing.md) / cols;
                return Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: visible
                      .map((g) => SizedBox(
                            width: cardWidth,
                            child: GroupedAssetCard(
                              group: g,
                              isHidden: _hiddenAssets.contains(g.main.assetId),
                              onTap: () => _showDetail(g),
                            ),
                          ))
                      .toList(),
                );
              },
            ),
        ],
        ),
      ),
    );
  }

  /// The phone's asset list: one card of rows, drawn exactly like the
  /// Dashboard's assets group so the same asset does not appear in two
  /// different materials one tap apart.
  ///
  /// The show-hidden toggle rides at the foot of the card rather than in the
  /// section label: it stays reachable when every asset is hidden (the list
  /// is then empty), and it gets a whole row instead of the 12 dp-tall text
  /// target the desktop header uses.
  Widget _phoneAssetList(
    BuildContext context,
    List<AssetGroup> visible,
    int hiddenCount,
  ) {
    final s = AppScheme.of(context);
    final masked = balancesHidden(context);
    return ListCard(
      children: [
        if (visible.isEmpty)
          // A row with no onTap is non-interactive — the Dashboard's own
          // empty-group pattern, so the section still has a shape.
          ListRow(
            icon: Icons.inbox_rounded,
            tint: s.inkFaint,
            title: 'No Liquid assets',
            subtitle: 'Assets you hold or issue appear here',
          )
        else
          for (final g in visible) _assetRow(context, g, masked),
        if (hiddenCount > 0)
          ListRow(
            // The eye shows the current state, never the action — the same
            // rule the PrivacyToggle follows (privacy.dart).
            icon: _showHidden
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            tint: s.inkFaint,
            title: _showHidden ? 'Hide hidden assets' : 'Show hidden assets',
            subtitle: '$hiddenCount hidden',
            onTap: () => setState(() => _showHidden = !_showHidden),
          ),
      ],
    );
  }

  Widget _assetRow(BuildContext context, AssetGroup g, bool masked) {
    final s = AppScheme.of(context);
    final reg = AssetRegistryService.instance;
    final asset = g.main;
    final hidden = _hiddenAssets.contains(asset.assetId);
    final ticker = reg.displayTicker(asset);
    final name = reg.displayName(asset);
    final info = reg.get(asset.assetId);
    final (value, unit) = _splitUnit(asset.displayAmount);
    return ListRow(
      // The two glyphs the Dashboard already uses for exactly these two
      // cases, so one asset is drawn one way across the phone.
      icon: asset.ticker == 'LBTC'
          ? Icons.currency_bitcoin
          : Icons.water_drop_rounded,
      tint: s.liquid,
      title: name == 'Unknown Asset' ? ticker : name,
      // The RT pill and the per-asset gradient tint are grid devices; in one
      // column the same facts read better as words.
      subtitle: <String>[
        if (info?.domain != null && info!.domain!.isNotEmpty)
          info.domain!
        else
          ticker,
        '${asset.utxoCount} UTXO${asset.utxoCount == 1 ? '' : 's'}',
        if (g.reissuanceToken != null) 'reissuance token',
        if (hidden) 'hidden',
      ].join(' · '),
      subtitleColor: hidden ? s.inkFaint : null,
      // ListAmount takes a plain String, so the mask is applied by hand here;
      // GroupedAssetCard masked internally through the Amount widget.
      trailing: ListAmount(
        value: masked ? kMaskedAmount : value,
        unit: masked ? null : (unit ?? ticker),
      ),
      chevron: true,
      onTap: () => _showDetail(g),
    );
  }
}

/// "1,000 FOO" → the number, and its unit. Mirrors the Dashboard's private
/// helper of the same name; a shared one belongs in list_rows.dart next to
/// ListAmount, which is not this pass's file to change.
(String, String?) _splitUnit(String text) {
  final i = text.lastIndexOf(' ');
  if (i <= 0) return (text, null);
  return (text.substring(0, i), text.substring(i + 1));
}

// ── Load failure ──────────────────────────────────────────────────────────────
// Replaces only the balances section; a failed load must not masquerade as
// "No Liquid assets found".

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: s.danger),
              const SizedBox(height: AppSpacing.md),
              Text('Could not load Liquid assets',
                  style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Retry',
                onPressed: onRetry,
                // A card's single action spans the card on a phone; on
                // desktop it stays the intrinsically sized button it was.
                isFullWidth: AppLayout.isPhone(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Asset Operations section ───────────────────────────────────────────────────

class _AssetOpsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Phone: one card of three rows instead of three bordered slabs (~250 dp
    // of chrome before a single balance appears), and the same object the
    // Asset Operations screen draws.
    if (AppLayout.isPhone(context)) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListSectionLabel(label: 'Asset operations'),
          AssetOpsRows(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Asset Operations', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.md),
        _OperationCard(
          icon: Icons.add_circle_outline,
          title: 'Issue Asset',
          description: 'Create a new Liquid asset with custom parameters.',
          color: AppColors.liquid,
          onTap: () => context.go(AppRoutes.issueAsset),
        ),
        const SizedBox(height: AppSpacing.md),
        _OperationCard(
          icon: Icons.refresh,
          title: 'Reissue',
          description: 'Mint additional supply of an existing asset you control.',
          color: AppColors.success,
          onTap: () => context.go(AppRoutes.reissueAsset),
        ),
        const SizedBox(height: AppSpacing.md),
        _OperationCard(
          icon: Icons.local_fire_department_outlined,
          title: 'Burn',
          description: 'Permanently destroy asset supply. This is irreversible.',
          color: AppColors.danger,
          onTap: () => context.go(AppRoutes.burnAsset),
        ),
      ],
    );
  }
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(
            color: isDark ? AppColors.borderDark : AppColors.borderLight,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTypography.label
                          .copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(description, style: AppTypography.caption),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

// ── Asset detail bottom sheet ─────────────────────────────────────────────────

class _AssetDetailSheet extends StatelessWidget {
  const _AssetDetailSheet({
    required this.asset,
    required this.blockstreamInfo,
    required this.isHidden,
    required this.onHide,
    required this.onUnhide,
    this.isRt = false,
    this.reissuanceToken,
    this.onTapToken,
  });

  final AssetBalance asset;
  final bool isRt;
  final AssetBalance? reissuanceToken;
  final VoidCallback? onTapToken;
  final BlockstreamAssetInfo? blockstreamInfo;
  final bool isHidden;
  final VoidCallback onHide;
  final VoidCallback onUnhide;

  void _copy(BuildContext context, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final isDark = s.isDark;
    final reg = AssetRegistryService.instance;
    final info = blockstreamInfo;
    final name = reg.displayName(asset, isRt: isRt);
    final ticker = reg.displayTicker(asset, isRt: isRt);
    // The sheet opens on both platforms (only useRootNavigator differs), so
    // every phone treatment below is gated.
    final phone = AppLayout.isPhone(context);

    return SheetSurface(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.pagePadding(context),
          AppSpacing.xl,
          AppSpacing.pagePadding(context),
          AppSpacing.xxl + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: s.edgeStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          // Header
          Row(
            children: [
              AssetBadge(ticker: ticker, isNative: asset.ticker == 'LBTC'),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: AppTypography.sectionTitle),
                    if (isRt)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.liquid.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'REISSUANCE TOKEN',
                          style: AppTypography.caption.copyWith(
                            color: AppColors.liquidDark,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    else
                      Text(ticker, style: AppTypography.caption),
                  ],
                ),
              ),
              Amount(
                asset.displayAmount,
                style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          const Divider(),
          const SizedBox(height: AppSpacing.lg),
          // Detail rows
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Row(
              children: [
                Icon(Icons.visibility_off_outlined,
                    size: 14, color: AppColors.liquid),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Confidential asset — amounts are blinded on-chain.',
                    style: AppTypography.caption
                        .copyWith(color: AppColors.liquidDark),
                  ),
                ),
              ],
            ),
          ),
          _DetailRow(
            label: 'Asset ID',
            value: asset.assetId,
            onCopy: () => _copy(context, asset.assetId),
          ),
          if (ticker.isNotEmpty && ticker != asset.assetId)
            _DetailRow(label: 'Ticker', value: ticker),
          if (info?.precision != null)
            _DetailRow(label: 'Precision', value: '${info!.precision}'),
          if (info?.domain != null)
            _DetailRow(label: 'Domain', value: info!.domain!),
          // Reissuance token section — only on parent assets.
          if (reissuanceToken != null) ...[
            const Divider(),
            const SizedBox(height: AppSpacing.md),
            // The phone row is titled 'Reissuance Token' itself, so the
            // heading above it would say the same thing twice.
            if (!phone) ...[
              Text(
                'Reissuance Token',
                style: AppTypography.label.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.liquidDark,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            if (phone)
              // It was a list row in everything but implementation: a
              // bespoke tinted box in a bare GestureDetector, with no
              // ripple. Icons.refresh is the glyph the RT pill and the
              // Reissue operation already use.
              ListCard(
                children: [
                  ListRow(
                    icon: Icons.refresh,
                    tint: s.liquid,
                    title: 'Reissuance Token',
                    subtitle: reg.displayTicker(reissuanceToken!, isRt: true),
                    trailing: ListAmount(
                      value: balancesHidden(context)
                          ? kMaskedAmount
                          : reissuanceToken!.displayAmount,
                    ),
                    chevron: onTapToken != null,
                    onTap: onTapToken,
                  ),
                ],
              )
            else
            GestureDetector(
              onTap: onTapToken,
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.liquid.withValues(alpha: isDark ? 0.12 : 0.07),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  border: Border.all(
                      color: AppColors.liquid.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    AssetLogo(
                        ticker: asset.ticker,
                        size: 28,
                        isReissuanceToken: true),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Reissuance Token',
                            style: AppTypography.bodySmall
                                .copyWith(fontWeight: FontWeight.w600),
                          ),
                          Amount(
                            reissuanceToken!.displayAmount,
                            style: AppTypography.caption,
                          ),
                        ],
                      ),
                    ),
                    if (onTapToken != null)
                      Icon(Icons.chevron_right,
                          size: 18,
                          color: AppColors.liquidDark.withValues(alpha: 0.7)),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          // Actions
          if (phone) ...[
            // Stacked and full width: side by side these two labels ellipsise
            // on a 379 dp column, and the phone's control decisions (54 dp,
            // filled, radius 16) arrive from buttons.dart instead of being
            // re-specified here. Copy leads because it is what this sheet is
            // opened for; hiding an asset is the rarer, stickier action.
            SecondaryButton(
              label: 'Copy ID',
              icon: Icons.copy,
              isFullWidth: true,
              onPressed: () => _copy(context, asset.assetId),
            ),
            const SizedBox(height: AppSpacing.md),
            SecondaryButton(
              label: isHidden ? 'Unhide' : 'Hide asset',
              icon: isHidden ? Icons.visibility : Icons.visibility_off,
              isFullWidth: true,
              onPressed: isHidden ? onUnhide : onHide,
            ),
          ] else
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: Icon(isHidden ? Icons.visibility : Icons.visibility_off,
                      size: 16),
                  label: Text(isHidden ? 'Unhide' : 'Hide asset'),
                  onPressed: isHidden ? onUnhide : onHide,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isHidden ? AppColors.success : AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy ID'),
                  onPressed: () => _copy(context, asset.assetId),
                ),
              ),
            ],
          ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.onCopy});
  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    // This sheet opens on desktop too, so the phone treatment is gated.
    // CopyRow already solved what this row hand-rolled badly on a phone: a
    // 64-hex asset ID wrapping to four mono lines behind a 14 px copy target.
    // It stacks the label, middle-ellipsises the value to one line, and gives
    // the copy control a 48 dp button with a copied confirmation.
    if (AppLayout.isPhone(context)) {
      return CopyRow(label: label, value: value, singleLine: onCopy != null);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: AppTypography.caption),
          ),
          Expanded(
            child: GestureDetector(
              onTap: onCopy,
              child: Text(
                value,
                style: AppTypography.mono.copyWith(fontSize: 12),
              ),
            ),
          ),
          if (onCopy != null)
            GestureDetector(
              onTap: onCopy,
              child: const Icon(Icons.copy, size: 14, color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}



