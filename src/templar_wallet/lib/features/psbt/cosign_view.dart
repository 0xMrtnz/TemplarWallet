import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../services/cosigner_label_store.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/cosigner_ring.dart'
    show CosignerEntry, resolveCosigners, signerSlotsFor;
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/signer_donut.dart';
import '../../shared/widgets/step_header.dart' show SelectableOptionCard;
import '../../shared/widgets/ur_qr.dart'
    show UrAnimatedQr, cameraScanSupported, showUrScannerDialog;
import '../../services/file_export.dart';
import '../hardware/hw_error.dart';
import '../hardware/hw_platform.dart' show usbHardwareSupported;
import '../hardware/ledger_connect_dialog.dart';
import 'cosign_handoff.dart' show reportSaved, stackOrRow;
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/pset_inspection.dart';
import 'models/psbt_inspection.dart';

/// Which chain the transaction belongs to.
///
/// Asked first, as its own step (the owner's call, 2026-09-09): the user
/// knows which wallet's transaction they are holding, and answering it up
/// front lets the next screen ask for exactly one thing — a PSBT or a PSET —
/// and refuse the other with a reason. The payload's magic bytes still get
/// read, as the check that the answer and the blob agree.
enum CosignChain { bitcoin, liquid }

extension CosignChainWords on CosignChain {
  String get name => this == CosignChain.liquid ? 'Liquid' : 'Bitcoin';

  /// The artifact this chain's transactions travel as.
  String get artifact => this == CosignChain.liquid ? 'PSET' : 'PSBT';
}

/// Magic prefix of a serialized PSET: `pset\xff`. A PSBT starts `psbt\xff`.
const _psetMagic = [0x70, 0x73, 0x65, 0x74, 0xff];

/// Embeddable co-sign flow: choose the chain → paste a PSBT or PSET →
/// inspect → sign → export. Hosted by the Send screen's "Cosign a
/// transaction" mode; provides no Scaffold or page header of its own.
class CosignView extends StatefulWidget {
  const CosignView({super.key, this.bridge});

  /// Test seam: the engine this view talks to. Null in the app, which then
  /// uses the process-wide [walletBridge].
  final WalletBridge? bridge;

  @override
  State<CosignView> createState() => _CosignViewState();
}

