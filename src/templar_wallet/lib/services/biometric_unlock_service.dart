import 'dart:io' show Platform;

import 'package:biometric_storage/biometric_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bridge_provider.dart';
import '../bridge/wallet_bridge.dart';

/// Fingerprint unlock of the vault: Android, and Touch ID on macOS.
///
/// # What is stored, and where
///
/// Enabling exports the raw vault key from the engine and seals it behind
/// the sensor.
///
/// On Android it is written into a file that the Keystore encrypts with a
/// hardware-backed AES key (StrongBox where the device has one). That key is
/// created with `setUserAuthenticationRequired(true)` and, on Android 11+,
/// with `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)`: a
/// class-3 biometric is required for *every single* decrypt, the cipher is
/// bound to the prompt through a `CryptoObject`, and no device credential
/// (PIN, pattern) can stand in for the sensor.
///
/// On macOS it is sealed to a Secure Enclave key whose access control is
/// `.biometryCurrentSet` — see `macos/Runner/TouchIdVaultKey.swift` for why
/// the keychain is not used (an ad-hoc-signed app cannot). Same rule: the
/// enclave asks for Touch ID on every use, and no password stands in.
///
/// On both, enrolling a new fingerprint invalidates the key, after which the
/// sealed file is unreadable and biometric unlock silently switches itself
/// off.
///
/// # The confirmation gates
///
/// On the Mac, and only there by decision, the same sealed key can also stand
/// in for the passphrase at the *confirmation* gates — signing, sharing
/// wallet data, revealing a seed. [confirm] shows the Touch ID sheet, reads
/// the key, and asks the engine to prove it against the vault without opening
/// a session (`verify_vault_key`, the twin of `verify_vault_passphrase`).
/// The user can switch this off separately ("Also confirm with Touch ID");
/// the passphrase always works too. Android keeps asking for the passphrase
/// at those gates. The app PIN, when set, still comes first.
///
/// # Key handling
///
/// The exported key exists in Dart memory as a `String` between the engine
/// call and the store write (enable) or the store read and the engine call
/// (unlock). Dart strings are immutable and garbage-collected, so there is no
/// way to zero them; the window is kept as short as possible and the value
/// is never logged, never put in an error message, never cached.
class BiometricUnlockService {
  BiometricUnlockService._()
      : _store = Platform.isMacOS ? _MacKeyStore() : _PluginKeyStore(),
        _bridge = null,
        _platformOk = platformSupported,
        _confirmPlatformOk = confirmPlatformSupported;

  /// Where a sensor can open the vault at all: Android (fingerprint) and
  /// macOS (Touch ID). Screens gate their biometric rows on this.
  static bool get platformSupported => Platform.isAndroid || Platform.isMacOS;

  /// Where a sensor can also stand in for the passphrase at a confirmation
  /// gate: the Mac only. Windows and Linux have no sensor path; Android keeps
  /// the passphrase at those gates by decision.
  static bool get confirmPlatformSupported => Platform.isMacOS;

  /// What the sensor is called on this platform, for copy.
  static String get sensorName => Platform.isMacOS ? 'Touch ID' : 'Fingerprint';

  /// Test seam: a fake store and bridge, and a platform override so the flag
  /// logic can run on a desktop test host.
  @visibleForTesting
  BiometricUnlockService.forTest({
    required this._store,
    required WalletBridge this._bridge,
    bool platformSupported = true,
    bool confirmPlatformSupported = true,
  })  : _platformOk = platformSupported,
        _confirmPlatformOk = confirmPlatformSupported;

  static final BiometricUnlockService instance = BiometricUnlockService._();

  static const _kEnabled = 'pref_biometric_unlock';
  static const _kConfirm = 'pref_biometric_confirm';

  final BiometricKeyStore _store;
  final WalletBridge? _bridge;
  final bool _platformOk;
  final bool _confirmPlatformOk;

  /// Why the last [tryUnlock] returned false, in words meant for the user —
  /// null after a success or a plain dismissal. Never contains key material.
  String? lastMessage;

  static String get _msgKeyGone =>
      '$sensorName unlock was turned off because the fingerprints on this '
      'device changed. Unlock with your passphrase, then turn it on again in '
      'Settings.';
  static String get _msgMismatch =>
      '$sensorName unlock was turned off because the stored key no longer '
      'matches this vault. Unlock with your passphrase, then turn it on again '
      'in Settings.';
  static String get _msgFailed =>
      '$sensorName unlock did not work this time. Use your passphrase.';

  // Lazy on purpose: touching the global constructs the FFI bridge, which
  // tests must never do.
  WalletBridge get _wallet => _bridge ?? walletBridge;

