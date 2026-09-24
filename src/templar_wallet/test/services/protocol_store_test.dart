// What Templar Protocol remembers between runs, and what it deliberately
// forgets. SharedPreferences is mocked; the store's in-memory copy is reset
// between tests so each one really goes through the encode/decode path.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:templar_wallet/features/protocol/models/protocol_records.dart';
import 'package:templar_wallet/services/protocol_store.dart';

ProtocolConnectedSite _site({
  String origin = 'https://protocol.example',
  String walletId = 'w1',
  String name = 'Templar Protocol demo',
  DateTime? at,
}) =>
    ProtocolConnectedSite(
      site: name,
      origin: origin,
      network: 'liquid-regtest',
      walletId: walletId,
      walletName: 'Alice',
      connectedAt: at ?? DateTime.utc(2026, 9, 17, 10),
      escrowFingerprint: '73c5da0a',
      receiveAddress: 'el1qq0000',
    );

ProtocolSignRecord _sign({
  String loanRef = 'SQ-42',
  ProtocolSignOutcome outcome = ProtocolSignOutcome.signed,
  DateTime? at,
}) =>
    ProtocolSignRecord(
      site: 'Templar Protocol demo',
      origin: 'https://protocol.example',
      walletName: 'Alice',
      at: at ?? DateTime.utc(2026, 9, 17, 11),
      outcome: outcome,
      loanRef: loanRef,
      action: 'origination',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ProtocolStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store.resetCacheForTest();
    await store.setPreferredWalletId(null);
  });

  group('connected sites', () {
    test('a connection survives a restart', () async {
      await store.recordConnect(_site());
      store.resetCacheForTest();

      final sites = await store.sites();
      expect(sites, hasLength(1));
      expect(sites.single.site, 'Templar Protocol demo');
      expect(sites.single.origin, 'https://protocol.example');
      expect(sites.single.walletName, 'Alice');
      expect(sites.single.escrowFingerprint, '73c5da0a');
      expect(sites.single.connectedAt, DateTime.utc(2026, 9, 17, 10));
    });

    test('the same site and wallet is one record, with the newer date',
        () async {
      await store.recordConnect(_site());
      await store.recordConnect(_site(at: DateTime.utc(2026, 9, 18, 9)));
      expect(await store.sites(), hasLength(1));
      expect((await store.sites()).single.connectedAt,
          DateTime.utc(2026, 9, 18, 9));

      // Another wallet on the same site is a different relationship.
      await store.recordConnect(_site(walletId: 'w2'));
      expect(await store.sites(), hasLength(2));
    });

    test('forget removes one record and leaves the rest', () async {
      await store.recordConnect(_site());
      await store.recordConnect(_site(origin: 'https://other.example'));
      await store.forgetSite(_site().key);
      store.resetCacheForTest();

      final left = await store.sites();
      expect(left, hasLength(1));
      expect(left.single.origin, 'https://other.example');
    });

    test('deleting a wallet takes its sites and its preference with it',
        () async {
      await store.recordConnect(_site(walletId: 'w1'));
      await store.recordConnect(_site(walletId: 'w2'));
      await store.setPreferredWalletId('w1');

      await store.forgetWallet('w1');
      expect((await store.sites()).single.walletId, 'w2');
      expect(await store.preferredWalletId(), isNull);

      // A preference for a wallet that stayed is left alone.
      await store.setPreferredWalletId('w2');
      await store.forgetWallet('w3');
      expect(await store.preferredWalletId(), 'w2');
    });
  });

  group('signing history', () {
    test('newest first, and it survives a restart', () async {
      await store.recordSign(_sign(loanRef: 'SQ-1'));
      await store.recordSign(_sign(loanRef: 'SQ-2'));
      store.resetCacheForTest();

      final all = await store.history();
      expect(all.map((r) => r.loanRef), ['SQ-2', 'SQ-1']);
      expect(all.first.outcome, ProtocolSignOutcome.signed);
    });

    test('every outcome round-trips', () async {
      for (final o in ProtocolSignOutcome.values) {
        await store.recordSign(_sign(outcome: o));
      }
      store.resetCacheForTest();
      expect((await store.history()).map((r) => r.outcome).toSet(),
          ProtocolSignOutcome.values.toSet());
    });

    test('only the last 50 are kept', () async {
      for (var i = 0; i < 60; i++) {
        await store.recordSign(_sign(loanRef: 'SQ-$i'));
      }
      store.resetCacheForTest();

      final all = await store.history();
      expect(all, hasLength(ProtocolStore.historyLimit));
      expect(all.first.loanRef, 'SQ-59');
      expect(all.last.loanRef, 'SQ-10');
    });

    test('clearing empties it on disk too', () async {
      await store.recordSign(_sign());
      await store.clearHistory();
      store.resetCacheForTest();
      expect(await store.history(), isEmpty);
    });
  });

  group('preferred wallet', () {
    test('is remembered, and clearable', () async {
      expect(await store.preferredWalletId(), isNull);
      await store.setPreferredWalletId('w1');
      expect(await store.preferredWalletId(), 'w1');
      await store.setPreferredWalletId(null);
      expect(await store.preferredWalletId(), isNull);
      await store.setPreferredWalletId('');
      expect(await store.preferredWalletId(), isNull);
    });
  });

  group('what a record holds', () {
    test('no PSET, no amounts, no descriptor reach the JSON', () async {
      await store.recordConnect(_site());
      await store.recordSign(_sign());
      final prefs = await SharedPreferences.getInstance();
      final blob = '${prefs.getString('protocol_sites_v1')}'
          '${prefs.getString('protocol_history_v1')}';
      // The connect record says *that* a descriptor was shared; neither the
      // descriptor nor a key, an amount or a PSET is written down.
      for (final forbidden in ['pset', 'ct(', 'tpub', 'xpub', 'amount']) {
        expect(blob.toLowerCase(), isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('a corrupt entry costs the list, not the app', () async {
      SharedPreferences.setMockInitialValues({
        'protocol_sites_v1': 'not json',
        'protocol_history_v1': '[{"no":"fields"}]',
      });
      store.resetCacheForTest();
      expect(await store.sites(), isEmpty);
      expect(await store.history(), isEmpty);
    });

    test('an escrow fingerprint is read from a keyorigin key, never guessed',
        () {
      expect(protocolKeyFingerprint("[73c5da0a/2121h/1h/0h]tpubDX"), '73c5da0a');
      expect(protocolKeyFingerprint("[73C5DA0A/2121'/1'/0']tpubDX"), '73c5da0a');
      expect(protocolKeyFingerprint('tpubDXnokeyorigin'), '');
      expect(protocolKeyFingerprint('[nothex/2121h]tpubDX'), '');
      expect(protocolKeyFingerprint(null), '');
    });
  });
}
