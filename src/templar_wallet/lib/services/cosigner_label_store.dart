// Per-wallet co-signer labels, kept on this device.
//
// Same home as the wallet's own name override and accent colour
// ([WalletCustomizationStore]): SharedPreferences, not the encrypted registry.
// That is a deliberate limit — labels are local, so they do not travel to
// another machine, are not in a backup, and are not part of anything the
// wallet exports. Nothing about spending depends on them.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../shared/models/cosigner_label.dart';

class CosignerLabelStore {
  static final CosignerLabelStore instance = CosignerLabelStore._();
  CosignerLabelStore._();

  static const _prefix = 'cosigner_labels_v1_';

  /// In-memory copy so a rebuild does not wait on disk. Written through on
  /// every save, dropped when the wallet is deleted.
  final Map<String, Map<String, CosignerLabel>> _cache = {};

  /// Labels for [walletId], keyed by [cosignerId].
  Future<Map<String, CosignerLabel>> load(String walletId) async {
    final cached = _cache[walletId];
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$walletId');
    final out = <String, CosignerLabel>{};
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in m.entries) {
          out[e.key] =
              CosignerLabel.fromJson(e.key, e.value as Map<String, dynamic>);
        }
      } catch (_) {
        // A corrupt entry costs names, never access to the wallet.
      }
    }
    _cache[walletId] = out;
    return out;
  }

  /// Reads what is already in memory, without waiting. Null before the first
  /// [load] — a caller that cannot await should render the fallback names.
  Map<String, CosignerLabel>? peek(String walletId) => _cache[walletId];

  Future<void> save(String walletId, Map<String, CosignerLabel> labels) async {
    // An empty label is the absence of one: keeping it would pin a stale entry
    // to a co-signer forever.
    final kept = {
      for (final e in labels.entries)
        if (!e.value.isEmpty) e.key: e.value,
    };
    _cache[walletId] = kept;
    final prefs = await SharedPreferences.getInstance();
    if (kept.isEmpty) {
      await prefs.remove('$_prefix$walletId');
      return;
    }
    await prefs.setString(
      '$_prefix$walletId',
      jsonEncode({for (final e in kept.entries) e.key: e.value.toJson()}),
    );
  }

  Future<void> saveOne(String walletId, CosignerLabel label) async {
    final all = Map<String, CosignerLabel>.from(await load(walletId));
    all[label.id] = label;
    await save(walletId, all);
  }

  Future<void> delete(String walletId) async {
    _cache.remove(walletId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$walletId');
  }

  /// Test seam: forget everything read so far.
  void clearCache() => _cache.clear();
}
