/// Conversions between what is typed into an amount field and satoshis.
///
/// Pure functions, no widgets: the Send screen calls them and the tests pin
/// them down. A decimal comma is accepted everywhere — a phone's numeric
/// keyboard offers the locale's separator, and "0,001" typed on an Italian
/// keyboard is an amount, not a typo.
abstract final class AmountUnits {
  /// A non-negative decimal, or null when [text] is not one.
  static double? parseDecimal(String text) {
    final t = text.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    final v = double.tryParse(t);
    if (v == null || v.isNaN || v.isInfinite || v < 0) return null;
    return v;
  }

  /// "0.00123456" (BTC or L-BTC) → satoshis.
  static int? satsFromCoin(String text) {
    final v = parseDecimal(text);
    if (v == null) return null;
    return (v * 1e8).round();
  }

  /// "98.40" in the selected fiat → satoshis at [btcPrice] (fiat per BTC).
  /// Null with no price: a fiat amount cannot be resolved without one.
  static int? satsFromFiat(String text, double btcPrice) {
    if (btcPrice <= 0) return null;
    final v = parseDecimal(text);
    if (v == null) return null;
    return (v / btcPrice * 1e8).round();
  }

  /// Satoshis as the coin figure the field would hold, 8 decimals.
  static String coinText(int sats) => (sats / 1e8).toStringAsFixed(8);

  /// Satoshis as the fiat figure the field would hold, 2 decimals.
  static String fiatText(int sats, double btcPrice) =>
      (sats / 1e8 * btcPrice).toStringAsFixed(2);

  /// The same amount re-expressed in the other unit, for the ⇅ toggle.
  /// Empty stays empty; a text that does not parse (or no price) returns
  /// null so the caller can leave the field alone.
  static String? convert(
    String text, {
    required bool toFiat,
    required double btcPrice,
  }) {
    if (text.trim().isEmpty) return '';
    if (btcPrice <= 0) return null;
    final sats = toFiat ? satsFromCoin(text) : satsFromFiat(text, btcPrice);
    if (sats == null) return null;
    return toFiat ? fiatText(sats, btcPrice) : coinText(sats);
  }
}
