// The co-signature hand-off sheet: what a multisig transaction sits on while
// it is out with its co-signers.
//
// The behaviour under test is the round trip. The sheet hands out one copy and
// takes copies back, and every copy that lands in it is read: the quorum chart
// has to move, the co-signer's row has to flip to Signed, the copy going out
// has to GROW by the signatures that came back — and a copy that brings
// nothing (the original pasted back) has to be refused with the reason rather
// than adopted as if it were progress.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/psbt/cosign_handoff.dart';
import 'package:templar_wallet/features/psbt/models/psbt_inspection.dart';
import 'package:templar_wallet/features/psbt/models/pset_inspection.dart';
import 'package:templar_wallet/features/wallet_info/models/wallet_info.dart';
import 'package:templar_wallet/services/cosigner_label_store.dart';
import 'package:templar_wallet/shared/models/cosigner_label.dart';
import 'package:templar_wallet/shared/widgets/code_box.dart';
import 'package:templar_wallet/shared/widgets/signer_donut.dart';
import 'package:templar_wallet/shared/widgets/ur_qr.dart';

const _fps = ['aa000001', 'bb000002', 'cc000003'];

/// A 2-of-3 whose signatures are read off the blob itself: `~sigA`, `~sigB`,
/// `~sigC` mark which co-signer has signed. That is what lets a test paste
/// "the copy B signed" and assert the chart followed it, and that a merged
/// copy carries both A's and B's marks.
class _QuorumBridge implements WalletBridge {
  int inspections = 0;
  int combines = 0;

  static List<bool> _signedIn(String blob) =>
      [for (final k in ['A', 'B', 'C']) blob.contains('~sig$k')];

  @override
  Future<PsbtInspection> inspectPsbt(String psbtBase64) async {
    inspections++;
    final signed = _signedIn(psbtBase64);
    return PsbtInspection(
      inputs: const [
        PsbtInput(
          outpoint: 'aa11:0',
          amountSats: 1234567,
          displayAmount: '0.01234567 BTC',
        ),
      ],
      outputs: const [
        PsbtOutput(
          address: 'tb1qrecipient',
          amountSats: 100000,
          displayAmount: '100000 sats',
        ),
      ],
      feeSats: 1560,
      feeDisplay: '1560 sats',
      sigsPresent: signed.where((s) => s).length,
      sigsRequired: 2,
      signers: [
        for (var i = 0; i < _fps.length; i++)
          PsbtSigner(fingerprint: _fps[i], hasSigned: signed[i]),
      ],
      policyHint: '2-of-3 multisig',
      rawPsbt: psbtBase64,
    );
  }

  /// Merges by keeping every `~sigX` mark of every copy, on the first copy's
  /// body — the shape of a real PSBT combine.
  @override
  Future<String> combinePsbts(List<String> psbtsBase64) async {
    combines++;
    final base = psbtsBase64.first.split('~sig').first;
    final marks = <String>{};
    for (final p in psbtsBase64) {
      for (final k in ['A', 'B', 'C']) {
        if (p.contains('~sig$k')) marks.add(k);
      }
    }
    return base + [for (final k in ['A', 'B', 'C']) if (marks.contains(k)) '~sig$k'].join();
  }

  @override
  Future<PsetInspection> inspectPset(String walletId, String psetBase64) async {
    inspections++;
    final signed = _signedIn(psetBase64);
    final present = [for (var i = 0; i < 3; i++) if (signed[i]) _fps[i]];
    final missing = [for (var i = 0; i < 3; i++) if (!signed[i]) _fps[i]];
    return PsetInspection(
      feeSats: 250,
      feeDisplay: '250 sats',
      recipients: const [],
      sigsHave: present.length,
      sigsNeeded: 2,
      signersPresent: present,
      signersMissing: missing,
      canFinalize: present.length >= 2,
      rawPset: psetBase64,
    );
  }

  @override
  Future<String> combinePsets(String walletId, List<String> psetsBase64) =>
      combinePsbts(psetsBase64);

  @override
  Future<List<String>> urPsbtEncode(String psbtBase64,
          {int maxFragmentLen = 100}) async =>
      const ['ur:crypto-psbt/part-1'];

  @override
  Future<List<String>> urPsetEncode(String psetBase64,
          {int maxFragmentLen = 100}) async =>
      const ['ur:bytes/part-1'];

