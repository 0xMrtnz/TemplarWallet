import 'dart:math';

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../features/wallet_picker/models/wallet_summary.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/choice_list.dart';
import '../../shared/widgets/hex_text.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/scan_button.dart';
import '../../shared/widgets/step_flow_scaffold.dart';
import '../../shared/widgets/step_header.dart';
import '../../shared/widgets/wallet_created_view.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../services/udev_installer.dart';
import '../hardware/device_permission_card.dart';
import '../hardware/hw_error.dart';
import '../hardware/hwi_install_card.dart';
import 'models/hw_device.dart';
import '../../services/cosigner_label_store.dart';
import '../../shared/models/cosigner_label.dart';
import '../../shared/widgets/cosigner_label_editor.dart';
import 'models/new_wallet_draft.dart';

/// Ordered stages of the wizard. Coordinator paths (watch-only and hardware)
/// skip the seed/backup/verify steps — no key is generated on this computer.
enum _Stage { threshold, seedLength, backup, verify, importKeys, review, success }

/// Where a co-signer key comes from. The creator's own key (co-signer role)
/// is generated in-flow and is never one of these.
///
/// [newKey] and [seedPhrase] both produce a *private* key this wallet holds:
/// several local keys can live in one multisig, and a single sign action signs
/// with all of them.
enum _ImportSource { paste, appWallet, hardware, newKey, seedPhrase }

class _ImportSlot {
  _ImportSource source = _ImportSource.paste;
  final TextEditingController pasteCtrl = TextEditingController();

  /// The co-signer's BIP87 key, typed in when the source is a paste. Liquid
  /// lives on a different account than Bitcoin (m/87'/1'/0' vs
  /// m/48'/1'/0'/2'), so a remote co-signer sends two keys — neither can be
  /// computed from the other.
  final TextEditingController liquidPasteCtrl = TextEditingController();

  /// 12/24 words typed by the user ([_ImportSource.seedPhrase]).
  final TextEditingController seedCtrl = TextEditingController();

  /// Resolved keyorigin xpub for every non-paste source. Paste uses
  /// [pasteCtrl].
  String? xpub;

  /// Resolved BIP87 key for every non-paste source: derived locally for keys
  /// whose seed is here, read from the device for a Jade.
  String? liquidXpub;

  /// Registry ID when the key comes from a software wallet in the app.
  String? walletId;

  /// Sign with this key from the app. Always true for keys whose seed lives
  /// here ([newKey] / [seedPhrase]); opt-in for an app wallet's key.
  bool signsLocally = true;

  /// Device model when the key was read from USB.
  String? hwModel;

  /// Seed of a private key held by this wallet (generated or imported).
  /// It is passed to the backend as a local signing key.
  List<String>? mnemonic;

  /// What the engine made of the pasted/scanned Bitcoin key, and of the
  /// Liquid one. Null while the field is empty or still being checked.
  CosignerKeyInfo? keyInfo;
  CosignerKeyInfo? liquidKeyInfo;

  /// Why the engine cannot use what is in the field. A wallet built on a key
  /// like this saves and then never opens again, so the wizard refuses to
  /// carry it forward.
  String? keyError;
  String? liquidKeyError;

  /// A check is in flight for this slot.
  bool checking = false;

  /// What this co-signer will be called. Held here until the wallet exists —
  /// labels are keyed by fingerprint, and the creator's own key has no
  /// fingerprint to key on until the backend answers.
  CosignerLabel label = const CosignerLabel(id: '');

  /// Drop every verdict about the pasted keys — call whenever the text or the
  /// source changes, so a stale tick can never stand next to a new key.
  void clearKeyChecks() {
    keyInfo = null;
    liquidKeyInfo = null;
    keyError = null;
    liquidKeyError = null;
  }

  /// The user confirmed they wrote the generated words down.
  bool backedUp = false;

  void dispose() {
    pasteCtrl.dispose();
    liquidPasteCtrl.dispose();
    seedCtrl.dispose();
  }

  /// True when this slot holds a private key the app will sign with.
  bool get isLocalKey =>
      (source == _ImportSource.newKey || source == _ImportSource.seedPhrase)
          ? mnemonic != null
          : source == _ImportSource.appWallet &&
              walletId != null &&
              signsLocally;

  /// A generated key must be written down before the flow can continue.
  bool get isReady =>
      source == _ImportSource.newKey ? (mnemonic != null && backedUp) : true;

  /// The key this slot contributes. A checked paste contributes the engine's
  /// normalized form — a scanned air-gap export is a whole descriptor as it
  /// arrives, and only the reduced key can go in a multisig descriptor.
  String get resolvedXpub => source == _ImportSource.paste
      ? (keyInfo?.normalized ?? pasteCtrl.text.trim())
      : (xpub ?? '');

  String get resolvedLiquidXpub => source == _ImportSource.paste
      ? (liquidKeyInfo?.normalized ?? liquidPasteCtrl.text.trim())
      : (liquidXpub ?? '');

  /// True when a pasted key has been checked and refused. Such a slot blocks
  /// the step: the failure it causes is otherwise invisible until the finished
  /// wallet fails to open.
  bool get hasKeyProblem =>
      source == _ImportSource.paste &&
      (keyError != null || liquidKeyError != null);

  /// True when the key was read from a device that is not a Jade.
  ///
  /// Such a key rules Liquid out for the whole wallet: those devices cannot
  /// sign an Elements transaction, and they have no BIP87 Liquid key worth
  /// putting in the descriptor either.
  bool get isBitcoinOnlyDevice =>
      source == _ImportSource.hardware &&
      !(hwModel ?? '').toLowerCase().contains('jade');

  /// Whether this key can be expected to sign on Liquid. A pasted key is
  /// unknowable — its owner may hold a Jade or a software wallet — so it
  /// counts as capable and the review step says so plainly.
  bool get liquidCapable => !isBitcoinOnlyDevice;
}

class MultisigSetupScreen extends StatefulWidget {
  const MultisigSetupScreen({
    super.key,
    this.baseStep = 0,
    this.onBackToWizard,
    this.bridge,
  });

  /// Questions already answered by the wizard hosting this setup —
  /// the step counter continues from here instead of restarting at 1.
  final int baseStep;

  /// Back from the first step: return to the wizard's last question.
  /// Null (standalone route) falls back to navigating there.
  final VoidCallback? onBackToWizard;

  /// Test seam: the engine this setup talks to. Null in the app, which then
  /// uses the process-wide [walletBridge] (same shape as WalletInfoScreen).
  final WalletBridge? bridge;

  @override
  State<MultisigSetupScreen> createState() => _MultisigSetupScreenState();
}

