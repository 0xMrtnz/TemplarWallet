// Shared BC-UR v2 QR widgets for air-gapped signers (Jade, SeedSigner, …):
// an animated `ur:` QR display and a multi-frame camera scanner that
// reassembles fountain-coded payloads via the Rust decoder.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../bridge/bridge_provider.dart';
import '../../services/app_settings.dart';
import '../../services/crash_log.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// mobile_scanner ships no Windows/Linux implementation — on those desktops
/// starting the camera throws MissingPluginException, which escapes every
/// error path in the plugin and leaves the dialog on a dead spinner. Gate all
/// camera entry points on this instead so unsupported platforms get a clear
/// message and the Paste / File alternatives.
bool get cameraScanSupported =>
    debugCameraScanSupportedOverride ??
    (kIsWeb || Platform.isMacOS || Platform.isAndroid || Platform.isIOS);

/// Test seam: stands in for the platform check while set, so a widget test
/// sees the same camera entry points on every host — CI runs the suite on
/// Linux, which has no camera plugin.
@visibleForTesting
bool? debugCameraScanSupportedOverride;

/// Cycles through UR fragments as a QR animation (~6 fps). A single fragment
/// renders as a static QR.
///
/// [size] is the side the caller wants; the QR shrinks to the width it is
/// actually given (minus its white margin) so a narrow sheet or a padded card
/// never clips it. On a phone pass [AppLayout.qrSide] — an animated BC-UR
/// code needs every dp it can get for a signer's camera.
class UrAnimatedQr extends StatefulWidget {
  const UrAnimatedQr({super.key, required this.parts, this.size = 260});

  final List<String> parts;
  final double size;

  @override
  State<UrAnimatedQr> createState() => _UrAnimatedQrState();
}

