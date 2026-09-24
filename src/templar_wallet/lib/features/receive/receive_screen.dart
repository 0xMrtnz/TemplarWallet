import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../services/price_service.dart';
import '../../shared/amount_units.dart';
import '../../shared/payment_uri.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/chain_switch.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/unit_chip.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../hardware/hw_error.dart';
import 'models/address_info.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, this.bridge});

  /// Test seam: the engine to ask for addresses. The app leaves it null and
  /// gets the process-wide [walletBridge]; a widget test hands in a stand-in
  /// so the screen can be driven without a wallet on disk.
  final WalletBridge? bridge;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

/// Longest note a payment request carries. A BIP21 label is read off a QR by
/// a payer's camera: every character grows the code, and past a few dozen a
/// phone-sized code is a wall of modules that will not scan. Forty is a
/// sentence — "Invoice 12 · March rent" — and keeps the QR at the size the
/// card was laid out for.
const int kRequestNoteMaxLength = 40;

/// Longest amount a request field takes: `0.00000001` is ten characters,
/// a fiat figure with a thousands group rarely passes twelve.
const int _requestAmountMaxLength = 16;

/// How many previous addresses Receive shows before "Show all": the list is
/// every address the wallet ever handed out, and this page exists to hand
/// over one. The rest, with what each received, live on the All addresses
/// page ([AppRoutes.receiveAddresses]).
const int _previousPreview = 8;