class _MultisigSetupScreenState extends State<MultisigSetupScreen> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;
  // Named for what it is: a watch-only coordinator arrives here from the
  // watch-only setup, and "My Multisig Wallet" is not what that user is making.
  late final _nameController = TextEditingController(
    text: newWalletDraft.path == WalletPath.watchOnly
        ? 'Watch-only Multisig'
        : 'My Multisig Wallet',
  );

  int _stageIndex = 0;

  int _m = 2; // required signatures
  int _n = 3; // total keys

  /// A watch-only wallet imports every xpub and can never sign. The wizard
  /// answers this one; everything else about where the keys live is answered
  /// per key on the import step.
  bool get _isWatchOnly => newWalletDraft.path == WalletPath.watchOnly;

  /// Whether one of the N keys is generated here, in-flow, before the others
  /// are imported — asked on the threshold step, not by the wizard, because
  /// it is a fact about *this* wallet's keys and not about the app.
  ///
  /// Off does not mean "no key here": any import slot can still be set to
  /// "New key" or "Seed phrase" and hold a private key. It only decides
  /// whether the guided create-and-back-up-a-key steps come first.
  bool _holdsKey = false;

  /// The coins answer from the wizard: Bitcoin only, or Bitcoin + Liquid.
  final bool _liquidWanted = newWalletDraft.liquidActive;

  /// True when no key is generated in-flow: all N keys are imported. Slots
  /// can still hold private keys unless this is a watch-only wallet.
  bool get _isCoordinator => _isWatchOnly || !_holdsKey;

  // ── Creator key (co-signer role only — generated like a software wallet) ────
  int _seedLength = 24;
  List<String>? _creatorMnemonic;
  String? _creatorXpub;

  /// The creator key's BIP87 counterpart, derived alongside it.
  String? _creatorLiquidXpub;
  bool _generatingKey = false;
  List<int> _challengeIndexes = [];
  final _challengeAnswers = <int, String>{};

  // ── Imported keys (N-1 for co-signer, N for watch-only) ─────────────────────
  List<_ImportSlot> _importSlots = [];
  List<WalletSummary> _appWallets = [];

  bool _busy = false;
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    for (final s in _importSlots) {
      s.dispose();
    }
    super.dispose();
  }

  // ── Stage model ─────────────────────────────────────────────────────────────

  /// Stages for the active role. Coordinators drop the three seed-key steps.
  List<_Stage> get _stages => _isCoordinator
      ? const [_Stage.threshold, _Stage.importKeys, _Stage.review, _Stage.success]
      : const [
          _Stage.threshold,
          _Stage.seedLength,
          _Stage.backup,
          _Stage.verify,
          _Stage.importKeys,
          _Stage.review,
          _Stage.success,
        ];

  _Stage get _stage => _stages[_stageIndex];

  /// Which import slot is open. The keys used to be a scroll of N fully
  /// expanded cards — every source picker, every field, all at once, for a
  /// step where the user works on exactly one key at a time. One card is open,
  /// the others collapse to a line saying whether they are filled, so the list
  /// still answers "how far am I" at a glance.
  int _expandedSlot = 0;

  void _goTo(_Stage s) => setState(() => _stageIndex = _stages.indexOf(s));
  void _back() => setState(() { if (_stageIndex > 0) _stageIndex--; });

  /// Back out of the setup: to the hosting wizard when embedded, otherwise
  /// to the wizard route (standalone entry).
  void _exitToWizard() {
    final cb = widget.onBackToWizard;
    if (cb != null) {
      cb();
    } else {
      context.go(AppRoutes.walletType);
    }
  }

  // ── Flow logic ────────────────────────────────────────────────────────────

  List<int> _pickChallengeIndexes(int length) {
    final rng = Random.secure();
    final third = length ~/ 3;
    return [
      rng.nextInt(third),
      third + rng.nextInt(third),
      2 * third + rng.nextInt(length - 2 * third),
    ];
  }

  /// Leaving the threshold step: branch on the role.
  Future<void> _advanceFromThreshold() async {
    if (_isCoordinator) {
      if (await _prepareImports(_n)) _goTo(_Stage.importKeys);
    } else {
      _goTo(_Stage.seedLength);
    }
  }

  /// Generate the creator's key (co-signer role) and move to the back-up step.
  Future<void> _generateCreatorKey() async {
    setState(() { _generatingKey = true; _error = null; });
    try {
      final words = await _bridge.generateMnemonic(_seedLength);
      final xpub = await _bridge.deriveCosignerXpub(words);
      // Both accounts come from this one seed, so the Liquid key costs the
      // user nothing to provide — only a remote co-signer is ever asked twice.
      final liquidXpub =
          _liquidWanted ? await _bridge.deriveLiquidCosignerXpub(words) : null;
      final idxs = _pickChallengeIndexes(words.length);
      if (mounted) {
        setState(() {
          _creatorMnemonic = words;
          _creatorXpub = xpub;
          _creatorLiquidXpub = liquidXpub;
          _challengeIndexes = idxs;
          _challengeAnswers.clear();
          _generatingKey = false;
        });
        _goTo(_Stage.backup);
      }
    } catch (e) {
      if (mounted) setState(() { _generatingKey = false; _error = e.toString(); });
    }
  }

  /// Check the back-up challenge, then prepare the N-1 import slots.
  Future<void> _verifyAndContinue() async {
    final mnemonic = _creatorMnemonic!;
    final correct = _challengeIndexes.every(
      (i) => (_challengeAnswers[i] ?? '').toLowerCase().trim() == mnemonic[i],
    );
    if (!correct) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('One or more words are incorrect. Check your backup and try again.'),
        ),
      );
      return;
    }
    if (await _prepareImports(_n - 1)) _goTo(_Stage.importKeys);
  }

  /// Build [count] import slots and load app wallets that can lend a key.
  /// Returns false (and sets [_error]) on failure.
  Future<bool> _prepareImports(int count) async {
    setState(() { _busy = true; _error = null; });
    try {
      final wallets = await _bridge.listWallets();
      _appWallets = wallets
          .where((w) =>
              w.type == WalletType.singlesig &&
              !w.isWatchOnly &&
              !w.isHardwareWallet &&
              !w.isAirgapWallet)
          .toList();
      // Keep typed values if the count is unchanged; otherwise rebuild.
      if (_importSlots.length != count) {
        for (final s in _importSlots) {
          s.dispose();
        }
        _importSlots = List.generate(count, (_) => _ImportSlot());
      }
      if (mounted) setState(() => _busy = false);
      return true;
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.toString(); });
      return false;
    }
  }

  Future<void> _pickAppWallet(_ImportSlot slot, String walletId) async {
    setState(() => _busy = true);
    try {
      final xpub = await _bridge.getCosignerXpub(walletId);
      final liquidXpub =
          _liquidWanted ? await _bridge.getLiquidCosignerXpub(walletId) : null;
      slot.walletId = walletId;
      slot.xpub = xpub;
      slot.liquidXpub = liquidXpub;
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.toString(); });
    }
  }

  /// Read a BIP48 cosigner xpub from a USB device: enumerate, let the user
  /// pick if several are connected, then fetch. A missing HWI toolkit opens
  /// the installer instead of a raw error.
  Future<void> _fetchHwXpub(_ImportSlot slot) async {
    setState(() { _busy = true; _error = null; });
    try {
      final devices = await _bridge.enumerateHwDevices();
      if (!mounted) return;
      if (devices.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'No USB device found. Connect it, unlock it, and open the '
              'Bitcoin Testnet app (Ledger).';
        });
        return;
      }
      HwDevice? device = devices.length == 1 ? devices.first : null;
      device ??= await showDialog<HwDevice>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Choose a device'),
          children: [
            for (final d in devices)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(d),
                child: Text('${d.model} (${d.fingerprint})'),
              ),
          ],
        ),
      );
      if (device == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final xpub = await _bridge.getHwCosignerXpub(device.fingerprint);
      // A Jade also holds a Liquid key; every other device is Bitcoin-only in
      // firmware, so there is nothing to ask it for. The read is fenced off on
      // its own: a Liquid key that cannot be read turns Liquid off for the
      // wallet, it does not throw away the Bitcoin key already in hand.
      String? liquidXpub;
      String? liquidError;
      final isJade = device.model.toLowerCase().contains('jade');
      if (_liquidWanted && isJade) {
        try {
          liquidXpub = await _bridge.getJadeLiquidCosignerXpub(
            expectFingerprint: device.fingerprint,
          );
        } catch (e) {
          liquidError = 'Bitcoin key read, but the Jade did not return its '
              'Liquid key: ${classifyHwError(e).message}';
        }
      }
      if (mounted) {
        setState(() {
          slot.xpub = xpub;
          slot.liquidXpub = liquidXpub;
          slot.hwModel = device!.model;
          slot.walletId = null;
          // Read over USB, so it signs over USB: the co-signing sheet offers
          // the device for this key.
          slot.label = slot.label.copyWith(hardware: true);
          // A Jade is a shield, anything else on USB is a USB stick — until
          // the user says otherwise.
          if (slot.label.iconId == null || slot.label.iconId == 'usb') {
            slot.label = slot.label.copyWith(
              iconId: suggestedIconFor(
                fromDevice: true,
                fromAppWallet: false,
                isLocalSeed: false,
                deviceModel: device.model,
              ),
            );
          }
          // And it names itself, if nothing else has.
          if ((slot.label.name?.trim().isEmpty ?? true) &&
              device.model.isNotEmpty) {
            slot.label = slot.label.copyWith(name: device.model);
          }
          _busy = false;
          _error = liquidError;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final failure = classifyHwError(e);
      if (failure.isHwiMissing) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('HWI toolkit required'),
            content: SizedBox(
              width: 460,
              child: HwiInstallCard(
                onInstalled: () {
                  Navigator.of(ctx).pop();
                  _fetchHwXpub(slot);
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
      } else if (failure.isPermission && UdevInstaller.supported) {
        // Linux: enrolling a device key hits the same udev wall as every
        // other device call, and deserves the same one-click fix.
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Device access blocked'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: DevicePermissionCard(
                  detail: failure.message,
                  onFixed: () {
                    Navigator.of(ctx).pop();
                    _fetchHwXpub(slot);
                  },
                ),
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
      } else {
        setState(() => _error = failure.message);
      }
    }
  }

  /// Generate a brand-new private key for this slot: the seed is kept by the
  /// wallet (it becomes another local signing key) and must be written down.
  Future<void> _generateSlotKey(_ImportSlot slot) async {
    setState(() { _busy = true; _error = null; });
    try {
      final words = await _bridge.generateMnemonic(24);
      final xpub = await _bridge.deriveCosignerXpub(words);
      final liquidXpub =
          _liquidWanted ? await _bridge.deriveLiquidCosignerXpub(words) : null;
      if (mounted) {
        setState(() {
          slot.mnemonic = words;
          slot.xpub = xpub;
          slot.liquidXpub = liquidXpub;
          slot.backedUp = false;
          slot.signsLocally = true;
          slot.walletId = null;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.toString(); });
    }
  }

  /// Adopt an existing 12/24-word seed as another private key of this wallet.
  Future<void> _useSlotSeed(_ImportSlot slot) async {
    final words = slot.seedCtrl.text
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.length != 12 && words.length != 24) {
      setState(() => _error = 'A seed phrase has 12 or 24 words (got ${words.length}).');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      // The backend validates the checksum while deriving.
      final xpub = await _bridge.deriveCosignerXpub(words);
      final liquidXpub =
          _liquidWanted ? await _bridge.deriveLiquidCosignerXpub(words) : null;
      if (mounted) {
        setState(() {
          slot.mnemonic = words;
          slot.xpub = xpub;
          slot.liquidXpub = liquidXpub;
          slot.signsLocally = true;
          slot.walletId = null;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
  }

  /// All N keys. Co-signer role puts its generated key first.
  List<String> get _allXpubs => _isCoordinator
      ? _importSlots.map((s) => s.resolvedXpub).toList()
      : [_creatorXpub ?? '', ..._importSlots.map((s) => s.resolvedXpub)];

  /// The same N co-signers' Liquid (BIP87) keys, in the same order — the
  /// descriptor's key order is part of the wallet, so the two lists must line
  /// up index for index.
  List<String> get _allLiquidXpubs => _isCoordinator
      ? _importSlots.map((s) => s.resolvedLiquidXpub).toList()
      : [
          _creatorLiquidXpub ?? '',
          ..._importSlots.map((s) => s.resolvedLiquidXpub),
        ];

  /// Keys that can be expected to sign on Liquid. The creator's own key always
  /// can; a key read from a Bitcoin-only device never can.
  int get _liquidCapableKeys =>
      (_isCoordinator ? 0 : 1) +
      _importSlots.where((s) => s.liquidCapable).length;

  /// A key that rules Liquid out no matter what else is filled in.
  _ImportSlot? get _bitcoinOnlyDeviceSlot {
    for (final s in _importSlots) {
      if (s.isBitcoinOnlyDevice) return s;
    }
    return null;
  }

  /// Why Liquid cannot be part of this wallet, or null when it can.
  ///
  /// Only reasons the user can act on — a missing key is not one of them, that
  /// is just an unfinished form.
  String? get _liquidBlockedReason {
    if (!_liquidWanted) return null;
    final device = _bitcoinOnlyDeviceSlot;
    if (device != null) {
      return 'Key from ${device.hwModel ?? 'this device'} is Bitcoin-only. '
          'Ledger, Trezor, Coldcard and KeepKey cannot sign Liquid '
          'transactions, and hold no Liquid key to enrol — so this wallet '
          'will be Bitcoin-only. Use a Blockstream Jade, or a key held in '
          'this app, for a wallet that also holds Liquid.';
    }
    if (_liquidCapableKeys < _m) {
      return 'Only $_liquidCapableKeys of the $_n keys could sign on Liquid, '
          'but $_m signatures are required. Liquid funds would be '
          'unspendable, so this wallet will be Bitcoin-only.';
    }
    return null;
  }

  /// Whether a Liquid side is still on the table for this wallet.
  bool get _liquidPossible => _liquidWanted && _liquidBlockedReason == null;

  /// Whether the Liquid side is fully specified and will actually be built.
  bool get _liquidReady {
    if (!_liquidPossible) return false;
    final keys = _allLiquidXpubs;
    if (keys.length != _n || keys.any((k) => k.isEmpty)) return false;
    return keys.toSet().length == keys.length;
  }

  /// Every key resolved, no duplicates, and every generated key backed up.
  /// With Liquid in play the same holds for the BIP87 keys — a half-filled
  /// Liquid column would silently create a Bitcoin-only wallet.
  bool get _importsComplete {
    final all = _allXpubs;
    if (all.length != _n || all.any((x) => x.isEmpty)) return false;
    if (_importSlots.any((s) => !s.isReady)) return false;
    if (all.toSet().length != all.length) return false;
    if (_liquidPossible && !_liquidReady) return false;
    return true;
  }

  /// Keys this app will sign with: the creator key plus every slot holding a
  /// private key (generated, imported seed, or an opted-in app wallet).
  int get _localKeyCount =>
      (_isCoordinator ? 0 : 1) + _importSlots.where((s) => s.isLocalKey).length;

  /// The creator's own generated key (co-signer role only) — key 1, which has
  /// no import slot to hold its label.
  var _creatorLabel = const CosignerLabel(id: '');

  /// Writes the labels once the wallet exists and its keys have fingerprints
  /// to key on. Nothing here can fail the creation: a wallet without names is
  /// a wallet, a name without a wallet is nothing.
  Future<void> _saveLabels(String walletId, List<String> cosignerKeys) async {
    final labels = <String, CosignerLabel>{};
    final ordered = _isCoordinator
        ? [for (final s in _importSlots) s.label]
        : [_creatorLabel, for (final s in _importSlots) s.label];
    for (var i = 0; i < cosignerKeys.length && i < ordered.length; i++) {
      final id = cosignerId(cosignerKeys, i);
      final label = ordered[i].copyWith();
      if (!label.isEmpty) {
        labels[id] = CosignerLabel(
          id: id,
          name: label.name,
          iconId: label.iconId,
          colorValue: label.colorValue,
          hardware: label.hardware,
        );
      }
    }
    if (labels.isEmpty) return;
    try {
      await CosignerLabelStore.instance.save(walletId, labels);
    } catch (_) {
      // Names are a convenience; losing them must never look like a failed
      // wallet creation.
    }
  }

  Future<void> _create() async {
    setState(() { _creating = true; _error = null; });
    try {
      // Collect every local signing key: the generated creator key, keys whose
      // seed lives in this wallet, and app wallets the user opted in — one
      // sign pass covers them all.
      final localMnemonics = <String>[];
      if (!_isCoordinator && _creatorMnemonic != null) {
        localMnemonics.add(_creatorMnemonic!.join(' '));
      }
      // A watch-only wallet never signs from this computer — keep the local
      // key list empty so the backend creates a watch-only coordinator.
      if (!_isWatchOnly) {
        for (final s in _importSlots) {
          if (!s.isLocalKey) continue;
          if (s.mnemonic != null) {
            localMnemonics.add(s.mnemonic!.join(' '));
          } else if (s.walletId != null) {
            final words = await _bridge.getMnemonic(s.walletId!);
            localMnemonics.add(words.join(' '));
          }
        }
      }

      final wallet = await _bridge.createMultisigWallet(
        name: _nameController.text.trim(),
        requiredSigs: _m,
        totalSigners: _n,
        cosignerXpubs: _allXpubs,
        localMnemonics: localMnemonics.isEmpty ? null : localMnemonics,
        // Empty unless every co-signer's Liquid key is in hand: the backend
        // treats a short list as an error rather than quietly building a
        // weaker wallet.
        liquidXpubs: _liquidReady ? _allLiquidXpubs : const [],
        liquidCapableKeys: _liquidReady ? _liquidCapableKeys : null,
      );
      await _saveLabels(wallet.id, _allXpubs);
      if (mounted) {
        context.read<AppState>().setActiveWallet(
          wallet.id,
          name: wallet.name,
          type: 'Multisig',
          // From the summary the backend returned, not from what was asked
          // for: a Liquid side the backend declined to build must not leave
          // the app showing Liquid screens with nothing behind them.
          liquid: wallet.liquidEnabled,
        );
        setState(() => _creating = false);
        _goTo(_Stage.success);
      }
    } catch (e) {
      if (mounted) setState(() { _creating = false; _error = e.toString(); });
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StepFlowScaffold(
      currentStep: widget.baseStep + _stageIndex + 1,
      totalSteps: widget.baseStep + _stages.length,
      title: _stageTitle,
      subtitle: _stageSubtitle,
      onBack: _stage == _Stage.success
          ? null
          : (_stageIndex > 0 ? _back : _exitToWizard),
      onCancel: _stage != _Stage.success
          ? () => context.go(AppRoutes.walletPicker)
          : null,
      // No Liquid banner here any more: the wizard's coins question is asked
      // *after* the structure question and states outright that multisig is
      // Bitcoin-only, so by this point it has already been answered rather
      // than contradicted.
      banner: null,
      headerVariants: [
        for (final stage in _Stage.values)
          StepHeaderVariant(_titleOfStage(stage), _subtitleOfStage(stage)),
        // Both wordings of the import step, for the reason on [_importSubtitle].
        StepHeaderVariant(
            _titleOfStage(_Stage.importKeys), _importSubtitle(true)),
        StepHeaderVariant(
            _titleOfStage(_Stage.importKeys), _importSubtitle(false)),
      ],
      body: _stageBody(isDark),
      actions: _stageActions,
    );
  }

  String get _stageTitle => _titleOfStage(_stage);

  String _titleOfStage(_Stage stage) => switch (stage) {
        _Stage.threshold => 'Choose your threshold',
        _Stage.seedLength => 'Create your key',
        _Stage.backup => 'Back up your key',
        _Stage.verify => 'Verify your backup',
        _Stage.importKeys => 'Import the keys',
        _Stage.review => 'Review & create',
        _Stage.success => 'Multisig wallet created',
      };

  String get _stageSubtitle => _subtitleOfStage(_stage);

  String _subtitleOfStage(_Stage stage) => switch (stage) {
        _Stage.threshold => "You'll need $_m keys out of $_n to sign a transaction",
        _Stage.seedLength => 'This key stays on this device so you can sign — choose its seed length',
        _Stage.backup => 'Write these words on paper. They are your key. Shown only once.',
        _Stage.verify => 'Enter the requested words to prove you saved them',
        _Stage.importKeys => _importSubtitle(_isCoordinator),
        _Stage.review => 'Check everything before the wallet is created',
        _Stage.success => '',
      };

  /// The import step's subtitle. Takes the role rather than reading it, so
  /// the header can reserve room for either wording — the toggle that picks
  /// between them sits on the step before, and flipping it must not move the
  /// header under the finger that flipped it.
  String _importSubtitle(bool coordinator) => _isWatchOnly
      ? 'Provide all $_n cosigner keys — paste/scan an xpub, or read one from a USB device'
      : coordinator
          ? 'Provide all $_n keys — an xpub, a USB device, or a private key held here'
          : 'Provide the other ${_n - 1} keys — an xpub, a USB device, or another private key of yours';

  Widget _stageBody(bool isDark) {
    if (_generatingKey) return const _Spinner(label: 'Generating secure key…');
    if (_creating) return const _Spinner(label: 'Creating wallet…');
    return switch (_stage) {
      _Stage.threshold => _thresholdBody(isDark),
      _Stage.seedLength => _seedLengthBody(),
      _Stage.backup => _backupBody(),
      _Stage.verify => _verifyBody(),
      _Stage.importKeys => _importBody(isDark),
      _Stage.review => _summaryBody(isDark),
      _Stage.success => _successBody(),
    };
  }

  Widget get _stageActions {
    if (_generatingKey || _creating) return const SizedBox.shrink();
    if (_stage == _Stage.success) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          PrimaryButton(
            label: 'Open Wallet',
            onPressed: () => context.go(AppRoutes.dashboard),
          ),
        ],
      );
    }
    final (label, enabled, onNext) = switch (_stage) {
      _Stage.threshold => (
          'Continue',
          _nameController.text.trim().isNotEmpty,
          _advanceFromThreshold,
        ),
      _Stage.seedLength => ('Continue', !_generatingKey, _generateCreatorKey),
      _Stage.backup => ('Continue', true, () async => _goTo(_Stage.verify)),
      _Stage.verify => ('Continue', !_busy, _verifyAndContinue),
      _Stage.importKeys => (
          'Continue',
          _importsComplete && !_busy,
          () async => _goTo(_Stage.review),
        ),
      _Stage.review => (_creating ? 'Creating…' : 'Create Wallet', !_creating, _create),
      _Stage.success => ('', false, () async {}),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // Always in the row, so nothing beside it moves between steps.
        GhostButton(
          label: 'Back',
          onPressed: _stageIndex > 0 ? _back : _exitToWizard,
        ),
        const SizedBox(width: AppSpacing.md),
        PrimaryButton(label: label, onPressed: enabled ? () => onNext() : null),
      ],
    );
  }

  // ── Threshold — name + M-of-N ─────────────────────────────────────────────

  Widget _thresholdBody(bool isDark) {
    final phone = AppLayout.isPhone(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Wallet name'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.xl),
        // Two pickers side by side need ~180 dp each; stacked on a phone.
        //
        // Neither arm uses a flexed child in an unbounded axis. The step's
        // body is a scroll view, so on a phone — where the pickers stack —
        // the vertical axis has no bound to divide: a `Flexible` there threw
        // "non-zero flex but incoming height constraints are unbounded" and
        // took the whole step down with it, the phone twin of the desktop
        // `stretch` crash fixed in alpha.8. Plain children stacked, plain
        // Expanded across a bounded width.
        if (phone) ...[
          _NumberPicker(
            label: 'Signatures required (M)',
            value: _m,
            min: 1,
            max: _n,
            onChanged: (v) => setState(() => _m = v),
          ),
          const SizedBox(height: AppSpacing.md),
          _NumberPicker(
            label: 'Total keys (N)',
            value: _n,
            min: 2,
            max: 9,
            onChanged: (v) => setState(() {
              _n = v;
              if (_m > _n) _m = _n;
            }),
          ),
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _NumberPicker(
                  label: 'Signatures required (M)',
                  value: _m,
                  min: 1,
                  max: _n,
                  onChanged: (v) => setState(() => _m = v),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: _NumberPicker(
                  label: 'Total keys (N)',
                  value: _n,
                  min: 2,
                  max: 9,
                  onChanged: (v) => setState(() {
                    _n = v;
                    if (_m > _n) _m = _n;
                  }),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.xl),
        // Where the keys come from is chosen key by key on the import step.
        // The one thing worth settling first is whether this wallet holds one
        // of them itself, because that key is created and backed up before
        // the others are collected.
        _RoleCard(
          n: _n,
          isDark: isDark,
          watchOnly: _isWatchOnly,
          holdsKey: _holdsKey,
          onHoldsKeyChanged: (v) => setState(() => _holdsKey = v),
        ),
        const SizedBox(height: AppSpacing.xl),
        InfoBanner(
          message: 'This will be a $_m-of-$_n wallet: $_n keys exist in total, '
              'and any $_m of them must sign before bitcoin can leave the wallet.',
        ),
      ],
    );
  }

  // ── Seed length for the creator's key ────────────────────────────────────

  Widget _seedLengthBody() {
    return Column(
      children: [
        SelectableOptionCard(
          title: '12 words',
          description: '128 bits of entropy. Standard for most wallets. Easier to back up.',
          isSelected: _seedLength == 12,
          icon: Icons.lock_outline,
          onTap: () => setState(() => _seedLength = 12),
        ),
        const SizedBox(height: AppSpacing.lg),
        SelectableOptionCard(
          title: '24 words',
          description: '256 bits of entropy. Maximum security. Recommended for large holdings.',
          isSelected: _seedLength == 24,
          icon: Icons.security,
          badge: 'Recommended',
          onTap: () => setState(() => _seedLength = 24),
        ),
        const SizedBox(height: AppSpacing.xl),
        const InfoBanner(
          message: 'This is your personal key in the multisig. It works exactly '
              'like a software wallet seed — keep it offline and safe.',
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          WarningBanner(title: 'Key generation failed', message: _error!),
        ],
      ],
    );
  }

  // ── Back up the creator's seed ───────────────────────────────────────────

  Widget _backupBody() {
    final mnemonic = _creatorMnemonic ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const WarningBanner(
          title: 'Write these words down on paper',
          message:
              'Never type or photograph your seed phrase. Anyone who sees it can steal your funds. This is shown only once.',
        ),
        const SizedBox(height: AppSpacing.xl),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisExtent: 44,
            crossAxisSpacing: AppSpacing.sm,
            mainAxisSpacing: AppSpacing.sm,
          ),
          itemCount: mnemonic.length,
          itemBuilder: (context, i) => _WordTile(index: i + 1, word: mnemonic[i]),
        ),
      ],
    );
  }

  // ── Verify the back-up ───────────────────────────────────────────────────

  Widget _verifyBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InfoBanner(
          message:
              'Enter the words at the requested positions to confirm you have them saved.',
        ),
        const SizedBox(height: AppSpacing.xl),
        ..._challengeIndexes.map(
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: TextField(
              decoration: InputDecoration(labelText: 'Word #${i + 1}'),
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              onChanged: (v) => setState(() => _challengeAnswers[i] = v),
            ),
          ),
        ),
      ],
    );
  }

  // ── Import keys ──────────────────────────────────────────────────────────

  /// A slot counts as provided once it has resolved to a key the engine
  /// accepts. A pasted key that has not been checked yet does not count —
  /// "provided" has to mean "will build a wallet that opens".
  bool _slotFilled(_ImportSlot slot) {
    if (slot.resolvedXpub.isEmpty || !slot.isReady) return false;
    if (slot.source != _ImportSource.paste) return true;
    if (slot.keyInfo == null || slot.keyError != null) return false;
    if (_liquidWanted && slot.liquidPasteCtrl.text.trim().isNotEmpty) {
      return slot.liquidKeyInfo != null && slot.liquidKeyError == null;
    }
    return true;
  }

  /// Runs the engine's own key check over a slot's pasted fields.
  ///
  /// The same rules wallet creation applies, run while the user is still
  /// looking at the field: a key that only fails at creation costs the whole
  /// wizard, and one that fails at *open* costs a wallet entry that cannot be
  /// removed from the sidebar.
  Future<void> _checkSlotKeys(_ImportSlot slot) async {
    final btc = slot.pasteCtrl.text.trim();
    final liquid = slot.liquidPasteCtrl.text.trim();
    setState(() {
      slot.checking = true;
      slot.clearKeyChecks();
    });
    try {
      if (btc.isNotEmpty) {
        try {
          slot.keyInfo = await _bridge.validateCosignerKey(btc);
        } catch (e) {
          slot.keyError = _plainError(e);
        }
      }
      if (_liquidWanted && liquid.isNotEmpty) {
        try {
          slot.liquidKeyInfo =
              await _bridge.validateCosignerKey(liquid, liquid: true);
        } catch (e) {
          slot.liquidKeyError = _plainError(e);
        }
      }
    } finally {
      if (mounted) setState(() => slot.checking = false);
    }
  }

  /// Check the slot's keys and, if they hold up, move on to the next one.
  /// The wizard's "Done" for a key placed by hand — every other source
  /// advances on its own once the device or the app has answered.
  Future<void> _confirmSlot(int i) async {
    final slot = _importSlots[i];
    await _checkSlotKeys(slot);
    if (!mounted) return;
    if (_slotFilled(slot)) _advanceFromSlot(i);
  }

  static String _plainError(Object e) =>
      e.toString().replaceFirst('Exception: wallet-ffi: ', '');

  /// After a key lands, open the next one still missing — the step reads as a
  /// queue of keys to collect rather than a wall of identical cards.
  void _advanceFromSlot(int i) {
    for (var j = i + 1; j < _importSlots.length; j++) {
      if (!_slotFilled(_importSlots[j])) {
        setState(() => _expandedSlot = j);
        return;
      }
    }
    setState(() => _expandedSlot = i);
  }

  Widget _importBody(bool isDark) {
    // Co-signer role: Key 1 is the generated key, imports start at Key 2.
    final firstKeyNumber = _isCoordinator ? 1 : 2;
    final filled = _importSlots.where(_slotFilled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('KEYS TO COLLECT',
                style: AppTypography.label.copyWith(letterSpacing: 1.2)),
            const Spacer(),
            Text('$filled of ${_importSlots.length} provided',
                style: AppTypography.caption),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        // Key 1 belongs to this device and never appears as an import slot,
        // so it would be the one key in the wallet that could not be named.
        if (!_isCoordinator) ...[
          Container(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(
                  color: isDark ? AppColors.borderDark : AppColors.borderLight),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Key 1', style: AppTypography.sectionTitle),
                    const SizedBox(width: AppSpacing.sm),
                    Text('your key, on this device',
                        style: AppTypography.caption),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _CosignerNameField(
                  label: _creatorLabel,
                  keyNumber: 1,
                  subtitle: 'Generated here, in this wallet',
                  onChanged: (l) => setState(() => _creatorLabel = l),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        for (var i = 0; i < _importSlots.length; i++) ...[
          if (i == _expandedSlot)
            _ImportSlotCard(
              keyNumber: firstKeyNumber + i,
              slot: _importSlots[i],
              appWallets: _appWallets,
              isDark: isDark,
              allowLocalSigning: !_isWatchOnly,
              liquidWanted: _liquidWanted,
              busy: _busy,
              onSourceChanged: (src) => setState(() {
                final s = _importSlots[i];
                s.source = src;
                s.xpub = null;
                s.liquidXpub = null;
                s.walletId = null;
                s.hwModel = null;
                s.mnemonic = null;
                s.backedUp = false;
                s.clearKeyChecks();
                // Start the icon off at something the source suggests. Only
                // when the user has not picked one — their choice outranks
                // the guess.
                if (s.label.iconId == null) {
                  s.label = s.label.copyWith(
                    iconId: suggestedIconFor(
                      fromDevice: src == _ImportSource.hardware,
                      fromAppWallet: src == _ImportSource.appWallet,
                      isLocalSeed: src == _ImportSource.newKey ||
                          src == _ImportSource.seedPhrase,
                    ),
                  );
                }
                // The source says where the key signs; a hardware slot is
                // flagged outright, any other source drops a stale flag.
                s.label = s.label.copyWith(
                  hardware: src == _ImportSource.hardware ? true : null,
                );
                // A watch-only wallet stays watch-only on this computer,
                // even when an app wallet lends its xpub.
                s.signsLocally = !_isWatchOnly;
              }),
              onAppWalletPicked: (id) async {
                await _pickAppWallet(_importSlots[i], id);
                if (mounted && _slotFilled(_importSlots[i])) _advanceFromSlot(i);
              },
              onFetchHw: () async {
                await _fetchHwXpub(_importSlots[i]);
                if (mounted && _slotFilled(_importSlots[i])) _advanceFromSlot(i);
              },
              onConfirm: () => _confirmSlot(i),
              onLabelChanged: (label) =>
                  setState(() => _importSlots[i].label = label),
              onGenerateKey: () => _generateSlotKey(_importSlots[i]),
              onUseSeed: () async {
                await _useSlotSeed(_importSlots[i]);
                if (mounted && _slotFilled(_importSlots[i])) _advanceFromSlot(i);
              },
              // Any edit invalidates the verdict shown next to it: a tick
              // beside a key that has since been retyped is worse than none.
              onChanged: () => setState(() => _importSlots[i].clearKeyChecks()),
            )
          else
            _CollapsedSlotRow(
              keyNumber: firstKeyNumber + i,
              filled: _slotFilled(_importSlots[i]),
              summary: _slotSummary(_importSlots[i]),
              label: _importSlots[i].label,
              isDark: isDark,
              onTap: () => setState(() => _expandedSlot = i),
            ),
          const SizedBox(height: AppSpacing.md),
        ],
        InfoBanner(
          message: _isWatchOnly
              ? 'Ask each co-signer for their xpub — paste or scan it, read it '
                  'from a USB device, or reuse a software wallet already in '
                  'this app. No key is stored here.'
              : _isCoordinator
                  ? 'Every key is chosen on its own: read over USB, pasted or '
                      'scanned from an air-gapped signer, borrowed from another '
                      'wallet in this app, or created here as "New key" / '
                      '"Seed phrase" — a slot set to either of those is a '
                      'private key this wallet signs with.'
                  : 'Key 1 is the one you just created on this device. Any slot set '
                      'to "New key", "Seed phrase", or an app wallet marked "signs '
                      'from this app" is another private key of this wallet — one '
                      'sign action signs with all of them.',
        ),
        if (_liquidWanted) ...[
          const SizedBox(height: AppSpacing.md),
          if (_liquidBlockedReason != null)
            WarningBanner(
              title: 'Liquid is not available for this wallet',
              message: _liquidBlockedReason!,
            )
          else
            const InfoBanner(
              title: 'Bitcoin + Liquid',
              message: 'Each co-signer contributes two keys: a Bitcoin one '
                  "(m/48'/1'/0'/2') and a Liquid one (m/87'/1'/0'). Keys "
                  'whose seed is in this app, and keys read from a Jade, '
                  'provide both without extra work — only a key pasted from '
                  'someone else has to be sent twice.',
            ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          WarningBanner(title: 'Error', message: _error!),
        ],
      ],
    );
  }

  // ── Summary ──────────────────────────────────────────────────────────────

  Widget _summaryBody(bool isDark) {
    final xpubs = _allXpubs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.cardPadding),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$_m-of-$_n Multisig',
                style: AppTypography.pageTitle.copyWith(color: AppColors.accent),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '$_m keys required to spend · ${_nameController.text.trim()}'
                '${_localKeyCount > 0 ? ' · $_localKeyCount local signing key${_localKeyCount == 1 ? '' : 's'}' : ''}',
                style: AppTypography.body,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('KEYS', style: AppTypography.label.copyWith(letterSpacing: 1.2)),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < xpubs.length; i++) ...[
          Row(
            children: [
              Icon(
                _signsLocally(i) ? Icons.phonelink_lock_rounded : Icons.key_outlined,
                size: 16,
                color: _signsLocally(i)
                    ? AppColors.accent
                    : (isDark ? AppColors.textMutedDark : AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Key ${i + 1} — ${_originLabel(i)}',
                  style: AppTypography.bodySmall,
                ),
              ),
              HexText(xpubs[i], truncate: true),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (_liquidReady) ...[
          const SizedBox(height: AppSpacing.md),
          InfoBanner(
            title: 'Bitcoin + Liquid',
            message: 'One wallet on both chains: a $_m-of-$_n Bitcoin '
                'multisig and a $_m-of-$_n Liquid multisig with a shared '
                'blinding key.'
                '${_hasPastedKey ? ' Pasted keys cannot be checked from here — only software wallets and a Blockstream Jade can sign on Liquid, so confirm with those co-signers that they can.' : ''}',
          ),
        ] else if (_liquidWanted) ...[
          const SizedBox(height: AppSpacing.md),
          WarningBanner(
            title: 'Bitcoin only',
            message: _liquidBlockedReason ??
                'The Liquid keys are incomplete, so this wallet will hold '
                    'Bitcoin only.',
          ),
        ],
        if (!_isWatchOnly && _localKeyCount == 0) ...[
          const SizedBox(height: AppSpacing.md),
          const InfoBanner(
            title: 'Coordinator — no key on this device',
            message: 'None of the keys you provided is held here, so this '
                'wallet cannot sign on its own. Transactions are signed with '
                'your devices — via USB or air-gap QR — in the co-sign flow.',
          ),
        ] else if (_isWatchOnly) ...[
          const SizedBox(height: AppSpacing.md),
          const WarningBanner(
            title: 'Watch-only',
            message: 'No key is stored here — this app cannot sign. You can build '
                'transactions and pass them to co-signers.',
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          WarningBanner(title: 'Creation failed', message: _error!),
        ],
      ],
    );
  }

  /// One line describing a collapsed slot: where its key came from, and the
  /// tail of the key itself once there is one to show.
  String _slotSummary(_ImportSlot slot) {
    final source = switch (slot.source) {
      _ImportSource.paste => 'Pasted or scanned',
      _ImportSource.appWallet => 'App wallet',
      _ImportSource.hardware => 'USB device (${slot.hwModel ?? 'hardware'})',
      _ImportSource.newKey => 'New private key',
      _ImportSource.seedPhrase => 'Seed phrase',
    };
    final key = slot.resolvedXpub;
    if (key.isEmpty) return '$source · not provided yet';
    if (slot.source == _ImportSource.newKey && !slot.backedUp) {
      return '$source · write the words down to continue';
    }
    // A checked key is named by what identifies it to a signing device — the
    // fingerprint and the account — not by the tail of its base58.
    final info = slot.keyInfo;
    if (info != null) return '$source · ${info.fingerprint} · m/${info.path}';
    final tail = key.length > 12 ? key.substring(key.length - 12) : key;
    return '$source · …$tail';
  }

  /// Whether any key came in as a pasted xpub — the one source whose ability
  /// to sign on Liquid this app cannot verify.
  bool get _hasPastedKey =>
      _importSlots.any((s) => s.source == _ImportSource.paste);

  /// True when key [i] is one this app signs with (the generated Key 1, a key
  /// whose seed lives here, or an opted-in app wallet).
  bool _signsLocally(int i) {
    if (!_isCoordinator && i == 0) return true;
    return _importSlots[_isCoordinator ? i : i - 1].isLocalKey;
  }

  String _originLabel(int i) {
    if (!_isCoordinator && i == 0) return 'your key (this device)';
    final slot = _importSlots[_isCoordinator ? i : i - 1];
    return switch (slot.source) {
      _ImportSource.paste => 'imported key',
      _ImportSource.appWallet =>
        slot.signsLocally ? 'app wallet — signs from this app' : 'app wallet (xpub only)',
      _ImportSource.hardware => 'USB device (${slot.hwModel ?? 'hardware'})',
      _ImportSource.newKey => 'new private key (this device)',
      _ImportSource.seedPhrase => 'imported seed (this device)',
    };
  }

  // ── Success ──────────────────────────────────────────────────────────────

  Widget _successBody() {
    return WalletCreatedView(
      walletName: _nameController.text.trim(),
      subtitle: _localKeyCount == 0
          ? '$_m-of-$_n multisig — no key here; sign with your devices via USB or air-gap QR.'
          : '$_m-of-$_n multisig — $_m keys required to spend.',
      details: [
        WalletCreatedDetail('Type', '$_m-of-$_n multisig'),
        WalletCreatedDetail(
            'Local keys',
            _localKeyCount == 0
                ? (_isWatchOnly
                    ? 'none (watch-only coordinator)'
                    : 'none — your devices sign (USB or air-gap QR)')
                : '$_localKeyCount signing key${_localKeyCount == 1 ? '' : 's'} on this device'),
        for (var i = 0; i < _allXpubs.length; i++)
          WalletCreatedDetail('Key ${i + 1}', _allXpubs[i], mono: true),
      ],
    );
  }
}

// ── Role card — one key of this wallet, held here ────────────────────────────

/// Where each key comes from is chosen key by key on the import step. The one
/// thing worth settling before that is whether this wallet holds one of them
/// itself: that key is generated and backed up here, in guided steps, before
/// the others are collected.
class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.n,
    required this.isDark,
    required this.watchOnly,
    required this.holdsKey,
    required this.onHoldsKeyChanged,
  });

  final int n;
  final bool isDark;

  /// A watch-only wallet has no choice to make: it holds nothing.
  final bool watchOnly;

  final bool holdsKey;
  final ValueChanged<bool> onHoldsKeyChanged;

  @override
  Widget build(BuildContext context) {
    final (icon, title, description) = watchOnly
        ? (
            Icons.visibility_outlined,
            'Watch-only coordinator',
            'You import all $n public keys. This app builds and inspects '
                'transactions but never signs.',
          )
        : holdsKey
            ? (
                Icons.phonelink_lock_rounded,
                'I hold one of these keys here',
                'Key 1 is generated on this device in the next step and backed '
                    'up before you collect the other ${n - 1}.',
              )
            : (
                Icons.group_rounded,
                'I hold one of these keys here',
                'Off: all $n keys are imported. You can still keep a key here '
                    '— set any slot to "New key" or "Seed phrase" while '
                    'importing, or read one from a USB device.',
              );
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.accent, size: 22),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.sectionTitle),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: AppTypography.bodySmall.copyWith(
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (!watchOnly) ...[
            const SizedBox(width: AppSpacing.md),
            ListSwitch(
              value: holdsKey,
              onChanged: onHoldsKeyChanged,
              semanticLabel: 'I hold one of these keys on this device',
            ),
          ],
        ],
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.lg),
          Text(label, style: AppTypography.body),
        ],
      ),
    );
  }
}

