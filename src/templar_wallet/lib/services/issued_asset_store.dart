import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class IssuedAssetEntry {
  final String assetId;
  final String name;
  final String ticker;
  final String? tokenId;
  final int precision;
  final String domain;
  final bool registered;

  const IssuedAssetEntry({
    required this.assetId,
    required this.name,
    required this.ticker,
    this.tokenId,
    this.precision = 8,
    this.domain = '',
    this.registered = false,
  });

  /// Whether this entry carries enough contract data to rebuild and re-submit
  /// the registry contract. Entries saved before precision/domain were
  /// persisted have an empty domain and cannot be re-registered from here.
  bool get canReregister => !registered && domain.isNotEmpty;
}

/// Persists issued asset metadata and hidden-token preferences using SharedPreferences.
/// All data is scoped per wallet ID to prevent cross-wallet leakage.
class IssuedAssetStore {
  static final IssuedAssetStore instance = IssuedAssetStore._();
  IssuedAssetStore._();

  String _issuedKey(String walletId) => 'issued_assets_v2_$walletId';
  static const _hiddenKey = 'hidden_assets_v1';

  // ── Issued assets ────────────────────────────────────────────────────────

  Future<void> saveIssuedAsset(String walletId, IssuedAssetEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_issuedKey(walletId)) ?? '{}';
    final map = jsonDecode(raw) as Map<String, dynamic>;
    map[entry.assetId] = {
      'name': entry.name,
      'ticker': entry.ticker,
      'token_id': entry.tokenId,
      'precision': entry.precision,
      'domain': entry.domain,
      'registered': entry.registered,
    };
    await prefs.setString(_issuedKey(walletId), jsonEncode(map));
  }

  /// Flags an issued asset as registered in the Liquid asset registry.
  /// No-op if the asset is unknown for this wallet.
  Future<void> markRegistered(String walletId, String assetId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_issuedKey(walletId)) ?? '{}';
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final entry = map[assetId];
    if (entry is Map<String, dynamic>) {
      entry['registered'] = true;
      await prefs.setString(_issuedKey(walletId), jsonEncode(map));
    }
  }

  Future<Map<String, IssuedAssetEntry>> getIssuedAssets(String walletId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_issuedKey(walletId)) ?? '{}';
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final kv in map.entries)
        kv.key: IssuedAssetEntry(
          assetId: kv.key,
          name: (kv.value as Map<String, dynamic>)['name'] as String? ?? '',
          ticker: (kv.value as Map<String, dynamic>)['ticker'] as String? ?? '',
          tokenId: (kv.value as Map<String, dynamic>)['token_id'] as String?,
          precision:
              (kv.value as Map<String, dynamic>)['precision'] as int? ?? 8,
          domain: (kv.value as Map<String, dynamic>)['domain'] as String? ?? '',
          registered:
              (kv.value as Map<String, dynamic>)['registered'] as bool? ?? false,
        ),
    };
  }

  // ── Hidden assets ────────────────────────────────────────────────────────

  Future<void> hideAsset(String assetId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_hiddenKey) ?? [];
    if (!list.contains(assetId)) {
      await prefs.setStringList(_hiddenKey, [...list, assetId]);
    }
  }

  Future<void> unhideAsset(String assetId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_hiddenKey) ?? [];
    await prefs.setStringList(_hiddenKey, list..remove(assetId));
  }

  Future<List<String>> getHiddenAssets() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_hiddenKey) ?? [];
  }
}
