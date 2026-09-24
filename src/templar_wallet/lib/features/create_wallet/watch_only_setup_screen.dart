import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/scan_button.dart';
import '../../shared/widgets/step_flow_scaffold.dart';
import '../../shared/widgets/step_header.dart';
import '../../shared/widgets/wallet_created_view.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/new_wallet_draft.dart';

/// Create a watch-only wallet from public keys. Two ways in, picked at the
/// top of the step: paste one finished key or descriptor, or build the wallet
/// from each cosigner's key — which hands the flow to the multisig
/// coordinator screens, the same ones a spending multisig uses.
///
/// The Bitcoin field accepts a bare xpub (wrapped into a native-SegWit
/// descriptor) or a full descriptor.
/// When the wizard's networks step chose Bitcoin + Liquid, a Liquid CT
/// descriptor is also collected — scanned, pasted, or derived (ELIP151) from
/// the Bitcoin descriptor. The choice is not re-asked here.
class WatchOnlySetupScreen extends StatefulWidget {
  const WatchOnlySetupScreen({
    super.key,
    this.baseStep = 0,
    this.onBackToWizard,
    this.onUseCosignerKeys,
  });

  /// Questions already answered by the wizard hosting this setup —
  /// the step counter continues from here instead of restarting at 1.
  final int baseStep;

  /// Back from the first step: return to the wizard's last question.
  /// Null (standalone route) falls back to navigating there.
  final VoidCallback? onBackToWizard;

  /// The user chose to build this wallet from its cosigners' keys — the host
  /// swaps in the multisig coordinator flow. Null (standalone route) hides
  /// the choice, since there is nothing here to hand the flow to.
  final VoidCallback? onUseCosignerKeys;

  @override
  State<WatchOnlySetupScreen> createState() => _WatchOnlySetupScreenState();
}

class _WatchOnlySetupScreenState extends State<WatchOnlySetupScreen> {
  final _bridge = walletBridge;
  final _nameController = TextEditingController(text: 'Watch-only Wallet');
  final _btcController = TextEditingController();
  final _ctController = TextEditingController();

  // From the wizard's networks step.
  final bool _liquid = newWalletDraft.liquidActive;

  /// Which of the two ways in is selected. Persisted on the draft so coming
  /// back from the cosigner flow lands on the choice that opened it — and
  /// forced off on the standalone route, which has nowhere to hand it to.
  bool get _fromCosigners =>
      widget.onUseCosignerKeys != null && newWalletDraft.watchOnlyFromCosigners;

  // 1 = details, 2 = success.
  int _step = 1;
  bool _creating = false;
  bool _deriving = false;
  String? _error;
  String? _deriveError;

  bool get _canCreate =>
      !_creating &&
      _nameController.text.trim().isNotEmpty &&
      _btcController.text.trim().isNotEmpty &&
      (!_liquid || _ctController.text.trim().isNotEmpty);

