// BiometricUnlockService flag logic against the in-memory mock bridge and a
// fake sealed-key store. The real store is the biometric_storage plugin,
// which has no Dart-side fake and needs an Android Keystore — so the store
// sits behind the BiometricKeyStore interface and this is what it is for.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/bridge/mock_wallet_bridge.dart';
import 'package:templar_wallet/services/biometric_unlock_service.dart';

/// Records every call and can be told to behave like a dismissed prompt, a
/// plugin failure, or a file that vanished (Keystore key invalidated).
class _FakeKeyStore implements BiometricKeyStore {
  String? sealed;
  BiometricAvailability available = BiometricAvailability.available;

  /// The next prompt (read or write) is dismissed by the user.
  bool cancelNext = false;

  /// The next prompt (read or write) throws this.
  Object? failNext;

  /// Delete throws.
  bool failDelete = false;

  int reads = 0;
  int writes = 0;
  int deletes = 0;

  @override
  Future<BiometricAvailability> availability() async => available;

  /// The reason the last read was prompted with — what the Mac's sheet says.
  String? lastReason;

  @override
  Future<String?> read({String? reason}) async {
    reads++;
    lastReason = reason;
    _maybeThrow();
    return sealed;
  }

  @override
  Future<void> write(String keyHex) async {
    writes++;
    _maybeThrow();
    sealed = keyHex;
  }

  @override
  Future<void> delete() async {
    deletes++;
    if (failDelete) throw StateError('delete failed');
    sealed = null;
  }