class _UrAnimatedQrState extends State<UrAnimatedQr> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    if (widget.parts.length > 1) {
      _timer = Timer.periodic(const Duration(milliseconds: 160), (_) {
        if (mounted) {
          setState(() => _index = (_index + 1) % widget.parts.length);
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.parts.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        var side = widget.size;
        if (constraints.hasBoundedWidth) {
          final fits = constraints.maxWidth - 2 * AppSpacing.sm;
          if (fits < side) side = math.max(fits, 120);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              ),
              child: QrImageView(
                // UR payloads are case-insensitive; upper-case enables the QR
                // alphanumeric mode → denser frames scan faster.
                data: widget.parts[_index].toUpperCase(),
                version: QrVersions.auto,
                size: side,
                backgroundColor: Colors.white,
              ),
            ),
            if (widget.parts.length > 1) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'frame ${_index + 1}/${widget.parts.length}',
                style: AppTypography.caption,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// What a [UrScannerDialog] scan produced.
class UrScanOutcome {
  const UrScanOutcome({
    required this.kind,
    this.psbtBase64,
    this.psetBase64,
    this.descriptor,
    this.keyorigin,
  });

  /// "psbt", "pset" or "descriptor".
  final String kind;
  final String? psbtBase64;

  /// A Liquid PSET, base64 — from Templar's own `ur:bytes` animation or a
  /// bare base64 QR starting with the PSET magic.
  final String? psetBase64;
  final String? descriptor;

  /// Whichever transaction the QR carried, base64, or null for a key.
  String? get transactionBase64 => psbtBase64 ?? psetBase64;

  /// Present when the QR carried an account key: the same key as [descriptor]
  /// reduced to `[fingerprint/path]tpub…`. A multisig cosigner field must use
  /// this, never the descriptor.
  final String? keyorigin;
}

/// Opens the camera and reassembles a (possibly multi-frame) UR payload.
/// Returns null when dismissed.
///
/// [expectPsbt] steers how a plain-text (non-UR) QR is interpreted: a base64
/// transaction when true, a descriptor/xpub otherwise. A payload that carries
/// a PSBT or PSET magic is typed by it whatever the caller expects.
///
/// A dialog on desktop; on a phone a full-screen page — the camera preview
/// takes the whole width, with a close button and a torch toggle in the
/// safe area, which is what every phone user expects a scanner to be.
Future<UrScanOutcome?> showUrScannerDialog(
  BuildContext context, {
  required bool expectPsbt,
  String? title,
}) async {
  if (!cameraScanSupported) {
    await showCameraUnsupportedDialog(context);
    return null;
  }
  final heading =
      title ?? (expectPsbt ? 'Scan signed transaction' : 'Scan wallet QR');
  if (AppLayout.isPhone(context)) {
    // Root navigator so the page covers the mobile shell (header + nav bar)
    // instead of rendering inside its content slot.
    return Navigator.of(context, rootNavigator: true).push<UrScanOutcome>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _UrScannerDialog(
          expectPsbt: expectPsbt,
          title: heading,
          fullScreen: true,
        ),
      ),
    );
  }
  return showDialog<UrScanOutcome>(
    context: context,
    builder: (_) => _UrScannerDialog(expectPsbt: expectPsbt, title: heading),
  );
}

/// Explains why the camera can't open on this platform. A safety net: scan
/// controls hide themselves where the camera is unavailable, so this is only
/// reached by a code path that asked for the scanner directly.
Future<void> showCameraUnsupportedDialog(BuildContext context) {
  final os = Platform.isWindows
      ? 'Windows'
      : Platform.isLinux
          ? 'Linux'
          : 'this platform';
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      title: Row(
        children: [
          const Icon(Icons.videocam_off_outlined, color: Colors.white70),
          const SizedBox(width: AppSpacing.sm),
          Text('Camera not available',
              style: AppTypography.body.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w700)),
        ],
      ),
      content: Text(
        'Camera QR scanning is not available on $os.\n\n'
        'Nothing is blocked: use Paste or Load file instead. Air-gap signing '
        'still works end to end — the app shows the unsigned transaction as a '
        'QR for your device to read, and you bring the signed one back as '
        'text or a .psbt file.',
        style: AppTypography.bodySmall.copyWith(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class _UrScannerDialog extends StatefulWidget {
  const _UrScannerDialog({
    required this.expectPsbt,
    required this.title,
    this.fullScreen = false,
  });

  final bool expectPsbt;
  final String title;

  /// Phone presentation: a page instead of a dialog.
  final bool fullScreen;

  @override
  State<_UrScannerDialog> createState() => _UrScannerDialogState();
}

class _UrScannerDialogState extends State<_UrScannerDialog> {
  final _bridge = walletBridge;
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final Set<String> _parts = {};

  /// UR type the collected frames belong to. The decoder reads the type from
  /// the first frame it is given, so frames from two different URs in one set
  /// make every later decode fail — which is what happened when a locked Jade
  /// was pointed at this scanner and then unlocked without closing it.
  String? _partsType;
  double _progress = 0.0;
  bool _finishing = false;
  bool _decoding = false;
  String? _error;

  /// The scanned QR belongs to a device flow that has to finish on the device
  /// first. Shown as instructions rather than as an error.
  String? _deviceHint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_finishing) return;
    final raw = capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (raw == null || raw.isEmpty) return;
    final value = raw.trim();

    // Plain-text QR: single shot, no UR reassembly needed. A base64 PSBT or
    // PSET announces itself by the base64 of its magic bytes.
    if (!value.toLowerCase().startsWith('ur:')) {
      _finishing = true;
      final looksLikePset = value.startsWith('cHNldP');
      final looksLikePsbt = value.startsWith('cHNidP');
      Navigator.of(context).pop(
        looksLikePset
            ? UrScanOutcome(kind: 'pset', psetBase64: value)
            : widget.expectPsbt || looksLikePsbt
                ? UrScanOutcome(kind: 'psbt', psbtBase64: value)
                : UrScanOutcome(kind: 'descriptor', descriptor: value),
      );
      return;
    }

    // Start a fresh set as soon as a different UR shows up: pointing the
    // camera at a second code must not be poisoned by the first.
    final type = _urType(value);
    if (type != _partsType) {
      _parts.clear();
      _partsType = type;
      _progress = 0.0;
    }

    if (!_parts.add(value.toLowerCase())) return;
    if (_decoding) return; // let the next frame pick up the new part
    _decoding = true;
    try {
      final result = await _bridge.urDecodeParts(_parts.toList());
      if (!mounted) return;
      if (result.complete) {
        _finishing = true;
        Navigator.of(context).pop(UrScanOutcome(
          kind: result.kind,
          psbtBase64: result.psbtBase64,
          psetBase64: result.psetBase64,
          descriptor: result.descriptor,
          keyorigin: result.keyorigin,
        ));
        return;
      }
      setState(() {
        _progress = result.progress;
        _error = null;
        _deviceHint = null;
      });
    } catch (e) {
      if (mounted) {
        final message =
            e.toString().replaceFirst('Exception: wallet-ffi: ', '');
        setState(() {
          // A locked Jade shows its PIN-unlock QR here. That is not a failed
          // scan, it is an earlier step of the device's own flow, so it gets
          // instructions instead of a red line the user cannot act on.
          final locked = _partsType == 'jade-pin';
          _deviceHint = locked ? message : null;
          _error = locked ? null : message;
        });
      }
    } finally {
      _decoding = false;
    }
  }

  /// `ur:crypto-psbt/1-3/…` → `crypto-psbt`.
  static String _urType(String part) {
    final head = part.split('/').first.toLowerCase();
    final colon = head.indexOf(':');
    return colon < 0 ? head : head.substring(colon + 1);
  }

  @override
  Widget build(BuildContext context) {
    return widget.fullScreen ? _buildPage(context) : _buildDialog(context);
  }

  /// Desktop: the floating 460 dp dialog.
  Widget _buildDialog(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.md),
              child: Row(
                children: [
                  const Icon(Icons.qr_code_scanner, size: 18, color: Colors.white),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(widget.title,
                        style: AppTypography.body.copyWith(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              child: SizedBox(
                width: 420,
                height: 420,
                child: _scanner(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _caption(),
            ),
          ],
        ),
      ),
    );
  }

  /// Phone: a full-screen page. Close and torch live in the safe area above
  /// the preview, the preview fills the width, the caption sits underneath.
  Widget _buildPage(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body.copyWith(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                  ),
                  _TorchButton(controller: _controller),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _scanner(),
                  // Viewfinder: a square guide so the user knows where to
                  // hold the code. Decorative only — detection covers the
                  // whole frame.
                  IgnorePointer(
                    child: Center(
                      child: FractionallySizedBox(
                        widthFactor: 0.78,
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  width: 2),
                              borderRadius:
                                  BorderRadius.circular(AppSpacing.radiusMd),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: _caption(),
            ),
          ],
        ),
      ),
    );
  }

  /// The camera failed to open. Start it again — after the user granted the
  /// permission in Settings, freed the camera from another app, or just
  /// wants another go. A failure lands back in the error view with the new
  /// reason on it.
  Future<void> _retry() async {
    try {
      await _controller.stop();
    } catch (_) {
      // Was never running: nothing to stop.
    }
    try {
      await _controller.start();
    } catch (e) {
      CrashLog.instance.write('scanner retry failed: $e');
    }
  }

  Widget _scanner() {
    return MobileScanner(
      controller: _controller,
      onDetect: _onDetect,
      fit: BoxFit.cover,
      errorBuilder: (context, error) {
        // The one line a bug report needs. "Camera unavailable" alone told
        // nobody why a particular phone's camera never opened.
        CrashLog.instance.write(
            'scanner error: ${error.errorCode.name} '
            '${error.errorDetails?.code ?? ''} '
            '${error.errorDetails?.message ?? ''} '
            '${error.errorDetails?.details ?? ''}');
        return _UrScannerError(
          error: error,
          large: widget.fullScreen,
          onRetry: _retry,
        );
      },
      placeholderBuilder: (context) => const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _caption() {
    final style = (widget.fullScreen ? AppTypography.bodySmall : AppTypography.caption)
        .copyWith(color: Colors.white70);
    return Column(
      children: [
        if (_parts.isNotEmpty) ...[
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '${_parts.length} frame${_parts.length == 1 ? '' : 's'} captured — keep the camera on the animation',
            style: style,
            textAlign: widget.fullScreen ? TextAlign.center : null,
          ),
        ] else
          Text(
            'Point the camera at the QR (animated codes are read frame by frame).',
            style: style,
            textAlign: widget.fullScreen ? TextAlign.center : null,
          ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!,
              textAlign: widget.fullScreen ? TextAlign.center : null,
              style: AppTypography.caption.copyWith(color: AppColors.danger)),
        ],
        if (_deviceHint != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _DeviceStepHint(message: _deviceHint!),
        ],
      ],
    );
  }
}

