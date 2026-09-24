import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hex_text.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/scan_button.dart';
import '../../shared/widgets/segmented_switch.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/peg_models.dart';

/// Peg screen — move between Bitcoin and Liquid Bitcoin through a peg
/// provider. The current provider is a built-in simulation (clearly labeled):
/// the full flow works end to end but no real funds move.
class PegScreen extends StatefulWidget {
  const PegScreen({super.key});

  @override
  State<PegScreen> createState() => _PegScreenState();
}

class _PegScreenState extends State<PegScreen> {
  final _bridge = walletBridge;

  // ── New-peg form ──
  String _direction = 'in'; // 'in' = BTC → L-BTC, 'out' = L-BTC → BTC
  final _amountCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  PegQuote? _quote;
  String? _quoteError;
  bool _quoting = false;
  int _quoteSeq = 0; // guards against out-of-order quote responses
  Timer? _quoteDebounce;
  bool _starting = false;
  String? _startError;

  // ── Orders ──
  List<PegOrder> _orders = [];
  bool _ordersLoading = true;
  String? _ordersError;
  final Set<String> _expanded = {};
  final Set<String> _cancelling = {};
  Timer? _pollTimer;
  bool _polling = false;

  AppState? _appState;
  String? _lastWalletId;

  static const _statusFlow = [
    ('awaiting_deposit', 'Awaiting deposit'),
    ('deposit_seen', 'Deposit seen'),
    ('confirming', 'Confirming'),
    ('settling', 'Settling'),
    ('completed', 'Completed'),
  ];

  String get _walletId =>
      context.read<AppState>().activeWalletId ?? 'wallet-1';

  bool get _isPegIn => _direction == 'in';
  String get _fromTicker => _isPegIn ? 'BTC' : 'L-BTC';
  String get _toTicker => _isPegIn ? 'L-BTC' : 'BTC';

