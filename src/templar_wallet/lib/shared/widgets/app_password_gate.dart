import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../services/biometric_unlock_service.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'buttons.dart';
import 'glass_dialog.dart';

/// Ask for the app password immediately before a signature.
///
/// Verifying proves the password against the vault's Argon2id verifier and
/// throws the derived key away — it does not open a session, and an unlocked
/// vault does not skip it. That is the point: the vault is unlocked for as
/// long as the app is running, so without this gate a wallet left open on a
/// desk is one click away from spending. Signing is the one action worth
/// asking twice for.
///
/// On a Mac with Touch ID unlock on (and "Also confirm with Touch ID" left
/// on), the sheet offers the sensor instead: it prompts as soon as the gate
/// opens and again from "Use Touch ID", and the passphrase field stays as
/// the way past a failed or dismissed prompt. See
/// [BiometricUnlockService.confirm] for what a sensor pass proves.
///
/// Returns true when the password was proven.
Future<bool> showSpendPasswordGate(
  BuildContext context, {
  required String message,
  String title = 'Confirm with your app password',
  String confirmLabel = 'Sign',
}) async {
  // Frosted dialog on desktop; on a phone [GlassDialog] renders as a bottom
  // sheet that rises with the keyboard, so the field is never covered.
  final ok = await showAppDialog<bool>(
    context,
    barrierDismissible: false,
    builder: (_) => _SpendPasswordGateDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
    ),
  );
  return ok == true;
}

class _SpendPasswordGateDialog extends StatefulWidget {
  const _SpendPasswordGateDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });
  final String title;
  final String message;

  /// What the confirm button says — "Sign" for a signature, "Share" when
  /// the gated action hands out wallet data instead.
  final String confirmLabel;

  @override
  State<_SpendPasswordGateDialog> createState() =>
      _SpendPasswordGateDialogState();
}

class _SpendPasswordGateDialogState extends State<_SpendPasswordGateDialog> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_ctrl.text.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await walletBridge.verifyVaultPassphrase(_ctrl.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      // The engine's message carries the useful part — attempts left, or how
      // long the gate is locked — so it is shown as-is, minus the transport's
      // framing.
      setState(() {
        _checking = false;
        _error = e
            .toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('wallet-ffi: ', '');
        _ctrl.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);

    final cancel = TextButton(
      onPressed: _checking ? null : () => Navigator.of(context).pop(false),
      child: const Text('Cancel'),
    );
    final confirm = FilledButton(
      onPressed: _checking ? null : _submit,
      child: _checking
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(widget.confirmLabel),
    );

    // While the vault is checking, the back gesture must not do what the
    // disabled Cancel refuses: the caller reads a dismissed gate as "no".
    return PopScope(
      canPop: !_checking,
      child: GlassDialog(
        title: widget.title,
        icon: Icons.lock_outline,
        actions: phone
            ? [
                // Stacked, full width: confirm where the thumb lands, Cancel
                // as the quiet line beneath it.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // No height clamp: the button states its own (54 dp on a
                    // phone, the theme's on desktop). Pinning it to 48 made
                    // the one confirm in the app six short of its siblings.
                    confirm,
                    const SizedBox(height: AppSpacing.xs),
                    cancel,
                  ],
                ),
              ]
            : [cancel, confirm],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message, style: AppTypography.caption),
            const SizedBox(height: AppSpacing.md),
            GlassPasswordField(
              controller: _ctrl,
              autofocus: true,
              errorText: _error,
              onSubmitted: _submit,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            BiometricGateButton(
              reason: 'confirm with Touch ID',
              onConfirmed: () => Navigator.of(context).pop(true),
              onMessage: (m) => setState(() => _error = m),
              fullWidth: phone,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Use Touch ID" beneath a password field.
///
/// Draws nothing unless [BiometricUnlockService.confirmAvailable] says the
/// sensor may stand in here. Where it may, it prompts on its own as soon as
/// it appears — the gate opened for exactly this — and again on tap. A pass
/// calls [onConfirmed]; anything else leaves the password field in charge,
/// with [onMessage] carrying the reason when there is one worth showing
/// (a lockout, a key that stopped matching). Never throws.
class BiometricGateButton extends StatefulWidget {
  const BiometricGateButton({
    super.key,
    required this.reason,
    required this.onConfirmed,
    this.onMessage,
    this.autoPrompt = true,
    this.fullWidth = false,
  });

  /// What the Mac's sheet says the app is trying to do.
  final String reason;
  final VoidCallback onConfirmed;
  final void Function(String? message)? onMessage;

  /// Prompt once, unasked, when the button first appears.
  final bool autoPrompt;
  final bool fullWidth;

  @override
  State<BiometricGateButton> createState() => _BiometricGateButtonState();
}

class _BiometricGateButtonState extends State<BiometricGateButton> {
  bool _available = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    bool available;
    try {
      available = await BiometricUnlockService.instance.confirmAvailable();
    } catch (_) {
      available = false;
    }
    if (!mounted) return;
    setState(() => _available = available);
    if (available && widget.autoPrompt) await _prompt();
  }

  Future<void> _prompt() async {
    if (_busy) return;
    setState(() => _busy = true);
    final bio = BiometricUnlockService.instance;
    final ok = await bio.confirm(reason: widget.reason);
    if (!mounted) return;
    if (ok) {
      widget.onConfirmed();
      return;
    }
    // Dismissed, or the feature switched itself off: the password is the
    // way in now, and the button follows the feature.
    final still = await bio.confirmAvailable();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _available = still;
    });
    widget.onMessage?.call(bio.lastMessage);
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SecondaryButton(
          label: 'Use ${BiometricUnlockService.sensorName}',
          icon: Icons.fingerprint,
          isFullWidth: widget.fullWidth,
          onPressed: _busy ? null : _prompt,
        ),
      ),
    );
  }
}