// ── Word tile (seed back-up grid) ─────────────────────────────────────────────

class _WordTile extends StatelessWidget {
  const _WordTile({required this.index, required this.word});
  final int index;
  final String word;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark2 : AppColors.tableHeader,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.codeBoxBorder),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text('$index.', style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
          ),
          Expanded(
            child: Text(word, style: AppTypography.mono.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ── Number picker — simple stepper ────────────────────────────────────────────

class _NumberPicker extends StatelessWidget {
  const _NumberPicker({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight),
      ),
      child: Column(
        children: [
          Text(label, style: AppTypography.label),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: value > min ? () => onChanged(value - 1) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: AppTypography.pageTitle,
                ),
              ),
              IconButton(
                onPressed: value < max ? () => onChanged(value + 1) : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Collapsed import slot — one line per key not being worked on ─────────────

class _CollapsedSlotRow extends StatefulWidget {
  const _CollapsedSlotRow({
    required this.keyNumber,
    required this.filled,
    required this.summary,
    required this.isDark,
    required this.onTap,
    required this.label,
  });

  final int keyNumber;
  final bool filled;
  final String summary;
  final bool isDark;
  final VoidCallback onTap;

  /// What this key has been called, if anything. A named key is listed by its
  /// name — "Key 3" is only what an unnamed one falls back to.
  final CosignerLabel label;

  @override
  State<_CollapsedSlotRow> createState() => _CollapsedSlotRowState();
}

class _CollapsedSlotRowState extends State<_CollapsedSlotRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final label = widget.label;
    final phone = AppLayout.isPhone(context);
    final s = AppScheme.of(context);
    final color = widget.filled ? AppColors.success : AppColors.textMuted;
    // The desktop pointer gets the tile's hover — surface up, hairline firm.
    // It used to be an InkWell, whose highlight painted on the Material
    // underneath this opaque card and so never showed at all.
    final active = !phone && _hover;
    final row = AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.settle,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: active
            ? (isDark ? AppColors.surfaceDark2 : AppColors.surfaceLight)
            : (isDark ? AppColors.surfaceDark : AppColors.surfaceLight),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: active
              ? s.edgeStrong
              : (isDark ? AppColors.borderDark : AppColors.borderLight),
        ),
      ),
      child: Row(
        children: [
          Icon(
              widget.filled
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 18,
              color: color),
          const SizedBox(width: AppSpacing.md),
          Icon(label.icon, size: 16, color: label.color ?? s.inkSecondary),
          const SizedBox(width: AppSpacing.sm),
          Text(label.displayName(widget.keyNumber - 1),
              style: AppTypography.sectionTitle),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(widget.summary,
                style: AppTypography.caption,
                overflow: TextOverflow.ellipsis),
          ),
          Icon(Icons.expand_more,
              size: 18, color: active ? s.accent : s.inkSecondary),
        ],
      ),
    );
    if (phone) {
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          child: row,
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: row,
      ),
    );
  }
}

