import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/step_flow_scaffold.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../hardware/device_list_section.dart';
import '../hardware/device_permission_card.dart';
import '../hardware/hw_error.dart';
import '../hardware/hw_platform.dart';
import '../hardware/hwi_install_card.dart';
import '../hardware/jade_liquid_dialog.dart';
import '../hardware/pairing_recap.dart';
import '../hardware/usb_unsupported_card.dart';
import 'models/hw_device.dart';
import 'models/hw_import_result.dart';
import 'models/new_wallet_draft.dart';

class HardwareSetupScreen extends StatefulWidget {
  const HardwareSetupScreen({super.key, this.baseStep = 0, this.onBackToWizard});

  /// Questions already answered by the wizard hosting this setup —
  /// the step counter continues from here instead of restarting at 1.
  final int baseStep;

  /// Back from the first step: return to the wizard's last question.
  /// Null (standalone route) falls back to navigating there.
  final VoidCallback? onBackToWizard;

  @override
  State<HardwareSetupScreen> createState() => _HardwareSetupScreenState();
}

class _HardwareSetupScreenState extends State<HardwareSetupScreen> {
  final _bridge = walletBridge;
  final _nameController = TextEditingController(text: 'My Hardware Wallet');

  int _step = 1;
  static const int _totalSteps = 4;

  HwDevice? _selected;

  /// From the wizard's networks step — not re-asked here; only applied when
  /// the device is a Jade, the only hardware wallet with Liquid in firmware.
  final bool _liquidEnabled = newWalletDraft.liquidActive;
  bool _importing = false;
  String? _error;

  /// The pairing result, which is what the recap step renders. Both sides of
  /// the wallet and the device they came from are read from here rather than
  /// re-asked — asking the device again would mean another PIN entry.
  HwImportResult? _result;

  /// Retrying the Liquid half from the recap step.
  bool _addingLiquid = false;

  /// Null while the check runs; false shows the HWI install card.
  bool? _hwiReady;

  /// Set when the OS is blocking device access (Linux udev). Shown as the
  /// permission card, which is a different fix from installing HWI — the two
  /// used to collapse into one unexplained "no devices found".
  bool _needsPermissionFix = false;

  /// The backend's own words about the permission failure, shown inside the
  /// fix card so the user sees what the OS actually said.
  String? _permissionDetail;

  @override
  void initState() {
    super.initState();
    _checkHwi();
  }

  Future<void> _checkHwi() async {
    try {
      final status = await _bridge.hwiStatus();
      // Which families are native and whether HWI can run here is the
      // backend's call, not the platform's — apply it before anything renders
      // a card that depends on it.
      applyHwPlatformStatus(
        nativeFamilies: status.nativeFamilies,
        hwiUsable: status.hwiUsable,
      );
      if (mounted) {
        setState(() {
          _hwiReady = status.installed;
          // Proactive on Linux: rules missing means enumeration will fail, so
          // offer the fix before the user hits an empty device list.
          _needsPermissionFix = status.needsUdevRules;
        });
      }
    } catch (_) {
      // Status probe failing must not block the screen — let the device
      // section surface it.
      if (mounted) setState(() => _hwiReady = true);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

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

  /// A failure the device section cannot fix on its own is routed to the card
  /// that can — the HWI installer, or the permission repair.
  void _onDeviceFailure(HwFailure failure) {
    if (!mounted) return;
    setState(() {
      if (failure.isHwiMissing) _hwiReady = false;
      if (failure.isPermission) {
        _needsPermissionFix = true;
        _permissionDetail = failure.message;
      }
    });
  }

  Future<void> _import() async {
    if (_selected == null) return;
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await _bridge.importHwWallet(
        _nameController.text.trim(),
        _selected!.fingerprint,
        liquid: _liquidActive,
      );
      if (!mounted) return;
      _applyActiveWallet(result);
      setState(() {
        _importing = false;
        _result = result;
        _step = 4;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error = friendlyHwError(e);
        });
      }
    }
  }

  /// Make the freshly paired wallet the open one. The type label comes from the
  /// backend (`Hardware (<fingerprint>)`): a bare 'Hardware' left the connect
  /// gate with no fingerprint to match, so any plugged-in device satisfied it —
  /// the device-binding check was silently a no-op for a whole session, exactly
  /// when a user is most likely to have two devices on the desk.
  void _applyActiveWallet(HwImportResult result) {
    context.read<AppState>().setActiveWallet(
          result.wallet.id,
          name: result.wallet.name,
          type: result.wallet.typeLabel,
          liquid: result.wallet.liquidEnabled,
          bitcoin: result.wallet.bitcoinEnabled,
        );
  }