/// The scanned QR belongs to a flow the device has not finished yet — a Jade
/// still on its PIN-unlock screen is the case this exists for.
///
/// Deliberately not styled as an error: nothing is broken, the camera is
/// simply pointed at an earlier step, and the way out is on the device.
class _DeviceStepHint extends StatelessWidget {
  const _DeviceStepHint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppTypography.caption.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

/// Torch toggle for the phone scanner. Hidden until the camera reports a
/// torch (front cameras and emulators have none) so the header never shows
/// a control that does nothing.
class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.controller});
  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final torch = state.torchState;
        if (torch == TorchState.unavailable) {
          return const SizedBox(width: AppLayout.minTouchTarget);
        }
        final on = torch == TorchState.on;
        return IconButton(
          tooltip: on ? 'Torch off' : 'Torch on',
          icon: Icon(on ? Icons.flash_on : Icons.flash_off,
              color: on ? AppColors.warning : Colors.white),
          onPressed: controller.toggleTorch,
        );
      },
    );
  }
}

class _UrScannerError extends StatelessWidget {
  const _UrScannerError({
    required this.error,
    this.large = false,
    this.onRetry,
  });
  final MobileScannerException error;

  /// Phone: the message is the whole screen, so it can afford body size.
  final bool large;

  /// Start the camera again.
  final VoidCallback? onRetry;

