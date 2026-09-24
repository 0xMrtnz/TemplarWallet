import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/step_header.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../vault/vault_setup_sheet.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../shared/widgets/glass_dialog.dart';

class ImportWalletScreen extends StatefulWidget {
  const ImportWalletScreen({super.key});

  @override
  State<ImportWalletScreen> createState() => _ImportWalletScreenState();
}

class _ImportWalletScreenState extends State<ImportWalletScreen> {
  final _bridge = walletBridge;
  final _mnemonicController = TextEditingController();
  final _nameController = TextEditingController(text: 'Restored Wallet');
  bool _importing = false;
  String? _error;

  /// Restore used to hard-code Bitcoin-only, which left the recovered wallet
  /// with no Liquid descriptor: no LIQUID section, no L-BTC address in
  /// Receive, no CT descriptor in Wallet Info. The same seed derives both
  /// chains, so the question is asked here exactly as the creation wizard
  /// asks it — and defaults the same way.
  bool _liquidEnabled = true;

  List<String> get _words => _mnemonicController.text
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  bool get _validWordCount => _words.length == 12 || _words.length == 24;

  bool get _canImport =>
      _validWordCount && _nameController.text.trim().isNotEmpty && !_importing;

  @override
  void dispose() {
    _mnemonicController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  /// A2 — a restored phrase is written to wallet storage, so encryption has to
  /// exist before the import, not as an afterthought. This screen is outside
  /// the new-wallet wizard (which has its own mandatory password step), so it
  /// asks here; the backend refuses the import either way, and a refusal after
  /// the user typed 24 words is a worse way to learn it. Returns false when the
  /// user backs out of the dialog.
  Future<bool> _ensureEncryption() async {
    try {
      if ((await _bridge.vaultStatus()).initialized) return true;
    } catch (_) {
      // Bridge unavailable — let the import itself surface the real error.
      return true;
    }
    if (!mounted) return false;
    final created = await showAppDialog<bool>(context,
      barrierDismissible: false,
      builder: (_) => const VaultSetupSheet(),
    );
    return created == true;
  }

  Future<void> _import() async {
    final words = _words;
    final name = _nameController.text.trim();
    setState(() {
      _importing = true;
      _error = null;
    });
    if (!await _ensureEncryption()) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error =
              'Set an app password first — Templar will not store a '
              'recovery phrase on this computer unencrypted.';
        });
      }
      return;
    }
    if (!mounted) return;
    try {
      final walletId = await _bridge.createWallet(
        name,
        words,
        liquid: _liquidEnabled,
      );
      if (mounted) {
        context.read<AppState>().setActiveWallet(
          walletId,
          name: name,
          type: 'Software',
          liquid: _liquidEnabled,
        );
        context.go(AppRoutes.dashboard);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _error = e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wordCount = _words.length;

    // Android back: leave to the picker like the on-screen Cancel does,
    // instead of exiting the app with the typed words lost.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(AppRoutes.walletPicker);
      },
      child: Scaffold(
        body: PageBackground.flat(
          // Edge-to-edge on mobile: the title must clear the status bar.
          child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
                children: [
                  PageHeader(
                    title: 'Restore Wallet',
                    subtitle:
                        'Import an existing wallet from a BIP39 seed phrase',
                    actions: [
                      GhostButton(
                        label: 'Cancel',
                        onPressed: () => context.go(AppRoutes.walletPicker),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  const WarningBanner(
                    title: 'Keep your seed phrase private',
                    message:
                        'Never enter your seed phrase on an untrusted device or '
                        'application. Templar stores it encrypted with your app '
                        'password — it is never written to disk in the clear.',
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  FormCard(
                    title: 'Seed phrase',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _mnemonicController,
                          maxLines: 5,
                          // Seed words must never reach the keyboard's
                          // autocorrect or personal dictionary.
                          autocorrect: false,
                          enableSuggestions: false,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            hintText:
                                'Enter your 12 or 24 word seed phrase, separated by spaces…',
                            alignLabelWithHint: true,
                          ),
                          style: AppTypography.mono,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          children: [
                            Text(
                              wordCount == 0
                                  ? 'Enter seed phrase above'
                                  : '$wordCount word${wordCount == 1 ? '' : 's'}',
                              style: AppTypography.caption.copyWith(
                                color: _validWordCount
                                    ? AppColors.success
                                    : wordCount > 0
                                    ? AppColors.warning
                                    : AppColors.textMuted,
                              ),
                            ),
                            const Spacer(),
                            if (_validWordCount)
                              const Icon(
                                Icons.check_circle,
                                size: 14,
                                color: AppColors.success,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FormCard(
                    title: 'Wallet name',
                    child: TextField(
                      controller: _nameController,
                      onChanged: (_) => setState(() {}),
                      // The FormCard title above is already this field's
                      // label; on a 379 dp column a floating Material label
                      // on top of it labels one field twice, and it fights
                      // the borderless filled phone field. A resting hint
                      // says the same thing without the second line.
                      decoration: InputDecoration(
                        labelText: AppLayout.isPhone(context) ? null : 'Name',
                        hintText:
                            AppLayout.isPhone(context) ? 'Wallet name' : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FormCard(
                    title: 'Coins',
                    subtitle:
                        'Both chains come from the phrase you just entered',
                    child: Column(
                      children: [
                        SelectableOptionCard(
                          title: 'Bitcoin + Liquid',
                          description:
                              'Restores the paired Liquid wallet too — confidential '
                              'L-BTC and Liquid assets, same recovery phrase.',
                          isSelected: _liquidEnabled,
                          icon: Icons.water_drop_outlined,
                          onTap: () => setState(() => _liquidEnabled = true),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SelectableOptionCard(
                          title: 'Bitcoin only',
                          description:
                              'Just the Bitcoin network. The Liquid section stays '
                              'hidden; you can turn it on later from Wallet Info.',
                          isSelected: !_liquidEnabled,
                          icon: Icons.currency_bitcoin,
                          onTap: () => setState(() => _liquidEnabled = false),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    DangerBanner(message: _error!),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  if (_importing)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: AppSpacing.md),
                          Text('Restoring wallet…', style: AppTypography.body),
                        ],
                      ),
                    )
                  else if (AppLayout.isPhone(context))
                    // One full-width action at the foot. The footer Cancel
                    // would be this screen's SECOND Cancel — the header
                    // already carries one, and Android back is wired to the
                    // same route by the PopScope above — while the primary
                    // action would sit at intrinsic width in the corner.
                    PrimaryButton(
                      label: 'Restore Wallet',
                      icon: Icons.restore,
                      isFullWidth: true,
                      onPressed: _canImport ? _import : null,
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        GhostButton(
                          label: 'Cancel',
                          onPressed: () => context.go(AppRoutes.walletPicker),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        PrimaryButton(
                          label: 'Restore Wallet',
                          icon: Icons.restore,
                          onPressed: _canImport ? _import : null,
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),),
    );
  }
}
