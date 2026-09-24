// Decode contract for the hardware-wallet models: HwDevice (from
// enumerate_hw_devices) and HwImportResult (from import_hw_wallet, which
// nests WalletSummary payloads — see HwImportResultDto in wallet-ffi).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/create_wallet/models/hw_device.dart';
import 'package:templar_wallet/features/create_wallet/models/hw_import_result.dart';
import 'package:templar_wallet/features/wallet_picker/models/wallet_summary.dart';

Map<String, dynamic> decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  test('HwDevice decodes an HWI enumerate entry and roundtrips toJson', () {
    final j = decode('''
      {"model": "ledger_nano_s_plus", "fingerprint": "f00dbabe", "path": "webusb:001:1"}
    ''');
    final d = HwDevice.fromJson(j);
    expect(d.model, 'ledger_nano_s_plus');
    expect(d.fingerprint, 'f00dbabe');
    expect(d.path, 'webusb:001:1');
    expect(d.toJson(), j);
  });

  test('HwDevice tolerates missing keys with empty strings', () {
    final d = HwDevice.fromJson(decode('{}'));
    expect(d.model, '');
    expect(d.fingerprint, '');
    expect(d.path, '');
  });

  test('HwImportResult decodes a Bitcoin-only pairing', () {
    final r = HwImportResult.fromJson(decode('''
      {
        "wallet": {"id": "hw-1", "name": "Ledger", "wallet_type": "watch_only",
                   "is_watch_only": true, "type_label": "Hardware (f00dbabe)",
                   "device_model": "Nano S Plus"},
        "fingerprint": "f00dbabe",
        "device_model": "Nano S Plus",
        "bitcoin_descriptor": "wpkh([f00dbabe/84h/1h/0h]tpubDX/0/*)",
        "liquid_descriptor": null,
        "liquid_error": null,
        "liquid_requested": false
      }
    '''));
    expect(r.wallet.id, 'hw-1');
    expect(r.wallet.type, WalletType.watchOnly);
    expect(r.wallet.isWatchOnly, isTrue);
    expect(r.wallet.isHardwareWallet, isTrue);
    // No Liquid asked for, none delivered: a complete pairing, not a partial one.
    expect(r.hasLiquid, isFalse);
    expect(r.isComplete, isTrue);
    expect(r.wallet.networksLabel, 'BTC only');
    expect(r.wallet.keyOriginLabel, 'Ledger USB');
  });

  test('HwImportResult decodes a wallet with both networks on one entry', () {
    final r = HwImportResult.fromJson(decode('''
      {
        "wallet": {"id": "hw-1", "name": "Jade", "wallet_type": "watch_only",
                   "liquid_enabled": true, "device_model": "Blockstream Jade",
                   "type_label": "Hardware (deadbeef)"},
        "fingerprint": "deadbeef",
        "device_model": "Blockstream Jade",
        "bitcoin_descriptor": "wpkh([deadbeef/84h/1h/0h]tpubDX/0/*)",
        "liquid_descriptor": "ct(slip77(aa),elwpkh([deadbeef/84h/1h/0h]tpubDX/<0;1>/*))",
        "liquid_requested": true
      }
    '''));
    expect(r.hasLiquid, isTrue);
    expect(r.isComplete, isTrue);
    // Both sides live on one wallet — there is no second entry to look for.
    expect(r.wallet.liquidEnabled, isTrue);
    expect(r.wallet.bitcoinEnabled, isTrue);
    expect(r.wallet.networksLabel, 'BTC + Liquid');
    expect(r.wallet.keyOriginLabel, 'Jade USB');
  });

  test('HwImportResult reports a Liquid half that failed to pair', () {
    final r = HwImportResult.fromJson(decode('''
      {
        "wallet": {"id": "hw-1", "name": "Jade", "wallet_type": "watch_only",
                   "type_label": "Hardware (deadbeef)"},
        "fingerprint": "deadbeef",
        "device_model": "Blockstream Jade",
        "bitcoin_descriptor": "wpkh([deadbeef/84h/1h/0h]tpubDX/0/*)",
        "liquid_error": "Jade is not ready: could not unlock",
        "liquid_requested": true
      }
    '''));
    // The Bitcoin wallet is real; only the Liquid side is missing.
    expect(r.wallet.bitcoinEnabled, isTrue);
    expect(r.hasLiquid, isFalse);
    expect(r.isComplete, isFalse);
    expect(r.liquidError, contains('could not unlock'));
  });

  test('a Liquid-only wallet reports no Bitcoin side', () {
    final w = WalletSummary.fromJson(decode('''
      {"id": "liq-1", "name": "Jade Liquid", "wallet_type": "watch_only",
       "liquid_enabled": true, "bitcoin_enabled": false,
       "device_model": "jade", "type_label": "Hardware (09026b48)"}
    '''));
    expect(w.bitcoinEnabled, isFalse);
    expect(w.networksLabel, 'Liquid only');
  });
}
