import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/relative_time.dart';
import '../../shared/widgets/asset_logo.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/chain_switch.dart';
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
import '../utxos/models/pending_consolidation.dart';
import '../../services/pending_consolidation_store.dart';
import 'models/transaction.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _bridge = walletBridge;
  List<Transaction> _txs = [];
  bool _loading = true;
  String? _error;
  String _chainFilter = 'all';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final appState = context.read<AppState>();
    if (appState.cachedTransactions != null) {
      _txs = appState.cachedTransactions!;
      _loading = false;
    }
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final appState = context.read<AppState>();
    final walletId = appState.activeWalletId ?? 'wallet-1';
    // A bridge failure must not strand the spinner; cached rows (if any)
    // keep showing, otherwise the error card takes over.
    final List<Transaction> txs;
    try {
      txs = await _bridge.listActivity(walletId);
    } catch (e) {
      if (mounted && appState.cachedTransactions == null) {
        setState(() { _loading = false; _error = e.toString(); });
      }
      return;
    }
    // A just-broadcast consolidation is in no node's answer yet — BDK only
    // learns about it on the next sync. Without this the coins vanish from
    // UTXOs while Activity shows nothing at all, which reads as a lost
    // transaction.
    final merged = await _withPendingConsolidations(walletId, txs);
    if (mounted) {
      appState.cachedTransactions = merged;
      setState(() { _txs = merged; _loading = false; _error = null; });
    }
  }

  /// Prepends rows for consolidations the wallet engine has not caught up
  /// with. Once a sync returns the real transaction the placeholder is
  /// dropped, because the txid is then already in [txs].
  Future<List<Transaction>> _withPendingConsolidations(
      String walletId, List<Transaction> txs) async {
    final List<PendingConsolidation> pending;
    try {
      pending = await PendingConsolidationStore.instance.listAllFor(walletId);
    } catch (_) {
      return txs;
    }
    if (pending.isEmpty) return txs;
    final known = txs.map((t) => t.txid).toSet();
    final extra = pending
        .where((p) => !known.contains(p.txid))
        .map((p) => Transaction(
              txid: p.txid,
              direction: TxDirection.self,
              chain:
                  p.chainKey == 'liquid' ? TxChain.liquid : TxChain.bitcoin,
              // Approximate: the real output is the inputs minus the fee, and
              // the exact figure only exists once the tx confirms.
              amount: '~${p.displayAmount}',
              ticker: p.ticker ?? 'BTC',
              timestamp: p.startedAt,
              confirmations: 0,
              note: p.activityNote,
            ))
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return [...extra, ...txs];
  }

  bool get _hasFilter =>
      _chainFilter != 'all' || _searchController.text.isNotEmpty;

  List<Transaction> get _filtered {
    return _txs.where((tx) {
      if (_chainFilter == 'bitcoin' && tx.chain != TxChain.bitcoin) return false;
      if (_chainFilter == 'liquid' && tx.chain != TxChain.liquid) return false;
      final q = _searchController.text.trim().toLowerCase();
      if (q.isEmpty) return true;
      // Amounts carry an upper-case ticker ('+0.001 BTC', '-12.50 USDT'), so
      // both sides are lower-cased or 'btc' would never match.
      return tx.txid.contains(q) ||
          (tx.note?.toLowerCase().contains(q) ?? false) ||
          tx.amount.toLowerCase().contains(q) ||
          tx.ticker.toLowerCase().contains(q);
    }).toList();
  }

  /// Builds date-keyed sections, each holding its transactions.
  List<({String date, List<Transaction> txs})> get _grouped {
    final items = _filtered;
    if (items.isEmpty) return [];

    final result = <({String date, List<Transaction> txs})>[];
    String? lastDate;

    for (final tx in items) {
      final dateKey = _dateKey(tx);
      if (dateKey != lastDate) {
        result.add((date: dateKey, txs: []));
        lastDate = dateKey;
      }
      result.last.txs.add(tx);
    }
    return result;
  }

  static String _dateKey(Transaction tx) {
    // Unconfirmed transactions carry no block time: both engines report 0,
    // which formats as 1 JAN 1970 and sinks the newest transaction in the
    // wallet to the bottom of the page.
    if (tx.confirmations == 0) return 'PENDING';
    final dt = tx.timestamp;
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'
    ];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    if (d == today) return 'TODAY';
    if (d == today.subtract(const Duration(days: 1))) return 'YESTERDAY';
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final grouped = _grouped;
    final st = context.watch<AppState>();
    final phone = AppSpacing.isPhone(context);
    final pad = AppSpacing.pagePadding(context);

    // Title, chain switch, privacy eye and the search field. On a phone the
    // subtitle goes (the title is a label there) and the search field gets a
    // clear button and a search key; PrivacyToggle grows its own 48 dp
    // target there.
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Activity',
          subtitle: phone ? null : 'Cross-chain transaction history',
          actions: [
            const PrivacyToggle(),
            // Chain choice sits top-right on UTXOs, Receive and
            // here alike — the same control in the same place on
            // every per-chain screen, always present.
            ChainSwitch<String>(
              selected: _chainFilter,
              onChanged: (v) => setState(() => _chainFilter = v),
              all: 'all',
              bitcoin: 'bitcoin',
              liquid: 'liquid',
              bitcoinEnabled: st.activeWalletBitcoin,
              liquidEnabled: st.activeWalletLiquid,
            ),
          ],
        ),
        // Second row: what this section does with the chain chosen
        // above.
        Row(
          children: [
            Expanded(
              child: phone
                  ? TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: 'Search by txid or note…',
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                    )
                  : TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: 'Search by txid or note…',
                        prefixIcon: Icon(Icons.search, size: 18),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
            ),
          ],
        ),
        SizedBox(height: phone ? AppSpacing.sm : AppSpacing.lg),
      ],
    );

    Widget section(int i) {
      final s = grouped[i];
      final rows = [
        for (final tx in s.txs)
          _TxRow(tx: tx, onTap: () => _showDetail(context, tx)),
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DateHeader(label: s.date),
          // A day's transactions are one list card on a phone — the same
          // panel, hairlines and radius the Dashboard's activity sits on, so
          // a run of rows is the same object on both screens. GlassCard's
          // gradient has nothing to bleed through on the flat phone canvas
          // anyway. Desktop keeps the glass panel and its own dividers.
          phone
              ? ListCard(children: rows)
              : GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.cardPaddingSmall,
                    vertical: AppSpacing.xs,
                  ),
                  child: Column(
                    children: [
                      for (int j = 0; j < rows.length; j++) ...[
                        rows[j],
                        if (j != rows.length - 1)
                          Divider(
                            height: 1,
                            color: isDark
                                ? AppColors.borderDark
                                : AppColors.borderLight,
                          ),
                      ],
                    ],
                  ),
                ),
          // 16 on both: with the phone card carrying its own hairline border,
          // the old 12 read as one continuous list rather than as days.
          const SizedBox(height: AppSpacing.lg),
        ],
      );
    }

    void retry() {
      setState(() { _loading = true; _error = null; });
      _load();
    }

    if (phone) {
      // One scroll view: the header scrolls away with the list, so with the
      // keyboard up for a txid search the rows still have most of the
      // screen. It is the depth-0 vertical scrollable, which is what the
      // shell's scroll-to-top listens for.
      return Scaffold(
        body: PageBackground.flat(
          child: CustomScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(pad, AppSpacing.lg, pad, 0),
                sliver: SliverToBoxAdapter(child: header),
              ),
              if (_loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: EdgeInsets.all(pad),
                    child: _LoadError(message: _error!, onRetry: retry),
                  ),
                )
              else if (grouped.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(
                    filtered: _hasFilter,
                    onClear: () => setState(() {
                      _chainFilter = 'all';
                      _searchController.clear();
                    }),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, AppSpacing.xl),
                  sliver: SliverList.builder(
                    itemCount: grouped.length,
                    itemBuilder: (context, i) => section(i),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: PageBackground.flat(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
              child: header,
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _LoadError(message: _error!, onRetry: retry)
                      : grouped.isEmpty
                      ? Center(
                          child: Text('No transactions found',
                              style: AppTypography.caption))
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(pad, 0, pad, AppSpacing.xl),
                          itemCount: grouped.length,
                          itemBuilder: (context, i) => section(i),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, Transaction tx) {
    final appState = context.read<AppState>();
    // On a phone the sheet must cover the whole screen — header and carousel
    // included — so it goes on the root navigator, not the shell's nested
    // one, where it would stop above the nav bar and leave it live.
    final phone = AppSpacing.isPhone(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: phone,
      useSafeArea: phone,
      backgroundColor: Colors.transparent,
      builder: (_) => _TxDetailSheet(
        tx: tx,
        btcExplorerUrl: appState.btcExplorerUrl,
        liquidExplorerUrl: appState.liquidExplorerUrl,
      ),
    );
  }
}

// ── Load failure ──────────────────────────────────────────────────────────────
// Shown only when the load failed and there is no cached history to fall
// back on — an empty list is NOT an error and keeps its own message.

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppSpacing.isPhone(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: s.danger),
              const SizedBox(height: AppSpacing.md),
              Text('Could not load activity',
                  style: AppTypography.sectionTitleOf(context)),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center,
                // A raw FFI error can run for paragraphs; on a phone it must
                // not push the Retry button under the nav bar.
                maxLines: phone ? 6 : null,
                overflow: phone ? TextOverflow.ellipsis : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                  label: 'Retry', onPressed: onRetry, isFullWidth: phone),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Empty state (phone) ───────────────────────────────────────────────────────
// Tells "no transactions yet" apart from "nothing matches the filter", and
// offers the way back from the second.

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filtered, required this.onClear});
  final bool filtered;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Same glyphs, on the inset tile every other phone glyph sits on
            // — the empty state stops being the one place one floats.
            ListIconTile(
              icon: filtered
                  ? Icons.search_off_rounded
                  : Icons.receipt_long_outlined,
              tint: s.inkSecondary,
              size: 56,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              filtered ? 'No matches' : 'No transactions yet',
              style: AppTypography.sectionTitleOf(context),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              filtered
                  ? 'Nothing matches this chain or search.'
                  : 'Received and sent transactions show up here.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
              textAlign: TextAlign.center,
            ),
            if (filtered) ...[
              const SizedBox(height: AppSpacing.md),
              // The shared tertiary rather than a bare TextButton: it is the
              // only control on the screen when a filter matches nothing, and
              // this way it inherits the phone slab (54 dp) centrally instead
              // of staying the smallest tap target here.
              GhostButton(label: 'Clear filters', onPressed: onClear),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Date header ───────────────────────────────────────────────────────────────

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final phone = AppSpacing.isPhone(context);
    if (phone) {
      // A day is a section label like any other on a phone — the same object
      // over 'TODAY' as over the Dashboard's 'RECENT ACTIVITY'. It brings its
      // own ink, letter spacing, left inset and bottom gap; only the gap
      // above the group is ours. The keys are already uppercase, so nothing
      // reads differently for its uppercasing them.
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: ListSectionLabel(label: label),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(
        top: phone ? AppSpacing.md : AppSpacing.lg,
        bottom: phone ? AppSpacing.xs : AppSpacing.sm,
      ),
      child: Text(
        label,
        style: AppTypography.navSection.copyWith(
          color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

// ── Transaction row ───────────────────────────────────────────────────────────

class _TxRow extends StatelessWidget {
  const _TxRow({required this.tx, required this.onTap});
  final Transaction tx;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final isIn = tx.direction == TxDirection.incoming;

    if (AppSpacing.isPhone(context)) {
      // The row the Dashboard draws under RECENT ACTIVITY, field for field:
      // its 'All →' link lands straight here, so the same transaction must
      // not change shape mid-tap. Same Material glyphs as the desktop row
      // below, in the _rounded variants the phone list grammar uses.
      final isSelf = tx.direction == TxDirection.self;
      final masked = balancesHidden(context);
      return ListRow(
        icon: isSelf
            ? Icons.autorenew_rounded
            : isIn
                ? Icons.south_west_rounded
                : Icons.north_east_rounded,
        tint: isIn ? s.success : s.inkSecondary,
        title: tx.note ?? tx.directionLabel,
        // Which chain, how far it has settled, how long ago — the three
        // things a row of activity is asked, in that order.
        subtitle: <String>[
          tx.chain == TxChain.bitcoin ? 'Bitcoin' : 'Liquid',
          if (tx.isConfirmed) '${tx.confirmations} conf.' else 'Unconfirmed',
          // An unconfirmed transaction carries no block time — both engines
          // report 0 — so its age would read '1 Jan 1970'. Same trap
          // _dateKey guards against.
          if (tx.isConfirmed) relativeTimeShort(tx.timestamp),
        ].join(' · '),
        subtitleColor: tx.isConfirmed ? null : s.warning,
        onTap: onTap,
        // ListAmount takes a plain String and masks nothing of its own, so
        // the privacy eye has to be honoured here or it stops covering this
        // screen.
        trailing: ListAmount(
          value: masked ? kMaskedAmount : tx.amount,
          unit: masked ? null : tx.fiatEstimate,
          valueColor: isIn ? s.success : s.ink,
          maxWidth: 132,
        ),
      );
    }

    final color = isIn ? s.success : s.ink;
    final icon = isIn ? Icons.south_west : Icons.north_east;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Asset logo (orange BTC / teal LBTC / teal token) with a small
    // direction badge so in/out stays readable at a glance.
    final logo = SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AssetLogo(ticker: tx.ticker, size: 36),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: isDark
                    ? AppColors.surfaceDark
                    : AppColors.surfaceLight,
                shape: BoxShape.circle,
              ),
              child: Icon(icon,
                  size: 11, color: isIn ? s.success : s.inkSecondary),
            ),
          ),
        ],
      ),
    );
    final chainBadge = StatusBadge(
      label: tx.chain == TxChain.bitcoin ? 'BTC' : 'Liquid',
      variant: tx.chain == TxChain.bitcoin
          ? BadgeVariant.accent
          : BadgeVariant.warning,
    );
    final confStyle = AppTypography.caption.copyWith(
      color: tx.isConfirmed ? AppColors.success : AppColors.warning,
    );
    final confText = tx.isConfirmed ? '${tx.confirmations} conf.' : 'Unconfirmed';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            logo,
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(tx.shortTxid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.mono.copyWith(fontSize: 12)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      chainBadge,
                    ],
                  ),
                  Row(
                    children: [
                      Text(confText, style: confStyle),
                      if (tx.note != null) ...[
                        Text('  ·  ', style: AppTypography.caption),
                        Flexible(
                          child: Text(tx.note!,
                              style: AppTypography.caption,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Amount(tx.amount,
                    style: AppTypography.numeric.copyWith(
                        fontSize: 14.5,
                        color: color,
                        fontWeight: FontWeight.w600)),
                if (tx.fiatEstimate != null)
                  Amount(tx.fiatEstimate!,
                      style: AppTypography.numericSmall
                          .copyWith(color: s.inkSecondary, fontSize: 12)),
              ],
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Detail bottom sheet ───────────────────────────────────────────────────────

class _TxDetailSheet extends StatelessWidget {
  const _TxDetailSheet({
    required this.tx,
    required this.btcExplorerUrl,
    required this.liquidExplorerUrl,
  });
  final Transaction tx;
  final String btcExplorerUrl;
  final String liquidExplorerUrl;

  String _explorerUrl() {
    final base = tx.chain == TxChain.liquid ? liquidExplorerUrl : btcExplorerUrl;
    final baseTrimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$baseTrimmed/tx/${tx.txid}';
  }

  Future<void> _openExplorer(BuildContext context) async {
    final url = _explorerUrl();
    final uri = Uri.parse(url);
    // launchUrl answers false (or throws on some OEM builds and restricted
    // work profiles) when nothing can take an https VIEW intent; a silent
    // no-op there reads as a dead button, so the link goes to the clipboard
    // with a word about it.
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
      content: Text("Couldn't open a browser — explorer link copied"),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final isDark = s.isDark;
    final isIn = tx.direction == TxDirection.incoming;
    final amountColor = isIn ? s.success : s.danger;
    final phone = AppSpacing.isPhone(context);
    // A root-navigator sheet on an edge-to-edge phone runs under the gesture
    // bar; the content clears it while the surface keeps the screen bottom.
    final bottomInset = phone ? MediaQuery.viewPaddingOf(context).bottom : 0.0;

    // Same glyph, same ink either way. On a phone it sits on the inset tile
    // the rows behind this sheet all use, rather than on a tinted wash that
    // is a surface step the phone uses nowhere else.
    final iconTile = phone
        ? ListIconTile(
            icon: isIn ? Icons.call_received : Icons.send,
            tint: amountColor,
            size: 40,
          )
        : Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: amountColor.withValues(alpha: isDark ? 0.18 : 0.12),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            ),
            child: Icon(
              isIn ? Icons.call_received : Icons.send,
              size: 20,
              color: amountColor,
            ),
          );
    final chainBadge = StatusBadge(
      label: tx.chain == TxChain.bitcoin ? 'Bitcoin' : 'Liquid',
      variant: tx.chain == TxChain.bitcoin
          ? BadgeVariant.accent
          : BadgeVariant.warning,
    );
    final title = isIn ? 'Received' : 'Sent';

    final Widget header;
    if (phone) {
      // Title line, then the amount on its own line: at 19 px a real amount
      // is ~180 dp and shares no row with a title and a badge at 379 dp.
      header = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              iconTile,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: AppTypography.sectionTitleOf(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    chainBadge,
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Amount(
                    tx.amount,
                    maxLines: 1,
                    style: AppTypography.numericLargeOf(context)
                        .copyWith(color: amountColor),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              const PrivacyToggle(size: 20),
            ],
          ),
        ],
      );
    } else {
      header = Row(
        children: [
          iconTile,
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.sectionTitle),
                chainBadge,
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Amount(
                tx.amount,
                style: AppTypography.numericLarge
                    .copyWith(color: amountColor),
              ),
              const SizedBox(width: AppSpacing.xs),
              const PrivacyToggle(size: 16),
            ],
          ),
        ],
      );
    }

    return SheetSurface(
      topMargin: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              decoration: BoxDecoration(
                color: s.edgeStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: phone
                  ? EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm,
                      AppSpacing.lg, AppSpacing.lg + bottomInset)
                  : const EdgeInsets.fromLTRB(AppSpacing.xxl, AppSpacing.sm,
                      AppSpacing.xxl, AppSpacing.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xl),

                  // Details table
                  _DetailRow(label: 'Status',
                      value: tx.isConfirmed
                          ? '${tx.confirmations} confirmations'
                          : 'Unconfirmed',
                      valueColor: tx.isConfirmed ? s.success : s.warning),
                  _DetailRow(label: 'Date',
                      value: _formatDate(tx.timestamp)),
                  _DetailRow(label: 'Ticker', value: tx.ticker),
                  if (tx.fee != null)
                    _DetailRow(label: 'Fee', value: tx.fee!),
                  if (tx.fiatEstimate != null)
                    _DetailRow(label: 'Est. value', value: tx.fiatEstimate!),
                  if (tx.note != null)
                    _DetailRow(label: 'Note', value: tx.note!),
                  if (tx.counterparty != null)
                    _DetailRow(label: 'Counterparty', value: tx.counterparty!),

                  const SizedBox(height: AppSpacing.lg),

                  // TXID — full, selectable, copy with feedback.
                  CodeBox(value: tx.txid, label: 'Transaction ID'),

                  SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xl),

                  // Actions. On a phone this is the shared secondary, so its
                  // height, radius and fill come from the one place that owns
                  // them instead of from a local minimumSize patch here.
                  phone
                      ? SecondaryButton(
                          label: 'View on Explorer',
                          icon: Icons.open_in_new,
                          onPressed: () => _openExplorer(context),
                          isFullWidth: true,
                        )
                      : SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => _openExplorer(context),
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('View on Explorer'),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}  $h:$m';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final valueText = Text(
      value,
      style: AppTypography.bodySmall.copyWith(
          fontWeight: FontWeight.w500,
          color: valueColor),
    );
    if (AppSpacing.isPhone(context)) {
      final s = AppScheme.of(context);
      // Label over value: no fixed label column to overflow at large font
      // scales, and a long counterparty address wraps across the full width.
      // The label is the app's uppercase micro-label — the same object that
      // captions a code box or a card — so 'Status' cannot be mistaken for
      // the value under it.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: AppTypography.navSection
                  .copyWith(letterSpacing: 1.3, color: s.inkFaint),
            ),
            const SizedBox(height: 3),
            valueText,
          ],
        ),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelText = Text(label,
        style: AppTypography.caption.copyWith(
            color: isDark ? AppColors.textMutedDark : AppColors.textMuted));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: labelText),
          Expanded(child: valueText),
        ],
      ),
    );
  }
}
