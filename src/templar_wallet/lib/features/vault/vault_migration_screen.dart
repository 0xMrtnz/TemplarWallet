import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'vault_passphrase_step.dart';

/// Startup gate for an install that is still holding recovery phrases in
/// cleartext.
///
/// # Why this blocks instead of nagging
///
/// The engine refuses to *write* a new seed without a vault, but that check
/// runs at wallet creation and can do nothing about phrases an earlier build
/// already wrote: those installs keep a readable `registry.json` forever. A
/// banner would leave the decision with the user, and the decision is between
/// "encrypted" and "every mnemonic on this disk is a plain string" — that is
/// not a preference, and there is no version of using the wallet meanwhile
/// that is safe. So the app does not open until it is done.
///
/// Setting the passphrase migrates the existing wallets into the sealed store
/// and shreds the plaintext file and its backups, so nothing is lost and
/// nothing readable is left behind. What Templar cannot reach is a copy made
/// before now — a Time Machine snapshot, a synced folder — which is why the
/// screen says so rather than implying the exposure is undone.
class VaultMigrationScreen extends StatefulWidget {
  const VaultMigrationScreen({
    super.key,
    required this.seedWalletCount,
    required this.onMigrated,
  });

  /// How many wallets currently have a phrase in the clear.
  final int seedWalletCount;
  final VoidCallback onMigrated;

  @override
  State<VaultMigrationScreen> createState() => _VaultMigrationScreenState();
}

class _VaultMigrationScreenState extends State<VaultMigrationScreen> {
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
      setState(() => _error = 'Passwords do not match');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await walletBridge.setupVault(p);
      if (!mounted) return;
      widget.onMigrated();
    } catch (e) {
      if (!mounted) return;
      // `setup` rolls back on failure, so the install is exactly as it was —
      // say that, or the user assumes a half-encrypted registry.
      setState(() {
        _busy = false;
        _error = 'Encryption failed, nothing was changed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.seedWalletCount;
    final plural = n == 1 ? 'wallet' : 'wallets';

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      // SafeArea: edge-to-edge on Android draws under the system bars.
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: AppColors.danger.withValues(alpha: 0.16),
                        borderRadius:
                            BorderRadius.circular(AppSpacing.radiusMd),
                        border: Border.all(
                          color: AppColors.danger.withValues(alpha: 0.5),
                        ),
                      ),
                      child: const Icon(
                        Icons.lock_open_rounded,
                        color: AppColors.danger,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text(
                      'Encrypt your wallets to continue',
                      style: AppTypography.pageTitle.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'This copy of Templar was set up before storage encryption '
                      'was required, so the recovery phrase of $n $plural is '
                      'saved on this computer as readable text — any program '
                      'running as you can read it.\n\n'
                      'Setting an app password now encrypts them (Argon2id + '
                      'XChaCha20-Poly1305) and deletes the readable copy. '
                      'Nothing is lost and no wallet changes.',
                      style: AppTypography.body.copyWith(
                        color: AppColors.textSecondaryDark,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _Note(
                      color: AppColors.warning,
                      icon: Icons.history_rounded,
                      text:
                          'A backup taken before today — Time Machine, a synced '
                          'folder, an old disk image — still holds the readable '
                          'file. Treat these phrases as exposed and move the '
                          'funds to a fresh wallet if they ever hold anything '
                          'you care about.',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _Note(
                      color: AppColors.danger,
                      icon: Icons.warning_amber_rounded,
                      text:
                          'If you lose this password, Templar cannot open these '
                          'wallets. Only your written recovery phrases can bring '
                          'them back.',
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    _field(_passCtrl, 'App password', autofocus: true),
                    const SizedBox(height: AppSpacing.sm),
                    _StrengthBar(strength: passphraseStrength(_passCtrl.text)),
                    const SizedBox(height: AppSpacing.md),
                    _field(_confirmCtrl, 'Confirm password', onSubmit: _submit),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        _error!,
                        style: AppTypography.bodySmall.copyWith(
                          color: AppColors.danger,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.lg,
                          ),
                        ),
                        child: _busy
                            // Argon2id at 256 MiB takes a moment; say what is
                            // happening or it reads as a hang.
                            ? const Text(
                                'Encrypting…',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              )
                            : const Text(
                                'Encrypt and continue',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'One password covers every wallet in Templar. You will be '
                      'asked for it each time the app starts.',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textMutedDark,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    bool autofocus = false,
    VoidCallback? onSubmit,
  }) => TextField(
    controller: ctrl,
    obscureText: true,
    autofocus: autofocus,
    enabled: !_busy,
    keyboardType: TextInputType.visiblePassword,
    style: const TextStyle(color: Colors.white, fontSize: 16),
    onChanged: (_) => setState(() => _error = null),
    onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
    decoration: InputDecoration(
      hintText: label,
      hintStyle: TextStyle(color: AppColors.textMutedDark, fontSize: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        borderSide: const BorderSide(color: AppColors.borderDark),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        borderSide: BorderSide(color: AppColors.accent, width: 2),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.color, required this.icon, required this.text});
  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: AppTypography.bodySmall.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Same 0..4 scale as the wizard's meter, drawn dark-on-dark for this screen.
class _StrengthBar extends StatelessWidget {
  const _StrengthBar({required this.strength});
  final int strength;

  static const _labels = ['', 'Weak', 'Fair', 'Good', 'Strong'];
  static const _colors = [
    Colors.transparent,
    AppColors.danger,
    AppColors.warning,
    AppColors.successMuted,
    AppColors.success,
  ];

  @override
  Widget build(BuildContext context) {
    final color = _colors[strength];
    return Row(
      children: [
        for (var i = 1; i <= 4; i++) ...[
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= strength ? color : AppColors.borderDark,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < 4) const SizedBox(width: AppSpacing.xs),
        ],
        const SizedBox(width: AppSpacing.md),
        SizedBox(
          width: 48,
          child: Text(
            _labels[strength],
            style: AppTypography.caption.copyWith(
              color: strength == 0 ? AppColors.textMutedDark : color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
