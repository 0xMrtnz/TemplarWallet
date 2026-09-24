import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyEvent, SystemChrome, SystemUiMode, SystemUiOverlayStyle;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'app/app_state.dart';
import 'app/router.dart';
import 'bridge/bridge_provider.dart';
import 'bridge/ffi_wallet_bridge.dart';
import 'features/vault/vault_migration_screen.dart';
import 'features/vault/vault_unlock_screen.dart';
import 'features/welcome/bridge_error_screen.dart';
import 'app/routes.dart';
import 'features/settings/seed_phrase_section.dart';
import 'services/auto_lock.dart';
import 'services/biometric_unlock_service.dart';
import 'services/crash_log.dart';
import 'services/price_service.dart';
import 'services/protocol_link_service.dart';
import 'theme/app_layout.dart';
import 'theme/app_theme.dart';

void main() {
  // Any uncaught error — sync, async, or framework — lands in the on-disk
  // log. Testers' crash reports otherwise contain nothing on Windows.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    if (Platform.isAndroid) {
      // Draw under the status and navigation bars — what Android 15 enforces
      // anyway, opted into here for every version. Screens keep their content
      // inside a SafeArea; the bars go transparent so the page ground shows
      // through them rather than a system-coloured strip.
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ));
    }
    // Android has no conventional data dir the engine could find on its own
    // (no XDG, no env): the app-private support dir is resolved once here and
    // handed to both the crash log and the native engine. Own subfolder, as on
    // desktop — google_fonts and other plugins cache into the support dir too.
    String? androidDataDir;
    if (Platform.isAndroid) {
      try {
        final support = await getApplicationSupportDirectory();
        androidDataDir = '${support.path}/templar_wallet';
      } catch (e) {
        debugPrint('application support dir: $e');
      }
    }
    await CrashLog.instance.init(dataDir: androidDataDir);
    FlutterError.onError = (details) {
      CrashLog.instance.error(details.exception, details.stack);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      CrashLog.instance.error(error, stack);
      return true;
    };
    if (androidDataDir != null) {
      try {
        final rc = FfiWalletBridge.setDataDir(androidDataDir);
        if (rc != 0) CrashLog.instance.write('wallet_set_data_dir: status $rc');
      } catch (e, st) {
        CrashLog.instance.error(e, st);
      }
    }
    // Force bridge construction now — top-level finals are lazy in Dart, and a
    // native-library load failure must be known before the first frame.
    debugPrint('bridge: ${walletBridge.runtimeType}');
    if (bridgeLoadError != null) {
      CrashLog.instance.error(bridgeLoadError!, null);
    }
    final appState = AppState();
    await appState.loadPrefs();
    // Which Liquid network the engine is on (testnet or a local regtest).
    // Best-effort: a failed read leaves the shell without its regtest strip,
    // and the settings screen reports the real error when opened.
    try {
      appState.setLiquidNetworkInfo(await walletBridge.getLiquidNetwork());
    } catch (e) {
      debugPrint('liquid network: $e');
    }
    // Warm up BTC price in background
    PriceService.instance.fetch();
    runApp(
      ChangeNotifierProvider.value(
        value: appState,
        child: const TemplarWalletApp(),
      ),
    );
  }, (error, stack) {
    CrashLog.instance.error(error, stack);
  });
}

class TemplarWalletApp extends StatefulWidget {
  const TemplarWalletApp({super.key});

  @override
  State<TemplarWalletApp> createState() => _TemplarWalletAppState();
}

class _TemplarWalletAppState extends State<TemplarWalletApp> {
  bool _vaultChecked = false;
  bool _vaultLocked = false;

  /// Wallets whose recovery phrase is still in the plaintext registry. Non-zero
  /// only on an install made before encryption was mandatory — the app is held
  /// on the migration screen until it is zero.
  int _plaintextSeeds = 0;

  /// True once templar:// links are routed to their screen — only after the
  /// vault gate is cleared, so a link can never open a screen in front of
  /// the unlock prompt. Links that arrive earlier wait.
  bool _linksArmed = false;

  /// Fingerprint unlock (Android, opt-in) is attempted exactly once per
  /// launch, from the vault check.
  bool _biometricTried = false;

  /// Auto-lock ([AutoLockPolicy]): when the app went out of sight, and the
  /// desktop idle timer that stands in for "out of sight" on a screen that
  /// never leaves.
  late final AppLifecycleListener _lifecycle;
  DateTime? _hiddenAt;
  Timer? _idleTimer;
  bool _locking = false;

  @override
  void initState() {
    super.initState();
    _checkVault();
    ProtocolLinkService.instance.start();
    _lifecycle = AppLifecycleListener(
      onHide: _onHidden,
      onPause: _onHidden,
      onShow: _onVisible,
      onResume: _onVisible,
    );
    HardwareKeyboard.instance.addHandler(_onKey);
    _restartIdleTimer();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idleTimer?.cancel();
    super.dispose();
  }

  void _onHidden() {
    _hiddenAt ??= DateTime.now();
    // A reveal grace must not survive the app leaving the screen.
    SeedRevealGate.reset();
  }

  Future<void> _onVisible() async {
    final since = _hiddenAt;
    _hiddenAt = null;
    if (since == null) return;
    final seconds = await AutoLockPolicy.seconds();
    if (AutoLockPolicy.due(since: since, now: DateTime.now(), seconds: seconds)) {
      await _autoLock();
    }
    _restartIdleTimer();
  }