  void _maybeThrow() {
    if (cancelNext) {
      cancelNext = false;
      throw const BiometricUnlockCancelled();
    }
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockWalletBridge bridge;
  late _FakeKeyStore store;
  late BiometricUnlockService bio;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    bridge = MockWalletBridge();
    store = _FakeKeyStore();
    bio = BiometricUnlockService.forTest(store: store, bridge: bridge);
    await bridge.setupVault('correct horse battery staple');
  });

  Future<bool> vaultUnlocked() async => (await bridge.vaultStatus()).unlocked;

  test('off by default; supported only when the sensor is usable', () async {
    expect(await bio.isEnabled(), isFalse);
    expect(await bio.isSupported(), isTrue);
    expect(await bio.availability(), BiometricAvailability.available);

    store.available = BiometricAvailability.noneEnrolled;
    expect(await bio.isSupported(), isFalse);
    expect(await bio.availability(), BiometricAvailability.noneEnrolled);
  });

  test('never supported or enabled off the platform', () async {
    SharedPreferences.setMockInitialValues({'pref_biometric_unlock': true});
    final desktop = BiometricUnlockService.forTest(
      store: store,
      bridge: bridge,
      platformSupported: false,
    );
    expect(await desktop.isSupported(), isFalse);
    expect(await desktop.isEnabled(), isFalse);
    expect(await desktop.tryUnlock(), isFalse);
    expect(store.reads, 0);
    expect(() => desktop.enable(), throwsStateError);
  });

  test('enable seals the exported key and sets the flag', () async {
    await bio.enable();
    expect(store.writes, 1);
    expect(store.sealed, await bridge.exportVaultKey());
    expect(store.sealed, hasLength(64));
    expect(await bio.isEnabled(), isTrue);
  });

  test('enable refuses a locked vault and stores nothing', () async {
    await bridge.lockVault();
    expect(() => bio.enable(), throwsStateError);
    expect(store.writes, 0);
    expect(await bio.isEnabled(), isFalse);
  });

  test('enable refuses a missing vault', () async {
    final fresh = MockWalletBridge();
    final svc = BiometricUnlockService.forTest(store: store, bridge: fresh);
    expect(() => svc.enable(), throwsStateError);
    expect(store.writes, 0);
  });

  test('enable leaves everything off when the prompt is dismissed', () async {
    store.cancelNext = true;
    expect(() => bio.enable(), throwsA(isA<BiometricUnlockCancelled>()));
    await Future<void>.delayed(Duration.zero);
    expect(store.sealed, isNull);
    expect(await bio.isEnabled(), isFalse);
  });

  test('tryUnlock is a no-op while disabled', () async {
    await bridge.lockVault();
    expect(await bio.tryUnlock(), isFalse);
    expect(store.reads, 0);
    expect(await vaultUnlocked(), isFalse);
  });

  test('tryUnlock opens the vault with the sealed key', () async {
    await bio.enable();
    await bridge.lockVault();
    expect(await vaultUnlocked(), isFalse);

    expect(await bio.tryUnlock(), isTrue);
    expect(store.reads, 1);
    expect(await vaultUnlocked(), isTrue);
    expect(await bio.isEnabled(), isTrue);
  });

  test('tryUnlock stays enabled when the prompt is dismissed', () async {
    await bio.enable();
    await bridge.lockVault();
    store.cancelNext = true;

    expect(await bio.tryUnlock(), isFalse);
    expect(await vaultUnlocked(), isFalse);
    expect(await bio.isEnabled(), isTrue);
    expect(store.sealed, isNotNull);
  });

  test('tryUnlock switches itself off when the key no longer matches',
      () async {
    await bio.enable();
    // The vault is re-created: a new key, the sealed one is now stale.
    await bridge.setupVault('a different passphrase');
    await bridge.lockVault();

    expect(await bio.tryUnlock(), isFalse);
    expect(await vaultUnlocked(), isFalse);
    expect(await bio.isEnabled(), isFalse);
    expect(store.deletes, 1);
    expect(store.sealed, isNull);
  });

  test('tryUnlock switches itself off when the sealed key is gone', () async {
    await bio.enable();
    await bridge.lockVault();
    // What the plugin does after a new fingerprint enrolment invalidates the
    // Keystore key: the file is dropped and read answers null.
    store.sealed = null;

    expect(await bio.tryUnlock(), isFalse);
    expect(await bio.isEnabled(), isFalse);
    expect(await vaultUnlocked(), isFalse);
  });

  test('tryUnlock never throws', () async {
    await bio.enable();
    await bridge.lockVault();

    store.failNext = StateError('plugin not attached');
    expect(await bio.tryUnlock(), isFalse);
    expect(await bio.isEnabled(), isTrue);

    // A malformed sealed value: the engine rejects it, the feature stays on
    // (only "does not match" is a permanent verdict).
    store.sealed = 'not hex';
    expect(await bio.tryUnlock(), isFalse);
    expect(await vaultUnlocked(), isFalse);
    expect(await bio.isEnabled(), isTrue);
  });

  test('disable clears the flag even when the delete fails', () async {
    await bio.enable();
    store.failDelete = true;

    await bio.disable();
    expect(await bio.isEnabled(), isFalse);
    expect(store.deletes, 1);

    // Nothing is tried afterwards, so a stale file can never be replayed.
    await bridge.lockVault();
    expect(await bio.tryUnlock(), isFalse);
    expect(store.reads, 0);
  });

  test('disable is safe when already off', () async {
    await bio.disable();
    expect(await bio.isEnabled(), isFalse);
    expect(store.deletes, 1);
  });

  group('confirm (the Mac\'s Touch ID at a password gate)', () {
    test('is not offered until unlock is on, and then is on by default',
        () async {
      expect(await bio.confirmAvailable(), isFalse);
      await bio.enable();
      expect(await bio.isConfirmEnabled(), isTrue);
      expect(await bio.confirmAvailable(), isTrue);
    });

    test('the switch turns it off without touching the unlock', () async {
      await bio.enable();
      await bio.setConfirmEnabled(false);
      expect(await bio.confirmAvailable(), isFalse);
      expect(await bio.isEnabled(), isTrue);
      expect(await bio.confirm(reason: 'sign'), isFalse);
      expect(store.reads, 0, reason: 'no prompt when the switch is off');
    });

    test('off the Mac it is never offered, whatever the preferences say',
        () async {
      final elsewhere = BiometricUnlockService.forTest(
          store: store, bridge: bridge, confirmPlatformSupported: false);
      await elsewhere.enable();
      expect(await elsewhere.isConfirmEnabled(), isFalse);
      expect(await elsewhere.confirmAvailable(), isFalse);
    });

    test('a pass proves the key without opening a session', () async {
      await bio.enable();
      await bridge.lockVault();
      expect(await bio.confirm(reason: 'sign this transaction'), isTrue);
      expect(store.lastReason, 'sign this transaction');
      // Proven, not granted: the vault is exactly as locked as before.
      expect((await bridge.vaultStatus()).unlocked, isFalse);
      expect(bio.lastMessage, isNull);
    });

    test('a dismissed prompt is a quiet no', () async {
      await bio.enable();
      store.cancelNext = true;
      expect(await bio.confirm(reason: 'sign'), isFalse);
      expect(bio.lastMessage, isNull);
      expect(await bio.isEnabled(), isTrue);
    });

    test('a key that no longer matches switches the feature off and says so',
        () async {
      await bio.enable();
      store.sealed = 'ff' * 32;
      expect(await bio.confirm(reason: 'sign'), isFalse);
      expect(await bio.isEnabled(), isFalse);
      expect(bio.lastMessage, contains('no longer matches'));
    });

    test('a vanished key switches the feature off and says so', () async {
      await bio.enable();
      store.sealed = null;
      expect(await bio.confirm(reason: 'sign'), isFalse);
      expect(await bio.isEnabled(), isFalse);
      expect(bio.lastMessage, contains('fingerprints on this device changed'));
    });
  });
}
