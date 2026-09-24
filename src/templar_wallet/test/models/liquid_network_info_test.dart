import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';

void main() {
  group('LiquidNetworkInfo.fromJson', () {
    test('decodes the get_liquid_network payload', () {
      final info = LiquidNetworkInfo.fromJson({
        'network': 'liquid-regtest',
        'short_name': 'regtest',
        'policy_asset': '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225',
        'backend': 'elements_rpc',
        'backend_description': 'elements-rpc http://127.0.0.1:18884',
        'env_locked': true,
        'regtest_default_policy_asset':
            '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225',
      });
      expect(info.network, 'liquid-regtest');
      expect(info.isRegtest, isTrue);
      expect(info.backend, 'elements_rpc');
      expect(info.envLocked, isTrue);
      expect(info.backendDescription, contains('127.0.0.1'));
    });

    test('missing fields mean testnet, unlocked', () {
      final info = LiquidNetworkInfo.fromJson({});
      expect(info.network, 'liquid-testnet');
      expect(info.shortName, 'testnet');
      expect(info.isRegtest, isFalse);
      expect(info.envLocked, isFalse);
    });
  });
}
