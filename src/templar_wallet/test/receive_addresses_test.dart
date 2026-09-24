// Receive lists the newest eight previous addresses and hands the rest to
// the All addresses page; Liquid, with its one reused address, lists none.
// Desktop arm only: AppLayout.isPhone needs a mobile platform, which a host
// test cannot be (see docs/ANDROID_PORT.md).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/receive/models/address_info.dart';
import 'package:templar_wallet/features/receive/receive_addresses_screen.dart';
import 'package:templar_wallet/features/receive/receive_screen.dart';

class _StubBridge implements WalletBridge {
  _StubBridge({this.previousCount = 12});
  final int previousCount;

  @override
  Future<AddressInfo> generateReceiveAddress(String walletId, String asset,
          {bool fresh = false}) async =>
      AddressInfo(
        address: asset == 'BTC'
            ? 'tb1qcurrent000000000000000000000000000000ab'
            : 'tlq1qqcurrentliquidaddress00000000000000000000000000000000000000000000000000000000000000ab',
        index: previousCount,
        asset: asset,
        derivationPath: "m/84'/1'/0'/0/$previousCount",
      );

  @override
  Future<List<AddressInfo>> listPreviousAddresses(
          String walletId, String asset) async =>
      [
        for (var i = 0; i < previousCount; i++)
          AddressInfo(
            address: 'tb1qprev${i.toString().padLeft(2, '0')}'
                '0000000000000000000000000000000ab',
            index: i,
            asset: asset,
            receivedSats: i.isEven ? 1000 * (i + 1) : 0,
            label: i == 3 ? 'Faucet' : null,
          ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(Widget child) => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: child,
      ),
    );

void _desktopWindow(WidgetTester t) {
  t.view.physicalSize = const Size(1400, 1600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('Receive shows the newest eight and offers the rest', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host(ReceiveScreen(bridge: _StubBridge())));
    await t.pumpAndSettle();

    expect(find.text('Previous addresses'), findsOneWidget);
    // Newest first: #11 down to #4 are rows, #3 and below are not.
    expect(find.text('#11'), findsOneWidget);
    expect(find.text('#4'), findsOneWidget);
    expect(find.text('#3'), findsNothing);
    expect(find.text('#0'), findsNothing);
    expect(find.text('Show all (4 more)'), findsOneWidget);
  });

  testWidgets('a short list has no hidden count', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(
        _host(ReceiveScreen(bridge: _StubBridge(previousCount: 3))));
    await t.pumpAndSettle();

    expect(find.text('#2'), findsOneWidget);
    expect(find.text('#0'), findsOneWidget);
    expect(find.text('Show all'), findsOneWidget);
    expect(find.textContaining('more)'), findsNothing);
  });

  testWidgets('the All addresses page lists every one with amounts',
      (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host(
        ReceiveAddressesScreen(asset: 'BTC', bridge: _StubBridge())));
    await t.pumpAndSettle();

    expect(find.text('All addresses'), findsOneWidget);
    expect(find.text('13 addresses'), findsOneWidget);
    // The current unused address leads, marked as such.
    expect(find.text('#12 · current'), findsOneWidget);
    // Every previous one, oldest included, with its label where it has one.
    expect(find.text('#0'), findsOneWidget);
    expect(find.text('#3 · Faucet'), findsOneWidget);
    // Amounts, in the unit the app is set to (coins by default): #0
    // received 1,000 sats, #2 3,000 — each figure drawn once.
    expect(find.text('0.00001000'), findsOneWidget);
    expect(find.text('0.00003000'), findsOneWidget);
    expect(find.text('Back to Receive'), findsOneWidget);
  });
}