// ── Import slot card — paste/scan xpub, app wallet, or USB device ─────────────

/// What the engine made of the key in the field above it.
///
/// Three states worth showing and one worth hiding: nothing before a key has
/// been checked, a spinner while it is, the fingerprint and path it resolved
/// to when it holds up, and the reason when it does not. The path matters as
/// much as the tick — a key at the wrong account builds a wallet that nobody
/// can ever sign for, and it is the one mistake neither end can detect later.
class _KeyVerdict extends StatelessWidget {
  const _KeyVerdict({
    required this.info,
    required this.error,
    required this.checking,
  });

  final CosignerKeyInfo? info;
  final String? error;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text('Checking the key…', style: AppTypography.caption),
          ],
        ),
      );
    }
    if (error != null) {
      return _line(Icons.error_outline_rounded, AppColors.danger, error!);
    }
    final info = this.info;
    if (info == null) return const SizedBox.shrink();
    if (info.warning != null) {
      return _line(Icons.warning_amber_rounded, AppColors.warning,
          '${info.fingerprint} · ${info.warning}');
    }
    return _line(Icons.check_circle_outline_rounded, AppColors.success,
        'Key ${info.fingerprint} at m/${info.path}');
  }

  Widget _line(IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(text,
                  style: AppTypography.caption.copyWith(color: color)),
            ),
          ],
        ),
      );
}

