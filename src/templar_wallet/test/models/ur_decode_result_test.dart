// Decode contract for UrDecodeResult.fromJson — the ur_decode_parts payload
// used by the air-gap QR scanner (fountain-coded BC-UR v2 parts).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';

Map<String, dynamic> decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  test('decodes an in-progress scan (integer progress from JSON)', () {
    final r = UrDecodeResult.fromJson(decode('''
      {"progress": 0, "complete": false, "kind": "", "psbt_base64": null, "descriptor": null}
    '''));
    // jsonDecode hands `0` over as int — the mapper must accept any num.
    expect(r.progress, 0.0);
    expect(r.complete, isFalse);
    expect(r.kind, '');
    expect(r.psbtBase64, isNull);
    expect(r.descriptor, isNull);
  });

  test('decodes a completed PSBT scan', () {
    final r = UrDecodeResult.fromJson(decode('''
      {"progress": 1.0, "complete": true, "kind": "psbt", "psbt_base64": "cHNidP8BAA==", "descriptor": null}
    '''));
    expect(r.progress, 1.0);
    expect(r.complete, isTrue);
    expect(r.kind, 'psbt');
    expect(r.psbtBase64, 'cHNidP8BAA==');
  });

  test('tolerates missing keys with safe defaults', () {
    final r = UrDecodeResult.fromJson(decode('{}'));
    expect(r.progress, 0.0);
    expect(r.complete, isFalse);
    expect(r.kind, '');
  });
}
