// Documentation screenshots — drives the real desktop app and writes one PNG
// per screen into SHOT_DIR. Not a test of anything: every step is best-effort
// and logs a MISS instead of failing, so one moved label cannot cost the whole
// tour.
//
//   flutter test integration_test/screenshots_test.dart -d macos \
//     --dart-define=TEMPLAR_MOCK_BRIDGE=true \
//     --dart-define=TEMPLAR_SHOTS=true \
//     --dart-define=SHOT_DIR=/absolute/output/dir
//
// The mock bridge supplies the populated wallets ("Primary" has Liquid); the
// shots flag hides the MOCK DATA strip (lib/dev/shot_mode.dart).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/app/router.dart';
import 'package:templar_wallet/app/routes.dart';
import 'package:templar_wallet/bridge/bridge_provider.dart';
import 'package:templar_wallet/features/create_wallet/models/new_wallet_draft.dart';
import 'package:templar_wallet/main.dart';

const String _shotDirDefine = String.fromEnvironment('SHOT_DIR');

/// Comma-separated scene names, or `all`. Lets a single screen be re-shot
/// without walking the whole app: `--dart-define=SCENES=send,settings`.
const String _scenes = String.fromEnvironment('SCENES', defaultValue: 'all');

bool _want(String scene) =>
    _scenes == 'all' || _scenes.split(',').contains(scene);
final GlobalKey _shotKey = GlobalKey();
late final String _outDir;
int _seq = 0;

/// The app is sandboxed on macOS, so a path outside its container is not
/// writable however the test is invoked: SHOT_DIR is used when it works and
/// the container's own temp dir otherwise (the runner prints the path and the
/// caller copies the PNGs out).
String _resolveOutDir() {
  for (final candidate in <String>[
    if (_shotDirDefine.isNotEmpty) _shotDirDefine,
    '${Directory.systemTemp.path}/templar-shots',
  ]) {
    try {
      final dir = Directory(candidate)..createSync(recursive: true);
      File('${dir.path}/.probe').writeAsStringSync('ok');
      File('${dir.path}/.probe').deleteSync();
      return dir.path;
    } catch (_) {
      continue;
    }
  }
  fail('no writable screenshot directory');
}