class _CosignViewState extends State<CosignView> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;
  final _pasteController = TextEditingController();

  /// The chain the user said the transaction is on. Null until they have:
  /// the load card is not shown before then.
  CosignChain? _chosen;

  /// Whether "Sign with device" is worth offering. The Android APK links the
  /// engine with `--no-default-features`: hidapi, serialport, Jade and Ledger
  /// are not in the binary at all, so the button's only possible outcome
  /// there is an error. Asked of the engine rather than guessed from the
  /// platform — the wizard's key-source picker settles it the same way — and
  /// a failed probe leaves USB on offer, so a real error explains itself
  /// instead of an option quietly vanishing on a guess.
  bool _usbAvailable = usbHardwareSupported;

  /// Chain of the loaded transaction. Decides which backend calls sign,
  /// inspect and broadcast it.
  CosignChain _chain = CosignChain.bitcoin;

  PsbtInspection? _inspection;
  bool _loading = false;
  bool _signing = false;
  String? _error;
  String? _signedPsbt;

  /// The open wallet's keys with their names and colours, so the quorum
  /// chart can say "Anna's phone" rather than `bb000002`. Empty for a
  /// wallet with no co-signers.
  List<CosignerEntry> _cosigners = const [];

  /// Re-inspection of the PSBT after our signature was added — drives the
  /// quorum display and the "Finalize & Broadcast" gate.
  PsbtInspection? _signedInspection;
  bool _broadcasting = false;
  String? _txid;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _checkUsb();
    _loadCosigners();
  }

  Future<void> _loadCosigners() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    try {
      final info = await _bridge.getWalletInfo(walletId);
      if (info.cosignerKeys.length < 2) return;
      final labels = await CosignerLabelStore.instance.load(walletId);
      if (!mounted) return;
      setState(() => _cosigners = resolveCosigners(
            cosignerKeys: info.cosignerKeys,
            labels: labels,
            localFingerprints: info.localFingerprints,
          ));
    } catch (_) {
      // Names are a convenience; the chart works by fingerprint without them.
    }
  }

  /// The chart's slots for [i]: the wallet's labels where the fingerprints
  /// match, fingerprints otherwise.
  List<SignerSlot>? _slotsFor(PsbtInspection i) => i.signers.isEmpty
      ? null
      : signerSlotsFor(
          entries: _cosigners,
          signerFingerprints: i.signers.map((x) => x.fingerprint),
          signedFingerprints: [
            for (final x in i.signers)
              if (x.hasSigned) x.fingerprint,
          ],
        );

  Future<void> _checkUsb() async {
    if (!Platform.isAndroid) return;
    bool supported;
    try {
      supported = (await _bridge.hwiStatus()).hardwareSupported;
    } catch (_) {
      return;
    }
    if (!mounted || supported) return;
    setState(() => _usbAvailable = false);
  }

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  /// Inspect a PSBT or PSET from any source (paste / file / QR). Shared by all
  /// three. The chain was chosen a step earlier; the payload's magic bytes
  /// are read only to catch a blob from the other chain, which is refused
  /// with the reason rather than handed to a decoder that will not know it.
  Future<void> _inspectText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final chain = _chosen ?? _detectChain(trimmed);
    final detected = _detectChain(trimmed);
    if (detected != chain) {
      setState(() {
        _error = chain == CosignChain.bitcoin
            ? 'This is a Liquid PSET, not a Bitcoin PSBT. Go back and choose '
                'Liquid to co-sign it.'
            : 'This is not a Liquid PSET. If it is a Bitcoin PSBT, go back and '
                'choose Bitcoin to co-sign it.';
      });
      return;
    }
    setState(() {
      _chain = chain;
      _loading = true;
      _error = null;
      _signedPsbt = null;
      _signedInspection = null;
      _txid = null;
    });
    try {
      final result = await _inspectFor(trimmed, chain);
      if (mounted) setState(() { _inspection = result; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
  }

  /// Read the chain off the payload's magic bytes. Anything that is not a
  /// recognizable PSET is handed to the Bitcoin path, which reports a decode
  /// error of its own — better than this guess inventing one.
  static CosignChain _detectChain(String base64Text) {
    try {
      final bytes = base64.decode(base64Text);
      if (bytes.length >= _psetMagic.length) {
        for (var i = 0; i < _psetMagic.length; i++) {
          if (bytes[i] != _psetMagic[i]) return CosignChain.bitcoin;
        }
        return CosignChain.liquid;
      }
    } catch (_) {
      // Not base64 at all — let the Bitcoin decoder produce the message.
    }
    return CosignChain.bitcoin;
  }

  /// Inspect through the right backend and normalise the answer, so the whole
  /// display below stays chain-agnostic.
  Future<PsbtInspection> _inspectFor(String raw, CosignChain chain) async {
    if (chain == CosignChain.bitcoin) return _bridge.inspectPsbt(raw);
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) {
      throw Exception(
        'Open the Liquid wallet this transaction belongs to first — its '
        'amounts are confidential and only that wallet can read them.',
      );
    }
    return _asPsbtInspection(await _bridge.inspectPset(walletId, raw));
  }

  /// A PSET rendered in the same shape as a PSBT, so one review screen serves
  /// both.
  ///
  /// Inputs come from the engine's script view: every input, tagged with
  /// whether it asks for this wallet's signature and whether it is a script
  /// contract (a Templar Protocol escrow is a P2WSH input carrying our `2121'`
  /// key). Amounts are blinded commitments unless the PSET carries them
  /// explicitly, so a row may show "amount blinded". Older engines without
  /// the script view leave the list empty and the panel is hidden.
  ///
  /// Outputs prefer the classified list (own / escrow / external / fee) and
  /// fall back to LWK's recipients.
  static PsbtInspection _asPsbtInspection(PsetInspection p) => PsbtInspection(
        inputs: [
          for (final i in p.inputs)
            PsbtInput(
              outpoint: i.outpoint,
              amountSats: i.amountSats,
              displayAmount: _inputLabel(i),
            ),
        ],
        outputs: p.outputs.isNotEmpty
            ? [
                for (final o in p.outputs)
                  if (!o.isFee)
                    PsbtOutput(
                      address: '${o.kindLabel}: '
                          '${o.address ?? (o.isEscrow ? 'P2WSH contract (no address)' : 'confidential output')}',
                      amountSats: o.amountSats ?? 0,
                      displayAmount: o.unverified
                          ? 'UNVERIFIABLE amount — do not sign'
                          : o.displayAmount ??
                              (o.ticker != null
                                  ? 'amount blinded (${o.ticker})'
                                  : 'blinded'),
                    ),
              ]
            : [
                for (final r in p.recipients)
                  PsbtOutput(
                    address: r.address ?? 'confidential output (not ours to read)',
                    amountSats: r.amountSats ?? 0,
                    displayAmount: r.unverified
                        ? 'UNVERIFIABLE amount — do not sign'
                        : r.displayAmount ??
                            (r.ticker != null ? 'amount blinded (${r.ticker})' : 'blinded'),
                  ),
              ],
        feeSats: p.feeSats,
        feeDisplay: p.feeDisplay,
        sigsPresent: p.sigsHave,
        sigsRequired: p.sigsNeeded,
        signers: [
          for (final fp in p.signersPresent)
            PsbtSigner(fingerprint: fp, hasSigned: true),
          for (final fp in p.signersMissing)
            PsbtSigner(fingerprint: fp, hasSigned: false),
        ],
        policyHint: p.sigsNeeded > 1
            ? 'Liquid ${p.sigsNeeded}-of-${p.signersPresent.length + p.signersMissing.length} multisig'
            : 'Liquid transaction',
        rawPsbt: p.rawPset,
        // An output whose amount its commitment does not prove hides what
        // the signature pays, exactly like an inconsistent PSBT input.
        utxoCheck: p.hasUnverifiedOutputs
            ? PsbtUtxoStatus.conflicting
            : PsbtUtxoStatus.ok,
      );

  /// Amount column of a Liquid input row: the explicit amount when the PSET
  /// carries one, plus who the input belongs to.
  static String _inputLabel(PsetInput i) {
    final amount = i.unverified && !i.isOurs
        ? 'unverifiable amount'
        : i.displayAmount ??
        (i.ticker != null ? 'amount blinded (${i.ticker})' : 'amount blinded');
    final who = i.isOurs
        ? (i.isScriptHash ? 'contract · your key' : 'your coin')
        : (i.isScriptHash ? 'contract · not yours' : 'not yours');
    return '$amount · $who';
  }

  void _loadPsbt() => _inspectText(_pasteController.text);

  /// Open a `.psbt`/`.pset`/`.txt` file and inspect it. Binary PSBTs (magic
  /// `psbt\xff`) are base64-encoded; text files are taken as-is.
  Future<void> _pickFile() async {
    try {
      final liquid = _chosen == CosignChain.liquid;
      final group = XTypeGroup(
        label: liquid ? 'PSET' : 'PSBT',
        extensions: [liquid ? 'pset' : 'psbt', 'txt'],
        // macOS UTIs — allow both a dedicated PSBT type and plain text.
        uniformTypeIdentifiers: const ['public.text', 'public.data'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _inspectText(_psbtBytesToBase64(bytes));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read file: $e');
    }
  }

  static String _psbtBytesToBase64(Uint8List bytes) {
    // Binary PSBT starts `psbt\xff`, binary PSET `pset\xff`. Both are files a
    // co-signer's tool may hand back, and both need base64 before the backend
    // will look at them.
    const psbtMagic = [0x70, 0x73, 0x62, 0x74, 0xff];
    bool startsWith(List<int> magic) {
      if (bytes.length < magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (bytes[i] != magic[i]) return false;
      }
      return true;
    }

    if (startsWith(psbtMagic) || startsWith(_psetMagic)) {
      return base64.encode(bytes);
    }
    // Otherwise the file already holds base64 (or hex) text.
    return utf8.decode(bytes, allowMalformed: true).trim();
  }

  /// Open the shared camera scanner; inspect whatever QR payload comes back.
  /// The shared dialog reassembles multi-frame BC-UR payloads — a PSBT as
  /// `ur:crypto-psbt`, a PSET as Templar's `ur:bytes` animation — and the
  /// chain check in [_inspectText] catches a code from the other chain.
  Future<void> _scanQr() async {
    final artifact = (_chosen ?? CosignChain.bitcoin).artifact;
    final outcome = await showUrScannerDialog(
      context,
      expectPsbt: true,
      title: 'Scan $artifact QR code',
    );
    final result = outcome?.transactionBase64 ?? outcome?.descriptor;
    if (result == null || result.trim().isEmpty) return;
    await _inspectText(result);
  }

  Future<void> _sign() async {
    final inspection = _inspection;
    if (inspection == null) return;
    // The engine refuses these too; saying so here spares a password prompt
    // for a signature that can never be made.
    if (!inspection.utxoCheckOk) {
      setState(() => _error = 'This transaction hides what it spends — its amounts '
          'cannot be proven, so it will not be signed.');
      return;
    }
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    await _runSign(() => _chain == CosignChain.liquid
        ? _bridge.signPset(walletId, inspection.rawPsbt)
        : _bridge.signPsbt(walletId, inspection.rawPsbt));
  }

  /// Co-sign with a connected USB device.
  ///
  /// This is the only route by which a hardware key enrolled in a multisig
  /// actually signs: the send flow picks its signing path from the wallet's
  /// type, and a multisig wallet's type is "Multisig" — never
  /// "Hardware (…)" — so a device that was enrolled as a cosigner could
  /// contribute an xpub and then never be asked for a signature.
  Future<void> _signWithDevice() async {
    final inspection = _inspection;
    if (inspection == null) return;

    // Liquid skips the device picker: a Jade is the only device that can sign
    // an Elements transaction, so there is nothing to choose between. The
    // backend connects over serial and registers the multisig on the device
    // before asking for the signature.
    if (_chain == CosignChain.liquid) {
      final walletId = context.read<AppState>().activeWalletId;
      if (walletId == null) return;
      await _runSign(() => _bridge.signPsetHw(walletId, inspection.rawPsbt));
      return;
    }

    final device = await showHwDevicePickerDialog(
      context,
      title: 'Connect the co-signing device',
    );
    if (device == null || !mounted) return;
    await _runSign(() => _bridge.signPsbtHw(device.fingerprint, inspection.rawPsbt));
  }

  /// Shared signing wrapper: both routes produce a signed PSBT and both need
  /// the same re-inspection and error handling around it.
  Future<void> _runSign(Future<String> Function() sign) async {
    setState(() { _signing = true; _error = null; });
    try {
      final signed = await sign();
      // Re-inspect to learn whether the quorum is now met. Display-only — a
      // failure here must not lose the signed PSBT.
      PsbtInspection? after;
      try {
        after = await _inspectFor(signed, _chain);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _signedPsbt = signed;
          _signedInspection = after;
          _signing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _signing = false;
          _error = friendlyHwError(e);
        });
      }
    }
  }

  /// Finalize the fully-signed PSBT and hand it to the network. Available
  /// once every required signature is present — whether we just added the
  /// last one, or a complete PSBT was loaded for broadcast.
  Future<void> _broadcast() async {
    final psbt = _signedPsbt ?? _inspection?.rawPsbt;
    if (psbt == null) return;
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    setState(() { _broadcasting = true; _error = null; });
    try {
      final txid = _chain == CosignChain.liquid
          ? await _bridge.broadcastPset(walletId, psbt)
          : await _bridge.broadcastSignedPsbt(
              walletId: walletId,
              psbtBase64: psbt,
            );
      if (mounted) setState(() { _txid = txid; _broadcasting = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _broadcasting = false;
          _error = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
  }

  Future<void> _copySignedPsbt() async {
    if (_signedPsbt == null) return;
    await Clipboard.setData(ClipboardData(text: _signedPsbt!));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  /// Back to the load card of the same chain: the transaction is dropped,
  /// the chain answer is kept.
  void _reset() => setState(() {
        _inspection = null;
        _signedPsbt = null;
        _signedInspection = null;
        _txid = null;
        _broadcasting = false;
        _error = null;
        _pasteController.clear();
      });

  void _chooseChain(CosignChain chain) => setState(() {
        _chosen = chain;
        _chain = chain;
        _error = null;
      });

  /// Back to the chain question. Only offered before anything is loaded —
  /// once a transaction is on screen, Decline is the way out.
  void _changeChain() {
    _reset();
    setState(() => _chosen = null);
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen;
    if (chosen == null) {
      return _ChainStep(
        liquidAvailable: context.watch<AppState>().activeWalletLiquid,
        onChoose: _chooseChain,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_inspection == null && !_loading) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: GhostButton(
              label: '‹ ${chosen.name} · change chain',
              onPressed: _changeChain,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (_error != null) ...[
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.xl),
        ],
        if (_inspection == null && !_loading)
          _LoadPsbtCard(
            chain: chosen,
            controller: _pasteController,
            onLoadPaste: _loadPsbt,
            onPickFile: _pickFile,
            onScan: _scanQr,
          )
        else if (_loading)
          Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              child: const CircularProgressIndicator(),
            ),
          )
        else
          PsbtInspectionPanel(
            inspection: _inspection!,
            chain: _chain,
            signedInspection: _signedInspection,
            signing: _signing,
            signedPsbt: _signedPsbt,
            broadcasting: _broadcasting,
            txid: _txid,
            copied: _copied,
            usbAvailable: _usbAvailable,
            // Broadcasting belongs to the session that started the
            // transaction — the coordinator's sheet. A co-signer on a phone
            // signs and hands the copy back; it never sends.
            allowBroadcast: !AppLayout.isMobilePlatform,
            slots: _slotsFor(_signedInspection ?? _inspection!),
            onSign: _sign,
            onSignWithDevice: _signWithDevice,
            onBroadcast: _broadcast,
            onCopy: _copySignedPsbt,
            onDecline: _reset,
          ),
      ],
    );
  }
}

// ── Chain step ────────────────────────────────────────────────────────────────

/// "Bitcoin or Liquid?" — the co-sign flow's first question. Picking a card
/// moves on, as the Send wizard's type step does; there is nothing else to
/// decide on this screen.
class _ChainStep extends StatelessWidget {
  const _ChainStep({required this.liquidAvailable, required this.onChoose});

  /// Whether the open wallet has a Liquid side. A PSET's amounts are
  /// confidential and only the wallet they belong to can read them, so a
  /// wallet without Liquid has nothing to co-sign there.
  final bool liquidAvailable;
  final void Function(CosignChain) onChoose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('WHICH CHAIN?',
            style: AppTypography.label.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: AppSpacing.md),
        SelectableOptionCard(
          title: 'Bitcoin',
          description: 'A PSBT — from a Bitcoin multisig, an air-gapped '
              'signer, or another Bitcoin wallet.',
          isSelected: false,
          icon: Icons.currency_bitcoin,
          onTap: () => onChoose(CosignChain.bitcoin),
        ),
        const SizedBox(height: AppSpacing.md),
        Opacity(
          opacity: liquidAvailable ? 1 : 0.5,
          child: SelectableOptionCard(
            title: 'Liquid',
            description: liquidAvailable
                ? 'A PSET from a Liquid multisig. Its amounts are '
                    'confidential, so open the wallet the transaction '
                    'belongs to — this one — before loading it.'
                : 'This wallet has no Liquid side. Open the Liquid wallet '
                    'the transaction belongs to, then come back here.',
            isSelected: false,
            icon: Icons.water_drop_outlined,
            onTap: liquidAvailable ? () => onChoose(CosignChain.liquid) : null,
          ),
        ),
      ],
    );
  }
}

