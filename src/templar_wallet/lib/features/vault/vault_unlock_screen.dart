import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../services/biometric_unlock_service.dart';
import '../../shared/widgets/app_logo.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Shown at app launch (and after "Lock now") when wallet storage is
/// encrypted and the vault key is not in memory. Calls [onUnlocked] once the
/// passphrase decrypts the registry.
///
/// Styled as a page of the app rather than a splash: flat canvas, the brand
/// mark at its normal size, one bordered panel. The old screen was pinned to
/// dark regardless of the user's theme and led with a 60px solid-crimson
/// shield — the loudest object in the whole product sitting in front of a
/// password field, which is exactly the moment to look calm and familiar.
///
/// On Android and macOS, when the user has enabled it, a fingerprint (Touch
/// ID on a Mac) can open the vault instead: the system prompt shows on its
/// own when the screen appears (see [biometricAutoPrompt]) and a "Use
/// fingerprint" / "Use Touch ID" button repeats it. The passphrase path is
/// untouched either way.
class VaultUnlockScreen extends StatefulWidget {
  const VaultUnlockScreen({
    super.key,
    required this.onUnlocked,
    this.biometricAutoPrompt = true,
  });
  final VoidCallback onUnlocked;

  /// Show the fingerprint prompt unasked as soon as the screen appears
  /// (feature enabled on a supported platform). The launch gate passes
  /// false — it has already prompted once and a second sheet would be a
  /// double ask.
  final bool biometricAutoPrompt;

  @override
  State<VaultUnlockScreen> createState() => _VaultUnlockScreenState();
}