  /// Whether this device can do biometric unlock right now. False off the
  /// supported platforms, without touching the plugin.
  Future<bool> isSupported() async =>
      await availability() == BiometricAvailability.available;

  /// Finer-grained than [isSupported], for the Settings card: "no fingerprint
  /// enrolled" deserves a hint where "no sensor" deserves nothing.
  Future<BiometricAvailability> availability() async {
    if (!_platformOk) return BiometricAvailability.unavailable;
    try {
      return await _store.availability();
    } catch (e) {
      debugPrint('biometric unlock: availability check failed: $e');
      return BiometricAvailability.unavailable;
    }
  }

  /// The user's choice. Off the platform this is always false, whatever the
  /// preferences say.
  Future<bool> isEnabled() async {
    if (!_platformOk) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? false;
  }

  /// Export the vault key and seal it behind the fingerprint prompt, then
  /// remember the choice. The vault must be unlocked (the engine only hands
  /// out the key of an open vault) — check [WalletBridge.vaultStatus] first
  /// and send the user through the unlock screen if it is not.
  ///
  /// Throws [BiometricUnlockCancelled] when the user dismisses the prompt,
  /// [StateError] when the vault is absent or locked, and whatever the store
  /// or the engine raise otherwise. Nothing is persisted on failure.
  Future<void> enable() async {
    if (!_platformOk) {
      throw StateError('Biometric unlock is only available on Android and macOS.');
    }
    final status = await _wallet.vaultStatus();
    if (!status.initialized) {
      throw StateError('Set a vault passphrase before enabling biometric unlock.');
    }
    if (!status.unlocked) {
      throw StateError('Unlock wallet storage before enabling biometric unlock.');
    }
    final keyHex = await _wallet.exportVaultKey();
    // The write is what shows the fingerprint prompt (the plugin binds the
    // encrypt cipher to it). A cancel surfaces as BiometricUnlockCancelled.
    await _store.write(keyHex);
    await _setEnabled(true);
  }

  /// Forget the sealed key and the choice. Safe to call when already off.
  Future<void> disable() async {
    if (!_platformOk) return;
    // Flag first: even if the delete fails, no launch will try the key again.
    await _setEnabled(false);
    try {
      await _store.delete();
    } catch (e) {
      debugPrint('biometric unlock: could not delete the sealed key: $e');
    }
  }

  /// Show the fingerprint prompt and open the vault with the sealed key.
  ///
  /// Returns true when the vault is unlocked afterwards. Never throws: a
  /// cancelled prompt, a missing sensor, a plugin error — all return false
  /// and leave the passphrase path to the caller. Two outcomes also switch
  /// the feature off, because retrying could never succeed: the sealed file
  /// is gone (the Keystore key was invalidated by a new enrolment), or the
  /// engine reports the key "does not match" (the vault was re-created).
  Future<bool> tryUnlock() async {
    lastMessage = null;
    try {
      if (!await isEnabled()) return false;
      final keyHex = await _store.read();
      if (keyHex == null || keyHex.isEmpty) {
        debugPrint('biometric unlock: sealed key missing, switching off');
        await disable();
        lastMessage = _msgKeyGone;
        return false;
      }
      try {
        await _wallet.unlockVaultWithKey(keyHex);
      } catch (e) {
        // Deliberately not echoing the engine message: it is the one place a
        // key-shaped string could leak into a log.
        if (e.toString().contains('does not match')) {
          debugPrint('biometric unlock: key rejected by the vault, switching off');
          await disable();
          lastMessage = _msgMismatch;
        } else {
          debugPrint('biometric unlock: engine refused the key (${e.runtimeType})');
          lastMessage = _msgFailed;
        }
        return false;
      }
      return true;
    } on BiometricUnlockCancelled {
      return false;
    } on AuthException catch (e) {
      // Lockouts and sensor errors carry the system's own wording
      // ("Too many attempts. Try again later."), never key material.
      debugPrint('biometric unlock: ${e.code}');
      lastMessage = '$sensorName unavailable: ${e.message}';
      return false;
    } catch (e) {
      debugPrint('biometric unlock: failed (${e.runtimeType})');
      lastMessage = _msgFailed;
      return false;
    }
  }

