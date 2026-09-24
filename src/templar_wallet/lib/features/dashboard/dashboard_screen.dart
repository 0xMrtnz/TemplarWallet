import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/routes.dart';
import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../services/asset_registry_service.dart';
import '../../services/cosigner_label_store.dart';
import '../../services/issued_asset_store.dart';
import '../../services/price_history_service.dart';
import '../../services/price_service.dart';
import '../../shared/models/cosigner_label.dart';
import '../../shared/relative_time.dart';
import '../../shared/widgets/asset_card.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cosigner_label_editor.dart';
import '../../shared/widgets/cosigner_ring.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/privacy.dart';
import '../../shared/widgets/segmented_switch.dart';
import '../../shared/widgets/value_chart.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../wallet_info/models/wallet_info.dart';
import 'models/balance_history.dart';
import '../utxos/models/pending_consolidation.dart';
import '../../services/pending_consolidation_store.dart';
import 'models/dashboard_data.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _bridge = walletBridge;
  DashboardData? _data;
  WalletInfo? _walletInfo;
  BalanceHistory? _history;
  bool _historyFailed = false;
  List<String> _hiddenAssets = [];
  Map<String, IssuedAssetEntry> _issuedAssets = {};
  bool _showHidden = false;
  bool _loading = true;
  String? _error;

  /// A rebuild is in flight from the open-failure card.
  bool _repairing = false;
  int _lastSyncVersion = 0;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    final appState = context.read<AppState>();
    if (appState.cachedDashboard != null) {
      _data = appState.cachedDashboard;
      _loading = false;
    }
    _load();
    _loadHistory();
    // Refresh price on dashboard open
    PriceService.instance.fetch();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _appState = context.read<AppState>();
        _lastSyncVersion = _appState!.syncVersion;
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
    if (newVersion != _lastSyncVersion && mounted) {
      _lastSyncVersion = newVersion;
      _load();
      _loadHistory();
    }
  }

  /// Balance history feeds the hero chart only — it loads on its own so a slow
  /// or failing call never holds up the first paint of the dashboard.
  Future<void> _loadHistory() async {
    if (!mounted) return;
    if (context.read<AppState>().syncState == SyncState.syncing) return;
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    try {
      final history = await _bridge.getBalanceHistory(walletId);
      if (mounted) {
        setState(() {
          _history = history;
          _historyFailed = false;
        });
      }
    } catch (_) {
      // The chart shows its own empty state; nothing else on Home depends on it.
      if (mounted) setState(() => _historyFailed = true);
    }
  }

  /// Prepends rows for consolidations the wallet engine has not caught up
  /// with. Dropped automatically once a sync returns the real transaction,
  /// since the txid is then already in the summary.
  Future<DashboardData> _withPendingConsolidations(
      String walletId, DashboardData data) async {
    final List<PendingConsolidation> pending;
    try {
      pending = await PendingConsolidationStore.instance.listAllFor(walletId);
    } catch (_) {
      return data;
    }
    if (pending.isEmpty) return data;
    final known = data.recentActivity.map((t) => t.txid).toSet();
    final extra = pending
        .where((p) => !known.contains(p.txid))
        .map((p) => RecentActivityItem(
              txid: p.txid,
              direction: 'self',
              chain: p.chainKey,
              // Approximate: the real output is the inputs minus the fee.
              amount: '~${p.displayAmount}',
              ticker: p.ticker ?? 'BTC',
              timestamp: p.startedAt,
              confirmations: 0,
              note: p.activityNote,
            ))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (extra.isEmpty) return data;
    return data.withActivity([...extra, ...data.recentActivity]);
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (context.read<AppState>().syncState == SyncState.syncing) return;
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    // Never let a bridge failure strand the shimmer: an uncaught error here
    // would skip the setState below and leave Home permanently blank.
    DashboardData data;
    try {
      data = await _bridge.getWalletSummary(walletId);
    } catch (e) {
      if (mounted && _data == null) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
      return;
    }
    final liquidIds = data.assets
        .where((a) => a.ticker != 'BTC' && a.ticker != 'LBTC')
        .map((a) => a.assetId)
        .toList();
    if (liquidIds.isNotEmpty) {
      AssetRegistryService.instance.prefetchAll(liquidIds);
    }
    // A consolidation broadcast a minute ago is in no engine's history yet —
    // BDK picks it up on the next sync. Home would otherwise show the coins
    // gone from UTXOs and nothing at all here.
    data = await _withPendingConsolidations(walletId, data);
    final hidden = await IssuedAssetStore.instance.getHiddenAssets();
    final issued = await IssuedAssetStore.instance.getIssuedAssets(walletId);
    // Fingerprint + xpub for the hero badge — non-fatal if unavailable.
    WalletInfo? info;
    try {
      info = await _bridge.getWalletInfo(walletId);
    } catch (_) {}
    if (mounted) {
      context.read<AppState>().cachedDashboard = data;
      setState(() {
        _data = data;
        _walletInfo = info;
        _hiddenAssets = hidden;
        _issuedAssets = issued;
        _loading = false;
        _error = null;
      });
    }
  }

  void _reload() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }

  /// A multisig whose stored descriptor cannot be parsed is the one open
  /// failure the app can fix by itself: the cosigner keys are still in the
  /// registry, so the descriptor can be rebuilt from them. Every other
  /// failure here (a locked vault, a missing file) needs something else.
  bool get _canRepair {
    final state = context.read<AppState>();
    final multisig =
        (state.activeWalletType ?? '').toLowerCase().contains('multisig');
    final error = (_error ?? '').toLowerCase();
    // "Descriptor checksum mismatch" is BDK refusing a database that holds
    // another wallet's descriptor — the descriptor itself is fine, and a
    // rebuild would produce the same one.
    return multisig &&
        error.contains('descriptor') &&
        !error.contains('checksum');
  }

  Future<void> _repairWallet() async {
    final state = context.read<AppState>();
    final id = state.activeWalletId;
    if (id == null) return;
    setState(() => _repairing = true);
    try {
      await walletBridge.repairMultisigWallet(id);
      if (!mounted) return;
      setState(() => _repairing = false);
      _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _repairing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            'Could not repair: ${e.toString().replaceFirst('Exception: wallet-ffi: ', '')}'),
        backgroundColor: AppScheme.of(context).danger,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageBackground.flat(
        child: _loading
            ? const DashboardShimmer()
            : _data == null
                ? _DashboardError(
                    message: _error ?? 'Could not load the wallet.',
                    onRetry: _reload,
                    onRepair: _canRepair ? _repairWallet : null,
                    repairing: _repairing,
                  )
                : _DashboardContent(
                    data: _data!,
                    walletInfo: _walletInfo,
                    history: _history,
                    historyFailed: _historyFailed,
                    hiddenAssets: _hiddenAssets,
                    issuedAssets: _issuedAssets,
                    showHidden: _showHidden,
                    onToggleShowHidden: () =>
                        setState(() => _showHidden = !_showHidden),
                  ),
      ),
    );
  }
}

// ── Load failure ──────────────────────────────────────────────────────────────
// Shown only when the very first load fails (no cached data to fall back on),
// e.g. the wallet could not be opened. Offline is NOT such a case — opening and
// address derivation work without a network.

class _DashboardError extends StatelessWidget {
  const _DashboardError({
    required this.message,
    required this.onRetry,
    this.onRepair,
    this.repairing = false,
  });
  final String message;
  final VoidCallback onRetry;