/// Name and glyph for one co-signer, inline in its card.
///
/// The field is the whole control: typing names the key, and the disc beside
/// it opens the icon and colour picker. Optional everywhere — an unnamed key
/// stays "Key N", which is what it was before any of this existed.
class _CosignerNameField extends StatefulWidget {
  const _CosignerNameField({
    required this.label,
    required this.keyNumber,
    required this.onChanged,
    this.subtitle,
  });

  final CosignerLabel label;
  final int keyNumber;
  final String? subtitle;
  final void Function(CosignerLabel) onChanged;

  @override
  State<_CosignerNameField> createState() => _CosignerNameFieldState();
}

class _CosignerNameFieldState extends State<_CosignerNameField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.label.name ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_CosignerNameField old) {
    super.didUpdateWidget(old);
    // The picker can set a name too; keep the field in step without stealing
    // the cursor from someone mid-word.
    final name = widget.label.name ?? '';
    if (name != _ctrl.text && !name.startsWith(_ctrl.text)) {
      _ctrl.text = name;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final color = widget.label.color ?? s.accent;
    return Row(
      children: [
        Tooltip(
          message: 'Icon and colour',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () async {
              final edited = await showCosignerLabelEditor(
                context,
                label: widget.label,
                index: widget.keyNumber - 1,
                subtitle: widget.subtitle,
              );
              if (edited == null) return;
              _ctrl.text = edited.name ?? '';
              widget.onChanged(edited);
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 0.7)),
              ),
              child: Icon(widget.label.icon, size: 19, color: color),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: TextField(
            controller: _ctrl,
            maxLength: 40,
            decoration: InputDecoration(
              labelText: 'Name this key (optional)',
              hintText: 'Key ${widget.keyNumber}',
              counterText: '',
            ),
            onChanged: (v) => widget.onChanged(
              widget.label.copyWith(name: v.trim().isEmpty ? null : v),
            ),
          ),
        ),
      ],
    );
  }
}

