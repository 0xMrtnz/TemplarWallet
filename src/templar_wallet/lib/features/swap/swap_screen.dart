import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/asset_logo.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'make_offer_flow.dart';
import 'models/swap_offer.dart';
import 'take_flow.dart';
import '../../shared/widgets/glass_dialog.dart';

/// LiquiDEX swap screen: browse the liquidex.it order book (mainnet rows are
/// view-only), take testnet orders, and make/manage this wallet's own offers.
class SwapScreen extends StatefulWidget {
  const SwapScreen({super.key});

  @override
  State<SwapScreen> createState() => _SwapScreenState();
}

class _SwapScreenState extends State<SwapScreen> {
  final _bridge = walletBridge;

  // Order book tab.
  List<SwapOffer> _offers = [];
  bool _loading = true;
  String? _error;
  bool _includeUnavailable = false;

  // My offers tab.
  List<MyOffer> _myOffers = [];
  bool _loadingMine = true;
  String? _mineError;
  bool _cancelling = false;

  String? get _walletId => context.read<AppState>().activeWalletId;

  @override
  void initState() {
    super.initState();
    _loadBook();
    _loadMine();
  }

  /// [silent] skips the full-page spinner: the phone's pull-to-refresh draws
  /// its own, and flipping `_loading` would swap the list the finger is still
  /// holding for a centred CircularProgressIndicator. Defaults to the old
  /// behaviour, so every other caller (and the whole desktop) is unchanged.
  Future<void> _loadBook({bool silent = false}) async {
    setState(() {
      if (!silent) _loading = true;
      _error = null;
    });
    try {
      final offers =
          await _bridge.listSwaps(includeUnavailable: _includeUnavailable);
      if (!mounted) return;
      setState(() {
        _offers = offers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = swapError(e);
        _loading = false;
      });
    }
  }

  /// [silent] as in [_loadBook]: pull-to-refresh keeps the list on screen.
  Future<void> _loadMine({bool silent = false}) async {
    final walletId = _walletId;
    if (walletId == null) {
      setState(() => _loadingMine = false);
      return;
    }
    setState(() {
      if (!silent) _loadingMine = true;
      _mineError = null;
    });
    try {
      final mine = await _bridge.listMyOffers(walletId);
      if (!mounted) return;
      setState(() {
        _myOffers = mine;
        _loadingMine = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mineError = swapError(e);
        _loadingMine = false;
      });
    }
  }

  void _refresh() {
    _loadBook();
    _loadMine();
  }

  // ── flows ────────────────────────────────────────────────────────────────────

  Future<void> _takeProposal(String proposalJson) async {
    final txid = await openTakeFlow(context, proposalJson: proposalJson);
    if (txid != null && mounted) _refresh();
  }

  Future<void> _importProposal() async {
    final proposal = await showImportProposalDialog(context);
    if (proposal != null && mounted) await _takeProposal(proposal);
  }

  Future<void> _makeOffer() async {
    final offer = await openMakeOfferFlow(context);
    if (offer != null && mounted) _loadMine();
  }

