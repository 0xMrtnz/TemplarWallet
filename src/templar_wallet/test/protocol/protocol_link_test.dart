import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/protocol/models/protocol_link.dart';

void main() {
  final now = DateTime.utc(2026, 9, 3, 12);
  final future = now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  final past = now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000;

  Map<String, dynamic> connectJson({
    String network = 'liquid-regtest',
    String callback = 'https://host/wallet/connect/tok',
    String nonce = 'n1',
    int? expires,
    int version = 1,
    String kind = 'connect',
    Object? policyAsset,
  }) =>
      {
        'version': version,
        'kind': kind,
        'site': 'Templar Protocol demo',
        'network': network,
        'nonce': nonce,
        'callback': callback,
        'expires_at': expires ?? future,
        'policy_asset': ?policyAsset,
      };

  // Two regtest chains: the stock liquidregtest asset and one a node of its
  // own made.
  const stockAsset =
      '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225';
  const otherAsset =
      'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';

  Map<String, dynamic> signJson({String callback = 'https://host/wallet/requests/req_1/signed'}) => {
        ...connectJson(kind: 'sign', callback: callback),
        'id': 'req_1',
        'action': 'origination',
        'loan_ref': 'SQ-42',
        'summary': {
          'role': 'borrower',
          'lines': [
            {'label': 'You receive', 'amount': '10,000 tUSDt'},
            {'label': 'Collateral locked', 'amount': '0.01000000 tLBTC'},
          ],
        },
        'pset': 'cHNldP8B',
        'escrow': {'descriptor': 'ct(slip77(…),elwsh(or_d(…)))', 'address': 'el1qq…'},
      };

  group('ProtocolLink.parse', () {
    test('parses connect and sign links', () {
      final c = ProtocolLink.parse(
          'templar://connect?url=https%3A%2F%2Fhost%2Fwallet%2Fconnect%2Ftok&nonce=n1');
      expect(c.action, ProtocolAction.connect);
      expect(c.url.toString(), 'https://host/wallet/connect/tok');
      expect(c.nonce, 'n1');
      expect(c.origin, 'https://host:443');
      expect(c.isLocal, isFalse);

      final s = ProtocolLink.parse('templar://sign?url=http://127.0.0.1:8087/wallet/requests/1&nonce=x');
      expect(s.action, ProtocolAction.sign);
      expect(s.isLocal, isTrue);
      expect(s.origin, 'http://127.0.0.1:8087');
    });

    test('accepts the path form and is case-insensitive on the action', () {
      final l = ProtocolLink.parse('templar:///Connect?url=https://h/x&nonce=n');
      expect(l.action, ProtocolAction.connect);
    });

    test('rejects other schemes, unknown actions and missing parts', () {
      expect(() => ProtocolLink.parse('https://host/x'), throwsA(isA<ProtocolLinkError>()));
      expect(() => ProtocolLink.parse('templar://pay?url=https://h&nonce=n'),
          throwsA(isA<ProtocolLinkError>()));
      expect(() => ProtocolLink.parse('templar://connect?nonce=n'), throwsA(isA<ProtocolLinkError>()));
      expect(() => ProtocolLink.parse('templar://connect?url=https://h/x'),
          throwsA(isA<ProtocolLinkError>()));
      expect(() => ProtocolLink.parse('templar://connect?url=ftp://h/x&nonce=n'),
          throwsA(isA<ProtocolLinkError>()));
      expect(() => ProtocolLink.parse('not a link at all ://'), throwsA(isA<ProtocolLinkError>()));
    });
  });

  group('ProtocolRequest.fromJson', () {
    test('decodes a sign request with summary and escrow', () {
      final r = ProtocolRequest.fromJson(signJson());
      expect(r.kind, 'sign');
      expect(r.id, 'req_1');
      expect(r.actionLabel, 'Loan origination');
      expect(r.summary!.role, 'borrower');
      expect(r.summary!.lines.length, 2);
      expect(r.summary!.lines.first.label, 'You receive');
      expect(r.escrow!.address, 'el1qq…');
      expect(r.pset, 'cHNldP8B');
    });

    test('names the missing field', () {
      final j = connectJson()..remove('callback');
      expect(
        () => ProtocolRequest.fromJson(j),
        throwsA(predicate((e) => e.toString().contains('"callback"'))),
      );
      expect(() => ProtocolRequest.fromJson({'kind': 'connect'}),
          throwsA(isA<ProtocolLinkError>()));
    });

    test('falls back to the callback host as site name', () {
      final j = connectJson()..remove('site');
      expect(ProtocolRequest.fromJson(j).site, 'host');
    });

    test('reads the regtest policy asset, and drops a malformed one', () {
      expect(ProtocolRequest.fromJson(connectJson()).policyAsset, isNull);
      expect(
          ProtocolRequest.fromJson(connectJson(policyAsset: stockAsset.toUpperCase()))
              .policyAsset,
          stockAsset);
      for (final bad in ['', 'not hex', '5ac9f6', 42]) {
        expect(ProtocolRequest.fromJson(connectJson(policyAsset: bad)).policyAsset,
            isNull,
            reason: '$bad');
      }
    });
  });

  group('validateProtocolRequest', () {
    final connect = ProtocolLink.parse(
        'templar://connect?url=https://host/wallet/connect/tok&nonce=n1');

    void check(Map<String, dynamic> json,
        {ProtocolLink? link, String network = 'liquid-regtest', String? policyAsset}) {
      validateProtocolRequest(link ?? connect, ProtocolRequest.fromJson(json),
          activeNetwork: network, activePolicyAsset: policyAsset, now: now);
    }

    String reason(Map<String, dynamic> json,
        {ProtocolLink? link, String network = 'liquid-regtest', String? policyAsset}) {
      try {
        check(json, link: link, network: network, policyAsset: policyAsset);
      } on ProtocolLinkError catch (e) {
        return e.message;
      }
      return '';
    }

    ProtocolNetworkMismatch mismatch(Map<String, dynamic> json,
        {ProtocolLink? link, String network = 'liquid-regtest', String? policyAsset}) {
      try {
        check(json, link: link, network: network, policyAsset: policyAsset);
      } on ProtocolNetworkMismatch catch (e) {
        return e;
      }
      fail('expected a ProtocolNetworkMismatch');
    }

    test('a good connect request passes', () {
      check(connectJson());
    });

    test('a good sign request passes', () {
      final link = ProtocolLink.parse(
          'templar://sign?url=https://host/wallet/requests/req_1&nonce=n1');
      check(signJson(), link: link);
    });

    test('rejects the wrong protocol version', () {
      expect(reason(connectJson(version: 2)), contains('version 2'));
    });

    test('rejects a kind that does not match the link', () {
      expect(reason(connectJson(kind: 'sign')), contains('asks to connect'));
    });

    test('rejects a nonce that changed', () {
      expect(reason(connectJson(nonce: 'other')), contains('nonce'));
    });

    test('rejects a network mismatch, naming both sides', () {
      final r = reason(connectJson(network: 'liquid-testnet'));
      expect(r, contains('Liquid testnet'));
      expect(r, contains('Liquid regtest'));
    });

    test('a network mismatch is typed, and switchable both ways', () {
      final m = mismatch(connectJson(network: 'liquid-testnet'));
      expect(m, isA<ProtocolLinkError>());
      expect(m.kind, ProtocolMismatchKind.network);
      expect(m.siteNetwork, 'liquid-testnet');
      expect(m.walletNetwork, 'liquid-regtest');
      expect(m.canSwitch, isTrue);
      expect(m.targetShortName, 'testnet');
      // Nothing to choose on testnet.
      expect(m.policyAssetFor(stockAsset), isNull);

      final back = mismatch(connectJson(network: 'liquid-regtest'),
          network: 'liquid-testnet');
      expect(back.targetShortName, 'regtest');
      expect(back.policyAssetFor(stockAsset), stockAsset);
    });

    test('the site\'s policy asset is the one the switch would use', () {
      final m = mismatch(
          connectJson(network: 'liquid-regtest', policyAsset: otherAsset),
          network: 'liquid-testnet');
      expect(m.sitePolicyAsset, otherAsset);
      expect(m.policyAssetFor(stockAsset), otherAsset);
    });

    test('same network, different chain is a mismatch of its own', () {
      final m = mismatch(connectJson(policyAsset: otherAsset),
          policyAsset: stockAsset);
      expect(m.kind, ProtocolMismatchKind.chain);
      expect(m.canSwitch, isTrue);
      expect(m.targetShortName, 'regtest');
      expect(m.policyAssetFor(stockAsset), otherAsset);
      // Both ids are named, short enough to read.
      expect(m.message, contains('a1b2…8f90'));
      expect(m.message, contains('5ac9…b225'));
    });

    test('the same regtest chain passes, whatever the case', () {
      check(connectJson(policyAsset: otherAsset), policyAsset: otherAsset);
      check(connectJson(policyAsset: otherAsset),
          policyAsset: otherAsset.toUpperCase());
      // Nothing known on one side: no chain claim to contradict.
      check(connectJson(policyAsset: otherAsset));
      check(connectJson(), policyAsset: stockAsset);
    });

    test('a network this build does not run offers no switch', () {
      for (final name in ['liquid', 'mock', 'bitcoin-signet']) {
        final m = mismatch(connectJson(network: name));
        expect(m.kind, ProtocolMismatchKind.unsupported, reason: name);
        expect(m.canSwitch, isFalse, reason: name);
        expect(m.targetShortName, isNull, reason: name);
        expect(m.policyAssetFor(stockAsset), isNull, reason: name);
      }
      expect(reason(connectJson(network: 'liquid')), contains('Liquid mainnet'));
      expect(reason(connectJson(network: 'mock')), contains('"mock"'));
    });

    test('rejects a callback on another origin', () {
      expect(reason(connectJson(callback: 'https://evil/wallet/connect/tok')),
          contains('different host'));
      // Same host, other port: still a different origin.
      expect(reason(connectJson(callback: 'https://host:8443/x')),
          contains('different host'));
    });

    test('requires https unless the host is local', () {
      final plain = ProtocolLink.parse('templar://connect?url=http://host/wallet/connect/tok&nonce=n1');
      expect(reason(connectJson(callback: 'http://host/wallet/connect/tok'), link: plain),
          contains('plain http'));
      final local = ProtocolLink.parse(
          'templar://connect?url=http://127.0.0.1:8087/wallet/connect/tok&nonce=n1');
      check(connectJson(callback: 'http://127.0.0.1:8087/wallet/connect/tok'), link: local);
      final localhost = ProtocolLink.parse(
          'templar://connect?url=http://localhost:8087/wallet/connect/tok&nonce=n1');
      check(connectJson(callback: 'http://localhost:8087/wallet/connect/tok'), link: localhost);
    });

    test('rejects an expired request', () {
      expect(reason(connectJson(expires: past)), contains('expired'));
    });

    test('a sign request needs an id and a PSET', () {
      final link = ProtocolLink.parse(
          'templar://sign?url=https://host/wallet/requests/req_1&nonce=n1');
      final noPset = signJson()..remove('pset');
      expect(reason(noPset, link: link), contains('no PSET'));
      final noId = signJson()..remove('id');
      expect(reason(noId, link: link), contains('no id'));
    });
  });
}