class _ReceiveScreenState extends State<ReceiveScreen> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;

  /// Last good answer per wallet and chain, mobile only. The carousel
  /// rebuilds this screen on every arrival, and a spinner on each swipe reads
  /// as "not working"; the cached address is shown at once while the refresh
  /// runs behind it. Plain visits ask for the last unused address, so the
  /// cache and the refresh agree unless funds arrived in between.
  static final Map<String, ({AddressInfo current, List<AddressInfo> previous})>
      _cache = {};

  String _selectedAsset = 'BTC';
  AddressInfo? _current;
  List<AddressInfo> _previous = [];
  bool _loading = true;
  bool _copied = false;
  String? _error;

  /// The optional payment request drawn into the QR: an amount, a note, or
  /// both. Closed and empty by default — this screen exists to hand over an
  /// address, and how much to send is the second question, never the first.
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _labelCtrl = TextEditingController();
  bool _requestOpen = false;

  /// The amount field holds the selected fiat currency rather than coin.
  /// Only the field is in fiat: the link always carries the coin figure,
  /// which is what BIP21 defines and the only figure a payer's wallet reads.
  bool _fiatInput = false;

  /// Bumped by every [_load]; a response carrying an older number lost the
  /// race to a chain switch or a newer "New address" and is dropped.
  int _loadSeq = 0;

  // Hardware wallet verification state
  bool _verifying = false;
  bool _verified = false;
  String? _hwError;

  /// Device-verifiable wallets: USB hardware wallets (typed label) and
  /// HWI-imported watch-only wallets. Single source of truth lives on
  /// AppState; the legacy 'watch_only' label is kept for wallets imported
  /// before the type labels were unified.
  bool get _isHardwareWallet {
    final appState = context.read<AppState>();
    return appState.isActiveWalletHardware ||
        appState.activeWalletType == 'watch_only';
  }

  /// "Verify on Ledger" needs a USB HID transport, which the phone build does
  /// not ship: on Android every hardware route answers HW_UNSUPPORTED, so the
  /// button could only ever end in an error there.
  bool get _canVerifyOnDevice =>
      _isHardwareWallet &&
      _selectedAsset == 'BTC' &&
      !AppLayout.isMobilePlatform;

  @override
  void initState() {
    super.initState();
    // A Liquid-only wallet has no Bitcoin side to ask: opening on the BTC tab
    // would greet the user with "Bitcoin wallet not open" instead of the
    // address they came for.
    final st = context.read<AppState>();
    if (!st.activeWalletBitcoin && st.activeWalletLiquid) {
      _selectedAsset = 'LBTC';
    }
    // An amount can be asked for in fiat, so the price has to be there by the
    // time the request section is opened — and has to keep the ≈ line honest
    // while the screen is up.
    PriceService.instance
      ..addListener(_onPriceChanged)
      ..fetch();
    _load();
  }

  @override
  void dispose() {
    PriceService.instance.removeListener(_onPriceChanged);
    _amountCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  void _onPriceChanged() {
    if (mounted) setState(() {});
  }

  /// Loads the receive address. [fresh] advances the derivation index — only
  /// the "New address" button asks for it; simply opening the screen reuses
  /// the current unused address instead of burning a new one.
  ///
  /// The chain is captured once, up front: both bridge calls ask for the same
  /// asset, and a result that lands after the user switched chains (or asked
  /// for another fresh address) is discarded instead of being shown under
  /// the other chain's heading.
  Future<void> _load({bool fresh = false}) async {
    final asset = _selectedAsset;
    final token = ++_loadSeq;
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    final cacheKey = '$walletId/$asset';
    // Platform, not width: MediaQuery is off limits from initState.
    final cached =
        !fresh && AppLayout.isMobilePlatform ? _cache[cacheKey] : null;
    setState(() {
      _loading = cached == null;
      if (cached != null) {
        _current = cached.current;
        _previous = cached.previous;
      }
      _error = null;
      _verified = false;
      _hwError = null;
    });
    bool stale() => !mounted || token != _loadSeq || asset != _selectedAsset;
    try {
      final cur = await _bridge.generateReceiveAddress(
        walletId,
        asset,
        fresh: fresh,
      );
      if (stale()) return;
      final prev = await _bridge.listPreviousAddresses(walletId, asset);
      if (stale()) return;
      _cache[cacheKey] = (current: cur, previous: prev);
      setState(() {
        _current = cur;
        _previous = prev;
        _loading = false;
      });
    } catch (e) {
      if (stale()) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// The copy button names what it puts on the clipboard: an address until
  /// something is asked for, the whole request afterwards.
  String get _copyLabel {
    if (_copied) return 'Copied!';
    return _paymentUri != null ? 'Copy payment link' : 'Copy address';
  }

  /// What this chain calls its coin, for the unit chip and the ≈ line.
  String get _ticker => _selectedAsset == 'BTC' ? 'BTC' : 'L-BTC';

  /// The requested amount in satoshis — null when the field is empty or does
  /// not parse. A half-typed figure must not quietly become a QR: until it
  /// is a number, nothing has been asked for.
  int? get _requestSats {
    final text = _amountCtrl.text.trim();
    if (text.isEmpty) return null;
    final sats = _fiatInput
        ? AmountUnits.satsFromFiat(text, PriceService.instance.btcPrice)
        : AmountUnits.satsFromCoin(text);
    return (sats == null || sats <= 0) ? null : sats;
  }

  String get _requestNote => _labelCtrl.text.trim();

  /// The BIP21 link, or null when nothing was asked for: with no amount and
  /// no note a payment link says nothing the address does not already say,
  /// and a bare address is what every wallet and every camera reads best.
  String? get _paymentUri {
    final address = _current?.address;
    if (address == null) return null;
    final sats = _requestSats;
    if (sats == null && _requestNote.isEmpty) return null;
    return PaymentUri.build(
      address: address,
      asset: _selectedAsset,
      amountSats: sats,
      label: _requestNote,
    );
  }

  /// What the QR carries and what Copy and Share hand over — the payment
  /// link once one has been asked for, the bare address otherwise.
  String get _shareData => _paymentUri ?? _current!.address;

  /// Whether the ⇅ can flip the field right now: only with a live price, as
  /// a fiat figure cannot be resolved to coin without one.
  bool get _canToggleFiat => PriceService.instance.hasPrice;

  /// Flip the amount field between coin and fiat, re-expressing whatever is
  /// typed so the figure on screen keeps meaning the same money.
  void _toggleFiat() {
    final price = PriceService.instance.btcPrice;
    if (price <= 0) return;
    final toFiat = !_fiatInput;
    final converted = AmountUnits.convert(
      _amountCtrl.text,
      toFiat: toFiat,
      btcPrice: price,
    );
    setState(() {
      _fiatInput = toFiat;
      if (converted != null) _amountCtrl.text = converted;
    });
  }

  /// The other reading of the amount, under the field while it is typed —
  /// "≈ €98.40" under a coin figure, "≈ 0.00123456 BTC" under a fiat one.
  String? get _equivalentText {
    final sats = _requestSats;
    if (sats == null) return null;
    final price = PriceService.instance;
    if (!price.hasPrice) return null;
    return _fiatInput
        ? '≈ ${AmountUnits.coinText(sats)} $_ticker'
        : '≈ ${price.symbol}${AmountUnits.fiatText(sats, price.btcPrice)}';
  }

  /// One line naming what is being asked for, shown beside the section's
  /// title so a closed request is still a stated fact and not a surprise
  /// hiding inside the QR.
  String? get _requestSummary {
    final sats = _requestSats;
    final note = _requestNote;
    if (sats == null) return note.isEmpty ? null : note;
    final coin = '${PaymentUri.amountText(sats)} $_ticker';
    final fiat = PriceService.instance.hasPrice
        ? ' ≈ ${PriceService.instance.symbol}'
            '${AmountUnits.fiatText(sats, PriceService.instance.btcPrice)}'
        : '';
    return note.isEmpty ? '$coin$fiat' : '$coin$fiat · $note';
  }

  Future<void> _copyAddress() async {
    if (_current == null) return;
    await Clipboard.setData(ClipboardData(text: _shareData));
    if (!mounted) return;
    _confirmCopyOnPhone(context);
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  /// Copies a previous address from the phone list. Nothing to reset
  /// afterwards: the haptic and the snackbar are the receipt, so the row
  /// needs no per-row "copied" state and no glyph that flips to a check.
  Future<void> _copyPrevious(String address) async {
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) return;
    _confirmCopyOnPhone(context);
  }

  /// Phone only: the system share sheet, so the address can go straight into
  /// a messenger instead of through the clipboard.
  Future<void> _shareAddress() async {
    if (_current == null) return;
    // iPad's share popover needs an anchor; Android ignores it.
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      text: _shareData,
      subject: _paymentUri != null
          ? 'Payment request'
          : (_selectedAsset == 'BTC'
              ? 'Bitcoin testnet address'
              : 'Liquid testnet address'),
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  Future<void> _newAddress() async {
    await _load(fresh: true);
  }

  void _switchAsset(String asset) {
    if (asset == _selectedAsset) return;
    setState(() {
      _selectedAsset = asset;
      _loading = true;
      // Addresses of the other chain must not linger under the new heading.
      _current = null;
      _previous = [];
      _error = null;
      _verified = false;
      _hwError = null;
    });
    _load();
  }

  Future<void> _verifyOnDevice() async {
    if (_verifying) return;
    final walletId = context.read<AppState>().activeWalletId ?? '';
    setState(() {
      _verifying = true;
      _hwError = null;
      _verified = false;
    });
    try {
      await _bridge.verifyHwAddress(walletId);
      if (mounted) {
        setState(() {
          _verifying = false;
          _verified = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _verifying = false;
          // Shared classifier: the same failure must read the same here as in
          // the send flow and the setup screen, with the backend's
          // platform-specific guidance already folded in.
          _hwError = friendlyHwError(e);
        });
      }
    }
  }

  /// "Request an amount" — the disclosure that turns an address into an
  /// invoice: an amount, a note, or both, folded into a BIP21 link that the
  /// QR, Copy and Share all carry.
  ///
  /// Closed, it is one row; open, two fields. Either way it states what is
  /// being asked for in its own subtitle, because a request the QR carries
  /// and the screen does not name is a number nobody agreed to.
  Widget _requestSection(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final summary = _requestSummary;
    final header = InkWell(
      onTap: () => setState(() => _requestOpen = !_requestOpen),
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: phone ? AppLayout.minTouchTarget : 0,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: [
              Icon(
                Icons.request_quote_outlined,
                size: 18,
                // Crimson only once a figure is actually being asked for:
                // the accent marks state, and an empty request is no state.
                color: summary == null ? s.inkSecondary : s.accent,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Request an amount',
                      style: AppTypography.body.copyWith(color: s.ink),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        summary ?? 'Optional — adds it to the QR and the link',
                        style: AppTypography.caption.copyWith(
                          color: summary == null ? s.inkFaint : s.inkSecondary,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                _requestOpen ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: s.inkFaint,
              ),
            ],
          ),
        ),
      ),
    );
    if (!_requestOpen) {
      return Semantics(
        button: true,
        label: 'Request an amount',
        child: header,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(button: true, label: 'Request an amount', child: header),
        const SizedBox(height: AppSpacing.md),
        if (phone) const ListSectionLabel(label: 'Amount'),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: AppTypography.numeric,
          maxLength: _requestAmountMaxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          decoration: InputDecoration(
            hintText: _fiatInput ? '0.00' : '0.00000000',
            // No "0/16" under an amount: the cap is a guard, not a feature.
            counterText: '',
            // The same ⇅ chip the Send amount carries: one control, one
            // gesture, whichever end of a payment you are on.
            //
            // The Row is not decoration: the suffix slot hands its child the
            // field's whole width, and the chip's own 48 dp touch box would
            // stretch across it and push the hint out. mainAxisSize.min
            // shrinks it back to the chip, at the end of the field, which is
            // how Send's amount row carries it too.
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                UnitChip(
                  label: _fiatInput ? PriceService.instance.currency : _ticker,
                  other: _canToggleFiat
                      ? (_fiatInput ? _ticker : PriceService.instance.currency)
                      : null,
                  onTap: _canToggleFiat ? _toggleFiat : null,
                ),
              ],
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (_equivalentText case final approx?) ...[
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              approx,
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        if (phone) const ListSectionLabel(label: 'Note'),
        TextField(
          controller: _labelCtrl,
          textCapitalization: TextCapitalization.sentences,
          // Hard cap, and one line: a note is a few words for the payer,
          // not a message, and the QR above has a fixed frame to fit in.
          maxLength: kRequestNoteMaxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          maxLines: 1,
          decoration: InputDecoration(
            hintText: 'What it is for (optional)',
            // The counter only once it matters: the last ten characters.
            counterText: _labelCtrl.text.length >= kRequestNoteMaxLength - 10
                ? '${_labelCtrl.text.length}/$kRequestNoteMaxLength'
                : '',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  String get _caption => _selectedAsset == 'BTC'
      ? 'Native SegWit · a fresh address for every payment'
      : 'Confidential · the same blinded address can be reused';

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    // A chain this wallet lacks stays on the switch, dimmed: the FFI answers
    // "Liquid wallet not open" / "Bitcoin wallet not open" for a side that
    // does not exist, and a tab whose only outcome is an error is worse than
    // an inert one.
    final st = context.watch<AppState>();
    return Scaffold(
      body: PageBackground.flat(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
          children: [
            PageHeader(
              title: 'Receive',
              // The phone shell already names the wallet in its header, and
              // the caption inside the card says what kind of address this is.
              subtitle: phone ? null : 'Generate a fresh address',
              actions: [
                // Same place, same control, same colours as UTXOs and
                // Activity: which chain the page is on is decided top-right
                // on every per-chain screen, and nowhere else.
                ChainSwitch<String>(
                  selected: _selectedAsset,
                  onChanged: _switchAsset,
                  bitcoin: 'BTC',
                  liquid: 'LBTC',
                  bitcoinEnabled: st.activeWalletBitcoin,
                  liquidEnabled: st.activeWalletLiquid,
                ),
              ],
            ),
            // Second row: what this section does with the chain chosen above.
            // On a phone this row moves into the address card (caption as
            // its subtitle, "New address" as its trailing action) — the two
            // do not fit side by side on a 379 dp column.
            if (!phone) ...[
              Row(
                children: [
                  Text(
                    _caption,
                    style: AppTypography.caption.copyWith(color: s.inkSecondary),
                  ),
                  const Spacer(),
                  // Liquid CT addresses stay stable — no regenerate there.
                  if (_selectedAsset == 'BTC')
                    SecondaryButton(
                      label: 'New address',
                      icon: Icons.refresh,
                      onPressed: _newAddress,
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
            if (_loading)
              phone
                  ? const Padding(
                      padding: EdgeInsets.only(top: AppSpacing.xxl),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Center(
                child: Column(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 40,
                      color: AppColors.danger,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SelectableText(
                      phone ? _plainError(_error!) : _error!,
                      style: AppTypography.caption,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    SecondaryButton(
                      label: 'Retry',
                      icon: Icons.refresh,
                      onPressed: _load,
                    ),
                  ],
                ),
              )
            else if (phone)
              _phoneBody(context)
            else if (!_hasPreviousList)
              // Liquid: one confidential address, reused — there is no list
              // of previous ones to put beside the card, so the card stands
              // alone at the width the two-column layout would give it.
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Reveal(child: _addressCard(context)),
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // QR + address
                  Expanded(
                    child: Reveal(
                      child: _addressCard(context),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xl),
                  // Previous addresses — the newest eight, then the page.
                  Expanded(
                    child: Reveal(
                      delay: 1,
                      child: _desktopPreviousCard(context),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Bitcoin hands out a fresh address per payment, so there is a history
  /// worth listing. Liquid's confidential address is one and reused: a
  /// "previous addresses" list there would only ever repeat the card above.
  bool get _hasPreviousList => _selectedAsset == 'BTC';

  /// The newest previous addresses first — the bridge lists by ascending
  /// derivation index, and the ones most likely still in use are the latest.
  List<AddressInfo> get _previousNewestFirst => _previous.reversed.toList();

  void _openAllAddresses() =>
      context.go('${AppRoutes.receiveAddresses}?asset=$_selectedAsset');

  /// The desktop QR card: code, address well, request section, copy.
  Widget _addressCard(BuildContext context) {
    final s = AppScheme.of(context);
    return FormCard(
                      title: 'Your address',
                      child: Column(
                        children: [
                          Center(
                            child: _QrTile(data: _shareData, side: 200),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          // The well always holds the address: it is what a
                          // human reads back to check, and the link's query
                          // is machine business. What the QR adds on top is
                          // named by the section right under it.
                          DataWell(
                            child: SelectableText(
                              _current!.address,
                              style: AppTypography.mono.copyWith(color: s.ink),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          _requestSection(context),
                          const SizedBox(height: AppSpacing.lg),
                          PrimaryButton(
                            label: _copyLabel,
                            icon: _copied ? Icons.check : Icons.copy,
                            isFullWidth: true,
                            onPressed: _copyAddress,
                          ),
                          if (_canVerifyOnDevice) ...[
                            const SizedBox(height: AppSpacing.md),
                            _HwVerifyButton(
                              verifying: _verifying,
                              verified: _verified,
                              error: _hwError,
                              onVerify: _verifyOnDevice,
                            ),
                          ],
                        ],
                      ),
                      );
  }

  /// The desktop list of previous addresses: the newest eight as rows, and
  /// one quiet action to the page that lists every one with its amounts.
  Widget _desktopPreviousCard(BuildContext context) {
    final s = AppScheme.of(context);
    final previous = _previousNewestFirst;
    final shown = previous.take(_previousPreview).toList();
    final hiddenCount = previous.length - shown.length;
    return SectionCard(
      title: 'Previous addresses',
      action: previous.isEmpty
          ? null
          : GhostButton(
              label: hiddenCount > 0
                  ? 'Show all ($hiddenCount more)'
                  : 'Show all',
              onPressed: _openAllAddresses,
            ),
      child: previous.isEmpty
          ? Text(
              'No previous addresses',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            )
          : Column(
              children: [for (final a in shown) _AddressRow(info: a)],
            ),
    );
  }

  /// Single column for a 379 dp content column: the QR card first, at full
  /// width with the code as large as the column allows, then the previous
  /// addresses as one labelled list group.
  Widget _phoneBody(BuildContext context) {
    final s = AppScheme.of(context);
    final address = _current!.address;
    final previous = _previousNewestFirst;
    final previewCount = previous.length <= _previousPreview
        ? previous.length
        : _previousPreview;
    final hiddenCount = previous.length - previewCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Reveal(
          child: FormCard(
            title: 'Your address',
            subtitle: _caption,
            // No trailing glyph here: "New address" moved down into the
            // button stack, where it has a name. A tooltip is the only name
            // an IconButton carries, and a finger never sees one.
            padding: const EdgeInsets.all(AppSpacing.cardPaddingSmall),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: _QrTile(
                    data: _shareData,
                    side: AppLayout.qrSide(context),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                // Tap copies; long-press still selects. monoSmall keeps a
                // bech32 address on one line and a CT address on two.
                DataWell(
                  child: SelectableText(
                    address,
                    style: AppTypography.monoSmall.copyWith(color: s.ink),
                    textAlign: TextAlign.center,
                    onTap: _copyAddress,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                _requestSection(context),
                const SizedBox(height: AppSpacing.md),
                PrimaryButton(
                  label: _copyLabel,
                  icon: _copied ? Icons.check : Icons.copy,
                  isFullWidth: true,
                  onPressed: _copyAddress,
                ),
                const SizedBox(height: AppSpacing.md),
                SecondaryButton(
                  label: 'Share',
                  icon: Icons.share_outlined,
                  isFullWidth: true,
                  onPressed: _shareAddress,
                ),
                // Liquid CT addresses stay stable — no regenerate there.
                // Stacked full width rather than sharing a line with Share:
                // half of a 360 dp column leaves ~84 dp of label, and "New
                // address" would ellipsise there.
                if (_selectedAsset == 'BTC') ...[
                  const SizedBox(height: AppSpacing.md),
                  SecondaryButton(
                    label: 'New address',
                    icon: Icons.refresh,
                    isFullWidth: true,
                    onPressed: _newAddress,
                  ),
                ],
                if (_canVerifyOnDevice) ...[
                  const SizedBox(height: AppSpacing.md),
                  _HwVerifyButton(
                    verifying: _verifying,
                    verified: _verified,
                    error: _hwError,
                    onVerify: _verifyOnDevice,
                  ),
                ],
              ],
            ),
          ),
        ),
        // Liquid's one address is the card above; nothing to list under it.
        if (_hasPreviousList) ...[
          // The gap the Dashboard leaves between two labelled list groups.
          const SizedBox(height: AppSpacing.xl),
          Reveal(
            delay: 1,
            // The phone's list grammar — the same labelled group of rows the
            // Dashboard and Settings draw, so a row means the same thing here.
            // The empty state and "Show all" are rows in that card too, so the
            // group keeps one shape whatever it holds.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ListSectionLabel(label: 'Previous addresses'),
                ListCard(
                  children: [
                    if (previous.isEmpty)
                      ListRow(
                        icon: Icons.inbox_rounded,
                        tint: s.inkFaint,
                        title: 'No previous addresses',
                        subtitle: 'Addresses you have used show up here',
                      )
                    else ...[
                      for (final a in previous.take(previewCount))
                        _previousRow(context, a),
                      if (hiddenCount > 0)
                        ListRow(
                          icon: Icons.list_alt_rounded,
                          tint: s.inkSecondary,
                          title: 'Show all',
                          subtitle: '$hiddenCount more, with amounts',
                          chevron: true,
                          onTap: _openAllAddresses,
                        ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// One previous address as a phone list row. The whole row is the copy
  /// target — there is no small button to miss — and the snackbar confirms.
  Widget _previousRow(BuildContext context, AddressInfo a) {
    final s = AppScheme.of(context);
    final funded = a.receivedSats > 0;
    final short = _shortAddress(a.address, head: 10, tail: 8);
    return ListRow(
      // The glyph Activity already gives an incoming transaction: an address
      // is where money arrives. The tint, not the glyph, says whether any
      // has.
      icon: Icons.south_west_rounded,
      tint: funded ? s.success : s.inkFaint,
      // A labelled address leads with its label; an unlabelled one has
      // nothing to lead with but itself.
      title: a.label ?? short,
      subtitle: a.label == null ? '#${a.index}' : '#${a.index} · $short',
      trailing: funded
          ? ListAmount(
              value: '${a.receivedSats}',
              unit: 'sats',
              maxWidth: 120,
            )
          // Nothing received: the faint copy glyph says what the tap does.
          : Icon(Icons.copy, size: 18, color: s.inkFaint),
      onTap: () => _copyPrevious(a.address),
    );
  }
}

/// Phone-only copy receipt: a light haptic plus a floating SnackBar. The thumb
/// covers the button whose label just flipped to "Copied!", and Android 12
/// and below show no system toast for clipboard writes.
void _confirmCopyOnPhone(BuildContext context) {
  if (!AppLayout.isPhone(context)) return;
  HapticFeedback.lightImpact();
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(
      content: Text('Address copied'),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 2),
    ));
}

/// Drops the transport wrappers ("Exception: wallet-ffi: …") so the phone's
/// error view leads with the backend's own sentence.
String _plainError(String raw) {
  var msg = raw.trim();
  for (final prefix in const ['Exception: ', 'wallet-ffi: ']) {
    if (msg.startsWith(prefix)) msg = msg.substring(prefix.length).trim();
  }
  return msg;
}

/// Middle-ellipsised address for a one-line row; short strings pass through.
String _shortAddress(String address, {int head = 12, int tail = 8}) {
  if (address.length <= head + tail + 1) return address;
  return '${address.substring(0, head)}…${address.substring(address.length - tail)}';
}

/// The QR on its white tile, sized by the caller: 200 dp on desktop, the
/// column width (capped) on a phone.
class _QrTile extends StatelessWidget {
  const _QrTile({required this.data, required this.side});

  final String data;
  final double side;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        // Soft accent halo lifts the QR off the glass.
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.20),
            blurRadius: 28,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      // The payload is this QR's identity: a new one is a different code,
      // not a repaint of the old. It is also the only way a test can read
      // back what a payer's camera would — the package keeps `data` private.
      //
      // The frame is pinned to [side] on both axes: a longer payload means
      // more modules inside the same square, never a bigger square.
      child: SizedBox.square(
        dimension: side,
        child: QrImageView(
          key: ValueKey<String>(data),
          data: data,
          version: QrVersions.auto,
          size: side,
          padding: EdgeInsets.zero,
          semanticsLabel: 'Receive address QR code',
        ),
      ),
    );
  }
}

class _HwVerifyButton extends StatelessWidget {
  const _HwVerifyButton({
    required this.verifying,
    required this.verified,
    required this.error,
    required this.onVerify,
  });

  final bool verifying;
  final bool verified;
  final String? error;
  final VoidCallback onVerify;

  @override
  Widget build(BuildContext context) {
    if (verified) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.verified, color: AppColors.success, size: 16),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Address confirmed on device',
              style: AppTypography.label.copyWith(color: AppColors.success),
            ),
          ],
        ),
      );
    }

    if (error != null) {
      return Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Text(
              error!,
              style: AppTypography.caption.copyWith(color: AppColors.danger),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _verifyButton(onVerify),
        ],
      );
    }

    return _verifyButton(onVerify, loading: verifying);
  }

  Widget _verifyButton(VoidCallback onPress, {bool loading = false}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: loading ? null : onPress,
        icon: loading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.usb, size: 16),
        label: Text(loading ? 'Confirm on Ledger…' : 'Verify on Ledger'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accent,
          side: BorderSide(color: AppColors.accent.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          textStyle: AppTypography.label,
        ),
      ),
    );
  }
}

/// One previous address on the desktop table: a single row, whole-row copy,
/// fixed columns. The phone draws the same data through the shared list
/// grammar instead (see _ReceiveScreenState._previousRow).
class _AddressRow extends StatefulWidget {
  const _AddressRow({required this.info});
  final AddressInfo info;

  @override
  State<_AddressRow> createState() => _AddressRowState();
}

class _AddressRowState extends State<_AddressRow> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.info.address));
    if (!mounted) return;
    _confirmCopyOnPhone(context);
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    // Whole row is a copy target — hover tint invites the click.
    return HoverRow(
      onTap: _copy,
      child: Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.sm,
        horizontal: AppSpacing.xs,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text('#${widget.info.index}', style: AppTypography.caption),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _shortAddress(widget.info.address),
              style: AppTypography.monoSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.info.label != null)
            Text(widget.info.label!, style: AppTypography.caption),
          const SizedBox(width: AppSpacing.sm),
          if (widget.info.receivedSats > 0)
            Text(
              '${widget.info.receivedSats} sats',
              style: AppTypography.caption,
            ),
          IconButton(
            icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
            onPressed: _copy,
            visualDensity: VisualDensity.compact,
            color: _copied ? AppColors.success : AppColors.textMuted,
          ),
        ],
      ),
      ),
    );
  }
}