  Future<void> _setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
  }

  // ── Confirmation gates ───────────────────────────────────────────────────

  /// The user's choice for the confirmation gates. On by default once the
  /// unlock itself is on — the switch exists to turn it off — and always
  /// false off the Mac.
  Future<bool> isConfirmEnabled() async {
    if (!_confirmPlatformOk) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kConfirm) ?? true;
  }

  Future<void> setConfirmEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kConfirm, value);
  }

  /// Whether a confirmation gate should offer the sensor right now: the Mac,
  /// unlock enabled, the confirmation switch on, and a usable sensor.
  Future<bool> confirmAvailable() async {
    if (!_confirmPlatformOk) return false;
    if (!await isEnabled()) return false;
    if (!await isConfirmEnabled()) return false;
    return isSupported();
  }

  /// Show the sensor prompt and prove the sealed key against the vault
  /// without opening a session — the sensor's answer to "confirm with your
  /// app password".
  ///
  /// Returns true when the key was proven. Never throws: a dismissed prompt,
  /// a missing sensor, a plugin error all return false and leave the
  /// passphrase field to the caller, with [lastMessage] saying why when
  /// there is something to say. A sealed key that is gone or no longer
  /// matches switches the whole feature off, as [tryUnlock] does.
  Future<bool> confirm({required String reason}) async {
    lastMessage = null;
    try {
      if (!await confirmAvailable()) return false;
      final keyHex = await _store.read(reason: reason);
      if (keyHex == null || keyHex.isEmpty) {
        debugPrint('biometric confirm: sealed key missing, switching off');
        await disable();
        lastMessage = _msgKeyGone;
        return false;
      }
      try {
        await _wallet.verifyVaultKey(keyHex);
      } catch (e) {
        if (e.toString().contains('does not match')) {
          debugPrint('biometric confirm: key rejected by the vault, switching off');
          await disable();
          lastMessage = _msgMismatch;
        } else {
          debugPrint('biometric confirm: engine refused the key (${e.runtimeType})');
          lastMessage = _msgFailed;
        }
        return false;
      }
      return true;
    } on BiometricUnlockCancelled {
      return false;
    } on AuthException catch (e) {
      debugPrint('biometric confirm: ${e.code}');
      lastMessage = '$sensorName unavailable: ${e.message}';
      return false;
    } catch (e) {
      debugPrint('biometric confirm: failed (${e.runtimeType})');
      lastMessage = _msgFailed;
      return false;
    }
  }
}

/// Whether the device can show a biometric prompt at all.
enum BiometricAvailability {
  /// A class-3 biometric is enrolled and the sensor is usable.
  available,

  /// The device has a sensor but nothing is enrolled — the user can fix it in
  /// the system settings.
  noneEnrolled,

  /// No usable sensor, or a platform without one.
  unavailable,
}

/// The user dismissed the system prompt (cancel, back, or the negative
/// button). Not an error: the caller falls back to the passphrase.
class BiometricUnlockCancelled implements Exception {
  const BiometricUnlockCancelled();

  @override
  String toString() => 'BiometricUnlockCancelled';
}

/// The sealed-key file behind the fingerprint prompt, as the service sees it.
/// One production implementation ([_PluginKeyStore]) and whatever a test
/// wants to stand in for it.
abstract class BiometricKeyStore {
  Future<BiometricAvailability> availability();

  /// Read the sealed key. Shows the prompt. Null when no key is stored (or
  /// the Keystore key was invalidated and the plugin dropped the file).
  /// Throws [BiometricUnlockCancelled] when the user dismisses the prompt.
  ///
  /// [reason] is what the prompt says the app is trying to do, where the
  /// platform lets the app say it (the Mac's "Templar Wallet is trying to
  /// …"); null means the unlock wording.
  Future<String?> read({String? reason});

  /// Seal [keyHex]. Shows the prompt. Throws [BiometricUnlockCancelled] when
  /// the user dismisses it.
  Future<void> write(String keyHex);

  /// Remove the sealed key and its Keystore key. No prompt.
  Future<void> delete();
}

/// `biometric_storage` (authpass) backing.
class _PluginKeyStore implements BiometricKeyStore {
  static const _fileName = 'templar_vault_key';

  /// The strictest options the plugin offers: authentication for every use
  /// (`-1` = no validity window, so no cached authorisation can be replayed),
  /// biometric only (a device PIN cannot stand in — and the plugin requires
  /// this whenever the window is `-1`). Same options on every call: the
  /// plugin keeps the first ones it sees for a file name.
  static final _options = StorageFileInitOptions(
    authenticationValidityDurationSeconds: -1,
    authenticationRequired: true,
    androidBiometricOnly: true,
  );