  /// Read the Liquid descriptor again for a wallet whose Bitcoin side paired
  /// but whose Liquid side did not — a PIN timeout, or the device busy in
  /// another app. The wallet already exists; this fills in its missing half.
  Future<void> _retryLiquid() async {
    final result = _result;
    if (result == null) return;
    setState(() {
      _addingLiquid = true;
      _error = null;
    });
    try {
      final updated = await _bridge.addLiquidToWallet(result.wallet.id);
      if (!mounted) return;
      setState(() {
        _addingLiquid = false;
        _result = HwImportResult(
          wallet: updated,
          fingerprint: result.fingerprint,
          deviceModel: result.deviceModel,
          bitcoinDescriptor: result.bitcoinDescriptor,
          // The descriptor itself is not handed back by this call; what matters
          // to the recap is that the side now exists.
          liquidDescriptor: 'read from the device',
          liquidRequested: true,
        );
      });
      _applyActiveWallet(_result!);
    } catch (e) {
      if (mounted) {
        setState(() {
          _addingLiquid = false;
          _error = friendlyHwError(e);
        });
      }
    }
  }

  /// Liquid-only wallet from a Jade, over serial. The fallback when the Bitcoin
  /// half cannot be read at all: it needs nothing but the serial port.
  Future<void> _setupJadeLiquid() async {
    final wallet = await showJadeLiquidSetupDialog(context);
    if (wallet == null || !mounted) return;
    context.read<AppState>().setActiveWallet(
          wallet.id,
          name: wallet.name,
          type: wallet.typeLabel,
          liquid: true,
          bitcoin: false,
        );
    context.go(AppRoutes.dashboard);
  }

  bool get _isJade => _selected?.model.toLowerCase().contains('jade') ?? false;

  /// Liquid pairing is only ever enabled for a Jade, even if the toggle was
  /// set while a Jade was selected and the user later switched devices. Every
  /// other device is Bitcoin-only in firmware, and a Liquid wallet paired with
  /// one could receive funds it could never send.
  bool get _liquidActive => _isJade && _liquidEnabled;

  @override
  Widget build(BuildContext context) {
    return StepFlowScaffold(
      currentStep: widget.baseStep + _step,
      totalSteps: widget.baseStep + _totalSteps,
      title: _stepTitle,
      subtitle: _stepSubtitle,
      onBack: _step < 4
          ? (_step > 1 ? () => setState(() => _step--) : _exitToWizard)
          : null,
      onCancel: _step < 4 ? () => context.go(AppRoutes.walletPicker) : null,
      body: _stepBody(),
      actions: _stepActions(),
    );
  }

  String get _stepTitle => switch (_step) {
        1 => 'Connect your device',
        2 => 'Confirm what this device will hold',
        3 => 'Name your wallet',
        _ => 'Pairing summary',
      };

  String get _stepSubtitle => switch (_step) {
        1 => 'Plug it in with its cable and unlock it with your PIN',
        2 => 'Review the device and the networks it will carry',
        3 => 'Give this wallet a name',
        _ => 'What was created, and where it came from',
      };

  Widget _stepBody() {
    if (_step == 1) {
      return _Step1Body(
        selected: _selected,
        liquidWanted: _liquidEnabled,
        hwiReady: _hwiReady,
        needsPermissionFix: _needsPermissionFix,
        permissionDetail: _permissionDetail,
        onUseAirgap: () {
          newWalletDraft.hwConnection = HwConnection.airgap;
          _exitToWizard();
        },
        onPermissionsFixed: () {
          setState(() {
            _needsPermissionFix = false;
            _permissionDetail = null;
          });
        },
        onHwiInstalled: () => setState(() => _hwiReady = true),
        onSelect: (d) => setState(() => _selected = d),
        onFailure: _onDeviceFailure,
      );
    }
    if (_step == 2) {
      return _Step2Body(
        device: _selected!,
        liquidEnabled: _liquidEnabled,
        isJade: _isJade,
      );
    }
    if (_step == 3) {
      return _Step3Body(
        controller: _nameController,
        importing: _importing,
        liquidActive: _liquidActive,
        error: _error,
      );
    }
    return _RecapBody(
      result: _result!,
      addingLiquid: _addingLiquid,
      error: _error,
      onRetryLiquid: _retryLiquid,
      onLiquidOnlyFallback: _setupJadeLiquid,
    );
  }

