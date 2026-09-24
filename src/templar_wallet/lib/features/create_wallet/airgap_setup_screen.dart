import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/scan_button.dart';
import '../../shared/widgets/step_flow_scaffold.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../hardware/pairing_recap.dart';
import '../wallet_picker/models/wallet_summary.dart';
import 'models/new_wallet_draft.dart';

enum _AirgapDevice { seedSigner, jade }

class AirgapSetupScreen extends StatefulWidget {
  const AirgapSetupScreen({super.key, this.baseStep = 0, this.onBackToWizard});

  /// Questions already answered by the wizard hosting this setup —
  /// the step counter continues from here instead of restarting at 1.
  final int baseStep;

  /// Back from the first step: return to the wizard's last question.
  /// Null (standalone route) falls back to navigating there.
  final VoidCallback? onBackToWizard;

  @override
  State<AirgapSetupScreen> createState() => _AirgapSetupScreenState();
}

class _AirgapSetupScreenState extends State<AirgapSetupScreen> {
  final _bridge = walletBridge;
  final _nameController = TextEditingController(text: 'My Air-gap Wallet');
  final _recvController = TextEditingController();
  final _changeController = TextEditingController();

  // The wizard's networks step asked for Liquid, but a QR-only device cannot
  // provide it: Jade's QR mode is Bitcoin-only — no master blinding key
  // export, no Liquid PSET transport. So this flow builds a Bitcoin wallet and
  // says so, instead of asking for a CT descriptor no device here can hand over.
  final bool _liquidWanted = newWalletDraft.liquidActive;

  int _step = 1;
  static const int _totalSteps = 4;

  _AirgapDevice? _device;
  bool _creating = false;
  String? _error;

  /// The created wallet, which is what the recap step reports on. Held so the
  /// summary shows what was actually stored — the descriptor the backend
  /// normalized and the key identity it parsed out of it — rather than what was
  /// typed into the field.
  WalletSummary? _created;

  @override
  void initState() {
    super.initState();
    // The Create button's enabled state lives in this parent — rebuild when
    // any gating field changes.
    for (final c in [_nameController, _recvController]) {
      c.addListener(_onFieldChanged);
    }
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
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

  @override
  void dispose() {
    _nameController.dispose();
    _recvController.dispose();
    _changeController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() { _creating = true; _error = null; });
    try {
      final wallet = await _bridge.createWatchOnlyWallet(
        _nameController.text.trim(),
        _recvController.text.trim(),
        _changeController.text.trim(),
        airgap: true,
      );
      if (mounted) {
        context.read<AppState>().setActiveWallet(
          wallet.id,
          name: wallet.name,
          // The backend's own label ("Air-gap watch-only"), so the wallet is
          // recognised as QR-signing everywhere: a bare 'Air-gap' would not
          // match the checks that keep Send available for this kind.
          type: wallet.typeLabel.isNotEmpty ? wallet.typeLabel : 'Air-gap',
          liquid: false,
        );
        setState(() { _creating = false; _created = wallet; _step = 4; });
      }
    } catch (e) {
      if (mounted) setState(() { _creating = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StepFlowScaffold(
      currentStep: widget.baseStep + _step,
      totalSteps: widget.baseStep + _totalSteps,
      title: _stepTitle,
      subtitle: _stepSubtitle,
      onBack: _step < 4
          ? (_step > 1 ? () => setState(() => _step--) : _exitToWizard)
          : null,
      onCancel: _step < 4 ? () => context.go(AppRoutes.walletPicker) : null,
      body: _stepBody(isDark),
      actions: _stepActions,
    );
  }

  String get _stepTitle => switch (_step) {
        1 => 'Choose your device',
        2 => 'Export descriptor',
        3 => 'Paste descriptor & name',
        _ => 'Pairing summary',
      };

  String get _stepSubtitle => switch (_step) {
        1 => 'Select the air-gap device you are using',
        2 => 'Follow the on-device steps to export the wallet descriptor',
        3 => 'Paste the descriptor shown on your device',
        _ => 'What was created, and where it came from',
      };

  Widget _stepBody(bool isDark) => switch (_step) {
        1 => _Step1Body(
              selected: _device,
              onSelect: (d) => setState(() => _device = d),
              liquidWanted: _liquidWanted,
              isDark: isDark,
            ),
        2 => _Step2Body(device: _device!, isDark: isDark),
        3 => _Step3Body(
              nameController: _nameController,
              recvController: _recvController,
              changeController: _changeController,
              creating: _creating,
              error: _error,
              isDark: isDark,
            ),
        _ => _RecapBody(
              wallet: _created!,
              device: _device!,
              liquidWanted: _liquidWanted,
            ),
      };

  Widget get _stepActions {
    if (_step == 4) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SecondaryButton(label: 'Get receive address', onPressed: () => context.go(AppRoutes.receive)),
          const SizedBox(width: AppSpacing.md),
          PrimaryButton(label: 'Open Wallet', onPressed: () => context.go(AppRoutes.dashboard)),
        ],
      );
    }
    if (_step == 3) {
      final canCreate = _recvController.text.trim().isNotEmpty &&
          _nameController.text.trim().isNotEmpty;
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GhostButton(label: 'Back', onPressed: () => setState(() => _step--)),
          const SizedBox(width: AppSpacing.md),
          PrimaryButton(
            label: _creating ? 'Creating…' : 'Create Wallet',
            onPressed: (canCreate && !_creating) ? _create : null,
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (_step > 1) GhostButton(label: 'Back', onPressed: () => setState(() => _step--)),
        const SizedBox(width: AppSpacing.md),
        PrimaryButton(
          label: 'Continue',
          onPressed: _step == 1 && _device == null ? null : () => setState(() => _step++),
        ),
      ],
    );
  }
}