  @override
  void initState() {
    super.initState();
    _loadOrders();
    _prefillAddress();
    _pollTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _pollActive());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _appState = context.read<AppState>();
      _lastWalletId = _appState!.activeWalletId;
      _appState!.addListener(_onAppStateChanged);
    });
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _pollTimer?.cancel();
    _quoteDebounce?.cancel();
    _amountCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  void _onAppStateChanged() {
    final newWalletId = _appState?.activeWalletId;
    if (newWalletId == _lastWalletId || !mounted) return;
    _lastWalletId = newWalletId;
    setState(() {
      _orders = [];
      _ordersLoading = true;
      _expanded.clear();
      _quote = null;
      _quoteError = null;
      _startError = null;
      _amountCtrl.clear();
      _addressCtrl.clear();
    });
    _loadOrders();
    _prefillAddress();
  }

  String _msg(Object e) =>
      e.toString().replaceFirst('Exception: wallet-ffi: ', '');

  String _fmtBtc(int sats) => (sats / 1e8).toStringAsFixed(8);

  String _fmtTime(int unixSecs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  // ── Quote ─────────────────────────────────────────────────────────────────

  int? get _amountSats {
    final v = double.tryParse(_amountCtrl.text.trim());
    // isFinite: tryParse accepts "NaN"/"Infinity", and .round() throws on them.
    if (v == null || !v.isFinite || v <= 0) return null;
    return (v * 1e8).round();
  }

  void _onAmountChanged() {
    _quoteDebounce?.cancel();
    setState(() {}); // refresh button/quote-panel enablement immediately
    _quoteDebounce =
        Timer(const Duration(milliseconds: 400), _fetchQuote);
  }

  Future<void> _fetchQuote() async {
    final sats = _amountSats;
    final seq = ++_quoteSeq;
    if (sats == null) {
      setState(() {
        _quote = null;
        _quoteError = null;
        _quoting = false;
      });
      return;
    }
    setState(() {
      _quoting = true;
      _quoteError = null;
    });
    try {
      final q = await _bridge.pegQuote(_direction, sats);
      if (!mounted || seq != _quoteSeq) return;
      setState(() {
        _quote = q;
        _quoting = false;
      });
    } catch (e) {
      if (!mounted || seq != _quoteSeq) return;
      setState(() {
        _quote = null;
        _quoting = false;
        _quoteError = _msg(e);
      });
    }
  }

  void _setDirection(String dir) {
    if (dir == _direction) return;
    setState(() {
      _direction = dir;
      _quote = null;
      _quoteError = null;
      _startError = null;
      _addressCtrl.clear(); // payout chain changed — old address is invalid
    });
    _quoteDebounce?.cancel();
    _fetchQuote();
    _prefillAddress();
  }

  // ── Payout address ────────────────────────────────────────────────────────

  Future<void> _prefillAddress() async {
    final dir = _direction;
    final wallet = _walletId;
    try {
      // Peg-in pays out on Liquid, peg-out on Bitcoin.
      final info = await _bridge.generateReceiveAddress(
        wallet,
        dir == 'in' ? 'LBTC' : 'BTC',
      );
      // Discard stale results: the user may have flipped direction or
      // switched wallet while the request was in flight.
      if (!mounted || dir != _direction || wallet != _walletId) return;
      setState(() => _addressCtrl.text = info.address);
    } catch (_) {
      // Leave the field for manual entry — the wallet side may be missing.
      if (mounted) setState(() {});
    }
  }

  // ── Orders ────────────────────────────────────────────────────────────────

  /// [silent] keeps the rows on screen while the reload runs — the phone's
  /// pull-to-refresh already draws its own spinner, and swapping the list for
  /// a second one under it flashes the card empty on every pull.
  Future<void> _loadOrders({bool silent = false}) async {
    setState(() {
      if (!silent) _ordersLoading = true;
      _ordersError = null;
    });
    try {
      final orders = await _bridge.pegList(_walletId);
      if (!mounted) return;
      setState(() {
        _orders = orders;
        _ordersLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ordersLoading = false;
        _ordersError = _msg(e);
      });
    }
  }

  Future<void> _pollActive() async {
    if (_polling || !mounted) return;
    final active = _orders.where((o) => !o.isTerminal).toList();
    if (active.isEmpty) return;
    _polling = true;
    try {
      final updates = await Future.wait(
        active.map((o) => _bridge.pegStatus(o.orderId)),
      );
      if (!mounted) return;
      setState(() {
        for (final u in updates) {
          final i = _orders.indexWhere((o) => o.orderId == u.orderId);
          if (i >= 0) _orders[i] = u;
        }
      });
    } catch (_) {
      // Transient polling failure — the next tick retries.
    } finally {
      _polling = false;
    }
  }

  Future<void> _start() async {
    final sats = _amountSats;
    final address = _addressCtrl.text.trim();
    if (sats == null || address.isEmpty || _starting) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final order =
          await _bridge.pegStart(_walletId, _direction, sats, address);
      if (!mounted) return;
      setState(() {
        _starting = false;
        _orders.insert(0, order);
        _expanded
          ..clear()
          ..add(order.orderId);
        _amountCtrl.clear();
        _quote = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = _msg(e);
      });
    }
  }

  Future<void> _cancel(PegOrder order) async {
    if (_cancelling.contains(order.orderId)) return;
    setState(() => _cancelling.add(order.orderId));
    try {
      final updated = await _bridge.pegCancel(order.orderId);
      if (!mounted) return;
      setState(() {
        _cancelling.remove(order.orderId);
        final i = _orders.indexWhere((o) => o.orderId == updated.orderId);
        if (i >= 0) _orders[i] = updated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelling.remove(order.orderId));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_msg(e))));
    }
  }

  Future<void> _openExplorer(String txid, {required bool liquid}) async {
    final app = context.read<AppState>();
    final base = liquid ? app.liquidExplorerUrl : app.btcExplorerUrl;
    final trimmed =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final uri = Uri.parse('$trimmed/tx/$txid');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final list = ListView(
      padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
      // The pull has to work even when the page is shorter than the screen.
      physics: phone ? const AlwaysScrollableScrollPhysics() : null,
      children: [
        const PageHeader(
          title: 'Peg',
          subtitle: 'Move between Bitcoin and Liquid Bitcoin',
        ),
        const WarningBanner(
          message: 'Simulated provider — no real funds move. '
              'A real peg provider arrives in a later update.',
        ),
        const SizedBox(height: AppSpacing.xl),
        Reveal(child: _pegForm(s)),
        const SizedBox(height: AppSpacing.xl),
        Reveal(delay: 1, child: _ordersPanel(s)),
      ],
    );
    return Scaffold(
      body: PageBackground.flat(
        // Pull-to-refresh replaces the 16 dp refresh button in the orders
        // panel header, which the phone list grammar has no header for. A
        // desktop pointer cannot pull, so it keeps the button and the bare
        // ListView.
        child: phone
            ? RefreshIndicator(
                onRefresh: () => _loadOrders(silent: true),
                child: list,
              )
            : list,
      ),
    );
  }

  // ── New-peg form ──────────────────────────────────────────────────────────

  Widget _pegForm(AppScheme s) {
    // The quote must match the current amount — editing the field after a
    // quote arrived disables Start until the debounced re-quote lands.
    final sats = _amountSats;
    final canStart = !_starting &&
        sats != null &&
        _quote != null &&
        _quote!.amountSats == sats &&
        _addressCtrl.text.trim().isNotEmpty;
    return HeroPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _directionToggle(s),
          const SizedBox(height: AppSpacing.xl),
          _fieldLabel(s, 'You send'),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _amountCtrl,
            enabled: !_starting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: AppTypography.numeric,
            decoration: InputDecoration(
              hintText: '0.00000000',
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: AppSpacing.md),
                child: Text(
                  _fromTicker,
                  style: AppTypography.label.copyWith(
                    color: s.inkFaint,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              suffixIconConstraints:
                  const BoxConstraints(minWidth: 0, minHeight: 0),
            ),
            onChanged: (_) => _onAmountChanged(),
          ),
          if (_quote != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Provider limits: ${_fmtBtc(_quote!.minSats)} – '
                '${_fmtBtc(_quote!.maxSats)} $_fromTicker',
                style: AppTypography.caption.copyWith(color: s.inkFaint),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          _quotePanel(s),
          const SizedBox(height: AppSpacing.lg),
          _fieldLabel(s, 'Payout address'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _isPegIn
                ? 'Where the L-BTC is delivered — pre-filled with this '
                    'wallet\'s Liquid address.'
                : 'Where the BTC is delivered — pre-filled with this '
                    'wallet\'s Bitcoin address.',
            style: AppTypography.caption.copyWith(color: s.inkFaint),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _addressCtrl,
            enabled: !_starting,
            style: AppTypography.mono,
            // A full address needs two lines beside the suffix icons.
            maxLines: AppLayout.isPhone(context) ? 2 : 1,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: 'Enter, paste, or scan a $_toTicker address',
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Use this wallet\'s address',
                    icon: const Icon(Icons.account_balance_wallet_outlined,
                        size: 18),
                    onPressed: _starting ? null : _prefillAddress,
                  ),
                  ScanIconButton(
                    controller: _addressCtrl,
                    title: 'Scan payout address',
                    onScanned: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (_startError != null) ...[
            const SizedBox(height: AppSpacing.lg),
            DangerBanner(message: _startError!),
          ],
          const SizedBox(height: AppSpacing.xl),
          PrimaryButton(
            label: _isPegIn ? 'Start peg-in' : 'Start peg-out',
            icon: Icons.swap_vert,
            isFullWidth: true,
            isLoading: _starting,
            onPressed: canStart ? _start : null,
          ),
        ],
      ),
    );
  }

  /// A field's name. On a phone it is the same uppercase micro-label that
  /// ListSectionLabel and CodeBox draw, so a field name and a section name
  /// read as one object; desktop keeps the mixed-case sentence label.
  Widget _fieldLabel(AppScheme s, String text) {
    if (AppLayout.isPhone(context)) {
      return Text(
        text.toUpperCase(),
        style: AppTypography.navSection
            .copyWith(color: s.inkFaint, letterSpacing: 1.3),
      );
    }
    return Text(text,
        style: AppTypography.label.copyWith(color: s.inkSecondary));
  }

  Widget _directionToggle(AppScheme s) {
    if (AppLayout.isPhone(context)) {
      // The shared track: 54 dp segments, a ripple, ellipsising labels and the
      // same selected treatment every segmented control in the app uses — the
      // bespoke version below lands at ~46 dp and duplicates it line for line.
      // The 'BTC → L-BTC' sub-line is dropped here because the amount field's
      // suffix and the quote panel already print both tickers.
      return SegmentedSwitch<String>(
        options: [
          SegOption(
            value: 'in',
            label: 'Peg-in',
            color: s.liquid, // peg-in delivers L-BTC
            enabled: !_starting,
            tooltip: 'Starting a peg — wait for it to finish.',
          ),
          SegOption(
            value: 'out',
            label: 'Peg-out',
            color: s.bitcoin, // peg-out delivers BTC
            enabled: !_starting,
            tooltip: 'Starting a peg — wait for it to finish.',
          ),
        ],
        selected: _direction,
        onChanged: _setDirection,
        expand: true,
      );
    }
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm + 3),
        border: Border.all(color: s.edge),
      ),
      child: Row(
        children: [
          _segment(s, 'in', 'Peg-in', 'BTC → L-BTC'),
          const SizedBox(width: 3),
          _segment(s, 'out', 'Peg-out', 'L-BTC → BTC'),
        ],
      ),
    );
  }

  Widget _segment(AppScheme s, String dir, String label, String sub) {
    final selected = _direction == dir;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        onTap: _starting || selected ? null : () => _setDirection(dir),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
          decoration: BoxDecoration(
            color: selected ? s.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.55)
                  : Colors.transparent,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: AppTypography.label.copyWith(
                  color: selected ? AppColors.accent : s.inkSecondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: AppTypography.caption.copyWith(
                  fontSize: 11,
                  color: selected ? s.ink : s.inkFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quotePanel(AppScheme s) {
    final Widget body;
    if (_quoting) {
      body = Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppSpacing.md),
          Text('Fetching quote…',
              style: AppTypography.caption.copyWith(color: s.inkSecondary)),
        ],
      );
    } else if (_quoteError != null) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: s.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _quoteError!,
              style: AppTypography.caption.copyWith(color: s.danger),
            ),
          ),
        ],
      );
    } else if (_quote == null) {
      body = Text(
        'Enter an amount to get a live quote.',
        style: AppTypography.caption.copyWith(color: s.inkFaint),
      );
    } else {
      final q = _quote!;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KvRow(
            label: 'Rate',
            value: q.rate == 1.0 ? '1:1' : q.rate.toStringAsFixed(8),
          ),
          KvRow(label: 'Service fee', value: '${q.serviceFeeSats} sats'),
          KvRow(label: 'Network fee', value: '${q.networkFeeSats} sats'),
          KvRow(label: 'ETA', value: '~${q.etaMinutes} min'),
          Divider(height: AppSpacing.lg, color: s.edge),
          Row(
            children: [
              Expanded(
                child: Text(
                  'You receive',
                  style: AppTypography.label.copyWith(color: s.inkSecondary),
                ),
              ),
              Text(
                '${_fmtBtc(q.receiveSats)} $_toTicker',
                style: AppTypography.numericLarge
                    .copyWith(fontSize: 18, color: AppColors.accent),
              ),
            ],
          ),
        ],
      );
    }
    return DataWell(child: body);
  }

  // ── Orders panel ──────────────────────────────────────────────────────────

  Widget _ordersPanel(AppScheme s) {
    final hasOrders =
        !_ordersLoading && _ordersError == null && _orders.isNotEmpty;
    if (AppLayout.isPhone(context)) {
      // The phone's list grammar (list_rows.dart): an uppercase label over one
      // card whose hairlines start past the glyph column — the same object the
      // Dashboard and Settings draw. The RailPanel below is a desktop
      // instrument: rail, header strip, zebra rows, and a 16 dp refresh button
      // as its only control (replaced here by pull-to-refresh in build()).
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListSectionLabel(label: 'Your peg orders'),
          ListCard(
            children: hasOrders
                ? [for (final o in _orders) _orderTile(s, o)]
                : [_ordersPlaceholder(s)],
          ),
        ],
      );
    }
    final Widget body = hasOrders
        ? Column(
            children: [
              for (var i = 0; i < _orders.length; i++)
                _orderRow(s, _orders[i], i.isOdd),
            ],
          )
        : _ordersPlaceholder(s);
    return RailPanel(
      title: 'Your peg orders',
      padding: EdgeInsets.zero,
      trailing: IconButton(
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh, size: 16),
        visualDensity: VisualDensity.compact,
        onPressed: _ordersLoading ? null : _loadOrders,
      ),
      child: body,
    );
  }

  /// Loading, failed or empty — the same three bodies on both platforms; only
  /// the frame around them differs.
  Widget _ordersPlaceholder(AppScheme s) {
    if (_ordersLoading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_ordersError != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          children: [
            Text('Could not load peg orders', style: AppTypography.body),
            const SizedBox(height: AppSpacing.xs),
            Text(
              _ordersError!,
              textAlign: TextAlign.center,
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            GhostButton(
                label: 'Retry', icon: Icons.refresh, onPressed: _loadOrders),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: Text(
          'No peg orders yet — start one above.',
          style: AppTypography.caption.copyWith(color: s.inkFaint),
        ),
      ),
    );
  }

  /// One order as a phone list row: the glyph tile carries the direction (the
  /// two colours the desktop TagChip uses), then the two legs on their own
  /// line — 8 decimals twice does not fit beside a status badge at 360 dp —
  /// then state and time. The order id moves into the expanded detail, where
  /// it is the only place it is needed.
  Widget _orderTile(AppScheme s, PegOrder o) {
    final expanded = _expanded.contains(o.orderId);
    final fromTicker = o.isPegIn ? 'BTC' : 'L-BTC';
    final toTicker = o.isPegIn ? 'L-BTC' : 'BTC';
    return Column(
      children: [
        Semantics(
          button: true,
          // Same contract as ListRow: the row's name, then what it is doing.
          label: '${o.isPegIn ? 'Peg-in' : 'Peg-out'}, '
              '${_fmtBtc(o.depositExpectedSats)} $fromTicker to '
              '${_fmtBtc(o.payoutExpectedSats)} $toTicker',
          hint: '${_statusParts(o).$1}, ${_fmtTime(o.createdAt)}',
          excludeSemantics: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: () => setState(() {
                expanded
                    ? _expanded.remove(o.orderId)
                    : _expanded.add(o.orderId);
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kListPad,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListIconTile(
                      icon: Icons.swap_vert,
                      tint: o.isPegIn ? s.liquid : s.bitcoin,
                    ),
                    const SizedBox(width: kListGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_fmtBtc(o.depositExpectedSats)} $fromTicker → '
                            '${_fmtBtc(o.payoutExpectedSats)} $toTicker',
                            style: AppTypography.numericSmall.copyWith(
                                color: s.ink, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: AppSpacing.sm - 2),
                          Row(
                            children: [
                              Flexible(child: _statusBadge(o)),
                              const SizedBox(width: AppSpacing.sm),
                              Flexible(
                                child: Text(
                                  _fmtTime(o.createdAt),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.caption.copyWith(
                                      fontSize: 12, color: s.inkFaint),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 22,
                      color: s.inkFaint,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (expanded) _orderDetail(s, o),
      ],
    );
  }

  /// The desktop table row. A phone never reaches this — [_ordersPanel] hands
  /// the phone [_orderTile] instead — so the two-line phone branch that used
  /// to live inside it is gone rather than unreachable.
  Widget _orderRow(AppScheme s, PegOrder o, bool zebra) {
    final expanded = _expanded.contains(o.orderId);
    final fromTicker = o.isPegIn ? 'BTC' : 'L-BTC';
    final toTicker = o.isPegIn ? 'L-BTC' : 'BTC';
    return Column(
      children: [
        HoverRow(
          zebra: zebra,
          onTap: () => setState(() {
            expanded ? _expanded.remove(o.orderId) : _expanded.add(o.orderId);
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: s.edge)),
            ),
            child: Row(
              children: [
                TagChip(
                  label: o.isPegIn ? 'Peg-in' : 'Peg-out',
                  color: o.isPegIn ? s.liquid : s.bitcoin,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_fmtBtc(o.depositExpectedSats)} $fromTicker → '
                        '${_fmtBtc(o.payoutExpectedSats)} $toTicker',
                        style: AppTypography.numericSmall.copyWith(
                            color: s.ink, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${o.orderId} · ${_fmtTime(o.createdAt)}',
                        style:
                            AppTypography.caption.copyWith(color: s.inkFaint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _statusBadge(o),
                const SizedBox(width: AppSpacing.sm),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: s.inkFaint,
                ),
              ],
            ),
          ),
        ),
        if (expanded) _orderDetail(s, o),
      ],
    );
  }

  StatusBadge _statusBadge(PegOrder o) {
    final (label, variant) = _statusParts(o);
    return StatusBadge(label: label, variant: variant, dot: !o.isTerminal);
  }

  /// The badge's words on their own, so the phone row can also say them to a
  /// screen reader (its badge is inside an excluded subtree).
  (String, BadgeVariant) _statusParts(PegOrder o) {
    return switch (o.status) {
      'awaiting_deposit' => ('Awaiting deposit', BadgeVariant.warning),
      'deposit_seen' => ('Deposit seen', BadgeVariant.accent),
      'confirming' => ('Confirming', BadgeVariant.accent),
      'settling' => ('Settling', BadgeVariant.accent),
      'completed' => ('Completed', BadgeVariant.success),
      'cancelled' => ('Cancelled', BadgeVariant.neutral),
      _ => (o.status, BadgeVariant.neutral),
    };
  }

  Widget _orderDetail(AppScheme s, PegOrder o) {
    final depositTicker = o.isPegIn ? 'BTC' : 'L-BTC';
    final payoutTicker = o.isPegIn ? 'L-BTC' : 'BTC';
    // Peg-in deposits on Bitcoin and pays out on Liquid; peg-out the reverse.
    final depositIsLiquid = !o.isPegIn;
    final payoutIsLiquid = o.isPegIn;
    final cancelling = _cancelling.contains(o.orderId);
    final phone = AppLayout.isPhone(context);
    return Container(
      // On a phone the detail is an inset well inside the list card: kListPad
      // lines its left edge up with the row's glyph tile, and the card already
      // clips and draws the hairline between orders, so a second bottom border
      // would double up.
      padding: EdgeInsets.all(phone ? kListPad : AppSpacing.lg),
      decoration: BoxDecoration(
        color: phone ? s.panelInset : s.zebra,
        border: phone ? null : Border(bottom: BorderSide(color: s.edge)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepper(s, o),
          const SizedBox(height: AppSpacing.lg),
          if (o.awaitingDeposit) ...[
            InfoBanner(
              message: 'Send ${_fmtBtc(o.depositExpectedSats)} $depositTicker '
                  'to the deposit address below to continue. This provider is '
                  'simulated — the deposit is auto-detected, no real funds '
                  'move.',
            ),
            const SizedBox(height: AppSpacing.lg),
            Flex(
              // QR beside the address on desktop; QR above it on a phone,
              // where the side-by-side pair leaves the address ~150 dp.
              direction: AppLayout.isPhone(context)
                  ? Axis.vertical
                  : Axis.horizontal,
              crossAxisAlignment: AppLayout.isPhone(context)
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: QrImageView(
                    data: o.depositAddress,
                    version: QrVersions.auto,
                    size: AppLayout.isPhone(context)
                        ? AppLayout.qrSide(context, max: 200)
                        : 110,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg, height: AppSpacing.md),
                Flexible(
                  fit: AppLayout.isPhone(context)
                      ? FlexFit.loose
                      : FlexFit.tight,
                  child: SizedBox(
                    width: double.infinity,
                    child: CodeBox(
                      value: o.depositAddress,
                      label: 'Deposit address (simulated)',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          // The phone row prints state and time, not the id — it lands here,
          // the one place the id is worth reading.
          if (phone) KvRow(label: 'Order', value: o.orderId),
          KvRow(
            label: 'Payout',
            value:
                '${_fmtBtc(o.payoutExpectedSats)} $payoutTicker → ${o.payoutAddress}',
          ),
          if (o.txidDeposit != null)
            _txRow(s, 'Deposit tx', o.txidDeposit!, liquid: depositIsLiquid),
          if (o.txidPayout != null)
            _txRow(s, 'Payout tx', o.txidPayout!, liquid: payoutIsLiquid),
          if (o.awaitingDeposit) ...[
            const SizedBox(height: AppSpacing.sm),
            // The one action in an expanded order: full width on a phone,
            // where a right-hugging tertiary control is a thumb-hostile
            // target sized to whatever its label happens to be.
            if (phone)
              GhostButton(
                label: cancelling ? 'Cancelling…' : 'Cancel order',
                icon: Icons.close,
                isFullWidth: true,
                onPressed: cancelling ? null : () => _cancel(o),
              )
            else
              Align(
                alignment: Alignment.centerRight,
                child: GhostButton(
                  label: cancelling ? 'Cancelling…' : 'Cancel order',
                  icon: Icons.close,
                  onPressed: cancelling ? null : () => _cancel(o),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _txRow(AppScheme s, String label, String txid,
      {required bool liquid}) {
    final explorer = IconButton(
      tooltip: 'View in explorer',
      icon: const Icon(Icons.open_in_new, size: 14),
      visualDensity: AppLayout.isPhone(context)
          ? VisualDensity.standard
          : VisualDensity.compact,
      color: s.inkSecondary,
      onPressed: () => _openExplorer(txid, liquid: liquid),
    );
    if (AppLayout.isPhone(context)) {
      // Stacked, the way KvRow stacks a long value: an 86 dp label column
      // plus a 48 dp icon leaves the txid ~180 dp on a 360 dp screen.
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: AppTypography.navSection
                  .copyWith(color: s.inkFaint, fontSize: 10),
            ),
            Row(
              children: [
                Expanded(child: HexText(txid, truncate: true)),
                explorer,
              ],
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label.toUpperCase(),
              style: AppTypography.navSection
                  .copyWith(color: s.inkFaint, fontSize: 10),
            ),
          ),
          Expanded(child: HexText(txid, truncate: true)),
          explorer,
        ],
      ),
    );
  }

  // ── Status stepper ────────────────────────────────────────────────────────

  Widget _stepper(AppScheme s, PegOrder o) {
    if (o.status == 'cancelled') {
      final at = o.statusHistory
          .where((e) => e.status == 'cancelled')
          .map((e) => e.at)
          .firstOrNull;
      return Row(
        children: [
          Icon(Icons.cancel_outlined, size: 16, color: s.danger),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Order cancelled',
            style: AppTypography.bodySmall
                .copyWith(color: s.danger, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (at != null)
            Text(_fmtTime(at),
                style: AppTypography.caption.copyWith(color: s.inkFaint)),
        ],
      );
    }

    final idx = _statusFlow.indexWhere((step) => step.$1 == o.status);
    final current = idx < 0 ? 0 : idx;
    final completed = o.status == 'completed';
    bool done(int i) => i < current || completed;
    bool active(int i) => i == current && !completed;

    if (AppLayout.isPhone(context)) {
      // Five captions across a 300 dp detail wrap to two lines of 10 px text
      // and read as noise. A phone gets the progress as bars plus the name of
      // the step it is on — and the timestamp that is otherwise locked inside
      // a Tooltip no finger can open.
      final at = o.statusHistory
          .where((e) => e.status == _statusFlow[current].$1)
          .map((e) => e.at)
          .firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < _statusFlow.length; i++) ...[
                if (i > 0) const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      // The same three states the dots carry on desktop.
                      color: done(i)
                          ? s.success
                          : (active(i) ? AppColors.accent : s.edgeStrong),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  _statusFlow[current].$2,
                  style: AppTypography.bodySmall
                      .copyWith(color: s.ink, fontWeight: FontWeight.w600),
                ),
              ),
              if (at != null)
                Text(_fmtTime(at),
                    style: AppTypography.caption.copyWith(color: s.inkFaint)),
            ],
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _statusFlow.length; i++)
          Expanded(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 2,
                        color: i == 0
                            ? Colors.transparent
                            : (done(i) || active(i)
                                ? s.success
                                : s.edgeStrong),
                      ),
                    ),
                    _stepDot(s, o, i, done: done(i), active: active(i)),
                    Expanded(
                      child: Container(
                        height: 2,
                        color: i == _statusFlow.length - 1
                            ? Colors.transparent
                            : (done(i + 1) || active(i + 1)
                                ? s.success
                                : s.edgeStrong),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _statusFlow[i].$2,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: AppTypography.caption.copyWith(
                    fontSize: 10,
                    color: done(i) || active(i) ? s.ink : s.inkFaint,
                    fontWeight:
                        active(i) ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _stepDot(AppScheme s, PegOrder o, int i,
      {required bool done, required bool active}) {
    final key = _statusFlow[i].$1;
    final at = o.statusHistory
        .where((e) => e.status == key)
        .map((e) => e.at)
        .firstOrNull;
    final dot = Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? s.success
            : (active ? s.accentSoft : Colors.transparent),
        border: Border.all(
          color: done
              ? s.success
              : (active ? AppColors.accent : s.edgeStrong),
          width: active ? 2 : 1,
        ),
      ),
      child: done
          ? const Icon(Icons.check, size: 12, color: Colors.white)
          : (active
              ? Center(
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.accent,
                    ),
                  ),
                )
              : null),
    );
    if (at == null) return dot;
    return Tooltip(message: _fmtTime(at), child: dot);
  }
}
