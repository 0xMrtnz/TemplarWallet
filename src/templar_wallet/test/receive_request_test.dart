// The Receive screen's payment request: the disclosure that turns an address
// into an invoice. What the QR carries, what Copy is called, and the ⇅ that
// lets the figure be typed in fiat.
//
// Runs on the host, so this is the desktop arm — the phone draws the same
// `_requestSection`, with the labels above the fields that a phone adds.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/receive/models/address_info.dart';
import 'package:templar_wallet/features/receive/receive_screen.dart';
import 'package:templar_wallet/services/price_service.dart';

/// Answers the two calls this screen makes and nothing else: on the host the
/// real engine loads but has no wallets, and a screen stuck on its error view
/// tests nothing.
class _StubBridge implements WalletBridge {
  @override
  Future<AddressInfo> generateReceiveAddress(String walletId, String asset,
          {bool fresh = false}) async =>
      const AddressInfo(
        address: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
        index: 0,
        asset: 'BTC',
        derivationPath: "m/84'/1'/0'/0/0",
      );

  @override
  Future<List<AddressInfo>> listPreviousAddresses(
          String walletId, String asset) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget host() => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: ReceiveScreen(bridge: _StubBridge()),
      ),
    );

/// A desktop window, not the 800×600 the test binding defaults to: the
/// Receive header and its chain switch are laid out for a real one.
void _desktopWindow(WidgetTester t) {
  t.view.physicalSize = const Size(1400, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

/// The string actually encoded in the QR — the only place that says what a
/// payer's camera will read. `QrImageView.data` is private, so the tile keys
/// the code by its payload and the key is what the test reads.
String qrData(WidgetTester t) =>
    (t.widget<QrImageView>(find.byType(QrImageView)).key as ValueKey<String>)
        .value;

Future<void> openRequest(WidgetTester t) async {
  await t.tap(find.text('Request an amount'));
  await t.pumpAndSettle();
}

/// The amount field is the numeric one; the note field follows it.
Finder amountField() => find.byType(TextField).first;
Finder noteField() => find.byType(TextField).last;

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  setUp(() => PriceService.instance.debugSetPrice(0));

  testWidgets('with nothing asked for the QR is the bare address', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();

    expect(qrData(t), startsWith('tb1q'));
    expect(find.text('Copy address'), findsOneWidget);
    expect(find.text('Copy payment link'), findsNothing);
    // Closed by default: handing over an address must stay one glance.
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text('Optional — adds it to the QR and the link'),
      findsOneWidget,
    );
  });

  testWidgets('the unit chip is wrapped so the suffix cannot stretch',
      (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    expect(find.text('0.00000000'), findsOneWidget);
    // Structural, because the failure it guards is phone-only and the host
    // cannot draw the phone theme: given the suffix slot's full width the
    // chip's 48 dp touch box stretches across the field and pushes the hint
    // out. The min-size Row is the fix, and unwrapping it brings the bug
    // straight back.
    final suffix = t.widget<TextField>(amountField()).decoration!.suffixIcon;
    expect(
      suffix,
      isA<Row>()
          .having((r) => r.mainAxisSize, 'mainAxisSize', MainAxisSize.min),
    );
  });

  testWidgets('an amount turns the QR into a BIP21 link', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    await t.enterText(amountField(), '0.001');
    await t.pumpAndSettle();

    expect(qrData(t), contains('bitcoin:'));
    expect(qrData(t), endsWith('?amount=0.001'));
    expect(find.text('Copy payment link'), findsOneWidget);
    // The well still shows the address itself: the link's query is machine
    // business, the address is what a human checks.
    expect(find.textContaining('tb1q'), findsWidgets);
  });

  testWidgets('a note rides along, percent-encoded', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    await t.enterText(amountField(), '0.001');
    await t.enterText(noteField(), 'Invoice 12');
    await t.pumpAndSettle();

    expect(qrData(t), endsWith('?amount=0.001&label=Invoice%2012'));
  });

  testWidgets('a note is cut at the cap so the QR keeps its frame', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);
    final tooLong = List.filled(3, 'A very long note for the payer ').join();
    expect(tooLong.length, greaterThan(kRequestNoteMaxLength));
    await t.enterText(noteField(), tooLong);
    await t.pumpAndSettle();
    final typed = t.widget<TextField>(noteField()).controller!.text;
    expect(typed.length, kRequestNoteMaxLength);
    expect(qrData(t), contains('label='));
    expect(qrData(t).length, lessThan(200));
  });

  testWidgets('a note alone is enough to make a link', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    await t.enterText(noteField(), 'Rent');
    await t.pumpAndSettle();

    expect(qrData(t), endsWith('?label=Rent'));
  });

  testWidgets('a half-typed amount asks for nothing', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    await t.enterText(amountField(), '0.');
    await t.pumpAndSettle();

    expect(qrData(t), isNot(contains('amount=')));
    expect(find.text('Copy address'), findsOneWidget);
  });

  testWidgets('closing the request keeps it, and names it', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);
    await t.enterText(amountField(), '0.001');
    await t.pumpAndSettle();

    await t.tap(find.text('Request an amount'));
    await t.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(qrData(t), endsWith('?amount=0.001'));
    // Nothing hides inside the QR: the closed row states the figure.
    expect(find.textContaining('0.001 BTC'), findsOneWidget);
  });

  testWidgets('the ⇅ chip is inert without a price', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    expect(find.text('BTC'), findsOneWidget);
    await t.tap(find.text('BTC'));
    await t.pumpAndSettle();
    // Still coin: a fiat figure cannot be resolved without a price.
    expect(find.text('BTC'), findsOneWidget);
  });

  testWidgets('the ⇅ chip flips the field to fiat and converts', (t) async {
    PriceService.instance.debugSetPrice(50000, currency: 'EUR');
    _desktopWindow(t);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    await openRequest(t);

    await t.enterText(amountField(), '0.002');
    await t.pumpAndSettle();
    expect(find.text('≈ €100.00'), findsOneWidget);

    await t.tap(find.text('BTC'));
    await t.pumpAndSettle();

    // The field now holds euros; the link still carries the coin figure,
    // which is the only amount BIP21 defines.
    expect(find.text('EUR'), findsOneWidget);
    expect(t.widget<TextField>(amountField()).controller!.text, '100.00');
    expect(find.text('≈ 0.00200000 BTC'), findsOneWidget);
    expect(qrData(t), endsWith('?amount=0.002'));
  });
}