  /// What went wrong, in the plugin's own terms — the part that tells one
  /// phone's failure from another's, and the part a bug report needs.
  String get _detail {
    final d = error.errorDetails;
    final parts = [
      error.errorCode.name,
      if (d?.code != null && d!.code!.isNotEmpty) d.code!,
      if (d?.message != null && d!.message!.isNotEmpty) d.message!,
    ];
    return parts.join(' · ');
  }

  /// A first line the user can act on, per error code.
  String get _headline => switch (error.errorCode) {
        MobileScannerErrorCode.permissionDenied => Platform.isAndroid
            ? 'Camera access denied. Allow camera access for Templar Wallet '
                'in Settings › Apps › Templar Wallet › Permissions › Camera, '
                'then try again.'
            : Platform.isIOS
                ? 'Camera access denied. Allow camera access for Templar '
                    'Wallet in Settings › Templar Wallet › Camera, then try '
                    'again.'
                : 'Camera access denied. Allow camera access for Templar '
                    'Wallet in System Settings › Privacy & Security › Camera.',
        MobileScannerErrorCode.unsupported =>
          'This device reports no usable camera for scanning. Paste the '
              'text or load the file instead.',
        MobileScannerErrorCode.controllerAlreadyInitialized ||
        MobileScannerErrorCode.controllerInitializing =>
          'The camera is still busy from a previous scan. Wait a moment and '
              'try again.',
        _ => 'The camera could not be opened. If another app is using it, '
            'close that app and try again — or paste the text or load the '
            'file instead.',
      };

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final style = (large ? AppTypography.body : AppTypography.bodySmall)
        .copyWith(color: Colors.white70);
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (large) ...[
                const Icon(Icons.videocam_off_outlined,
                    color: Colors.white54, size: 40),
                const SizedBox(height: AppSpacing.md),
              ],
              Text(_headline, textAlign: TextAlign.center, style: style),
              const SizedBox(height: AppSpacing.sm),
              SelectableText(
                _detail,
                textAlign: TextAlign.center,
                style: AppTypography.monoSmall.copyWith(color: Colors.white38),
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                alignment: WrapAlignment.center,
                children: [
                  if (onRetry != null)
                    OutlinedButton.icon(
                      onPressed: onRetry,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Try again'),
                    ),
                  if (denied && AppSettingsLauncher.supported)
                    OutlinedButton.icon(
                      onPressed: AppSettingsLauncher.open,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                      ),
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: const Text('Open app settings'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