  Widget _stepActions() {
    if (_step == 4) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SecondaryButton(
            label: 'Get receive address',
            onPressed: () => context.go(AppRoutes.receive),
          ),
          const SizedBox(width: AppSpacing.md),
          PrimaryButton(
            label: 'Open Wallet',
            onPressed: () => context.go(AppRoutes.dashboard),
          ),
        ],
      );
    }
    if (_step == 3) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GhostButton(label: 'Back', onPressed: () => setState(() => _step--)),
          const SizedBox(width: AppSpacing.md),
          PrimaryButton(
            label: _importing ? 'Pairing…' : 'Pair device',
            onPressed: (_importing || _nameController.text.trim().isEmpty)
                ? null
                : _import,
          ),
        ],
      );
    }
    // steps 1 & 2
    final canContinue = _step == 1 ? _selected != null : true;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (_step > 1)
          GhostButton(label: 'Back', onPressed: () => setState(() => _step--)),
        const SizedBox(width: AppSpacing.md),
        PrimaryButton(
          label: 'Continue',
          onPressed: canContinue ? () => setState(() => _step++) : null,
        ),
      ],
    );
  }
}

// ── Step 1 — connect and pick a device ────────────────────────────────────────
//
// Two blocks, in this order: what needs fixing (nothing, normally), then the
// devices. They used to be interleaved, with the same device listed inside a
// warning card *and* in the results below it.

class _Step1Body extends StatelessWidget {
  const _Step1Body({
    required this.selected,
    required this.liquidWanted,
    required this.hwiReady,
    required this.needsPermissionFix,
    required this.permissionDetail,
    required this.onUseAirgap,
    required this.onPermissionsFixed,
    required this.onHwiInstalled,
    required this.onSelect,
    required this.onFailure,
  });

  final HwDevice? selected;
  final bool liquidWanted;

  /// Null = probing, false = HWI missing (show install card), true = ok.
  final bool? hwiReady;

  /// Linux: the OS is blocking device access until udev rules are installed.
  final bool needsPermissionFix;
  final String? permissionDetail;

  /// Leave for the air-gap branch, which works on every platform.
  final VoidCallback onUseAirgap;
  final VoidCallback onPermissionsFixed;
  final VoidCallback onHwiInstalled;
  final void Function(HwDevice) onSelect;
  final void Function(HwFailure) onFailure;

  @override
  Widget build(BuildContext context) {
    // Plain Column: StepFlowScaffold already wraps the body in a scroll view,
    // and a second viewport inside it gets unbounded height and throws.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (needsPermissionFix) ...[
          DevicePermissionCard(
            onFixed: onPermissionsFixed,
            detail: permissionDetail,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        // HWI is optional: a Ledger or a Jade is found without it, so this is
        // an offer, not a gate.
        if (allFamiliesSupported && hwiReady == false) ...[
          HwiInstallCard(onInstalled: onHwiInstalled),
          const SizedBox(height: AppSpacing.lg),
        ],
        // The devices themselves — their own block, nothing else in it.
        DeviceListSection(
          selected: selected,
          onSelect: onSelect,
          liquidWanted: liquidWanted,
          onFailure: onFailure,
        ),
        const SizedBox(height: AppSpacing.lg),
        _PrerequisiteCard(liquidWanted: liquidWanted),
        // Where some families are out of reach, say so once, below the list —
        // the rows themselves already carry a "not usable here" state.
        if (!allFamiliesSupported) ...[
          const SizedBox(height: AppSpacing.lg),
          UsbUnsupportedCard(onUseAirgap: onUseAirgap),
        ],
      ],
    );
  }
}

// ── Step 2 — what the chosen device will hold ─────────────────────────────────

class _Step2Body extends StatelessWidget {
  const _Step2Body({
    required this.device,
    required this.liquidEnabled,
    required this.isJade,
  });

