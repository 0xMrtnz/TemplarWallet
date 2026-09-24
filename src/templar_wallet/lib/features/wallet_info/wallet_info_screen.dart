import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../services/file_export.dart';
import '../../theme/app_typography.dart';
import '../hardware/hw_error.dart';
import 'models/wallet_info.dart';

class WalletInfoScreen extends StatefulWidget {
  const WalletInfoScreen({super.key, this.bridge});

  /// Test seam: the engine to read keys from. Null in the app, which then
  /// uses the process-wide [walletBridge].
  final WalletBridge? bridge;

  @override
  State<WalletInfoScreen> createState() => _WalletInfoScreenState();
}

class _WalletInfoScreenState extends State<WalletInfoScreen> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;
  WalletInfo? _info;
  bool _loading = true;
  String? _error;

  /// Reading the Liquid descriptor off the device for a wallet paired
  /// Bitcoin-only.
  bool _addingLiquid = false;
  String? _liquidError;

  /// The two keys this wallet hands to whoever is building a multisig with
  /// it: BIP48 for Bitcoin, BIP87 for Liquid. Neither is the XPUB this page
  /// already shows — that one is the singlesig account (m/84'/1'/0') and is
  /// useless to a co-signer, which is exactly the mistake this section
  /// exists to stop.
  String? _cosignerXpub;
  String? _liquidCosignerXpub;
  bool _loadingCosignerKeys = false;

  /// Why the two keys are not on screen, when they are not: a hardware or
  /// watch-only wallet keeps its seed out of reach, so the engine refuses.
  String? _cosignerKeysError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Whether this wallet could gain a Liquid side from its device.
  ///
  /// Only a USB hardware wallet can: a software wallet already derives Liquid
  /// from its own seed, and an air-gap wallet cannot get a blinding key at all
  /// — Jade's QR mode does not export one. The backend refuses the other cases
  /// too; this keeps the button from appearing where it could only fail.
  bool get _canAddLiquid {
    final st = context.read<AppState>();
    return st.isActiveWalletHardware &&
        !st.activeWalletLiquid &&
        !(st.activeWalletType ?? '').toLowerCase().contains('air-gap');
  }

  /// Whether this software wallet can derive its Liquid side right here.
  ///
  /// The seed is already in the registry, so no device and no re-import is
  /// needed — this is the recovery path for wallets restored before the
  /// Restore screen asked the coins question and passed `liquid: false`.
  bool get _canEnableLiquidFromSeed {
    final st = context.read<AppState>();
    return !st.activeWalletLiquid &&
        (st.activeWalletType ?? '').toLowerCase() == 'software';
  }

  Future<void> _enableLiquidFromSeed() async {
    final st = context.read<AppState>();
    final walletId = st.activeWalletId ?? '';
    setState(() {
      _addingLiquid = true;
      _liquidError = null;
    });
    try {
      await _bridge.enableLiquid(walletId);
      if (!mounted) return;
      // The sidebar's LIQUID section and the Receive tabs read this flag, so it
      // has to flip before anything reloads.
      st.setActiveWallet(
        walletId,
        name: st.activeWalletName,
        type: st.activeWalletType,
        liquid: true,
        bitcoin: st.activeWalletBitcoin,
      );
      setState(() => _addingLiquid = false);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Liquid enabled for this wallet')),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _addingLiquid = false;
          _liquidError = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
  }

  Future<void> _addLiquid() async {
    final walletId = context.read<AppState>().activeWalletId ?? '';
    setState(() {
      _addingLiquid = true;
      _liquidError = null;
    });
    try {
      final updated = await _bridge.addLiquidToWallet(walletId);
      if (!mounted) return;
      // The wallet gained a chain: the sidebar's Liquid section and the receive
      // tabs read this flag, so it has to be updated before anything reloads.
      context.read<AppState>().setActiveWallet(
            updated.id,
            name: updated.name,
            type: updated.typeLabel,
            liquid: true,
            bitcoin: updated.bitcoinEnabled,
          );
      setState(() => _addingLiquid = false);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Liquid added to this wallet')),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _addingLiquid = false;
          _liquidError = friendlyHwError(e);
        });
      }
    }
  }

  Future<void> _load() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    // A bridge failure must surface an error card, not strand the spinner.
    final WalletInfo info;
    try {
      info = await _bridge.getWalletInfo(walletId);
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; _error = e.toString(); });
      }
      return;
    }
    if (!mounted) return;
    setState(() { _info = info; _loading = false; _error = null; });
    if (_isSinglesigWallet) await _loadCosignerKeys(walletId);
  }

  /// Fetches the BIP48 and BIP87 cosigner keys. Both come off the seed, so
  /// only a software wallet has them here; a hardware one exports its own
  /// during the multisig wizard, over USB or as a QR, and the section says so
  /// rather than showing an error the user cannot act on.
  Future<void> _loadCosignerKeys(String walletId) async {
    if (!mounted) return;
    final st = context.read<AppState>();
    if (st.isActiveWalletHardware || (_info?.hasSeed ?? false) == false) {
      setState(() {
        _cosignerXpub = null;
        _liquidCosignerXpub = null;
        _cosignerKeysError = st.isActiveWalletWatchOnly
            ? 'A watch-only wallet holds no keys, so it has none to hand '
                'over. Take the cosigner keys from the wallet or device that '
                'holds its seed.'
            : 'This wallet keeps its keys on a device. Read them straight '
                'from it in the multisig wizard — "Read xpub from device" '
                'over USB, or the device\'s own QR export.';
      });
      return;
    }
    setState(() {
      _loadingCosignerKeys = true;
      _cosignerKeysError = null;
    });
    // Two independent calls: a Liquid key that cannot be derived must not
    // cost the Bitcoin one, which is the half a Bitcoin-only multisig needs.
    String? btc;
    String? liquid;
    String? failure;
    try {
      btc = await _bridge.getCosignerXpub(walletId);
    } catch (e) {
      failure = _plain(e);
    }
    try {
      liquid = await _bridge.getLiquidCosignerXpub(walletId);
    } catch (e) {
      failure ??= _plain(e);
    }
    if (!mounted) return;
    setState(() {
      _loadingCosignerKeys = false;
      _cosignerXpub = btc;
      _liquidCosignerXpub = liquid;
      _cosignerKeysError = (btc == null && liquid == null) ? failure : null;
    });
  }

  /// Drops the transport wrapper so the engine's own sentence leads.
  String _plain(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('wallet-ffi: ', '');

  /// Human-readable descriptor bundle — what a co-signer or another wallet
  /// app needs to reconstruct this wallet watch-only.
  String _descriptorBundle() {
    final i = _info!;
    final b = StringBuffer()
      ..writeln('# ${i.name} — Templar Wallet descriptor export (testnet)')
      ..writeln('Master fingerprint: ${i.masterFingerprint}')
      ..writeln('Derivation path: ${i.derivationPath}')
      ..writeln('Script type: ${i.scriptType}');
    if (i.xpub.isNotEmpty) b.writeln('XPUB: ${i.xpub}');
    b.writeln('Receive descriptor: ${i.receiveDescriptor}');
    if (i.multipathDescriptor != null) {
      b.writeln('Multipath descriptor: ${i.multipathDescriptor}');
    }
    for (final e in i.cosignerKeys.asMap().entries) {
      b.writeln('Cosigner key ${e.key + 1}: ${e.value}');
    }
    // The two keys this wallet gives OUT, kept apart from the keys it is made
    // of and labelled with their accounts — a bundle mailed to a co-signer is
    // read by a human who has to know which line goes in which field. Only a
    // singlesig wallet ever loads them.
    if (_cosignerXpub case final k?) {
      b.writeln("As a cosigner — Bitcoin (BIP48, m/48'/1'/0'/2'): $k");
    }
    if (_liquidCosignerXpub case final k?) {
      b.writeln("As a cosigner — Liquid (BIP87, m/87'/1'/0'): $k");
    }
    if (i.liquidDescriptor != null) {
      b.writeln('Liquid CT descriptor: ${i.liquidDescriptor}');
    }
    return b.toString();
  }

  Future<void> _copyBundle() async {
    await Clipboard.setData(ClipboardData(text: _descriptorBundle()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Descriptor bundle copied to clipboard')),
    );
  }

  /// Sparrow/Specter-compatible generic JSON export via the platform's native
  /// save dialog (GTK / NSSavePanel / IFileDialog). A user-chosen location is
  /// also the only path the macOS sandbox lets us write outside the container.
  Future<void> _exportJson() async {
    final i = _info!;
    final map = <String, dynamic>{
      'label': i.name,
      'network': i.network,
      'master_fingerprint': i.masterFingerprint,
      'derivation_path': i.derivationPath,
      'script_type': i.scriptType,
      if (i.xpub.isNotEmpty) 'xpub': i.xpub,
      'receive_descriptor': i.receiveDescriptor,
      if (i.multipathDescriptor != null)
        'multipath_descriptor': i.multipathDescriptor,
      if (i.cosignerKeys.isNotEmpty) 'cosigner_keys': i.cosignerKeys,
      if (_cosignerXpub != null) 'as_cosigner_bip48_xpub': _cosignerXpub,
      if (_liquidCosignerXpub != null)
        'as_cosigner_bip87_liquid_xpub': _liquidCosignerXpub,
      if (i.liquidDescriptor != null) 'liquid_ct_descriptor': i.liquidDescriptor,
    };
    try {
      final safeName =
          i.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').toLowerCase();
      final where = await FileExport.saveOrShareText(
        context,
        suggestedName: 'templar-wallet-$safeName.json',
        text: const JsonEncoder.withIndent('  ').convert(map),
        mimeType: 'application/json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (where == null) return; // user cancelled
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(where == 'shared' ? 'Exported' : 'Exported to $where'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  /// QR of the wallet descriptor for airgapped import into other apps.
  void _showQr() {
    final i = _info!;
    showValueQr(
      context,
      title: 'Descriptor QR',
      value: i.multipathDescriptor ?? i.receiveDescriptor,
      caption: 'Scan with Sparrow, Specter, or another wallet to import '
          'this wallet watch-only.',
    );
  }

  /// Whether this wallet is itself a multisig — it then has cosigner keys of
  /// its own, and its account key is the BIP48 one rather than a singlesig
  /// account.
  bool get _isMultisigWallet => _info!.cosignerKeys.isNotEmpty;

  /// Whether this wallet is a single key that can join someone else's
  /// multisig. A multisig or a Miniscript policy is already made of several
  /// keys and has no cosigner key of its own to hand over, so the "Use this
  /// wallet as a cosigner" card belongs to singlesig wallets only.
  bool get _isSinglesigWallet {
    final type =
        (context.read<AppState>().activeWalletType ?? '').toLowerCase();
    return !_isMultisigWallet &&
        _info!.requiredSigs == null &&
        type != 'multisig' &&
        !type.startsWith('policy');
  }

  /// "Use this wallet as a cosigner": the two keys, spelled out, with the
  /// wizard field each one goes in.
  ///
  /// The whole point is that there are TWO and that they are not
  /// interchangeable — Liquid lives on m/87'/1'/0' and Bitcoin on
  /// m/48'/1'/0'/2', neither computable from the other — so the card names
  /// both paths and both destinations instead of leaving a tester to guess
  /// which xpub on this page the wizard wanted.
  Widget _asACosignerCard({required bool phone, required int codeLines}) {
    final s = AppScheme.of(context);
    final caption =
        AppTypography.caption.copyWith(color: phone ? s.inkSecondary : null);
    final watchOnly = context.read<AppState>().isActiveWalletWatchOnly;
    return SectionCard(
      title: 'Use this wallet as a cosigner',
      subtitle: 'The keys another wallet needs to include this one in a '
          'multisig. Safe to share — neither can spend.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadingCosignerKeys)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_cosignerKeysError case final err?)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                    watchOnly
                        ? Icons.visibility_outlined
                        : Icons.usb_rounded,
                    size: 16,
                    color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(err, style: caption)),
              ],
            )
          else ...[
            if (_cosignerXpub case final key?) ...[
              CodeBox(
                label: "Cosigner xpub — Bitcoin (BIP48)",
                value: key,
                maxLines: codeLines,
                showQr: true,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                "Account m/48'/1'/0'/2'. Goes in the wizard's "
                '"Cosigner xpub" field.',
                style: caption,
              ),
            ],
            if (_cosignerXpub != null && _liquidCosignerXpub != null)
              const SizedBox(height: AppSpacing.lg),
            if (_liquidCosignerXpub case final key?) ...[
              CodeBox(
                label: 'Cosigner Liquid key (BIP87)',
                value: key,
                maxLines: codeLines,
                showQr: true,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                "Account m/87'/1'/0'. Goes in the wizard's "
                '"Cosigner Liquid key (BIP87)" field. A separate account from '
                'the Bitcoin key — it cannot be computed from it, so a '
                'co-signer has to send both.',
                style: caption,
              ),
            ],
            if (_liquidCosignerXpub == null && _cosignerXpub != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                'No Liquid key for this wallet, so it can only join a '
                'Bitcoin-only multisig.',
                style: caption,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// The cosigner keys, one block each.
  ///
  /// A phone reads a cosigner key exactly like the descriptors in the card
  /// above it: the shared [CodeBox] brings the inset-grey surface, the 48 dp
  /// copy target and the measured "Show all" toggle, none of which the
  /// hand-rolled [_CosignerKeyRow] has. The desktop keeps [_CosignerKeyRow]
  /// verbatim so nothing moves there.
  List<Widget> _cosignerKeyBlocks({required bool phone, required int codeLines}) {
    final keys = _info!.cosignerKeys;
    if (!phone) {
      return [
        for (final e in keys.asMap().entries)
          _CosignerKeyRow(index: e.key + 1, key_: e.value),
      ];
    }
    return [
      for (var i = 0; i < keys.length; i++) ...[
        if (i > 0) const SizedBox(height: AppSpacing.lg),
        CodeBox(label: 'Key ${i + 1}', value: keys[i], maxLines: codeLines, showQr: true),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Read once: every phone branch below keys off these, and a page this long
    // should not re-ask MediaQuery a dozen times per build.
    final phone = AppLayout.isPhone(context);
    final s = AppScheme.of(context);
    // A phone clips a descriptor at six lines — a whole xpub, or the head of
    // any descriptor — so CodeBox's own measured "Show all" toggle can fire.
    // The old cap of 40 meant nothing ever overflowed: the toggle was dead
    // code and the export buttons sat far below the fold.
    final codeLines = phone ? 6 : 4;
    // Between cards: the 16 the Settings and Dashboard groups use on a phone,
    // the desktop 24 otherwise. One instance reused down the list — a widget
    // is configuration, not identity.
    final gap = SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xl);
    // Defined once so the phone column and the desktop Wrap can never drift
    // apart on label, glyph or order. isFullWidth is false off a phone, which
    // is the desktop default, so the desktop subtree is unchanged.
    Widget exportBtn(String label, IconData icon, VoidCallback onPressed) =>
        SecondaryButton(
          label: label,
          icon: icon,
          onPressed: onPressed,
          isFullWidth: phone,
        );
    return Scaffold(
      body: PageBackground.flat(
        child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _info == null
          ? _LoadError(
              message: _error ?? 'Could not load wallet details.',
              onRetry: () {
                setState(() { _loading = true; _error = null; });
                _load();
              },
            )
          : ListView(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              children: [
                // The phone shell's header already says "Wallet info" with
                // the arrow back to Settings.
                if (!phone)
                  const PageHeader(
                      title: 'Wallet Info',
                      subtitle: 'Keys and descriptors'),
                // Identity — six label/value readouts, the one real list on
                // the page. A phone rules them with the same s.edge hairline
                // ListCard uses between its rows, so this card reads like the
                // Settings and Dashboard groups; the desktop keeps the theme
                // divider (null colour = fall through to the theme).
                SectionCard(
                  title: 'Identity',
                  child: Column(
                    children: [
                      CopyRow(label: 'Wallet name', value: _info!.name, mono: false, showQr: true),
                      Divider(height: 1, color: phone ? s.edge : null),
                      CopyRow(label: 'Network', value: _info!.network, mono: false, showQr: true),
                      Divider(height: 1, color: phone ? s.edge : null),
                      CopyRow(
                        label: 'Liquid network',
                        value: _info!.liquidNetwork,
                        mono: false,
                        showQr: true,
                      ),
                      Divider(height: 1, color: phone ? s.edge : null),
                      CopyRow(label: 'Master fingerprint', value: _info!.masterFingerprint, showQr: true),
                      Divider(height: 1, color: phone ? s.edge : null),
                      CopyRow(label: 'Derivation path', value: _info!.derivationPath, showQr: true),
                      Divider(height: 1, color: phone ? s.edge : null),
                      CopyRow(label: 'Script type', value: _info!.scriptType, mono: false, showQr: true),
                    ],
                  ),
                ),
                gap,
                // No backup card here. This page is the public face of the
                // wallet — descriptors and xpubs, safe to copy and hand to a
                // co-signer. Seed state belongs with the seed tools, in
                // Settings, behind the reveal gate; a "Seed: Available" row
                // next to an Export button trains the user to look for secrets
                // on the page they screen-share.
                // Bitcoin descriptors
                SectionCard(
                  title: 'Bitcoin Descriptors',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_info!.xpub.isNotEmpty) ...[
                        CodeBox(
                          // Named by its account, not just "XPUB": on a
                          // singlesig wallet this is m/84'/1'/0', and handing
                          // it to a co-signer builds a multisig nobody can
                          // spend. The cosigner section below has the key
                          // that belongs in the wizard.
                          label: 'XPUB · ${_info!.derivationPath}',
                          value: _info!.xpub,
                          maxLines: codeLines,
                          showQr: true,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _isMultisigWallet
                              ? 'This wallet\'s own account key.'
                              : 'This wallet\'s singlesig account key — not a '
                                  'cosigner key. To join a multisig, hand over '
                                  'the two keys below.',
                          style: AppTypography.caption
                              .copyWith(color: phone ? s.inkSecondary : null),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      CodeBox(label: 'Receive descriptor', value: _info!.receiveDescriptor, maxLines: codeLines, showQr: true),
                      if (_info!.multipathDescriptor != null) ...[
                        const SizedBox(height: AppSpacing.lg),
                        CodeBox(label: 'Multipath descriptor', value: _info!.multipathDescriptor!, maxLines: codeLines, showQr: true),
                      ],
                    ],
                  ),
                ),
                // Only a singlesig wallet joins someone else's multisig; a
                // multisig already lists the keys it is built from below.
                if (_isSinglesigWallet) ...[
                  gap,
                  _asACosignerCard(phone: phone, codeLines: codeLines),
                ],
                if (_info!.cosignerKeys.isNotEmpty) ...[
                  gap,
                  SectionCard(
                    // Named for what they are — the keys this wallet is BUILT
                    // from — so they are not confused with the keys a
                    // singlesig wallet GIVES to someone else.
                    title: 'Cosigner Keys in this wallet',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Each key in [fingerprint/derivation-path]xpub format',
                          // caption bakes in the light-mode secondary ink, so
                          // on a dark phone it reads muddy; a null colour in
                          // copyWith leaves the desktop style untouched.
                          style: AppTypography.caption
                              .copyWith(color: phone ? s.inkSecondary : null),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        ..._cosignerKeyBlocks(phone: phone, codeLines: codeLines),
                      ],
                    ),
                  ),
                ],
                if (_info!.liquidDescriptor != null) ...[
                  gap,
                  SectionCard(
                    title: 'Liquid Descriptors',
                    child: Column(
                      children: [
                        CodeBox(label: 'CT descriptor', value: _info!.liquidDescriptor!, maxLines: codeLines, showQr: true),
                        if (_info!.masterBlindingKey != null) ...[
                          const SizedBox(height: AppSpacing.lg),
                          CodeBox(label: 'Master blinding key', value: _info!.masterBlindingKey!, maxLines: codeLines, showQr: true),
                        ],
                      ],
                    ),
                  ),
                ] else if (_canEnableLiquidFromSeed) ...[
                  gap,
                  SectionCard(
                    title: 'Liquid Network',
                    subtitle: 'Not set up for this wallet yet',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'The same recovery phrase derives a Liquid wallet: '
                          'confidential L-BTC and Liquid assets, nothing extra '
                          'to back up. Wallets restored before Templar asked '
                          'this question came back Bitcoin-only — turning it '
                          'on here adds the Liquid descriptor and leaves the '
                          'Bitcoin side untouched.',
                          style: AppTypography.bodySmall,
                        ),
                        if (_liquidError != null) ...[
                          const SizedBox(height: AppSpacing.md),
                          SelectableText(
                            _liquidError!,
                            style: AppTypography.caption
                                .copyWith(color: AppColors.danger),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        PrimaryButton(
                          label: _addingLiquid
                              ? 'Deriving the Liquid wallet…'
                              : 'Enable Liquid',
                          icon: Icons.water_drop_rounded,
                          onPressed:
                              _addingLiquid ? null : _enableLiquidFromSeed,
                          // The card's one action: a slab across the card on a
                          // phone, the intrinsic desktop button otherwise.
                          isFullWidth: phone,
                        ),
                      ],
                    ),
                  ),
                ] else if (_canAddLiquid) ...[
                  gap,
                  SectionCard(
                    title: 'Liquid Network',
                    subtitle: 'Not set up for this wallet yet',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'A Blockstream Jade can hold the Liquid side of this '
                          'same wallet. Connect it over USB and unlock it: its '
                          'confidential descriptor is read from the device, so '
                          'the Jade can spend from the Liquid wallet too. '
                          'Nothing about the Bitcoin side changes.',
                          style: AppTypography.bodySmall,
                        ),
                        if (_liquidError != null) ...[
                          const SizedBox(height: AppSpacing.md),
                          SelectableText(
                            _liquidError!,
                            style: AppTypography.caption
                                .copyWith(color: AppColors.danger),
                          ),
                        ],
                        const SizedBox(height: AppSpacing.lg),
                        PrimaryButton(
                          label: _addingLiquid
                              ? 'Reading from the device…'
                              : 'Add Liquid from my Jade',
                          icon: Icons.water_drop_rounded,
                          onPressed: _addingLiquid ? null : _addLiquid,
                          isFullWidth: phone,
                        ),
                      ],
                    ),
                  ),
                ],
                gap,
                // For other apps
                SectionCard(
                  title: 'For other apps',
                  subtitle: 'Export for Sparrow, Specter, BlueWallet, Jade, SeedSigner',
                  // Three intrinsic pills reflow into a ragged 2 + 1 grid on a
                  // 360 dp screen. A phone stacks them full-width instead, one
                  // action per line; the desktop keeps the Wrap.
                  child: phone
                      ? Column(
                          children: [
                            exportBtn(
                                'Copy descriptor bundle', Icons.copy, _copyBundle),
                            const SizedBox(height: AppSpacing.md),
                            exportBtn('Export JSON', Icons.download_outlined,
                                _exportJson),
                            const SizedBox(height: AppSpacing.md),
                            exportBtn('Show QR', Icons.qr_code, _showQr),
                          ],
                        )
                      : Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            exportBtn(
                                'Copy descriptor bundle', Icons.copy, _copyBundle),
                            exportBtn('Export JSON', Icons.download_outlined,
                                _exportJson),
                            exportBtn('Show QR', Icons.qr_code, _showQr),
                          ],
                        ),
                ),
              ],
            ),
      ),
    );
  }

}

