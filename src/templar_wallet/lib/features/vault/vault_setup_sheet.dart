import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// First-time vault setup dialog (Settings → Security → Encrypt wallet
/// storage). Asks for a passphrase twice, warns that losing it makes the
/// stored wallets unrecoverable, and runs [WalletBridge.setupVault] itself
/// (key derivation takes a moment). Pops `true` on success.
class VaultSetupSheet extends StatefulWidget {
  const VaultSetupSheet({super.key});

  @override
  State<VaultSetupSheet> createState() => _VaultSetupSheetState();
}

class _VaultSetupSheetState extends State<VaultSetupSheet> {
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final p = _passCtrl.text;
    if (p.length < 8) {
      setState(() => _error = 'Use at least 8 characters');
      return;
    }
    if (p != _confirmCtrl.text) {
      setState(() => _error = 'Passphrases do not match');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await walletBridge.setupVault(p);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = 'Setup failed: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassDialog(
      title: 'Encrypt wallet storage',
      icon: Icons.shield_outlined,
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Encrypt'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your wallet seeds are encrypted on disk with this passphrase '
            '(Argon2id + XChaCha20). You will enter it every time the app '
            'starts. The unencrypted wallet file and its backups are '
            'overwritten and deleted as part of this — though a '
            '${Platform.isAndroid ? 'cloud backup' : 'Time Machine snapshot'} '
            'or a copy made earlier is beyond Templar\'s reach.',
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
            ),
            child: Text(
              'If you lose this passphrase, the wallets stored in this app '
              'cannot be recovered without their seed-phrase backups.',
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          GlassPasswordField(
            controller: _passCtrl,
            label: 'Passphrase',
            autofocus: true,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: AppSpacing.md),
          GlassPasswordField(
            controller: _confirmCtrl,
            label: 'Confirm passphrase',
            errorText: _error,
            onSubmitted: _submit,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
    );
  }
}