  final HwDevice device;
  final bool liquidEnabled;
  final bool isJade;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SummaryCard(device: device),
        const SizedBox(height: AppSpacing.xl),
        Text(
          'NETWORKS',
          style: AppTypography.label
              .copyWith(color: s.inkFaint, letterSpacing: 1.2),
        ),
        const SizedBox(height: AppSpacing.md),
        _NetworkRow(
          icon: Icons.currency_bitcoin,
          name: 'Bitcoin',
          description: 'The device signs; this app watches the addresses',
          accentColor: s.bitcoin,
          isDark: s.isDark,
        ),
        const SizedBox(height: AppSpacing.sm),
        // Networks come from the wizard's first step — shown here, not
        // re-asked. Liquid pairing only ever applies to Jade: it is the one
        // device with Liquid in firmware.
        if (liquidEnabled && isJade) ...[
          _NetworkRow(
            icon: Icons.water_drop_rounded,
            name: 'Liquid Network',
            description: 'Full wallet · the Jade signs, send and receive',
            accentColor: s.liquid,
            isDark: s.isDark,
          ),
          const SizedBox(height: AppSpacing.lg),
          const InfoBanner(
            message: 'Both networks land in one wallet, read from the device '
                'in a single unlock: the Liquid side uses the confidential '
                'descriptor from the Jade itself, so the device can spend '
                'from it. You will be asked to unlock the Jade once now, and '
                'again for every transaction you send.',
          ),
        ] else if (liquidEnabled)
          const WarningBanner(
            title: 'This device is Bitcoin-only',
            // Not a limitation of Templar, and worth saying so plainly — the
            // alternative reading is "the app is missing a feature", which
            // sends people looking for a setting that does not exist.
            message: 'You chose Bitcoin + Liquid, but only a Blockstream Jade '
                'can sign Liquid transactions — Ledger, Trezor, Coldcard and '
                'KeepKey have no Liquid support in their firmware. This wallet '
                'will be Bitcoin-only. Pairing a Liquid wallet with this device '
                'would let you receive funds it could never send.',
          )
        else
          const InfoBanner(
            message: 'Bitcoin only, as chosen. If this is a Jade you can add '
                'the Liquid side later from the wallet — the device is asked '
                'for its confidential descriptor then.',
          ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.device});
  final HwDevice device;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.success, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: s.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Icon(Icons.usb_rounded, color: s.success, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.model, style: AppTypography.sectionTitle),
                const SizedBox(height: 2),
                Text(
                  device.fingerprint,
                  style: AppTypography.mono
                      .copyWith(fontSize: 11, color: s.inkFaint),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm, vertical: 3),
            decoration: BoxDecoration(
              color: s.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            child: Text(
              'identified',
              style:
                  AppTypography.label.copyWith(color: s.success, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.icon,
    required this.name,
    required this.description,
    required this.accentColor,
    required this.isDark,
  });

  final IconData icon;
  final String name;
  final String description;
  final Color accentColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: isDark ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: accentColor, width: 1.5),
      ),
      child: Row(
        children: [
          Icon(icon, color: accentColor, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppTypography.sectionTitle),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: AppTypography.caption
                      .copyWith(color: s.inkSecondary),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(Icons.check_circle, color: accentColor, size: 20),
          ),
        ],
      ),
    );
  }
}

// ── Step 3 — name ─────────────────────────────────────────────────────────────

class _Step3Body extends StatelessWidget {
  const _Step3Body({
    required this.controller,
    required this.importing,
    required this.liquidActive,
    this.error,
  });
  final TextEditingController controller;
  final bool importing;

  /// Both sides are read in one device session, so the wait says so — a user
  /// who expects a second PIN prompt will otherwise sit waiting for one.
  final bool liquidActive;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (importing) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.lg),
          Text(
            liquidActive
                ? 'Reading the Bitcoin and Liquid descriptors from the device…'
                : 'Reading descriptors from the device…',
            style: AppTypography.body,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Unlock it with your PIN and confirm on its screen if asked. One '
            'unlock covers both networks.',
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
        ]),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Wallet name'),
          autofocus: true,
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          WarningBanner(title: 'Pairing failed', message: error!),
        ],
      ],
    );
  }
}

// ── Step 4 — recap ────────────────────────────────────────────────────────────

class _RecapBody extends StatelessWidget {
  const _RecapBody({
    required this.result,
    required this.addingLiquid,
    required this.error,
    required this.onRetryLiquid,
    required this.onLiquidOnlyFallback,
  });

