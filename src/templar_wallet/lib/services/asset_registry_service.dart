import 'dart:convert';
import 'package:http/http.dart' as http;
import '../features/dashboard/models/dashboard_data.dart';

class BlockstreamAssetInfo {
  final String assetId;
  final String? name;
  final String? ticker;
  final int? precision;
  final String? domain;
  final bool isConfidential;

  const BlockstreamAssetInfo({
    required this.assetId,
    this.name,
    this.ticker,
    this.precision,
    this.domain,
    this.isConfidential = false,
  });
}

/// Fetches and caches asset metadata from the Blockstream Liquid testnet API.
/// Singleton — call [prefetchAll] at startup and after sync.
class AssetRegistryService {
  static final AssetRegistryService instance = AssetRegistryService._();
  AssetRegistryService._();

  static const _baseUrl = 'https://blockstream.info/liquidtestnet/api/asset';

  final Map<String, BlockstreamAssetInfo> _cache = {};

  BlockstreamAssetInfo? get(String assetId) => _cache[assetId];

  // ── Display helpers ────────────────────────────────────────────────────────

  static bool _isHexId(String s) =>
      s.length >= 32 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

  /// Human-readable name. Falls back to registry → AssetBalance.name →
  /// 'Reissuance Token' (if [isRt]) → 'Unknown Asset'.
  String displayName(AssetBalance a, {bool isRt = false}) {
    final info = _cache[a.assetId];
    if (info?.name != null) return info!.name!;
    if (!_isHexId(a.name) && a.name.isNotEmpty) return a.name;
    return isRt ? 'Reissuance Token' : 'Unknown Asset';
  }

  /// Human-readable ticker. Falls back to registry → AssetBalance.ticker →
  /// 'RT' (if [isRt]) → '—'.
  String displayTicker(AssetBalance a, {bool isRt = false}) {
    final info = _cache[a.assetId];
    if (info?.ticker != null) return info!.ticker!;
    if (!_isHexId(a.ticker) && a.ticker.isNotEmpty) return a.ticker;
    return isRt ? 'RT' : '—';
  }

  /// Fetches metadata for all [assetIds] not already cached.
  Future<void> prefetchAll(List<String> assetIds) async {
    final missing = assetIds.where((id) => !_cache.containsKey(id)).toList();
    if (missing.isEmpty) return;
    await Future.wait(missing.map(_fetch), eagerError: false);
  }

  /// Clears cache (call before re-fetching after sync).
  void clear() => _cache.clear();

  Future<void> _fetch(String assetId) async {
    try {
      final resp = await http
          .get(Uri.parse('$_baseUrl/$assetId'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final entity = json['entity'] as Map<String, dynamic>?;
      _cache[assetId] = BlockstreamAssetInfo(
        assetId: assetId,
        name: json['name'] as String?,
        ticker: json['ticker'] as String?,
        precision: json['precision'] as int?,
        domain: entity?['domain'] as String?,
        isConfidential: json['is_confidential'] as bool? ?? false,
      );
    } catch (_) {
      // Network failure is non-fatal; asset displays with its on-chain ticker
    }
  }
}