// ── Load section (paste / file / scan) ────────────────────────────────────────

class _LoadPsbtCard extends StatefulWidget {
  const _LoadPsbtCard({
    required this.chain,
    required this.controller,
    required this.onLoadPaste,
    required this.onPickFile,
    required this.onScan,
  });

  /// Names the artifact on every tile: a PSBT on Bitcoin, a PSET on Liquid.
  final CosignChain chain;
  final TextEditingController controller;
  final VoidCallback onLoadPaste;
  final Future<void> Function() onPickFile;
  final Future<void> Function() onScan;

  @override
  State<_LoadPsbtCard> createState() => _LoadPsbtCardState();
}

class _LoadPsbtCardState extends State<_LoadPsbtCard> {
  /// Whether the Paste tile is open (revealing its text field). File and Scan
  /// tiles fire their native flows directly, so they need no open state.
  bool _pasteOpen = false;

  @override
  Widget build(BuildContext context) {
    // Three square selectors straight on the page — no wrapper panel or
    // banner. Flat surfaces like the rest of the app's option menus.
    //
    // Three 190 dp squares need 570 dp plus their gaps, which no phone has:
    // the Row ran 255 px off the right edge and took Scan QR with it, so the
    // camera route was invisible on the very platform that has a camera. On a
    // phone the same three become full-width rows, stacked.
    final phone = AppLayout.isPhone(context);
    final artifact = widget.chain.artifact;
    final tiles = <Widget>[
      _SourceTile(
        icon: Icons.content_paste,
        label: 'Paste',
        sub: 'base64 $artifact text',
        selected: _pasteOpen,
        wide: phone,
        onTap: () => setState(() => _pasteOpen = !_pasteOpen),
      ),
      _SourceTile(
        icon: Icons.folder_open,
        label: 'File',
        sub: '.${artifact.toLowerCase()}',
        wide: phone,
        onTap: () {
          setState(() => _pasteOpen = false);
          widget.onPickFile();
        },
      ),
      // Only where a camera exists: on Windows and Linux mobile_scanner has no
      // implementation, and the tile's only outcome is an apology dialog. Both
      // chains scan: a PSBT arrives as ur:crypto-psbt, a PSET as the ur:bytes
      // animation another Templar shows for it.
      if (cameraScanSupported)
        _SourceTile(
          icon: Icons.qr_code_scanner,
          label: 'Scan QR',
          sub: 'camera',
          wide: phone,
          onTap: () {
            setState(() => _pasteOpen = false);
            widget.onScan();
          },
        ),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phone)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < tiles.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.md),
                    tiles[i],
                  ],
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < tiles.length; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.xxl),
                    tiles[i],
                  ],
                ],
              ),
            // Paste tile expands to a text field + load button below.
            AnimatedSize(
              duration: AppMotion.of(context, AppMotion.quick),
              curve: AppMotion.settle,
              alignment: Alignment.topCenter,
              child: _pasteOpen
                  ? Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xl),
                      child: _PasteSource(
                        artifact: artifact,
                        controller: widget.controller,
                        onLoad: widget.onLoadPaste,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// One square source selector (Paste / File / Scan QR).
class _SourceTile extends StatefulWidget {
  const _SourceTile({
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
    this.selected = false,
    this.wide = false,
  });
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;
  final bool selected;

  /// Phone shape: a full-width row instead of a fixed 190 dp square, so three
  /// of them stack down the column rather than running off its right edge.
  final bool wide;

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final active = widget.selected || _hover;

    // Flat option-card styling — same language as the wizard's
    // SelectableOptionCard: solid surface, plain border, accent when active.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.of(context, AppMotion.quick),
          curve: AppMotion.settle,
          width: widget.wide ? null : 190,
          height: widget.wide ? null : 190,
          padding: widget.wide
              ? const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.md)
              : null,
          decoration: BoxDecoration(
            color: widget.selected ? s.accentSoft : s.surfaceSolid,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(
              color: active ? s.accent : s.edge,
              width: widget.selected ? 2 : 1,
            ),
          ),
          child: widget.wide
              ? Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 26,
                      color: active ? s.accent : s.inkSecondary,
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.label,
                            style: AppTypography.sectionTitle.copyWith(
                              color: active ? s.accent : s.ink,
                            ),
                          ),
                          Text(
                            widget.sub,
                            style: AppTypography.caption
                                .copyWith(color: s.inkFaint),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      widget.icon,
                      size: 36,
                      color: active ? s.accent : s.inkSecondary,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      widget.label,
                      style: AppTypography.sectionTitle.copyWith(
                        color: active ? s.accent : s.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.sub,
                      style: AppTypography.caption.copyWith(color: s.inkFaint),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _PasteSource extends StatelessWidget {
  const _PasteSource({
    required this.artifact,
    required this.controller,
    required this.onLoad,
  });
  final String artifact;
  final TextEditingController controller;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: 'Paste the base64 $artifact here…',
            alignLabelWithHint: true,
          ),
          style: AppTypography.mono,
        ),
        const SizedBox(height: AppSpacing.lg),
        PrimaryButton(
          label: 'Load & Inspect',
          icon: Icons.search,
          isFullWidth: true,
          onPressed: onLoad,
        ),
      ],
    );
  }
}

