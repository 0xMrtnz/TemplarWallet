// Classification of hardware-wallet errors coming back from the FFI.
//
// templar-core tags every hardware error with a stable prefix
// (`HWI_MISSING: …`, `DEVICE_NOT_READY: …`, …). Branching on the tag instead
// of sniffing free text means the wording can change per platform — and be
// translated — without any screen silently losing its remedy. Untagged errors
// still get a best-effort match so older backends keep working.
//
// Each screen asks the same question of a failure: *is there something the
// user can press to fix this?* That is what [HwFailure.remedy] answers.

import 'dart:io' show Platform;

/// What went wrong, at the granularity the UI actually reacts to.
enum HwErrorKind {
  /// The HWI toolkit is not installed / cannot run. In-app installer fixes it.
  hwiMissing,

  /// The OS refused access to the device: Linux udev rules, macOS/Windows
  /// device handle held elsewhere.
  permission,

  /// A device is attached but unusable: locked, wrong app open, busy.
  deviceNotReady,

  /// No device matching the wallet's fingerprint is attached.
  deviceNotFound,

  /// The device was reached but did not sign (declined, or wrong wallet).
  signingRefused,

  /// Spending a Liquid asset from a hardware or air-gap wallet — unsupported.
  liquidUnsupported,

  /// This build has no USB hardware stack at all (Android): the QR air-gap
  /// flow is the way to use an external signer.
  hardwareUnsupported,

  /// Anything else; shown verbatim.
  unknown,
}

/// The action a screen can offer for a failure. Screens that cannot host a
/// given remedy just ignore it and show the message.
enum HwRemedy { none, installHwi, fixPermissions, reconnectDevice }

class HwFailure {
  const HwFailure({
    required this.kind,
    required this.message,
    required this.remedy,
  });

  final HwErrorKind kind;

  /// Ready to display: tag stripped, platform-specific guidance appended.
  final String message;

  final HwRemedy remedy;

  bool get isHwiMissing => kind == HwErrorKind.hwiMissing;
  bool get isPermission => kind == HwErrorKind.permission;
}

const _tagToKind = <String, HwErrorKind>{
  'HWI_MISSING': HwErrorKind.hwiMissing,
  'HWI_PERMISSION': HwErrorKind.permission,
  'DEVICE_NOT_READY': HwErrorKind.deviceNotReady,
  'DEVICE_NOT_FOUND': HwErrorKind.deviceNotFound,
  'SIGNING_FAILED': HwErrorKind.signingRefused,
  'LIQUID_HW_UNSUPPORTED': HwErrorKind.liquidUnsupported,
  'HW_UNSUPPORTED': HwErrorKind.hardwareUnsupported,
};

/// Strip the FFI exception wrapper so a tag at the start of the backend
/// message is actually at the start of the string we inspect.
String _unwrap(Object error) {
  var s = error.toString();
  for (final prefix in const [
    'Exception: wallet-ffi: ',
    'Exception: ',
    'wallet-ffi: ',
  ]) {
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
  }
  return s.trim();
}

/// Classify a raw error into something a screen can act on.
HwFailure classifyHwError(Object error) {
  final raw = _unwrap(error);

  for (final entry in _tagToKind.entries) {
    final tag = '${entry.key}: ';
    if (raw.startsWith(tag)) {
      final body = raw.substring(tag.length).trim();
      return HwFailure(
        kind: entry.value,
        message: entry.value == HwErrorKind.hardwareUnsupported
            ? 'Hardware wallets are not available on this device. Use the '
                'QR air-gap flow to sign with an external device.'
            : body,
        remedy: _remedyFor(entry.value),
      );
    }
  }

  // Untagged fallbacks — older backend, or an error raised outside templar-core.
  final lower = raw.toLowerCase();
  if (lower.contains('could not run hwi') || lower.contains('hwi toolkit')) {
    return HwFailure(
      kind: HwErrorKind.hwiMissing,
      message: raw,
      remedy: HwRemedy.installHwi,
    );
  }
  if (lower.contains('permission') || lower.contains('access denied')) {
    return HwFailure(
      kind: HwErrorKind.permission,
      message: raw,
      remedy: _remedyFor(HwErrorKind.permission),
    );
  }
  if (lower.contains('did not sign') || lower.contains('no signatures')) {
    return HwFailure(
      kind: HwErrorKind.signingRefused,
      message: 'The device did not sign. Unlock it, open the Bitcoin Testnet '
          'app, and approve the transaction on screen.',
      remedy: HwRemedy.reconnectDevice,
    );
  }
  if (lower.contains('not found') ||
      lower.contains('not connected') ||
      lower.contains('enumerate')) {
    return HwFailure(
      kind: HwErrorKind.deviceNotFound,
      message: 'Device not detected. Reconnect it, unlock it with your PIN, '
          'and open the Bitcoin Testnet app.',
      remedy: HwRemedy.reconnectDevice,
    );
  }
  return HwFailure(
    kind: HwErrorKind.unknown,
    message: raw,
    remedy: HwRemedy.none,
  );
}

HwRemedy _remedyFor(HwErrorKind kind) => switch (kind) {
      HwErrorKind.hwiMissing => HwRemedy.installHwi,
      // Only Linux has an in-app fix (udev rules); elsewhere the remedy is
      // physical, so pointing at a button that does nothing would be worse
      // than the plain message the backend already tailored per platform.
      HwErrorKind.permission =>
        Platform.isLinux ? HwRemedy.fixPermissions : HwRemedy.reconnectDevice,
      HwErrorKind.deviceNotReady => HwRemedy.reconnectDevice,
      HwErrorKind.deviceNotFound => HwRemedy.reconnectDevice,
      HwErrorKind.signingRefused => HwRemedy.reconnectDevice,
      HwErrorKind.liquidUnsupported => HwRemedy.none,
      HwErrorKind.hardwareUnsupported => HwRemedy.none,
      HwErrorKind.unknown => HwRemedy.none,
    };

/// One-line convenience for screens that only display text.
String friendlyHwError(Object error) => classifyHwError(error).message;

/// Short heading to pair with the message in banners and dialogs.
String hwErrorTitle(HwErrorKind kind) => switch (kind) {
      HwErrorKind.hwiMissing => 'HWI toolkit required',
      HwErrorKind.permission => 'Device access blocked',
      HwErrorKind.deviceNotReady => 'Device not ready',
      HwErrorKind.deviceNotFound => 'Device not found',
      HwErrorKind.signingRefused => 'Not signed',
      HwErrorKind.liquidUnsupported => 'Not supported yet',
      HwErrorKind.hardwareUnsupported => 'Not available on this device',
      HwErrorKind.unknown => 'Hardware wallet error',
    };