  @override
  void dispose() {
    _nameController.dispose();
    _btcController.dispose();
    _ctController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    setState(() { _creating = true; _error = null; });
    try {
      // Raw input is normalized in templar-core: a bare xpub is wrapped into a
      // wpkh descriptor, a multipath descriptor is split, and the change
      // descriptor is derived. So send the BTC input as the receive descriptor
      // and let the core handle the rest.
      final wallet = await _bridge.createWatchOnlyWallet(
        name,
        _btcController.text.trim(),
        '',
        liquidCtDescriptor: _liquid ? _ctController.text.trim() : null,
      );
      if (mounted) {
        context.read<AppState>().setActiveWallet(
          wallet.id,
          name: wallet.name,
          type: 'Watch-only',
          liquid: _liquid,
        );
        setState(() { _creating = false; _step = 2; });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
  }

  /// Fill the CT field from the Bitcoin field via ELIP151 — no seed needed.
  Future<void> _deriveCt() async {
    final btc = _btcController.text.trim();
    if (btc.isEmpty) {
      setState(() => _deriveError = 'Fill the Bitcoin key or descriptor first.');
      return;
    }
    setState(() { _deriving = true; _deriveError = null; });
    try {
      final ct = await _bridge.deriveLiquidDescriptor(btc);
      if (mounted) {
        setState(() {
          _deriving = false;
          _ctController.text = ct;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _deriving = false;
          _deriveError = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
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
  Widget build(BuildContext context) {
    return StepFlowScaffold(
      currentStep: widget.baseStep + _step,
      // The cosigner route hands over to the four multisig coordinator steps;
      // counting them here keeps the bar from lurching on the handover.
      totalSteps: widget.baseStep + (_fromCosigners ? 4 : 2),
      title: _step == 1 ? 'Watch-only Wallet' : 'Wallet created',
      subtitle: _step == 1 ? _detailsSubtitle : null,
      headerVariants: const [
        StepHeaderVariant('Watch-only Wallet', _pasteSubtitle),
        StepHeaderVariant('Watch-only Wallet', _cosignerSubtitle),
        StepHeaderVariant('Wallet created'),
      ],
      onBack: _step == 1 ? _exitToWizard : null,
      onCancel: _step == 1 ? () => context.go(AppRoutes.walletPicker) : null,
      body: _step == 1
          ? (_fromCosigners ? _cosignerBody() : _detailsBody())
          : _successBody(),
      actions: _actions(),
    );
  }

  static const _pasteSubtitle =
      'Track funds from an xpub or descriptor — view only, no spending';
  static const _cosignerSubtitle =
      'Track an M-of-N wallet from its cosigners\' keys — view only, no spending';

  String get _detailsSubtitle =>
      _fromCosigners ? _cosignerSubtitle : _pasteSubtitle;

  /// The two ways in. Hidden on the standalone route, which has no host to
  /// hand the cosigner flow to.
  Widget _sourcePicker() {
    if (widget.onUseCosignerKeys == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          ChoiceTile(
            label: 'Paste a key or descriptor',
            icon: Icons.content_paste_rounded,
            selected: !_fromCosigners,
            onSelected: () =>
                setState(() => newWalletDraft.watchOnlyFromCosigners = false),
          ),
          ChoiceTile(
            label: 'Build from cosigner keys',
            icon: Icons.group_rounded,
            selected: _fromCosigners,
            onSelected: () =>
                setState(() => newWalletDraft.watchOnlyFromCosigners = true),
          ),
        ],
      ),
    );
  }

  /// What the cosigner route does, before it takes the flow over.
  Widget _cosignerBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sourcePicker(),
        const InfoBanner(
          title: 'The next steps collect every cosigner',
          message: 'You pick the threshold — 2 of 3, 3 of 5 — and then provide '
              'each key: pasted, scanned from an air-gapped signer, read from '
              'a USB device, or taken from another wallet in this app. '
              'Templar assembles the descriptor for you. No private key is '
              'held here, so the wallet watches but cannot sign.',
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Already have the finished descriptor? Choose "Paste a key or '
          'descriptor" above — it is one field and one step.',
          style: AppTypography.caption,
        ),
      ],
    );
  }

  Widget _detailsBody() {
    if (_creating) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.md),
            Text('Creating watch-only wallet…', style: AppTypography.body),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sourcePicker(),
        const InfoBanner(
          message: 'A watch-only wallet holds no private key. It can show '
              'balances and history and build unsigned transactions, but it '
              'cannot sign or spend.',
        ),
        const SizedBox(height: AppSpacing.xl),

        // ── Name ───────────────────────────────────────────────────────
        FormCard(
          title: 'Wallet name',
          child: TextField(
            controller: _nameController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),

        // ── Bitcoin key / descriptor ───────────────────────────────────
        FormCard(
          title: 'Bitcoin key or descriptor',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _btcController,
                      maxLines: 3,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'tpub… or wpkh(tpub…/<0;1>/*)',
                        alignLabelWithHint: true,
                      ),
                      style: AppTypography.monoSmall,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  ScanIconButton(
                    controller: _btcController,
                    title: 'Scan Bitcoin xpub / descriptor',
                    tooltip: 'Scan QR (Jade: QR mode → Xpub export)',
                    onScanned: (_) => setState(() {}),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Paste an extended public key (xpub/tpub) — wrapped as native '
                'SegWit — or a full output descriptor. The QR button reads a '
                'signer\'s xpub export (BC-UR or plain text).',
                style: AppTypography.caption,
              ),
            ],
          ),
        ),

        // ── Liquid CT descriptor (conditional) ─────────────────────────
        if (_liquid) ...[
          const SizedBox(height: AppSpacing.lg),
          FormCard(
            title: 'Liquid CT descriptor',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctController,
                        maxLines: 3,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'ct(slip77(…),elwpkh(…))',
                          alignLabelWithHint: true,
                        ),
                        style: AppTypography.monoSmall,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    ScanIconButton(
                      controller: _ctController,
                      title: 'Scan Liquid CT descriptor',
                      onScanned: (_) => setState(() {}),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: Text(_deriving
                        ? 'Deriving…'
                        : 'Derive from the Bitcoin descriptor'),
                    onPressed: _deriving ? null : _deriveCt,
                  ),
                ),
                Text(
                  'A confidential Liquid descriptor including the blinding key '
                  '— e.g. ct(slip77(<key>),elwpkh(<xpub>/<0;1>/*)). Derive uses '
                  'ELIP151 (this app\'s convention); wallets with a seed-derived '
                  'SLIP77 key need their own exported descriptor.',
                  style: AppTypography.caption,
                ),
                if (_deriveError != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _deriveError!,
                    style: AppTypography.caption.copyWith(color: AppColors.danger),
                  ),
                ],
              ],
            ),
          ),
        ],

        if (_error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          DangerBanner(message: _error!),
        ],
      ],
    );
  }

  Widget _successBody() {
    return WalletCreatedView(
      walletName: _nameController.text.trim(),
      subtitle: 'Watch-only wallet ready — balances and history, no spending keys.',
      details: [
        WalletCreatedDetail('Type', 'Watch-only · Single-sig'),
        WalletCreatedDetail('Networks',
            _liquid ? 'Bitcoin + Liquid' : 'Bitcoin only'),
        WalletCreatedDetail('Bitcoin key', _btcController.text.trim(), mono: true),
        if (_liquid)
          WalletCreatedDetail('Liquid CT', _ctController.text.trim(), mono: true),
      ],
    );
  }

  Widget _actions() {
    if (_creating) return const SizedBox.shrink();
    if (_step == 2) {
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        GhostButton(label: 'Back', onPressed: _exitToWizard),
        const SizedBox(width: AppSpacing.md),
        if (_fromCosigners)
          PrimaryButton(
            label: 'Continue',
            icon: Icons.group_rounded,
            onPressed: widget.onUseCosignerKeys,
          )
        else
          PrimaryButton(
            label: 'Create Wallet',
            icon: Icons.visibility_outlined,
            onPressed: _canCreate ? _create : null,
          ),
      ],
    );
  }
}
