// Templar Protocol's local memory: which sites hold a watch-only view, what
// signing requests were answered, and which wallet to offer first.
//
// SharedPreferences, like the co-signer labels and the issued-asset list —
// nothing here is a secret, so nothing here belongs in the vault or the
// keychain. Two consequences the UI states out loud: the records do not
// travel to another machine and are not in a backup, and forgetting a site
// removes only this side of the connection — the site keeps the descriptor
// until the wallet is removed there.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../features/protocol/models/protocol_records.dart';

class ProtocolStore {
  static final ProtocolStore instance = ProtocolStore._();
  ProtocolStore._();

  static const _sitesKey = 'protocol_sites_v1';
  static const _historyKey = 'protocol_history_v1';
  static const _preferredKey = 'protocol_preferred_wallet_v1';

  /// How many signing requests are kept. Old enough to answer "did I sign
  /// that", short enough that the list stays readable and small.
  static const int historyLimit = 50;

  List<ProtocolConnectedSite>? _sites;
  List<ProtocolSignRecord>? _history;

  // ── Connected sites ─────────────────────────────────────────────────────────

  Future<List<ProtocolConnectedSite>> sites() async {
    final cached = _sites;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final out = _newestFirst(
        _decode(prefs.getString(_sitesKey), ProtocolConnectedSite.fromJson),
        (s) => s.connectedAt);
    _sites = out;
    return out;
  }

  /// What is already in memory, for a build that cannot await.
  List<ProtocolConnectedSite>? peekSites() => _sites;

  /// Records a completed connect. One entry per site and wallet: connecting
  /// the same pair again is the same relationship, with a newer date.
  Future<void> recordConnect(ProtocolConnectedSite site) async {
    final all = [...await sites()]
      ..removeWhere((s) => s.key == site.key)
      ..insert(0, site);
    await _writeSites(all);
  }

  /// Drops the local record. The site is not told: nothing in the protocol
  /// revokes a descriptor, which is why the UI says so plainly.
  Future<void> forgetSite(String key) async {
    final all = [...await sites()]..removeWhere((s) => s.key == key);
    await _writeSites(all);
  }

  Future<void> _writeSites(List<ProtocolConnectedSite> all) async {
    _sites = all;
    final prefs = await SharedPreferences.getInstance();
    if (all.isEmpty) {
      await prefs.remove(_sitesKey);
      return;
    }
    await prefs.setString(
        _sitesKey, jsonEncode(all.map((s) => s.toJson()).toList()));
  }

  // ── Signing history ─────────────────────────────────────────────────────────

  Future<List<ProtocolSignRecord>> history() async {
    final cached = _history;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final out = _newestFirst(
        _decode(prefs.getString(_historyKey), ProtocolSignRecord.fromJson),
        (r) => r.at);
    _history = out.take(historyLimit).toList();
    return _history!;
  }

  List<ProtocolSignRecord>? peekHistory() => _history;

  Future<void> recordSign(ProtocolSignRecord record) async {
    final all = [record, ...await history()].take(historyLimit).toList();
    _history = all;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _historyKey, jsonEncode(all.map((r) => r.toJson()).toList()));
  }

  Future<void> clearHistory() async {
    _history = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  // ── Preferred wallet ────────────────────────────────────────────────────────

  /// The wallet a request opens with. A preference, never a decision: the
  /// confirm gate still runs, and a connect request still asks which wallet
  /// the site should know.
  Future<String?> preferredWalletId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_preferredKey);
    return (id == null || id.isEmpty) ? null : id;
  }

  Future<void> setPreferredWalletId(String? walletId) async {
    final prefs = await SharedPreferences.getInstance();
    if (walletId == null || walletId.isEmpty) {
      await prefs.remove(_preferredKey);
      return;
    }
    await prefs.setString(_preferredKey, walletId);
  }

  /// Everything about one wallet, when it is deleted.
  Future<void> forgetWallet(String walletId) async {
    final all = [...await sites()]..removeWhere((s) => s.walletId == walletId);
    await _writeSites(all);
    if (await preferredWalletId() == walletId) {
      await setPreferredWalletId(null);
    }
  }

  /// Test seam: drops the in-memory copies so the next read hits prefs.
  void resetCacheForTest() {
    _sites = null;
    _history = null;
  }

  /// Newest first, keeping the written order where two records share a
  /// timestamp — `List.sort` is not stable, and two requests answered in the
  /// same second would otherwise swap places on every read.
  static List<T> _newestFirst<T>(List<T> items, DateTime Function(T) when) {
    final indexed = List.generate(items.length, (i) => (i, items[i]));
    indexed.sort((a, b) {
      final c = when(b.$2).compareTo(when(a.$2));
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  static List<T> _decode<T>(String? raw, T? Function(Map<String, dynamic>) one) {
    if (raw == null || raw.isEmpty) return <T>[];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return <T>[];
      return list
          .whereType<Map<String, dynamic>>()
          .map(one)
          .whereType<T>()
          .toList();
    } catch (_) {
      // A corrupt entry costs the history, never access to the wallet.
      return <T>[];
    }
  }
}