  final HwImportResult result;
  final bool addingLiquid;
  final String? error;
  final VoidCallback onRetryLiquid;
  final VoidCallback onLiquidOnlyFallback;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final wallet = result.wallet;

    final networks = <PairingNetwork>[
      PairingNetwork(
        name: 'Bitcoin',
        icon: Icons.currency_bitcoin,
        color: s.bitcoin,
        ok: wallet.bitcoinEnabled,
        detail: wallet.bitcoinEnabled
            ? 'Imported · watch the addresses here, sign on the device'
            : 'Not imported',
        descriptor: wallet.bitcoinEnabled ? result.bitcoinDescriptor : null,
      ),
      if (result.liquidRequested || result.hasLiquid)
        PairingNetwork(
          name: 'Liquid Network',
          icon: Icons.water_drop_rounded,
          color: s.liquid,
          ok: result.hasLiquid,
          detail: result.hasLiquid
              ? 'Imported · confidential descriptor read from the device'
              : (result.liquidError ??
                  'The device did not hand over its Liquid descriptor.'),
          descriptor: result.hasLiquid ? result.liquidDescriptor : null,
          action: result.hasLiquid ? null : onRetryLiquid,
          actionLabel: 'Retry Liquid',
          busy: addingLiquid,
        ),
    ];

    final checks = <PairingCheck>[
      PairingCheck(
        label: 'Device answered with a master fingerprint',
        passed: result.fingerprint.isNotEmpty,
        detail: result.fingerprint,
      ),
      if (wallet.bitcoinEnabled)
        PairingCheck(
          // The check that matters for a hardware wallet: the descriptor stored
          // here must be derived from the key of the device that will sign, or
          // the wallet can receive and never spend.
          label: 'Bitcoin descriptor belongs to this device',
          passed: wallet.masterFingerprint == null ||
              wallet.masterFingerprint!.toLowerCase() ==
                  result.fingerprint.toLowerCase(),
          detail: wallet.masterFingerprint,
        ),
      if (result.hasLiquid)
        const PairingCheck(
          // Both descriptors came out of the same unlocked session, so they
          // cannot belong to two different devices — the failure mode when
          // Liquid was read through a second connection with two Jades around.
          label: 'Liquid side read from the same device session',
          passed: true,
        ),
      PairingCheck(
        label: 'No private key stored on this computer',
        passed: wallet.isWatchOnly,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PairingRecapView(
          walletName: wallet.name,
          deviceLabel: '${result.deviceModel} over USB',
          fingerprint: result.fingerprint,
          networks: networks,
          checks: checks,
          footnote: 'You can browse this wallet with the device unplugged — '
              'balances, history and receive addresses are all local. Sending '
              'asks you to connect and unlock it, because only the device can '
              'sign.',
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpacing.md),
          WarningBanner(title: 'Could not add Liquid', message: error!),
        ],
        // Last resort when the Bitcoin half is the one that failed: a Jade can
        // still hold a Liquid-only wallet, which needs nothing but the port.
        if (!result.wallet.bitcoinEnabled && !result.hasLiquid) ...[
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
              label: 'Set up a Liquid-only wallet instead',
              icon: Icons.water_drop_rounded,
              onPressed: onLiquidOnlyFallback,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Shared sub-widgets ────────────────────────────────────────────────────────

class _PrerequisiteCard extends StatelessWidget {
  const _PrerequisiteCard({required this.liquidWanted});

  /// A Liquid pairing has one extra requirement worth stating up front: the
  /// PIN unlock talks to Blockstream's blind pinserver, so it needs the network.
  final bool liquidWanted;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final items = [
      'Connected with a data cable (a charge-only cable shows nothing)',
      'Unlocked with its PIN',
      'Ledger: the "Bitcoin Test" app open on the device',
      'Jade: no other app holding it — close Blockstream Green',
      if (liquidWanted) 'Jade: internet reachable, its PIN unlock needs it',
      'Linux: udev rules installed',
    ];
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: s.surfaceGlass,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('If nothing shows up', style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.md),
          ...items.map((item) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle_outline,
                        size: 16, color: s.inkFaint),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(item,
                          style: AppTypography.bodySmall
                              .copyWith(color: s.inkSecondary)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
