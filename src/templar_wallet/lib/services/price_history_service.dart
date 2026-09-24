import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'price_service.dart';

/// One historical BTC price sample.
class PricePoint {
  final DateTime time;
  final double price;
  const PricePoint(this.time, this.price);
}

/// Fetches historical BTC prices from CoinGecko for the portfolio chart.
/// Caches per (currency, range) in SharedPreferences and serves the cached
/// series while revalidating in the background — the UI never waits on the
/// network once a range has been loaded.
class PriceHistoryService extends ChangeNotifier {
  PriceHistoryService._();
  static final PriceHistoryService instance = PriceHistoryService._();

  /// Value to pass as `days` for the "All" range (CoinGecko `days=max`).
  /// Any non-positive value is treated the same way.
  static const int allDays = 0;

  static const _baseUrl =
      'https://api.coingecko.com/api/v3/coins/bitcoin/market_chart';

  /// Intraday data moves fast; multi-day series are daily/hourly candles.
  static const _intradayCacheDuration = Duration(minutes: 10);
  static const _cacheDuration = Duration(hours: 1);

  final Map<String, _Series> _memory = {};
  final Map<String, Future<List<PricePoint>?>> _inFlight = {};

  bool _lastFetchFailed = false;
  bool get lastFetchFailed => _lastFetchFailed;

  /// Daily (or hourly for short ranges) BTC price in [currency], oldest→newest.
  /// Returns the cached series while a refresh runs, and `[]` when nothing is
  /// available (first run offline, rate-limited). Never throws.
  Future<List<PricePoint>> series({
    required String currency,
    required int days,
  }) async {
    final key = _cacheKey(currency, days);
    final cached = _memory[key] ?? await _load(key);
    if (cached != null) _memory[key] = cached;

    final ttl = days == 1 ? _intradayCacheDuration : _cacheDuration;
    final fresh =
        cached != null && DateTime.now().difference(cached.fetchedAt) < ttl;

    if (cached != null && (fresh || cached.points.isNotEmpty)) {
      if (!fresh) unawaited(_refresh(currency, days, key));
      return cached.points;
    }
    final fetched = await _refresh(currency, days, key);
    return fetched ?? cached?.points ?? const <PricePoint>[];
  }

  /// Price at [t] by nearest-earlier sample. Falls back to the current spot
  /// price when [series] is empty or [t] precedes its first sample (and to the
  /// first sample when the spot price is not loaded yet).
  double priceAt(DateTime t, List<PricePoint> series) {
    if (series.isEmpty) return PriceService.instance.btcPrice;
    if (t.isBefore(series.first.time)) {
      final spot = PriceService.instance.btcPrice;
      return spot > 0 ? spot : series.first.price;
    }
    // series is sorted ascending — find the last sample at or before t.
    var lo = 0;
    var hi = series.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (series[mid].time.isAfter(t)) {
        hi = mid - 1;
      } else {
        lo = mid;
      }
    }
    return series[lo].price;
  }

  // ── Fetch ──────────────────────────────────────────────────────────────────

  /// Coalesces concurrent refreshes of the same (currency, range).
  Future<List<PricePoint>?> _refresh(String currency, int days, String key) {
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final f = _fetch(currency, days, key);
    _inFlight[key] = f;
    return f.whenComplete(() => _inFlight.remove(key));
  }

  Future<List<PricePoint>?> _fetch(String currency, int days, String key) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl?vs_currency=${currency.toLowerCase()}&days=${_daysParam(days)}',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return _failed();
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final points = _parse(data['prices']);
      if (points.isEmpty) return _failed();

      final entry = _Series(points, DateTime.now());
      _memory[key] = entry;
      _lastFetchFailed = false;
      await _save(key, entry);
      notifyListeners();
      return points;
    } catch (_) {
      // Offline / rate-limited / malformed body — cached data stays served.
      return _failed();
    }
  }

  List<PricePoint>? _failed() {
    if (!_lastFetchFailed) {
      _lastFetchFailed = true;
      notifyListeners();
    }
    return null;
  }

  /// `[[unixMillis, price], ...]` → sorted samples. Skips malformed entries.
  static List<PricePoint> _parse(dynamic raw) {
    if (raw is! List) return const [];
    final points = <PricePoint>[];
    for (final row in raw) {
      if (row is! List || row.length < 2) continue;
      final ms = (row[0] as num?)?.toInt();
      final price = (row[1] as num?)?.toDouble();
      if (ms == null || price == null || price <= 0) continue;
      points.add(PricePoint(DateTime.fromMillisecondsSinceEpoch(ms), price));
    }
    points.sort((a, b) => a.time.compareTo(b.time));
    return points;
  }

  // ── Cache ──────────────────────────────────────────────────────────────────

  static String _daysParam(int days) => days > 0 ? '$days' : 'max';

  static String _cacheKey(String currency, int days) =>
      'price_history_v1_${currency.toUpperCase()}_${_daysParam(days)}';

  Future<_Series?> _load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final map = json.decode(raw) as Map<String, dynamic>;
      final fetchedAt = (map['fetched_at'] as num?)?.toInt();
      if (fetchedAt == null) return null;
      return _Series(
        _parse(map['points']),
        DateTime.fromMillisecondsSinceEpoch(fetchedAt),
      );
    } catch (_) {
      return null; // corrupt entry — treat as a cache miss
    }
  }

  Future<void> _save(String key, _Series entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        json.encode({
          'fetched_at': entry.fetchedAt.millisecondsSinceEpoch,
          'points': [
            for (final p in entry.points)
              [p.time.millisecondsSinceEpoch, p.price],
          ],
        }),
      );
    } catch (_) {
      // Persistence is best-effort; the in-memory series is already usable.
    }
  }
}

class _Series {
  final List<PricePoint> points;
  final DateTime fetchedAt;
  const _Series(this.points, this.fetchedAt);
}
