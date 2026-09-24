// Phone layouts of the shared UTXO widgets: no fixed-width columns, so they
// must fit the narrowest column they are embedded in (the send wizard's
// FormCard, 337 dp) without a RenderFlex overflow, and stay tappable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/features/utxos/models/utxo.dart';
import 'package:templar_wallet/shared/widgets/utxo_details.dart';
import 'package:templar_wallet/shared/widgets/utxo_views.dart';

const _txid =
    'a1b2c3d4e5f60718293a4b5c6d7e8f9001122334455667788990aabbccddeeff';

// The provider sits ABOVE the MaterialApp: the details sheet is pushed on
// the root navigator, and a provider under `home` would be invisible to it.
Widget host(Widget child, {double width = 337}) {
  return ChangeNotifierProvider<AppState>(
    create: (_) => AppState(),
    child: MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

const _coin = Utxo(
  outpoint: '$_txid:1',
  amount: 1234567890000,
  displayAmount: '12345.67890000 USDT',
  confirmations: 3,
  state: UtxoState.dusty,
  label: 'Exchange withdrawal, kept for the loan collateral',
  ticker: 'USDT',
  assetId: 'asset',
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('midOutpoint keeps head, tail and vout', () {
    expect(_coin.midOutpoint, 'a1b2c3d4e5…ddeeff:1');
    expect(_coin.shortOutpoint, 'a1b2c3d4…:1');
    const short = Utxo(
      outpoint: 'abc:0',
      amount: 1,
      displayAmount: '1 sat',
      confirmations: 0,
      state: UtxoState.available,
    );
    expect(short.midOutpoint, 'abc:0');
  });

  testWidgets('compact CoinRow fits 337 dp and toggles on tap', (t) async {
    var taps = 0;
    await t.pumpWidget(host(CoinRow(
      utxo: _coin,
      share: 0.42,
      compact: true,
      onTap: () => taps++,
    )));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('12345.67890000 USDT'), findsOneWidget);
    expect(find.text(_coin.midOutpoint), findsOneWidget);
    expect(find.text('Dust'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    // The whole card is the checkbox's hit area, and tall enough for a finger.
    expect(t.getSize(find.byType(CoinRow)).height, greaterThanOrEqualTo(56));
    await t.tap(find.byType(CoinRow));
    expect(taps, 1);
  });

  testWidgets('compact CoinRow without share hides the meter', (t) async {
    await t.pumpWidget(host(CoinRow(
      utxo: _coin,
      share: 0.42,
      compact: true,
      showShare: false,
      onTap: () {},
    )));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('42%'), findsNothing);
  });

  testWidgets('compact banknote is full width and fits a long amount',
      (t) async {
    var taps = 0;
    await t.pumpWidget(host(UtxoBanknote(
      utxo: _coin,
      tier: BanknoteTier.whale,
      compact: true,
      onTap: () => taps++,
    )));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(t.getSize(find.byType(UtxoBanknote)).width, 337);
    // The tier and its share are one tag now: "WHALE · 0%".
    expect(find.textContaining('WHALE'), findsOneWidget);
    expect(find.text('12345.67890000 USDT'), findsOneWidget);
    await t.tap(find.byType(UtxoBanknote));
    expect(taps, 1);
  });

  testWidgets('desktop CoinRow keeps the short outpoint at desktop width',
      (t) async {
    await t.pumpWidget(host(
      CoinRow(utxo: _coin, share: 0.42, compact: false, onTap: () {}),
      width: 900,
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text(_coin.shortOutpoint), findsOneWidget);
    expect(find.text(_coin.midOutpoint), findsNothing);
    expect(find.text('42%'), findsOneWidget);
  });

  // ── Tiers ────────────────────────────────────────────────────────────────

  Utxo btc(int sats) => Utxo(
        outpoint: '$_txid:0',
        amount: sats,
        displayAmount: '$sats sats',
        confirmations: 1,
        state: UtxoState.available,
        ticker: 'BTC',
      );

  test('dust and whale are fixed amounts, whatever the share', () {
    expect(utxoTier(btc(546), 1.0), BanknoteTier.dust);
    expect(utxoTier(btc(1), 1.0), BanknoteTier.dust);
    expect(utxoTier(btc(547), 0.0), BanknoteTier.small);
    expect(utxoTier(btc(100000000), 0.0), BanknoteTier.whale);
    expect(utxoTier(btc(250000000), 0.001), BanknoteTier.whale);
  });

  test('the middle tiers follow the share of holdings', () {
    expect(utxoTier(btc(10000), 0.01), BanknoteTier.small);
    expect(utxoTier(btc(10000), 0.049), BanknoteTier.small);
    expect(utxoTier(btc(10000), 0.05), BanknoteTier.big);
    expect(utxoTier(btc(10000), 0.249), BanknoteTier.big);
    expect(utxoTier(btc(10000), 0.25), BanknoteTier.huge);
    expect(utxoTier(btc(99999999), 0.9), BanknoteTier.huge);
  });

  test('a token is never dust or a whale by amount', () {
    // 500 units of a token is not 500 sats; 1e8 units is not one coin.
    expect(utxoTier(_coin, 0.5), BanknoteTier.huge);
    const crumbs = Utxo(
      outpoint: '$_txid:2',
      amount: 500,
      displayAmount: '0.00000500 USDT',
      confirmations: 1,
      state: UtxoState.available,
      ticker: 'USDT',
      assetId: 'asset',
    );
    expect(utxoTier(crumbs, 0.01), BanknoteTier.small);
  });

  test('share text keeps one decimal only where it changes the reading', () {
    expect(utxoShareText(0.42), '42%');
    expect(utxoShareText(0.0999), '10%');
    expect(utxoShareText(0.042), '4.2%');
    expect(utxoShareText(0.001), '0.1%');
    expect(utxoShareText(0.0001), '<0.1%');
    expect(utxoShareText(0), '0%');
  });

  // ── Pending coins ────────────────────────────────────────────────────────

  const pendingCoin = Utxo(
    outpoint: '$_txid:3',
    amount: 150000,
    displayAmount: '0.0015 BTC',
    confirmations: 0,
    state: UtxoState.unconfirmed,
    ticker: 'BTC',
  );

  testWidgets('a pending coin row cannot be selected and says it is incoming',
      (t) async {
    var taps = 0;
    await t.pumpWidget(host(
      CoinListCard(children: [
        CoinRow(utxo: pendingCoin, share: 0.3, compact: true, onTap: () => taps++),
      ]),
    ));
    // A spinner never settles; one frame is enough to lay the row out.
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.textContaining('Incoming'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.tap(find.byType(CoinRow));
    await t.pump();
    expect(taps, 0);
  });

  testWidgets('a pending coin on the wall is the grey provisional note',
      (t) async {
    await t.pumpWidget(host(
      const PendingCoinNote(utxo: pendingCoin, share: 0.3, compact: true),
    ));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.byType(ProvisionalNote), findsOneWidget);
    expect(find.text('Incoming'), findsOneWidget);
    expect(find.text('Waiting for confirmation'), findsOneWidget);
    expect(find.text('0.0015 BTC'), findsOneWidget);
    // No banknote paper for money that has not landed.
    expect(find.byType(UtxoBanknote), findsNothing);
  });

  testWidgets('the consolidating placeholder is the same provisional note',
      (t) async {
    await t.pumpWidget(host(
      const ConsolidatingNote(
        count: 3,
        displayAmount: '0.005 BTC',
        txid: _txid,
        size: Size(double.infinity, 84),
      ),
    ));
    await t.pump();
    expect(find.byType(ProvisionalNote), findsOneWidget);
    expect(find.text('3 coins → 1 · waiting for confirmation'), findsOneWidget);
  });

  // ── Details ──────────────────────────────────────────────────────────────

  testWidgets('the info button opens the details sheet without toggling',
      (t) async {
    var taps = 0;
    await t.pumpWidget(host(
      CoinRow(utxo: _coin, share: 0.42, compact: true, onTap: () => taps++),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.info_outline_rounded));
    await t.pumpAndSettle();
    expect(taps, 0);
    expect(find.byType(UtxoDetailsDialog), findsOneWidget);
    expect(find.text('Coin details'), findsOneWidget);
    // The whole outpoint, the tier and its rule.
    expect(find.text(_coin.outpoint), findsOneWidget);
    expect(find.textContaining('HUGE'), findsWidgets);
    expect(find.textContaining('42% of your USDT'), findsOneWidget);
  });

  testWidgets('a banknote carries its share and an info button', (t) async {
    await t.pumpWidget(host(
      UtxoBanknote(
        utxo: _coin,
        tier: BanknoteTier.big,
        share: 0.12,
        onTap: () {},
      ),
      width: 900,
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.textContaining('BIG'), findsOneWidget);
    expect(find.textContaining('12%'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    expect(find.byType(ShareMeter), findsOneWidget);
  });
}
