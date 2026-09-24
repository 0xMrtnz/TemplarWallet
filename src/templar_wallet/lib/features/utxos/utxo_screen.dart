import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../services/pending_consolidation_store.dart';
import '../../services/utxo_label_store.dart';
import '../../shared/widgets/psbt_sign_flow.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/chain_switch.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/segmented_switch.dart';
import '../../shared/widgets/privacy.dart';
import '../../shared/widgets/utxo_views.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/pending_consolidation.dart';
import 'models/utxo.dart';

/// How the UTXO set is rendered.
enum UtxoViewMode { notes, list }

class UtxoScreen extends StatefulWidget {
  const UtxoScreen({super.key, this.bridge});

  /// Test seam; the app uses the global [walletBridge].
  final WalletBridge? bridge;

  @override
  State<UtxoScreen> createState() => _UtxoScreenState();
}

class _UtxoScreenState extends State<UtxoScreen>
    with WidgetsBindingObserver {
  static const _kViewModePref = 'pref_utxo_view_mode';

  late final WalletBridge _bridge = widget.bridge ?? walletBridge;
  List<Utxo> _utxos = [];
  bool _loading = true;
  String? _error;
  String _chain = 'BTC';

  UtxoViewMode _viewMode = UtxoViewMode.notes;
  String _sortBy = 'amount'; // 'amount' | 'label'
  bool _sortAsc = false;

  // ── Consolidation (inline, no separate screen) ──────────────────────────
  bool _consolidateMode = false;
  bool _sending = false;
  String? _consolidateError;
  String _feePreset = 'normal'; // 'slow' | 'normal' | 'fast' | 'custom'
  final _customFeeCtrl = TextEditingController();

  /// Consolidations broadcast but not yet confirmed. Their inputs are hidden
  /// and replaced by one grey placeholder each.
  List<PendingConsolidation> _pending = [];

  @override
  void initState() {
    super.initState();
    // A wallet without a Bitcoin side has nothing to show on the default
    // chain; open on the one it has.
    final st = context.read<AppState>();
    if (!st.activeWalletBitcoin && st.activeWalletLiquid) _chain = 'Liquid';
    // A phone is backgrounded for hours; the pending-consolidation poll must
    // not keep hitting Electrum from a pocket. Desktop windows stay as they
    // were.
    if (AppLayout.isMobilePlatform) WidgetsBinding.instance.addObserver(this);
    _loadViewPref();
    _load();
  }

  @override
  void dispose() {
    if (AppLayout.isMobilePlatform) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _pendingPoll?.cancel();
    _customFeeCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _pendingPoll?.cancel();
        _pendingPoll = null;
      case AppLifecycleState.resumed:
        // One immediate check — a block may well have landed meanwhile —
        // then the periodic poll resumes if anything is still in flight.
        if (_pending.isNotEmpty && mounted) _load();
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// Re-checks the node while a consolidation is in flight. Without this the
  /// grey block would sit there until the user navigated away and back, even
  /// after the transaction confirmed.
  Timer? _pendingPoll;

  void _syncPendingPoll() {
    if (_pending.isEmpty) {
      _pendingPoll?.cancel();
      _pendingPoll = null;
      return;
    }
    // A block is ~10 minutes; a minute is responsive without hammering
    // Electrum, and each tick is the same call the screen already makes.
    _pendingPoll ??= Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _load();
    });
  }

  Future<void> _loadViewPref() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_kViewModePref);
    final mode = UtxoViewMode.values
        .where((m) => m.name == saved)
        .firstOrNull;
    if (mode != null && mounted) setState(() => _viewMode = mode);
  }

  Future<void> _setViewMode(UtxoViewMode mode) async {
    setState(() => _viewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kViewModePref, mode.name);
  }

  Future<void> _load() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    final List<Utxo> utxos;
    try {
      utxos = await _bridge.listUtxos(walletId, _chain);
    } catch (e) {
      // Drop coins from the previous chain — an error card floating over
      // another chain's UTXOs would misattribute them.
      if (mounted) {
        setState(() { _utxos = []; _loading = false; _error = e.toString(); });
      }
      return;
    }
    // Merge persisted labels
    final labels = await UtxoLabelStore.instance.getAllLabels();
    final withLabels = utxos.map((u) {
      final saved = labels[u.outpoint];
      return saved != null ? u.copyWith(label: saved) : u;
    }).toList();

    final pending = await _reconcilePending(walletId, withLabels);

    if (mounted) {
      setState(() {
        _utxos = _withoutPending(withLabels, pending);
        _pending = pending;
        _loading = false;
        _error = null;
      });
      _syncPendingPoll();
    }
  }

  /// Drops any consolidation whose output has landed AND confirmed, and returns
  /// the ones still in flight.
  ///
  /// Confirmation is the bar, not mere appearance: between broadcast and the
  /// first block the output shows up as unconfirmed, and swapping the
  /// placeholder for a coin that can still be replaced would be a lie.
  Future<List<PendingConsolidation>> _reconcilePending(
    String walletId,
    List<Utxo> utxos,
  ) async {
    final store = PendingConsolidationStore.instance;
    final live = await store.listFor(walletId: walletId, chain: _chain);
    final stillPending = <PendingConsolidation>[];
    for (final p in live) {
      final settled = utxos.any((u) =>
          p.isSettledBy(u.outpoint) && u.state != UtxoState.unconfirmed);
      if (settled) {
        await store.remove(p.txid);
      } else {
        stillPending.add(p);
      }
    }
    return stillPending;
  }

  /// Hides the coins a pending consolidation spends, plus its own unconfirmed
  /// output — otherwise the wall would briefly show both the inputs' successor
  /// and the placeholder standing for it.
  List<Utxo> _withoutPending(
    List<Utxo> utxos,
    List<PendingConsolidation> pending,
  ) {
    if (pending.isEmpty) return utxos;
    final spent = <String>{for (final p in pending) ...p.inputs};
    return utxos
        .where((u) =>
            !spent.contains(u.outpoint) &&
            !pending.any((p) => p.isSettledBy(u.outpoint)))
        .toList();
  }

  void _toggle(int i) {
    // A coin still in the mempool cannot be tagged or merged; the row and
    // the note already refuse the tap, this is the belt to their braces.
    if (_utxos[i].isPending) return;
    // Merging spends, and a frozen coin is never spent: say so rather than
    // let the selection count up coins the transaction will leave behind.
    if (_consolidateMode && _utxos[i].isFrozen && !_utxos[i].isSelected) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Frozen coins are not consolidated — unfreeze it first'),
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    setState(() => _utxos[i] = _utxos[i].copyWith(isSelected: !_utxos[i].isSelected));
  }

  bool _freezing = false;

  /// Freezes [coins], or unfreezes them when [frozen] is false. The engine
  /// keeps the list; the screen reloads from it so what it shows is what
  /// the engine will enforce.
  Future<void> _setFrozen(List<Utxo> coins, {required bool frozen}) async {
    if (coins.isEmpty || _freezing) return;
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    setState(() => _freezing = true);
    try {
      await _bridge.setUtxosFrozen(
        walletId: walletId,
        chain: _chain,
        outpoints: [for (final u in coins) u.outpoint],
        frozen: frozen,
      );
      if (!mounted) return;
      final n = coins.length;
      final what = n == 1 ? '1 coin' : '$n coins';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(frozen
              ? 'Froze $what — the wallet will not spend ${n == 1 ? 'it' : 'them'}'
              : 'Unfroze $what'),
          behavior: SnackBarBehavior.floating,
        ));
      _clearSelection();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not ${frozen ? 'freeze' : 'unfreeze'}: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _freezing = false);
    }
  }

  /// One coin, from its details sheet.
  VoidCallback _toggleFrozenOf(Utxo u) =>
      () => _setFrozen([u], frozen: !u.isFrozen);

  /// The selection's freeze action: Unfreeze when every selected coin is
  /// frozen, Freeze otherwise (freezing one that already is changes
  /// nothing).
  bool get _selectionAllFrozen =>
      _selected.isNotEmpty && _selected.every((u) => u.isFrozen);

  void _clearSelection() {
    setState(() => _utxos = _utxos.map((u) => u.copyWith(isSelected: false)).toList());
  }

  Future<void> _tagSelected() async {
    final selected = _selected;
    if (selected.isEmpty) return;
    final controller = TextEditingController(
      text: selected.length == 1 ? (selected.first.label ?? '') : '',
    );
    final label = await showAppDialog<String>(
      context,
      builder: (ctx) => AppDialog(
        title: Text('Tag ${selected.length} UTXO${selected.length == 1 ? '' : 's'}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Label (leave empty to clear)'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        // On a phone this dialog is a bottom sheet, and its two actions are
        // the app's own filled buttons — the same pair the custom-fee sheet
        // next door shows. Desktop keeps the plain Material pair verbatim.
        actions: AppLayout.isPhone(ctx)
            ? [
                SecondaryButton(
                  label: 'Cancel',
                  onPressed: () => Navigator.of(ctx).pop(null),
                ),
                PrimaryButton(
                  label: 'Save',
                  onPressed: () => Navigator.of(ctx).pop(controller.text),
                ),
              ]
            : [
                TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(controller.text),
                  child: const Text('Save'),
                ),
              ],
      ),
    );
    if (label == null) return;
    for (final u in selected) {
      if (label.isEmpty) {
        await UtxoLabelStore.instance.removeLabel(u.outpoint);
      } else {
        await UtxoLabelStore.instance.setLabel(u.outpoint, label);
      }
    }
    if (mounted) {
      setState(() {
        _utxos = _utxos.map((u) {
          if (u.isSelected) {
            return label.isEmpty
                ? u.copyWith(clearLabel: true)
                : u.copyWith(label: label);
          }
          return u;
        }).toList();
      });
    }
  }

  /// Enters inline consolidation mode. Selection happens directly in the
  /// active view (banknotes or list) — no separate screen.
  void _enterConsolidate() {
    setState(() {
      _consolidateMode = true;
      _consolidateError = null;
    });
  }

  void _exitConsolidate() {
    setState(() {
      _consolidateMode = false;
      _sending = false;
      _consolidateError = null;
    });
  }

  /// Only spendable coins can be consolidated.
  List<Utxo> get _spendableSelected => _selected
      .where((u) => u.state == UtxoState.available || u.state == UtxoState.dusty)
      .toList();

  /// Fee presets per chain. Liquid fees are near-flat and tiny; BTC varies.
  List<(String, String, String, double)> get _feePresets => _chain == 'Liquid'
      ? const [
          ('slow', 'Slow', 'min relay', 0.1),
          ('normal', 'Normal', 'standard', 0.5),
          ('fast', 'Fast', 'priority', 1.0),
        ]
      : const [
          ('slow', 'Slow', '~60 min', 1.0),
          ('normal', 'Normal', '~30 min', 3.0),
          ('fast', 'Fast', '~10 min', 8.0),
        ];

  double get _feeRate {
    if (_feePreset == 'custom') return double.tryParse(_customFeeCtrl.text.trim()) ?? 0;
    return _feePresets.firstWhere((p) => p.$1 == _feePreset).$4;
  }

  /// Rough vsize for n P2WPKH/P2WSH inputs → 1 output.
  int get _estFeeSats {
    final n = _spendableSelected.length;
    if (n == 0) return 0;
    final vsize = 11 + 68 * n + 31;
    return (_feeRate * vsize).round();
  }

  Future<void> _runConsolidate() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    final merged = _spendableSelected;
    final outpoints = merged.map((u) => u.outpoint).toList();
    setState(() {
      _sending = true;
      _consolidateError = null;
    });
    try {
      // Two passes, never one: build the PSBT, show what it does with its QR,
      // sign it behind the app password, review the signed transaction, and
      // only then broadcast. A consolidation moves every selected coin at
      // once — it is the last thing that should happen on a single click.
      final unsigned = await _bridge.buildConsolidationPsbt(
        walletId: walletId,
        outpoints: outpoints,
        chain: _chain,
        feeRate: _feeRate,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      final txid = await showPsbtSignFlow(
        context,
        walletId: walletId,
        unsignedPsbt: unsigned,
        title: 'Consolidate coins',
        summary: 'Merging ${merged.length} coins into a single new coin of '
            'this wallet, minus the fee.',
      );
      // Cancelled at the review or the signature: nothing was broadcast, and
      // the selection stays exactly as the user left it.
      if (txid == null || !mounted) return;

      // Record BEFORE reloading: the merged coins have to disappear behind the
      // placeholder in the same frame the user sees, not after a round trip.
      final total = merged.fold<int>(0, (sum, u) => sum + u.amount);
      final pending = PendingConsolidation(
        txid: txid,
        walletId: walletId,
        chain: _chain,
        inputs: outpoints,
        amount: total,
        displayAmount: _formatSats(total),
        ticker: merged.isNotEmpty ? merged.first.ticker : null,
        startedAt: DateTime.now(),
      );
      await PendingConsolidationStore.instance.add(pending);
      if (!mounted) return;

      setState(() {
        _pending = [..._pending, pending];
        _utxos = _withoutPending(_utxos, _pending);
        _sending = false;
        _consolidateMode = false;
        _consolidateError = null;
      });
      _syncPendingPoll();

      // A blocking dialog here would hide the very thing it is announcing.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Consolidating ${merged.length} coins — '
            '${txid.substring(0, 12)}…',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _load();
    } catch (e) {
      if (mounted) setState(() { _sending = false; _consolidateError = e.toString(); });
    }
  }

  static String _formatSats(int sats) {
    if (sats >= 100000000) return '${(sats / 1e8).toStringAsFixed(8)} BTC';
    return '$sats sats';
  }

  List<Utxo> get _selected => _utxos.where((u) => u.isSelected).toList();
  int get _selectedTotal => _selected.fold(0, (s, u) => s + u.amount);

  /// Share/tier math is shared with [UtxoPicker] (utxo_views.dart).
  Map<String, int> get _assetTotals => utxoAssetTotals(_utxos);

  double _shareOf(Utxo u) => utxoShareOf(u, _assetTotals);

  /// How many coins are still on their way in.
  int get _pendingCount => _utxos.where((u) => u.isPending).length;

  /// How many coins the user froze.
  int get _frozenCount => _utxos.where((u) => u.isFrozen).length;

  /// "UTXOs", with what is pending and what is frozen when there is any.
  String get _countLabel => [
        'UTXOs',
        if (_pendingCount > 0) '$_pendingCount pending',
        if (_frozenCount > 0) '$_frozenCount frozen',
      ].join(' · ');

  /// UTXOs ordered for the table view by the active sort column. Coins that
  /// have not confirmed lead whatever the sort: they are the newest thing
  /// that happened to this wallet, the same place Activity puts them.
  List<int> get _sortedIndices {
    final idx = List<int>.generate(_utxos.length, (i) => i);
    int cmp(Utxo a, Utxo b) => switch (_sortBy) {
          'label' => (a.label ?? '').compareTo(b.label ?? ''),
          _ => a.amount.compareTo(b.amount),
        };
    idx.sort((a, b) {
      final ua = _utxos[a];
      final ub = _utxos[b];
      if (ua.isPending != ub.isPending) return ua.isPending ? -1 : 1;
      final c = cmp(ua, ub);
      return _sortAsc ? c : -c;
    });
    return idx;
  }

  /// Biggest first for the wall, pending coins ahead of everything — the
  /// wall reads as a value hierarchy with what is arriving on top.
  List<int> get _wallOrder {
    final idx = List<int>.generate(_utxos.length, (i) => i);
    idx.sort((a, b) {
      final ua = _utxos[a];
      final ub = _utxos[b];
      if (ua.isPending != ub.isPending) return ua.isPending ? -1 : 1;
      return ub.amount.compareTo(ua.amount);
    });
    return idx;
  }

  /// One coin on the wall: a provisional grey note while it is pending, a
  /// banknote sized by its tier once it has confirmed.
  Widget _wallNote(int i, {required bool compact}) {
    final u = _utxos[i];
    final share = _shareOf(u);
    if (u.isPending) {
      return PendingCoinNote(utxo: u, share: share, compact: compact);
    }
    return UtxoBanknote(
      utxo: u,
      tier: utxoTier(u, share),
      share: share,
      onTap: () => _toggle(i),
      compact: compact,
      onToggleFrozen: _toggleFrozenOf(u),
    );
  }

  void _setSort(String by) {
    setState(() {
      if (_sortBy == by) {
        _sortAsc = !_sortAsc;
      } else {
        _sortBy = by;
        _sortAsc = false;
      }
    });
  }

  // ── View modes ─────────────────────────────────────────────────────────────

  Widget _notesView() {
    final order = _wallOrder;
    if (AppLayout.isPhone(context)) {
      // One full-width note per row; the tier lives in the rail and the
      // amount size, not in the note's width (see UtxoBanknote.compact).
      final pad = AppSpacing.pagePadding(context);
      return ListView.builder(
        padding: EdgeInsets.fromLTRB(pad, AppSpacing.md, pad, AppSpacing.xl),
        itemCount: _pending.length + order.length,
        itemBuilder: (context, n) {
          if (n < _pending.length) {
            final p = _pending[n];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: ConsolidatingNote(
                count: p.count,
                displayAmount: p.displayAmount,
                txid: p.txid,
                size: const Size(double.infinity, 84),
              ),
            );
          }
          final i = order[n - _pending.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _wallNote(i, compact: true),
          );
        },
      );
    }
    return SingleChildScrollView(
      padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
      child: Wrap(
        spacing: AppSpacing.lg,
        runSpacing: AppSpacing.lg,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          // In-flight consolidations first: they are the most recent thing the
          // user did, and the coins they replace are gone from the wall.
          for (final p in _pending)
            ConsolidatingNote(
              count: p.count,
              displayAmount: p.displayAmount,
              txid: p.txid,
            ),
          for (final i in order) _wallNote(i, compact: false),
        ],
      ),
    );
  }

  /// The list: one card of hairline-separated rows (design.md — repeated
  /// things are one object), each with a tier glyph tile, the state chip,
  /// the share of holdings as the lead figure, the amount and a details
  /// button. Pending coins lead, consolidations in flight sit above the card.
  Widget _listView() {
    final s = AppScheme.of(context);

    Widget headerCell(String label, String? by,
        {int? flex, double? width, TextAlign align = TextAlign.left}) {
      final active = by != null && _sortBy == by;
      final main = align == TextAlign.right
          ? MainAxisAlignment.end
          : MainAxisAlignment.start;
      final cell = Row(
        mainAxisAlignment: main,
        children: [
          Text(
            label,
            style: AppTypography.navSection.copyWith(
              color: active ? AppColors.accent : s.inkFaint,
              fontSize: 10,
              letterSpacing: 0.8,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
          if (active) ...[
            const SizedBox(width: 3),
            Icon(
              _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 11,
              color: AppColors.accent,
            ),
          ],
        ],
      );
      final wrapped = by == null
          ? cell
          : InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => _setSort(by),
              child: cell,
            );
      if (width != null) return SizedBox(width: width, child: wrapped);
      return Expanded(flex: flex ?? 1, child: wrapped);
    }

    final phone = AppLayout.isPhone(context);
    // pagePadding is xxl on desktop, so the desktop list keeps its 32 dp.
    final pad = AppSpacing.pagePadding(context);

    // Phone: the fixed-column header has nothing to line up with above
    // stacked cards, so it becomes a pair of sort chips (tap the active one
    // to flip direction), sized for a finger.
    Widget sortChip(String label, String by) {
      final active = _sortBy == by;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _setSort(by),
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          child: Container(
            // 44 dp, not 54: a chip is not a button, and the list below is
            // the thing this row is meant to serve.
            constraints: const BoxConstraints(
                minHeight: AppLayout.minTouchTarget - 4),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              // Filled in both states — inset grey at rest, accent wash when
              // active. No hairline: nothing else on the phone has one.
              color: active ? s.accentSoft : s.panelInset,
              borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppTypography.bodySmall.copyWith(
                    color: active ? s.accent : s.inkSecondary,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    _sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 14,
                    color: s.accent,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (phone)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, AppSpacing.md, pad, AppSpacing.sm),
            child: Row(
              children: [
                Text(
                  // The uppercase micro-label every phone group carries
                  // (ListSectionLabel), so this control row labels itself the
                  // same way the lists do.
                  'SORT',
                  style: AppTypography.navSection.copyWith(
                    color: s.inkFaint,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                sortChip('Amount', 'amount'),
                const SizedBox(width: AppSpacing.sm),
                sortChip('Label', 'label'),
              ],
            ),
          )
        else
        // Column header — floats above the card stack, no chrome around it.
        Padding(
          padding: EdgeInsets.fromLTRB(
              pad + AppSpacing.lg,
              AppSpacing.lg,
              pad + AppSpacing.lg,
              AppSpacing.sm),
          child: Row(
            children: [
              // Mirrors CoinRow's desktop columns exactly (CoinColumns), plus
              // the card's own hairline border.
              const SizedBox(width: CoinColumns.textInset - AppSpacing.lg + 1),
              headerCell('COIN', 'label'),
              const SizedBox(width: AppSpacing.md),
              headerCell('STATE', null, width: CoinColumns.state),
              // Share orders the same way amount does; one arrow, not two.
              headerCell('SHARE', null,
                  width: CoinColumns.share, align: TextAlign.right),
              const SizedBox(width: AppSpacing.lg),
              headerCell('AMOUNT', 'amount',
                  width: CoinColumns.amount, align: TextAlign.right),
              const SizedBox(width: AppSpacing.sm + CoinColumns.info + 1),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, AppSpacing.xl),
            children: [
              // In-flight consolidations lead the list, same as the wall.
              for (final p in _pending)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: ConsolidatingNote(
                    count: p.count,
                    displayAmount: p.displayAmount,
                    txid: p.txid,
                    size: const Size(double.infinity, 84),
                  ),
                ),
              Reveal(
                child: CoinListCard(
                  children: [
                    for (final i in _sortedIndices)
                      CoinRow(
                        utxo: _utxos[i],
                        share: _shareOf(_utxos[i]),
                        // Percentages across mixed Liquid assets read as
                        // noise; the share is per asset, so it still
                        // means something, but a wall of "100%" for
                        // single-coin tokens does not.
                        showShare: _chain != 'Liquid',
                        onTap: () => _toggle(i),
                        compact: phone,
                        onToggleFrozen: _toggleFrozenOf(_utxos[i]),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _switchChain(String chain) {
    setState(() {
      _chain = chain;
      _loading = true;
      _error = null;
      // Consolidate mode is chain-specific (and Liquid never offers it).
      _consolidateMode = false;
      _sending = false;
      _consolidateError = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // A chain the wallet lacks stays on the switch, dimmed: asking the bridge
    // for its coins only yields a "wallet not open" error.
    final liquidEnabled =
        context.select<AppState, bool>((st) => st.activeWalletLiquid);
    final bitcoinEnabled =
        context.select<AppState, bool>((st) => st.activeWalletBitcoin);
    final phone = AppLayout.isPhone(context);
    final chainSwitch = ChainSwitch<String>(
      selected: _chain,
      onChanged: _switchChain,
      bitcoin: 'BTC',
      liquid: 'Liquid',
      bitcoinEnabled: bitcoinEnabled,
      liquidEnabled: liquidEnabled,
    );
    return Scaffold(
      body: PageBackground.flat(
        child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
            child: Column(
              // Phone: the header stacks its actions under the title, and a
              // Column with the default centre alignment would centre that
              // narrower block in the page — stretch pins it left.
              crossAxisAlignment: phone
                  ? CrossAxisAlignment.stretch
                  : CrossAxisAlignment.center,
              children: [
                PageHeader(
                  title: 'UTXOs',
                  // The carousel already names the screen on a phone.
                  subtitle: phone ? null : 'Coin control',
                  actions: [
                    // Owns its 48 dp hit area on a phone.
                    const PrivacyToggle(),
                    // Which chain's coins are on screen — the single most
                    // consequential control here, so it is the last thing
                    // top-right, always present, in the chain's own colour.
                    chainSwitch,
                    // Phone: the Notes/List switch is an icon toggle beside
                    // the chain switch; the stats row below has no room for
                    // the labelled one.
                    if (phone)
                      _ViewToggle(mode: _viewMode, onChanged: _setViewMode),
                  ],
                ),
                if (phone) ...[
                  Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          label: _countLabel,
                          value: '${_utxos.length}',
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _StatTile(
                            label: 'Selected', value: '${_selected.length}'),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        flex: 2,
                        child: _StatTile(
                          label: 'Selected total',
                          value: maskAmount(
                              context, _formatSats(_selectedTotal)),
                        ),
                      ),
                    ],
                  ),
                  // Consolidation acts on the coins below. BTC-only — the
                  // backend rejects it for Liquid. Hidden while selecting:
                  // the bar at the foot owns the mode then, and the coins
                  // need the room.
                  if (_chain != 'Liquid' && !_consolidateMode) ...[
                    const SizedBox(height: AppSpacing.md),
                    PrimaryButton(
                      label: 'Consolidate',
                      icon: Icons.compress,
                      isFullWidth: true,
                      onPressed: _utxos.isEmpty ? null : _enterConsolidate,
                    ),
                  ],
                ] else
                // Stats, the coin action, and the view toggle
                Row(
                  children: [
                    _StatBox(
                      label: _countLabel,
                      value: '${_utxos.length}',
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    _StatBox(label: 'Selected', value: '${_selected.length}'),
                    const SizedBox(width: AppSpacing.lg),
                    _StatBox(
                        label: 'Selected total',
                        value: maskAmount(context, _formatSats(_selectedTotal))),
                    const Spacer(),
                    // Consolidation acts on the coins below, so it lives on
                    // their row, not in the page header. BTC-only — the
                    // backend rejects it for Liquid.
                    if (_chain != 'Liquid') ...[
                      // Enters inline consolidate mode — select coins in place.
                      PrimaryButton(
                        label: 'Consolidate',
                        icon: Icons.compress,
                        onPressed: _utxos.isEmpty || _consolidateMode
                            ? null
                            : _enterConsolidate,
                      ),
                      const SizedBox(width: AppSpacing.md),
                    ],
                    SegmentedSwitch<UtxoViewMode>(
                      selected: _viewMode,
                      onChanged: _setViewMode,
                      options: const [
                        SegOption(
                          value: UtxoViewMode.notes,
                          label: 'Notes',
                          icon: Icons.payments_outlined,
                          tooltip: 'Coins sized as banknotes',
                        ),
                        SegOption(
                          value: UtxoViewMode.list,
                          label: 'List',
                          icon: Icons.view_list_outlined,
                          tooltip: 'Sortable table',
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _LoadError(
                        message: _error!,
                        onRetry: () {
                          setState(() { _loading = true; _error = null; });
                          _load();
                        },
                      )
                    : _utxos.isEmpty
                        ? (phone
                            ? const _EmptyCoins()
                            : Center(
                                child: Text('No UTXOs found',
                                    style: AppTypography.caption),
                              ))
                        : switch (_viewMode) {
                            UtxoViewMode.notes => _notesView(),
                            UtxoViewMode.list => _listView(),
                          },
          ),
          if (_consolidateMode)
            _buildConsolidateBar()
          else if (_selected.isNotEmpty)
            _BottomActionBar(
              selectedCount: _selected.length,
              allFrozen: _selectionAllFrozen,
              busy: _freezing,
              onTag: _tagSelected,
              onFreeze: () =>
                  _setFrozen(_selected, frozen: !_selectionAllFrozen),
              onClear: _clearSelection,
            ),
        ],
        ),
      ),
    );
  }

  /// Inline fee picker + confirm bar shown while in consolidate mode.
  /// BTC-only: the backend rejects Liquid consolidation, so this bar is
  /// unreachable on the Liquid chain.
  Widget _buildConsolidateBar() {
    final s = AppScheme.of(context);
    final count = _spendableSelected.length;
    final total = _spendableSelected.fold(0, (sum, u) => sum + u.amount);
    final isCustom = _feePreset == 'custom';
    final canSend = count >= 2 && !_sending && _feeRate > 0;

    Widget feeChip(String id, String label, String sub, String rate) {
      final active = id == _feePreset;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: InkWell(
            onTap: () => setState(() => _feePreset = id),
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: active ? s.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(
                  color: active ? s.accent : s.edge,
                  width: active ? 2 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: AppTypography.label.copyWith(
                        color: active ? s.accent : s.ink,
                        fontWeight: FontWeight.w700,
                      )),
                  Text(rate.isEmpty ? sub : '$sub · $rate sat/vB',
                      style: AppTypography.caption.copyWith(color: s.inkSecondary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (AppLayout.isPhone(context)) {
      return _buildPhoneConsolidateBar(
        s: s,
        count: count,
        total: total,
        isCustom: isCustom,
        canSend: canSend,
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        border: Border(top: BorderSide(color: s.edge)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final p in _feePresets) feeChip(p.$1, p.$2, p.$3, '${p.$4}'),
              // Custom fee preset.
              feeChip('custom', 'Custom', 'sat/vB', ''),
            ],
          ),
          if (isCustom) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: 200,
              child: TextField(
                controller: _customFeeCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Custom fee rate',
                  suffixText: 'sat/vB',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_consolidateError != null) ...[
            Text(_consolidateError!,
                style: AppTypography.caption.copyWith(color: AppColors.danger)),
            const SizedBox(height: AppSpacing.sm),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  count < 2
                      ? 'Select at least 2 UTXOs to consolidate'
                      : '$count UTXOs · ${_formatSats(total)} '
                          '· estimated fee ≈$_estFeeSats sats',
                  style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                ),
              ),
              GhostButton(
                label: 'Cancel',
                onPressed: _sending ? null : _exitConsolidate,
              ),
              const SizedBox(width: AppSpacing.sm),
              PrimaryButton(
                // The button no longer broadcasts: it builds the transaction
                // and opens the review-then-sign flow.
                label: _sending ? 'Preparing…' : 'Review & consolidate',
                icon: Icons.compress,
                onPressed: canSend ? _runConsolidate : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Phone consolidate bar. Stacked: one segmented track of four label-only
  /// preset cells (48 dp), a caption with the active preset's detail, the
  /// summary, then Cancel / Review side by side at full width. The custom
  /// rate is typed in a bottom sheet rather than an inline field: the bar
  /// sits under a non-scrolling header, and a keyboard would push the whole
  /// Column past the screen.
  Widget _buildPhoneConsolidateBar({
    required AppScheme s,
    required int count,
    required int total,
    required bool isCustom,
    required bool canSend,
  }) {
    final pad = AppSpacing.pagePadding(context);

    Widget chip(String id, String label, VoidCallback onTap) {
      final active = id == _feePreset;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              // 42 dp inside the track's 3 dp padding — a 48 dp control.
              constraints: const BoxConstraints(
                  minHeight: AppLayout.minTouchTarget - 6),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                // A pill sliding inside the track, not a ringed chip: the
                // 2 px accent border used to be the loudest thing in the bar.
                color: active ? s.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.label.copyWith(
                  color: active ? s.accent : s.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final detail = isCustom
        ? (_feeRate > 0
            ? 'Custom · $_feeRate sat/vB · tap Custom to change'
            : 'Custom · tap Custom to enter a rate')
        : () {
            final p = _feePresets.firstWhere((p) => p.$1 == _feePreset);
            return '${p.$3} · ${p.$4} sat/vB';
          }();

    return Container(
      padding: EdgeInsets.fromLTRB(pad, AppSpacing.md, pad, AppSpacing.md),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        border: Border(top: BorderSide(color: s.edge)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // One segmented track, the same object as the header's view
          // toggle — four separate outlined chips read as four buttons.
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: s.panelInset,
              borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            ),
            child: Row(
              children: [
                for (var i = 0; i < _feePresets.length; i++)
                  chip(_feePresets[i].$1, _feePresets[i].$2,
                      () => setState(() => _feePreset = _feePresets[i].$1)),
                chip('custom', 'Custom', _editCustomFee),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs + 2),
          Text(
            detail,
            style: AppTypography.caption.copyWith(color: s.inkSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_consolidateError != null) ...[
            Text(_consolidateError!,
                style: AppTypography.caption.copyWith(color: AppColors.danger),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: AppSpacing.sm),
          ],
          Text(
            count < 2
                ? 'Select at least 2 UTXOs to consolidate'
                : '$count UTXOs · ${_formatSats(total)} '
                    '· estimated fee ≈$_estFeeSats sats',
            style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          // No height box around either button: the shared phone button spec
          // (54 dp, radius 16, filled) owns its own height, and a hard 48 dp
          // would clamp it below spec and squash the glow.
          Row(
            children: [
              Expanded(
                child: SecondaryButton(
                  label: 'Cancel',
                  isFullWidth: true,
                  onPressed: _sending ? null : _exitConsolidate,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                flex: 2,
                child: PrimaryButton(
                  label: _sending ? 'Preparing…' : 'Review',
                  icon: Icons.compress,
                  isFullWidth: true,
                  onPressed: canSend ? _runConsolidate : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Phone: custom fee rate entered in a keyboard-aware sheet. Selecting
  /// "Custom" and editing its value are one gesture. The sheet edits the
  /// screen's own controller (the phone bar hosts no inline field, so
  /// nothing else is bound to it) and puts the old text back on cancel —
  /// no throwaway controller to dispose under a sheet that is still
  /// animating out.
  Future<void> _editCustomFee() async {
    final previous = _customFeeCtrl.text;
    final value = await showAppDialog<String>(
      context,
      builder: (ctx) => AppDialog(
        title: const Text('Custom fee rate'),
        // A floating label inside a filled field fights the phone field
        // style; the label sits above it as the same micro-label the lists
        // and the stat tiles use, and the field itself is left entirely to
        // the shared decoration (filled inset grey, radius 14, focus ring).
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'FEE RATE',
              style: AppTypography.navSection.copyWith(
                color: AppScheme.of(ctx).inkFaint,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: AppSpacing.xs + 2),
            TextField(
              controller: _customFeeCtrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: '3.0',
                suffixText: 'sat/vB',
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          SecondaryButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(ctx).pop(null),
          ),
          PrimaryButton(
            label: 'Use rate',
            onPressed: () => Navigator.of(ctx).pop(_customFeeCtrl.text),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (value == null) {
      _customFeeCtrl.text = previous;
      return;
    }
    setState(() {
      _customFeeCtrl.text = value.trim();
      _feePreset = 'custom';
    });
  }
}

// ── Phone-only header pieces ───────────────────────────────────────────────────

/// Icon-only Notes/List toggle for the phone header: two 42 dp cells in the
/// segmented-switch track (48 dp tall with the track). Labels live in the
/// semantics and tooltips; the labelled SegmentedSwitch is 186 dp, which the
/// header row cannot spare next to the chain switch.
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.mode, required this.onChanged});
  final UtxoViewMode mode;
  final ValueChanged<UtxoViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    Widget cell(UtxoViewMode m, IconData icon, String label) {
      final selected = m == mode;
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: label,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onChanged(m),
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              child: Container(
                width: AppLayout.minTouchTarget - 6,
                height: AppLayout.minTouchTarget - 6,
                decoration: BoxDecoration(
                  // The selected cell is a filled pill inside the track — no
                  // ring: the fill and the accent glyph already say which one
                  // is on, and a border would fight every other phone control.
                  color: selected ? s.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Icon(icon,
                    size: 20, color: selected ? s.accent : s.inkSecondary),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        // A filled inset track with a nested pill — the same object the
        // shared SegmentedSwitch draws on a phone.
        color: s.panelInset,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          cell(UtxoViewMode.notes, Icons.payments_outlined, 'Notes view'),
          cell(UtxoViewMode.list, Icons.view_list_outlined, 'List view'),
        ],
      ),
    );
  }
}

/// Compact phone stat: micro-label over a fitted numeric value, on the
/// inset-grey surface every filled phone control shares. Three of them share
/// the 379 dp column, and the md/md padding puts them at ~56 dp — the height
/// of a phone field, so they sit level with the controls around them.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        // Filled inset grey, no hairline — a phone reads the tile from its
        // fill, and a border here would re-create the shrunken desktop box.
        color: s.panelInset,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            // Same uppercase micro-label ListSectionLabel paints, so a group
            // label means the same thing here as on the Dashboard.
            label.toUpperCase(),
            style: AppTypography.navSection.copyWith(
              color: s.inkFaint,
              letterSpacing: 1.1,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppTypography.numeric
                  .copyWith(color: s.ink, fontWeight: FontWeight.w700),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Phone empty state: a lone caption in a tall empty canvas reads as a
/// screen still loading; this says what is going on and what to do.
class _EmptyCoins extends StatelessWidget {
  const _EmptyCoins();

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.savings_outlined, size: 40, color: s.inkFaint),
            const SizedBox(height: AppSpacing.md),
            Text('No coins yet', style: AppTypography.sectionTitleOf(context)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Receive coins on this chain to see them here.',
              style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Load failure ──────────────────────────────────────────────────────────────
// An empty UTXO set is NOT an error and keeps its own message; this card only
// appears when the bridge call itself failed.

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Center(
      child: Padding(
        // Keeps the card off the screen edges on a phone; the centred 480 dp
        // card on desktop never reaches the padding.
        padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.pagePadding(context)),
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: s.danger),
              const SizedBox(height: AppSpacing.md),
              Text('Could not load UTXOs', style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              // Full-bleed on a phone, like every other phone CTA; the
              // desktop card keeps its intrinsically-sized button.
              PrimaryButton(
                label: 'Retry',
                isFullWidth: AppLayout.isPhone(context),
                onPressed: onRetry,
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTypography.caption.copyWith(color: s.inkSecondary)),
        Text(value,
            style: AppTypography.numericLarge
                .copyWith(fontSize: 18, color: s.ink)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.selectedCount,
    required this.allFrozen,
    required this.busy,
    required this.onTag,
    required this.onFreeze,
    required this.onClear,
  });

  final int selectedCount;

  /// Every selected coin is frozen: the freeze button unfreezes.
  final bool allFrozen;

  /// A freeze is in flight.
  final bool busy;
  final VoidCallback onTag;
  final VoidCallback onFreeze;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final tag = SecondaryButton(
      label: 'Tag',
      icon: Icons.label_outline,
      isFullWidth: phone,
      onPressed: onTag,
    );
    final freeze = SecondaryButton(
      label: allFrozen ? 'Unfreeze' : 'Freeze',
      icon: kFrozenIcon,
      isFullWidth: phone,
      isLoading: busy,
      onPressed: busy ? null : onFreeze,
    );
    // No local height box: the shared buttons carry the phone's own 54 dp
    // spec, and a 48 dp wrapper here would pin these two 6 dp shorter than
    // every other button on the phone.
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.pagePadding(context),
          vertical: phone ? AppSpacing.md : AppSpacing.lg),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        border: Border(top: BorderSide(color: s.edge)),
      ),
      // Phone: the count already sits in the stat tiles above, so the two
      // actions take the width between them.
      child: phone
          ? Row(
              children: [
                Expanded(child: tag),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: freeze),
                const SizedBox(width: AppSpacing.xs),
                GhostButton(label: 'Clear', onPressed: onClear),
              ],
            )
          : Row(
              children: [
                Text('$selectedCount selected',
                    style: AppTypography.numericSmall
                        .copyWith(fontWeight: FontWeight.w600, color: s.ink)),
                const SizedBox(width: AppSpacing.xl),
                tag,
                const SizedBox(width: AppSpacing.sm),
                freeze,
                const Spacer(),
                GhostButton(label: 'Clear', onPressed: onClear),
              ],
            ),
    );
  }
}