// ── Load failure ──────────────────────────────────────────────────────────────

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Center(
      // A phone never binds the 480 dp cap, so without this the error card
      // runs edge to edge with no page gutter. On desktop the cap still binds
      // inside the centred column, so the padding changes nothing there.
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: GlassCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 40, color: s.danger),
                const SizedBox(height: AppSpacing.md),
                Text('Could not load wallet details',
                    style: AppTypography.sectionTitle),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                PrimaryButton(
                    label: 'Retry', onPressed: onRetry, isFullWidth: phone),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CosignerKeyRow extends StatefulWidget {
  const _CosignerKeyRow({required this.index, required this.key_});
  final int index;
  final String key_;

  @override
  State<_CosignerKeyRow> createState() => _CosignerKeyRowState();
}

class _CosignerKeyRowState extends State<_CosignerKeyRow> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.key_));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Key ${widget.index}', style: AppTypography.label),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.codeBoxBgDark : AppColors.codeBoxBg,
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    border: Border.all(
                      color: isDark ? AppColors.codeBoxBorderDark : AppColors.codeBoxBorder,
                    ),
                  ),
                  child: SelectableText(
                    widget.key_,
                    style: AppTypography.monoSmall,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
                onPressed: _copy,
                tooltip: _copied ? 'Copied!' : 'Copy',
                color: _copied ? AppColors.success : (isDark ? AppColors.textMutedDark : AppColors.textMuted),
              ),
              IconButton(
                icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                onPressed: () => showValueQr(
                  context,
                  title: 'Key ${widget.index}',
                  value: widget.key_,
                ),
                tooltip: 'Show QR',
                color: isDark ? AppColors.textMutedDark : AppColors.textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