  /// The wallet behind the sheet: three keys, the first one local.
  @override
  Future<WalletInfo> getWalletInfo(String walletId) async => WalletInfo(
        id: walletId,
        name: 'Treasury',
        network: 'testnet',
        masterFingerprint: _fps[0],
        derivationPath: "m/48'/1'/0'/2'",
        scriptType: 'wsh',
        xpub: '',
        receiveDescriptor: '',
        changeDescriptor: '',
        cosignerKeys: [for (final fp in _fps) "[$fp/48'/1'/0'/2']tpubFAKE$fp"],
        requiredSigs: 2,
        localFingerprints: [_fps[0]],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A rejects everything it is asked to read except the copy going out — the
/// returning copy that is a truncated paste, or the wrong file entirely.
class _RejectingBridge extends _QuorumBridge {
  @override
  Future<PsbtInspection> inspectPsbt(String psbtBase64) async {
    if (psbtBase64 == _psbt) return super.inspectPsbt(psbtBase64);
    throw Exception('wallet-ffi: that is not a PSBT');
  }
}

const _psbt = 'cHNidP8BAH0partial~sigA';

/// The sheet is an [AppDialog]; it is laid out against the window rather than
/// inside a scroll view, which would leave its height unbounded and send the
/// dialog looking for intrinsics its QR cannot give.
///
/// Animations are off: the donut's sweep would otherwise never settle, and
/// under reduced motion it lands on the count it is being asserted for.
Widget _host(Widget sheet) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: ChangeNotifierProvider<AppState>(
          create: (_) => AppState()
            ..setActiveWallet('w1', name: 'Treasury', type: 'Multisig 2-of-3'),
          child: Scaffold(body: Center(child: sheet)),
        ),
      ),
    );

Future<void> _pump(WidgetTester t, Widget sheet) async {
  t.view.physicalSize = const Size(1280, 2600);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(sheet));
  await t.pumpAndSettle();
}

/// The blob the sheet is currently handing out, read off its code box.
String _artifactOnScreen(WidgetTester t) =>
    t.widget<CodeBox>(find.byType(CodeBox)).value;

