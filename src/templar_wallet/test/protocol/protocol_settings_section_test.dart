// Settings › Templar Protocol. The page states what the wallet is ready for,
// what it has given away and what it signed — so the tests are about what it
// says, and about the one promise it must not overstate: forgetting a site
// does not revoke anything.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/settings/protocol_section.dart';
import 'package:templar_wallet/features/protocol/models/protocol_records.dart';
import 'package:templar_wallet/features/wallet_picker/models/wallet_summary.dart';
import 'package:templar_wallet/services/protocol_store.dart';
import 'package:templar_wallet/shared/widgets/buttons.dart';
import 'package:templar_wallet/theme/app_theme.dart';

const _regtestAsset =
    '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225';

class _StubBridge implements WalletBridge {
  _StubBridge({this.regtest = false, this.envLocked = false, this.wallets});

  final bool regtest;
  final bool envLocked;
  final List<WalletSummary>? wallets;

  @override
  Future<LiquidNetworkInfo> getLiquidNetwork() async => LiquidNetworkInfo(
        network: regtest ? 'liquid-regtest' : 'liquid-testnet',
        shortName: regtest ? 'regtest' : 'testnet',
        policyAsset: regtest ? _regtestAsset : '',
        backend: regtest ? 'elements_rpc' : 'electrum',
        backendDescription: regtest
            ? 'elements_rpc http://127.0.0.1:18884'
            : 'electrum ssl://elements-testnet.blockstream.info:50002',
        envLocked: envLocked,
        regtestDefaultPolicyAsset: _regtestAsset,
      );

  @override
  Future<List<WalletSummary>> listWallets() async => wallets ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WalletSummary _wallet(String id, String name, {bool liquid = true}) =>
    WalletSummary(
      id: id,
      name: name,
      type: WalletType.singlesig,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.utc(2026, 9, 17),
      typeLabel: 'Software',
      liquidEnabled: liquid,
      masterFingerprint: 'cafebabe',
    );

Widget _host(WalletBridge bridge) => MaterialApp(
      theme: AppTheme.dark(),
      home: ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: Scaffold(
          body: SingleChildScrollView(child: ProtocolSection(bridge: bridge)),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProtocolStore.instance.resetCacheForTest();
  });

