import 'dart:async';
import 'package:flutter/material.dart';
import '../../bridge/bridge_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../services/udev_installer.dart';
import '../create_wallet/models/hw_device.dart';
import 'device_permission_card.dart';
import 'hw_error.dart';
import 'hw_platform.dart';
import 'hwi_install_card.dart';

/// Outcome of the Ledger connect gate.
enum LedgerConnectResult {
  /// Matching device found and confirmed — open the wallet for signing.
  connected,

  /// User chose to open the wallet in watch-only mode (balance + receive only).
  watchOnly,

  /// User backed out.
  cancelled,
}

/// Parse the device fingerprint out of a wallet type label such as
/// `Hardware (1250a3f4)`. Returns null when no fingerprint is embedded.
String? fingerprintFromTypeLabel(String? typeLabel) {
  if (typeLabel == null) return null;
  final match = RegExp(r'\(([0-9a-fA-F]{6,8})\)').firstMatch(typeLabel);
  return match?.group(1);
}

/// Shows the Ledger connect gate. Polls the HWI bridge until a device matching
/// [expectedFingerprint] appears (any device if null), then shows a green tick
/// and resolves with [LedgerConnectResult.connected].
Future<LedgerConnectResult> showLedgerConnectDialog(
  BuildContext context, {
  String? expectedFingerprint,
  Set<String>? expectedFingerprints,
  bool allowWatchOnly = true,
  String title = 'Connect your device',
  String? confirmLabel,
  void Function(HwDevice device)? onDeviceFound,
}) async {
  final result = await showDialog<LedgerConnectResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LedgerConnectDialog(
      expectedFingerprint: expectedFingerprint,
      expectedFingerprints: expectedFingerprints,
      allowWatchOnly: allowWatchOnly,
      title: title,
      confirmLabel: confirmLabel,
      onDeviceFound: onDeviceFound,
    ),
  );
  return result ?? LedgerConnectResult.cancelled;
}

/// Wait for a device and hand it back, for callers that need to *address* it
/// afterwards rather than just know one is present — co-signing a PSBT, for
/// instance, needs the fingerprint to pass to HWI.
///
/// [expectedFingerprints] accepts any of several devices — a multisig with
/// two hardware keys takes whichever one is plugged in. With [confirmLabel]
/// the gate does not close itself on a match: it names the device and waits
/// for the user to press the button, so the next step (approving on the
/// device) is taken deliberately rather than sprung.
Future<HwDevice?> showHwDevicePickerDialog(
  BuildContext context, {
  String? expectedFingerprint,
  Set<String>? expectedFingerprints,
  String title = 'Connect the signing device',
  String? confirmLabel,
}) async {
  HwDevice? found;
  final result = await showLedgerConnectDialog(
    context,
    expectedFingerprint: expectedFingerprint,
    expectedFingerprints: expectedFingerprints,
    // There is no watch-only answer to "which device signs this?".
    allowWatchOnly: false,
    title: title,
    confirmLabel: confirmLabel,
    onDeviceFound: (d) => found = d,
  );
  return result == LedgerConnectResult.connected ? found : null;
}

/// User's intent when opening a hardware wallet from the picker.
enum HwOpenChoice {
  /// Connect the device now and open for signing.
  connect,

  /// Open in watch-only mode (balance + receive only, no device).
  watchOnly,

  /// Backed out.
  cancelled,
}

