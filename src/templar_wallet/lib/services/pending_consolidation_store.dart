import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../features/utxos/models/pending_consolidation.dart';

/// Persists in-flight consolidations across navigation and app restarts.
///
/// A consolidation confirms in minutes to hours. Holding it only in screen
/// state would drop the placeholder the moment the user left the UTXO page,
/// and the spent coins would reappear as if nothing had happened.
class PendingConsolidationStore {
  PendingConsolidationStore._();
  static final instance = PendingConsolidationStore._();

  static const _key = 'pending_consolidations_v1';

  Future<List<PendingConsolidation>> _all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(PendingConsolidation.fromJson)
          .whereType<PendingConsolidation>()
          .toList();
    } on FormatException {
      // Corrupt entry must never block the UTXO screen from loading.
      return [];
    }
  }

  Future<void> _write(List<PendingConsolidation> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(items.map((p) => p.toJson()).toList()),
    );
  }

  /// Live consolidations for one wallet and chain, stale ones dropped.
  Future<List<PendingConsolidation>> listFor({
    required String walletId,
    required String chain,
  }) async {
    final all = await _all();
    final fresh = all.where((p) => !p.isStale).toList();
    if (fresh.length != all.length) await _write(fresh);
    return fresh
        .where((p) => p.walletId == walletId && p.chain == chain)
        .toList();
  }

  /// Every live consolidation for one wallet, both chains.
  ///
  /// Activity and Home show a broadcast consolidation before any node has
  /// it — neither of them has a chain switcher tied to the UTXO page, so they
  /// filter by wallet only.
  Future<List<PendingConsolidation>> listAllFor(String walletId) async {
    final all = await _all();
    final fresh = all.where((p) => !p.isStale).toList();
    if (fresh.length != all.length) await _write(fresh);
    return fresh.where((p) => p.walletId == walletId).toList();
  }

  Future<void> add(PendingConsolidation pending) async {
    final all = await _all();
    all.removeWhere((p) => p.txid == pending.txid);
    all.add(pending);
    await _write(all);
  }

  Future<void> remove(String txid) async {
    final all = await _all();
    final kept = all.where((p) => p.txid != txid).toList();
    if (kept.length != all.length) await _write(kept);
  }
}
