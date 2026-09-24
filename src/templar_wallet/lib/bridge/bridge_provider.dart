// Single source of truth for the WalletBridge implementation.
// Uses FfiWalletBridge on desktop and Android, where the native library ships
// with the app.
// A failed native load is FATAL in release builds (main.dart shows
// BridgeErrorScreen); only debug builds fall back to MockWalletBridge, with a
// persistent badge in the shell so fake data can never pass for real.

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ffi_wallet_bridge.dart';
import 'mock_wallet_bridge.dart';
import 'wallet_bridge.dart';

/// Set when the native wallet library failed to load. Checked by main.dart
/// (fatal error screen in non-debug builds) and by the shell badge.
Object? bridgeLoadError;

/// True when the UI is running on fake in-memory data — either the debug
/// fallback after a failed native load, or an unsupported platform.
bool get isMockBridge => walletBridge is MockWalletBridge;

/// Debug-only: `--dart-define=TEMPLAR_MOCK_BRIDGE=true` forces the in-memory
/// mock so populated screens can be exercised on a device without funding a
/// testnet wallet. Ignored outside debug builds — release never serves mock
/// data (see [createBridge]).
const bool _forceMockBridge = bool.fromEnvironment('TEMPLAR_MOCK_BRIDGE');

/// `flutter test` sets FLUTTER_TEST. A widget test must never load a native
/// engine: which one it found would depend on the host (a stale build under
/// target/ on one machine, nothing on a CI runner), and a real engine opens
/// the real wallet data folder.
bool get _underFlutterTest => Platform.environment.containsKey('FLUTTER_TEST');

WalletBridge createBridge() {
  if (kDebugMode && (_forceMockBridge || _underFlutterTest)) {
    if (_forceMockBridge) {
      debugPrint('TEMPLAR_MOCK_BRIDGE set: serving MockWalletBridge');
    }
    return MockWalletBridge();
  }
  if (Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isAndroid) {
    try {
      return FfiWalletBridge();
    } catch (e, st) {
      bridgeLoadError = e;
      debugPrint('!!! FfiWalletBridge load FAILED: $e');
      debugPrint('$st');
      if (kDebugMode) {
        // Debug-only convenience: keep the app usable on fake data. The shell
        // shows a persistent "MOCK DATA" badge so this can't go unnoticed.
        return MockWalletBridge();
      }
      // Release (and profile): never serve mock wallets — phantom balances and
      // an address nobody controls. Every call fails with the load error;
      // main.dart never routes past the fatal error screen anyway.
      return _UnloadedBridge(e);
    }
  }
  return MockWalletBridge();
}

/// Defensive stub for release builds when the native library failed to load:
/// every bridge call rejects with the original load error.
class _UnloadedBridge implements WalletBridge {
  _UnloadedBridge(this.error);
  final Object error;

  // Every WalletBridge member returns a Future, so a failed Future satisfies
  // all of them.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(StateError('Wallet engine not loaded: $error'));
}

// Global singleton — instantiated once at startup. Top-level finals are lazy
// in Dart; main.dart touches this before runApp so bridgeLoadError is set
// before the first frame.
final WalletBridge walletBridge = createBridge();
