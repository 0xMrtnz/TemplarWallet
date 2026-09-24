// Decode contract for TxIo.fromJson and the TxOutputSpec.toJson request
// shape — both sides of the send preview wire format (wallet-ffi TxIoDto /
// TxOutputSpec in src/wallet-ffi/src/types.rs).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/send/models/tx_preview.dart';

Map<String, dynamic> decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  group('TxIo.fromJson', () {
    test('decodes a Bitcoin input with outpoint', () {
      final io = TxIo.fromJson(decode('''
        {
          "outpoint": "deadbeef:0",
          "address": "tb1qexample",
          "amount_sats": 15000,
          "is_change": false,
          "asset_id": null,
          "ticker": null,
          "amount_display": null
        }
      '''));

      expect(io.outpoint, 'deadbeef:0');
      expect(io.address, 'tb1qexample');
      expect(io.amountSats, 15000);
      expect(io.isChange, isFalse);
      expect(io.assetId, isNull);
      expect(io.ticker, isNull);
      expect(io.amountDisplay, isNull);
    });

    test('decodes a Liquid change output without outpoint', () {
      final io = TxIo.fromJson(decode('''
        {
          "outpoint": null,
          "address": "tlq1qqexample",
          "amount_sats": 4200,
          "is_change": true,
          "asset_id": "144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49",
          "ticker": "L-BTC",
          "amount_display": "0.00004200 L-BTC"
        }
      '''));

      expect(io.outpoint, isNull);
      expect(io.isChange, isTrue);
      expect(io.ticker, 'L-BTC');
      expect(io.amountDisplay, '0.00004200 L-BTC');
    });

    test('tolerates missing optional keys with safe defaults', () {
      final io = TxIo.fromJson(decode('{"address": "tb1qminimal"}'));
      expect(io.address, 'tb1qminimal');
      expect(io.outpoint, isNull);
      expect(io.amountSats, 0);
      expect(io.isChange, isFalse);
    });
  });

  group('TxOutputSpec.toJson', () {
    test('emits the snake_case keys wallet-ffi deserializes', () {
      const spec = TxOutputSpec(
        address: 'tb1qdest',
        amountSats: 5000,
        assetId: 'aaaa',
        sendMax: true,
      );
      expect(spec.toJson(), {
        'address': 'tb1qdest',
        'amount_sats': 5000,
        'asset_id': 'aaaa',
        'send_max': true,
      });
    });

    test('omits null asset and false send_max (serde defaults fill them)', () {
      const spec = TxOutputSpec(address: 'tb1qdest', amountSats: 5000);
      expect(spec.toJson(), {'address': 'tb1qdest', 'amount_sats': 5000});
    });
  });
}