  Future<void> _cancelOffer(MyOffer o) async {
    final walletId = _walletId;
    if (walletId == null || _cancelling) return;
    final confirmed = await showAppDialog<bool>(context,
          builder: (ctx) => AppDialog(
            title: const Text('Cancel this offer?'),
            content: SizedBox(
              width: 440,
              child: Text(
                'Cancelling self-spends your coin, which invalidates the '
                'proposal everywhere it was shared (a small network fee '
                'applies). This cannot be undone.',
                style: AppTypography.bodySmall,
              ),
            ),
            actions: [
              GhostButton(
                  label: 'Keep offer',
                  onPressed: () => Navigator.of(ctx).pop(false)),
              DangerButton(
                label: 'Cancel offer',
                icon: Icons.cancel_outlined,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() => _cancelling = true);
    try {
      final txid = await _bridge.swapCancel(walletId, o.offerId);
      if (!mounted) return;
      setState(() => _cancelling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Offer cancelled — txid $txid')),
      );
      _loadMine();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cancelling = false;
        _mineError = swapError(e);
      });
    }
  }

  // ── build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageBackground.flat(
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Builder(builder: (context) {
                final phone = AppLayout.isPhone(context);
                final pad = AppSpacing.pagePadding(context);
                if (phone) {
                  // One primary action; the rest behind the ⋮ overflow. Four
                  // 54 dp controls under the title made the toolbar the
                  // heaviest thing on the screen, before any content. Refresh
                  // is gone entirely — both lists pull to refresh instead.
                  return Padding(
                    padding: EdgeInsets.fromLTRB(pad, AppSpacing.lg, pad, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        PageHeader(
                          title: 'LiquiDEX',
                          actions: [
                            PopupMenuButton<String>(
                              tooltip: 'More',
                              icon: const Icon(Icons.more_vert),
                              onSelected: (v) {
                                if (v == 'filled') {
                                  setState(() =>
                                      _includeUnavailable = !_includeUnavailable);
                                  _loadBook();
                                } else if (v == 'import') {
                                  _importProposal();
                                }
                              },
                              itemBuilder: (_) => [
                                CheckedPopupMenuItem(
                                  value: 'filled',
                                  checked: _includeUnavailable,
                                  enabled: !_loading,
                                  child: const Text('Show filled'),
                                ),
                                const PopupMenuItem(
                                  value: 'import',
                                  child: Text('Import proposal'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        PrimaryButton(
                          label: 'Make offer',
                          icon: Icons.add,
                          isFullWidth: true,
                          onPressed: _makeOffer,
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],
                    ),
                  );
                }
                final actions = <Widget>[
                  FilterChip(
                    label: const Text('Show filled'),
                    selected: _includeUnavailable,
                    onSelected: _loading
                        ? null
                        : (v) {
                            setState(() => _includeUnavailable = v);
                            _loadBook();
                          },
                    selectedColor: AppColors.accent.withValues(alpha: 0.18),
                  ),
                  SecondaryButton(
                    label: 'Refresh',
                    icon: Icons.refresh,
                    onPressed: _loading ? null : _refresh,
                  ),
                  SecondaryButton(
                    label: phone ? 'Import' : 'Import proposal',
                    icon: Icons.input,
                    onPressed: _importProposal,
                  ),
                  PrimaryButton(
                    label: 'Make offer',
                    icon: Icons.add,
                    onPressed: _makeOffer,
                  ),
                ];
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xxl, AppSpacing.xxl, AppSpacing.xxl, 0),
                  child: PageHeader(
                    title: 'LiquiDEX',
                    subtitle: 'Order book · make & take atomic swaps on Liquid',
                    actions: [
                      const SizedBox(width: AppSpacing.sm),
                      actions[0],
                      const SizedBox(width: AppSpacing.sm),
                      actions[1],
                      const SizedBox(width: AppSpacing.sm),
                      actions[2],
                      const SizedBox(width: AppSpacing.sm),
                      actions[3],
                    ],
                  ),
                );
              }),
              if (AppLayout.isPhone(context))
                // Two tabs at full width: each takes half and the indicator
                // reads as a real segment. Scrolled-and-left-aligned leaves
                // two thirds of a 360 dp bar empty — a desktop toolbar habit.
                Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.pagePadding(context)),
                  child: TabBar(
                    labelColor: AppColors.accent,
                    indicatorColor: AppColors.accent,
                    tabs: const [
                      Tab(text: 'Order Book'),
                      Tab(text: 'My Offers'),
                    ],
                  ),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.pagePadding(context)),
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelColor: AppColors.accent,
                      indicatorColor: AppColors.accent,
                      tabs: const [
                        Tab(text: 'Order Book'),
                        Tab(text: 'My Offers'),
                      ],
                    ),
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [
                    _orderBookTab(),
                    _myOffersTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Order book tab ────────────────────────────────────────────────────────

  /// The gutter for a centred empty/error state. These states used to hold
  /// their copy in a fixed SizedBox(width: 420/440), which a 360 dp phone
  /// clamps to the full screen — the only text on either tab that ran into
  /// the bezel. They now cap the measure instead (ConstrainedBox) and take
  /// this gutter. Zero on the desktop, where the centred, ≤440 dp copy inside
  /// a ≥960 dp pane must not move a pixel.
  EdgeInsets get _statePad => EdgeInsets.symmetric(
        horizontal:
            AppLayout.isPhone(context) ? AppSpacing.pagePadding(context) : 0,
      );

  Widget _orderBookTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: _statePad,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 32, color: AppColors.textMuted),
              const SizedBox(height: AppSpacing.md),
              Text('Could not load the order book', style: AppTypography.body),
              const SizedBox(height: AppSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              GhostButton(
                label: 'Retry',
                icon: Icons.refresh,
                isFullWidth: AppLayout.isPhone(context),
                onPressed: _loadBook,
              ),
            ],
          ),
        ),
      );
    }
    if (_offers.isEmpty) {
      final s = AppScheme.of(context);
      // Scrollable even with nothing in it: the phone dropped the Refresh
      // button for pull-to-refresh, and a Center cannot be pulled.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: _statePad,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              Icon(Icons.swap_horiz, size: 36, color: s.inkFaint),
              const SizedBox(height: AppSpacing.md),
              Text('No open orders', style: AppTypography.body),
              const SizedBox(height: AppSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Text(
                  'The order book is empty right now. Make your own offer, or '
                  'import a proposal someone shared with you.',
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(color: s.inkSecondary),
                ),
              ),
              ],
            ),
          ),
        ],
      );
    }

    final s = AppScheme.of(context);
    final pad = AppSpacing.pagePadding(context);
    if (AppLayout.isPhone(context)) {
      // 496 dp of fixed table columns cannot live on a 379 dp column, so the
      // phone reads the book in the shared list grammar: one card, one row
      // per offer. Pull to refresh — it replaces the dropped Refresh button.
      return RefreshIndicator(
        onRefresh: () => _loadBook(silent: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(pad, AppSpacing.md, pad, AppSpacing.lg),
          children: [
            ListCard(children: [for (final o in _offers) _offerTile(o)]),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, AppSpacing.lg, pad, AppSpacing.lg),
      child: DataWell(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            // Column header strip.
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.md),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: s.edgeStrong)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 22),
                  _h('SWAP', flex: 4),
                  _h('PRICE', width: 150, align: TextAlign.right),
                  _h('STATUS', width: 90, align: TextAlign.center),
                  _h('NETWORK', width: 150, align: TextAlign.center),
                  const SizedBox(width: 84),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _offers.length,
                itemBuilder: (context, n) => _offerRow(_offers[n], n.isOdd),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _verifyIcon(SwapOffer o) {
    return Tooltip(
      message: o.verified
          ? 'Maker output & signature verified'
          : (o.verifyNote ?? 'Unverified'),
      child: Icon(
        o.verified ? Icons.verified_outlined : Icons.warning_amber_rounded,
        size: 16,
        color: o.verified ? AppColors.success : AppColors.warning,
      ),
    );
  }

  Widget _networkChip(SwapOffer o) {
    final s = AppScheme.of(context);
    if (o.network == 'mainnet') {
      return TagChip(label: 'MAINNET · view only', color: s.testnet);
    }
    if (o.network == 'testnet') {
      return TagChip(label: 'testnet', color: s.success);
    }
    return TagChip(label: 'unknown', color: s.inkFaint);
  }

  Widget _h(String label,
      {int? flex, double? width, TextAlign align = TextAlign.left}) {
    final s = AppScheme.of(context);
    final cell = Text(
      label,
      textAlign: align,
      style: AppTypography.navSection.copyWith(
        color: s.inkFaint,
        fontSize: 10,
        letterSpacing: 0.8,
      ),
    );
    if (width != null) return SizedBox(width: width, child: cell);
    return Expanded(flex: flex ?? 1, child: cell);
  }

  Widget _offerRow(SwapOffer o, bool zebra) {
    final s = AppScheme.of(context);
    return HoverRow(
      zebra: zebra,
      onTap: () => _showDetails(o),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: s.edge)),
        ),
        child: Row(
          children: [
            SizedBox(width: 22, child: Center(child: _verifyIcon(o))),
            // Swap pair: receive → pay.
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  AssetLogo(ticker: o.receive.ticker, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      '${o.receive.displayAmount} ${o.receive.ticker}',
                      style: AppTypography.numericSmall.copyWith(
                          color: s.ink, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    child:
                        Icon(Icons.arrow_forward, size: 14, color: s.inkFaint),
                  ),
                  AssetLogo(ticker: o.pay.ticker, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      '${o.pay.displayAmount} ${o.pay.ticker}',
                      style: AppTypography.numericSmall
                          .copyWith(color: s.inkSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 150,
              child: Text(
                o.priceDisplay,
                textAlign: TextAlign.right,
                style: AppTypography.numericSmall.copyWith(color: s.ink),
              ),
            ),
            SizedBox(
              width: 90,
              child: Center(
                child: StatusBadge(
                  label: o.available ? 'Open' : 'Filled',
                  variant:
                      o.available ? BadgeVariant.success : BadgeVariant.neutral,
                ),
              ),
            ),
            SizedBox(width: 150, child: Center(child: _networkChip(o))),
            SizedBox(
              width: 84,
              child: Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message: o.takeable
                      ? 'Verify, preview, and take this swap'
                      : (o.network == 'mainnet'
                          ? 'Mainnet order — this wallet signs testnet only'
                          : 'This order cannot be taken'),
                  child: TextButton(
                    onPressed:
                        o.takeable ? () => _takeProposal(o.proposalJson) : null,
                    child: const Text('Take'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Offer details dialog ──────────────────────────────────────────────────

  Widget _verifyBanner(BuildContext ctx, SwapOffer o) {
    final s = AppScheme.of(ctx);
    final color = o.verified ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            o.verified ? Icons.verified_outlined : Icons.warning_amber_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              o.verified
                  ? 'Maker output commitment & SIGHASH verified'
                  : 'Unverified: ${o.verifyNote ?? 'unknown'}',
              style: AppTypography.caption.copyWith(color: s.ink),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDetails(SwapOffer o) async {
    await showAppDialog<void>(context,
      builder: (ctx) {
        final s = AppScheme.of(ctx);
        return AppDialog(
          title: Row(
            children: [
              Icon(Icons.swap_horiz, color: AppColors.accent, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Flexible(child: Text('Swap order #${o.id}', overflow: TextOverflow.ellipsis)),
              const Spacer(),
              _networkChip(o),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _verifyBanner(ctx, o),
                  const SizedBox(height: AppSpacing.md),
                  _leg(ctx, 'You receive', o.receive, emphasize: true),
                  const SizedBox(height: AppSpacing.sm),
                  _leg(ctx, 'You pay', o.pay),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text('+ network fee (paid by you)',
                        style: AppTypography.caption
                            .copyWith(color: s.inkSecondary)),
                  ),
                  const Divider(height: AppSpacing.xl),
                  _kv(ctx, 'Price',
                      '${o.priceDisplay} ${o.pay.ticker}/${o.receive.ticker}'),
                  _kv(ctx, 'Status', o.available ? 'Open' : 'Filled'),
                  if (o.created.isNotEmpty) _kv(ctx, 'Listed', o.created),
                  if (!o.takeable) ...[
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: s.accentSoft,
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusSm),
                        border: Border.all(color: s.edge),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline,
                              size: 16, color: AppColors.accent),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              o.network == 'mainnet'
                                  ? 'This is a live mainnet order, shown for '
                                      'reference. This wallet signs on Liquid '
                                      'testnet only, so it cannot be taken here.'
                                  : 'This order cannot be taken right now.',
                              style: AppTypography.caption
                                  .copyWith(color: s.inkSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  CodeBox(value: o.proposalJson, label: 'Proposal (v0)'),
                ],
              ),
            ),
          ),
          actions: [
            GhostButton(
                label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
            SecondaryButton(
              label: 'Copy proposal',
              icon: Icons.copy,
              onPressed: () async {
                // Capture before the async gap so we never use a BuildContext
                // across it.
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(ctx);
                await Clipboard.setData(ClipboardData(text: o.proposalJson));
                navigator.pop();
                messenger.showSnackBar(
                  const SnackBar(content: Text('Proposal copied to clipboard')),
                );
              },
            ),
            if (o.takeable)
              PrimaryButton(
                label: 'Take',
                icon: Icons.swap_horiz,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _takeProposal(o.proposalJson);
                },
              ),
          ],
        );
      },
    );
  }

  Widget _leg(BuildContext ctx, String label, SwapLeg leg,
      {bool emphasize = false}) {
    final s = AppScheme.of(ctx);
    return Row(
      children: [
        AssetLogo(ticker: leg.ticker, size: 22),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(label,
              style: AppTypography.body.copyWith(color: s.inkSecondary)),
        ),
        Text(
          '${leg.displayAmount} ${leg.ticker}',
          style: emphasize
              ? AppTypography.numericLarge
                  .copyWith(fontSize: 18, color: AppColors.accent)
              : AppTypography.numericSmall.copyWith(color: s.ink),
        ),
      ],
    );
  }

  Widget _kv(BuildContext ctx, String k, String v) {
    final s = AppScheme.of(ctx);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(k,
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
          ),
          Expanded(
            child:
                Text(v, style: AppTypography.bodySmall.copyWith(color: s.ink)),
          ),
        ],
      ),
    );
  }

  // ── My Offers tab ─────────────────────────────────────────────────────────

  static String _fmtCreated(int unixSecs) {
    if (unixSecs <= 0) return '—';
    final d =
        DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static (BadgeVariant, String) _statusBadge(String status) =>
      switch (status) {
        'open' => (BadgeVariant.success, 'Open'),
        'closed' => (BadgeVariant.neutral, 'Closed'),
        'cancelled' => (BadgeVariant.warning, 'Cancelled'),
        _ => (BadgeVariant.neutral, status),
      };

  Widget _myOffersTab() {
    final s = AppScheme.of(context);
    if (_loadingMine) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_mineError != null) {
      return Center(
        child: Padding(
          padding: _statePad,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 32, color: AppColors.textMuted),
              const SizedBox(height: AppSpacing.md),
              Text('Could not load your offers', style: AppTypography.body),
              const SizedBox(height: AppSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  _mineError!,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              GhostButton(
                label: 'Retry',
                icon: Icons.refresh,
                isFullWidth: AppLayout.isPhone(context),
                onPressed: _loadMine,
              ),
            ],
          ),
        ),
      );
    }
    if (_myOffers.isEmpty) {
      return Center(
        child: Padding(
          padding: _statePad,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.storefront_outlined, size: 36, color: s.inkFaint),
              const SizedBox(height: AppSpacing.md),
              Text('No offers yet', style: AppTypography.body),
              const SizedBox(height: AppSpacing.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Text(
                  'Press "Make offer" to sign a LiquiDEX proposal from one of '
                  'your Liquid coins and share it with a counterparty.',
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(color: s.inkSecondary),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Make offer',
                icon: Icons.add,
                isFullWidth: AppLayout.isPhone(context),
                onPressed: _makeOffer,
              ),
            ],
          ),
        ),
      );
    }

    final pad = AppSpacing.pagePadding(context);
    if (AppLayout.isPhone(context)) {
      // Same grammar as the order book: one card, one row per offer, pulled
      // to refresh.
      return RefreshIndicator(
        onRefresh: () => _loadMine(silent: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(pad, AppSpacing.md, pad, AppSpacing.lg),
          children: [
            ListCard(children: [for (final o in _myOffers) _myOfferTile(o)]),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, AppSpacing.lg, pad, AppSpacing.lg),
      child: DataWell(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.md),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: s.edgeStrong)),
              ),
              child: Row(
                children: [
                  _h('OFFER', flex: 4),
                  _h('CREATED', width: 140),
                  _h('STATUS', width: 100, align: TextAlign.center),
                  const SizedBox(width: 180),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _myOffers.length,
                itemBuilder: (context, n) =>
                    _myOfferRow(_myOffers[n], n.isOdd),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Phone rows ────────────────────────────────────────────────────────────

  /// One order-book row in the phone's list grammar.
  ///
  /// The verify state becomes the row's glyph and tint — the same two icons
  /// and the same success/warning pair the desktop table paints in its 22 dp
  /// verify column, so the check is no less visible for having moved. Network
  /// rides in the subtitle, tinted with the testnet ink when the order is a
  /// mainnet one this wallet can only look at.
  ///
  /// The per-row "Take" text link is gone: the detail sheet this row opens
  /// already carries Take as a primary button, and it puts the verify banner
  /// and the whole proposal on screen before the user commits to a swap.
  Widget _offerTile(SwapOffer o) {
    final s = AppScheme.of(context);
    final mainnet = o.network == 'mainnet';
    return ListRow(
      icon: o.verified ? Icons.verified_outlined : Icons.warning_amber_rounded,
      tint: o.verified ? s.success : s.warning,
      title: '${o.receive.displayAmount} ${o.receive.ticker} → '
          '${o.pay.displayAmount} ${o.pay.ticker}',
      subtitle: mainnet
          ? '${o.priceDisplay} · mainnet — view only'
          : '${o.priceDisplay} · ${o.network}',
      subtitleColor: mainnet ? s.testnet : null,
      trailing: StatusBadge(
        label: o.available ? 'Open' : 'Filled',
        variant: o.available ? BadgeVariant.success : BadgeVariant.neutral,
      ),
      chevron: true,
      onTap: () => _showDetails(o),
    );
  }

  /// One of this wallet's own offers, same grammar.
  ///
  /// Both text links the card used to carry are dropped: "Proposal" did what
  /// tapping the row already does, and "Cancel" lives in the detail sheet as
  /// a danger button — which is where its confirmation dialog is anyway.
  Widget _myOfferTile(MyOffer o) {
    final s = AppScheme.of(context);
    final (variant, label) = _statusBadge(o.status);
    return ListRow(
      icon: Icons.storefront_outlined,
      tint: s.accent,
      title: '${o.offers.displayAmount} ${o.offers.ticker} → '
          '${o.wants.displayAmount} ${o.wants.ticker}',
      subtitle: _fmtCreated(o.createdAt),
      trailing: StatusBadge(label: label, variant: variant),
      chevron: true,
      onTap: () => _showMyOfferDetails(o),
    );
  }

  Widget _myOfferRow(MyOffer o, bool zebra) {
    final s = AppScheme.of(context);
    final (variant, label) = _statusBadge(o.status);
    return HoverRow(
      zebra: zebra,
      onTap: () => _showMyOfferDetails(o),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: s.edge)),
        ),
        child: Row(
          children: [
            // Offer pair: offers → wants.
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  AssetLogo(ticker: o.offers.ticker, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      '${o.offers.displayAmount} ${o.offers.ticker}',
                      style: AppTypography.numericSmall.copyWith(
                          color: s.ink, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    child:
                        Icon(Icons.arrow_forward, size: 14, color: s.inkFaint),
                  ),
                  AssetLogo(ticker: o.wants.ticker, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      '${o.wants.displayAmount} ${o.wants.ticker}',
                      style: AppTypography.numericSmall
                          .copyWith(color: s.inkSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 140,
              child: Text(
                _fmtCreated(o.createdAt),
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ),
            SizedBox(
              width: 100,
              child: Center(
                  child: StatusBadge(label: label, variant: variant)),
            ),
            SizedBox(
              width: 180,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _showMyOfferDetails(o),
                    child: const Text('Proposal'),
                  ),
                  if (o.status == 'open')
                    TextButton(
                      onPressed:
                          _cancelling ? null : () => _cancelOffer(o),
                      child: Text('Cancel',
                          style: TextStyle(color: AppColors.danger)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMyOfferDetails(MyOffer o) async {
    final (variant, label) = _statusBadge(o.status);
    await showAppDialog<void>(context,
      builder: (ctx) {
        final s = AppScheme.of(ctx);
        return AppDialog(
          title: Row(
            children: [
              Icon(Icons.storefront_outlined,
                  color: AppColors.accent, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Flexible(child: Text('Offer ${o.offerId}', overflow: TextOverflow.ellipsis)),
              const Spacer(),
              StatusBadge(label: label, variant: variant),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _leg(ctx, 'You offer', o.offers, emphasize: true),
                  const SizedBox(height: AppSpacing.sm),
                  _leg(ctx, 'You want', o.wants),
                  const Divider(height: AppSpacing.xl),
                  _kv(ctx, 'Created', _fmtCreated(o.createdAt)),
                  _kv(ctx, 'Coin', o.utxo),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'The proposal stays valid until the offered coin is '
                    'spent. Publish it by pasting at liquidex.it/proposal, '
                    'or share it directly with a counterparty.',
                    style:
                        AppTypography.caption.copyWith(color: s.inkSecondary),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  CodeBox(value: o.proposalJson, label: 'Proposal (v0)'),
                ],
              ),
            ),
          ),
          actions: [
            GhostButton(
                label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
            if (o.status == 'open')
              DangerButton(
                label: 'Cancel offer',
                icon: Icons.cancel_outlined,
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _cancelOffer(o);
                },
              ),
            SecondaryButton(
              label: 'Copy proposal',
              icon: Icons.copy,
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(ctx);
                await Clipboard.setData(ClipboardData(text: o.proposalJson));
                navigator.pop();
                messenger.showSnackBar(
                  const SnackBar(content: Text('Proposal copied to clipboard')),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
