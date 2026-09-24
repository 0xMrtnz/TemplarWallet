// The pairing UI's own logic: one row per physical device, honest wallet flags,
// and a recap that tells a complete pairing from a half one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/create_wallet/models/hw_device.dart';
import 'package:templar_wallet/features/create_wallet/models/native_device.dart';
import 'package:templar_wallet/features/hardware/device_list_section.dart';
import 'package:templar_wallet/features/hardware/hw_platform.dart';
import 'package:templar_wallet/features/hardware/pairing_recap.dart';
import 'package:templar_wallet/features/wallet_picker/models/wallet_summary.dart';
import 'package:templar_wallet/features/wallet_picker/wallet_flags.dart';

NativeDevice native({
  required String model,
  required String path,
  String family = 'jade',
  String transport = 'serial',
  bool drivable = true,
}) =>
    NativeDevice(
      family: family,
      model: model,
      transport: transport,
      path: path,
      vendorId: 0x303a,
      productId: 0x4001,
      drivable: drivable,
    );

WalletSummary wallet({
  String typeLabel = 'Hardware (deadbeef)',
  String? deviceModel = 'Blockstream Jade',
  bool liquid = false,
  bool bitcoin = true,
  WalletType type = WalletType.watchOnly,
  String? masterFingerprint,
  int? requiredSigs,
  int? totalSigners,
}) =>
    WalletSummary(
      id: 'w1',
      name: 'Wallet',
      type: type,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.fromMillisecondsSinceEpoch(0),
      isWatchOnly: true,
      typeLabel: typeLabel,
      liquidEnabled: liquid,
      bitcoinEnabled: bitcoin,
      deviceModel: deviceModel,
      masterFingerprint: masterFingerprint,
      requiredSigs: requiredSigs,
      totalSigners: totalSigners,
    );

Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('mergeDeviceRows', () {
    test('a detected device gains its fingerprint instead of a second row', () {
      final rows = mergeDeviceRows(
        detected: [native(model: 'Jade', path: '/dev/cu.usbmodem1234561')],
        identified: [
          const HwDevice(
            model: 'Blockstream Jade',
            fingerprint: '09026b48',
            path: '/dev/cu.usbmodem1234561',
          ),
        ],
      );
      expect(rows, hasLength(1), reason: 'one physical device is one row');
      expect(rows.single.fingerprint, '09026b48');
      expect(rows.single.isIdentified, isTrue);
    });

    test('an HWI device with its own path shape is listed once', () {
      final rows = mergeDeviceRows(
        detected: [
          native(
            model: 'Trezor',
            family: 'trezor',
            transport: 'hid',
            path: 'hid:0001',
            drivable: false,
          ),
        ],
        identified: [
          // HWI reports a path of its own; the fingerprint is what ties them.
          const HwDevice(
            model: 'trezor_1',
            fingerprint: 'aabbccdd',
            path: 'webusb:001:4',
          ),
        ],
      );
      expect(rows, hasLength(2), reason: 'different devices stay separate');

      final duplicate = mergeDeviceRows(
        detected: const [],
        identified: [
          const HwDevice(model: 'a', fingerprint: 'aabbccdd', path: 'p1'),
          const HwDevice(model: 'a', fingerprint: 'aabbccdd', path: 'p2'),
        ],
      );
      expect(duplicate, hasLength(1),
          reason: 'one fingerprint is one device, whatever the path');
    });

    test('a plugged-in device with no fingerprint yet is still a row', () {
      final rows = mergeDeviceRows(
        detected: [native(model: 'Jade', path: '/dev/cu.usbmodem1')],
        identified: const [],
      );
      expect(rows.single.isIdentified, isFalse);
      expect(rows.single.drivable, isTrue);
      expect(rows.single.supportsLiquid, isTrue,
          reason: 'a Jade can hold Liquid');
    });

    test('an HWI-only device is usable where the helper runs', () {
      final rows = mergeDeviceRows(
        detected: [
          native(
            model: 'Trezor Model T',
            family: 'trezor',
            transport: 'hid',
            path: 'hid:5',
            drivable: false,
          ),
        ],
        identified: const [],
      );
      final row = rows.single;
      expect(row.drivable, isFalse, reason: 'no native driver for Trezor');

      // Windows and Linux: the helper runs, so the device is pairable and must
      // not be greyed out.
      hwiFallbackUsable = true;
      expect(row.usable, isTrue);

      // macOS: the App Sandbox blocks the helper, and only then is it unusable.
      hwiFallbackUsable = false;
      expect(row.usable, isFalse);
      hwiFallbackUsable = true;
    });

    test('only a Jade is offered as Liquid-capable', () {
      final ledger = mergeDeviceRows(
        detected: [
          native(
            model: 'Nano S Plus',
            family: 'ledger',
            transport: 'hid',
            path: 'hid:2',
          ),
        ],
        identified: const [],
      );
      expect(ledger.single.supportsLiquid, isFalse);
    });
  });

  group('WalletFlags', () {
    // The flags render as ONE composed line (Text.rich), not a row of separate
    // pills, so these match inside the rich text rather than whole widgets.
    Finder says(String fragment) =>
        find.textContaining(fragment, findRichText: true);

    testWidgets('a hardware Jade wallet with both chains', (tester) async {
      await pump(tester, WalletFlags(wallet: wallet(liquid: true)));
      expect(says('Jade USB'), findsOneWidget);
      expect(says('BTC + Liquid'), findsOneWidget);
    });

    testWidgets('an air-gap wallet is flagged as such, Bitcoin-only',
        (tester) async {
      await pump(
        tester,
        WalletFlags(
          wallet: wallet(typeLabel: 'Air-gap watch-only', deviceModel: 'air-gap'),
        ),
      );
      expect(says('Air-gap'), findsOneWidget);
      expect(says('BTC only'), findsOneWidget);
    });

    testWidgets('a Liquid-only wallet says so rather than claiming Bitcoin',
        (tester) async {
      await pump(
        tester,
        WalletFlags(wallet: wallet(liquid: true, bitcoin: false)),
      );
      expect(says('Liquid only'), findsOneWidget);
      expect(says('BTC'), findsNothing);
    });

    testWidgets('a view-only wallet is not shown as a signing device',
        (tester) async {
      await pump(
        tester,
        WalletFlags(
          wallet: wallet(typeLabel: 'Watch-only', deviceModel: 'watch-only'),
        ),
      );
      expect(says('Watch-only'), findsOneWidget);
    });

    testWidgets('a multisig states its threshold exactly once', (tester) async {
      // The threshold IS the key-origin label for a multisig. Appending it
      // again as a fingerprint fallback printed "2-of-3 · BTC only · 2-of-3".
      await pump(
        tester,
        WalletFlags(
          wallet: wallet(
            type: WalletType.multisig,
            typeLabel: 'Multisig',
            deviceModel: null,
            requiredSigs: 2,
            totalSigners: 3,
          ),
        ),
      );
      final line = tester.widget<Text>(find.byType(Text)).textSpan!.toPlainText();
      expect('2-of-3'.allMatches(line).length, 1, reason: line);
    });

    testWidgets('the fingerprint is the trailing fact when there is one',
        (tester) async {
      await pump(
        tester,
        WalletFlags(wallet: wallet(masterFingerprint: 'f0b68896')),
      );
      expect(says('f0b68896'), findsOneWidget);
    });

    testWidgets('compact drops the chain list, keeps the key origin',
        (tester) async {
      await pump(
        tester,
        WalletFlags(wallet: wallet(liquid: true), compact: true),
      );
      expect(says('Jade USB'), findsOneWidget);
      expect(says('BTC + Liquid'), findsNothing);
    });
  });

  group('PairingRecapView', () {
    testWidgets('both chains paired reads as complete', (tester) async {
      await pump(
        tester,
        PairingRecapView(
          walletName: 'Jade',
          deviceLabel: 'Blockstream Jade over USB',
          fingerprint: 'deadbeef',
          networks: [
            const PairingNetwork(
              name: 'Bitcoin',
              icon: Icons.currency_bitcoin,
              color: Colors.orange,
              ok: true,
              detail: 'Imported',
              descriptor: 'wpkh([deadbeef/84h/1h/0h]tpub/0/*)',
            ),
            const PairingNetwork(
              name: 'Liquid Network',
              icon: Icons.water_drop_rounded,
              color: Colors.teal,
              ok: true,
              detail: 'Imported',
            ),
          ],
          checks: const [
            PairingCheck(label: 'Device answered', passed: true),
          ],
        ),
      );
      expect(find.text('Pairing complete'), findsOneWidget);
      expect(find.text('deadbeef'), findsOneWidget);
      // The stored descriptor is on screen so it can be compared with the device.
      expect(find.textContaining('wpkh([deadbeef'), findsOneWidget);
    });

    testWidgets('a missing half is reported, with its retry', (tester) async {
      var retried = false;
      await pump(
        tester,
        PairingRecapView(
          walletName: 'Jade',
          deviceLabel: 'Blockstream Jade over USB',
          fingerprint: 'deadbeef',
          networks: [
            const PairingNetwork(
              name: 'Bitcoin',
              icon: Icons.currency_bitcoin,
              color: Colors.orange,
              ok: true,
              detail: 'Imported',
            ),
            PairingNetwork(
              name: 'Liquid Network',
              icon: Icons.water_drop_rounded,
              color: Colors.teal,
              ok: false,
              detail: 'Jade is not ready: could not unlock',
              action: () => retried = true,
              actionLabel: 'Retry Liquid',
            ),
          ],
          checks: const [],
        ),
      );
      expect(find.text('Paired, with one part missing'), findsOneWidget);
      expect(find.textContaining('could not unlock'), findsOneWidget);
      await tester.tap(find.text('Retry Liquid'));
      expect(retried, isTrue);
    });

    testWidgets('a failed check drops the complete headline', (tester) async {
      await pump(
        tester,
        const PairingRecapView(
          walletName: 'Jade',
          deviceLabel: 'Blockstream Jade over USB',
          fingerprint: 'deadbeef',
          networks: [
            PairingNetwork(
              name: 'Bitcoin',
              icon: Icons.currency_bitcoin,
              color: Colors.orange,
              ok: true,
              detail: 'Imported',
            ),
          ],
          checks: [
            // The descriptor not matching the device is the one failure that
            // must never read as success: the wallet could receive and never spend.
            PairingCheck(
              label: 'Bitcoin descriptor belongs to this device',
              passed: false,
              detail: 'aabbccdd',
            ),
          ],
        ),
      );
      expect(find.text('Pairing complete'), findsNothing);
      expect(find.text('Paired, with one part missing'), findsOneWidget);
    });
  });
}