class _VaultUnlockScreenState extends State<VaultUnlockScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  /// "Use fingerprint" / "Use Touch ID" is offered: supported platform,
  /// usable sensor, feature on.
  bool _biometricAvailable = false;
  bool _biometricBusy = false;

  /// While an automatic prompt may still come, the passphrase field does not
  /// take focus — a keyboard sliding up under the system sheet is noise.
  /// Released once the attempt is over or turns out not to apply; the field
  /// is remounted then (it exposes no FocusNode) so autofocus applies.
  bool _holdFocus = false;
  int _fieldGeneration = 0;

  @override
  void initState() {
    super.initState();
    final bio = BiometricUnlockService.platformSupported;
    _holdFocus = bio && widget.biometricAutoPrompt;
    if (bio) _initBiometric();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initBiometric() async {
    final bio = BiometricUnlockService.instance;
    final available = await bio.isEnabled() && await bio.isSupported();
    if (!mounted) return;
    setState(() => _biometricAvailable = available);
    if (available && widget.biometricAutoPrompt) {
      await _biometricUnlock();
    } else {
      _releaseFocus();
    }
  }

  void _releaseFocus() {
    if (!_holdFocus) return;
    setState(() {
      _holdFocus = false;
      _fieldGeneration++;
    });
  }

  Future<void> _biometricUnlock() async {
    if (_biometricBusy || _checking) return;
    setState(() {
      _biometricBusy = true;
      _error = null;
    });
    final ok = await BiometricUnlockService.instance.tryUnlock();
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
      return;
    }
    // Dismissed, or the key stopped matching and the feature switched itself
    // off — either way the passphrase is the way in now.
    final bio = BiometricUnlockService.instance;
    final stillEnabled = await bio.isEnabled();
    if (!mounted) return;
    setState(() {
      _biometricBusy = false;
      _biometricAvailable = _biometricAvailable && stillEnabled;
      // Lockout, changed fingerprints, re-created vault: say so, in the
      // passphrase field the user is about to use anyway.
      _error = bio.lastMessage;
    });
    _releaseFocus();
  }

  Future<void> _unlock() async {
    final passphrase = _controller.text;
    if (passphrase.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await walletBridge.unlockVault(passphrase);
      if (!mounted) return;
      widget.onUnlocked();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = e.toString().contains('Wrong passphrase')
            ? 'Wrong passphrase. Try again.'
            : 'Could not unlock: $e';
        _controller.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final device = Platform.isAndroid ? 'device' : 'computer';
    return Scaffold(
      body: PageBackground.flat(
        child: SafeArea(
          child: Align(
            // Top-biased on a phone: dead centre leaves 40% of the screen
            // empty above the form and pushes the field under the keyboard.
            alignment: AppLayout.isPhone(context)
                ? const Alignment(0, -0.7)
                : Alignment.center,
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const AppLogo(size: 32),
                          const SizedBox(width: AppSpacing.md),
                          Text(
                            'Templar Wallet',
                            style: AppTypography.gallerySection
                                .copyWith(color: s.inkSecondary),
                          ),
                        ],
                      ),
                      SizedBox(
                          height: AppLayout.isPhone(context)
                              ? AppSpacing.xl
                              : AppSpacing.xxxl),
                      Text(
                        'Unlock wallet storage',
                        style: AppTypography.displayTitleOf(context)
                            .copyWith(color: s.ink),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Your wallets are encrypted on this $device. Enter '
                        'your vault passphrase to decrypt them for this '
                        'session.',
                        style:
                            AppTypography.body.copyWith(color: s.inkSecondary),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        decoration: BoxDecoration(
                          // The phone canvas is flat, so the translucent
                          // gallery-card fill reads as a third surface step
                          // next to panel/panelInset. A gate card is a panel.
                          color: AppLayout.isPhone(context)
                              ? s.panel
                              : s.cardBase,
                          borderRadius:
                              BorderRadius.circular(AppSpacing.radiusXl),
                          border: Border.all(color: s.edge),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GlassPasswordField(
                              key: ValueKey(_fieldGeneration),
                              controller: _controller,
                              label: 'Vault passphrase',
                              autofocus: !_holdFocus,
                              errorText: _error,
                              onSubmitted: _unlock,
                              onChanged: (_) {
                                if (_error != null) {
                                  setState(() => _error = null);
                                }
                              },
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            SizedBox(
                              width: double.infinity,
                              child: _checking
                                  ? (AppLayout.isPhone(context)
                                      // Hold the button's slab while the
                                      // passphrase is checked. Swapping a
                                      // 54 dp control for a bare 36 dp
                                      // spinner collapsed the card and moved
                                      // "Use fingerprint" under the user's
                                      // thumb mid-tap; this is the same
                                      // button's disabled shape and surface.
                                      ? Container(
                                          height:
                                              AppSpacing.phoneControlHeight,
                                          decoration: BoxDecoration(
                                            color: s.panelInset,
                                            borderRadius:
                                                BorderRadius.circular(
                                                    AppSpacing
                                                        .radiusPhoneControl),
                                          ),
                                          child: const Center(
                                            child: SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth: 2),
                                            ),
                                          ),
                                        )
                                      : const Center(
                                          child: Padding(
                                            padding:
                                                EdgeInsets.all(AppSpacing.sm),
                                            child: SizedBox(
                                              width: 20,
                                              height: 20,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth: 2),
                                            ),
                                          ),
                                        ))
                                  : AccentButton(
                                      label: 'Unlock',
                                      icon: Icons.lock_open_outlined,
                                      isFullWidth: true,
                                      onPressed: _unlock,
                                    ),
                            ),
                            if (_biometricAvailable) ...[
                              SizedBox(
                                  height: AppLayout.isPhone(context)
                                      ? AppSpacing.md
                                      : AppSpacing.sm),
                              SecondaryButton(
                                label: Platform.isMacOS
                                    ? 'Use Touch ID'
                                    : 'Use fingerprint',
                                icon: Icons.fingerprint,
                                isFullWidth: true,
                                onPressed: _biometricBusy || _checking
                                    ? null
                                    : _biometricUnlock,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        'Forgot the passphrase? Wallets can only be restored '
                        'from their seed-phrase backups.',
                        style:
                            AppTypography.caption.copyWith(color: s.inkFaint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
