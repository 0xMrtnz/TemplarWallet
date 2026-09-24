// The Send wizard's first question, which is not the same question on every
// wallet.
//
// A multisig wallet cannot finish a transaction alone: both of its choices are
// halves of one round trip — create a partial transaction, or cosign one. The
// co-sign mode has one name on every wallet: it takes a Bitcoin PSBT or a
// Liquid PSET alike, and asks which inside.
//
// "Verify a PSBT" was a third choice here and is gone. The guard is that it
// stays gone: it inspected a transaction while withholding every action, which
// is the load-and-inspect half of the co-sign screen with buttons removed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/send/send_screen.dart';

/// No engine: `_loadAssets` catches the miss and drops the spinner, which is
/// all the type step needs. Keeps the native library and the user's wallet
/// directory out of a unit test.
class _NoEngineBridge implements WalletBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(String walletType) => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => AppState()
          ..setActiveWallet('w1', name: 'Test', type: walletType),
        child: SendScreen(bridge: _NoEngineBridge()),
      ),
    );

/// A desktop window: `AppLayout.isPhone` also needs a mobile platform, so a
/// host test can only ever exercise this arm.
Future<void> _pump(WidgetTester t, String walletType) async {
  t.view.physicalSize = const Size(1280, 1400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(walletType));
  await t.pump();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('a multisig wallet is offered exactly two choices', (t) async {
    await _pump(t, 'Multisig 2-of-3');

    expect(find.text('Create a partial transaction'), findsOneWidget);
    expect(find.text('Cosign a transaction'), findsOneWidget);
    expect(find.text('Standard transaction'), findsNothing);
    expect(find.text('Import a PSBT'), findsNothing);
  });

  testWidgets('a singlesig wallet keeps its first choice and shares the second',
      (t) async {
    await _pump(t, 'Standard');

    expect(find.text('Standard transaction'), findsOneWidget);
    expect(find.text('Cosign a transaction'), findsOneWidget);
    expect(find.text('Co-sign a PSBT'), findsNothing);
    expect(find.text('Create a partial transaction'), findsNothing);
  });

  testWidgets('no wallet is offered a verify-only mode', (t) async {
    for (final type in const ['Multisig 2-of-3', 'Standard']) {
      await _pump(t, type);
      expect(find.text('Verify a PSBT'), findsNothing);
      expect(find.textContaining('Nothing is signed'), findsNothing);
    }
  });
}