  bool _onKey(KeyEvent _) {
    _restartIdleTimer();
    return false;
  }

  /// Desktop only: a phone's screen turns off and sends the app to the
  /// background, which the lifecycle listener already covers.
  Future<void> _restartIdleTimer() async {
    _idleTimer?.cancel();
    if (AppLayout.isMobilePlatform) return;
    final seconds = await AutoLockPolicy.seconds();
    if (seconds <= 0) return; // never, or "immediately" (lifecycle only)
    _idleTimer = Timer(Duration(seconds: seconds), _autoLock);
  }

  /// Lock at the root: the unlocked app (router, open sheets and dialogs) is
  /// replaced by the unlock screen, exactly like the launch gate. Installs
  /// without a vault (hardware / watch-only only) have nothing to lock.
  Future<void> _autoLock() async {
    if (_locking || _vaultLocked || !_vaultChecked || _plaintextSeeds > 0) return;
    _locking = true;
    try {
      final status = await walletBridge.vaultStatus();
      if (!status.initialized || !status.unlocked) return;
      await walletBridge.lockVault();
      SeedRevealGate.reset();
      if (!mounted) return;
      context.read<AppState>().setActiveWallet(null);
      appRouter.go(AppRoutes.walletPicker);
      setState(() => _vaultLocked = true);
    } catch (e) {
      debugPrint('auto-lock failed: $e');
    } finally {
      _locking = false;
    }
  }

  void _armLinks() {
    if (_linksArmed) return;
    _linksArmed = true;
    ProtocolLinkService.instance.arm((uri) {
      appRouter.go(
        '${AppRoutes.protocol}?link=${Uri.encodeQueryComponent(uri.toString())}',
      );
    });
  }

  Future<void> _checkVault() async {
    // At-rest encryption (C1): when a vault exists, wallet storage stays
    // sealed until the passphrase is entered. A bridge failure must not brick
    // startup — the picker / error screen reports the real problem.
    var locked = false;
    var plaintextSeeds = 0;
    try {
      final status = await walletBridge.vaultStatus();
      locked = status.initialized && !status.unlocked;
      plaintextSeeds = status.plaintextSeedWallets;
    } catch (_) {}
    if (locked && plaintextSeeds == 0) {
      // Fingerprint first, passphrase screen only if that does not open the
      // vault.
      locked = !await _biometricUnlock();
    }
    if (!mounted) return;
    setState(() {
      _vaultLocked = locked;
      _plaintextSeeds = plaintextSeeds;
      _vaultChecked = true;
    });
  }

  /// The one launch-time fingerprint attempt. True when the vault is open
  /// afterwards. Silent and cheap when the feature is off or not on Android,
  /// and never throws: a failure here must not hold the app on the loading
  /// screen — the passphrase screen is the fallback.
  Future<bool> _biometricUnlock() async {
    if (_biometricTried) return false;
    _biometricTried = true;
    try {
      final bio = BiometricUnlockService.instance;
      if (!await bio.isEnabled()) return false;
      return await bio.tryUnlock();
    } catch (e) {
      debugPrint('biometric unlock at launch: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fatal in non-debug builds: the native wallet engine failed to load and
    // no mock fallback is allowed. Nothing else in the app can work — show
    // only the error screen (before the vault gate; there is nothing to unlock).
    if (bridgeLoadError != null && !kDebugMode) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        builder: AppTheme.phoneBuilder,
        home: BridgeErrorScreen(error: bridgeLoadError!),
      );
    }

    return Consumer<AppState>(
      builder: (context, state, _) {
        final app = MaterialApp.router(
          title: 'Templar Wallet',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: state.themeMode,
          // The phone's filled controls (see AppTheme.phoneBuilder). Off a
          // phone this returns the child untouched.
          builder: AppTheme.phoneBuilder,
          routerConfig: appRouter,
        );

        if (!_vaultChecked) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            builder: AppTheme.phoneBuilder,
            home: const Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        // Seeds in the clear from an older build: encrypt before anything
        // else. Ordered ahead of the unlock gate because the two are mutually
        // exclusive — there is no vault to unlock while this is true.
        if (_plaintextSeeds > 0) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            builder: AppTheme.phoneBuilder,
            home: VaultMigrationScreen(
              seedWalletCount: _plaintextSeeds,
              onMigrated: () => setState(() => _plaintextSeeds = 0),
            ),
          );
        }

        // Encrypted wallet storage (C1): the registry stays sealed on disk
        // until the vault passphrase is entered — no wallet data to route to.
        if (_vaultLocked) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.dark(),
            builder: AppTheme.phoneBuilder,
            home: VaultUnlockScreen(
              onUnlocked: () {
                setState(() => _vaultLocked = false);
                _restartIdleTimer();
              },
              // The launch attempt above has already prompted once; the
              // screen offers the "Use fingerprint" button for a retry.
              biometricAutoPrompt: false,
            ),
          );
        }

        // Every gate is open: deliver deep links from now on.
        WidgetsBinding.instance.addPostFrameCallback((_) => _armLinks());
        // Any pointer activity counts as presence for the desktop idle lock.
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _restartIdleTimer(),
          onPointerSignal: (_) => _restartIdleTimer(),
          onPointerHover: (_) => _restartIdleTimer(),
          child: app,
        );
      },
    );
  }
}