// ── Loaded PSBT view ──────────────────────────────────────────────────────────

/// Everything shown once a PSBT or PSET has been decoded: the summary, the
/// signature quorum chart, the inputs and outputs, and the action row.
///
/// Public so it can be driven from a test with a hand-written
/// [PsbtInspection] — reaching the signer chart and the action row through the
/// real engine would need a multisig PSBT fixture to assert on what are pure
/// layout decisions.
class PsbtInspectionPanel extends StatelessWidget {
  const PsbtInspectionPanel({
    super.key,
    required this.inspection,
    required this.chain,
    required this.signedInspection,
    required this.signing,
    required this.signedPsbt,
    required this.broadcasting,
    required this.txid,
    required this.copied,
    this.usbAvailable = true,
    this.allowBroadcast = true,
    this.slots,
    required this.onSign,
    required this.onSignWithDevice,
    required this.onBroadcast,
    required this.onCopy,
    required this.onDecline,
  });

  final PsbtInspection inspection;

  /// Which chain this transaction is on. Only changes wording and the inputs
  /// panel — a PSET reports what it pays, not what it spends.
  final CosignChain chain;

  final PsbtInspection? signedInspection;
  final bool signing;
  final String? signedPsbt;
  final bool broadcasting;
  final String? txid;
  final bool copied;

