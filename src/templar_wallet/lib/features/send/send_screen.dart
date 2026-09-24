import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/back_handler.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../features/dashboard/models/dashboard_data.dart';
import '../../features/send/models/tx_preview.dart';
import '../../shared/amount_units.dart';
import '../../shared/payment_uri.dart';
import '../../shared/widgets/unit_chip.dart';
import '../hardware/hw_error.dart';
import '../hardware/ledger_connect_dialog.dart';
import '../hardware/ledger_signing_dialog.dart';
import '../psbt/cosign_handoff.dart';
import '../psbt/cosign_view.dart';
import '../utxos/models/utxo.dart';
import '../../services/asset_registry_service.dart';
import '../../services/price_service.dart';
import '../../shared/widgets/asset_logo.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/hex_text.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/app_password_gate.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/psbt_sign_flow.dart';
import '../../shared/widgets/scan_button.dart';
import '../../shared/widgets/tx_confirm_view.dart';
import '../../shared/widgets/tx_success_view.dart';
import '../../shared/widgets/ur_qr.dart';
import '../receive/models/address_info.dart';
import '../../shared/widgets/utxo_views.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// What kind of send this is: build a new transaction from scratch, or load a
/// PSBT someone else started and add this wallet's signature to it.
enum _TxKind { standard, cosign }

/// Wizard steps for a standard transaction.
enum _WizStep { type, asset, inputs, outputs, fee, review }

/// One recipient row being edited in the Outputs step.
class _OutputDraft {
  final addressCtrl = TextEditingController();
  final amountCtrl = TextEditingController();

  /// Per-output Liquid asset; null = L-BTC (or plain Bitcoin on BTC sends).
  /// One Liquid transaction can carry different assets per output.
  AssetBalance? asset;

  /// Backend drain flag: "spend everything that is left, after the fee".
  /// Only BTC/L-BTC can be drained, because the fee comes out of the same
  /// asset — the exact amount is not known until the preview builds.
  bool sendMax = false;

  /// MAX is engaged on this row. Distinct from [sendMax]: a token MAX is a
  /// concrete number (its whole balance, since the fee is paid in L-BTC), so
  /// it never sets the drain flag but must still light up and toggle off.
  bool maxEngaged = false;

  /// Whatever was typed before MAX took the field over, restored on toggle-off
  /// so engaging MAX by accident costs nothing.
  String? amountBeforeMax;

  /// The amount field holds the selected fiat currency rather than coin.
  /// BTC / L-BTC rows only — a token has no price to convert at. The wallet
  /// never sees fiat: [_SendScreenState._amountSatsOf] resolves it to sats
  /// at the spot price the moment it is read.
  bool fiatInput = false;

  /// The exact amount behind the text the last ⇅ flip wrote, and that text.
  /// Fiat has two decimals, so "0.0025 BTC" flips to "199.25" and would come
  /// back as 0.00250003; as long as the field still reads what the flip
  /// wrote, the amount is these sats, not a re-parse of the rounded text.
  int? flipSats;
  String? flipText;

  void dispose() {
    addressCtrl.dispose();
    amountCtrl.dispose();
  }
}

class SendScreen extends StatefulWidget {
  const SendScreen({super.key, this.startInCosign = false, this.bridge});

  /// Open directly in co-sign mode (used by the legacy /cosign deep link).
  final bool startInCosign;

  /// Test seam. Null in the app, where the global engine is used; a widget
  /// test hands in a stub so the wizard can be pumped without the native
  /// library or the user's wallet directory.
  final WalletBridge? bridge;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;

  late _TxKind? _kind = widget.startInCosign ? _TxKind.cosign : null;
  _WizStep _step = _WizStep.type;

  /// Highest step the user has reached — earlier steps stay clickable.
  int _maxReached = 0;

  /// Android back: step the wizard back before leaving the screen.
  late final BackHandlerCallback _systemBack = _handleSystemBack;

  // Network step
  List<AssetBalance> _assets = [];
  AssetBalance? _selectedAsset;
  bool _loadingAssets = true;

  // Inputs step
  bool _manualInputs = false;
  List<Utxo> _utxos = [];
  bool _loadingUtxos = false;

  // Outputs step
  final List<_OutputDraft> _outputs = [_OutputDraft()];

  // Fee step
  String _feePreset = 'normal';
  final _customFeeCtrl = TextEditingController();
  static const _feeRates = {'slow': 1.0, 'normal': 3.0, 'fast': 8.0};

  // Review step
  TxPreview? _preview;
  bool _previewing = false;
  bool _sending = false;
  String? _error;

  /// A device-signed PSBT whose broadcast has not succeeded yet. Held so a
  /// broadcast-only failure can be retried without a second on-device
  /// approval. Cleared the moment the transaction reaches the network.
  String? _pendingSignedPsbt;

  /// The transaction the retained PSBT was signed for. Reuse is allowed only
  /// when the user is still sending exactly that — edit the amount, the
  /// recipient, the fee or the coin selection and the retained signature is
  /// for a different transaction, which must never be the one broadcast.
  String? _pendingSignedKey;

  /// A fully-signed transaction whose broadcast failed, retained as
  /// (walletId, signed PSBT base64) so the user can retry the broadcast or
  /// copy the artifact out instead of losing the collected signatures.
  (String, String)? _failedBroadcast;

  @override
  void initState() {
    super.initState();
    BackHandler.instance.push(_systemBack);
    _loadAssets();
    // The amount field can be typed in fiat; make sure a price is there by
    // the time the user reaches it, and follow it while the screen is up.
    PriceService.instance
      ..addListener(_onPriceChanged)
      ..fetch();
  }

  @override
  void dispose() {
    BackHandler.instance.remove(_systemBack);
    PriceService.instance.removeListener(_onPriceChanged);
    for (final o in _outputs) {
      o.dispose();
    }
    _customFeeCtrl.dispose();
    super.dispose();
  }

  // ── data loading ────────────────────────────────────────────────────────────

  String get _walletId =>
      context.read<AppState>().activeWalletId ?? 'wallet-1';

