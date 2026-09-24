// Freezing coins: the coin screen's selection bar and details sheet ask the
// engine to freeze, and the send wizard's picker shows a frozen coin without
// letting it be picked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/utxos/models/utxo.dart';
import 'package:templar_wallet/features/utxos/utxo_screen.dart';
import 'package:templar_wallet/services/utxo_label_store.dart';
import 'package:templar_wallet/shared/widgets/utxo_details.dart';
import 'package:templar_wallet/shared/widgets/utxo_views.dart';

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:0';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:1';

Utxo _coin(String outpoint, int sats, {UtxoState state = UtxoState.available}) =>
    Utxo(
      outpoint: outpoint,
      amount: sats,
      displayAmount: '$sats sats',
      confirmations: 6,
      state: state,
      ticker: 'BTC',
    );

/// Keeps the frozen set the way the engine does and answers list_utxos
/// from it.
class _FreezeBridge implements WalletBridge {
  final Set<String> frozen = {};
  final List<(List<String>, bool)> calls = [];

  @override
  Future<List<Utxo>> listUtxos(String walletId, String chain) async => [
        for (final u in [_coin(_a, 90000), _coin(_b, 40000)])
          frozen.contains(u.outpoint) ? u.copyWith(state: UtxoState.frozen) : u,
      ];

  @override
  Future<void> setUtxosFrozen({
    required String walletId,
    required String chain,
    required List<String> outpoints,
    required bool frozen,
  }) async {
    calls.add((outpoints, frozen));
    frozen ? this.frozen.addAll(outpoints) : this.frozen.removeAll(outpoints);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _screen(WalletBridge bridge) => ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..setActiveWallet('w1', name: 'W', type: 'Software'),
      child: MaterialApp(home: UtxoScreen(bridge: bridge)),
    );

/// Pumps the screen once its label store is warm: the store reads a real
/// file, which only completes outside the test's fake clock — so it is read
/// here, before any widget (and any font load) exists.
Future<void> _open(WidgetTester t, WalletBridge bridge) async {
  await t.runAsync(() => UtxoLabelStore.instance.getAllLabels());
  await t.pumpWidget(_screen(bridge));
  await t.pumpAndSettle();
}

void _desktopWindow(WidgetTester t) {
  t.view.physicalSize = const Size(1400, 1000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  // The screen reads its view mode and the pending-consolidation list from
  // SharedPreferences, which has no platform side in a widget test.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the selection bar freezes the selected coin, then unfreezes it',
      (t) async {
    _desktopWindow(t);
    final bridge = _FreezeBridge();
    await _open(t, bridge);

    // List view: rows are easier to target than banknotes.
    await t.tap(find.text('List'));
    await t.pumpAndSettle();
    await t.tap(find.text('90000 sats'));
    await t.pumpAndSettle();
    expect(find.text('Freeze'), findsOneWidget);

    await t.tap(find.text('Freeze'));
    await t.pumpAndSettle();
    expect(bridge.calls.single.$1, [_a]);
    expect(bridge.calls.single.$2, isTrue);
    // Reloaded from the engine: the row wears the chip, the stat counts it,
    // and the selection is gone.
    expect(find.text('Frozen'), findsOneWidget);
    expect(find.text('UTXOs · 1 frozen'), findsOneWidget);
    expect(find.text('Freeze'), findsNothing);
    // Let the confirmation snackbar go: it floats over the bar.
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();

    await t.tap(find.text('90000 sats'));
    await t.pumpAndSettle();
    expect(find.text('Unfreeze'), findsOneWidget);
    await t.tap(find.text('Unfreeze'));
    await t.pumpAndSettle();
    expect(bridge.calls.last.$1, [_a]);
    expect(bridge.calls.last.$2, isFalse);
    expect(find.text('Frozen'), findsNothing);
  });

  testWidgets('the details sheet freezes the one coin it shows', (t) async {
    _desktopWindow(t);
    final bridge = _FreezeBridge();
    await _open(t, bridge);
    await t.tap(find.text('List'));
    await t.pumpAndSettle();

    await t.tap(find.byIcon(Icons.info_outline_rounded).last);
    await t.pumpAndSettle();
    expect(find.byType(UtxoDetailsDialog), findsOneWidget);
    await t.tap(find.text('Freeze'));
    await t.pumpAndSettle();
    expect(find.byType(UtxoDetailsDialog), findsNothing);
    expect(bridge.calls.single.$2, isTrue);
    expect(bridge.calls.single.$1, hasLength(1));
  });

  testWidgets('the send picker shows a frozen coin but will not pick it',
      (t) async {
    final picked = <int>[];
    await t.pumpWidget(ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: MaterialApp(
        home: Scaffold(
          body: UtxoPicker(
            utxos: [_coin(_a, 90000, state: UtxoState.frozen), _coin(_b, 40000)],
            onToggle: picked.add,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('2 coins · 1 frozen'), findsOneWidget);
    expect(find.text('Frozen'), findsOneWidget);
    expect(find.byIcon(kFrozenIcon), findsWidgets);

    await t.tap(find.text('90000 sats'));
    await t.tap(find.text('40000 sats'));
    await t.pump();
    expect(picked, [1], reason: 'only the unfrozen coin is pickable');
  });
}
