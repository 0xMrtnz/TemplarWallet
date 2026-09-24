// Hover probe — photographs the new-wallet flow with the mouse resting on
// each interactive thing, one PNG per pose, so the desktop hover states can
// be judged by eye. Same harness as screenshots_test.dart; not a test.
//
//   flutter test integration_test/hover_probe_test.dart -d macos \
//     --dart-define=TEMPLAR_MOCK_BRIDGE=true --dart-define=TEMPLAR_SHOTS=true

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/app/router.dart';
import 'package:templar_wallet/app/routes.dart';
import 'package:templar_wallet/features/create_wallet/models/new_wallet_draft.dart';
import 'package:templar_wallet/main.dart';
import 'package:templar_wallet/shared/widgets/list_rows.dart';

final GlobalKey _shotKey = GlobalKey();
late final String _outDir;

Future<void> _wait(WidgetTester tester, [int ms = 700]) async {
  for (var i = 0; i < (ms / 100).ceil(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  await _wait(tester, 500);
  final boundary =
      _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  File('$_outDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  debugPrint('SHOT $_outDir/$name.png');
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final f = find.text(label).hitTestable();
  if (f.evaluate().isEmpty) {
    debugPrint('MISS text "$label"');
    return;
  }
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, 900);
}

/// Hover [finder] (its centre) and shoot.
Future<void> _hoverShot(
    WidgetTester tester, TestGesture mouse, Finder finder, String name) async {
  if (finder.evaluate().isEmpty) {
    debugPrint('MISS hover target for $name');
    return;
  }
  try {
    await tester.ensureVisible(finder.first);
    await _wait(tester, 300);
  } catch (_) {}
  await mouse.moveTo(tester.getCenter(finder.first));
  await _wait(tester, 400);
  await _shot(tester, name);
  await mouse.moveTo(const Offset(5, 5));
  await _wait(tester, 300);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('hover probe', (tester) async {
    final dir = Directory('${Directory.systemTemp.path}/templar-hover');
    dir.createSync(recursive: true);
    _outDir = dir.path;
    debugPrint('HOVER_DIR $_outDir');

    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(2560, 1600);

    final appState = AppState();
    await appState.loadPrefs();
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

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(5, 5));
    addTearDown(mouse.removePointer);

    // ── Wizard: structure + coins ─────────────────────────────────────────
    appRouter.go(AppRoutes.walletType);
    await _wait(tester, 1500);
    await _hoverShot(tester, mouse,
        find.text('Several keys must agree (multisig)'), 'w1-card-hover');
    await _tapText(tester, 'Several keys must agree (multisig)');
    await _tapText(tester, 'Continue');
    await _shot(tester, 'w2-coins');
    await _hoverShot(tester, mouse, find.text('Bitcoin only'), 'w2-card-hover');
    await _hoverShot(tester, mouse, find.text('Mainnet'), 'w2-network-hover');

    // ── Multisig setup ────────────────────────────────────────────────────
    newWalletDraft.path = WalletPath.multisig;
    newWalletDraft.liquidEnabled = false;
    appRouter.go(AppRoutes.walletPicker);
    await _wait(tester, 600);
    appRouter.go(AppRoutes.multisigSetup);
    await _wait(tester, 1600);
    await _hoverShot(tester, mouse, find.byIcon(Icons.add_circle_outline),
        'ms1-plus-hover');
    await _hoverShot(
        tester, mouse, find.byType(ListSwitch), 'ms1-switch-hover');
    await _hoverShot(tester, mouse, find.text('Wallet name'), 'ms1-name-hover');
    await _hoverShot(tester, mouse, find.byIcon(Icons.arrow_back), 'ms1-back-hover');
    await _hoverShot(tester, mouse, find.text('Cancel'), 'ms1-cancel-hover');
    await _tapText(tester, 'Continue');
    await _shot(tester, 'ms2-import');
    await _hoverShot(tester, mouse, find.text('Key 2'), 'ms2-collapsed-hover');
    await _hoverShot(tester, mouse, find.text('USB device'), 'ms2-row-hover');
    await _hoverShot(tester, mouse, find.text('App wallet'), 'ms2-row-disabled-hover');
    await _hoverShot(tester, mouse, find.byIcon(Icons.key), 'ms2-disc-hover');
    await _hoverShot(tester, mouse, find.byIcon(Icons.qr_code_scanner),
        'ms2-scan-hover');
    await _hoverShot(tester, mouse, find.text('Done with this key'),
        'ms2-done-hover');
    await _tapText(tester, 'New key');
    await _shot(tester, 'ms2-newkey');
    await _hoverShot(tester, mouse, find.text('Generate a new 24-word key'),
        'ms2-generate-hover');
    await _tapText(tester, 'Generate a new 24-word key');
    await _shot(tester, 'ms2-generated');
    await _hoverShot(tester, mouse, find.text('I wrote these words down'),
        'ms2-checkbox-hover');
    await _tapText(tester, 'Seed phrase');
    await _shot(tester, 'ms2-seed');
    await _tapText(tester, 'USB device');
    await _shot(tester, 'ms2-usb');
    await _hoverShot(tester, mouse, find.text('Read xpub from device'),
        'ms2-usb-hover');
    debugPrint('PROBE DONE in $_outDir');
  });
}
