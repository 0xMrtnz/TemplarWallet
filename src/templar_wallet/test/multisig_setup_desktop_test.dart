// The multisig wizard on a desktop window, guarded at the two places it was
// broken.
//
// "Choose your threshold" put its two number pickers in a
// `Flex(crossAxisAlignment: stretch)`. On a phone that Flex is vertical and
// stretch means full width; on a desktop it is horizontal, the cross axis is
// the step's unbounded scroll height, and stretch asked the pickers for an
// infinite one — the whole step threw on every desktop build.
//
// "Import the keys" below it drew its key-source picker with Material's
// `SegmentedButton`: not the app's material, and five named segments never
// fitted the wizard's 640 dp column. Chips wrapped onto two ragged lines
// instead; it is a [ChoiceList] now — one row per source, in one panel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/wallet_picker/models/wallet_summary.dart';
import 'package:templar_wallet/features/create_wallet/models/new_wallet_draft.dart';
import 'package:templar_wallet/features/create_wallet/multisig_setup_screen.dart';
import 'package:templar_wallet/shared/widgets/choice_list.dart';

/// No wallets to lend a key: the step still has to build its N slots and its
/// source picker. Keeps the real engine (and the user's wallet directory) out
/// of a unit test.
///
/// [validateCosignerKey] stands in for the engine's own check, with the two
/// answers the wizard has to render: a key it accepts, and a refusal.
class _EmptyBridge implements WalletBridge {
  _EmptyBridge({this.keyError});

  /// When set, every key check fails with this message.
  final String? keyError;

  /// Keys the wizard asked about, in order.
  final List<String> checked = [];

  @override
  Future<List<WalletSummary>> listWallets() async => const [];

  @override
  Future<CosignerKeyInfo> validateCosignerKey(String key,
      {bool liquid = false}) async {
    checked.add(key);
    if (keyError != null) throw Exception('wallet-ffi: $keyError');
    return const CosignerKeyInfo(
      normalized: "[f0b68896/48'/1'/0'/2']tpubREDUCED",
      fingerprint: 'f0b68896',
      path: "48'/1'/0'/2'",
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host([WalletBridge? bridge]) => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: MultisigSetupScreen(bridge: bridge ?? _EmptyBridge()),
      ),
    );

/// The step's own progress line, e.g. "0 of 3 provided". Read rather than
/// hardcoded: the default threshold belongs to the wizard, not to this test.
String _provided(WidgetTester t) => t
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? '')
    .firstWhere((s) => s.endsWith(' provided'), orElse: () => '');

/// Walk to "Import the keys" and type [key] into the first cosigner field.
Future<void> _typeFirstKey(WidgetTester t, String key) async {
  await t.tap(find.text('Continue'));
  await t.pumpAndSettle();
  await t.enterText(find.widgetWithText(TextField, 'Cosigner xpub').first, key);
  await t.pumpAndSettle();
}

/// "Done with this key" sits under the source list, below the fold of a
/// 900 px window: scroll it in before pressing it.
Future<void> _tapDone(WidgetTester t) async {
  final done = find.text('Done with this key');
  await t.ensureVisible(done);
  await t.pumpAndSettle();
  await t.tap(done);
  await t.pumpAndSettle();
}