// ── Step 1: device choice ─────────────────────────────────────────────────────

class _Step1Body extends StatelessWidget {
  const _Step1Body({
    required this.selected,
    required this.onSelect,
    required this.liquidWanted,
    required this.isDark,
  });
  final _AirgapDevice? selected;
  final void Function(_AirgapDevice) onSelect;

  /// Liquid was asked for in the wizard but cannot be delivered over QR —
  /// said here, before the user exports anything from the device, rather than
  /// discovered as a missing Liquid wallet after setup.
  final bool liquidWanted;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    if (liquidWanted) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const WarningBanner(
            title: 'This wallet will be Bitcoin-only',
            message: 'Liquid does not travel over QR: a Jade in QR mode signs '
                'Bitcoin only, and never hands out the blinding key a Liquid '
                'wallet needs. To use Liquid, go back and connect the Jade by '
                'USB cable instead — everything else about this setup stays '
                'the same.',
          ),
          const SizedBox(height: AppSpacing.lg),
          // Plain child, not Expanded: StepFlowScaffold scrolls the body, and
          // an Expanded inside a scroll view has no height to fill.
          _deviceCards(context),
        ],
      );
    }
    return _deviceCards(context);
  }

  Widget _deviceCards(BuildContext context) {
    if (AppLayout.isPhone(context)) {
      // Two 250 dp cards side by side are 524 dp; stacked they each get the
      // column.
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DeviceCard(
              label: 'SeedSigner',
              subtitle: 'Open-source DIY device',
              icon: Icons.developer_board_rounded,
              accent: AppColors.success,
              isSelected: selected == _AirgapDevice.seedSigner,
              onTap: () => onSelect(_AirgapDevice.seedSigner),
              isDark: isDark,
            ),
            const SizedBox(height: AppSpacing.md),
            _DeviceCard(
              label: 'Jade',
              subtitle: 'Blockstream hardware wallet',
              icon: Icons.memory_rounded,
              accent: AppColors.accent,
              isSelected: selected == _AirgapDevice.jade,
              onTap: () => onSelect(_AirgapDevice.jade),
              isDark: isDark,
            ),
          ],
        ),
      );
    }
    // The device choice is the whole step — make the two cards big and
    // centered instead of a cramped side row.
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xl),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 250,
              child: _DeviceCard(
                label: 'SeedSigner',
                subtitle: 'Open-source DIY device',
                icon: Icons.developer_board_rounded,
                accent: AppColors.success,
                isSelected: selected == _AirgapDevice.seedSigner,
                onTap: () => onSelect(_AirgapDevice.seedSigner),
                isDark: isDark,
              ),
            ),
            const SizedBox(width: AppSpacing.xl),
            SizedBox(
              width: 250,
              child: _DeviceCard(
                label: 'Jade',
                subtitle: 'Blockstream hardware wallet',
                icon: Icons.memory_rounded,
                accent: AppColors.accent,
                isSelected: selected == _AirgapDevice.jade,
                onTap: () => onSelect(_AirgapDevice.jade),
                isDark: isDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.isSelected,
    required this.onTap,
    required this.isDark,
  });
  final String label;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl, vertical: AppSpacing.xxl),
        decoration: BoxDecoration(
          color: isSelected
              ? accent.withValues(alpha: isDark ? 0.15 : 0.08)
              : (isDark ? AppColors.surfaceDark : AppColors.surfaceLight),
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          border: Border.all(
            color: isSelected ? accent : (isDark ? AppColors.borderDark : AppColors.borderLight),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: accent, size: 56),
            const SizedBox(height: AppSpacing.lg),
            Text(label,
                style: AppTypography.pageTitle.copyWith(fontSize: 20)),
            const SizedBox(height: AppSpacing.xs),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: AppTypography.bodySmall.copyWith(
                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                )),
            if (isSelected) ...[
              const SizedBox(height: AppSpacing.md),
              Icon(Icons.check_circle, color: accent, size: 22),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Step 2: on-device instructions ───────────────────────────────────────────

class _Step2Body extends StatelessWidget {
  const _Step2Body({required this.device, required this.isDark});
  final _AirgapDevice device;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final steps = device == _AirgapDevice.seedSigner
        ? [
            'Seeds → select your seed → Export Xpub',
            'Choose Native Segwit (P2WPKH) → Testnet',
            'The receive descriptor QR will be shown',
            'Scan or copy the descriptor on the next screen',
          ]
        : [
            // The unlock is where Jade QR setups stall: the animated QR the
            // device shows after the PIN is a pinserver handshake that needs
            // an online relay (the Blockstream app). Temporary Signer skips
            // the PIN entirely and stays offline.
            'Unlock the Jade: QR PIN unlock needs the Blockstream app to relay '
                'the animated QR — or use Options → Temporary Signer to enter '
                'your recovery phrase on the device instead',
            'Start a QR session, then Options → Wallet → Export Xpub',
            'Choose Native Segwit and the Testnet network',
            'Scan the animated QR on the next screen (or copy the descriptor)',
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoBanner(message: 'Follow these steps on your ${device == _AirgapDevice.seedSigner ? "SeedSigner" : "Jade"} device:'),
        const SizedBox(height: AppSpacing.xl),
        ...steps.asMap().entries.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text('${e.key + 1}',
                          style: AppTypography.label.copyWith(color: AppColors.accent)),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(e.value, style: AppTypography.body.copyWith(
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                    )),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}

// ── Step 3: paste descriptor + name ──────────────────────────────────────────

class _Step3Body extends StatefulWidget {
  const _Step3Body({
    required this.nameController,
    required this.recvController,
    required this.changeController,
    required this.creating,
    this.error,
    required this.isDark,
  });
  final TextEditingController nameController;
  final TextEditingController recvController;
  final TextEditingController changeController;
  final bool creating;
  final String? error;
  final bool isDark;

  @override
  State<_Step3Body> createState() => _Step3BodyState();
}

class _Step3BodyState extends State<_Step3Body> {
  bool _showChange = false;

  @override
  Widget build(BuildContext context) {
    if (widget.creating) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.lg),
          Text('Creating wallet…', style: AppTypography.body),
        ]),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.nameController,
            decoration: const InputDecoration(labelText: 'Wallet name'),
          ),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(child: TextField(
                controller: widget.recvController,
                decoration: const InputDecoration(
                  labelText: 'Receive descriptor',
                  hintText: 'wpkh([fingerprint/84\'/1\'/0\']tpub…/0/*)',
                ),
                maxLines: 3,
              )),
              const SizedBox(width: AppSpacing.sm),
              // Shared widget rather than a bespoke IconButton: it hides
              // itself where no camera plugin exists, so Windows/Linux see
              // Paste alone instead of a button that only apologises.
              ScanIconButton(
                controller: widget.recvController,
                title: 'Scan wallet QR (Jade: QR mode → Xpub export)',
                tooltip: 'Scan QR (Jade: QR mode → Xpub export)',
              ),
              IconButton(
                tooltip: 'Paste from clipboard',
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: () async {
                  final data = await Clipboard.getData('text/plain');
                  if (data?.text != null) {
                    widget.recvController.text = data!.text!.trim();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => setState(() => _showChange = !_showChange),
            child: Text(_showChange ? 'Hide change descriptor' : '+ Add change descriptor (optional)'),
          ),
          if (_showChange) ...[
            Row(
              children: [
                Expanded(child: TextField(
                  controller: widget.changeController,
                  decoration: const InputDecoration(
                    labelText: 'Change descriptor (optional)',
                    hintText: 'wpkh([fingerprint/84\'/1\'/0\']tpub…/1/*)',
                  ),
                  maxLines: 3,
                )),
                const SizedBox(width: AppSpacing.sm),
                ScanIconButton(
                  controller: widget.changeController,
                  title: 'Scan change descriptor',
                ),
                IconButton(
                  tooltip: 'Paste from clipboard',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null) {
                      widget.changeController.text = data!.text!.trim();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Change addresses live on a second descriptor chain (…/1/*), '
              'derived automatically from the receive descriptor. Leave this '
              'empty unless your device exports a separate change descriptor '
              'that cannot be derived (different key or account).',
              style: AppTypography.caption,
            ),
          ],
          if (widget.error != null) ...[
            const SizedBox(height: AppSpacing.lg),
            WarningBanner(title: 'Creation failed', message: widget.error!),
          ],
        ],
      ),
    );
  }
}

// ── Step 4: recap ─────────────────────────────────────────────────────────────
//
// The same summary shape the USB pairing ends on: what exists, per network, and
// which checks passed. An air-gap wallet is built from a descriptor the user
// carried across by QR or clipboard, so the checks that matter here are about
// that descriptor — was a key identity actually parsed out of it, and is the
// change chain separate from the receive chain.

class _RecapBody extends StatelessWidget {
  const _RecapBody({
    required this.wallet,
    required this.device,
    required this.liquidWanted,
  });

  final WalletSummary wallet;
  final _AirgapDevice device;

  /// Liquid was asked for in the wizard and cannot be delivered over QR. Said
  /// again here, because this is the screen the user leaves the flow from.
  final bool liquidWanted;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final deviceName = device == _AirgapDevice.seedSigner ? 'SeedSigner' : 'Jade';
    final fingerprint = wallet.masterFingerprint ?? '';

    return PairingRecapView(
      walletName: wallet.name,
      deviceLabel: '$deviceName (air-gap, QR)',
      fingerprint: fingerprint,
      networks: [
        PairingNetwork(
          name: 'Bitcoin',
          icon: Icons.currency_bitcoin,
          color: s.bitcoin,
          ok: true,
          detail: 'Watch-only here · your device signs the PSBT offline',
          descriptor: wallet.xpub,
        ),
        if (liquidWanted)
          PairingNetwork(
            name: 'Liquid Network',
            icon: Icons.water_drop_rounded,
            color: s.liquid,
            ok: false,
            // Not a missing feature: Jade's QR mode never exports the blinding
            // key a Liquid wallet needs, so no QR flow can produce one.
            detail: 'Not possible over QR — connect the Jade by USB to pair '
                'Liquid. Everything else about the setup is the same.',
          ),
      ],
      checks: [
        PairingCheck(
          label: 'Descriptor accepted and stored',
          passed: true,
          detail: wallet.typeLabel,
        ),
        PairingCheck(
          // A descriptor with no readable key origin still opens, but the
          // wallet then has no identity to match a signing device against.
          label: 'Key identity read from the descriptor',
          passed: fingerprint.isNotEmpty,
          detail: fingerprint.isNotEmpty ? fingerprint : 'none found',
        ),
        const PairingCheck(
          label: 'No private key stored on this computer',
          passed: true,
        ),
      ],
      footnote: 'Sending builds an unsigned PSBT here, shows it as a QR code '
          'for your device to sign offline, and takes the signed one back by '
          'QR, file or paste. Nothing but public keys ever leaves the device.',
    );
  }
}
