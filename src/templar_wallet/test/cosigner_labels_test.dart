// Naming a multisig's keys: what a label is keyed on, what survives a
// rebuild, and what the ring does when there are more keys than it can draw.
//
// The identity rule is the load-bearing one. A label pinned to a position
// would follow whichever key happened to land there; pinned to the key's
// fingerprint it follows the device, which is what a name is about.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/services/cosigner_label_store.dart';
import 'package:templar_wallet/shared/models/cosigner_label.dart';
import 'package:templar_wallet/shared/widgets/cosigner_ring.dart';

String _key(String fp, [String path = "48'/1'/0'/2'"]) => '[$fp/$path]tpubFAKE';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CosignerLabelStore.instance.clearCache();
  });

  group('identity', () {
    test('a label is keyed on the fingerprint, not the position', () {
      final keys = [_key('aaaaaaaa'), _key('bbbbbbbb'), _key('cccccccc')];
      expect(cosignerId(keys, 1), 'bbbbbbbb');

      // The same wallet after a repair reordered nothing but rewrote the
      // strings: `h` for `'`, upper case, no wrapper. The id must not move.
      final rebuilt = [
        _key('aaaaaaaa'),
        '[BBBBBBBB/48h/1h/0h/2h]tpubFAKE',
        _key('cccccccc'),
      ];
      expect(cosignerId(rebuilt, 1), 'bbbbbbbb');
    });

    test('a repeated fingerprint falls back to the position', () {
      // Two accounts of one seed in the same wallet: unusual, but a label
      // keyed on the fingerprint alone would describe both.
      final keys = [_key('aaaaaaaa'), _key('aaaaaaaa', "48'/1'/1'/2'")];
      expect(cosignerId(keys, 0), 'aaaaaaaa:0');
      expect(cosignerId(keys, 1), 'aaaaaaaa:1');
    });

    test('a key with no origin still gets a stable id', () {
      expect(cosignerId(['tpubNOORIGIN'], 0), 'i0');
    });

    test('fingerprint and path are read out of the origin', () {
      expect(fingerprintOf(_key('F0B68896')), 'f0b68896');
      expect(pathOf(_key('f0b68896')), "48'/1'/0'/2'");
      expect(fingerprintOf('tpubNOORIGIN'), '');
    });
  });

  group('label', () {
    test('an unnamed key reads as its position', () {
      const label = CosignerLabel(id: 'aaaaaaaa');
      expect(label.displayName(2), 'Key 3');
      expect(label.icon, defaultCosignerIcon);
      expect(label.isEmpty, isTrue);
    });

    test('a retired icon id degrades to the default rather than throwing', () {
      const label = CosignerLabel(id: 'a', iconId: 'no-such-icon');
      expect(label.icon, defaultCosignerIcon);
    });

    test('whitespace is not a name', () {
      const label = CosignerLabel(id: 'a', name: '   ');
      expect(label.displayName(0), 'Key 1');
      expect(label.isEmpty, isTrue);
    });
  });

  group('hardware flag', () {
    test('an explicit answer round-trips and is not empty', () {
      const label = CosignerLabel(id: 'a', hardware: true);
      expect(label.isHardware, isTrue);
      expect(label.isEmpty, isFalse);
      final back = CosignerLabel.fromJson('a', label.toJson());
      expect(back.hardware, isTrue);
      expect(back.toJson(), {'hw': true});
    });

    test('without an answer the USB and Jade icons stand in for it', () {
      // Wallets labelled before the flag existed: the wizard gave keys it
      // read over USB the stick or the shield, and nothing else.
      expect(const CosignerLabel(id: 'a', iconId: 'usb').isHardware, isTrue);
      expect(
          const CosignerLabel(id: 'a', iconId: 'shield').isHardware, isTrue);
      expect(const CosignerLabel(id: 'a', iconId: 'phone').isHardware, isFalse);
      expect(const CosignerLabel(id: 'a').isHardware, isFalse);
      expect(const CosignerLabel(id: 'a', iconId: 'usb').toJson(),
          isNot(contains('hw')));
    });

    test('an explicit no beats the icon', () {
      const label = CosignerLabel(id: 'a', iconId: 'usb', hardware: false);
      expect(label.isHardware, isFalse);
      expect(label.copyWith(hardware: null).isHardware, isTrue);
    });
  });

  group('store', () {
    test('a label round-trips', () async {
      final store = CosignerLabelStore.instance;
      await store.saveOne(
        'w1',
        const CosignerLabel(
            id: 'aaaaaaaa', name: 'Jade in the safe', iconId: 'shield'),
      );
      store.clearCache();

      final loaded = await store.load('w1');
      expect(loaded['aaaaaaaa']?.name, 'Jade in the safe');
      expect(loaded['aaaaaaaa']?.icon, cosignerIcons['shield']);
    });

    test('clearing a label removes it instead of storing an empty one',
        () async {
      final store = CosignerLabelStore.instance;
      await store.saveOne('w1', const CosignerLabel(id: 'a', name: 'Phone'));
      await store.saveOne('w1', const CosignerLabel(id: 'a'));
      store.clearCache();
      expect(await store.load('w1'), isEmpty);
    });

    test('labels are per wallet and deleting one leaves the other', () async {
      final store = CosignerLabelStore.instance;
      await store.saveOne('w1', const CosignerLabel(id: 'a', name: 'One'));
      await store.saveOne('w2', const CosignerLabel(id: 'a', name: 'Two'));

      await store.delete('w1');
      store.clearCache();
      expect(await store.load('w1'), isEmpty);
      expect((await store.load('w2'))['a']?.name, 'Two');
    });

    test('a corrupt entry costs names, not the wallet', () async {
      SharedPreferences.setMockInitialValues(
          {'cosigner_labels_v1_w1': 'not json at all'});
      CosignerLabelStore.instance.clearCache();
      expect(await CosignerLabelStore.instance.load('w1'), isEmpty);
    });
  });

  group('resolve', () {
    test('keys pair with their labels and the local one is marked', () {
      final keys = [_key('aaaaaaaa'), _key('bbbbbbbb')];
      final entries = resolveCosigners(
        cosignerKeys: keys,
        labels: const {
          'bbbbbbbb': CosignerLabel(id: 'bbbbbbbb', name: 'Anna’s phone'),
        },
        // The engine reports fingerprints in whatever case it stored them.
        localFingerprints: const ['AAAAAAAA'],
      );

      expect(entries[0].name, 'Key 1');
      expect(entries[0].isLocal, isTrue);
      expect(entries[1].name, 'Anna’s phone');
      expect(entries[1].isLocal, isFalse);
    });
  });

  group('ring', () {
    List<CosignerEntry> entries(int n) => resolveCosigners(
          cosignerKeys: [
            for (var i = 0; i < n; i++) _key('${i}0000000'),
          ],
          labels: const {},
        );

    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('every key is drawn while they fit', (t) async {
      await t.pumpWidget(
          host(CosignerRing(entries: entries(3), requiredSigs: 2)));
      expect(find.byIcon(defaultCosignerIcon), findsNWidgets(3));
      expect(find.textContaining('+'), findsNothing);
      expect(find.text('2/3'), findsOneWidget);
    });

    testWidgets('past five, the rest collapse into one badge', (t) async {
      await t.pumpWidget(
          host(CosignerRing(entries: entries(8), requiredSigs: 5)));
      // Five drawn, three folded away — and the centre still reports the
      // whole wallet, not the part that fitted.
      expect(find.byIcon(defaultCosignerIcon), findsNWidgets(maxRingIcons));
      expect(find.text('+3'), findsOneWidget);
      expect(find.text('5/8'), findsOneWidget);
    });

    testWidgets('the overflow badge opens the roster', (t) async {
      var opened = false;
      await t.pumpWidget(host(CosignerRing(
        entries: entries(9),
        requiredSigs: 2,
        onTapMore: () => opened = true,
      )));
      await t.tap(find.text('+4'));
      expect(opened, isTrue);
    });

    // A rename that only reached the store left the row the user had just
    // edited still reading "Key 2" until the sheet was closed and reopened.
    testWidgets('a rename shows up in the open roster', (t) async {
      final renamed = resolveCosigners(
        cosignerKeys: [_key('00000000'), _key('10000000')],
        labels: const {
          '10000000': CosignerLabel(id: '10000000', name: 'Jade in the safe'),
        },
      );

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCosignerRoster(
                context,
                entries: entries(2),
                requiredSigs: 2,
                onEdit: (_) async => renamed,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Key 2'), findsOneWidget);

      await t.tap(find.byIcon(Icons.edit_outlined).last);
      await t.pumpAndSettle();

      expect(find.text('Jade in the safe'), findsOneWidget);
      expect(find.text('Key 2'), findsNothing);
    });

    testWidgets('the roster lists every key, drawn or not', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCosignerRoster(
                context,
                entries: entries(7),
                requiredSigs: 3,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.text('Keys of this wallet'), findsOneWidget);
      expect(find.textContaining('Any 3 of these 7'), findsOneWidget);
      expect(find.text('Key 1'), findsOneWidget);

      // The two the ring could not draw are in here, past the fold — the
      // roster is the complete list, not a longer truncation of it.
      await t.scrollUntilVisible(find.text('Key 7'), 120,
          scrollable: find.byType(Scrollable).last);
      expect(find.text('Key 7'), findsOneWidget);
    });
  });
}