/// Choice-first gate shown when a hardware wallet is selected: connect the
/// device now, or open watch-only. Returns [HwOpenChoice.cancelled] if dismissed.
Future<HwOpenChoice> showHwOpenChoiceDialog(
  BuildContext context, {
  required String walletName,
}) async {
  final result = await showDialog<HwOpenChoice>(
    context: context,
    builder: (ctx) {
      final isDark = Theme.of(ctx).brightness == Brightness.dark;
      return AlertDialog(
        title: Text('Open "$walletName"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HwOpenOption(
              icon: Icons.usb_rounded,
              iconColor: AppColors.accent,
              iconBg: AppColors.accentLight,
              title: 'Connect device',
              subtitle: 'Plug in your hardware wallet to sign and send.',
              onTap: () => Navigator.of(ctx).pop(HwOpenChoice.connect),
              isDark: isDark,
            ),
            const SizedBox(height: AppSpacing.sm),
            _HwOpenOption(
              icon: Icons.visibility_outlined,
              iconColor: AppColors.textSecondary,
              iconBg: isDark ? AppColors.surfaceDark : AppColors.backgroundLight,
              title: 'Open watch-only',
              subtitle: 'View balance and receive. No device needed.',
              onTap: () => Navigator.of(ctx).pop(HwOpenChoice.watchOnly),
              isDark: isDark,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(HwOpenChoice.cancelled),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
  return result ?? HwOpenChoice.cancelled;
}

/// One tappable row in the HW open choice dialog.
class _HwOpenOption extends StatelessWidget {
  const _HwOpenOption({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
    required this.isDark,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(
              color: isDark ? AppColors.borderDark : AppColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: AppTypography.body
                          .copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTypography.caption),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}

class LedgerConnectDialog extends StatefulWidget {
  const LedgerConnectDialog({
    super.key,
    this.expectedFingerprint,
    this.expectedFingerprints,
    this.allowWatchOnly = true,
    this.title = 'Connect your device',
    this.confirmLabel,
    this.onDeviceFound,
  });

  final String? expectedFingerprint;

  /// Any of these devices will do. Combined with [expectedFingerprint]; both
  /// null accepts whatever answers.
  final Set<String>? expectedFingerprints;
  final bool allowWatchOnly;
  final String title;

  /// When set, a matched device is shown with this button instead of the
  /// dialog closing on its own; pressing it resolves `connected`.
  final String? confirmLabel;

  /// Fired with the matched device just before the dialog resolves.
  final void Function(HwDevice device)? onDeviceFound;

  /// Every fingerprint that satisfies the gate, lower-cased. Empty = any.
  Set<String> get wanted => {
        if (expectedFingerprint != null) expectedFingerprint!.toLowerCase(),
        ...?expectedFingerprints?.map((f) => f.toLowerCase()),
      };

  @override
  State<LedgerConnectDialog> createState() => _LedgerConnectDialogState();
}

class _LedgerConnectDialogState extends State<LedgerConnectDialog>
    with SingleTickerProviderStateMixin {
  final _bridge = walletBridge;
  late final AnimationController _anim;
  Timer? _poll;
  bool _found = false;
  String? _error;
  HwDevice? _device;

  /// HWI binary missing — polling is paused and the install card shown.
  bool _hwiMissing = false;

  /// The OS is refusing device access (Linux udev) — polling is paused and
  /// the permission card shown. Polling on would spawn a subprocess every
  /// 1.5 s for a condition that cannot resolve itself.
  bool _permissionBlocked = false;
  String? _permissionDetail;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _startPolling();
  }

  /// True while an identify is in flight. Opening a device is slow — an `hwi
  /// enumerate` unpacks itself on every run, and a Jade waits for a PIN — so
  /// without this the timer stacks up overlapping attempts that fight over the
  /// same USB handle, which looks exactly like a flaky device.
  bool _scanInFlight = false;

  /// Whether anything wallet-shaped is plugged in, from the cheap detection
  /// that reads cached USB descriptors and never opens a device.
  bool _devicePresent = false;

  /// An identify attempt already ran for the currently attached device. Set so
  /// the timer does not keep re-opening it: on a Jade every attempt is another
  /// PIN prompt, and the old 2-second loop turned a wrong-device or
  /// declined-unlock into an endless series of them.
  bool _identifyAttempted = false;

  /// Detection ticks that saw nothing, for the slow HWI sweep below.
  int _emptyTicks = 0;

  void _startPolling() {
    _poll?.cancel();
    _identifyAttempted = false;
    _detectOnce();
    // Presence only. The expensive step — opening the device to read its
    // fingerprint — is triggered once per attached device, below.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _detectOnce());
  }

  /// Cheap: "is something plugged in?", asked of USB descriptors the OS already
  /// cached. Safe on a timer because it never talks to the device.
  Future<void> _detectOnce() async {
    if (_found || _hwiMissing || _permissionBlocked || !mounted) return;
    try {
      final detected = await _bridge.enumerateNativeDevices();
      if (!mounted) return;
      // Usable, not merely native-drivable: on Windows and Linux a Trezor or a
      // Coldcard is paired through the HWI helper, and gating on the native
      // driver alone would leave those users watching a spinner for a device
      // sitting right there.
      final present =
          detected.any((d) => d.drivable) || (detected.isNotEmpty && hwiFallbackUsable);
      // A device unplugged and plugged back in deserves a fresh attempt —
      // reconnecting is exactly how a user retries.
      if (!present && _identifyAttempted) _identifyAttempted = false;
      if (present != _devicePresent) setState(() => _devicePresent = present);
      if (present && !_identifyAttempted && !_scanInFlight) {
        _identify();
        return;
      }
      // Nothing recognised on the bus, but the helper can still run: it knows
      // devices our own USB id table does not, so give it an occasional turn.
      // Slow (~16 s) because each attempt spawns a subprocess — and safe,
      // because this branch only runs when no device we could open was seen,
      // so it can never sit on a Jade's PIN prompt.
      _emptyTicks++;
      if (!present && hwiFallbackUsable && _emptyTicks % 8 == 0) {
        _identifyAttempted = false;
        _identify();
      }
    } catch (_) {
      // Detection is the cheap half; a failure here must not close the gate.
      // The identify path below reports anything that actually matters.
    }
  }

  /// Expensive: open the attached devices and read their master fingerprints.
  /// On a Jade this prompts for the PIN, so it runs once per attached device
  /// and then waits for the user.
  Future<void> _identify() async {
    if (_found || _hwiMissing || _permissionBlocked || _scanInFlight || !mounted) {
      return;
    }
    _scanInFlight = true;
    _identifyAttempted = true;
    setState(() {});
    try {
      await _scanOnceInner();
    } finally {
      _scanInFlight = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _scanOnceInner() async {
    try {
      final devices = await _bridge.enumerateHwDevices();
      if (!mounted || _found) return;
      final wanted = widget.wanted;
      final match = devices.where((d) {
        if (wanted.isEmpty) return true;
        return wanted.contains(d.fingerprint.toLowerCase());
      });
      if (match.isNotEmpty) {
        setState(() => _error = null);
        _onFound(match.first);
        return;
      }
      // A device answered, but not this wallet's device. Worth saying which:
      // with two devices on the desk the fix is to swap cables, and silence
      // here used to look identical to "still searching".
      setState(() => _error = devices.isEmpty
          ? null
          : wanted.length > 1
              ? 'Connected device ${devices.first.fingerprint} is not one of '
                  'this wallet\'s hardware keys (${wanted.join(', ')}). '
                  'Connect one of those and press Retry.'
              : 'Connected device ${devices.first.fingerprint} is not the one '
                  'this wallet was created from (${wanted.join()}). '
                  'Connect that device and press Retry.');
    } catch (e) {
      if (!mounted) return;
      final failure = classifyHwError(e);
      if (failure.isHwiMissing) {
        // Missing toolkit is fixable in place — pause polling (each failing
        // attempt spawns a subprocess) and offer the installer.
        _poll?.cancel();
        setState(() { _hwiMissing = true; _error = null; });
      } else if (failure.isPermission && UdevInstaller.supported) {
        _poll?.cancel();
        setState(() {
          _permissionBlocked = true;
          _permissionDetail = failure.message;
          _error = null;
        });
      } else {
        // Transient device issue — surface it but keep polling.
        setState(() => _error = failure.message);
      }
    }
  }

  void _onFound(HwDevice device) {
    _found = true;
    _poll?.cancel();
    _anim.stop();
    widget.onDeviceFound?.call(device);
    setState(() => _device = device);
    // With a confirm button the gate waits for the user: the next step is
    // an approval on the device, which nobody wants sprung on them.
    if (widget.confirmLabel != null) return;
    // Hold the green tick briefly so the confirmation is visible.
    Timer(const Duration(milliseconds: 900), () {
      if (mounted) Navigator.of(context).pop(LedgerConnectResult.connected);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No platform wall here any more — the scan reaches a Ledger or a Jade on
    // every OS. A device with no path on this platform surfaces through the
    // normal error state, with the reason on it.
    if (_hwiMissing) {
      return AlertDialog(
        title: const Text('HWI toolkit required'),
        content: SizedBox(
          width: 460,
          child: HwiInstallCard(
            onInstalled: () {
              setState(() => _hwiMissing = false);
              _startPolling();
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(LedgerConnectResult.cancelled),
            child: const Text('Cancel'),
          ),
        ],
      );
    }
    if (_permissionBlocked) {
      return AlertDialog(
        title: const Text('Device access blocked'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: DevicePermissionCard(
              detail: _permissionDetail,
              onFixed: () {
                setState(() {
                  _permissionBlocked = false;
                  _permissionDetail = null;
                });
                _startPolling();
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(LedgerConnectResult.cancelled),
            child: const Text('Cancel'),
          ),
          if (widget.allowWatchOnly)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(LedgerConnectResult.watchOnly),
              child: const Text('Open in watch-only'),
            ),
        ],
      );
    }
    return AlertDialog(
      title: Text(_found ? 'Device connected' : widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.lg),
          _Indicator(anim: _anim, found: _found),
          const SizedBox(height: AppSpacing.xl),
          Text(
            _found
                ? widget.confirmLabel != null
                    ? '${_device?.model ?? 'Device'} ready '
                        '(${_device?.fingerprint ?? ''}). Press '
                        '“${widget.confirmLabel}”, then approve the '
                        'transaction on the device screen.'
                    : '${_device?.model ?? 'Device'} ready (${_device?.fingerprint ?? ''}).'
                : _devicePresent
                    ? 'Device detected. Unlock it with your PIN — and on a '
                        'Ledger, open the Bitcoin Testnet app.'
                    : 'Plug in your device with its cable, then unlock it with '
                        'your PIN.',
            textAlign: TextAlign.center,
            style: AppTypography.body,
          ),
          if (!_found) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_scanInFlight)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation(AppColors.accentMuted),
                    ),
                  )
                else
                  Icon(
                    _devicePresent ? Icons.usb_rounded : Icons.search_rounded,
                    size: 13,
                    color: AppColors.accentMuted,
                  ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  _scanInFlight
                      ? 'Reading the device…'
                      : _devicePresent
                          ? 'Connected — waiting for you to unlock it'
                          : 'Watching for a device…',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ],
          if (_error != null && !_found) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: AppTypography.caption.copyWith(color: AppColors.danger),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
      actions: _found
          ? (widget.confirmLabel == null
              ? null
              : [
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pop(LedgerConnectResult.cancelled),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context)
                        .pop(LedgerConnectResult.connected),
                    icon: const Icon(Icons.draw_outlined, size: 16),
                    label: Text(widget.confirmLabel!),
                  ),
                ])
          : [
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(LedgerConnectResult.cancelled),
                child: const Text('Cancel'),
              ),
              if (widget.allowWatchOnly)
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(LedgerConnectResult.watchOnly),
                  child: const Text('Open in watch-only'),
                ),
              // The device is opened once per connection, not on a loop: on a
              // Jade each attempt is another PIN prompt. After a declined or
              // timed-out unlock, retrying is the user's call.
              if (_devicePresent)
                TextButton(
                  onPressed: _scanInFlight ? null : _identify,
                  child: Text(_identifyAttempted ? 'Retry' : 'Check device'),
                ),
            ],
    );
  }
}

/// Pulsing scan ring while searching, animated green check once found.
class _Indicator extends StatelessWidget {
  const _Indicator({required this.anim, required this.found});
  final AnimationController anim;
  final bool found;

  @override
  Widget build(BuildContext context) {
    if (found) {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutBack,
        builder: (_, scale, child) => Transform.scale(
          scale: scale,
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: AppColors.successLight,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_rounded,
                color: AppColors.success, size: 40),
          ),
        ),
      );
    }
    return AnimatedBuilder(
      animation: anim,
      builder: (_, child) {
        final t = anim.value;
        return SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Expanding fading pulse ring.
              Opacity(
                opacity: (1 - t).clamp(0.0, 1.0) * 0.5,
                child: Container(
                  width: 56 + 32 * t,
                  height: 56 + 32 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.accentMuted, width: 2),
                  ),
                ),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.accentLight,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.usb_rounded,
                    color: AppColors.accent, size: 32),
              ),
            ],
          ),
        );
      },
    );
  }
}
