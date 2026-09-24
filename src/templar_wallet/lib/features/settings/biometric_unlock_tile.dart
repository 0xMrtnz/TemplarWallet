// Biometric vault unlock, in two skins: a row in the settings list and a card
// on the Security page. One implementation, because the enable path is the
// delicate part — the vault key can only be exported from an open vault, so a
// locked one is sent through the usual unlock screen first.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:biometric_storage/biometric_storage.dart' show AuthException;
import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../services/biometric_unlock_service.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/list_rows.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../vault/lock_action.dart';

/// Android and macOS: a fingerprint (Touch ID on a Mac) standing in for the
/// vault passphrase at launch (see [BiometricUnlockService]). Hidden on
/// devices without a usable
/// sensor; disabled, with a hint, when there is a sensor and nothing is
/// enrolled. Turning it on shows the system prompt right away — the vault
/// key can only be exported from an open vault, so a locked one is sent
/// through the usual unlock screen first.
class BiometricUnlockTile extends StatefulWidget {
  const BiometricUnlockTile({super.key, this.compact = false});

  /// Render as one row of the settings list instead of a card of its own.
  final bool compact;

  @override
  State<BiometricUnlockTile> createState() => _BiometricUnlockTileState();
}

class _BiometricUnlockTileState extends State<BiometricUnlockTile> {
  BiometricAvailability? _availability;
  bool _enabled = false;
  bool _busy = false;

  /// The Mac's second switch: the sensor at the confirmation gates too.
  bool _confirm = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bio = BiometricUnlockService.instance;
    final availability = await bio.availability();
    final enabled = await bio.isEnabled();
    final confirm = await bio.isConfirmEnabled();
    if (!mounted) return;
    setState(() {
      _availability = availability;
      _enabled = enabled;
      _confirm = confirm;
    });
  }

  Future<void> _toggleConfirm(bool on) async {
    await BiometricUnlockService.instance.setConfirmEnabled(on);
    if (!mounted) return;
    setState(() => _confirm = on);
    _snack(on
        ? '${BiometricUnlockService.sensorName} now confirms signing and '
            'reveals too.'
        : 'Confirmations ask for the passphrase again.');
  }

  void _snack(String text, {bool danger = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: danger ? AppColors.danger : null,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    if (!on) {
      setState(() => _busy = true);
      await BiometricUnlockService.instance.disable();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Biometric unlock is off.');
      await _load();
      return;
    }
    VaultStatus status;
    try {
      status = await walletBridge.vaultStatus();
    } catch (e) {
      _snack('Could not read the vault status: $e', danger: true);
      return;
    }
    if (!mounted) return;
    if (!status.initialized) {
      _snack('Set a vault passphrase first.', danger: true);
      return;
    }
    if (!status.unlocked) {
      // The existing full-screen unlock, then straight into enabling —
      // whether or not this card is still on screen by then.
      _snack('Unlock wallet storage first.');
      pushVaultUnlock(context, onUnlocked: () => unawaited(_enable()));
      return;
    }
    await _enable();
  }

  Future<void> _enable() async {
    if (mounted) setState(() => _busy = true);
    try {
      await BiometricUnlockService.instance.enable();
      _snack('${BiometricUnlockService.sensorName} unlock is on.');
    } on BiometricUnlockCancelled {
      // Prompt dismissed: the switch simply stays off.
    } catch (e) {
      // The plugin answers "available" on devices with no screen lock and
      // fails only when the Keystore key is created; keep the raw text out
      // of the UI and say what to do instead.
      debugPrint('biometric unlock enable: $e');
      final raw = e.toString().toLowerCase();
      final mac = Platform.isMacOS;
      final String msg;
      if (raw.contains('enrolled') || raw.contains('none_enrolled')) {
        msg = mac
            ? 'No fingerprint is enrolled in Touch ID. Add one in System '
                'Settings › Touch ID & Password, then try again.'
            : 'No fingerprint is enrolled on this device. Add one in Android '
                'Settings › Security, then try again.';
      } else if (raw.contains('screen lock') ||
          raw.contains('secure lock') ||
          raw.contains('keystore') ||
          raw.contains('keygenerator')) {
        msg = 'Set a screen lock and a fingerprint in Android Settings › '
            'Security first, then try again.';
      } else if (e is StateError) {
        msg = e.message;
      } else if (e is AuthException) {
        msg = e.message;
      } else {
        msg = mac
            ? 'Could not enable Touch ID unlock. Check that Touch ID is set '
                'up in System Settings.'
            : 'Could not enable biometric unlock. Check that a screen lock '
                'and a fingerprint are set on this device.';
      }
      _snack(msg, danger: true);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final availability = _availability;
    final usable = availability == BiometricAvailability.available;

    if (widget.compact) {
      // Inside the settings list the row is always drawn — the list decides
      // whether this device has a sensor at all, and a row that vanished
      // mid-card would leave a hairline with nothing under it.
      final sensor = BiometricUnlockService.sensorName;
      final String subtitle;
      if (availability == null) {
        subtitle = 'Checking this device…';
      } else if (usable) {
        subtitle = '$sensor opens the vault';
      } else if (availability == BiometricAvailability.unavailable) {
        subtitle = 'Not available on this device';
      } else {
        subtitle = Platform.isMacOS
            ? 'No fingerprint enrolled in Touch ID'
            : 'No fingerprint enrolled on this device';
      }
      return ListRow(
        icon: Icons.fingerprint_rounded,
        tint: AppScheme.of(context).success,
        title: Platform.isMacOS ? 'Touch ID unlock' : 'Biometric unlock',
        subtitle: subtitle,
        trailing: ListSwitch(
          value: _enabled,
          onChanged: usable && !_busy ? _toggle : null,
          semanticLabel: 'Biometric unlock',
        ),
      );
    }

    if (availability == null ||
        availability == BiometricAvailability.unavailable) {
      return const SizedBox.shrink();
    }
    // The Mac gets a second switch under the first: the sensor at the
    // confirmation gates. Only shown while the unlock is on — without the
    // sealed key there is nothing for a confirmation to prove.
    final confirmRow = Platform.isMacOS && _enabled;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: SectionCard(
        title: Platform.isMacOS ? 'Touch ID unlock' : 'Biometric unlock',
        child: Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(Platform.isMacOS
                  ? 'Unlock with Touch ID'
                  : 'Unlock with fingerprint'),
              subtitle: Text(
                usable
                    ? Platform.isMacOS
                        ? 'Touch ID opens the vault at launch and after '
                            '“Lock now”.'
                        : '${BiometricUnlockService.sensorName} opens the '
                            'vault. The passphrase is still asked to reveal '
                            'the seed and to sign.'
                    : Platform.isMacOS
                        ? 'No fingerprint is enrolled in Touch ID. Add one in '
                            'System Settings › Touch ID & Password first.'
                        : 'No fingerprint is enrolled on this device. Add one '
                            'in the system settings first.',
                style: AppTypography.caption,
              ),
              value: _enabled,
              onChanged: usable && !_busy ? _toggle : null,
              activeThumbColor: AppColors.accent,
            ),
            if (confirmRow)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Also confirm with Touch ID'),
                subtitle: Text(
                  'Signing, sharing wallet data and revealing the seed take '
                  'Touch ID in place of the app password. The password '
                  'always works too.',
                  style: AppTypography.caption,
                ),
                value: _confirm,
                onChanged: _busy ? null : _toggleConfirm,
                activeThumbColor: AppColors.accent,
              ),
          ],
        ),
      ),
    );
  }
}