class _ImportSlotCard extends StatelessWidget {
  const _ImportSlotCard({
    required this.keyNumber,
    required this.slot,
    required this.appWallets,
    required this.isDark,
    required this.allowLocalSigning,
    required this.liquidWanted,
    required this.busy,
    required this.onSourceChanged,
    required this.onAppWalletPicked,
    required this.onFetchHw,
    required this.onGenerateKey,
    required this.onUseSeed,
    required this.onChanged,
    required this.onConfirm,
    required this.onLabelChanged,
  });

  /// 1-based key number shown to the user.
  final int keyNumber;
  final _ImportSlot slot;
  final List<WalletSummary> appWallets;
  final bool isDark;

  /// Whether this wallet may hold private keys at all (false = watch-only
  /// coordinator: only public keys can be imported).
  final bool allowLocalSigning;

  /// The wizard's coins answer. When true each key needs a Liquid (BIP87)
  /// counterpart, so the card asks for one — or explains why it cannot.
  final bool liquidWanted;
  final bool busy;
  final void Function(_ImportSource) onSourceChanged;
  final void Function(String walletId) onAppWalletPicked;
  final VoidCallback onFetchHw;
  final VoidCallback onGenerateKey;
  final VoidCallback onUseSeed;
  final VoidCallback onChanged;

