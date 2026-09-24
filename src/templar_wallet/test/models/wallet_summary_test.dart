// Decode contract for WalletSummary.fromJson — the exact shape wallet-ffi's
// WalletSummaryDto serializes (see src/wallet-ffi/src/types.rs). A duplicate
// parser drifting from this model already shipped one bug (commit 0b75bd9),
// so the fixtures below mirror real wire payloads, not hand-picked subsets.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/wallet_picker/models/wallet_summary.dart';

Map<String, dynamic> decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  test('decodes a full singlesig summary as serialized by wallet-ffi', () {
    final w = WalletSummary.fromJson(decode('''
      {
        "id": "w-1",
        "name": "Contract Test",
        "wallet_type": "singlesig",
        "network": "testnet",
        "balance_sats": 12345,
        "tx_count": 2,
        "last_sync_at": 1722500000,
        "is_watch_only": false,
        "type_label": "Software",
        "liquid_enabled": true,
        "master_fingerprint": "73c5da0a",
        "xpub": "tpubDC5FSnBiZDMmhiuCmWAYsLwgLYrrT9rAqvTySfuCCrgsWz8wxMXUS9Tb9iVMvcRbvFcAHGkMD5Kx8koh4GquNGNTfohfk7pgjhaPCdXpoba",
        "required_sigs": null,
        "total_signers": null
      }
    '''));

    expect(w.id, 'w-1');
    expect(w.name, 'Contract Test');
    expect(w.type, WalletType.singlesig);
    expect(w.balanceSats, 12345);
    expect(w.txCount, 2);
    expect(w.lastSyncAt,
        DateTime.fromMillisecondsSinceEpoch(1722500000 * 1000));
    expect(w.isWatchOnly, isFalse);
    expect(w.typeLabel, 'Software');
    expect(w.liquidEnabled, isTrue);
    expect(w.masterFingerprint, '73c5da0a');
    expect(w.xpub, startsWith('tpub'));
    expect(w.requiredSigs, isNull);
    expect(w.thresholdLabel, isNull);
    expect(w.displayType, 'Software');
  });

  test('decodes a multisig summary and derives the threshold label', () {
    final w = WalletSummary.fromJson(decode('''
      {
        "id": "w-2",
        "name": "Treasury",
        "wallet_type": "multisig",
        "network": "testnet",
        "balance_sats": 0,
        "tx_count": 0,
        "last_sync_at": 0,
        "is_watch_only": false,
        "type_label": "Multisig 2-of-3",
        "liquid_enabled": false,
        "master_fingerprint": "aabbccdd",
        "xpub": null,
        "required_sigs": 2,
        "total_signers": 3
      }
    '''));

    expect(w.type, WalletType.multisig);
    expect(w.xpub, isNull);
    expect(w.requiredSigs, 2);
    expect(w.totalSigners, 3);
    expect(w.thresholdLabel, '2-of-3');
  });

  test('decodes watch-only type and tolerates missing optional keys', () {
    final w = WalletSummary.fromJson(decode('''
      {"id": "w-3", "name": "Cold", "wallet_type": "watch_only"}
    '''));

    expect(w.type, WalletType.watchOnly);
    expect(w.balanceSats, 0);
    expect(w.txCount, 0);
    expect(w.isWatchOnly, isFalse);
    expect(w.typeLabel, '');
    expect(w.liquidEnabled, isFalse);
    expect(w.masterFingerprint, isNull);
    expect(w.displayType, 'Watch-only');
  });

  test('unknown wallet_type falls back to singlesig', () {
    final w = WalletSummary.fromJson(
        decode('{"id": "w-4", "name": "Odd", "wallet_type": "policy"}'));
    expect(w.type, WalletType.singlesig);
  });
}