/// Open the paste box, type a copy in, and press the button that reads it.
Future<void> _paste(WidgetTester t, String copy) async {
  await t.tap(find.text('Paste signed copy'));
  await t.pumpAndSettle();
  await t.enterText(find.byType(TextField), copy);
  await t.tap(find.text('Add signature'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CosignerLabelStore.instance.clearCache();
    // A host with a camera (macOS, Android), whatever this suite runs on.
    debugCameraScanSupportedOverride = true;
  });
  tearDown(() => debugCameraScanSupportedOverride = null);

  group('PSBT hand-off', () {
    Widget sheet(_QuorumBridge bridge) => PsbtHandoffSheet(
          unsignedPsbt: _psbt,
          bridge: bridge,
          title: 'Co-signatures needed',
          quorumHave: 1,
          quorumNeeded: 2,
          onBroadcast: (_) {},
        );

    testWidgets('charts the quorum the exported copy carries, by signer',
        (t) async {
      await _pump(t, sheet(_QuorumBridge()));

      expect(find.byType(SignerDonut), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('1 MORE SIGNATURE NEEDED'), findsOneWidget);
      // Every signer is a row: the local key marked as this device, the
      // others by their position until they are named — the same "Key N"
      // the dashboard's Keys ring calls them.
      expect(find.text('Key 1 · this device'), findsOneWidget);
      expect(find.text('Key 2'), findsOneWidget);
      expect(find.text('Key 3'), findsOneWidget);
      expect(find.text('Signed'), findsOneWidget);
      expect(find.text('Waiting'), findsNWidgets(2));
    });

    testWidgets('the rows wear the names and colours the wallet gave its keys',
        (t) async {
      await CosignerLabelStore.instance.saveOne(
        'w1',
        const CosignerLabel(
            id: 'bb000002', name: 'Anna’s phone', colorValue: 0xFF1D4ED8),
      );
      await _pump(t, sheet(_QuorumBridge()));

      expect(find.text('Anna’s phone'), findsOneWidget);
      expect(find.text('Key 2'), findsNothing);
      final donut = t.widget<SignerDonut>(find.byType(SignerDonut));
      expect(donut.slots![1].color, const Color(0xFF1D4ED8));
    });

    testWidgets('Copy, Save and Paste share one row; the box opens on Paste',
        (t) async {
      await _pump(t, sheet(_QuorumBridge()));

      expect(find.text('Copy PSBT'), findsOneWidget);
      expect(find.text('Save .psbt file'), findsOneWidget);
      expect(find.text('Paste signed copy'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      // Nothing to type into until Paste is pressed.
      expect(find.byType(TextField), findsNothing);

      await t.tap(find.text('Paste signed copy'));
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Add signature'), findsOneWidget);
      expect(find.text('Close paste box'), findsOneWidget);
    });

    testWidgets('a pasted signature moves the chart and lands on its signer',
        (t) async {
      await _pump(t, sheet(_QuorumBridge()));
      expect(find.text('1/3'), findsOneWidget);

      await _paste(t, '$_psbt~sigB');

      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('QUORUM MET'), findsOneWidget);
      expect(find.text('Signed'), findsNWidgets(2));
      // The note says whose signature arrived and where that leaves things.
      expect(
        find.text('Signature from Key 2 added · 2 of 2 — quorum met'),
        findsOneWidget,
      );
      // The box closed behind it.
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a returning copy is folded into the copy handed out',
        (t) async {
      // A signed the original and handed it out; B signed A's copy. The
      // copy going out must now carry both, and it must be one copy.
      final bridge = _QuorumBridge();
      await _pump(t, sheet(bridge));
      expect(_artifactOnScreen(t), _psbt);

      await _paste(t, '$_psbt~sigB');

      expect(bridge.combines, 1);
      expect(_artifactOnScreen(t), 'cHNidP8BAH0partial~sigA~sigB');
    });

    testWidgets('signatures collected in parallel are merged, not swapped',
        (t) async {
      // B and C each signed the ORIGINAL (no A in their copies). Taking C's
      // copy after B's must not throw B's signature away.
      final bridge = _QuorumBridge();
      await _pump(
        t,
        PsbtHandoffSheet(
          unsignedPsbt: 'cHNidP8BAH0partial',
          bridge: bridge,
          quorumHave: 0,
          quorumNeeded: 2,
          onBroadcast: (_) {},
        ),
      );
      await _paste(t, 'cHNidP8BAH0partial~sigB');
      expect(find.text('1/3'), findsOneWidget);

      await _paste(t, 'cHNidP8BAH0partial~sigC');
      expect(find.text('2/3'), findsOneWidget);
      expect(_artifactOnScreen(t), 'cHNidP8BAH0partial~sigB~sigC');
    });

    testWidgets('the copy going out pasted back is refused with the reason',
        (t) async {
      // The confusing case: the coordinator copies its own PSBT, pastes it
      // into the same sheet, and nothing visibly happens. Now it says why.
      final bridge = _QuorumBridge();
      await _pump(t, sheet(bridge));

      await _paste(t, _psbt);

      expect(find.textContaining('carries nothing new'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
      expect(bridge.combines, 0);
      // The box stays open, with the verdict in it.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('a copy with no new signature is refused too', (t) async {
      await _pump(t, sheet(_QuorumBridge()));
      // A's copy under another name: same one signature.
      await _paste(t, 'cHNidP8BAH0partial-again~sigA');
      expect(find.textContaining('No new signature in that copy'),
          findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('an unreadable paste says so and leaves the chart alone',
        (t) async {
      await _pump(t, sheet(_RejectingBridge()));

      await _paste(t, 'not-a-psbt');

      expect(find.textContaining('that is not a PSBT'), findsOneWidget);
      // Still the quorum of the copy that went out — nothing was adopted.
      expect(find.text('1/3'), findsOneWidget);
      expect(_artifactOnScreen(t), _psbt);
    });

    testWidgets('broadcast waits for the quorum', (t) async {
      await _pump(t, sheet(_QuorumBridge()));
      final before = t.widget<ElevatedButton>(find.widgetWithText(
          ElevatedButton, 'Review & Broadcast'));
      expect(before.onPressed, isNull);

      await _paste(t, '$_psbt~sigB');

      final after = t.widget<ElevatedButton>(find.widgetWithText(
          ElevatedButton, 'Review & Broadcast'));
      expect(after.onPressed, isNotNull);
    });

    testWidgets('a hardware key still to sign offers the USB route',
        (t) async {
      await CosignerLabelStore.instance.saveOne(
        'w1',
        const CosignerLabel(id: 'cc000003', name: 'Ledger', hardware: true),
      );
      await _pump(t, sheet(_QuorumBridge()));
      expect(find.text('Sign with USB hardware wallet'), findsOneWidget);
      expect(find.byIcon(Icons.usb_rounded), findsWidgets);

      // Once that key has signed, the button has nothing left to do.
      await _paste(t, '$_psbt~sigC');
      expect(find.text('Sign with USB hardware wallet'), findsNothing);
    });

    testWidgets('no hardware key, no USB button', (t) async {
      await _pump(t, sheet(_QuorumBridge()));
      expect(find.text('Sign with USB hardware wallet'), findsNothing);
    });
  });

  group('PSET hand-off', () {
    testWidgets('charts the quorum and folds a pasted signature in',
        (t) async {
      final bridge = _QuorumBridge();
      await _pump(
        t,
        PsetHandoffSheet(
          pset: 'cHNldP8Bpartial~sigA',
          have: 1,
          needed: 2,
          bridge: bridge,
          onBroadcast: (_) {},
        ),
      );

      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('1 MORE SIGNATURE NEEDED'), findsOneWidget);
      // The PSET goes out as a QR too — the ur:bytes frames the stub hands
      // back — beside the clipboard, file and paste routes.
      expect(find.byType(UrAnimatedQr), findsOneWidget);
      expect(find.text('Scan signed QR'), findsOneWidget);
      expect(find.text('Copy PSET'), findsOneWidget);
      expect(find.text('Paste signed copy'), findsOneWidget);

      await _paste(t, 'cHNldP8Bpartial~sigB');

      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('QUORUM MET'), findsOneWidget);
      expect(bridge.combines, 1);
      expect(_artifactOnScreen(t), 'cHNldP8Bpartial~sigA~sigB');
    });
  });
}