Future<void> _wait(WidgetTester tester, [int ms = 700]) async {
  for (var i = 0; i < (ms / 100).ceil(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String scene, String name,
    {int settle = 600}) async {
  await _wait(tester, settle);
  final boundary =
      _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File('$_outDir/$name.png');
  file.writeAsBytesSync(data!.buffer.asUint8List());
  _seq++;
  debugPrint('SHOT ${file.path}');
}

Future<bool> _tapText(WidgetTester tester, String label,
    {int ms = 900, bool last = false}) async {
  final finder = find.text(label).hitTestable();
  if (finder.evaluate().isEmpty) {
    debugPrint('MISS text "$label"');
    return false;
  }
  await tester.tap(last ? finder.last : finder.first, warnIfMissed: false);
  await _wait(tester, ms);
  return true;
}

Future<void> _go(WidgetTester tester, String route, {int ms = 1200}) async {
  appRouter.go(route);
  await _wait(tester, ms);
}

/// Types into the field that carries [hint] as its hint or label.
Future<bool> _type(WidgetTester tester, String hint, String text) async {
  final field =
      find.ancestor(of: find.text(hint), matching: find.byType(TextField));
  if (field.evaluate().isEmpty) {
    debugPrint('MISS field "$hint"');
    return false;
  }
  await tester.enterText(field.first, text);
  await _wait(tester, 400);
  return true;
}

Future<void> _scroll(WidgetTester tester, double dy) async {
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  await tester.drag(scrollable.first, Offset(0, dy));
  await _wait(tester, 600);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('desktop tour', (tester) async {
    _outDir = _resolveOutDir();
    debugPrint('SHOT_DIR $_outDir');

    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(2560, 1600); // 1280 x 800 logical

    final appState = AppState();
    await appState.loadPrefs();
    try {
      appState.setLiquidNetworkInfo(await walletBridge.getLiquidNetwork());
    } catch (_) {}

    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: ChangeNotifierProvider.value(
          value: appState,
          child: const TemplarWalletApp(),
        ),
      ),
    );
    await _wait(tester, 2500);

    // Every scene opens its own wallet state from the picker, so a scene can
    // be re-run on its own: SCENES=send,settings runs just those two.

    if (_want('welcome')) {
      await _go(tester, AppRoutes.welcome, ms: 2500);
      await _shot(tester, 'welcome', 'welcome');
      await _go(tester, AppRoutes.walletPicker, ms: 1500);
    }

    if (_want('picker')) {
      await _shot(tester, 'picker', 'wallet-picker');
    }

    // Open "Primary" — the mock wallet with Bitcoin and Liquid.
    await _tapText(tester, 'Primary', ms: 2000);

    if (_want('dashboard')) {
      await _shot(tester, 'dashboard', 'dashboard');
      await _scroll(tester, -420);
      await _shot(tester, 'dashboard', 'dashboard-lower');
      await _scroll(tester, 420);
    }

    if (_want('receive')) {
      await _go(tester, AppRoutes.receive, ms: 1600);
      await _shot(tester, 'receive', 'receive');
      await _tapText(tester, 'Liquid', ms: 1600, last: true);
      await _shot(tester, 'receive', 'receive-liquid');
    }

    if (_want('send')) {
      // Six steps: type → asset → inputs → outputs → fee → review. The type
      // step has no Continue button; picking a card advances it.
      await _go(tester, AppRoutes.send, ms: 1600);
      await _shot(tester, 'send', 'send-1-type');
      await _tapText(tester, 'Standard transaction', ms: 1400);
      await _shot(tester, 'send', 'send-2-asset');
      await _tapText(tester, 'Bitcoin', ms: 1200);
      await _tapText(tester, 'Continue', ms: 1600);
      await _shot(tester, 'send', 'send-3-inputs');
      await _tapText(tester, 'Continue', ms: 1600);
      await _shot(tester, 'send', 'send-4-outputs');
      await _type(tester, 'Enter, paste, or scan address',
          'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx');
      await _type(tester, '0.00000000', '0.0025');
      await _shot(tester, 'send', 'send-4-outputs-filled');
      await _tapText(tester, 'Continue', ms: 1800);
      await _shot(tester, 'send', 'send-5-fee');
      await _tapText(tester, 'Continue', ms: 2500);
      await _shot(tester, 'send', 'send-6-review');
    }

    for (final scene in const <List<String>>[
      ['activity', AppRoutes.history, 'activity'],
      ['utxos', AppRoutes.utxos, 'utxos'],
      ['liquid', AppRoutes.liquid, 'liquid'],
      ['liquidex', AppRoutes.swap, 'liquidex'],
      ['peg', AppRoutes.peg, 'peg'],
      ['info', AppRoutes.walletInfo, 'wallet-info'],
    ]) {
      if (!_want(scene[0])) continue;
      await _go(tester, scene[1], ms: 1800);
      await _shot(tester, scene[0], scene[2]);
    }

    if (_want('settings')) {
      await _go(tester, AppRoutes.settings, ms: 1800);
      await _shot(tester, 'settings', 'settings-network');
      for (final section in const ['Security', 'Appearance', 'About']) {
        if (await _tapText(tester, section, ms: 1400)) {
          await _shot(tester, 'settings', 'settings-${section.toLowerCase()}');
        }
      }
    }

    if (_want('wizard')) {
      // Structure first, then (single-sig only) where the keys live, then the
      // coins — with the network stated under them.
      await _go(tester, AppRoutes.walletType, ms: 1500);
      await _shot(tester, 'wizard', 'wizard-1-structure');
      await _tapText(tester, 'One key');
      await _tapText(tester, 'Continue');
      await _shot(tester, 'wizard', 'wizard-2-keys');
      await _tapText(tester, 'On this computer');
      await _tapText(tester, 'Continue');
      await _shot(tester, 'wizard', 'wizard-3-coins');
      await _tapText(tester, 'Bitcoin + Liquid');
      await _tapText(tester, 'Continue');
      await _shot(tester, 'wizard', 'wizard-4-password');
      await _type(tester, 'App password', 'correct horse battery staple');
      await _type(tester, 'Confirm password', 'correct horse battery staple');
      await _shot(tester, 'wizard', 'wizard-4-password-filled');
      for (var i = 5; i <= 8; i++) {
        if (find.text('Continue').hitTestable().evaluate().isEmpty) break;
        await _tapText(tester, 'Continue', ms: 1400);
        await _shot(tester, 'wizard', 'wizard-$i');
      }
    }

    if (_want('create')) {
      await _tapText(tester, 'Start setup', ms: 2200);
      await _shot(tester, 'create', 'create-1-name');
      await _type(tester, 'Wallet name', 'Savings');
      await _tapText(tester, 'Continue', ms: 3000);
      await _shot(tester, 'create', 'create-2-words');
      await _tapText(tester, 'Continue', ms: 1800);
      await _shot(tester, 'create', 'create-3-verify');
    }

    if (_want('light')) {
      await _go(tester, AppRoutes.dashboard, ms: 1500);
      appState.toggleTheme();
      await _shot(tester, 'light', 'dashboard-light', settle: 1200);
      appState.toggleTheme();
      await _wait(tester, 800);
    }

    // The multisig "Import the keys" step, both coordinator roles. Reached by
    // route with the draft pre-answered: the wizard path in front of it costs
    // five taps and a seed verification the tour cannot answer.
    if (_want('multisig')) {
      newWalletDraft.liquidEnabled = false;
      for (final role in const [WalletPath.watchOnly, WalletPath.multisig]) {
        newWalletDraft.path = role;
        // Watch-only reaches the multisig screens by building the wallet from
        // its cosigners' keys instead of one pasted descriptor.
        newWalletDraft.watchOnlyFromCosigners = role == WalletPath.watchOnly;
        final tag = role == WalletPath.multisig ? 'coordinator' : 'watchonly';
        await _go(tester, AppRoutes.walletPicker, ms: 600);
        await _go(tester, AppRoutes.multisigSetup, ms: 1600);
        await _shot(tester, 'multisig', 'multisig-threshold-$tag');
        await _tapText(tester, 'Continue', ms: 1600);
        await _shot(tester, 'multisig', 'multisig-import-$tag');
        if (await _tapText(tester, 'USB device', ms: 900)) {
          await _shot(tester, 'multisig', 'multisig-import-$tag-usb');
        }
        appState.toggleTheme();
        await _shot(tester, 'multisig', 'multisig-import-$tag-light',
            settle: 1200);
        appState.toggleTheme();
        await _wait(tester, 600);
      }
    }

    if (_want('import')) {
      await _go(tester, AppRoutes.importWallet, ms: 1800);
      await _shot(tester, 'import', 'import-wallet');
    }

    debugPrint('TOUR DONE — $_seq shots in $_outDir');
  });
}
