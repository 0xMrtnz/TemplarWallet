// The new-wallet wizard's question order, and the chrome that must not move
// while the user walks it.
//
// Order (2026-09-08, with the owner): structure first — one key, several keys,
// or (set apart) watch-only — and only a single-sig wallet is then asked where
// its keys live. A multisig picks a source per key on its own import step, so
// asking once up front would ask for an answer the flow then ignores N times.
//
// The chrome half of this file guards the complaint that prompted the
// reorder: the back arrow rendered only from step 2 on, so the title block —
// and the arrow with it — jumped sideways every time the user advanced.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/create_wallet/models/new_wallet_draft.dart';
import 'package:templar_wallet/features/create_wallet/wallet_type_screen.dart';
import 'package:templar_wallet/shared/widgets/buttons.dart';

/// Vault already set up (no password step) and no USB probe to answer.
class _QuietBridge implements WalletBridge {
  @override
  Future<VaultStatus> vaultStatus() async =>
      const VaultStatus(initialized: true, unlocked: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _hostWith(WalletBridge b) => MaterialApp(home: WalletTypeScreen(bridge: b));

void _desktopWindow(WidgetTester t) {
  t.view.physicalSize = const Size(1280, 900);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Future<void> _pump(WidgetTester t) async {
  _desktopWindow(t);
  await t.pumpWidget(_hostWith(_QuietBridge()));
  await t.pumpAndSettle();
}

Future<void> _tapCard(WidgetTester t, String title) async {
  // Watch-only sits below the fold on a short window — it is set apart at the
  // bottom of the step, under the divider.
  await t.ensureVisible(find.text(title));
  await t.pumpAndSettle();
  await t.tap(find.text(title));
  await t.pumpAndSettle();
}

Future<void> _continue(WidgetTester t) async {
  await t.tap(find.widgetWithText(PrimaryButton, 'Continue'));
  await t.pumpAndSettle();
}

void main() {
  setUp(() {
    newWalletDraft
      ..path = WalletPath.singleSig
      ..keyKind = WalletKind.software
      ..watchOnlyFromCosigners = false
      ..includeVaultStep = false
      ..hwConnection = null
      ..liquidEnabled = true;
  });

  testWidgets('the first question is the structure, watch-only set apart',
      (t) async {
    await _pump(t);

    expect(find.text('What kind of wallet?'), findsOneWidget);
    expect(find.text('One key'), findsOneWidget);
    expect(find.text('Several keys must agree (multisig)'), findsOneWidget);
    expect(find.text('Somewhere else — just watch it'), findsOneWidget);
    // Neither the network nor where the keys live is on this screen: the
    // network sat below the fold here until the owner moved it (2026-09-08).
    expect(find.text('NETWORK'), findsNothing);
    expect(find.text('On this computer'), findsNothing);
  });

  testWidgets('single-sig is asked where its keys live; multisig is not',
      (t) async {
    await _pump(t);
    await _tapCard(t, 'One key');
    await _continue(t);
    expect(find.text('Where do your keys live?'), findsOneWidget);
    expect(find.text('On a hardware wallet'), findsOneWidget);

    // Back to the start, pick multisig instead: the keys question is gone.
    await t.tap(find.byIcon(Icons.arrow_back));
    await t.pumpAndSettle();
    await _tapCard(t, 'Several keys must agree (multisig)');
    await _continue(t);
    expect(find.text('Where do your keys live?'), findsNothing);
    expect(find.text('Which coins?'), findsOneWidget);
    expect(newWalletDraft.structure, WalletStructure.multisig);
    // The network is stated here, under the coins — not asked as a step.
    expect(find.text('NETWORK'), findsOneWidget);
    expect(find.text('Testnet'), findsOneWidget);
    expect(find.text('Mainnet'), findsOneWidget);
  });

  testWidgets('watch-only skips the keys question too', (t) async {
    await _pump(t);
    await _tapCard(t, 'Somewhere else — just watch it');
    await _continue(t);
    expect(find.text('Where do your keys live?'), findsNothing);
    expect(find.text('Which coins?'), findsOneWidget);
    expect(newWalletDraft.kind, WalletKind.watchOnly);
  });

  testWidgets('the back arrow keeps its place on step 1', (t) async {
    await _pump(t);

    // The slot is rendered on step 1 — inert, but occupying its own width, so
    // the title beside it does not slide when a real Back appears on step 2.
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    final titleX = t.getTopLeft(find.text('What kind of wallet?')).dx;
    final arrowX = t.getTopLeft(find.byIcon(Icons.arrow_back)).dx;

    await _tapCard(t, 'One key');
    await _continue(t);

    expect(t.getTopLeft(find.text('Where do your keys live?')).dx, titleX);
    expect(t.getTopLeft(find.byIcon(Icons.arrow_back)).dx, arrowX);
  });

  testWidgets('the header reserves one height for every question', (t) async {
    await _pump(t);
    final firstCardY = t.getTopLeft(find.text('One key')).dy;

    await _tapCard(t, 'One key');
    await _continue(t);

    // Step 2's subtitle is a different length; the body must not move.
    expect(t.getTopLeft(find.text('On this computer')).dy, firstCardY);
  });

  testWidgets('the bottom Back button is always in the row', (t) async {
    await _pump(t);

    final back = find.widgetWithText(GhostButton, 'Back');
    expect(back, findsOneWidget);
    expect(t.widget<GhostButton>(back).onPressed, isNull);
    final buttonX = t.getTopLeft(back).dx;

    await _tapCard(t, 'One key');
    await _continue(t);

    expect(t.widget<GhostButton>(back).onPressed, isNotNull);
    expect(t.getTopLeft(back).dx, buttonX);
  });

  testWidgets('an answer that drops a question keeps the step in range',
      (t) async {
    await _pump(t);
    await _tapCard(t, 'One key');
    await _continue(t); // step 2 — keys
    await _continue(t); // step 3 — coins
    expect(find.text('Which coins?'), findsOneWidget);

    // Walk back and switch to multisig: the flow is a question shorter, and
    // the wizard must not be left pointing past its end.
    await t.tap(find.byIcon(Icons.arrow_back));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.arrow_back));
    await t.pumpAndSettle();
    await _tapCard(t, 'Several keys must agree (multisig)');
    expect(t.takeException(), isNull);
    expect(newWalletDraft.wizardSteps, 2);
  });
}