  Future<void> _loadAssets() async {
    try {
      final data = await _bridge.getWalletSummary(_walletId);
      if (mounted) {
        setState(() {
          // Air-gap wallets sign by QR, and there is no Liquid PSET QR flow,
          // so their Liquid assets are not offered at all — showing them let
          // the user reach the review step before anything objected.
          //
          // USB wallets are *not* filtered here: a Jade's Liquid wallet is a
          // hardware wallet whose only assets are Liquid ones, and a
          // Bitcoin-only device never has a Liquid side to show in the first
          // place, because pairing one is refused at creation.
          _assets = _signsBitcoinOnly
              ? data.assets.where((a) => a.ticker == 'BTC').toList()
              : data.assets;
          _selectedAsset ??= _assets.isNotEmpty ? _assets.first : null;
          _loadingAssets = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingAssets = false);
    }
  }

  /// Air-gap wallets sign a PSBT carried by QR, and no Liquid PSET QR flow
  /// exists — on either side of the glass. So Liquid is off the table for
  /// them regardless of which device it is, Jade included.
  ///
  /// USB is deliberately *not* included: a Jade signs Liquid over serial.
  bool get _signsBitcoinOnly => _isAirgapWallet;

  Future<void> _loadUtxos() async {
    setState(() => _loadingUtxos = true);
    try {
      final all = await _bridge.listUtxos(_walletId, 'BTC');
      // Spendable coins are pickable as inputs. Frozen ones are listed too,
      // locked with their chip, so the coins on screen still add up to the
      // balance; the engine would refuse them anyway.
      final spendable = all
          .where((u) =>
              u.state == UtxoState.available ||
              u.state == UtxoState.dusty ||
              u.state == UtxoState.frozen)
          .toList();
      if (mounted) {
        setState(() {
          _utxos = spendable;
          _loadingUtxos = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingUtxos = false);
    }
  }

  // ── derived state ───────────────────────────────────────────────────────────

  bool get _isBtc => _selectedAsset?.ticker == 'BTC';
  bool get _isBtcLike =>
      _selectedAsset?.ticker == 'BTC' || _selectedAsset?.ticker == 'LBTC';

  /// Assets spendable per-output on Liquid: L-BTC first, then every token
  /// with a balance (reissuance tokens included — they are outputs too).
  List<AssetBalance> get _liquidSpendable => [
        ..._assets.where((a) => a.ticker == 'LBTC'),
        ..._assets.where((a) => a.ticker != 'BTC' && a.ticker != 'LBTC' && a.amount > 0),
      ];

  /// The asset a given output row pays (L-BTC when none picked).
  AssetBalance? _rowAsset(_OutputDraft o) =>
      _isBtc ? _selectedAsset : (o.asset ?? _selectedAsset);

  bool _rowIsBtcLike(_OutputDraft o) {
    final t = _rowAsset(o)?.ticker ?? 'BTC';
    return t == 'BTC' || t == 'LBTC';
  }

  String _rowTicker(_OutputDraft o) {
    final a = _rowAsset(o);
    if (a == null) return 'BTC';
    return a.ticker == 'LBTC' || a.ticker == 'BTC'
        ? a.ticker
        : AssetRegistryService.instance.displayTicker(a);
  }

  bool get _isHardwareWallet {
    final t = context.read<AppState>().activeWalletType ?? '';
    return t.startsWith('Hardware (') || t.toLowerCase().contains('hardware');
  }

  bool get _isAirgapWallet {
    final t = context.read<AppState>().activeWalletType ?? '';
    return t.toLowerCase().contains('air-gap') || t.toLowerCase().contains('airgap');
  }

  bool get _isMultisigWallet {
    final t = context.read<AppState>().activeWalletType ?? '';
    return t.toLowerCase().contains('multisig');
  }

  double get _feeRate {
    if (_feePreset == 'custom') {
      final v = double.tryParse(_customFeeCtrl.text.trim());
      // Clamp to sane testnet bounds; fall back to normal when unparsable.
      if (v != null && v > 0) return v.clamp(0.1, 500.0);
      return 3.0;
    }
    return _feeRates[_feePreset] ?? 3.0;
  }

  void _onPriceChanged() {
    if (mounted) setState(() {});
  }

  /// Parses one output row's amount into sats/base units for the row's asset.
  int? _amountSatsOf(_OutputDraft o) {
    final text = o.amountCtrl.text;
    if (text.trim().isEmpty) return null;
    if (_rowIsBtcLike(o)) {
      // Untouched since a ⇅ flip: the flip's exact amount, not the rounded
      // text re-parsed.
      if (o.flipSats != null && text == o.flipText) return o.flipSats;
      // BTC / L-BTC: typed in coin (8 decimals) or in the selected fiat and
      // converted at the spot price — the wallet only ever sees sats.
      return o.fiatInput
          ? AmountUnits.satsFromFiat(text, PriceService.instance.btcPrice)
          : AmountUnits.satsFromCoin(text);
    }
    // Other tokens: input directly in base units.
    final v = AmountUnits.parseDecimal(text);
    return v?.round();
  }

  /// Whether a row's ⇅ can flip between coin and fiat right now: a BTC-like
  /// row, a live price, and MAX not holding the field.
  bool _canToggleFiat(_OutputDraft o) =>
      _rowIsBtcLike(o) && PriceService.instance.hasPrice && !o.maxEngaged;

  /// Flip a row between coin and fiat, re-expressing whatever is typed so
  /// the amount itself does not change — the number in the box does.
  void _toggleFiat(int i) {
    final o = _outputs[i];
    if (!_canToggleFiat(o)) return;
    final price = PriceService.instance.btcPrice;
    final toFiat = !o.fiatInput;
    // Resolve the amount in the unit the field is in *now*, exact where a
    // previous flip left it untouched.
    final sats = _amountSatsOf(o);
    setState(() {
      o.fiatInput = toFiat;
      final String? converted;
      if (o.amountCtrl.text.trim().isEmpty) {
        converted = '';
      } else if (sats == null) {
        // Unparsable: the user is mid-edit and can see it — leave it alone.
        converted = null;
      } else {
        converted = toFiat
            ? AmountUnits.fiatText(sats, price)
            : AmountUnits.coinText(sats);
      }
      if (converted != null) {
        o.amountCtrl.value = TextEditingValue(
          text: converted,
          selection: TextSelection.collapsed(offset: converted.length),
        );
      }
      o.flipSats = converted == null || converted.isEmpty ? null : sats;
      o.flipText = converted == null || converted.isEmpty ? null : converted;
    });
  }

  /// "≈ €98.40" under a coin amount, "≈ 0.00123456 BTC" under a fiat one —
  /// the other reading of the same number, so a typo in either unit is
  /// caught before Review. Null when there is nothing to say.
  String? _equivalentText(_OutputDraft o) {
    if (!_rowIsBtcLike(o) || o.sendMax) return null;
    final price = PriceService.instance;
    if (!price.hasPrice) return null;
    final sats = _amountSatsOf(o);
    if (sats == null) return null;
    return o.fiatInput
        ? '≈ ${AmountUnits.coinText(sats)} ${_rowTicker(o)}'
        : '≈ ${price.symbol}${AmountUnits.fiatText(sats, price.btcPrice)}';
  }

  List<TxOutputSpec>? get _outputSpecs {
    final specs = <TxOutputSpec>[];
    for (final o in _outputs) {
      final addr = o.addressCtrl.text.trim();
      if (addr.isEmpty) return null;
      // Per-output asset only matters on Liquid; the backend falls back to
      // the transaction-level asset (L-BTC) when omitted.
      final assetId = _isBtc ? null : _rowAsset(o)?.assetId;
      if (o.sendMax) {
        specs.add(TxOutputSpec(
            address: addr, amountSats: 0, assetId: assetId, sendMax: true));
        continue;
      }
      final sats = _amountSatsOf(o);
      if (sats == null || sats <= 0) return null;
      specs.add(TxOutputSpec(address: addr, amountSats: sats, assetId: assetId));
    }
    return specs.isEmpty ? null : specs;
  }

  /// BTC-like total of the fixed rows (MAX rows excluded — their amount is
  /// only known after the preview builds).
  int get _outputsTotal => _outputs
      .where((o) => !o.sendMax && _rowIsBtcLike(o))
      .fold(0, (s, o) => s + (_amountSatsOf(o) ?? 0));

  /// One "ticker → total" line per asset across the output rows.
  Map<String, int> get _totalsByTicker {
    final totals = <String, int>{};
    for (final o in _outputs.where((o) => !o.sendMax)) {
      final sats = _amountSatsOf(o);
      if (sats == null) continue;
      final t = _rowTicker(o);
      totals[t] = (totals[t] ?? 0) + sats;
    }
    return totals;
  }

  bool get _hasMaxOutput => _outputs.any((o) => o.sendMax);

  List<Utxo> get _selectedUtxos => _utxos.where((u) => u.isSelected).toList();
  int get _selectedInputTotal =>
      _selectedUtxos.fold(0, (s, u) => s + u.amount);

  /// Outpoints to pass to the bridge — null means automatic selection.
  List<String>? get _spendOutpoints => _isBtc && _manualInputs
      ? _selectedUtxos.map((u) => u.outpoint).toList()
      : null;

  String _fmtAmount(int sats) {
    if (_isBtcLike) {
      return '${(sats / 1e8).toStringAsFixed(8)} ${_selectedAsset?.ticker ?? 'BTC'}';
    }
    return '$sats ${_selectedAsset != null ? AssetRegistryService.instance.displayTicker(_selectedAsset!) : ''}';
  }

  // ── wizard navigation ───────────────────────────────────────────────────────

  bool get _canContinue => switch (_step) {
        _WizStep.type => _kind != null,
        _WizStep.asset => _selectedAsset != null,
        _WizStep.inputs =>
          !_manualInputs || (_isBtc && _selectedUtxos.isNotEmpty),
        _WizStep.outputs => _outputSpecs != null,
        _WizStep.fee => _feeRate > 0,
        _WizStep.review => _preview != null && !_previewing && !_sending,
      };

  void _goTo(_WizStep step) {
    setState(() {
      _step = step;
      _maxReached = math.max(_maxReached, step.index);
      _error = null;
    });
    if (step == _WizStep.inputs && _isBtc && _utxos.isEmpty) _loadUtxos();
    if (step == _WizStep.review) _buildPreview();
  }

  void _next() {
    if (_step == _WizStep.review) return;
    _goTo(_WizStep.values[_step.index + 1]);
  }

  void _back() {
    if (_step == _WizStep.type) return;
    setState(() {
      _step = _WizStep.values[_step.index - 1];
      _error = null;
    });
  }

  /// The system back while the wizard is past its first step: one step
  /// back, exactly as the on-screen Back. Consumed but ignored mid-send,
  /// when the on-screen Back is disabled too. On the first step the shell
  /// takes over and returns to the Dashboard.
  bool _handleSystemBack() {
    // A departing Send stays mounted for the page transition; its handler
    // must not swallow a press meant for the page that replaced it.
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    if (_step == _WizStep.type) return false;
    if (!_sending) _back();
    return true;
  }

  void _selectKind(_TxKind kind) {
    setState(() => _kind = kind);
    if (kind == _TxKind.standard) _goTo(_WizStep.asset);
  }

  void _resetWizard() {
    setState(() {
      _step = _WizStep.asset;
      _maxReached = _WizStep.asset.index;
      _manualInputs = false;
      for (final o in _outputs) {
        o.dispose();
      }
      _outputs
        ..clear()
        ..add(_OutputDraft());
      _preview = null;
      _error = null;
      _failedBroadcast = null;
      _utxos = [];
    });
  }

  // ── preview + send ──────────────────────────────────────────────────────────

  Future<void> _buildPreview() async {
    final specs = _outputSpecs;
    final asset = _selectedAsset;
    if (specs == null || asset == null) return;

    setState(() {
      _previewing = true;
      _preview = null;
      _error = null;
      // A new build supersedes any signed transaction kept from a failed
      // broadcast — the user chose to start over.
      _failedBroadcast = null;
    });
    try {
      final preview = await _bridge.previewTransaction(
        walletId: _walletId,
        outputs: specs,
        assetId: asset.assetId,
        feeRate: _isBtc ? _feeRate : 0.1,
        utxos: _spendOutpoints,
      );
      if (mounted) {
        setState(() {
          _preview = preview;
          _previewing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewing = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Text on the confirm dialog's primary button, and the line under it.
  (String, String) get _signCopy => _isHardwareWallet
      ? (
          'Sign on device',
          'Your hardware wallet will display the transaction and ask you to approve it.'
        )
      : _isAirgapWallet
          ? (
              'Export PSBT',
              'A PSBT is generated for your air-gap device; you scan the signed one back.'
            )
          : _isMultisigWallet
              ? (
                  'Sign & continue',
                  'Signed with this wallet\'s key(s). If the policy needs more '
                      'signatures, you\'ll export the PSBT to your co-signers '
                      'instead of broadcasting.'
                )
              // Only Liquid reaches this branch now: a Bitcoin software send
              // skips this dialog entirely for the two-phase review, and a
              // PSET has no QR form to review it with.
              : (
                  'Sign & send',
                  'Signed with this wallet\'s key — you re-enter your app '
                      'password first — and broadcast immediately.'
                );

  /// "Send" on the review step opens a last summary of exactly what will
  /// happen. Nothing is signed until the user confirms there.
  Future<void> _confirm() async {
    final specs = _outputSpecs;
    final asset = _selectedAsset;
    final preview = _preview;
    if (specs == null || asset == null || preview == null) return;

    // The two-phase path opens with its own summary of the built PSBT — the
    // same numbers, plus the QR and the signature state. Showing the confirm
    // dialog first would summarise the transaction twice in a row.
    final twoPhase = _isBtc &&
        !_isHardwareWallet &&
        !_isAirgapWallet &&
        !_isMultisigWallet;
    if (!twoPhase) {
      final (signLabel, signHint) = _signCopy;
      final confirmed = await showTxConfirmDialog(
        context,
        preview: preview,
        ticker: _isBtc ? 'BTC' : 'L-BTC',
        signLabel: signLabel,
        signHint: signHint,
      );
      if (!confirmed || !mounted) return;
    }

    // Asset decides the route before wallet type does. A Jade's Liquid wallet
    // carries the same `Hardware (fp)` label as a Ledger's Bitcoin wallet, so
    // branching on type alone would hand an Elements transaction to the
    // Bitcoin/HWI path. Liquid always goes through `sendTransaction`, where
    // the backend picks the signer — software, or the Jade over serial — and
    // refuses any device that cannot sign Liquid at all.
    if (!_isBtc) {
      // A Liquid send from a hardware wallet still needs the device: the
      // backend connects to the Jade and asks it to sign the PSET. Gate on the
      // device being there first, so the prompt is "connect and unlock your
      // Jade" rather than a serial timeout several seconds later. Air-gap
      // wallets never reach here — Liquid is not offered for them at all.
      if (_isHardwareWallet && !_isAirgapWallet) {
        if (!await _ensureDeviceConnected()) return;
        if (!mounted) return;
      }
      await _doSend(specs, asset);
    } else if (_isHardwareWallet) {
      await _doSendHw(specs, asset);
    } else if (_isAirgapWallet) {
      await _doSendAirgap(specs);
    } else if (_isMultisigWallet) {
      // Multisig keeps the one-shot path: a partial signature has to reach the
      // co-signer hand-off dialog, which `sendTransaction` already returns.
      await _doSend(specs, asset);
    } else {
      await _doSendTwoPhase(specs);
    }
  }

  /// Label of the wizard's own send button, so the review step says what the
  /// next screen will be rather than promising a broadcast.
  String get _sendButtonLabel => _isHardwareWallet
      ? 'Sign on device'
      : _isAirgapWallet
          ? 'Export PSBT'
          : 'Review & sign';

  /// Software-key Bitcoin send, in two passes — the same flow the UTXO screen
  /// uses to consolidate.
  ///
  /// `send_transaction` builds, signs and broadcasts inside one FFI call: the
  /// user never sees what was signed, and a broadcast failure throws the
  /// signature away. Here the PSBT is built first, reviewed (with its QR),
  /// signed behind the app password, reviewed again as a signed transaction,
  /// and only then broadcast.
  Future<void> _doSendTwoPhase(List<TxOutputSpec> specs) async {
    final walletId = _walletId;
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final unsigned = await _bridge.buildUnsignedPsbt(
        walletId: walletId,
        outputs: specs,
        feeRate: _feeRate,
        utxos: _spendOutpoints,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      final txid = await showPsbtSignFlow(
        context,
        walletId: walletId,
        unsignedPsbt: unsigned,
        title: 'Review transaction',
        summary: specs.length == 1
            ? 'One recipient.'
            : '${specs.length} recipients in one transaction.',
      );
      // Backed out at the review or the password: nothing was signed, nothing
      // was sent, and the wizard stays on the review step.
      if (txid == null || !mounted) return;
      _showSuccess(txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Software-key send. Known limitation: the FFI signs and broadcasts inside
  /// one call (`send_transaction`), so when only the broadcast leg fails the
  /// signed transaction never reaches Dart and cannot be retained for retry —
  /// unlike the air-gap/multisig flows, which broadcast a PSBT they hold.
  /// Re-running the send just re-signs the same coins, so nothing is lost.
  Future<void> _doSend(List<TxOutputSpec> specs, AssetBalance asset) async {
    final walletId = _walletId;
    // Same gate as the two-phase path: a key held on this computer is only
    // ever used behind the app password. A hardware wallet approves on the
    // device instead, so asking there would protect nothing.
    if (!_isHardwareWallet) {
      final ok = await showSpendPasswordGate(
        context,
        message: 'Templar is about to sign this transaction with the key '
            'stored on this ${AppLayout.isMobilePlatform ? 'device' : 'computer'}.',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final result = await _bridge.sendTransaction(
        walletId: walletId,
        outputs: specs,
        assetId: asset.assetId,
        feeRate: _isBtc ? _feeRate : 0.1,
        utxos: _spendOutpoints,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      // A multisig send needing external co-signatures returns a JSON object
      // instead of a txid (see FfiWalletBridge.sendTransaction).
      if (result.startsWith('{')) {
        final j = jsonDecode(result) as Map<String, dynamic>;
        final partial = j['partial_psbt'] as String?;
        if (partial != null) {
          _showPartialSignDialog(
            walletId,
            partial,
            j['sigs_have'] as int? ?? 0,
            j['sigs_needed'] as int?,
          );
          return;
        }
        // The Liquid form of the same outcome. Kept apart from the PSBT path
        // because the transports differ: a PSET has no BC-UR QR encoding, so
        // it travels as text or a file only.
        final partialPset = j['partial_pset'] as String?;
        if (partialPset != null) {
          _showLiquidCosignDialog(
            walletId,
            partialPset,
            j['sigs_have'] as int? ?? 0,
            j['sigs_needed'] as int? ?? 0,
          );
          return;
        }
      }
      _showSuccess(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Make sure the wallet's own device is plugged in and unlocked before
  /// signing, on either chain. Shows the connect gate (no watch-only escape
  /// hatch here — we need to sign) and checks the device reports the
  /// fingerprint this wallet was created from, so a second device on the desk
  /// cannot be asked to sign for a wallet it has no key for.
  ///
  /// This is what makes "browse with the device unplugged, connect it to send"
  /// work: the wallet opens watch-only, and the device is only ever required
  /// here.
  Future<bool> _ensureDeviceConnected() async {
    final appState = context.read<AppState>();
    final result = await showLedgerConnectDialog(
      context,
      expectedFingerprint: fingerprintFromTypeLabel(appState.activeWalletType),
      allowWatchOnly: false,
      title: 'Connect your device to sign',
    );
    if (!mounted) return false;
    if (result == LedgerConnectResult.connected) {
      appState.setHwWatchOnly(false);
      return true;
    }
    return false;
  }

  /// Hardware-wallet send. Same limitation as [_doSend]: build, device
  /// signing, and broadcast happen inside one FFI call
  /// (`send_transaction_hw`), so a broadcast-only failure surfaces as an
  /// error string and the device-signed PSBT is not retained on the Dart
  /// side. The user re-approves on the device to try again.
  /// Identifies the exact transaction a retained signature belongs to.
  String _txKey(List<TxOutputSpec> specs, AssetBalance asset) => jsonEncode({
        'wallet': _walletId,
        'asset': asset.assetId,
        'fee': _feeRate,
        'utxos': _spendOutpoints,
        'outputs': specs.map((o) => o.toJson()).toList(),
      });

  Future<void> _doSendHw(List<TxOutputSpec> specs, AssetBalance asset) async {
    if (!_assertBitcoinOnly(asset)) return;
    // No platform gate here any more: Ledger and Jade are driven in-process
    // on every OS. A device that genuinely has no path on this platform is
    // refused by the backend with the reason and the way round it, which
    // arrives through the normal error banner.
    final key = _txKey(specs, asset);
    // Signing and broadcasting are two backend calls, not one. A PSBT the
    // device already signed is reused *only* for the identical transaction,
    // so a broadcast that failed on its own (no connectivity, a node hiccup)
    // is retried without a second on-device approval — while any edit to the
    // draft invalidates it and forces a fresh signature.
    final retry = _pendingSignedPsbt != null && _pendingSignedKey == key;
    if (!retry) {
      _pendingSignedPsbt = null;
      _pendingSignedKey = null;
      // Confirm the device is actually present before building/signing — gives
      // a clear "plug in your device" prompt instead of a deep driver error.
      if (!await _ensureDeviceConnected()) return;
      if (!mounted) return;
    }

    setState(() {
      _error = null;
      _sending = true;
    });

    final walletId = _walletId;
    final txid = await showLedgerSigningDialog(
      context,
      // Pre-sign guard: device displays a wallet address and the user confirms
      // it matches the on-device screen, proving the connected Ledger controls
      // this wallet before we build and sign. Skipped on a broadcast-only
      // retry: nothing is being signed, and the device may be unplugged again.
      verifyTask: retry ? null : () => _bridge.verifyHwAddress(walletId),
      task: () async {
        if (_pendingSignedPsbt == null) {
          _pendingSignedPsbt = await _bridge.signTransactionHw(
            walletId: walletId,
            outputs: specs,
            assetId: asset.assetId,
            feeRate: _feeRate,
            utxos: _spendOutpoints,
          );
          _pendingSignedKey = key;
        }
        final id = await _bridge.broadcastSignedPsbt(
          walletId: walletId,
          psbtBase64: _pendingSignedPsbt!,
        );
        // Only drop the retained PSBT once it is irreversibly on the network.
        _pendingSignedPsbt = null;
        _pendingSignedKey = null;
        return id;
      },
      formatError: _friendlyHwError,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (txid != null) {
      _showSuccess(txid);
    } else if (_pendingSignedPsbt != null) {
      // The device signed but the transaction never reached the network. Say
      // so plainly and keep the PSBT: "Send" now retries the broadcast alone.
      setState(() => _error =
          'The device signed, but broadcasting failed. Your transaction is '
          'not on the network. Press Send again to retry the broadcast — you '
          'will not have to approve on the device again.');
    }
  }

  /// Translate raw FFI/Electrum errors into actionable guidance.
  String _friendlyHwError(String raw) {
    final lower = raw.toLowerCase();
    // Network-level rejection: not a hardware problem, so it is not part of
    // the shared hardware classifier.
    if (lower.contains('witness program') || lower.contains('hash mismatch') ||
        lower.contains('stack size') || lower.contains('script-verify')) {
      return 'The signed transaction was rejected by the network. Make sure '
          'the wallet was imported as native segwit and re-import if needed.';
    }
    return friendlyHwError(raw);
  }

  /// Air-gap signing is Bitcoin-only: it builds a BDK PSBT and moves it by QR,
  /// and there is no Liquid equivalent of that transport. The asset step
  /// already hides Liquid for air-gap wallets and the backend rejects it too;
  /// this is the middle guard, so no route can reach the QR flow with an
  /// asset it cannot carry.
  bool _assertBitcoinOnly(AssetBalance asset) {
    if (asset.ticker == 'BTC') return true;
    setState(() {
      _sending = false;
      _error = 'Air-gap wallets can only send Bitcoin: signing happens over QR '
          'codes, and there is no Liquid equivalent of that flow. To spend '
          'Liquid from a hardware wallet, connect a Blockstream Jade over USB.';
    });
    return false;
  }

  Future<void> _doSendAirgap(List<TxOutputSpec> specs) async {
    final asset = _selectedAsset;
    if (asset != null && !_assertBitcoinOnly(asset)) return;
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final walletId = _walletId;
      final unsignedPsbt = await _bridge.buildUnsignedPsbt(
        walletId: walletId,
        outputs: specs,
        feeRate: _feeRate,
        assetId: asset?.assetId ?? 'BTC',
        utxos: _spendOutpoints,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      _showAirgapSignDialog(walletId, unsignedPsbt);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  void _showAirgapSignDialog(String walletId, String unsignedPsbt) {
    showAppDialog<void>(
      context,
      builder: (ctx) => PsbtHandoffSheet(
        unsignedPsbt: unsignedPsbt,
        onBroadcast: (signedPsbt) =>
            _broadcastFromDialog(ctx, walletId, signedPsbt),
      ),
    );
  }

  /// Multisig outcome: this wallet's key(s) signed, but the policy needs more
  /// signatures. Same export/import surface as the air-gap dialog, with the
  /// quorum charted at the top — nothing was broadcast.
  void _showPartialSignDialog(
      String walletId, String partialPsbt, int have, int? needed) {
    final quorum = needed != null ? '$have of $needed' : '$have';
    showAppDialog<void>(
      context,
      builder: (ctx) => PsbtHandoffSheet(
        unsignedPsbt: partialPsbt,
        title: 'Co-signatures needed',
        progressNote: 'Partially signed — $quorum signatures collected. This '
            'wallet\'s key alone cannot satisfy the spending policy, so '
            'nothing was broadcast.',
        exportEyebrow: 'HAND IT TO YOUR CO-SIGNERS',
        intro: 'Send them this PSBT — by QR, clipboard or file. Each one '
            'loads it under Send › Cosign a transaction, signs, and returns '
            'it.',
        returnEyebrow: 'COLLECT THE SIGNATURES',
        returnLabel: 'Paste each signed copy with the button above, or scan '
            'or load it here. Its signatures join the copy you hand out, and '
            'the chart follows.',
        quorumHave: have,
        quorumNeeded: needed,
        onBroadcast: (signedPsbt) =>
            _broadcastFromDialog(ctx, walletId, signedPsbt),
      ),
    );
  }

  /// Liquid multisig outcome: this wallet signed what it could, and the PSET
  /// now needs the other co-signers.
  void _showLiquidCosignDialog(
      String walletId, String pset, int have, int needed) {
    showAppDialog<void>(
      context,
      builder: (ctx) => PsetHandoffSheet(
        pset: pset,
        have: have,
        needed: needed,
        onBroadcast: (signed) => _broadcastPsetFromDialog(ctx, walletId, signed),
      ),
    );
  }

  Future<void> _broadcastPsetFromDialog(
      BuildContext ctx, String walletId, String signedPset) async {
    Navigator.of(ctx).pop();
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final txid = await _bridge.broadcastPset(walletId, signedPset);
      if (!mounted) return;
      setState(() => _sending = false);
      _showSuccess(txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _broadcastFromDialog(
      BuildContext ctx, String walletId, String signedPsbt) async {
    Navigator.of(ctx).pop();
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final txid = await _bridge.broadcastSignedPsbt(
        walletId: walletId,
        psbtBase64: signedPsbt,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _failedBroadcast = null;
      });
      _showSuccess(txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
          // The signatures are still valid — keep the signed PSBT so the
          // user can retry or export it instead of re-signing from scratch.
          _failedBroadcast = (walletId, signedPsbt);
        });
      }
    }
  }

  /// Retry broadcasting the signed transaction kept from a failed attempt.
  Future<void> _retryBroadcast() async {
    final failed = _failedBroadcast;
    if (failed == null) return;
    final (walletId, signedPsbt) = failed;
    setState(() {
      _error = null;
      _sending = true;
    });
    try {
      final txid = await _bridge.broadcastSignedPsbt(
        walletId: walletId,
        psbtBase64: signedPsbt,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _failedBroadcast = null;
      });
      _showSuccess(txid);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _copyFailedBroadcastPsbt() async {
    final failed = _failedBroadcast;
    if (failed == null) return;
    await Clipboard.setData(ClipboardData(text: failed.$2));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Signed transaction copied'),
      duration: Duration(seconds: 2),
    ));
  }

  void _showSuccess(String txid) {
    // The wallet is stale the instant a broadcast succeeds — balances read
    // wrong and the spent UTXOs could be re-selected on the next send. Kick
    // off a background sync on the shell's footer/bumpSync path; a failure is
    // tolerated (the footer shows the sync state).
    final appState = context.read<AppState>();
    final syncWalletId = appState.activeWalletId;
    if (syncWalletId != null) {
      appState.setSyncState(SyncState.syncing);
      unawaited(_bridge
          .syncWallet(syncWalletId)
          .then(appState.applySyncOutcomes)
          .catchError((Object e) {
        debugPrint('[send] post-broadcast sync failed: $e');
        appState.setSyncState(SyncState.error);
        appState.bumpSync();
      }));
    }

    // Capture before the reset wipes it — the recap needs the preview data.
    final preview = _preview;
    if (preview != null) {
      showTxSuccessDialog(
        context,
        txid: txid,
        preview: preview,
        ticker: _isBtc ? 'BTC' : 'L-BTC',
      );
    } else {
      // No preview available (should not happen) — minimal fallback.
      final phone = AppLayout.isPhone(context);
      showAppDialog<void>(
        context,
        builder: (ctx) => AppDialog(
          title: const Text('Transaction sent'),
          content: SizedBox(
              width: phone ? double.infinity : 480,
              child: CodeBox(value: txid, label: 'TxID')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done')),
          ],
        ),
      );
    }
    _resetWizard();
  }

  // ── build ───────────────────────────────────────────────────────────────────

  static const _stepLabels = ['Type', 'Network', 'Inputs', 'Outputs', 'Fee', 'Review'];

  String get _stepSubtitle => switch (_step) {
        _WizStep.type => 'What do you want to do?',
        _WizStep.asset => 'Bitcoin or Liquid?',
        _WizStep.inputs => 'Choose which coins to spend',
        _WizStep.outputs => 'Who receives, and how much',
        _WizStep.fee => 'Pick a fee rate',
        _WizStep.review => 'Verify everything before signing',
      };

  @override
  Widget build(BuildContext context) {
    // The PSBT mode hosts its own view and skips the send wizard entirely.
    final isPsbt = _kind == _TxKind.cosign;
    // Phone: the Back / Continue row is pinned under the scrolling steps so
    // it stays reachable with the keyboard up; desktop keeps it at the foot
    // of the step. Gaps tighten a notch on the phone too.
    final phone = AppLayout.isPhone(context);
    final pinNav = phone && !isPsbt && _step != _WizStep.type;
    final gap = phone ? AppSpacing.lg : AppSpacing.xl;

    final page = ListView(
          padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
          children: [
            // Phone: the shell's header already says "Send" with the arrow
            // back, so the page title is the step's own question.
            PageHeader(
              title: phone
                  ? switch (_kind) {
                      _TxKind.cosign => _cosignTitle,
                      _ => _stepSubtitle,
                    }
                  : 'Send',
              subtitle: phone
                  ? null
                  : switch (_kind) {
                      _TxKind.cosign =>
                        'Review and sign a partially-signed transaction',
                      _ => _stepSubtitle,
                    },
            ),
            if (context.watch<AppState>().isActiveWalletHardware &&
                context.watch<AppState>().hwWatchOnly) ...[
              WarningBanner(
                title: 'Watch-only mode',
                message: 'This wallet was opened without its device. Browsing '
                    'works offline; connect and unlock the device to sign and '
                    'send.',
                action: SecondaryButton(
                  label: 'Connect',
                  icon: Icons.usb,
                  onPressed: () => _ensureDeviceConnected(),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            if (isPsbt) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: GhostButton(
                  label: '‹ Change transaction type',
                  onPressed: () => setState(() {
                    _kind = null;
                    _step = _WizStep.type;
                  }),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Keyed so leaving and re-entering the mode rebuilds the
              // view rather than carrying a loaded PSBT — and its Sign
              // buttons — across the change.
              CosignView(key: ValueKey(_kind)),
            ] else ...[
              _WizardStepper(
                labels: _stepLabels,
                current: _step.index,
                maxReached: _maxReached,
                onTap: (i) => _goTo(_WizStep.values[i]),
              ),
              SizedBox(height: gap),
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: _step == _WizStep.review ? 1020 : 760),
                  child: AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.standard),
                    switchInCurve: AppMotion.settle,
                    child: Column(
                      key: ValueKey(_step),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ..._stepChildren(),
                        if (_error != null && _step != _WizStep.review) ...[
                          const SizedBox(height: AppSpacing.lg),
                          DangerBanner(message: _error!),
                        ],
                        if (!pinNav) ...[
                          SizedBox(height: gap),
                          _navBar(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        );

    return Scaffold(
      body: PageBackground.flat(
        child: !pinNav
            ? page
            : Column(
                children: [
                  Expanded(child: page),
                  // The pinned row needs a ground and a rule of its own:
                  // without them the steps scroll up until they touch the
                  // Continue button, and the row melts into the shell's
                  // CarouselNav sitting right underneath it. Phone-only —
                  // pinNav is false on every desktop build.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppScheme.of(context).canvas,
                      border: Border(
                        top: BorderSide(color: AppScheme.of(context).edge),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.pagePadding(context),
                        AppSpacing.md,
                        AppSpacing.pagePadding(context),
                        AppSpacing.sm,
                      ),
                      child: _navBar(),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _stepChildren() => switch (_step) {
        _WizStep.type => _typeStep(),
        _WizStep.asset => _assetStep(),
        _WizStep.inputs => _inputsStep(),
        _WizStep.outputs => _outputsStep(),
        _WizStep.fee => _feeStep(),
        _WizStep.review => _reviewStep(),
      };

  Widget _navBar() {
    final isReview = _step == _WizStep.review;
    // Phone: Back stays compact on the left, the primary action takes the
    // rest of the row so it is a full-width thumb target.
    final phone = AppLayout.isPhone(context);
    final Widget primary;
    if (_step == _WizStep.type) {
      primary = const SizedBox.shrink();
    } else if (isReview) {
      // Says what the next screen is: nothing is signed or sent from
      // here, the summary that opens next is where that happens.
      primary = PrimaryButton(
        label: _sending ? 'Preparing…' : _sendButtonLabel,
        icon: Icons.send_rounded,
        isFullWidth: phone,
        onPressed: _canContinue ? _confirm : null,
      );
    } else {
      primary = PrimaryButton(
        label: 'Continue',
        icon: Icons.arrow_forward,
        isFullWidth: phone,
        onPressed: _canContinue ? _next : null,
      );
    }
    return Row(
      children: [
        if (_step != _WizStep.type)
          // Phone: two filled controls of the same height side by side — the
          // inset-grey Back beside the crimson primary. A ghost there is a
          // border-less wash, which loses its edge next to a filled slab.
          // Desktop keeps the ghost it has always had.
          phone
              ? SecondaryButton(
                  label: '‹ Back', onPressed: _sending ? null : _back)
              : GhostButton(label: '‹ Back', onPressed: _sending ? null : _back),
        if (phone && _step != _WizStep.type) ...[
          const SizedBox(width: AppSpacing.md),
          Expanded(child: primary),
        ] else ...[
          const Spacer(),
          primary,
        ],
      ],
    );
  }

  // ── Step 1: type ────────────────────────────────────────────────────────────

  /// What the co-sign mode is called. One name on every wallet and both
  /// chains: it used to be "Import a PSBT" / "Co-sign a PSBT", which named
  /// the Bitcoin artifact on a screen that takes a Liquid PSET just the same
  /// — the chain is asked inside, as the mode's first step.
  String get _cosignTitle => 'Cosign a transaction';

  /// The only two things a multisig wallet can do here: start a transaction
  /// its co-signers will finish, or take one of theirs further. A singlesig
  /// wallet keeps the wording it has always had.
  List<Widget> _typeStep() {
    final multisig = _isMultisigWallet;
    return [
      _BigChoiceCard(
        icon: Icons.send_outlined,
        title: multisig ? 'Create a partial transaction' : 'Standard transaction',
        subtitle: multisig
            ? 'Build the transaction and sign it with this wallet\'s key. It '
                'comes back as a PSBT to hand to your co-signers — nothing is '
                'broadcast until the quorum is met.'
            : 'Build a new transaction: pick coins, add one or more '
                'recipients, set the fee, review and sign.',
        selected: _kind == _TxKind.standard,
        onTap: () => _selectKind(_TxKind.standard),
      ),
      const SizedBox(height: AppSpacing.md),
      _BigChoiceCard(
        icon: Icons.edit_document,
        title: _cosignTitle,
        subtitle: multisig
            ? 'Load a transaction a co-signer started — a Bitcoin PSBT or a '
                'Liquid PSET — inspect it, add your signature, and pass it on '
                'or broadcast once every required signature is in.'
            : 'Paste a partially-signed transaction from a co-signer — a '
                'Bitcoin PSBT or a Liquid PSET — inspect it, add your '
                'signature, and pass it on or broadcast.',
        selected: _kind == _TxKind.cosign,
        onTap: () => _selectKind(_TxKind.cosign),
      ),
    ];
  }

  // ── Step 2: network ─────────────────────────────────────────────────────────

  /// Pick the chain. On Liquid the transaction can carry several assets at
  /// once — the asset is chosen per output row on the Outputs step, so this
  /// step is a plain Bitcoin-vs-Liquid choice.
  List<Widget> _assetStep() {
    if (_loadingAssets) {
      return [const Center(child: CircularProgressIndicator())];
    }
    final s = AppScheme.of(context);
    final btc = _assets.where((a) => a.ticker == 'BTC').firstOrNull;
    final lbtc = _assets.where((a) => a.ticker == 'LBTC').firstOrNull;
    final tokenCount = _liquidSpendable.where((a) => a.ticker != 'LBTC').length;

    void selectNetwork(AssetBalance a) {
      setState(() {
        if (_selectedAsset?.assetId != a.assetId) {
          // Chain changed: coin selection, output assets, and previews no
          // longer apply — start the recipient list fresh.
          _manualInputs = false;
          for (final i in List.generate(_utxos.length, (i) => i)) {
            _utxos[i] = _utxos[i].copyWith(isSelected: false);
          }
          _preview = null;
          for (final o in _outputs) {
            o.dispose();
          }
          _outputs
            ..clear()
            ..add(_OutputDraft());
        }
        _selectedAsset = a;
      });
    }

    final cards = <Widget>[
      if (btc != null)
        _BigChoiceCard(
          leading: const AssetLogo(ticker: 'BTC', size: 28),
          title: 'Bitcoin',
          subtitle: btc.displayAmount,
          selected: _selectedAsset?.assetId == btc.assetId,
          onTap: () => selectNetwork(btc),
        ),
      if (lbtc != null)
        _BigChoiceCard(
          leading: const AssetLogo(ticker: 'LBTC', size: 28),
          title: 'Liquid Network',
          // The backend formats L-BTC amounts with a plain "BTC" suffix;
          // spell the asset out so the two cards can't be confused.
          subtitle: () {
            final amount = lbtc.displayAmount.replaceFirst(
                RegExp(r'\bBTC\b'), 'L-BTC');
            return tokenCount > 0
                ? '$amount · $tokenCount token${tokenCount == 1 ? '' : 's'}'
                : amount;
          }(),
          selected: _selectedAsset?.assetId == lbtc.assetId,
          onTap: () => selectNetwork(lbtc),
        ),
    ];

    return [
      // Side by side on desktop; a phone column is too narrow for two cards
      // (the titles and balances wrapped into three ragged lines), so the
      // cards stack there at full width.
      if (AppLayout.isPhone(context))
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          cards[i],
        ]
      else
        Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.md),
              Expanded(child: cards[i]),
            ],
          ],
        ),
      if (_selectedAsset?.ticker == 'LBTC') ...[
        const SizedBox(height: AppSpacing.lg),
        Text(
          'One Liquid transaction can move L-BTC and tokens together — '
          'pick the asset for each recipient on the Outputs step.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
      ],
    ];
  }

  // ── Step 3: inputs ──────────────────────────────────────────────────────────

  List<Widget> _inputsStep() {
    final s = AppScheme.of(context);
    if (!_isBtc) {
      return [
        _BigChoiceCard(
          icon: Icons.auto_awesome,
          title: 'Automatic selection',
          subtitle: 'On Liquid, coins are selected automatically and stay '
              'confidential — manual coin control applies to Bitcoin only.',
          selected: true,
          onTap: () {},
        ),
      ];
    }

    return [
      _BigChoiceCard(
        icon: Icons.auto_awesome,
        title: 'Automatic',
        badge: 'Easiest',
        subtitle: 'Let the wallet pick the best coins for this payment.',
        selected: !_manualInputs,
        onTap: () => setState(() => _manualInputs = false),
      ),
      const SizedBox(height: AppSpacing.md),
      _BigChoiceCard(
        icon: Icons.tune,
        title: 'Manual coin control',
        badge: 'Safest',
        subtitle: 'Choose exactly which UTXOs this transaction spends.',
        selected: _manualInputs,
        onTap: () {
          setState(() => _manualInputs = true);
          if (_utxos.isEmpty) _loadUtxos();
        },
      ),
      if (_manualInputs) ...[
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Your coins',
          subtitle: 'Tap to select the inputs to spend',
          child: _loadingUtxos
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                )
              : _utxos.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text('No spendable coins found',
                          style: AppTypography.caption),
                    )
                  : UtxoPicker(
                      utxos: _utxos,
                      // Phone: no inner scroll region — the page scrolls and
                      // the coin list takes the height it needs.
                      maxHeight: AppLayout.isPhone(context)
                          ? double.infinity
                          : 420,
                      onToggle: (i) {
                        if (_utxos[i].isFrozen) return;
                        setState(() => _utxos[i] = _utxos[i]
                            .copyWith(isSelected: !_utxos[i].isSelected));
                      },
                    ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          // Phone: this is a stat strip, not a card — it sits on the inset
          // grey like every other small phone surface instead of drawing a
          // hairline box around two figures. Desktop keeps the outlined card.
          decoration: AppLayout.isPhone(context)
              ? BoxDecoration(
                  color: s.panelInset,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                )
              : BoxDecoration(
                  color: s.surfaceSolid,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(color: s.edge),
                ),
          child: Row(
            children: [
              Icon(Icons.account_balance_wallet_outlined,
                  size: 16, color: s.inkSecondary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${_selectedUtxos.length} selected',
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
              ),
              const Spacer(),
              // Phone: the amount takes the rest of the row (Expanded, not
              // Flexible — a loose child would leave the leftover space
              // after itself and drift off the right edge) and wraps
              // instead of overflowing.
              if (AppLayout.isPhone(context))
                Expanded(
                  child: Text(
                    _fmtAmount(_selectedInputTotal),
                    textAlign: TextAlign.end,
                    style: AppTypography.numericSmall
                        .copyWith(fontWeight: FontWeight.w700, color: s.ink),
                  ),
                )
              else
                Text(
                  _fmtAmount(_selectedInputTotal),
                  style: AppTypography.numericSmall
                      .copyWith(fontWeight: FontWeight.w700, color: s.ink),
                ),
            ],
          ),
        ),
      ],
    ];
  }

  // ── Step 4: outputs ─────────────────────────────────────────────────────────

  /// Toggle MAX on a row — engaging and disengaging both work, for tokens as
  /// well as BTC/L-BTC. Disengaging restores the amount that MAX replaced.
  void _toggleMax(int i) {
    final o = _outputs[i];
    setState(() {
      if (o.maxEngaged) {
        _clearMax(o);
        return;
      }
      if (_rowIsBtcLike(o)) {
        // Only one row can drain the wallet: a second would have nothing left
        // to take. Disengaging the others restores their amounts.
        for (final other in _outputs) {
          if (!identical(other, o) && other.maxEngaged && _rowIsBtcLike(other)) {
            _clearMax(other);
          }
        }
      }
      o.amountBeforeMax = o.amountCtrl.text;
      o.maxEngaged = true;
      if (_rowIsBtcLike(o)) {
        // Drain: the backend resolves the amount once it knows the fee.
        o.sendMax = true;
        o.amountCtrl.clear();
      } else {
        // The fee is paid in L-BTC, so a token MAX is just the whole balance —
        // a number we can show right now.
        o.sendMax = false;
        o.amountCtrl.text = '${_rowAsset(o)?.amount ?? 0}';
      }
    });
  }

  /// Disengage MAX on a row and put back whatever it replaced. Call inside a
  /// [setState]; it only mutates.
  void _clearMax(_OutputDraft o) {
    o.maxEngaged = false;
    o.sendMax = false;
    o.amountCtrl.text = o.amountBeforeMax ?? '';
    o.amountBeforeMax = null;
  }

  /// Fill a row's address with one of this wallet's own — a fresh one or a
  /// previously used one (handy when steering change to yourself).
  Future<void> _useMyAddress(int i, {required bool fresh}) async {
    final asset = _isBtc ? 'BTC' : 'LBTC';
    try {
      if (fresh) {
        final info = await _bridge.generateReceiveAddress(_walletId, asset);
        if (!mounted) return;
        setState(() => _outputs[i].addressCtrl.text = info.address);
      } else {
        final list = await _bridge.listPreviousAddresses(_walletId, asset);
        if (!mounted) return;
        final chosen = await _pickUsedAddress(list);
        if (chosen != null && mounted) {
          setState(() => _outputs[i].addressCtrl.text = chosen);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<String?> _pickUsedAddress(List<AddressInfo> addresses) {
    final phone = AppLayout.isPhone(context);
    return showAppDialog<String>(
      context,
      builder: (ctx) => AppDialog(
        title: const Text('Choose one of your addresses'),
        content: SizedBox(
          width: phone ? double.infinity : 480,
          child: addresses.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text('No previously used addresses.'),
                )
              : phone
                  // The sheet already scrolls; a nested list would fight it.
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final a in addresses)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Text('#${a.index}',
                                style: AppTypography.caption),
                            title: HexText(a.address, truncate: true),
                            subtitle:
                                a.label != null ? Text(a.label!) : null,
                            onTap: () => Navigator.of(ctx).pop(a.address),
                          ),
                      ],
                    )
                  : ListView.builder(
                  shrinkWrap: true,
                  itemCount: addresses.length,
                  itemBuilder: (_, i) {
                    final a = addresses[i];
                    return ListTile(
                      dense: true,
                      leading: Text('#${a.index}', style: AppTypography.caption),
                      title: HexText(a.address, truncate: true),
                      subtitle: a.label != null ? Text(a.label!) : null,
                      onTap: () => Navigator.of(ctx).pop(a.address),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  /// Fills a row from text that arrived whole — pasted, scanned, or dropped
  /// into the field in one go.
  ///
  /// A `bitcoin:` / `liquidtestnet:` payment link carries the amount beside
  /// the address, so the row takes both and the field is left holding the
  /// address alone: the recipient asked for a figure, and copying it across
  /// by eye is the step that puts a digit in the wrong place. A MAX still
  /// engaged is stood down — an amount was named, so "everything" is no
  /// longer what is being sent.
  void _applyAddressInput(int i, String text) {
    final o = _outputs[i];
    final req = PaymentUri.parse(text);
    setState(() {
      if (req == null) {
        o.addressCtrl.text = text.trim();
        return;
      }
      o.addressCtrl.text = req.address;
      if (req.amountSats case final sats?) {
        _clearMax(o);
        o.fiatInput = false;
        o.amountCtrl.text = AmountUnits.coinText(sats);
      }
    });
  }

  Future<void> _pasteAddress(int i) async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && mounted) {
      _applyAddressInput(i, data!.text!);
    }
  }

  /// Camera scan into a row's address field — the phone strip's version of
  /// [ScanIconButton]. Plain-text QRs (addresses and payment links) come back
  /// as `descriptor`.
  Future<void> _scanAddress(int i) async {
    final outcome = await showUrScannerDialog(
      context,
      expectPsbt: false,
      title: 'Scan recipient address',
    );
    final value = outcome?.descriptor ?? outcome?.psbtBase64;
    if (value == null || value.isEmpty || !mounted) return;
    _applyAddressInput(i, value);
  }

  /// Phone stand-in for the use-my-address popup menu: a sheet with the
  /// same two choices, big enough to tap.
  Future<void> _pickMyAddressSource(int i) async {
    final choice = await showAppDialog<String>(
      context,
      builder: (ctx) {
        final s = AppScheme.of(ctx);
        return AppDialog(
          title: const Text('Use my own address'),
          icon: const Icon(Icons.account_balance_wallet_outlined),
          // Same two choices, same two glyphs — drawn in the phone's list
          // grammar (one card, hairline-separated rows, tinted glyph tile)
          // so a row here means what a row means on Settings and the
          // Dashboard. This sheet is only ever opened from the phone strip.
          content: ListCard(
            children: [
              ListRow(
                icon: Icons.add_circle_outline,
                tint: s.accent,
                title: 'New address (this wallet)',
                onTap: () => Navigator.of(ctx).pop('fresh'),
              ),
              ListRow(
                icon: Icons.history,
                tint: s.inkSecondary,
                title: 'Choose a used address…',
                onTap: () => Navigator.of(ctx).pop('used'),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    await _useMyAddress(i, fresh: choice == 'fresh');
  }

  /// Phone: the address field keeps its whole width for the address and the
  /// actions sit under it as labelled buttons — three 48 dp icon buttons
  /// were eating 144 dp of a 337 dp field, and tooltips do not exist on
  /// touch.
  Widget _addressActionStrip(int i) {
    // Dense: three inline actions under one field. At the phone's full 54 dp
    // slab they wrapped onto two rows and cost ~60 dp per recipient.
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        if (cameraScanSupported)
          SecondaryButton(
            label: 'Scan',
            icon: Icons.qr_code_scanner,
            dense: true,
            onPressed: () => _scanAddress(i),
          ),
        SecondaryButton(
          label: 'Paste',
          icon: Icons.paste,
          dense: true,
          onPressed: () => _pasteAddress(i),
        ),
        SecondaryButton(
          label: 'My address',
          icon: Icons.account_balance_wallet_outlined,
          dense: true,
          onPressed: () => _pickMyAddressSource(i),
        ),
      ],
    );
  }

  /// Address-field suffix: scan QR, paste, use-my-address menu.
  Widget _addressActions(int i) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScanIconButton(
          controller: _outputs[i].addressCtrl,
          title: 'Scan recipient address',
          onScanned: (_) => setState(() {}),
        ),
        IconButton(
          icon: const Icon(Icons.paste, size: 18),
          tooltip: 'Paste',
          onPressed: () async {
            final data = await Clipboard.getData('text/plain');
            if (data?.text != null) {
              _outputs[i].addressCtrl.text = data!.text!;
              setState(() {});
            }
          },
        ),
        PopupMenuButton<String>(
          tooltip: 'Use my own address',
          icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
          onSelected: (v) => _useMyAddress(i, fresh: v == 'fresh'),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'fresh', child: Text('New address (this wallet)')),
            PopupMenuItem(value: 'used', child: Text('Choose a used address…')),
          ],
        ),
      ],
    );
  }

  /// A "Total BTC" figure: the coin amount; tokens are their base units.
  String _totalCoinText(String ticker, int amount) =>
      (ticker == 'BTC' || ticker == 'LBTC')
          ? '${AmountUnits.coinText(amount)} $ticker'
          : '$amount $ticker';

  /// The fiat reading of a BTC/L-BTC total, when a price is known.
  String? _totalFiatText(String ticker, int amount) {
    if (ticker != 'BTC' && ticker != 'LBTC') return null;
    final price = PriceService.instance;
    if (!price.hasPrice) return null;
    return '≈ ${price.symbol}${AmountUnits.fiatText(amount, price.btcPrice)}';
  }

  List<Widget> _outputsStep() {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final insufficient = _isBtc &&
        _manualInputs &&
        !_hasMaxOutput &&
        _outputsTotal > 0 &&
        _outputsTotal > _selectedInputTotal;
    final totals = _totalsByTicker;

    return [
      for (var i = 0; i < _outputs.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: FormCard(
            title: _outputs.length == 1 ? 'Recipient' : 'Recipient ${i + 1}',
            trailing: _outputs.length > 1
                ? IconButton(
                    icon: Icon(Icons.close, size: 18, color: s.inkSecondary),
                    tooltip: 'Remove output',
                    onPressed: () => setState(() {
                      _outputs[i].dispose();
                      _outputs.removeAt(i);
                    }),
                  )
                : null,
            child: Column(
              children: [
                // Per-output asset — Liquid only: one tx can pay L-BTC and
                // tokens to different recipients at once.
                if (!_isBtc && _liquidSpendable.length > 1) ...[
                  // Phone: the uppercase micro-label sits above the field
                  // rather than floating inside it — three filled boxes
                  // stacked in one card need captions that stay put, and this
                  // is the same label the Dashboard and Settings put over a
                  // group. Desktop keeps the floating labelText.
                  if (phone) const ListSectionLabel(label: 'Asset'),
                  DropdownButtonFormField<String>(
                    initialValue: _rowAsset(_outputs[i])?.assetId,
                    decoration: phone
                        ? const InputDecoration(hintText: 'Choose asset')
                        : const InputDecoration(labelText: 'Asset'),
                    // Phone: the value fills the field and a long ticker +
                    // amount ellipsises instead of overflowing.
                    isExpanded: phone,
                    items: [
                      for (final a in _liquidSpendable)
                        DropdownMenuItem(
                          value: a.assetId,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AssetLogo(ticker: a.ticker, size: 18),
                              const SizedBox(width: AppSpacing.sm),
                              if (phone)
                                Flexible(
                                  child: Text(
                                    a.ticker == 'LBTC'
                                        ? 'L-BTC'
                                        : AssetRegistryService.instance
                                            .displayTicker(a),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                )
                              else
                                Text(a.ticker == 'LBTC'
                                    ? 'L-BTC'
                                    : AssetRegistryService.instance
                                        .displayTicker(a)),
                              const SizedBox(width: AppSpacing.sm),
                              if (phone)
                                Flexible(
                                  child: Text(a.displayAmount,
                                      style: AppTypography.caption,
                                      overflow: TextOverflow.ellipsis),
                                )
                              else
                                Text(a.displayAmount,
                                    style: AppTypography.caption),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (id) => setState(() {
                      _outputs[i].asset = _liquidSpendable
                          .where((a) => a.assetId == id)
                          .firstOrNull;
                      // Units changed meaning — old amount no longer applies.
                      _clearMax(_outputs[i]);
                      _outputs[i].fiatInput = false;
                      _outputs[i].amountCtrl.clear();
                    }),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (phone) const ListSectionLabel(label: 'Address'),
                TextField(
                  controller: _outputs[i].addressCtrl,
                  style: AppTypography.mono,
                  // An address is not prose: no autocorrect, no suggestions,
                  // no capitalisation — a "corrected" bech32 string is a
                  // different address. No-ops on desktop.
                  keyboardType: TextInputType.visiblePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  // Phone: let the whole address show, wrapped, so it can
                  // be checked in place; Enter never inserts a newline.
                  maxLines: phone ? null : 1,
                  textInputAction: phone ? TextInputAction.done : null,
                  inputFormatters: phone
                      ? [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]'))]
                      : null,
                  decoration: InputDecoration(
                    hintText: 'Enter, paste, or scan address',
                    suffixIcon: phone ? null : _addressActions(i),
                  ),
                  // A payment link pasted straight into the field (⌘V on the
                  // desktop never goes through the paste button) resolves to
                  // address + amount on the spot. Setting the controller
                  // does not re-enter onChanged, so this runs once: after it
                  // the field holds a bare address and the branch is dead.
                  onChanged: (v) => PaymentUri.isPaymentUri(v)
                      ? _applyAddressInput(i, v)
                      : setState(() {}),
                ),
                if (phone) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _addressActionStrip(i),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                if (phone) const ListSectionLabel(label: 'Amount'),
                TextField(
                  controller: _outputs[i].amountCtrl,
                  // MAX owns the field while engaged — tap it again to edit.
                  enabled: !_outputs[i].maxEngaged,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: AppTypography.numeric,
                  decoration: InputDecoration(
                    hintText: _outputs[i].sendMax
                        ? 'Everything after the fee'
                        : _outputs[i].fiatInput
                            ? '0.00'
                            : (_rowIsBtcLike(_outputs[i])
                                ? '0.00000000'
                                : '0'),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MaxToggle(
                          engaged: _outputs[i].maxEngaged,
                          onTap: () => _toggleMax(i),
                        ),
                        // The unit — and, on a BTC/L-BTC row with a price,
                        // the ⇅ that flips the field to fiat and back.
                        UnitChip(
                          label: _outputs[i].fiatInput
                              ? PriceService.instance.currency
                              : _rowTicker(_outputs[i]),
                          other: _canToggleFiat(_outputs[i])
                              ? (_outputs[i].fiatInput
                                  ? _rowTicker(_outputs[i])
                                  : PriceService.instance.currency)
                              : null,
                          onTap: _canToggleFiat(_outputs[i])
                              ? () => _toggleFiat(i)
                              : null,
                        ),
                      ],
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (_equivalentText(_outputs[i]) case final approx?) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      approx,
                      style: AppTypography.numericSmall.copyWith(
                        fontSize: 13,
                        color: s.inkSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: SecondaryButton(
          label: 'Add output',
          icon: Icons.add,
          onPressed: () => setState(() => _outputs.add(_OutputDraft())),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      for (final entry in totals.entries)
        Row(
          children: [
            Text('Total ${entry.key}',
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
            const Spacer(),
            if (phone)
              // Coin on one line, the fiat reading under it: side by side
              // they wrapped at "· ≈" on a phone column.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _totalCoinText(entry.key, entry.value),
                      textAlign: TextAlign.end,
                      style: AppTypography.numericSmall
                          .copyWith(fontWeight: FontWeight.w700, color: s.ink),
                    ),
                    if (_totalFiatText(entry.key, entry.value)
                        case final fiat?)
                      Text(
                        fiat,
                        textAlign: TextAlign.end,
                        style: AppTypography.caption
                            .copyWith(color: s.inkSecondary),
                      ),
                  ],
                ),
              )
            else
              Text(
                switch (_totalFiatText(entry.key, entry.value)) {
                  final fiat? =>
                    '${_totalCoinText(entry.key, entry.value)} · $fiat',
                  null => _totalCoinText(entry.key, entry.value),
                },
                style: AppTypography.numericSmall
                    .copyWith(fontWeight: FontWeight.w700, color: s.ink),
              ),
          ],
        ),
      if (_hasMaxOutput)
        Row(
          children: [
            Text('MAX output',
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
            const Spacer(),
            Text('resolved at review',
                style: AppTypography.caption.copyWith(color: s.inkFaint)),
          ],
        ),
      if (insufficient) ...[
        const SizedBox(height: AppSpacing.md),
        WarningBanner(
          title: 'Selected inputs may not cover this',
          message:
              'Outputs total ${_fmtAmount(_outputsTotal)} but the selected '
              'coins hold ${_fmtAmount(_selectedInputTotal)} (fee comes on '
              'top). Go back and select more coins, or lower the amounts.',
        ),
      ],
    ];
  }

  // ── Step 5: fee ─────────────────────────────────────────────────────────────

  List<Widget> _feeStep() {
    final s = AppScheme.of(context);
    if (!_isBtc) {
      return [
        FormCard(
          title: 'Network fee',
          subtitle: 'Liquid uses a flat minimal fee — nothing to configure.',
          child: Row(
            children: [
              Icon(Icons.water_drop_outlined, size: 18, color: s.liquid),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Flat fee (~0.1 sat/vB), deducted automatically.',
                  style:
                      AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                ),
              ),
            ],
          ),
        ),
      ];
    }

    final estVsize = 110 + 68 * math.max(1, _manualInputs ? _selectedUtxos.length : 1) +
        31 * _outputs.length;
    return [
      FormCard(
        title: 'Fee rate',
        subtitle: 'Times are network estimates — actual confirmation varies.',
        child: _FeeSelector(
          selected: _feePreset,
          customController: _customFeeCtrl,
          onSelect: (f) => setState(() => _feePreset = f),
          onCustomChanged: () => setState(() {}),
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      if (AppLayout.isPhone(context))
        // Label above value: the one-liner is a hair too long for the
        // narrower Android widths once a custom rate is typed.
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rough forecast',
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
            const SizedBox(height: 2),
            Text(
              '≈${(_feeRate * estVsize).round()} sats '
              '(${_feeRate.toStringAsFixed(1)} sat/vB × ~$estVsize vB)',
              style: AppTypography.numericSmall.copyWith(color: s.ink),
            ),
          ],
        )
      else
        Row(
          children: [
            Text('Rough forecast',
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
            const Spacer(),
            Text(
              '≈${(_feeRate * estVsize).round()} sats '
              '(${_feeRate.toStringAsFixed(1)} sat/vB × ~$estVsize vB)',
              style: AppTypography.numericSmall.copyWith(color: s.ink),
            ),
          ],
        ),
      Text(
        'The exact fee is computed at the review step.',
        style: AppTypography.caption.copyWith(color: s.inkFaint),
      ),
    ];
  }

  // ── Step 6: review ──────────────────────────────────────────────────────────

  List<Widget> _reviewStep() {
    final s = AppScheme.of(context);
    if (_previewing) {
      return [
        Padding(
          padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
          child: const Center(child: CircularProgressIndicator()),
        ),
        Center(
          child: Text('Building transaction…',
              style: AppTypography.caption.copyWith(color: s.inkSecondary)),
        ),
      ];
    }
    if (_error != null) {
      // A broadcast failure after signing is recoverable without re-signing:
      // the signed PSBT was retained, so offer retry/export instead of the
      // plain rebuild-preview retry.
      if (_failedBroadcast != null) {
        return [
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'The transaction is signed — only the broadcast failed. Your '
            'signatures were kept: retry when the network is reachable, or '
            'copy the signed transaction and broadcast it elsewhere.',
            style: AppTypography.caption.copyWith(color: s.inkSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          if (AppLayout.isPhone(context)) ...[
            // Two wide buttons do not share a 379 dp row: stack them.
            PrimaryButton(
              label: _sending ? 'Broadcasting…' : 'Retry broadcast',
              icon: Icons.refresh,
              isFullWidth: true,
              onPressed: _sending ? null : _retryBroadcast,
            ),
            const SizedBox(height: AppSpacing.sm),
            SecondaryButton(
              label: 'Copy signed transaction',
              icon: Icons.copy,
              isFullWidth: true,
              onPressed: _copyFailedBroadcastPsbt,
            ),
          ] else
            Row(
              children: [
                PrimaryButton(
                  label: _sending ? 'Broadcasting…' : 'Retry broadcast',
                  icon: Icons.refresh,
                  onPressed: _sending ? null : _retryBroadcast,
                ),
                const SizedBox(width: AppSpacing.md),
                SecondaryButton(
                  label: 'Copy signed transaction',
                  icon: Icons.copy,
                  onPressed: _copyFailedBroadcastPsbt,
                ),
              ],
            ),
        ];
      }
      return [
        DangerBanner(message: _error!),
        const SizedBox(height: AppSpacing.lg),
        Align(
          alignment: Alignment.centerLeft,
          child: SecondaryButton(
            label: 'Retry',
            icon: Icons.refresh,
            onPressed: _buildPreview,
          ),
        ),
      ];
    }
    final preview = _preview;
    if (preview == null) return [const SizedBox.shrink()];

    return [
      _TxDiagram(
        preview: preview,
        isBtcLike: _isBtcLike,
        ticker: _selectedAsset?.ticker ?? 'BTC',
      ),
      const SizedBox(height: AppSpacing.xl),
      _FeeForecastPanel(preview: preview, isBtc: _isBtc),
      const SizedBox(height: AppSpacing.lg),
      Text(
        'Verify each recipient address — character by character for '
        'high-value sends. "Send" opens a final summary; nothing is signed '
        'until you confirm there.',
        style: AppTypography.caption.copyWith(color: s.inkSecondary),
      ),
    ];
  }
}

// ── Wizard stepper header ─────────────────────────────────────────────────────

/// Step rail for the send wizard.
///
/// Layout note: the connector must line up with the CENTRE OF THE DOTS, not
/// with the centre of the dot+label column — an `Expanded` sibling of the whole
/// column centres itself against the label too and lands visibly low. The rail
/// is therefore top-aligned and offset by exactly half the dot.
class _WizardStepper extends StatelessWidget {
  const _WizardStepper({
    required this.labels,
    required this.current,
    required this.maxReached,
    required this.onTap,
  });

  final List<String> labels;
  final int current;
  final int maxReached;
  final void Function(int) onTap;

  /// Diameter of a step dot. The rail offset is derived from it.
  static const double _dot = 28;

  /// Rail thickness.
  static const double _rail = 2;

  /// Phone: a dot, not a small numbered circle. Six numbered rings joined by
  /// rails was the desktop rail shrunk down; here the dots are only
  /// wayfinding and the step name under them does the talking. Each dot
  /// still sits in a 48 dp-tall touch slot, so a passed step is tappable.
  static const double _dotCompact = 8;

  /// The dot of the step you are on — a touch bigger, so "where am I" is
  /// answerable without reading the line below.
  static const double _dotCompactCurrent = 10;

  @override
  Widget build(BuildContext context) {
    if (AppLayout.isPhone(context)) return _buildCompact(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: (_dot - _rail) / 2,
                  left: AppSpacing.xs,
                  right: AppSpacing.xs,
                ),
                child: _StepRail(filled: i <= current, thickness: _rail),
              ),
            ),
          _StepDot(
            index: i,
            label: labels[i],
            size: _dot,
            active: i == current,
            done: i < current,
            clickable: i <= maxReached && i != current,
            onTap: () => onTap(i),
          ),
        ],
      ],
    );
  }

  /// Phone: small dots and the step's name.
  ///
  /// No numerals, no connecting rails: a 2 px rail between 8 dp dots is noise,
  /// and stretching six dots edge to edge across the column is exactly what
  /// made the header read as a desktop widget scaled down. The dots are a
  /// left-aligned rail at a fixed pitch (each in its own touch slot, so
  /// tapping a passed dot still jumps back to it) and the line underneath
  /// carries the wayfinding: a quiet counter, then the step name loud.
  Widget _buildCompact(BuildContext context) {
    final s = AppScheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              _StepDot(
                index: i,
                label: labels[i],
                size: i == current ? _dotCompactCurrent : _dotCompact,
                active: i == current,
                done: i < current,
                clickable: i <= maxReached && i != current,
                onTap: () => onTap(i),
                compact: true,
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            // The same uppercase micro-label the rest of the phone puts over
            // a group — the counter is the quiet half of this line.
            Text(
              'Step ${current + 1} of ${labels.length}'.toUpperCase(),
              style: AppTypography.navSection.copyWith(
                color: s.inkFaint,
                letterSpacing: 1.3,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                labels[current],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.stepIndicator.copyWith(
                  color: s.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// One connector between two dots: a static track with an accent fill that
/// sweeps across as the step is passed, rather than snapping colour.
class _StepRail extends StatelessWidget {
  const _StepRail({required this.filled, required this.thickness});

  final bool filled;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return SizedBox(
      height: thickness,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: s.edge,
              borderRadius: BorderRadius.circular(thickness),
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: filled ? 1 : 0),
            duration: AppMotion.of(context, AppMotion.emphasized),
            curve: AppMotion.settle,
            builder: (context, t, _) => Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: t.clamp(0.0, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: s.accent,
                    borderRadius: BorderRadius.circular(thickness),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepDot extends StatefulWidget {
  const _StepDot({
    required this.index,
    required this.label,
    required this.size,
    required this.active,
    required this.done,
    required this.clickable,
    required this.onTap,
    this.compact = false,
  });

  final int index;
  final String label;
  final double size;
  final bool active;
  final bool done;
  final bool clickable;
  final VoidCallback onTap;

  /// Phone form: the dot alone inside a 48 dp touch slot, no label.
  final bool compact;

  @override
  State<_StepDot> createState() => _StepDotState();
}

class _StepDotState extends State<_StepDot> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final reached = widget.active || widget.done;
    if (widget.compact) {
      // Phone: a dot, and nothing else. No numeral, no check glyph, no ring —
      // the fill alone says passed / here / not yet, and the
      // AnimatedContainer still animates that fill (and the current dot's
      // extra 2 dp) as the step changes.
      return Semantics(
        // The numeral used to be the dot's only spoken content; without it
        // the step name has to be said here, or the rail is six unlabelled
        // targets to a screen reader.
        button: widget.clickable,
        selected: widget.active,
        label: 'Step ${widget.index + 1}: ${widget.label}',
        excludeSemantics: true,
        child: GestureDetector(
          onTap: widget.clickable ? widget.onTap : null,
          behavior: HitTestBehavior.opaque,
          // The dot is pinned to the left of its slot so the rail starts
          // flush with the page's text; the rest of the 32 x 48 slot is touch
          // area, which is what keeps an 8 dp dot tappable back to a passed
          // step.
          child: SizedBox(
            width: 32,
            height: AppLayout.minTouchTarget,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: AppMotion.of(context, AppMotion.quick),
                curve: AppMotion.settle,
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.active
                      ? s.accent
                      : widget.done
                          ? s.accent.withValues(alpha: 0.45)
                          : s.panelInset,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final ring = reached
        ? s.accent
        : _hover
            ? s.accent.withValues(alpha: 0.55)
            : s.edgeStrong;

    final dot = AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.settle,
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.active
            ? s.accent
            : widget.done
                ? s.accentSoft
                : Colors.transparent,
        border: Border.all(
          color: ring,
          width: widget.active ? 0 : 1.4,
        ),
      ),
      child: Center(
        child: widget.done
            ? Icon(Icons.check_rounded, size: 15, color: s.accent)
            : Text(
                '${widget.index + 1}',
                style: AppTypography.numericSmall.copyWith(
                  color: widget.active
                      ? Colors.white
                      : _hover
                          ? s.accent
                          : s.inkSecondary,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
              ),
      ),
    );

    return MouseRegion(
      cursor: widget.clickable
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (widget.clickable) setState(() => _hover = true);
      },
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.clickable ? widget.onTap : null,
        // Labels vary in width; a fixed slot keeps the rails between dots
        // even instead of stretching around the longest word.
        child: SizedBox(
          width: 78,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              dot,
              const SizedBox(height: AppSpacing.sm),
              Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                // 12px, not 10.5 — these are the only wayfinding in the flow
                // and were being read as decoration rather than labels.
                style: AppTypography.caption.copyWith(
                  fontSize: 12,
                  height: 1.2,
                  color: reached ? s.ink : s.inkSecondary,
                  fontWeight: widget.active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── MAX toggle ────────────────────────────────────────────────────────────────

/// The MAX affordance on an amount field. A real two-state toggle: crimson
/// while engaged, quiet while not (a hairline outline on desktop, the inset
/// grey on a phone), so "is MAX on?" is answerable at a glance and tapping
/// again always turns it back off.
class _MaxToggle extends StatefulWidget {
  const _MaxToggle({required this.engaged, required this.onTap});

  final bool engaged;
  final VoidCallback onTap;

  @override
  State<_MaxToggle> createState() => _MaxToggleState();
}

class _MaxToggleState extends State<_MaxToggle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final on = widget.engaged;
    final border = on
        ? s.accent
        : _hover
            ? s.accent.withValues(alpha: 0.6)
            : s.edgeStrong;
    final phone = AppLayout.isPhone(context);
    final chip = AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.quick),
            // Phone: no margin — the chip already sits inside its own 48 dp
            // slot below, and the vertical margin only inflated the field's
            // suffix and pushed the amount box past 70 dp.
            margin: phone
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            padding: EdgeInsets.symmetric(
                horizontal: phone ? AppSpacing.md : AppSpacing.sm,
                vertical: phone ? 7 : 5),
            // Phone: off is a filled inset-grey chip, like every other small
            // control on the phone, rather than an outlined ghost; on stays
            // the crimson fill. Desktop keeps the hairline two-state chip.
            decoration: phone
                ? BoxDecoration(
                    color: on ? s.accent : s.panelInset,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  )
                : BoxDecoration(
                    color: on ? s.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    border: Border.all(color: border, width: 1),
                  ),
            child: Text(
              'MAX',
              style: AppTypography.label.copyWith(
                color: on
                    ? Colors.white
                    : _hover
                        ? s.accent
                        : s.inkSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                height: 1.0,
              ),
            ),
          );
    if (phone) {
      // Touch: the whole 48 dp slot taps, not just the 23 dp chip, and the
      // hover states are simply never entered.
      return GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: AppLayout.minTouchTarget,
            minHeight: AppLayout.minTouchTarget,
          ),
          child: Center(child: chip),
        ),
      );
    }
    return Tooltip(
      message: on ? 'MAX on — tap to edit the amount' : 'Send the whole balance',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: chip,
        ),
      ),
    );
  }
}

// ── Big selectable choice card ────────────────────────────────────────────────

class _BigChoiceCard extends StatelessWidget {
  const _BigChoiceCard({
    this.icon,
    this.leading,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  /// Optional qualifier chip, drawn beside the title. Same wording and styling
  /// as the wallet-setup cards: "Easiest" / "Safest", never "Recommended" —
  /// the trade-off is named, so the user picks on their own terms.
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    // Phone: the softer card corner the rest of the phone uses, and a 1.5 px
    // selected ring — a 2 px ring reads heavy against a 14 radius. Three of
    // these stack on the Type step, so the padding tightens a notch too.
    final radius = phone ? AppSpacing.radiusLg : AppSpacing.radiusMd;
    final card = AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.quick),
        curve: AppMotion.settle,
        padding: EdgeInsets.all(
            phone ? AppSpacing.cardPaddingSmall : AppSpacing.lg),
        decoration: BoxDecoration(
          color: selected ? s.accentSoft : (phone ? s.panel : s.surfaceSolid),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: selected ? s.accent : s.edge,
            width: selected ? (phone ? 1.5 : 2) : 1,
          ),
        ),
        child: Row(
          children: [
            leading ??
                Icon(icon, size: 26, color: selected ? s.accent : s.inkSecondary),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: AppTypography.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: selected ? s.accent : s.ink,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.warningLight,
                            borderRadius:
                                BorderRadius.circular(AppSpacing.radiusSm),
                          ),
                          child: Text(badge!,
                              style: AppTypography.label
                                  .copyWith(color: AppColors.warning)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style:
                        AppTypography.caption.copyWith(color: s.inkSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? s.accent : s.inkFaint,
            ),
          ],
        ),
      );
    if (phone) {
      // The card's fill is opaque, so an InkWell underneath it never shows
      // its ripple; on touch the ripple is painted over the card instead.
      return Stack(
        children: [
          card,
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
              ),
            ),
          ),
        ],
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: card,
    );
  }
}

// ── Fee selector (presets + custom sat/vB) ────────────────────────────────────

class _FeeSelector extends StatelessWidget {
  const _FeeSelector({
    required this.selected,
    required this.onSelect,
    required this.customController,
    required this.onCustomChanged,
  });
  final String selected;
  final void Function(String) onSelect;
  final TextEditingController customController;
  final VoidCallback onCustomChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final presets = [
      ('slow', 'Slow', '~60 min', '1 sat/vB'),
      ('normal', 'Normal', '~30 min', '3 sat/vB'),
      ('fast', 'Fast', '~10 min', '8 sat/vB'),
      ('custom', 'Custom', 'your rate', 'sat/vB'),
    ];
    final phone = AppLayout.isPhone(context);

    Widget tile((String, String, String, String) p) {
      final (id, label, time, rate) = p;
      final isActive = id == selected;
      return InkWell(
        onTap: () => onSelect(id),
        borderRadius: BorderRadius.circular(
            phone ? AppSpacing.radiusLg : AppSpacing.radiusSm),
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.quick),
          curve: AppMotion.settle,
          padding: const EdgeInsets.all(AppSpacing.md),
          constraints: phone
              ? const BoxConstraints(minHeight: AppLayout.minTouchTarget)
              : null,
          // Phone: four filled inset-grey cells with the chosen one lit —
          // the same segmented grammar the phone uses everywhere else. Four
          // empty hairline boxes on the page ground was the desktop row
          // wrapped into a grid, not a phone control.
          decoration: phone
              ? BoxDecoration(
                  color: isActive ? s.accentSoft : s.panelInset,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                  // The unlit cell's ring is its own fill: invisible, but it
                  // keeps the inner width constant so the captions do not
                  // re-wrap as the selection moves between cells.
                  border: Border.all(
                    color: isActive ? s.accent : s.panelInset,
                    width: 1.5,
                  ),
                )
              : BoxDecoration(
                  color: isActive ? s.accentSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  border: Border.all(
                    color: isActive ? s.accent : s.edge,
                    width: isActive ? 2 : 1,
                  ),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTypography.label.copyWith(
                  color: isActive ? s.accent : s.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(time,
                  style: AppTypography.caption
                      .copyWith(color: s.inkSecondary)),
              Text(
                rate,
                style: AppTypography.monoSmall
                    .copyWith(color: s.inkSecondary),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (phone)
          // 2 x 2: four presets across 337 dp left ~50 dp of text each and
          // wrapped every caption at a different height.
          LayoutBuilder(
            builder: (context, constraints) {
              final w = (constraints.maxWidth - AppSpacing.sm) / 2;
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final p in presets)
                    SizedBox(width: w, child: tile(p)),
                ],
              );
            },
          )
        else
          Row(
            children: presets.map((p) {
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: tile(p),
                ),
              );
            }).toList(),
          ),
        if (selected == 'custom') ...[
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: customController,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            style: AppTypography.numeric,
            decoration: const InputDecoration(
              hintText: '3.0',
              suffixText: 'sat/vB',
              helperText: 'Minimum 0.1 sat/vB',
            ),
            onChanged: (_) => onCustomChanged(),
          ),
        ],
      ],
    );
  }
}

// ── Mempool-style transaction diagram ─────────────────────────────────────────

/// Visual role of a diagram block.
enum _BlockKind { input, autoInput, recipient, change, fee }

class _DiagramEntry {
  const _DiagramEntry({
    required this.kind,
    required this.title,
    required this.amountText,
    this.mono = true,
  });
  final _BlockKind kind;
  final String title;
  final String amountText;
  final bool mono;
}

/// Inputs on the left, outputs (incl. change + fee) on the right, curved
/// arrows flowing through a central node — the classic mempool.space layout.
class _TxDiagram extends StatelessWidget {
  const _TxDiagram({
    required this.preview,
    required this.isBtcLike,
    required this.ticker,
  });

  final TxPreview preview;
  final bool isBtcLike;
  final String ticker;

  static const _blockH = 62.0;
  static const _gap = 12.0;

  String _fmt(int sats) {
    if (isBtcLike) return '${(sats / 1e8).toStringAsFixed(8)} $ticker';
    return '$sats $ticker';
  }

  /// Per-output amount: the backend's precision-aware display when present
  /// (Liquid multi-asset), else the transaction-level format.
  String _fmtIo(TxIo io) {
    if (io.amountDisplay != null) return io.amountDisplay!;
    if (io.ticker != null) return '${io.amountSats} ${io.ticker}';
    return _fmt(io.amountSats);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);

    final inputs = preview.inputs.isEmpty
        ? [
            const _DiagramEntry(
              kind: _BlockKind.autoInput,
              title: 'Auto-selected coins',
              amountText: 'confidential',
              mono: false,
            ),
          ]
        : [
            for (final i in preview.inputs)
              _DiagramEntry(
                kind: _BlockKind.input,
                title: i.address,
                amountText: _fmt(i.amountSats),
              ),
          ];

    final outputs = [
      for (final o in preview.outputs)
        _DiagramEntry(
          kind: o.isChange ? _BlockKind.change : _BlockKind.recipient,
          title: o.address,
          amountText: _fmtIo(o),
        ),
      _DiagramEntry(
        kind: _BlockKind.fee,
        title: 'Network fee',
        amountText: preview.feeDisplay,
        mono: false,
      ),
    ];

    if (AppLayout.isPhone(context)) {
      return _buildStacked(context, s, inputs, outputs);
    }

    final rows = math.max(inputs.length, outputs.length);
    final height =
        rows * _blockH + (rows - 1) * _gap + AppSpacing.lg * 2;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TagChip(label: 'Inputs (${inputs.length})', color: s.bitcoin),
              const Spacer(),
              TagChip(
                  label:
                      'Outputs (${preview.outputs.length}) + fee',
                  color: s.accent),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                // Columns share the width with a fixed arrow lane between.
                final laneW = math.min(180.0, math.max(90.0, w * 0.18));
                final colW = (w - laneW) / 2;

                double centerYFor(int i, int count) {
                  final columnH =
                      count * _blockH + (count - 1) * _gap;
                  final top = (height - columnH) / 2;
                  return top + i * (_blockH + _gap) + _blockH / 2;
                }

                return Stack(
                  children: [
                    // Arrows behind the blocks.
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _ArrowPainter(
                          inputYs: [
                            for (var i = 0; i < inputs.length; i++)
                              centerYFor(i, inputs.length)
                          ],
                          outputYs: [
                            for (var i = 0; i < outputs.length; i++)
                              centerYFor(i, outputs.length)
                          ],
                          outputKinds: [for (final o in outputs) o.kind],
                          leftX: colW,
                          rightX: w - colW,
                          centerX: w / 2,
                          centerY: height / 2,
                          scheme: s,
                        ),
                      ),
                    ),
                    // Central tx node.
                    Positioned(
                      left: w / 2 - 17,
                      top: height / 2 - 17,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: s.surfaceSolid,
                          border: Border.all(color: s.accent, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: s.accentGlow,
                              blurRadius: 14,
                            ),
                          ],
                        ),
                        child: Icon(Icons.swap_horiz,
                            size: 18, color: s.accent),
                      ),
                    ),
                    // Input blocks.
                    for (var i = 0; i < inputs.length; i++)
                      Positioned(
                        left: 0,
                        top: centerYFor(i, inputs.length) - _blockH / 2,
                        width: colW,
                        height: _blockH,
                        child: _DiagramBlock(entry: inputs[i]),
                      ),
                    // Output blocks.
                    for (var i = 0; i < outputs.length; i++)
                      Positioned(
                        right: 0,
                        top: centerYFor(i, outputs.length) - _blockH / 2,
                        width: colW,
                        height: _blockH,
                        child: _DiagramBlock(entry: outputs[i]),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Phone form of the diagram: the two columns become two full-width groups
/// (inputs, then outputs + fee) with an arrow between them. At 379 dp the
/// side-by-side blocks showed 7 glyphs of each address, which defeats the
/// "verify each address" instruction under it; here every block has the
/// whole width and the address is readable.
extension on _TxDiagram {
  Widget _buildStacked(
    BuildContext context,
    AppScheme s,
    List<_DiagramEntry> inputs,
    List<_DiagramEntry> outputs,
  ) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPaddingSmall),
      // Phone card: panel ground, hairline, softer corner. Reached only from
      // the isPhone guard in _TxDiagram.build.
      decoration: BoxDecoration(
        color: s.panel,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TagChip(label: 'Inputs (${inputs.length})', color: s.bitcoin),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < inputs.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            _DiagramBlock(entry: inputs[i], wide: true),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: [
                Expanded(child: Divider(color: s.edge, height: 1)),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Inset grey inside the card, with a lighter ring — a
                      // 2 px ring on a 30 dp node read as a control.
                      color: s.panelInset,
                      border: Border.all(color: s.accent, width: 1.5),
                    ),
                    child: Icon(Icons.arrow_downward_rounded,
                        size: 16, color: s.accent),
                  ),
                ),
                Expanded(child: Divider(color: s.edge, height: 1)),
              ],
            ),
          ),
          TagChip(
              label: 'Outputs (${preview.outputs.length}) + fee',
              color: s.accent),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < outputs.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            _DiagramBlock(entry: outputs[i], wide: true),
          ],
        ],
      ),
    );
  }
}

class _DiagramBlock extends StatelessWidget {
  const _DiagramBlock({required this.entry, this.wide = false});
  final _DiagramEntry entry;

  /// Full-width phone block: readable type, the address wraps instead of
  /// hiding behind a hover tooltip, and no fixed height.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final (color, chip) = switch (entry.kind) {
      _BlockKind.input => (s.bitcoin, 'IN'),
      _BlockKind.autoInput => (s.liquid, 'AUTO'),
      _BlockKind.recipient => (s.accent, 'OUT'),
      _BlockKind.change => (s.inkSecondary, 'CHANGE'),
      _BlockKind.fee => (s.warning, 'FEE'),
    };

    if (wide) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
              color.withValues(alpha: s.isDark ? 0.10 : 0.06),
              s.surfaceSolid),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(color: color.withValues(alpha: 0.65), width: 1.4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TagChip(label: chip, color: color),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    entry.amountText,
                    textAlign: TextAlign.end,
                    style: AppTypography.numericSmall.copyWith(
                      color: s.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            entry.mono
                ? HexText(
                    entry.title,
                    style: AppTypography.monoSmall.copyWith(color: s.ink),
                  )
                : Text(
                    entry.title,
                    style: AppTypography.caption.copyWith(color: s.ink),
                  ),
          ],
        ),
      );
    }

    return Tooltip(
      message: entry.title,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
              color.withValues(alpha: s.isDark ? 0.10 : 0.06), s.surfaceSolid),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(
            color: color.withValues(alpha: 0.65),
            width: 1.4,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    chip,
                    style: AppTypography.caption.copyWith(
                      color: color,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: entry.mono
                      // Sparrow-style endpoint highlighting on addresses.
                      ? HexText(
                          entry.title,
                          truncate: true,
                          style: AppTypography.monoSmall
                              .copyWith(color: s.ink, fontSize: 10.5),
                        )
                      : Text(
                          entry.title,
                          style: AppTypography.caption
                              .copyWith(color: s.ink, fontSize: 10.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              entry.amountText,
              style: AppTypography.numericSmall.copyWith(
                color: s.ink,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the flow curves: inputs converge into the central node, outputs
/// fan out of it, with small arrowheads on the output side.
class _ArrowPainter extends CustomPainter {
  _ArrowPainter({
    required this.inputYs,
    required this.outputYs,
    required this.outputKinds,
    required this.leftX,
    required this.rightX,
    required this.centerX,
    required this.centerY,
    required this.scheme,
  });

  final List<double> inputYs;
  final List<double> outputYs;
  final List<_BlockKind> outputKinds;
  final double leftX;
  final double rightX;
  final double centerX;
  final double centerY;
  final AppScheme scheme;

  Color _colorFor(_BlockKind kind) => switch (kind) {
        _BlockKind.input || _BlockKind.autoInput => scheme.bitcoin,
        _BlockKind.recipient => scheme.accent,
        _BlockKind.change => scheme.inkSecondary,
        _BlockKind.fee => scheme.warning,
      };

  @override
  void paint(Canvas canvas, Size size) {
    // Input side — one curve per input into the node.
    for (final y in inputYs) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = scheme.bitcoin.withValues(alpha: 0.55);
      final path = Path()
        ..moveTo(leftX, y)
        ..cubicTo(
          leftX + (centerX - leftX) * 0.5, y,
          centerX - (centerX - leftX) * 0.4, centerY,
          centerX - 17, centerY,
        );
      canvas.drawPath(path, paint);
    }

    // Output side — node to each output, arrowhead at the end.
    for (var i = 0; i < outputYs.length; i++) {
      final y = outputYs[i];
      final color = _colorFor(outputKinds[i]).withValues(alpha: 0.65);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = color;
      final endX = rightX - 7;
      final path = Path()
        ..moveTo(centerX + 17, centerY)
        ..cubicTo(
          centerX + (endX - centerX) * 0.4, centerY,
          endX - (endX - centerX) * 0.5, y,
          endX, y,
        );
      canvas.drawPath(path, paint);

      // Arrowhead.
      final head = Path()
        ..moveTo(rightX, y)
        ..lineTo(endX - 1, y - 4.5)
        ..lineTo(endX - 1, y + 4.5)
        ..close();
      canvas.drawPath(head, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) =>
      old.inputYs != inputYs ||
      old.outputYs != outputYs ||
      old.leftX != leftX ||
      old.rightX != rightX;
}

// ── Fee forecast panel (review step) ──────────────────────────────────────────

class _FeeForecastPanel extends StatelessWidget {
  const _FeeForecastPanel({required this.preview, required this.isBtc});
  final TxPreview preview;
  final bool isBtc;

  String get _eta {
    if (!isBtc) return '~1 min';
    if (preview.feeRate >= 8) return '~10 min';
    if (preview.feeRate >= 3) return '~30 min';
    return '~60 min or more';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);

    Widget cellBody(String label, String value, {Color? valueColor}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
            const SizedBox(height: 2),
            Text(
              value,
              style: AppTypography.numericSmall.copyWith(
                fontWeight: FontWeight.w700,
                color: valueColor ?? s.ink,
              ),
            ),
          ],
        );
    Widget cell(String label, String value, {Color? valueColor}) =>
        Expanded(child: cellBody(label, value, valueColor: valueColor));

    if (phone) {
      // Five cells in one row are 62 dp each on a phone; two per line keeps
      // "Confirmation" and the total on one line apiece.
      final cells = <(String, String, Color?)>[
        ('Fee', '${preview.feeSats} sats', s.warning),
        if (isBtc) ...[
          ('Rate', '${preview.feeRate.toStringAsFixed(1)} sat/vB', null),
          ('Est. size', '~${preview.vsizeEst} vB', null),
        ],
        ('Confirmation', _eta, null),
        ('Total spend', preview.totalDisplay, null),
      ];
      return Container(
        padding: const EdgeInsets.all(AppSpacing.cardPaddingSmall),
        // Phone: a card — panel ground, hairline, the softer corner.
        decoration: BoxDecoration(
          color: s.panel,
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          border: Border.all(color: s.edge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.local_gas_station_outlined,
                    size: 18, color: s.warning),
                const SizedBox(width: AppSpacing.sm),
                Text('Fee forecast',
                    style: AppTypography.label.copyWith(color: s.ink)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = (constraints.maxWidth - AppSpacing.md) / 2;
                return Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: [
                    for (final (label, value, color) in cells)
                      SizedBox(
                        width: w,
                        // Each figure gets its own inset tile: this is the
                        // step where the numbers have to be easiest to read,
                        // and label-over-value columns floating on the card
                        // ground had nothing separating one from the next.
                        child: Container(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: BoxDecoration(
                            color: s.panelInset,
                            borderRadius:
                                BorderRadius.circular(AppSpacing.radiusMd),
                          ),
                          child: cellBody(label, value, valueColor: color),
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

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
      ),
      child: Row(
        children: [
          Icon(Icons.local_gas_station_outlined, size: 20, color: s.warning),
          const SizedBox(width: AppSpacing.lg),
          cell('Fee', '${preview.feeSats} sats', valueColor: s.warning),
          if (isBtc) ...[
            cell('Rate', '${preview.feeRate.toStringAsFixed(1)} sat/vB'),
            cell('Est. size', '~${preview.vsizeEst} vB'),
          ],
          cell('Confirmation', _eta),
          cell('Total spend', preview.totalDisplay),
        ],
      ),
    );
  }
}