  /// Whether this build can talk to a USB signer at all — false on Android,
  /// whose engine is linked without the hardware stack.
  final bool usbAvailable;

  /// Whether "Finalize & Broadcast" is offered here at all. False on a phone:
  /// broadcasting is the coordinator's move, in the session that built the
  /// transaction; a co-signer's job ends at handing the signed copy back.
  final bool allowBroadcast;

  /// The signers by name and colour, when the open wallet knows them.
  final List<SignerSlot>? slots;

  final VoidCallback onSign;

  /// Co-sign with a connected USB hardware device.
  final VoidCallback onSignWithDevice;
  final VoidCallback onBroadcast;
  final VoidCallback onCopy;
  final VoidCallback onDecline;

  /// Every required signature is present — the PSBT can be finalized and
  /// broadcast. Only claimed when the threshold is actually known.
  bool get _isComplete {
    final i = signedInspection ?? inspection;
    return i.sigsRequired != null && i.sigsPresent >= i.sigsRequired!;
  }

  /// Complete AND this surface may broadcast.
  bool get _offersBroadcast => allowBroadcast && _isComplete;

  @override
  Widget build(BuildContext context) {
    // Post-signature inspection supersedes the original: same transaction,
    // but with our signature counted in the quorum display.
    final i = signedInspection ?? inspection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary banner
        Reveal(child: _SummaryBanner(inspection: i)),
        const SizedBox(height: AppSpacing.xl),
        // Signers (if multisig)
        if (i.signers.isNotEmpty) ...[
          Reveal(delay: 1, child: _SignersCard(inspection: i, slots: slots)),
          const SizedBox(height: AppSpacing.xl),
        ],
        // Inputs — full outpoints, never truncated. A PSET lists them only
        // when the engine's script view is present (it tags each input with
        // whose key it asks for); without it an empty panel would read as
        // "spends nothing", so it is hidden.
        if (chain == CosignChain.bitcoin || i.inputs.isNotEmpty) ...[
        Reveal(
          delay: 2,
          child: RailPanel(
            title: 'Inputs (${i.inputs.length})',
            rail: AppScheme.of(context).bitcoin,
            child: Column(
              children: [
                for (final inp in i.inputs) ...[
                  DataWell(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Spacer(),
                            Text(inp.displayAmount,
                                style: AppTypography.numericSmall.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppScheme.of(context).ink,
                                )),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        KvRow(label: 'Outpoint', value: inp.outpoint),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        ],
        // Outputs — full addresses, never truncated.
        Reveal(
          delay: 3,
          child: RailPanel(
            title: 'Outputs (${i.outputs.length})',
            rail: AppScheme.of(context).liquid,
            child: Column(
              children: [
                for (final out in i.outputs) ...[
                  DataWell(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Spacer(),
                            Text(out.displayAmount,
                                style: AppTypography.numericSmall.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppScheme.of(context).ink,
                                )),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        KvRow(label: 'Address', value: out.address),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        // Fee summary
        SummaryCard(
          title: 'Transaction Summary',
          rows: [
            (label: 'Fee', value: i.feeDisplay, isMono: false),
            (label: 'Policy', value: i.policyHint, isMono: false),
            if (i.sigsRequired != null)
              (
                label: 'Signatures',
                value: '${i.sigsPresent} of ${i.sigsRequired} collected',
                isMono: false
              ),
          ],
        ),
        // Broadcast result / signed PSBT export
        if (txid != null) ...[
          const SizedBox(height: AppSpacing.xl),
          _BroadcastResultCard(txid: txid!),
        ] else if (signedPsbt != null) ...[
          const SizedBox(height: AppSpacing.xl),
          _SignedExportCard(
            signedPsbt: signedPsbt!,
            chain: chain,
            copied: copied,
            onCopy: onCopy,
            message: _exportMessage(i),
          ),
        ],
        const SizedBox(height: AppSpacing.xxl),
        // Action row. Three labelled buttons ("Decline", "Sign with device",
        // "Sign & Export") never fitted one phone line — the Row ran off the
        // right edge and Flutter painted the overflow stripes. On a phone the
        // same buttons stack full width, most important first, which is also
        // where a thumb expects them.
        _actionRow(context),
      ],
    );
  }

  /// The buttons under the transaction: one line on a desktop, a full-width
  /// stack on a phone. [stackOrRow] orders them as given, so the list is
  /// written most-important-first and the desktop row reverses back to its
  /// established right-aligned order.
  Widget _actionRow(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final buttons = <Widget>[];

    if (txid != null) {
      buttons.add(SecondaryButton(
        label: 'Co-sign another transaction',
        icon: Icons.swap_horiz,
        isFullWidth: phone,
        onPressed: onDecline,
      ));
    } else if (signedPsbt == null) {
      if (signing || broadcasting) {
        return const Align(
            alignment: Alignment.centerRight, child: _ActionSpinner());
      }
      // A loaded PSBT that already carries every signature (e.g. the
      // coordinator got it back from the last cosigner) skips straight to
      // broadcast — where this surface may broadcast at all.
      if (_offersBroadcast) {
        buttons.add(PrimaryButton(
          label: 'Finalize & Broadcast',
          icon: Icons.cell_tower,
          isFullWidth: phone,
          onPressed: onBroadcast,
        ));
        buttons.add(SecondaryButton(
          label: 'Sign & Export',
          icon: Icons.verified_outlined,
          isFullWidth: phone,
          onPressed: onSign,
        ));
      } else {
        buttons.add(PrimaryButton(
          label: 'Sign & Export',
          icon: Icons.verified_outlined,
          isFullWidth: phone,
          onPressed: onSign,
        ));
        // Offered next to the software key, not instead of it: a multisig
        // quorum is routinely a mix of both. Not on Android, which has no USB
        // stack at all — there the button's only outcome is an error.
        if (usbAvailable) {
          buttons.add(SecondaryButton(
            label: 'Sign with device',
            icon: Icons.usb_rounded,
            isFullWidth: phone,
            onPressed: onSignWithDevice,
          ));
        }
      }
      buttons.add(DangerButton(
        label: 'Decline',
        icon: Icons.close,
        isFullWidth: phone,
        onPressed: onDecline,
      ));
    } else {
      if (_offersBroadcast) {
        if (broadcasting) {
          return const Align(
              alignment: Alignment.centerRight, child: _ActionSpinner());
        }
        buttons.add(PrimaryButton(
          label: 'Finalize & Broadcast',
          icon: Icons.cell_tower,
          isFullWidth: phone,
          onPressed: onBroadcast,
        ));
      }
      buttons.add(SecondaryButton(
        label: 'Co-sign another transaction',
        icon: Icons.swap_horiz,
        isFullWidth: phone,
        onPressed: onDecline,
      ));
    }

    if (phone) return stackOrRow(true, buttons);
    // Desktop keeps the right-aligned row it always had, in its established
    // order (the list above is written most-important-first for the stack).
    final row = buttons.reversed.toList();
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        for (var i = 0; i < row.length; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.sm),
          row[i],
        ],
      ],
    );
  }

  /// The word for what the user is holding, on the chain they are on.
  String get _artifact => chain == CosignChain.liquid ? 'PSET' : 'PSBT';

  /// Copy under the signed export card: either the quorum is met and the
  /// transaction is broadcast-ready, or it states how many signatures are
  /// missing.
  String _exportMessage(PsbtInspection i) {
    if (_isComplete) {
      return allowBroadcast
          ? 'All ${i.sigsRequired} required signatures are present. Finalize '
              '& broadcast below, or copy the $_artifact to broadcast elsewhere.'
          : 'All ${i.sigsRequired} required signatures are present. Hand this '
              '$_artifact back to whoever started the transaction — it is '
              'broadcast from there.';
    }
    final required = i.sigsRequired;
    if (required != null) {
      final missing = (required - i.sigsPresent).clamp(1, required);
      return 'Your signature has been added. $missing more '
          'signature${missing == 1 ? '' : 's'} needed — copy the $_artifact and '
          'send it to the other signers or the coordinator.';
    }
    return 'Your signature has been added. Copy the $_artifact and send it to the '
        'other signers or the coordinator.';
  }
}

class _ActionSpinner extends StatelessWidget {
  const _ActionSpinner();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({required this.inspection});
  final PsbtInspection inspection;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final i = inspection;
    return HeroPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Transaction',
                  style: AppTypography.caption.copyWith(color: s.inkSecondary)),
              const Spacer(),
              TagChip(label: i.policyHint, color: s.accent),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${i.inputs.length} input${i.inputs.length == 1 ? '' : 's'}  ·  '
            '${i.outputs.length} output${i.outputs.length == 1 ? '' : 's'}  ·  '
            'Fee: ${i.feeDisplay}',
            style: AppTypography.numericSmall.copyWith(color: s.ink),
          ),
        ],
      ),
    );
  }
}

