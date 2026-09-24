// The card a site's network mismatch lands on. Its whole point is that the
// user never leaves with nothing to do, so each state is checked for the one
// action it can honestly offer.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/protocol/models/protocol_link.dart';
import 'package:templar_wallet/features/protocol/protocol_network_mismatch_card.dart';
import 'package:templar_wallet/theme/app_theme.dart';

const _stockAsset =
    '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225';
const _otherAsset =
    'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

LiquidNetworkInfo _info({bool envLocked = false}) => LiquidNetworkInfo(
      network: 'liquid-testnet',
      shortName: 'testnet',
      policyAsset: '',
      backend: 'electrum',
      backendDescription: 'electrum ssl://host:50002',
      envLocked: envLocked,
      regtestDefaultPolicyAsset: _stockAsset,
    );

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  final switchButton = find.byKey(const Key('protocol-mismatch-switch'));
  final settingsButton = find.byKey(const Key('protocol-mismatch-settings'));
  final assetField = find.byKey(const Key('protocol-mismatch-policy'));

  Future<void> pump(
    WidgetTester tester,
    ProtocolNetworkMismatch mismatch, {
    LiquidNetworkInfo? info,
    void Function(String?)? onSwitch,
    VoidCallback? onOpenSettings,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 700,
            child: ProtocolNetworkMismatchCard(
              mismatch: mismatch,
              info: info ?? _info(),
              onSwitch: onSwitch ?? (_) {},
              onOpenSettings: onOpenSettings ?? () {},
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('a switchable mismatch leads with the switch and the site\'s asset id',
      (tester) async {
    String? used;
    var settings = 0;
    await pump(
      tester,
      const ProtocolNetworkMismatch(
        kind: ProtocolMismatchKind.network,
        siteNetwork: 'liquid-regtest',
        walletNetwork: 'liquid-testnet',
        sitePolicyAsset: _otherAsset,
      ),
      onSwitch: (a) => used = a,
      onOpenSettings: () => settings++,
    );

    // Both sides named, in the user's words.
    expect(
        find.text('This site runs on Liquid regtest. This wallet is on '
            'Liquid testnet.'),
        findsOneWidget);
    expect(find.text('Switch this wallet to Liquid regtest'), findsOneWidget);
    expect(settingsButton, findsOneWidget);

    // The asset id the site sent is prefilled, and is what the switch uses.
    expect(
        tester.widget<TextField>(assetField).controller!.text, _otherAsset);
    await tester.tap(switchButton);
    await tester.pump();
    expect(used, _otherAsset);

    await tester.tap(settingsButton);
    await tester.pump();
    expect(settings, 1);
  });

  testWidgets('with no asset id from the site the stock regtest one is offered',
      (tester) async {
    String? used;
    await pump(
      tester,
      const ProtocolNetworkMismatch(
        kind: ProtocolMismatchKind.network,
        siteNetwork: 'liquid-regtest',
        walletNetwork: 'liquid-testnet',
      ),
      onSwitch: (a) => used = a,
    );
    expect(tester.widget<TextField>(assetField).controller!.text, _stockAsset);
    await tester.tap(switchButton);
    await tester.pump();
    expect(used, _stockAsset);
  });

  testWidgets('switching to testnet asks for no asset id', (tester) async {
    var calls = 0;
    String? used = 'untouched';
    await pump(
      tester,
      const ProtocolNetworkMismatch(
        kind: ProtocolMismatchKind.network,
        siteNetwork: 'liquid-testnet',
        walletNetwork: 'liquid-regtest',
      ),
      onSwitch: (a) {
        calls++;
        used = a;
      },
    );
    expect(assetField, findsNothing);
    expect(find.text('Switch this wallet to Liquid testnet'), findsOneWidget);
    await tester.tap(switchButton);
    await tester.pump();
    expect(calls, 1);
    expect(used, isNull);
  });

  testWidgets('a chain mismatch says so and still switches', (tester) async {
    String? used;
    await pump(
      tester,
      const ProtocolNetworkMismatch(
        kind: ProtocolMismatchKind.chain,
        siteNetwork: 'liquid-regtest',
        walletNetwork: 'liquid-regtest',
        sitePolicyAsset: _otherAsset,
        walletPolicyAsset: _stockAsset,
      ),
      onSwitch: (a) => used = a,
    );
    expect(find.textContaining('a1b2…8f90'), findsOneWidget);
    expect(find.textContaining('5ac9…b225'), findsOneWidget);
    expect(find.text("Switch this wallet to the site's chain"), findsOneWidget);
    await tester.tap(switchButton);
    await tester.pump();
    expect(used, _otherAsset);
  });

  testWidgets('an env-locked network explains itself and offers no switch',
      (tester) async {
    var settings = 0;
    await pump(
      tester,
      const ProtocolNetworkMismatch(
        kind: ProtocolMismatchKind.network,
        siteNetwork: 'liquid-regtest',
        walletNetwork: 'liquid-testnet',
        sitePolicyAsset: _otherAsset,
      ),
      info: _info(envLocked: true),
      onOpenSettings: () => settings++,
    );
    expect(switchButton, findsNothing);
    expect(assetField, findsNothing);
    expect(find.textContaining('TEMPLAR_LIQUID_NETWORK'), findsOneWidget);

    // The only way on is still there.
    expect(settingsButton, findsOneWidget);
    await tester.tap(settingsButton);
    await tester.pump();
    expect(settings, 1);
  });

  testWidgets('a network Templar does not run offers only Settings',
      (tester) async {
    await pump(
      tester,
      const ProtocolNetworkMismatch(
        kind: ProtocolMismatchKind.unsupported,
        siteNetwork: 'mock',
        walletNetwork: 'liquid-testnet',
      ),
    );
    expect(switchButton, findsNothing);
    expect(assetField, findsNothing);
    expect(find.textContaining('"mock"'), findsOneWidget);
    expect(find.textContaining('does not run'), findsWidgets);
    expect(settingsButton, findsOneWidget);
  });

  testWidgets('while switching, nothing can be tapped twice', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 700,
            child: ProtocolNetworkMismatchCard(
              mismatch: const ProtocolNetworkMismatch(
                kind: ProtocolMismatchKind.network,
                siteNetwork: 'liquid-regtest',
                walletNetwork: 'liquid-testnet',
              ),
              info: _info(),
              busy: true,
              onSwitch: (_) => calls++,
              onOpenSettings: () => calls++,
            ),
          ),
        ),
      ),
    ));
    await tester.tap(switchButton);
    await tester.tap(settingsButton);
    await tester.pump();
    expect(calls, 0);
  });
}