  /// Copy of the prompt shown while *enabling*. Confirmation left at the
  /// plugin default (required): with a face sensor the user gets an explicit
  /// button before the key is sealed.
  static const enablePrompt = PromptInfo(
    androidPromptInfo: AndroidPromptInfo(
      title: 'Enable fingerprint unlock',
      subtitle: 'Templar Wallet',
      description:
          'Confirm your fingerprint to protect the vault key on this device.',
      negativeButton: 'Cancel',
    ),
  );

  /// Copy of the prompt shown at launch / on "Use fingerprint". No extra
  /// confirmation step: the sensor read alone opens the vault, and the
  /// negative button reads as the alternative it really is.
  static const unlockPrompt = PromptInfo(
    androidPromptInfo: AndroidPromptInfo(
      title: 'Unlock wallet storage',
      subtitle: 'Templar Wallet',
      description: 'Touch the fingerprint sensor to open your vault.',
      negativeButton: 'Use passphrase',
      confirmationRequired: false,
    ),
  );

  Future<BiometricStorageFile> _file() =>
      BiometricStorage().getStorage(_fileName, options: _options);

  @override
  Future<BiometricAvailability> availability() async {
    switch (await BiometricStorage().canAuthenticate()) {
      case CanAuthenticateResponse.success:
        return BiometricAvailability.available;
      case CanAuthenticateResponse.errorNoBiometricEnrolled:
        return BiometricAvailability.noneEnrolled;
      case CanAuthenticateResponse.errorHwUnavailable:
      case CanAuthenticateResponse.errorNoHardware:
      case CanAuthenticateResponse.errorPasscodeNotSet:
      case CanAuthenticateResponse.statusUnknown:
      case CanAuthenticateResponse.unsupported:
        return BiometricAvailability.unavailable;
    }
  }

  @override
  Future<String?> read({String? reason}) =>
      _prompted(() async => (await _file()).read(promptInfo: unlockPrompt));

  @override
  Future<void> write(String keyHex) => _prompted(
      () async => (await _file()).write(keyHex, promptInfo: enablePrompt));

  @override
  Future<void> delete() async => (await _file()).delete();

  /// Map the plugin's "the user went away" codes to [BiometricUnlockCancelled];
  /// everything else propagates as the error it is.
  Future<T> _prompted<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on AuthException catch (e) {
      switch (e.code) {
        case AuthExceptionCode.userCanceled:
        case AuthExceptionCode.canceled:
        case AuthExceptionCode.timeout:
          throw const BiometricUnlockCancelled();
        case AuthExceptionCode.unknown:
        case AuthExceptionCode.linuxAppArmorDenied:
          rethrow;
      }
    }
  }
}

/// macOS backing: the Runner's `TouchIdVaultKey` channel (Secure Enclave +
/// Touch ID). Same contract as the Android store; the native side owns the
/// prompt, the sealing and the file.
class _MacKeyStore implements BiometricKeyStore {
  static const _channel = MethodChannel('dev.templarwallet/touch_id');

  static const _enableReason =
      'confirm Touch ID to protect the vault key on this Mac';
  static const _unlockReason = 'open your vault';

  @override
  Future<BiometricAvailability> availability() async {
    final a = await _channel.invokeMethod<String>('availability');
    return switch (a) {
      'available' => BiometricAvailability.available,
      'noneEnrolled' => BiometricAvailability.noneEnrolled,
      _ => BiometricAvailability.unavailable,
    };
  }

  @override
  Future<String?> read({String? reason}) => _prompted(() => _channel
      .invokeMethod<String>('read', {'reason': reason ?? _unlockReason}));

  @override
  Future<void> write(String keyHex) => _prompted(() => _channel
      .invokeMethod<void>('write', {'content': keyHex, 'reason': _enableReason}));

  @override
  Future<void> delete() => _channel.invokeMethod<void>('delete');

  /// The channel's error codes, in the service's terms: a dismissed sheet is
  /// [BiometricUnlockCancelled]; a key the enclave no longer honours reads
  /// as absent (the service then switches the feature off and says why);
  /// a lockout or anything else is an [AuthException] carrying the system's
  /// own wording.
  Future<T> _prompted<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'cancelled':
          throw const BiometricUnlockCancelled();
        case 'invalidated':
          // Only read() can land here, and null is its "nothing sealed".
          return null as T;
        case 'lockout':
          throw AuthException(
              AuthExceptionCode.unknown, e.message ?? 'Touch ID is locked');
        case 'not_enrolled':
          throw AuthException(AuthExceptionCode.unknown,
              e.message ?? 'No fingerprint is enrolled in Touch ID');
        default:
          throw AuthException(
              AuthExceptionCode.unknown, e.message ?? 'Touch ID failed');
      }
    }
  }
}
