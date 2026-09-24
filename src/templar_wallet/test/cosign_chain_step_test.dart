// The co-sign flow asks which chain first, then for that chain's artifact.
//
// It used to guess the chain from the pasted blob and take a PSBT or a PSET
// in one box. The owner asked for the question (2026-09-09): choose Bitcoin
// or Liquid, then load a PSBT or a PSET — and a blob from the other chain is
// refused with the reason, not handed to the wrong decoder.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/psbt/cosign_view.dart';
import 'package:templar_wallet/shared/widgets/step_header.dart';
import 'package:templar_wallet/shared/widgets/ur_qr.dart';

/// No engine at all: nothing in these tests may reach it. A call that does
/// throws, which is the assertion.
class _NoEngineBridge implements WalletBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host({required bool liquid}) => MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider<AppState>(
          create: (_) => AppState()
            ..setActiveWallet('w1',
                name: 'Shared', type: 'Multisig 2-of-2', liquid: liquid),
          child: SingleChildScrollView(
            child: CosignView(bridge: _NoEngineBridge()),
          ),
        ),
      ),
    );

Future<void> _pump(WidgetTester t, {bool liquid = true}) async {
  t.view.physicalSize = const Size(1280, 1400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(liquid: liquid));
  await t.pumpAndSettle();
}

/// A serialized PSET's first bytes (`pset\xff`), base64 — what a Liquid
/// co-signer pastes, as far as the magic-byte check is concerned.
final _psetLike = base64Encode([0x70, 0x73, 0x65, 0x74, 0xff, 0, 0, 0]);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  // A host with a camera (macOS, Android), whatever this suite runs on.
  setUp(() => debugCameraScanSupportedOverride = true);
  tearDown(() => debugCameraScanSupportedOverride = null);

  testWidgets('the chain is asked before the transaction', (t) async {
    await _pump(t);

    expect(find.text('WHICH CHAIN?'), findsOneWidget);
    expect(find.text('Bitcoin'), findsOneWidget);
    expect(find.text('Liquid'), findsOneWidget);
    expect(find.text('Paste'), findsNothing);

    await t.tap(find.text('Liquid'));
    await t.pumpAndSettle();
    expect(find.text('WHICH CHAIN?'), findsNothing);
    expect(find.text('Paste'), findsOneWidget);
    // Named for the chain's artifact, not "PSBT / PSET".
    expect(find.text('base64 PSET text'), findsOneWidget);
    expect(find.text('.pset'), findsOneWidget);
    // A PSET scans too — Templar's own ur:bytes animation — so the camera
    // tile is there on this path as well.
    expect(find.text('Scan QR'), findsOneWidget);

    // Back to the question, answer kept for nothing — Bitcoin this time.
    await t.tap(find.textContaining('change chain'));
    await t.pumpAndSettle();
    await t.tap(find.text('Bitcoin'));
    await t.pumpAndSettle();
    expect(find.text('base64 PSBT text'), findsOneWidget);
    expect(find.text('.psbt'), findsOneWidget);
  });

  testWidgets('a wallet without a Liquid side cannot pick Liquid', (t) async {
    await _pump(t, liquid: false);

    final liquidCard = t.widget<SelectableOptionCard>(
      find.widgetWithText(SelectableOptionCard, 'Liquid'),
    );
    expect(liquidCard.onTap, isNull);
    expect(find.textContaining('no Liquid side'), findsOneWidget);

    await t.tap(find.text('Liquid'));
    await t.pumpAndSettle();
    expect(find.text('WHICH CHAIN?'), findsOneWidget, reason: 'still asking');
  });

  testWidgets('a PSET on the Bitcoin path is refused with the reason',
      (t) async {
    await _pump(t);
    await t.tap(find.text('Bitcoin'));
    await t.pumpAndSettle();
    await t.tap(find.text('Paste'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), _psetLike);
    await t.tap(find.text('Load & Inspect'));
    await t.pumpAndSettle();

    // Refused before the engine is asked — the bridge would have thrown.
    expect(find.textContaining('This is a Liquid PSET'), findsOneWidget);
    expect(find.text('Paste'), findsOneWidget, reason: 'still on the load card');
  });

  testWidgets('a PSBT on the Liquid path is refused with the reason',
      (t) async {
    await _pump(t);
    await t.tap(find.text('Liquid'));
    await t.pumpAndSettle();
    await t.tap(find.text('Paste'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField),
        base64Encode([0x70, 0x73, 0x62, 0x74, 0xff, 0, 0, 0]));
    await t.tap(find.text('Load & Inspect'));
    await t.pumpAndSettle();

    expect(find.textContaining('not a Liquid PSET'), findsOneWidget);
  });
}