class _SignersCard extends StatelessWidget {
  const _SignersCard({required this.inspection, this.slots});
  final PsbtInspection inspection;

  /// Named slots, when the wallet knows the signers; the chart then lists
  /// them itself and the fingerprint rows below are not drawn twice.
  final List<SignerSlot>? slots;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final i = inspection;
    final named = slots != null && slots!.isNotEmpty;
    return RailPanel(
      title: 'Signature quorum',
      trailing: i.sigsRequired != null
          ? Text(
              '${i.sigsPresent} OF ${i.sigsRequired} REQUIRED',
              style: AppTypography.navSection
                  .copyWith(color: s.accent, fontSize: 10.5),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ring counts come from the signer list rather than from
          // `sigsPresent`, so the ring can never disagree with the rows
          // printed under it: `sigsPresent` is the minimum partial-signature
          // count across all inputs and may include a signature the
          // inspection could not attribute to a named signer. That number is
          // still reported, verbatim, in the quorum line beside the legend.
          SignerChart(
            signed: i.signers.where((x) => x.hasSigned).length,
            total: i.signers.length,
            requiredCount: i.sigsRequired,
            collected: i.sigsPresent,
            slots: slots,
          ),
          if (!named) const SizedBox(height: AppSpacing.lg),
          if (!named) ...i.signers.map((sig) {
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(
                    sig.hasSigned
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: sig.hasSigned ? s.success : s.inkFaint,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(sig.fingerprint,
                      style: AppTypography.mono.copyWith(
                          color: sig.hasSigned ? s.ink : s.inkSecondary)),
                  const Spacer(),
                  TagChip(
                    label: sig.hasSigned ? 'Signed' : 'Pending',
                    color: sig.hasSigned ? s.success : s.inkFaint,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// What a co-signer does with the transaction once they have signed it: read
/// it back as a QR, hand it over as a file, or copy the text.
///
/// The card used to offer Copy alone, which on a phone is the one route that
/// goes nowhere — there is no second window to paste base64 into, and the
/// clipboard is not how a signed PSBT reaches a coordinator across the room.
/// The QR is the air-gap route the rest of the app already speaks (BC-UR,
/// animated when the payload needs more than one frame); the share sheet is
/// how a phone moves a file at all.
class _SignedExportCard extends StatefulWidget {
  const _SignedExportCard({
    required this.signedPsbt,
    required this.chain,
    required this.copied,
    required this.onCopy,
    required this.message,
  });
  final String signedPsbt;
  final CosignChain chain;
  final bool copied;
  final VoidCallback onCopy;
  final String message;

  @override
  State<_SignedExportCard> createState() => _SignedExportCardState();
}

class _SignedExportCardState extends State<_SignedExportCard> {
  /// BC-UR fragments of the signed PSBT, once the engine has encoded them.
  List<String>? _urParts;
  String? _urError;
  bool _showQr = false;

  /// A PSBT goes out as `ur:crypto-psbt`, which any air-gap signer reads; a
  /// PSET has no registry type and goes out as Templar's own `ur:bytes`
  /// animation, for the coordinator's Templar across the table.
  Future<void> _toggleQr() async {
    setState(() => _showQr = !_showQr);
    if (!_showQr || _urParts != null || _urError != null) return;
    try {
      final parts = widget.chain == CosignChain.liquid
          ? await walletBridge.urPsetEncode(widget.signedPsbt)
          : await walletBridge.urPsbtEncode(widget.signedPsbt);
      if (mounted) setState(() => _urParts = parts);
    } catch (e) {
      if (!mounted) return;
      setState(() => _urError =
          e.toString().replaceFirst('Exception: wallet-ffi: ', ''));
    }
  }

  Future<void> _saveFile() async {
    final liquid = widget.chain == CosignChain.liquid;
    try {
      final outcome = await FileExport.saveOrShareText(
        context,
        suggestedName: liquid ? 'signed.pset' : 'signed.psbt',
        text: widget.signedPsbt,
        acceptedTypeGroups: [
          XTypeGroup(
              label: liquid ? 'PSET' : 'PSBT',
              extensions: [liquid ? 'pset' : 'psbt']),
        ],
        shareTitle: liquid ? 'Signed PSET' : 'Signed PSBT',
      );
      if (!mounted) return;
      reportSaved(context, outcome);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final artifact = widget.chain == CosignChain.liquid ? 'PSET' : 'PSBT';
    final saveLabel = FileExport.sharesInsteadOfSaves
        ? 'Share .${artifact.toLowerCase()}'
        : 'Save .${artifact.toLowerCase()} file';

    return FormCard(
      title: 'Signed $artifact',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InfoBanner(message: widget.message),
          if (_showQr) ...[
            const SizedBox(height: AppSpacing.lg),
            Center(
              child: _urParts != null
                  ? UrAnimatedQr(
                      parts: _urParts!,
                      size: phone ? AppLayout.qrSide(context, max: 300) : 260,
                    )
                  : _urError != null
                      ? Text(_urError!,
                          style: AppTypography.bodySmall
                              .copyWith(color: AppScheme.of(context).danger))
                      : const Padding(
                          padding: EdgeInsets.all(AppSpacing.xl),
                          child: CircularProgressIndicator(),
                        ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          CodeBox(value: widget.signedPsbt, maxLines: 5),
          const SizedBox(height: AppSpacing.lg),
          stackOrRow(phone, [
            SecondaryButton(
              label: _showQr ? 'Hide QR' : 'Show QR',
              icon: _showQr ? Icons.qr_code_2_outlined : Icons.qr_code_2,
              isFullWidth: phone,
              onPressed: _toggleQr,
            ),
            SecondaryButton(
              label: saveLabel,
              icon: FileExport.sharesInsteadOfSaves
                  ? Icons.ios_share
                  : Icons.save_alt,
              isFullWidth: phone,
              onPressed: _saveFile,
            ),
            SecondaryButton(
              label: widget.copied ? 'Copied!' : 'Copy $artifact',
              icon: widget.copied ? Icons.check : Icons.copy,
              isFullWidth: phone,
              onPressed: widget.onCopy,
            ),
          ]),
        ],
      ),
    );
  }
}

class _BroadcastResultCard extends StatelessWidget {
  const _BroadcastResultCard({required this.txid});
  final String txid;

  @override
  Widget build(BuildContext context) {
    return FormCard(
      title: 'Transaction broadcast',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const InfoBanner(
            message: 'All required signatures were present — the transaction '
                'was finalized and sent to the network.',
          ),
          const SizedBox(height: AppSpacing.lg),
          CodeBox(value: txid, label: 'TxID'),
        ],
      ),
    );
  }
}

// Note for a future FFI proposal (not done silently here): PsbtInspection
// lacks per-input addresses and mine/change attribution for outputs. Once the
// bridge exposes them, inputs/outputs gain YOURS / CHANGE TagChips like the
// send review dialog.