  void desktop(WidgetTester t) {
    t.view.physicalSize = const Size(1400, 3200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
  }

  testWidgets('says what it is ready for, with the regtest asset id',
      (t) async {
    desktop(t);
    await t.pumpWidget(_host(_StubBridge(regtest: true)));
    await t.pumpAndSettle();

    expect(find.text('Ready for Liquid regtest · policy asset 5ac9…b225'),
        findsOneWidget);
    expect(find.byKey(const Key('protocol-change-network')), findsOneWidget);
    expect(find.textContaining('Switches to Liquid testnet'), findsOneWidget);
  });

  testWidgets('testnet names no asset id', (t) async {
    desktop(t);
    await t.pumpWidget(_host(_StubBridge()));
    await t.pumpAndSettle();

    expect(find.text('Ready for Liquid testnet'), findsOneWidget);
    expect(find.textContaining('Switches to Liquid regtest'), findsOneWidget);
  });

  testWidgets('an env-locked network offers no switch', (t) async {
    desktop(t);
    await t.pumpWidget(_host(_StubBridge(envLocked: true)));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('protocol-change-network')), findsNothing);
    expect(find.textContaining('TEMPLAR_LIQUID_NETWORK'), findsOneWidget);
  });

  testWidgets('the paste box is here, and it is the fallback', (t) async {
    desktop(t);
    await t.pumpWidget(_host(_StubBridge()));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('protocol-paste-field')), findsOneWidget);
    expect(find.byKey(const Key('protocol-paste-open')), findsOneWidget);
    expect(find.textContaining('normally opens Templar by itself'),
        findsOneWidget);
  });

  testWidgets('a connected site shows what was shared, and forgetting is honest',
      (t) async {
    desktop(t);
    await ProtocolStore.instance.recordConnect(ProtocolConnectedSite(
      site: 'Templar Protocol demo',
      origin: 'http://127.0.0.1:8087',
      network: 'liquid-regtest',
      walletId: 'w1',
      walletName: 'Alice',
      connectedAt: DateTime.now().toUtc(),
      escrowFingerprint: '73c5da0a',
      receiveAddress: 'el1qqfakeaddress',
    ));
    await t.pumpWidget(_host(_StubBridge(regtest: true)));
    await t.pumpAndSettle();

    expect(find.text('Templar Protocol demo'), findsOneWidget);
    expect(find.text('http://127.0.0.1:8087 · Liquid regtest'), findsOneWidget);
    expect(
        find.textContaining('watch-only descriptor · escrow key 73c5da0a'),
        findsOneWidget);

    await t.tap(find.widgetWithText(GhostButton, 'Forget'));
    await t.pumpAndSettle();
    // The dialog must not promise a revocation the protocol cannot make.
    expect(find.textContaining('keeps the watch-only descriptor'),
        findsOneWidget);
    expect(find.textContaining('Nothing here can revoke it'), findsOneWidget);

    await t.tap(find.widgetWithText(PrimaryButton, 'Forget'));
    await t.pumpAndSettle();
    expect(find.text('No site has been connected from this device.'),
        findsOneWidget);
  });

  testWidgets('history shows the outcome and clears', (t) async {
    desktop(t);
    for (final o in [ProtocolSignOutcome.signed, ProtocolSignOutcome.refused]) {
      await ProtocolStore.instance.recordSign(ProtocolSignRecord(
        site: 'Templar Protocol demo',
        origin: 'http://127.0.0.1:8087',
        walletName: 'Alice',
        at: DateTime.now().toUtc(),
        outcome: o,
        loanRef: o == ProtocolSignOutcome.signed ? 'SQ-1' : 'SQ-2',
        action: 'origination',
      ));
    }
    await t.pumpWidget(_host(_StubBridge()));
    await t.pumpAndSettle();

    expect(find.text('SQ-1 · Loan origination'), findsOneWidget);
    // TagChip uppercases what it is given.
    expect(find.text('SIGNED'), findsOneWidget);
    expect(find.text('REFUSED BY YOU'), findsOneWidget);

    await t.tap(find.byKey(const Key('protocol-clear-history')));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(PrimaryButton, 'Clear'));
    await t.pumpAndSettle();
    expect(find.text('Nothing signed yet.'), findsOneWidget);
  });

  testWidgets('the preferred wallet is a preference, not a bypass', (t) async {
    desktop(t);
    await t.pumpWidget(_host(_StubBridge(wallets: [
      _wallet('w1', 'Alice'),
      _wallet('w2', 'Bob'),
      // No Liquid side: cannot answer a Templar Protocol request, so it is not offered.
      _wallet('w3', 'BTC only', liquid: false),
    ])));
    await t.pumpAndSettle();

    expect(find.text('No preference'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('BTC only'), findsNothing);
    expect(find.textContaining('still asks for your app password'),
        findsOneWidget);

    await t.tap(find.text('Bob'));
    await t.pumpAndSettle();
    expect(await ProtocolStore.instance.preferredWalletId(), 'w2');

    await t.tap(find.text('No preference'));
    await t.pumpAndSettle();
    expect(await ProtocolStore.instance.preferredWalletId(), isNull);
  });

  testWidgets('how it works names the escrow path and links the guide',
      (t) async {
    desktop(t);
    await t.pumpWidget(_host(_StubBridge()));
    await t.pumpAndSettle();

    expect(find.textContaining("m/2121'/1'/0'"), findsOneWidget);
    expect(find.textContaining('never broadcasts'), findsOneWidget);
    expect(find.text('docs/guides/PROTOCOL_CONNECTOR.md'), findsOneWidget);
  });
}