  /// Offered only for the failure it actually fixes: a multisig whose stored
  /// descriptor does not parse. Null otherwise — a button that cannot help is
  /// worse than no button on a screen where nothing else works.
  final VoidCallback? onRepair;
  final bool repairing;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Center(
      // The ListView gutter does not apply on this branch: without it the
      // card's border touches both screen edges on a phone.
      child: Padding(
        padding: EdgeInsets.all(phone ? AppSpacing.lg : 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: GlassCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 40, color: s.danger),
                const SizedBox(height: AppSpacing.md),
                Text('Could not open this wallet',
                    style: AppTypography.sectionTitleOf(context)),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  style:
                      AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                  textAlign: TextAlign.center,
                ),
                if (onRepair != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'This wallet\'s descriptor was built from a key that could '
                    'not be used as it was written. The cosigner keys are still '
                    'here, so it can be rebuilt from them — same wallet, same '
                    'addresses, nothing to collect from your devices again.',
                    style:
                        AppTypography.caption.copyWith(color: s.inkSecondary),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                    label: 'Retry', onPressed: onRetry, isFullWidth: phone),
                if (onRepair != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  SecondaryButton(
                    label: repairing ? 'Repairing…' : 'Rebuild from the keys',
                    icon: Icons.healing_rounded,
                    isLoading: repairing,
                    isFullWidth: true,
                    onPressed: repairing ? null : onRepair,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.data,
    required this.walletInfo,
    required this.history,
    required this.historyFailed,
    required this.hiddenAssets,
    required this.issuedAssets,
    required this.showHidden,
    required this.onToggleShowHidden,
  });
  final DashboardData data;
  final WalletInfo? walletInfo;
  final BalanceHistory? history;
  final bool historyFailed;
  final List<String> hiddenAssets;
  final Map<String, IssuedAssetEntry> issuedAssets;
  final bool showHidden;
  final VoidCallback onToggleShowHidden;

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    return ListView(
      padding: phone
          ? const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg)
          : const EdgeInsets.all(AppSpacing.xl),
      children: [
        // The mobile shell's own header already names the wallet directly
        // above; repeating it here cost ~116 dp before the balance. The
        // network answer (TESTNET) moves into the hero's greeting row.
        if (!phone)
          Reveal(
            child: PageHeader(
              title: data.walletName,
              subtitle: 'Dashboard',
              actions: const [TestnetBadge()],
            ),
          ),
        Reveal(
          delay: 1,
          child: _BrandHero(
            data: data,
            walletInfo: walletInfo,
            history: history,
            historyFailed: historyFailed,
          ),
        ),
        // A shared wallet's keys, on the screen people actually open. The
        // same card on both layouts: it is one ring and a caption, and a
        // phone has room for exactly that.
        if ((walletInfo?.cosignerKeys.length ?? 0) > 1) ...[
          const SizedBox(height: AppSpacing.xl),
          Reveal(delay: 2, child: _CosignerCard(info: walletInfo!)),
        ],
        if (phone) ...[
          // One assets list and one activity list, both chains folded in. A
          // row already says which chain it belongs to — its glyph, its name
          // — so a panel per chain was saying it a second time and cost the
          // screen two headers, two balances and two "latest" lists.
          const SizedBox(height: AppSpacing.xl),
          Reveal(
            delay: 2,
            child: _PhoneAssets(
              data: data,
              issuedAssets: issuedAssets,
              hiddenAssets: hiddenAssets,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Reveal(delay: 3, child: _PhoneActivity(data: data)),
        ] else ...[
          const SizedBox(height: AppSpacing.lg),
          Reveal(
            delay: 2,
            child: _ChainSections(
              data: data,
              issuedAssets: issuedAssets,
              hiddenAssets: hiddenAssets,
              showHidden: showHidden,
              onToggleShowHidden: onToggleShowHidden,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Keys ────────────────────────────────────────────────────────────────────
// Who can sign for this wallet, in the place people look first. Until now a
// multisig's keys lived only on Wallet info, as raw `[fingerprint/path]tpub…`
// strings — accurate, and no help at all in answering "is my phone still one
// of these three".

class _CosignerCard extends StatefulWidget {
  const _CosignerCard({required this.info});

  final WalletInfo info;

  @override
  State<_CosignerCard> createState() => _CosignerCardState();
}

class _CosignerCardState extends State<_CosignerCard> {
  Map<String, CosignerLabel> _labels = const {};

  @override
  void initState() {
    super.initState();
    _loadLabels();
  }

  @override
  void didUpdateWidget(_CosignerCard old) {
    super.didUpdateWidget(old);
    if (old.info.id != widget.info.id) _loadLabels();
  }

  Future<void> _loadLabels() async {
    final labels = await CosignerLabelStore.instance.load(widget.info.id);
    if (mounted) setState(() => _labels = labels);
  }

  List<CosignerEntry> get _entries => resolveCosigners(
        cosignerKeys: widget.info.cosignerKeys,
        labels: _labels,
        localFingerprints: widget.info.localFingerprints,
      );

  Future<void> _openRoster([int? index]) async {
    await showCosignerRoster(
      context,
      entries: _entries,
      requiredSigs: widget.info.requiredSigs,
      initialIndex: index,
      onEdit: (entry) async {
        final edited = await showCosignerLabelEditor(
          context,
          label: entry.label,
          index: entry.index,
          subtitle: entry.fingerprint.isEmpty
              ? null
              : '${entry.fingerprint} · m/${entry.path}',
        );
        if (edited == null) return null;
        await CosignerLabelStore.instance.saveOne(widget.info.id, edited);
        await _loadLabels();
        // Hand the sheet the refreshed roster: it renders its own copy, and
        // the card behind it is not the thing the user is looking at.
        return _entries;
      },
    );
    // The roster edits labels in place, so the card behind it has to catch up
    // whether or not anything was changed.
    await _loadLabels();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final entries = _entries;
    final phone = AppLayout.isPhone(context);
    final shown = math.min(entries.length, maxRingIcons);

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Keys', style: AppTypography.sectionTitleOf(context)),
              ),
              TextButton(
                onPressed: () => _openRoster(),
                child: Text(entries.length > shown ? 'See all' : 'Details'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CosignerRing(
                entries: entries,
                requiredSigs: widget.info.requiredSigs,
                size: phone ? 124 : 138,
                onTapEntry: (e) => _openRoster(e.index),
                onTapMore: () => _openRoster(),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.info.requiredSigs == null
                          ? '${entries.length} keys'
                          : 'Any ${widget.info.requiredSigs} of '
                              '${entries.length} keys can sign.',
                      style: AppTypography.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    // The names, in order, so the ring's glyphs mean
                    // something without hovering every one of them.
                    for (final e in entries.take(maxRingIcons))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            Icon(e.label.icon,
                                size: 13, color: e.label.color ?? s.inkFaint),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                e.isLocal ? '${e.name} · this device' : e.name,
                                style: AppTypography.caption,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (entries.length > shown)
                      Text(
                        '+${entries.length - shown} more',
                        style:
                            AppTypography.caption.copyWith(color: s.inkFaint),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Brand hero ──────────────────────────────────────────────────────────────
// A time-of-day greeting, the whole-portfolio net worth as the headline (the
// wallet's name already sits in the page header above), the fingerprint as a
// small copyable identity line, and the primary actions.

class _BrandHero extends StatefulWidget {
  const _BrandHero({
    required this.data,
    required this.walletInfo,
    required this.history,
    required this.historyFailed,
  });
  final DashboardData data;
  final WalletInfo? walletInfo;
  final BalanceHistory? history;
  final bool historyFailed;

  @override
  State<_BrandHero> createState() => _BrandHeroState();
}

class _BrandHeroState extends State<_BrandHero> {
  /// Phone only: the headline shows the coin balance instead of the fiat
  /// estimate — and the chart follows it. One tap on the number swaps both,
  /// where the desktop keeps a separate unit switch under the chart.
  bool _coinFirst = false;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    // Pure watch-only wallets cannot sign — no Send anywhere.
    final watchOnly = context.watch<AppState>().isActiveWalletWatchOnly;

    final greeting = Text(
      _greeting.toUpperCase(),
      style: AppTypography.navSection.copyWith(
        color: s.inkSecondary,
        letterSpacing: 1.4,
      ),
    );

    if (phone) {
      // The wallet's front door, and the only tile on the page that is not a
      // list: what it is worth, what it did, and the two verbs. One eyebrow
      // names the figure and the network, the number owns the row, the chart
      // states the last stretch, and Send is the single filled control on the
      // screen. The greeting and the fingerprint are gone — the first was a
      // row of chrome above the balance, the second is identity and lives in
      // Settings › Wallet info.
      return HeroPanel(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.cardPaddingSmall + 2,
          AppSpacing.cardPaddingSmall,
          AppSpacing.cardPaddingSmall + 2,
          AppSpacing.cardPaddingSmall + 2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _HeroEyebrow(),
            const SizedBox(height: AppSpacing.xs),
            _PhoneBalance(
              assets: widget.data.assets,
              coinFirst: _coinFirst,
              onSwap: () => setState(() => _coinFirst = !_coinFirst),
              note: _lastMoveNote(widget.data.recentActivity),
            ),
            const SizedBox(height: AppSpacing.md),
            _PortfolioChart(
              history: widget.history,
              historyFailed: widget.historyFailed,
              fiatOverride: !_coinFirst,
            ),
            const SizedBox(height: AppSpacing.lg),
            _HeroActions(showSend: !watchOnly),
          ],
        ),
      );
    }

    final send = AccentButton(
      label: 'Send',
      icon: Icons.send,
      isFullWidth: phone,
      onPressed: () => context.go(AppRoutes.send),
    );
    final receive = SecondaryButton(
      label: 'Receive',
      icon: Icons.call_received,
      isFullWidth: phone,
      onPressed: () => context.go(AppRoutes.receive),
    );

    return HeroPanel(
      padding: EdgeInsets.all(
          phone ? AppSpacing.cardPaddingSmall : AppSpacing.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (phone)
                // The page header is gone on a phone; the network chip
                // takes the greeting row's right edge instead.
                Row(
                  children: [
                    Expanded(child: greeting),
                    const TestnetBadge(),
                  ],
                )
              else
                greeting,
              const SizedBox(height: AppSpacing.sm),
              _NetWorth(assets: widget.data.assets),
              if (widget.walletInfo != null) ...[
                const SizedBox(height: AppSpacing.xs),
                _WalletKeyBadge(info: widget.walletInfo!),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _PortfolioChart(
              history: widget.history, historyFailed: widget.historyFailed),
          SizedBox(height: phone ? AppSpacing.md : AppSpacing.lg),
          if (phone)
            // Two equal halves; Receive alone spans the width.
            Row(
              children: [
                if (!watchOnly) ...[
                  Expanded(child: send),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(child: receive),
              ],
            )
          else
            Row(
              children: [
                if (!watchOnly) ...[
                  send,
                  const SizedBox(width: AppSpacing.sm),
                ],
                receive,
              ],
            ),
        ],
      ),
    );
  }
}

// ── Net worth headline ────────────────────────────────────────────────────────
// Whole-portfolio value: the fiat sum of native coins (BTC + L-BTC) in the
// user's selected currency, with the Bitcoin-denominated equivalent beneath.
// Tokens without a price feed are shown in the assets grid but not valued here.
//
// Clicking the headline swaps the two lines: coin-denominated on top, fiat
// underneath. Fiat is an estimate from a third-party feed and the coin balance
// is the fact, so getting to the fact must never cost more than one click.
// The choice is per-visit state, not a preference — the settings toggle
// (BTC/sats) still decides *which* coin unit this shows.

class _NetWorth extends StatefulWidget {
  const _NetWorth({required this.assets});
  final List<AssetBalance> assets;

  @override
  State<_NetWorth> createState() => _NetWorthState();
}

class _NetWorthState extends State<_NetWorth> {
  /// Headline shows the coin balance instead of the fiat estimate.
  bool _coinFirst = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final useSats = context.select<AppState, bool>((st) => st.useSats);
    // Depend on the currency too so the headline rebuilds when it changes.
    context.select<AppState, String>((st) => st.fiatCurrency);
    final hidden = balancesHidden(context);
    final phone = AppLayout.isPhone(context);
    final nativeSats = widget.assets
        .where((a) => a.ticker == 'BTC' || a.ticker == 'LBTC')
        .fold<int>(0, (sum, a) => sum + a.amount);
    final price = PriceService.instance;
    return AnimatedBuilder(
      animation: price,
      builder: (_, _) {
        final unitStr = PriceService.formatUnit(nativeSats, sat: useSats);
        // With no price feed there is only one number to show, so the swap has
        // nothing to swap to and the headline stays plain text.
        final swappable = price.hasPrice;
        final showCoin = _coinFirst || !swappable;
        final headline = showCoin ? unitStr : price.totalFiatDisplay(nativeSats);
        final under = !swappable
            ? 'Net worth'
            : showCoin
                ? 'Net worth · ≈ ${price.totalFiatDisplay(nativeSats)}'
                : 'Net worth · ≈ $unitStr';

        Widget headlineText = GradientText(
          hidden ? kMaskedAmount : headline,
          style: phone
              ? AppTypography.balanceHeroOf(context)
              : AppTypography.balanceHero.copyWith(fontSize: 38),
          // One line on a phone: the FittedBox below scales it, never wraps.
          maxLines: phone ? 1 : null,
        );
        if (phone) {
          // A long sats figure scales down to the column instead of wrapping
          // the headline onto two lines.
          headlineText = FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: headlineText,
          );
        }
        if (swappable) {
          // Touch has no hover cursor or tooltip to say the number is
          // tappable, so on a phone a small swap glyph rides beside it.
          final body = phone
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: headlineText),
                    const SizedBox(width: AppSpacing.xs),
                    Icon(Icons.swap_vert_rounded, size: 18, color: s.inkFaint),
                  ],
                )
              : headlineText;
          headlineText = MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _coinFirst = !_coinFirst),
              behavior: HitTestBehavior.opaque,
              child: Tooltip(
                message: showCoin
                    ? 'Show ${price.currency}'
                    : 'Show ${useSats ? 'sats' : 'BTC'}',
                child: body,
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(child: headlineText),
                const SizedBox(width: AppSpacing.sm),
                const PrivacyToggle(size: 19),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              hidden && swappable ? 'Net worth · hidden' : under,
              style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
            ),
          ],
        );
      },
    );
  }
}

// ── Portfolio chart ───────────────────────────────────────────────────────────
// Native-coin balance over time, valued in fiat by default (matching the
// headline above) or shown as the raw coin balance. Everything is derived from
// two inputs: the wallet's balance history (a step function) and the BTC price
// series — neither of which is required for the hero to render.

enum _ChartRange {
  h24('24H', '1D', Duration(hours: 24), 1),
  d7('7D', '1W', Duration(days: 7), 7),
  d30('30D', '1M', Duration(days: 30), 30),
  d90('90D', '3M', Duration(days: 90), 90),
  y1('1Y', '1Y', Duration(days: 365), 365),
  all('All', 'ALL', null, 365);

  const _ChartRange(this.label, this.shortLabel, this.window, this.priceDays);

  final String label;

  /// The phone's word for the range: six of them share one row there.
  final String shortLabel;

  /// null = the whole history.
  final Duration? window;
  final int priceDays;
}

enum _ChainFilter { all, btc, liquid }

class _PortfolioChart extends StatefulWidget {
  const _PortfolioChart({
    required this.history,
    required this.historyFailed,
    this.fiatOverride,
  });
  final BalanceHistory? history;

  /// The history call failed — say so instead of loading forever.
  final bool historyFailed;

  /// Fiat or coin, decided outside (the phone hero's headline tap). Null
  /// leaves the choice to the unit switch under the chart, as on desktop.
  final bool? fiatOverride;

  @override
  State<_PortfolioChart> createState() => _PortfolioChartState();
}

class _PortfolioChartState extends State<_PortfolioChart> {
  _ChartRange _range = _ChartRange.d30;
  _ChainFilter _chain = _ChainFilter.all;
  bool _fiatMode = true;

  List<PricePoint> _prices = const [];
  bool _pricesLoaded = false;
  bool _fetchingPrices = false;
  String _pricesKey = '';

  List<ChartPoint>? _series;
  String _seriesKey = '';
  Timer? _edgeTimer;

  @override
  void initState() {
    super.initState();
    _syncEdgeTimer();
    _loadPrices();
    // The currency lives on PriceService; switching it invalidates the series.
    PriceService.instance.addListener(_onPriceServiceChanged);
  }

  @override
  void dispose() {
    _edgeTimer?.cancel();
    PriceService.instance.removeListener(_onPriceServiceChanged);
    super.dispose();
  }

  /// "Now" quantised so the memo key is stable between ticks. Short ranges
  /// advance by the minute; long ones by the hour, where a minute is invisible.
  DateTime _nowBucket() {
    final now = DateTime.now();
    final step = _range.window != null && _range.window! <= const Duration(days: 7)
        ? const Duration(minutes: 1)
        : const Duration(hours: 1);
    return DateTime.fromMillisecondsSinceEpoch(
      (now.millisecondsSinceEpoch ~/ step.inMilliseconds) * step.inMilliseconds,
    );
  }

  /// Keeps the right edge of a short-range chart current while Home stays open;
  /// longer ranges ride on the sync/price rebuilds already happening.
  void _syncEdgeTimer() {
    final live =
        _range.window != null && _range.window! <= const Duration(days: 7);
    if (live == (_edgeTimer != null)) return;
    _edgeTimer?.cancel();
    _edgeTimer = live
        ? Timer.periodic(const Duration(minutes: 1), (_) {
            if (mounted) setState(() {});
          })
        : null;
  }

  @override
  void didUpdateWidget(covariant _PortfolioChart old) {
    super.didUpdateWidget(old);
    // The "All" range asks for as many days of price as the history spans.
    if (old.history != widget.history) _loadPrices();
  }

  void _onPriceServiceChanged() => _loadPrices();

  /// Price days for the selected range. "All" walks up a ladder to the
  /// shortest series that still covers the wallet's history, so a young wallet
  /// does not download (and cache) a decade of prices it cannot use.
  int get _priceDays {
    if (_range.window != null) return _range.priceDays;
    final points = widget.history?.points ?? const <BalanceHistoryPoint>[];
    if (points.isEmpty) return 30;
    final span = DateTime.now().difference(points.first.time).inDays;
    for (final d in const [1, 7, 30, 90, 365]) {
      if (span <= d) return d;
    }
    return PriceHistoryService.allDays;
  }

  Future<void> _loadPrices() async {
    final currency = PriceService.instance.currency;
    final days = _priceDays;
    final key = '$currency|$days';
    // An empty series means offline/rate-limited, so a later price tick is
    // worth another try even though the key has not changed.
    final retryable = _pricesLoaded && _prices.isEmpty;
    if (_fetchingPrices || (key == _pricesKey && !retryable)) return;
    _fetchingPrices = true;
    _pricesKey = key;
    final series = await PriceHistoryService.instance
        .series(currency: currency, days: days);
    _fetchingPrices = false;
    if (!mounted) return;
    setState(() {
      _prices = series;
      _pricesLoaded = true;
    });
  }

  void _selectRange(_ChartRange r) {
    if (r == _range) return;
    setState(() => _range = r);
    _syncEdgeTimer();
    _loadPrices();
  }

  int _chainSats(BalanceHistoryPoint p) => switch (_chain) {
        _ChainFilter.all => p.btcSats + p.lbtcSats,
        _ChainFilter.btc => p.btcSats,
        _ChainFilter.liquid => p.lbtcSats,
      };

  int _currentSats(BalanceHistory h) => switch (_chain) {
        _ChainFilter.all => h.btcSats + h.lbtcSats,
        _ChainFilter.btc => h.btcSats,
        _ChainFilter.liquid => h.lbtcSats,
      };

  /// The balance step function clipped to the selected window, as
  /// (time, sats) pairs — always at least two samples.
  List<(DateTime, int)> _windowSamples(BalanceHistory h, DateTime now) {
    final points = h.points;
    final start = _range.window != null
        ? now.subtract(_range.window!)
        : (points.isNotEmpty
            ? points.first.time
            : now.subtract(const Duration(days: 30)));

    final out = <(DateTime, int)>[];
    int? carried;
    for (final p in points) {
      if (p.time.isBefore(start)) {
        carried = _chainSats(p);
        continue;
      }
      if (p.time.isAfter(now)) continue;
      out.add((p.time, _chainSats(p)));
    }
    // Balance before the window opened is the window's opening value —
    // without it a wallet that has not moved in 24h draws nothing at all.
    if (carried != null) out.insert(0, (start, carried));
    if (out.isEmpty) out.add((start, _currentSats(h)));
    out.add((now, _currentSats(h)));
    return out;
  }

  /// Fiat series: the balance is a step function, so resample onto an even
  /// grid — that is what makes the line move with price between transactions.
  List<ChartPoint> _fiatSeries(List<(DateTime, int)> samples, DateTime now) {
    final start = samples.first.$1;
    final spanMs = now.difference(start).inMilliseconds;
    final price = PriceHistoryService.instance;
    if (spanMs <= 0) {
      final sats = samples.last.$2;
      return [ChartPoint(now, sats / 1e8 * price.priceAt(now, _prices))];
    }
    const buckets = 120;
    final out = <ChartPoint>[];
    var index = 0;
    var held = samples.first.$2;
    for (var i = 0; i <= buckets; i++) {
      final t = start.add(Duration(milliseconds: spanMs * i ~/ buckets));
      while (index < samples.length && !samples[index].$1.isAfter(t)) {
        held = samples[index].$2;
        index++;
      }
      out.add(ChartPoint(t, held / 1e8 * price.priceAt(t, _prices)));
    }
    return out;
  }

  /// Built series, memoized on its inputs. [ValueChart] restarts its draw
  /// animation whenever the list identity changes, so an unrelated rebuild
  /// (a price tick, a sync notification) must hand back the very same list.
  List<ChartPoint> _seriesPoints(BalanceHistory? history, bool fiat) {
    // Keyed on content, not identity: a hash collision here would serve a
    // stale line for a different range or balance.
    final h = history;
    final hKey = h == null
        ? 'none'
        : '${h.points.length}.${h.btcSats}.${h.lbtcSats}.'
            '${h.points.isEmpty ? 0 : h.points.last.time.millisecondsSinceEpoch}';
    final pKey = _prices.isEmpty
        ? '0'
        : '${_prices.length}.${_prices.last.price}';
    final key = '$hKey|${_range.name}|${_chain.name}|$fiat|$pKey'
        '|${_nowBucket().millisecondsSinceEpoch}';
    final cached = _series;
    if (cached != null && key == _seriesKey) return cached;

    final List<ChartPoint> built;
    if (history == null) {
      built = const [];
    } else {
      final now = _nowBucket();
      final samples = _windowSamples(history, now);
      built = fiat
          ? _fiatSeries(samples, now)
          : [
              for (final (time, sats) in samples)
                ChartPoint(time, sats.toDouble()),
            ];
    }
    _series = built;
    _seriesKey = key;
    return built;
  }

  /// Percent change across the rendered series; null when it cannot be stated
  /// honestly (no history, or a zero opening value).
  double? _delta(List<ChartPoint> points) {
    if (points.length < 2) return null;
    final first = points.first.value;
    if (first <= 0) return null;
    return (points.last.value - first) / first * 100;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final useSats = context.select<AppState, bool>((st) => st.useSats);
    final hidden = balancesHidden(context);
    final history = widget.history;
    final phone = AppLayout.isPhone(context);

    return AnimatedBuilder(
      animation: PriceService.instance,
      builder: (context, _) {
        // Offline (or rate-limited): coin balance is still the truth, so show
        // that rather than an empty chart.
        final priceUnavailable = _pricesLoaded && _prices.isEmpty;
        // Until the series lands, priceAt falls back to the spot price. With
        // neither we would multiply every balance by zero and draw a flat $0
        // line, so stay on coin balance until some price exists. Computed
        // inside the builder so the arrival of the spot price re-evaluates it.
        final hasAnyPrice =
            _prices.isNotEmpty || PriceService.instance.btcPrice > 0;
        final fiatWanted = widget.fiatOverride ?? _fiatMode;
        final fiat = fiatWanted && !priceUnavailable && hasAnyPrice;
        final points = _seriesPoints(history, fiat);
        final symbol = PriceService.instance.symbol;
        // Only meaningful when the wallet actually has both chains.
        final bothChains =
            history != null && history.hasBitcoin && history.hasLiquid;

        final chart = ValueChart(
          height: phone ? 136 : 132,
          points: points,
          // A bare line at this size read as decoration. Three rules behind
          // it and a dot landing on the newest sample make it a chart, at no
          // cost in labels. Desktop keeps the plain line it always had.
          gridLines: phone ? 3 : 0,
          markLatest: phone,
          formatValue: (v) => hidden
              ? kMaskedAmount
              : fiat
                  ? _fiatLabel(v, symbol)
                  : PriceService.formatUnit(v.round(), sat: useSats),
          emptyMessage: history != null
              ? 'Not enough history yet'
              : widget.historyFailed
                  ? 'Balance history unavailable'
                  : 'Loading history…',
          // Replay the sweep only when the user changes the view, not on
          // the per-minute edge refresh.
          animationKey: '${_range.name}|${_chain.name}|$fiat',
        );
        final priceNote = fiatWanted && priceUnavailable
            ? Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Price history unavailable — showing coin balance',
                  style: AppTypography.caption.copyWith(color: s.inkFaint),
                ),
              )
            : null;

        if (phone) {
          // The chart first, then one row of words for the range with the
          // change over it at the right, and — only when the wallet has
          // both chains — a second, quieter row to pick one. The unit is
          // not here: the headline above decides it for both. Bordered
          // tracks with eleven cells stood between the balance and the
          // actions; words in a row do not.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              chart,
              ?priceNote,
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _TextChips<_ChartRange>(
                      selected: _range,
                      onChanged: _selectRange,
                      spread: true,
                      options: [
                        for (final r in _ChartRange.values)
                          (r, r.shortLabel, null),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _DeltaReadout(
                    delta: _delta(points),
                    rangeLabel: _range.shortLabel,
                    showRange: false,
                  ),
                ],
              ),
              if (bothChains) ...[
                const SizedBox(height: AppSpacing.xs),
                _TextChips<_ChainFilter>(
                  selected: _chain,
                  onChanged: (v) => setState(() => _chain = v),
                  options: [
                    (_ChainFilter.all, 'All', null),
                    (_ChainFilter.btc, 'BTC', s.bitcoin),
                    (_ChainFilter.liquid, 'Liquid', s.liquid),
                  ],
                ),
              ],
            ],
          );
        }

        // Phone: SegmentedSwitch already makes every segment a 48-dp touch
        // row; `expand` spreads the track across the column so six range
        // segments share 351 dp instead of overflowing on a narrow phone.
        final rangeSwitch = SegmentedSwitch<_ChartRange>(
          dense: true,
          expand: phone,
          selected: _range,
          onChanged: _selectRange,
          options: [
            for (final r in _ChartRange.values)
              SegOption(value: r, label: r.label),
          ],
        );
        final chainSwitch = bothChains
            ? SegmentedSwitch<_ChainFilter>(
                dense: true,
                expand: phone,
                selected: _chain,
                onChanged: (v) => setState(() => _chain = v),
                options: [
                  const SegOption(value: _ChainFilter.all, label: 'All'),
                  SegOption(
                    value: _ChainFilter.btc,
                    label: 'BTC',
                    color: s.bitcoin,
                  ),
                  SegOption(
                    value: _ChainFilter.liquid,
                    label: 'Liquid',
                    color: s.liquid,
                  ),
                ],
              )
            : null;
        final unitSwitch = SegmentedSwitch<bool>(
          dense: true,
          // Alone on its row it fills the column like the range track above;
          // beside the chain track it keeps its intrinsic two-segment width.
          expand: phone && chainSwitch == null,
          selected: fiat,
          onChanged: (v) => setState(() => _fiatMode = v),
          options: [
            SegOption(value: true, label: PriceService.instance.currency),
            SegOption(value: false, label: useSats ? 'sats' : 'BTC'),
          ],
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DeltaReadout(delta: _delta(points), rangeLabel: _range.label),
            const SizedBox(height: AppSpacing.sm),
            chart,
            ?priceNote,
            const SizedBox(height: AppSpacing.md),
            // Three questions, three tracks: how far back, which chain, which
            // unit. They used to be one run of 11 near-identical 11px chips
            // where only a hairline said where one group ended and the next
            // began — you had to read every label to find the one you wanted.
            if (phone) ...[
              // Two rows: the range track across the column, then chain and
              // unit side by side. A Wrap here left ragged runs.
              rangeSwitch,
              const SizedBox(height: AppSpacing.sm),
              if (chainSwitch != null)
                Row(
                  children: [
                    Expanded(child: chainSwitch),
                    const SizedBox(width: AppSpacing.sm),
                    unitSwitch,
                  ],
                )
              else
                unitSwitch,
            ] else
              Wrap(
                spacing: AppSpacing.xl,
                runSpacing: AppSpacing.md,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  rangeSwitch,
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.sm,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ?chainSwitch,
                      unitSwitch,
                    ],
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// Fiat labels on the chart follow the net-worth headline's compaction.
String _fiatLabel(double value, String symbol) {
  if (value >= 1000000) return '$symbol${(value / 1000000).toStringAsFixed(2)}M';
  if (value >= 1000) return '$symbol${(value / 1000).toStringAsFixed(2)}k';
  return '$symbol${value.toStringAsFixed(2)}';
}

class _DeltaReadout extends StatelessWidget {
  const _DeltaReadout({
    required this.delta,
    required this.rangeLabel,
    this.showRange = true,
  });

  /// Percent change over the range; null when there is not enough history.
  final double? delta;
  final String rangeLabel;

  /// Name the range after the figure. Off where the range chips sit on the
  /// same row and already say it.
  final bool showRange;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final d = delta;
    // Sub-0.05% moves read as noise, not as a gain.
    final flat = d == null || d.abs() < 0.05;
    final up = d != null && d > 0;
    final color = flat ? s.inkFaint : (up ? s.success : s.danger);

    // The one-node reading and the shrink-wrapped row belong to the phone,
    // where the figure shares a line with the range words. Desktop keeps the
    // three separate nodes and the stretched row it always had.
    final phone = AppLayout.isPhone(context);
    return Semantics(
      label: phone
          ? (d == null
              ? 'No change data'
              : '${d.toStringAsFixed(1)} percent over $rangeLabel')
          : null,
      excludeSemantics: phone,
      child: Row(
        mainAxisSize: phone ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Icon(
            flat
                ? Icons.remove_rounded
                : (up
                    ? Icons.arrow_drop_up_rounded
                    : Icons.arrow_drop_down_rounded),
            size: flat ? 13 : 20,
            color: color,
          ),
          const SizedBox(width: 1),
          Text(
            d == null ? '—' : '${d > 0 ? '+' : ''}${d.toStringAsFixed(1)}%',
            style: AppTypography.numericSmall.copyWith(color: color),
          ),
          if (showRange) ...[
            const SizedBox(width: AppSpacing.xs),
            Text(
              '($rangeLabel)',
              style: AppTypography.caption.copyWith(color: s.inkFaint),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Phone chart controls ──────────────────────────────────────────────────────

/// A row of words, one of them lit: the phone's stand-in for a bordered
/// segmented track. Each word is a 40-dp target; the chosen one sits on a
/// soft pill of its own colour (the chain hue for BTC/Liquid, else the
/// accent). [spread] shares the row out evenly — for the six ranges — where
/// the default packs the words to the left.
class _TextChips<T> extends StatelessWidget {
  const _TextChips({
    required this.options,
    required this.selected,
    required this.onChanged,
    this.spread = false,
  });

  /// (value, label, colour) — colour null takes the accent.
  final List<(T, String, Color?)> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final bool spread;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final motion = AppMotion.of(context, AppMotion.quick);
    return Row(
      mainAxisSize: spread ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment:
          spread ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
      children: [
        for (final (value, label, tint) in options)
          Builder(
            builder: (context) {
              final sel = value == selected;
              final color = tint ?? s.accent;
              return Semantics(
                button: true,
                selected: sel,
                label: label,
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => onChanged(value),
                  borderRadius: BorderRadius.circular(999),
                  child: ConstrainedBox(
                    // A word is a control: it clears the touch floor on both
                    // axes even though the lit pill inside it is smaller.
                    constraints: const BoxConstraints(
                      minHeight: AppLayout.minTouchTarget,
                      minWidth: 40,
                    ),
                    child: Center(
                      child: AnimatedContainer(
                        duration: motion,
                        curve: AppMotion.settle,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm + 2,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: sel
                              ? color.withValues(alpha: s.isDark ? 0.18 : 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          label,
                          style: AppTypography.label.copyWith(
                            fontSize: 12,
                            letterSpacing: 0.4,
                            fontWeight: sel ? FontWeight.w700 : FontWeight.w600,
                            color: sel ? color : s.inkSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

// ── Phone hero: eyebrow, balance, actions ────────────────────────────────────

/// Names the figure under it and the chain it is denominated on, and carries
/// the one control that belongs beside a balance: the eye.
class _HeroEyebrow extends StatelessWidget {
  const _HeroEyebrow();

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final label = AppTypography.navSection.copyWith(letterSpacing: 1.3);
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'TOTAL BALANCE',
                  style: label.copyWith(color: s.inkFaint),
                ),
                TextSpan(text: '  ·  ', style: label.copyWith(color: s.inkFaint)),
                // The network answer, once, where the number is read. It is
                // amber because it is a warning, not a label.
                TextSpan(text: 'TESTNET', style: label.copyWith(color: s.testnet)),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const PrivacyToggle(size: 18),
      ],
    );
  }
}

/// "0.01734567 BTC" → the number, and its unit. A fiat figure carries its
/// symbol in front and has nothing to split off.
(String, String?) _splitUnit(String text) {
  final i = text.lastIndexOf(' ');
  if (i <= 0) return (text, null);
  return (text.substring(0, i), text.substring(i + 1));
}

/// "last move 12 min ago", from the newest transaction the engine handed us.
///
/// The age of the newest item is a fact whichever way the list was capped —
/// a count of "transactions this week" would not be: the engine returns only
/// the most recent few per chain, so a busy wallet would be told a number
/// that is quietly wrong.
String? _lastMoveNote(List<RecentActivityItem> activity) {
  if (activity.isEmpty) return null;
  var newest = activity.first.timestamp;
  for (final a in activity) {
    if (a.timestamp.isAfter(newest)) newest = a.timestamp;
  }
  return 'last move ${relativeTimeShort(newest)}';
}

/// The headline: a big figure, a quiet unit, and one line of context. Tapping
/// it swaps fiat for coin — and the chart above follows, because the parent
/// owns that choice.
class _PhoneBalance extends StatelessWidget {
  const _PhoneBalance({
    required this.assets,
    required this.coinFirst,
    required this.onSwap,
    this.note,
  });

  final List<AssetBalance> assets;
  final bool coinFirst;
  final VoidCallback onSwap;

  /// A fact about the wallet under the figure — how long ago it last moved.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final useSats = context.select<AppState, bool>((st) => st.useSats);
    // Depend on the currency too, so the headline rebuilds when it changes.
    context.select<AppState, String>((st) => st.fiatCurrency);
    final hidden = balancesHidden(context);
    final nativeSats = assets
        .where((a) => a.ticker == 'BTC' || a.ticker == 'LBTC')
        .fold<int>(0, (sum, a) => sum + a.amount);
    final price = PriceService.instance;

    return AnimatedBuilder(
      animation: price,
      builder: (_, _) {
        final coinStr = PriceService.formatUnit(nativeSats, sat: useSats);
        // With no price feed there is only one number to show, so the swap
        // has nothing to swap to.
        final swappable = price.hasPrice;
        final showCoin = coinFirst || !swappable;
        final headline =
            showCoin ? coinStr : price.totalFiatDisplay(nativeSats);
        final (value, unit) = _splitUnit(headline);
        final other =
            showCoin ? price.totalFiatDisplay(nativeSats) : coinStr;

        final line = <String>[
          if (swappable && !hidden) '≈ $other',
          ?note,
        ].join('  ·  ');

        final number = Text(
          hidden ? kMaskedAmount : value,
          style: AppTypography.balanceHeroOf(context),
          maxLines: 1,
        );

        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // A long sats figure scales down to the column instead of
            // wrapping the headline onto two lines.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: number,
              ),
            ),
            if (unit != null && !hidden) ...[
              const SizedBox(width: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  unit,
                  style: AppTypography.balanceMediumOf(context).copyWith(
                    fontSize: 17,
                    color: s.inkSecondary,
                  ),
                ),
              ),
            ],
            if (swappable) ...[
              const SizedBox(width: AppSpacing.xs),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Icon(Icons.swap_vert_rounded, size: 18, color: s.inkFaint),
              ),
            ],
          ],
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!swappable)
              row
            else
              Semantics(
                button: true,
                label: showCoin
                    ? 'Show ${price.currency}'
                    : 'Show ${useSats ? 'sats' : 'BTC'}',
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: onSwap,
                  behavior: HitTestBehavior.opaque,
                  child: row,
                ),
              ),
            if (line.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                line,
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Send and Receive, right under the balance they act on — the same two
/// buttons the desktop hero draws, wearing the phone's filled grammar
/// (buttons.dart). Send is the one filled action on the screen and the one
/// thing in the app that casts a shadow (design.md).
class _HeroActions extends StatelessWidget {
  const _HeroActions({required this.showSend});

  /// False on a pure watch-only wallet, which cannot sign.
  final bool showSend;

  @override
  Widget build(BuildContext context) {
    final receive = SecondaryButton(
      label: 'Receive',
      icon: Icons.call_received,
      isFullWidth: true,
      onPressed: () => context.go(AppRoutes.receive),
    );
    if (!showSend) return receive;
    return Row(
      children: [
        // The Action takes the wider half: on a wallet's home screen the two
        // verbs are not equals.
        Expanded(
          flex: 6,
          child: AccentButton(
            label: 'Send',
            icon: Icons.send,
            isFullWidth: true,
            onPressed: () => context.go(AppRoutes.send),
          ),
        ),
        const SizedBox(width: AppSpacing.sm + 2),
        Expanded(flex: 5, child: receive),
      ],
    );
  }
}

// ── Phone lists: assets, then activity ───────────────────────────────────────
//
// Both chains in one list each. A row carries its own chain — the Bitcoin
// glyph in orange, the Liquid drop in teal, the name that says so — which is
// what let the two per-chain panels collapse into these two.

AssetBalance? _assetWithTicker(List<AssetBalance> assets, String ticker) {
  for (final a in assets) {
    if (a.ticker == ticker) return a;
  }
  return null;
}

class _PhoneAssets extends StatelessWidget {
  const _PhoneAssets({
    required this.data,
    required this.issuedAssets,
    required this.hiddenAssets,
  });

  final DashboardData data;
  final Map<String, IssuedAssetEntry> issuedAssets;
  final List<String> hiddenAssets;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final useSats = context.select<AppState, bool>((st) => st.useSats);
    final hasLiquid = context.select<AppState, bool>(
      (st) => st.activeWalletLiquid,
    );
    final masked = balancesHidden(context);

    final btc = _assetWithTicker(data.assets, 'BTC');
    final lbtc = _assetWithTicker(data.assets, 'LBTC');
    final tokens = groupAssets(
      data.assets
          .where((a) => a.ticker != 'BTC' && a.ticker != 'LBTC')
          .toList(),
      issuedAssets,
    ).where((g) => !hiddenAssets.contains(g.main.assetId)).toList();

    final rows = <Widget>[
      if (btc != null)
        _nativeRow(
          context,
          asset: btc,
          title: 'Bitcoin',
          tint: s.bitcoin,
          coin: 'BTC',
          useSats: useSats,
          masked: masked,
        ),
      if (lbtc != null)
        _nativeRow(
          context,
          asset: lbtc,
          title: 'Liquid Bitcoin',
          tint: s.liquid,
          coin: 'L-BTC',
          useSats: useSats,
          masked: masked,
        ),
      for (final g in tokens) _tokenRow(context, g, masked),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListSectionLabel(
          label: 'Assets',
          actionLabel: hasLiquid ? 'Liquid' : null,
          onAction: hasLiquid ? () => context.go(AppRoutes.liquid) : null,
        ),
        ListCard(children: rows),
      ],
    );
  }

  /// BTC or L-BTC: the chain's own coin, counted in coins.
  Widget _nativeRow(
    BuildContext context, {
    required AssetBalance asset,
    required String title,
    required Color tint,
    required String coin,
    required bool useSats,
    required bool masked,
  }) {
    final s = AppScheme.of(context);
    final (value, unit) = _splitUnit(
      PriceService.formatUnit(asset.amount, sat: useSats, coin: coin),
    );
    final coins = '${asset.utxoCount} coin${asset.utxoCount == 1 ? '' : 's'}';
    // 'synced' is the quiet case; anything else is worth a word, and
    // 'unavailable' is worth a red one.
    final unsynced = asset.status != 'synced';
    return ListRow(
      icon: Icons.currency_bitcoin,
      tint: tint,
      title: title,
      subtitle: unsynced ? '$coins · ${asset.status}' : coins,
      subtitleColor: asset.status == 'unavailable' ? s.danger : null,
      trailing: ListAmount(
        value: masked ? kMaskedAmount : value,
        unit: masked ? null : unit,
      ),
    );
  }

  /// A Liquid token: named by the registry where it is known, and saying so.
  Widget _tokenRow(BuildContext context, AssetGroup g, bool masked) {
    final s = AppScheme.of(context);
    final registry = AssetRegistryService.instance;
    final asset = g.main;
    final ticker = registry.displayTicker(asset);
    final name = registry.displayName(asset);
    final info = registry.get(asset.assetId);
    final (value, unit) = _splitUnit(asset.displayAmount);
    return ListRow(
      icon: Icons.water_drop_rounded,
      tint: s.liquid,
      title: name == 'Unknown Asset' ? ticker : name,
      subtitle: <String>[
        'Liquid asset',
        if (info?.domain != null && info!.domain!.isNotEmpty) info.domain!,
        if (g.reissuanceToken != null) 'reissuance token',
      ].join(' · '),
      trailing: ListAmount(
        value: masked ? kMaskedAmount : value,
        unit: masked ? null : (unit ?? ticker),
      ),
    );
  }
}

class _PhoneActivity extends StatelessWidget {
  const _PhoneActivity({required this.data});

  final DashboardData data;

  /// Enough to answer "did it arrive?" without becoming the Activity screen.
  static const int _shown = 4;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final masked = balancesHidden(context);
    final items = [...data.recentActivity]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final recent = items.take(_shown).toList();

    final rows = <Widget>[];
    if (recent.isEmpty) {
      rows.add(
        ListRow(
          icon: Icons.inbox_rounded,
          tint: s.inkFaint,
          title: 'Nothing yet',
          subtitle: 'Received and sent transactions land here',
        ),
      );
    } else {
      for (final tx in recent) {
        rows.add(_activityRow(context, tx, masked));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListSectionLabel(
          label: 'Recent activity',
          actionLabel: recent.isEmpty ? null : 'All',
          onAction:
              recent.isEmpty ? null : () => context.go(AppRoutes.history),
        ),
        ListCard(children: rows),
      ],
    );
  }

  Widget _activityRow(
    BuildContext context,
    RecentActivityItem tx,
    bool masked,
  ) {
    final s = AppScheme.of(context);
    final isIn = tx.direction == 'incoming';
    final isSelf = tx.direction == 'self';
    final counterparty = tx.counterparty;
    return ListRow(
      icon: isSelf
          ? Icons.autorenew_rounded
          : isIn
              ? Icons.south_west_rounded
              : Icons.north_east_rounded,
      tint: isIn ? s.success : s.inkSecondary,
      title: tx.note ??
          (isSelf
              ? 'Internal transfer'
              : isIn
                  ? 'Received'
                  : 'Sent'),
      // Which chain, from whom, how long ago — the three things a row of
      // activity is asked, in the order they are asked in.
      subtitle: <String>[
        tx.isLiquid ? 'Liquid' : 'Bitcoin',
        if (counterparty != null && counterparty.isNotEmpty) counterparty,
        relativeTimeShort(tx.timestamp),
      ].join(' · '),
      onTap: () => context.go(AppRoutes.history),
      trailing: ListAmount(
        value: masked ? kMaskedAmount : tx.amount,
        // The one thing worth saying under an amount is that it has not
        // settled yet.
        unit: tx.isConfirmed ? null : 'unconfirmed',
        valueColor: isIn ? s.success : s.ink,
        unitColor: s.warning,
        maxWidth: 132,
      ),
    );
  }
}

// ── Wallet key badge ──────────────────────────────────────────────────────────
// `f0b68896` — the wallet's master fingerprint, small and mono. Click copies
// the full xpub (the fingerprint alone is not enough to reconstruct it), or
// the fingerprint itself when no single xpub exists (multisig).

class _WalletKeyBadge extends StatefulWidget {
  const _WalletKeyBadge({required this.info});
  final WalletInfo info;

  @override
  State<_WalletKeyBadge> createState() => _WalletKeyBadgeState();
}

class _WalletKeyBadgeState extends State<_WalletKeyBadge> {
  bool _copied = false;

  bool get _hasXpub => widget.info.xpub.isNotEmpty;

  Future<void> _copy() async {
    final text = _hasXpub ? widget.info.xpub : widget.info.masterFingerprint;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final fp = widget.info.masterFingerprint;
    if (fp.isEmpty) return const SizedBox.shrink();
    final phone = AppLayout.isPhone(context);

    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Padding(
        // 2 dp around 12-px mono text is a 22-dp target; a finger needs more.
        padding: phone
            ? const EdgeInsets.symmetric(vertical: AppSpacing.sm)
            : const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              fp,
              style: AppTypography.monoSmall.copyWith(color: s.accent),
            ),
            const SizedBox(width: AppSpacing.xs),
            Icon(
              _copied ? Icons.check : Icons.copy_rounded,
              size: phone ? 16 : 13,
              color: _copied ? s.success : s.inkFaint,
            ),
            if (_copied) ...[
              const SizedBox(width: 3),
              Text(_hasXpub ? 'xpub copied' : 'fingerprint copied',
                  style: AppTypography.caption.copyWith(color: s.success)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Asset card grid ───────────────────────────────────────────────────────────

// ── Chain sections ────────────────────────────────────────────────────────────
//
// Below the portfolio hero the wallet stops being one number and becomes two
// chains. A single "Assets" grid and a single "Recent activity" list forced
// the user to do that separation themselves: a row reading "+100 USDT" says
// nothing about which chain settled it, and BTC and L-BTC sat side by side as
// if they were interchangeable.
//
// So: one panel per chain, in the same order the hero chart offers them
// (Bitcoin, then Liquid). Each states its own balance and its own latest
// transactions. Liquid additionally carries the asset cards, because tokens
// only exist there.

class _ChainSections extends StatelessWidget {
  const _ChainSections({
    required this.data,
    required this.issuedAssets,
    required this.hiddenAssets,
    required this.showHidden,
    required this.onToggleShowHidden,
  });

  final DashboardData data;
  final Map<String, IssuedAssetEntry> issuedAssets;
  final List<String> hiddenAssets;
  final bool showHidden;
  final VoidCallback onToggleShowHidden;

  /// Below this the two panels stack — side by side they would each be too
  /// narrow for an amount and a counterparty on one line.
  static const double _sideBySide = 900;

  AssetBalance? _native(String ticker) {
    for (final a in data.assets) {
      if (a.ticker == ticker) return a;
    }
    return null;
  }

  List<RecentActivityItem> _activity(String chain) =>
      data.recentActivity.where((t) => t.chain == chain).take(3).toList();

  @override
  Widget build(BuildContext context) {
    final btc = _native('BTC');
    final lbtc = _native('LBTC');

    final panels = <Widget>[
      // The same glyph and hue the chain switch and the phone's asset rows
      // use for each chain — one vocabulary, not two.
      if (btc != null)
        _ChainPanel(
          title: 'Bitcoin',
          icon: Icons.currency_bitcoin,
          rail: AppScheme.of(context).bitcoin,
          native: btc,
          activity: _activity('bitcoin'),
        ),
      if (lbtc != null)
        _ChainPanel(
          title: 'Liquid',
          icon: Icons.water_drop_outlined,
          rail: AppScheme.of(context).liquid,
          native: lbtc,
          activity: _activity('liquid'),
          // Loans live on Liquid, so the way into Templar Protocol sits in the
          // Liquid panel: one tap from the dashboard, as its own row.
          showProtocol: true,
          // Everything that is not L-BTC on the Liquid side: issued tokens and
          // third-party assets, with their reissuance tokens folded in.
          assets: data.assets
              .where((a) => a.ticker != 'BTC' && a.ticker != 'LBTC')
              .toList(),
          issuedAssets: issuedAssets,
          hiddenAssets: hiddenAssets,
          showHidden: showHidden,
          onToggleShowHidden: onToggleShowHidden,
        ),
    ];

    if (panels.isEmpty) return const SizedBox.shrink();
    if (panels.length == 1) return panels.single;

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < _sideBySide) {
          return Column(
            children: [
              panels[0],
              const SizedBox(height: AppSpacing.lg),
              panels[1],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: panels[0]),
            const SizedBox(width: AppSpacing.lg),
            Expanded(child: panels[1]),
          ],
        );
      },
    );
  }
}

class _ChainPanel extends StatelessWidget {
  const _ChainPanel({
    required this.title,
    required this.icon,
    required this.rail,
    required this.native,
    required this.activity,
    this.assets,
    this.issuedAssets = const {},
    this.hiddenAssets = const [],
    this.showHidden = false,
    this.onToggleShowHidden,
    this.showProtocol = false,
  });

  final String title;

  /// The chain's glyph, drawn in [rail] on the inset tile that heads every
  /// list row — so the panel names its chain the way a row does.
  final IconData icon;
  final Color rail;

  /// The chain's own coin — BTC or L-BTC. This is the panel's headline.
  final AssetBalance native;

  final List<RecentActivityItem> activity;

  /// Non-native assets on this chain. Null on Bitcoin, which has none.
  final List<AssetBalance>? assets;
  final Map<String, IssuedAssetEntry> issuedAssets;
  final List<String> hiddenAssets;
  final bool showHidden;
  final VoidCallback? onToggleShowHidden;

  /// Whether this chain carries the Templar Protocol row (Liquid does).
  final bool showProtocol;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final useSats = context.select<AppState, bool>((st) => st.useSats);
    final hidden = balancesHidden(context);
    final price = PriceService.instance;
    final phone = AppLayout.isPhone(context);
    final gutter = phone ? AppSpacing.cardPaddingSmall : AppSpacing.lg;

    // The same glass the Keys card and the hero above sit on — the old
    // rail panel (raised eyebrow strip, 3 px coloured rule) was the one
    // surface on the page drawn in another grammar. The chain's colour now
    // lives where the rows put it: in the glyph and the name.
    // Clipped: the zebra activity rows paint edge to edge and would square
    // off the card's bottom corners otherwise.
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        child: AnimatedBuilder(
        animation: price,
        builder: (_, _) {
          final coin = native.ticker == 'LBTC' ? 'L-BTC' : 'BTC';
          final unit =
              PriceService.formatUnit(native.amount, sat: useSats, coin: coin);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: glyph tile, chain name in its hue, sync state.
              Padding(
                padding: EdgeInsets.fromLTRB(
                    gutter, phone ? AppSpacing.md : AppSpacing.lg, gutter, 0),
                child: Row(
                  children: [
                    ListIconTile(icon: icon, tint: rail, size: 36),
                    const SizedBox(width: kListGap),
                    Expanded(
                      child: Text(
                        title,
                        style: AppTypography.sectionTitleOf(context)
                            .copyWith(color: rail),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (native.status != 'synced')
                      StatusBadge(
                        label: native.status,
                        variant: native.status == 'unavailable'
                            ? BadgeVariant.danger
                            : BadgeVariant.neutral,
                      ),
                  ],
                ),
              ),
              // Balance.
              Padding(
                padding: EdgeInsets.fromLTRB(
                    gutter, AppSpacing.md, gutter, AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (phone)
                      // Scales a long sats figure down to the panel instead
                      // of wrapping the number onto two lines.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Amount(
                          hidden ? kMaskedAmount : unit,
                          maxLines: 1,
                          style: AppTypography.balanceMediumOf(context)
                              .copyWith(fontSize: 22, color: s.ink),
                        ),
                      )
                    else
                      Amount(
                        hidden ? kMaskedAmount : unit,
                        style: AppTypography.balanceMedium
                            .copyWith(fontSize: 24, color: s.ink),
                      ),
                    const SizedBox(height: 2),
                    if (phone)
                      // One wrapping line; a Row of three Texts overflows
                      // once the fiat figure grows.
                      Text(
                        [
                          if (price.hasPrice && !hidden)
                            '≈ ${price.fiatDisplay(native.amount)}',
                          '${native.utxoCount} '
                              'coin${native.utxoCount == 1 ? '' : 's'}',
                        ].join('  ·  '),
                        style: AppTypography.bodySmall
                            .copyWith(color: s.inkSecondary),
                        softWrap: true,
                      )
                    else
                      Row(
                        children: [
                          if (price.hasPrice && !hidden)
                            Text(
                              '≈ ${price.fiatDisplay(native.amount)}',
                              style: AppTypography.bodySmall
                                  .copyWith(color: s.inkSecondary),
                            ),
                          if (price.hasPrice && !hidden)
                            Text(
                              '  ·  ',
                              style: AppTypography.bodySmall
                                  .copyWith(color: s.inkFaint),
                            ),
                          Text(
                            '${native.utxoCount} '
                            'coin${native.utxoCount == 1 ? '' : 's'}',
                            style: AppTypography.bodySmall
                                .copyWith(color: s.inkSecondary),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              // Templar Protocol — Liquid only. A row, not a button: it goes
              // somewhere, like the rows underneath it.
              if (showProtocol) ...[
                Divider(height: 1, color: s.edge),
                HoverRow(
                  onTap: () => context.go(AppRoutes.settingsProtocol),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: gutter, vertical: AppSpacing.sm),
                    child: Row(
                      children: [
                        ListIconTile(
                            icon: Icons.link_rounded, tint: rail, size: 28),
                        const SizedBox(width: kListGap),
                        Expanded(
                          child: Text('Templar Protocol',
                              style: AppTypography.body.copyWith(color: s.ink)),
                        ),
                        Icon(Icons.chevron_right, size: 18, color: s.inkFaint),
                      ],
                    ),
                  ),
                ),
              ],
              // Assets — Liquid only.
              if (assets != null) ...[
                Divider(height: 1, color: s.edge),
                _PanelAssets(
                  assets: assets!,
                  issuedAssets: issuedAssets,
                  hiddenAssets: hiddenAssets,
                  showHidden: showHidden,
                  onToggleShowHidden: onToggleShowHidden,
                ),
              ],
              // Latest transactions on this chain.
              Divider(height: 1, color: s.edge),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    gutter, phone ? AppSpacing.xs : AppSpacing.md, gutter, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'LATEST',
                        style: AppTypography.navSection
                            .copyWith(color: s.inkFaint, letterSpacing: 1.2),
                      ),
                    ),
                    // On a phone the quiet tile keeps a resting hairline
                    // and a 48-dp height (buttons.dart), so it reads as an
                    // action without hover.
                    GhostButton(
                      label: 'All activity',
                      onPressed: () => context.go(AppRoutes.history),
                    ),
                  ],
                ),
              ),
              if (activity.isEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      gutter, AppSpacing.md, gutter, AppSpacing.lg),
                  child: Text(
                    'Nothing yet on this chain.',
                    style: AppTypography.caption.copyWith(color: s.inkFaint),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Column(
                    children: [
                      for (var i = 0; i < activity.length; i++)
                        HoverRow(
                          zebra: i.isOdd,
                          // On a phone the rows look like a list, so they
                          // act like one and open the activity page.
                          onTap: phone
                              ? () => context.go(AppRoutes.history)
                              : null,
                          child: _ActivityRow(tx: activity[i]),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
        ),
      ),
    );
  }
}

/// The asset cards, as a block inside the Liquid panel.
class _PanelAssets extends StatelessWidget {
  const _PanelAssets({
    required this.assets,
    required this.issuedAssets,
    required this.hiddenAssets,
    required this.showHidden,
    required this.onToggleShowHidden,
  });

  final List<AssetBalance> assets;
  final Map<String, IssuedAssetEntry> issuedAssets;
  final List<String> hiddenAssets;
  final bool showHidden;
  final VoidCallback? onToggleShowHidden;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final groups = groupAssets(assets, issuedAssets);
    final visible = showHidden
        ? groups
        : groups.where((g) => !hiddenAssets.contains(g.main.assetId)).toList();
    final hiddenCount =
        groups.where((g) => hiddenAssets.contains(g.main.assetId)).length;
    final phone = AppLayout.isPhone(context);
    final gutter = phone ? AppSpacing.cardPaddingSmall : AppSpacing.lg;

    return Padding(
      padding: EdgeInsets.fromLTRB(
          gutter, phone ? AppSpacing.sm : AppSpacing.md, gutter, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'ASSETS',
                  style: AppTypography.navSection
                      .copyWith(color: s.inkFaint, letterSpacing: 1.2),
                ),
              ),
              if (hiddenCount > 0 && onToggleShowHidden != null)
                InkWell(
                  onTap: onToggleShowHidden,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  child: Padding(
                    padding: phone
                        ? const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: AppSpacing.sm + 2)
                        : const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xs, vertical: 2),
                    child: Text(
                      showHidden
                          ? 'Hide hidden ($hiddenCount)'
                          : 'Show hidden ($hiddenCount)',
                      style: AppTypography.caption.copyWith(color: s.accent),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: phone ? AppSpacing.xs : AppSpacing.sm),
          if (visible.isEmpty)
            Text(
              'No other assets on Liquid.',
              style: AppTypography.caption.copyWith(color: s.inkFaint),
            )
          else if (phone)
            // One compact row per asset, full width; the grid tile at the
            // column's width was a 120-dp card with an empty right half.
            // Tapping opens the Liquid page, where the detail sheet lives.
            Column(
              children: [
                for (final g in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: GroupedAssetCard(
                      group: g,
                      isHidden: hiddenAssets.contains(g.main.assetId),
                      compact: true,
                      onTap: () => context.go(AppRoutes.liquid),
                    ),
                  ),
              ],
            )
          else
            LayoutBuilder(
              builder: (context, c) {
                final cols = (c.maxWidth / 190).floor().clamp(1, 4);
                final w =
                    (c.maxWidth - (cols - 1) * AppSpacing.sm) / cols;
                return Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final g in visible)
                      SizedBox(
                        width: w,
                        child: GroupedAssetCard(
                          group: g,
                          isHidden: hiddenAssets.contains(g.main.assetId),
                          // No detail sheet on the dashboard yet — render the
                          // card non-interactive rather than fake a target.
                          onTap: null,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

// ── Activity row ──────────────────────────────────────────────────────────────

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.tx});
  final RecentActivityItem tx;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final isIn = tx.direction == 'incoming';
    final color = isIn ? s.success : s.ink;
    final icon = isIn ? Icons.south_west : Icons.north_east;
    final phone = AppLayout.isPhone(context);

    final amountStyle = AppTypography.numericSmall.copyWith(
      fontSize: 14,
      color: color,
      fontWeight: FontWeight.w600,
    );
    // Only the phone branch caps the amount's width, so only there does it
    // need to ellipsise; the desktop tree stays exactly as it was.
    final amount = phone
        ? Amount(
            tx.amount,
            style: amountStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
          )
        : Amount(tx.amount, style: amountStyle);

    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: phone ? AppSpacing.cardPaddingSmall : AppSpacing.lg,
          vertical: phone ? AppSpacing.sm + 3 : AppSpacing.sm + 1),
      child: Row(
        children: [
          Icon(icon, size: 15, color: isIn ? s.success : s.inkSecondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.note ?? tx.counterparty ?? (isIn ? 'Received' : 'Sent'),
                  style: AppTypography.bodySmall
                      .copyWith(fontWeight: FontWeight.w500, color: s.ink),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  tx.isConfirmed
                      ? '${tx.confirmations} conf${tx.confirmations == 1 ? '' : 's'}.'
                      : 'Unconfirmed',
                  style: AppTypography.caption.copyWith(
                    color: tx.isConfirmed ? s.success : s.warning,
                  ),
                ),
              ],
            ),
          ),
          if (phone) ...[
            const SizedBox(width: AppSpacing.sm),
            // Capped so a long amount ellipsises instead of squeezing the
            // counterparty to nothing; the title keeps >= ~150 dp.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: amount,
            ),
          ] else
            amount,
        ],
      ),
    );
  }
}

