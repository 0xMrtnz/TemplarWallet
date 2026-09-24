import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/psbt/models/pset_inspection.dart';

void main() {
  group('PsetInspection.fromJson', () {
    test('decodes the script view the engine adds for loan contracts', () {
      final p = PsetInspection.fromJson({
        'fee_sats': 500,
        'fee_display': '0.00000500 L-BTC',
        'recipients': [],
        'sigs_have': 0,
        'sigs_needed': 1,
        'signers_present': [],
        'signers_missing': ['73c5da0a'],
        'can_finalize': false,
        'raw_pset': 'cHNldP8=',
        'network': 'liquid-regtest',
        'inputs': [
          {
            'index': 0,
            'outpoint': '${'2' * 64}:0',
            'is_ours': true,
            'script_type': 'p2wsh',
            'witness_script': '5221',
            'witness_script_asm': 'OP_PUSHNUM_2 ... OP_CHECKMULTISIG',
            'asset_id': 'aa' * 32,
            'ticker': 'L-BTC',
            'amount_sats': 1000000,
            'display_amount': '0.01000000 L-BTC',
            'key_fingerprints': ['73c5da0a', 'deadbeef'],
            'signed_by': [],
          },
          {
            'index': 1,
            'outpoint': '${'3' * 64}:1',
            'is_ours': false,
            'script_type': 'p2wpkh',
          },
        ],
        'outputs': [
          {'index': 0, 'kind': 'escrow', 'script_type': 'p2wsh', 'amount_sats': 10},
          {'index': 1, 'kind': 'own', 'script_type': 'p2wpkh', 'address': 'el1qq…'},
          {'index': 2, 'kind': 'fee', 'script_type': 'fee', 'amount_sats': 500},
        ],
      });
      expect(p.network, 'liquid-regtest');
      expect(p.inputs.length, 2);
      expect(p.ourInputs.length, 1);
      expect(p.inputs[0].isScriptHash, isTrue);
      expect(p.inputs[0].witnessScript, '5221');
      expect(p.inputs[0].keyFingerprints, contains('deadbeef'));
      expect(p.inputs[1].isOurs, isFalse);
      expect(p.outputs[0].isEscrow, isTrue);
      expect(p.outputs[0].kindLabel, 'Escrow contract');
      expect(p.outputs[1].isOwn, isTrue);
      expect(p.outputs[2].isFee, isTrue);
      expect(p.touchesEscrow, isTrue);
    });

    test('older payloads without the script view still decode', () {
      final p = PsetInspection.fromJson({
        'fee_sats': 1,
        'fee_display': '1 sat',
        'recipients': [
          {'address': 'tlq1…', 'asset_id': null, 'ticker': null, 'amount_sats': null}
        ],
        'sigs_have': 1,
        'sigs_needed': 1,
        'signers_present': ['73c5da0a'],
        'signers_missing': [],
        'can_finalize': true,
        'raw_pset': 'x',
      });
      expect(p.network, 'liquid-testnet');
      expect(p.inputs, isEmpty);
      expect(p.outputs, isEmpty);
      expect(p.touchesEscrow, isFalse);
      expect(p.recipients.single.address, 'tlq1…');
    });
  });
}