/// A desktop window: `AppLayout.isPhone` also needs a mobile platform, so a
/// host test can only ever exercise this arm — which is the broken one.
void _desktopWindow(WidgetTester t) {
  t.view.physicalSize = const Size(1280, 900);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  setUp(() {
    // The watch-only coordinator: threshold → import, no seed to generate.
    newWalletDraft.path = WalletPath.watchOnly;
    newWalletDraft.watchOnlyFromCosigners = true;
    newWalletDraft.liquidEnabled = false;
  });

  testWidgets('threshold step lays out on a desktop window', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host());
    await t.pump();

    expect(t.takeException(), isNull);
    expect(find.text('Choose your threshold'), findsOneWidget);
    expect(find.text('Signatures required (M)'), findsOneWidget);
    expect(find.text('Total keys (N)'), findsOneWidget);
  });

  testWidgets('key sources are one list of rows', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host());
    await t.pumpAndSettle();

    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();

    expect(find.text('Import the keys'), findsOneWidget);
    expect(t.takeException(), isNull);
    // A watch-only coordinator imports public keys only: paste/scan, an app
    // wallet, a USB device — no "New key", no "Seed phrase".
    expect(find.byWidgetPredicate((w) => w is ChoiceList), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ChoiceListRow), findsNWidgets(3));
    // The option the user cannot take says why, in place.
    expect(find.text('No software wallet in this app to lend a key'),
        findsOneWidget);
    // "Air-gap / QR" named one of the three things this source does, and the
    // common one — a key from another wallet of your own, or from a phone —
    // was not it.
    expect(find.text('Paste or scan a key'), findsOneWidget);
    expect(find.text('Air-gap / QR'), findsNothing);
    expect(find.text('New key'), findsNothing);
  });

  // A key typed or scanned by hand had no way to say "that one is done": every
  // other source advances the queue itself, so a pasted key left the card open
  // and the count unchanged, with nothing to press.
  testWidgets('Done checks the typed key and moves to the next slot',
      (t) async {
    _desktopWindow(t);
    final bridge = _EmptyBridge();
    await t.pumpWidget(_host(bridge));
    await t.pumpAndSettle();

    await _typeFirstKey(t, "[f0b68896/48'/1'/0'/2']tpubTYPED");
    expect(_provided(t), startsWith('0 of '), reason: 'unchecked key counts');

    await _tapDone(t);

    expect(bridge.checked, ["[f0b68896/48'/1'/0'/2']tpubTYPED"]);
    // Checked, accepted, counted — and the card has closed behind it, naming
    // the key by what a signing device knows it as.
    expect(_provided(t), startsWith('1 of '));
    expect(find.textContaining("f0b68896 · m/48'/1'/0'/2'"), findsOneWidget);
    expect(find.text('Cosigner xpub'), findsOneWidget,
        reason: 'the next key is the open card now');
  });

  // The failure that started this: a key the engine cannot use was carried all
  // the way to a created wallet, which then could not be opened — ever, from
  // any screen. It has to stop at the field it was typed into.
  testWidgets('a key the engine refuses is reported and does not count',
      (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host(_EmptyBridge(
      keyError: 'This key has no origin.',
    )));
    await t.pumpAndSettle();

    await _typeFirstKey(t, 'tpubNOORIGIN');
    await _tapDone(t);

    expect(find.text('This key has no origin.'), findsOneWidget);
    expect(_provided(t), startsWith('0 of '));
  });

  // Every key can be named, and the name is what the step then calls it. A
  // wallet's keys are otherwise "Key 1, Key 2, Key 3" forever, which is no
  // help at all in deciding which device to go and fetch.
  testWidgets('a named key is listed by its name', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host());
    await t.pumpAndSettle();

    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    // Unnamed: the header and the field's own hint both read "Key 1".
    expect(find.text('Key 1'), findsWidgets);

    await t.enterText(
      find.widgetWithText(TextField, 'Name this key (optional)').first,
      'Jade in the safe',
    );
    await t.pumpAndSettle();

    // The card header takes the name; the position stays as a quiet caption
    // so "which key is this" is still answerable.
    expect(find.text('Jade in the safe'), findsWidgets);
    expect(find.text('key 1'), findsOneWidget);
  });

  // A verdict that outlives the key it was about is worse than none: the tick
  // would vouch for whatever is in the field now.
  testWidgets('editing the key drops the verdict beside it', (t) async {
    _desktopWindow(t);
    await t.pumpWidget(_host());
    await t.pumpAndSettle();

    await _typeFirstKey(t, "[f0b68896/48'/1'/0'/2']tpubTYPED");
    await _tapDone(t);

    // Reopen the checked slot: the verdict is still there, next to the key it
    // was made about. (Scrolled to Done a moment ago; the row is above.)
    await t.ensureVisible(find.text('Key 1').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Key 1').first);
    await t.pumpAndSettle();
    expect(find.text("Key f0b68896 at m/48'/1'/0'/2'"), findsOneWidget);

    await t.enterText(
        find.widgetWithText(TextField, 'Cosigner xpub').first, 'something else');
    await t.pumpAndSettle();

    expect(find.text("Key f0b68896 at m/48'/1'/0'/2'"), findsNothing);
    expect(_provided(t), startsWith('0 of '));
  });
}