  /// "Done" on a key typed or scanned by hand: check it, then move to the
  /// next key. Sources that talk to a device or the app advance themselves.
  final VoidCallback onConfirm;

  /// The user named this key, or picked an icon or colour for it.
  final void Function(CosignerLabel) onLabelChanged;

  /// Which key the naming dialog is about, in whatever terms are known yet:
  /// the checked fingerprint, else the device or wallet it came from.
  String? _labelSubtitle() {
    final info = slot.keyInfo;
    if (info != null) return '${info.fingerprint} · m/${info.path}';
    if (slot.hwModel case final model?) return model;
    return switch (slot.source) {
      _ImportSource.newKey => 'A new private key, generated on this device',
      _ImportSource.seedPhrase => 'A key restored from seed words',
      _ImportSource.appWallet => 'A key borrowed from a wallet in this app',
      _ImportSource.hardware => 'A key read from a USB device',
      _ImportSource.paste => 'A key pasted or scanned in',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(slot.label.displayName(keyNumber - 1),
                  style: AppTypography.sectionTitle),
              if (slot.label.name?.trim().isNotEmpty ?? false) ...[
                const SizedBox(width: AppSpacing.sm),
                Text('key $keyNumber', style: AppTypography.caption),
              ],
              if (slot.isLocalKey) ...[
                const SizedBox(width: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'PRIVATE KEY · SIGNS HERE',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.accent,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Naming the key comes first: it is the only part of a co-signer a
          // person can hold in their head, and by the time the xpub is pasted
          // nobody wants to go back for it.
          _CosignerNameField(
            label: slot.label,
            keyNumber: keyNumber,
            subtitle: _labelSubtitle(),
            onChanged: onLabelChanged,
          ),
          const SizedBox(height: AppSpacing.md),
          // Public sources first, then the private ones (a key this wallet
          // holds and signs with) — which a watch-only coordinator never sees.
          // A list, not a row of chips: five of them wrapped onto two ragged
          // lines, and the one that was greyed out could not say why.
          Text('WHERE THIS KEY COMES FROM',
              style: AppTypography.label.copyWith(letterSpacing: 1.2)),
          const SizedBox(height: AppSpacing.sm),
          ChoiceList<_ImportSource>(
            options: [
              // "Air-gap / QR" described one of the three things this does.
              // Most keys arriving here come from another wallet the user
              // already has — their own phone, a co-signer's export — and
              // nobody looking for that reads "air-gap".
              const ChoiceListOption(
                value: _ImportSource.paste,
                label: 'Paste or scan a key',
                icon: Icons.content_paste_rounded,
              ),
              ChoiceListOption(
                value: _ImportSource.appWallet,
                label: 'App wallet',
                icon: Icons.account_balance_wallet_outlined,
                enabled: appWallets.isNotEmpty,
                disabledReason: appWallets.isEmpty
                    ? 'No software wallet in this app to lend a key'
                    : null,
              ),
              // USB only where a USB stack exists (not Android).
              if (!Platform.isAndroid)
                const ChoiceListOption(
                  value: _ImportSource.hardware,
                  label: 'USB device',
                  icon: Icons.usb_rounded,
                ),
              if (allowLocalSigning) ...[
                const ChoiceListOption(
                  value: _ImportSource.newKey,
                  label: 'New key',
                  icon: Icons.add_moderator_rounded,
                  note: 'signs here',
                ),
                const ChoiceListOption(
                  value: _ImportSource.seedPhrase,
                  label: 'Seed phrase',
                  icon: Icons.vpn_key_rounded,
                  note: 'signs here',
                ),
              ],
            ],
            selected: slot.source,
            onChanged: onSourceChanged,
          ),
          const SizedBox(height: AppSpacing.lg),
          switch (slot.source) {
            _ImportSource.paste => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: slot.pasteCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Cosigner xpub',
                            hintText: "[fingerprint/48'/1'/0'/2']tpub…",
                          ),
                          style: AppTypography.monoSmall,
                          onChanged: (_) => onChanged(),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      ScanIconButton(
                        controller: slot.pasteCtrl,
                        expectsKey: true,
                        title: 'Scan a cosigner xpub or an air-gapped '
                            'device\'s QR',
                        // A scanned key checks itself, the way a key read over
                        // USB does — nobody scans a QR and then wonders
                        // whether to press anything.
                        onScanned: (_) => onConfirm(),
                      ),
                    ],
                  ),
                  _KeyVerdict(
                    info: slot.keyInfo,
                    error: slot.keyError,
                    checking: slot.checking,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Wherever the key already is: another Templar wallet '
                    '(this computer or your phone — Wallet info → "Use this '
                    'wallet as a cosigner"), a key a co-signer sent you, or an '
                    'air-gapped device\'s QR (SeedSigner, or a Jade in QR '
                    'mode — unlock it first, a locked Jade only shows its '
                    'PIN-unlock QR).',
                    style: AppTypography.caption,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  SecondaryButton(
                    label: slot.checking ? 'Checking…' : 'Done with this key',
                    icon: Icons.check_rounded,
                    isLoading: slot.checking,
                    isFullWidth: true,
                    onPressed: slot.checking || slot.pasteCtrl.text.trim().isEmpty
                        ? null
                        : onConfirm,
                  ),
                ],
              ),
            _ImportSource.appWallet => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: slot.walletId,
                    items: appWallets
                        .map((w) => DropdownMenuItem(value: w.id, child: Text(w.name)))
                        .toList(),
                    onChanged: (id) { if (id != null) onAppWalletPicked(id); },
                    decoration: const InputDecoration(hintText: 'Choose a software wallet'),
                  ),
                  if (allowLocalSigning && slot.walletId != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: slot.signsLocally,
                      onChanged: (v) {
                        slot.signsLocally = v ?? false;
                        onChanged();
                      },
                      title: Text(
                        'Sign with this key from this app',
                        style: AppTypography.bodySmall,
                      ),
                      subtitle: Text(
                        'One sign action will sign with every local key.',
                        style: AppTypography.caption,
                      ),
                    ),
                ],
              ),
            _ImportSource.hardware => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (slot.xpub == null)
                    SecondaryButton(
                      label: busy ? 'Reading…' : 'Read xpub from device',
                      icon: Icons.usb_rounded,
                      isLoading: busy,
                      isFullWidth: true,
                      onPressed: busy ? null : onFetchHw,
                    )
                  else
                    Row(
                      children: [
                        const Icon(Icons.usb_rounded,
                            size: 16, color: AppColors.success),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            slot.hwModel ?? 'Device',
                            style: AppTypography.bodySmall,
                          ),
                        ),
                        HexText(slot.xpub!, truncate: true),
                        IconButton(
                          tooltip: 'Read again',
                          icon: const Icon(Icons.refresh, size: 16),
                          onPressed: busy ? null : onFetchHw,
                        ),
                      ],
                    ),
                ],
              ),

            // ── New private key: generated here, written down here ──────────
            _ImportSource.newKey => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (slot.mnemonic == null)
                    SecondaryButton(
                      label: busy
                          ? 'Generating…'
                          : 'Generate a new 24-word key',
                      icon: Icons.add_moderator_rounded,
                      isLoading: busy,
                      isFullWidth: true,
                      onPressed: busy ? null : onGenerateKey,
                    )
                  else ...[
                    const WarningBanner(
                      title: 'Write these words down on paper',
                      message:
                          'This is a second private key of this wallet. Anyone who '
                          'sees it can sign with it. Shown only once.',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisExtent: 40,
                        crossAxisSpacing: AppSpacing.sm,
                        mainAxisSpacing: AppSpacing.sm,
                      ),
                      itemCount: slot.mnemonic!.length,
                      itemBuilder: (context, i) =>
                          _WordTile(index: i + 1, word: slot.mnemonic![i]),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: slot.backedUp,
                      onChanged: (v) {
                        slot.backedUp = v ?? false;
                        onChanged();
                      },
                      title: Text('I wrote these words down',
                          style: AppTypography.bodySmall),
                    ),
                    HexText(slot.xpub!, truncate: true),
                  ],
                ],
              ),

            // ── Existing seed adopted as another private key ────────────────
            _ImportSource.seedPhrase => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: slot.seedCtrl,
                    maxLines: 3,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Seed phrase (12 or 24 words)',
                      hintText: 'abandon abandon … about',
                      alignLabelWithHint: true,
                    ),
                    style: AppTypography.monoSmall,
                    onChanged: (_) => onChanged(),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      SecondaryButton(
                        label: slot.xpub == null ? 'Use this seed' : 'Re-check',
                        icon: Icons.check_rounded,
                        isLoading: busy,
                        onPressed: busy ? null : onUseSeed,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      if (slot.xpub != null)
                        Expanded(child: HexText(slot.xpub!, truncate: true)),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'The seed is stored in this wallet and signs alongside your '
                    'other keys. Keep the paper backup safe.',
                    style: AppTypography.caption,
                  ),
                ],
              ),
          },
          if (liquidWanted) ...[
            const SizedBox(height: AppSpacing.md),
            Divider(
              height: 1,
              color: isDark ? AppColors.borderDark : AppColors.borderLight,
            ),
            const SizedBox(height: AppSpacing.md),
            _liquidKeySection(),
          ],
        ],
      ),
    );
  }

  /// This co-signer's Liquid key.
  ///
  /// Derived without asking whenever the seed is reachable from here, read
  /// from a Jade over USB, and typed in only for a remote co-signer — the one
  /// case where the app has neither the seed nor the device.
  Widget _liquidKeySection() {
    if (slot.isBitcoinOnlyDevice) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.block_rounded, size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '${slot.hwModel ?? 'This device'} is Bitcoin-only — it cannot '
              'sign Liquid transactions. Including this key makes the whole '
              'wallet Bitcoin-only.',
              style: AppTypography.caption,
            ),
          ),
        ],
      );
    }

    if (slot.source == _ImportSource.paste) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: slot.liquidPasteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Cosigner Liquid key (BIP87)',
                    hintText: "[fingerprint/87'/1'/0']tpub…",
                  ),
                  style: AppTypography.monoSmall,
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              ScanIconButton(
                controller: slot.liquidPasteCtrl,
                expectsKey: true,
                title: 'Scan cosigner Liquid key',
                onScanned: (_) => onConfirm(),
              ),
            ],
          ),
          _KeyVerdict(
            info: slot.liquidKeyInfo,
            error: slot.liquidKeyError,
            checking: slot.checking,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'A second key from the same co-signer: Liquid uses account '
            "m/87'/1'/0', Bitcoin uses m/48'/1'/0'/2'. Neither can be "
            'computed from the other, so ask for both.',
            style: AppTypography.caption,
          ),
        ],
      );
    }

    final key = slot.liquidXpub;
    if (key == null) {
      return Row(
        children: [
          const Icon(Icons.hourglass_empty_rounded,
              size: 16, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              slot.source == _ImportSource.hardware
                  ? 'Liquid key is read from the Jade together with the '
                      'Bitcoin one.'
                  : 'Liquid key is derived from this seed automatically.',
              style: AppTypography.caption,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        const Icon(Icons.water_drop_outlined,
            size: 16, color: AppColors.liquid),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text('Liquid key ready', style: AppTypography.bodySmall),
        ),
        HexText(key, truncate: true),
      ],
    );
  }
}
