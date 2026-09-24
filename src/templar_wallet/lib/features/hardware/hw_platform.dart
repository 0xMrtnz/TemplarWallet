// Which hardware-wallet transports this build can use, and where.
//
// The answer used to be per operating system: USB worked on Windows and Linux
// and not on macOS, because every device went through the `hwi` CLI as a child
// process and the macOS App Sandbox will not let this app start one. Measured,
// not assumed — `hwi` in the data container returns EPERM from execve, and a
// copy inside the .app bundle hangs in its PyInstaller bootloader.
//
// It is now per **device family**. Ledger (USB HID) and Blockstream Jade (USB
// serial) are driven in-process by `crates/templar-core/src/bitcoin/device/`,
// with no subprocess anywhere, so they behave identically on all three
// platforms. The families without a native driver — Trezor, Coldcard, KeepKey,
// BitBox — still go through HWI, which means Windows and Linux only.
//
// The rule lives in Rust (`DeviceFamily::is_drivable` / `hwi_usable`) and
// arrives here through `hwi_status`. Nothing below hard-codes a platform: a
// second copy of that rule in Dart is exactly how the two would drift apart.

import 'dart:io' show Platform;

/// Families driven in-process, so USB works for them on every platform.
/// Overwritten from `hwi_status` at runtime; this is the fallback for the
/// window before the first status probe returns.
List<String> nativeUsbFamilies = const ['Ledger', 'Blockstream Jade'];

/// Whether the HWI fallback can run at all here — false on macOS.
bool hwiFallbackUsable = !Platform.isMacOS;

/// Update the platform picture from a `hwi_status` reply.
void applyHwPlatformStatus({
  required List<String> nativeFamilies,
  required bool hwiUsable,
}) {
  if (nativeFamilies.isNotEmpty) nativeUsbFamilies = nativeFamilies;
  hwiFallbackUsable = hwiUsable;
}

/// Whether USB is worth offering at all. True everywhere now: even where HWI
/// cannot run, a Ledger or a Jade connects natively.
bool get usbBitcoinSupported => true;

/// Kept as the general name used across the hardware screens.
bool get usbHardwareSupported => usbBitcoinSupported;

/// Whether a Jade can be used for **Liquid** over USB. True everywhere:
/// Liquid goes through `lwk_jade` in our own process over a serial port.
bool get jadeLiquidSupported => true;

/// Devices that need HWI, named for the copy that has to explain their absence.
const String hwiOnlyFamilies = 'Trezor, Coldcard, KeepKey and BitBox';

/// Why a device row that needs the HWI helper cannot be used, in a few words —
/// for a single line next to that device rather than a paragraph.
String get hwiUnavailableHere => hwiFallbackUsable
    ? 'the helper is not installed yet'
    : 'blocked by the macOS App Sandbox';

/// Whether *every* attached-device family works here, or only the native ones.
bool get allFamiliesSupported => hwiFallbackUsable;

/// Why some devices are missing from the list, when they are. Empty when
/// everything works on this platform.
String get usbPartialSupportReason => hwiFallbackUsable
    ? ''
    : '$hwiOnlyFamilies need a helper process that the macOS App Sandbox will '
        'not let this app start, so they cannot be used over USB here. '
        '${nativeUsbFamilies.join(" and ")} connect directly and work '
        'normally.';

/// Legacy name still used by the wizard's connection card. Now describes a
/// partial limitation rather than a dead end, because USB is no longer off.
String get usbUnsupportedReason => usbPartialSupportReason;

/// Jade's Liquid path, worth pointing at whenever Liquid is in play.
const String jadeLiquidStillWorks =
    'A Blockstream Jade can hold a Liquid wallet here: Liquid talks to the '
    'device directly from inside the app, so it works on every platform.';

/// What the user can do instead when their device is one of the HWI-only ones.
const String usbUnsupportedAlternative =
    'Two routes work with any device: use a Ledger or a Jade over USB, or sign '
    'air-gapped — the app shows the unsigned transaction as a QR code, your '
    'device signs it offline, and you bring the signed transaction back by QR, '
    'file, or paste.';
