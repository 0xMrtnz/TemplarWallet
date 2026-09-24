import 'amount_units.dart';

/// What a payment link carries: who is paid, and — when the receiver asked
/// for them — how much and what for.
class PaymentRequest {
  const PaymentRequest({required this.address, this.amountSats, this.label});

  final String address;

  /// The requested amount, null when the link only names an address.
  final int? amountSats;

  /// The receiver's note ("Invoice 12"), null or empty when there is none.
  final String? label;
}

/// BIP21 payment links — the string a Receive QR carries once an amount is
/// asked for, and the string a Send field accepts in place of a bare address.
///
/// Pure text in, pure text out: no widgets, no engine calls, so the round
/// trip can be pinned down by tests (`test/payment_uri_test.dart`).
abstract final class PaymentUri {
  /// Bitcoin's scheme is the same on every network — the address says which
  /// one. Liquid has a scheme per network and this build is testnet-locked.
  static const String bitcoinScheme = 'bitcoin';
  static const String liquidScheme = 'liquidtestnet';

  static const Set<String> _schemes = {bitcoinScheme, liquidScheme};

  /// The scheme a chain answers to, keyed by the asset the Receive screen
  /// names its chains with ('BTC' / 'LBTC').
  static String schemeFor(String asset) =>
      asset == 'BTC' ? bitcoinScheme : liquidScheme;

  /// The link for [address] on [asset]. An amount of null or zero and an
  /// empty label are simply left out — a link with no query is still a valid
  /// BIP21 URI, and every wallet reads it as "pay this address".
  static String build({
    required String address,
    required String asset,
    int? amountSats,
    String? label,
  }) {
    final params = <String>[];
    if (amountSats != null && amountSats > 0) {
      params.add('amount=${amountText(amountSats)}');
    }
    final note = label?.trim() ?? '';
    if (note.isNotEmpty) {
      // Percent-encoding, not form encoding: a '+' means a plus sign to some
      // wallets and a space to others, and %20 means a space to all of them.
      params.add('label=${Uri.encodeComponent(note)}');
    }
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return '${schemeFor(asset)}:$address$query';
  }

  /// The amount as BIP21 spells it: decimal coin, no trailing zeros, so a
  /// request for a tenth of a millibitcoin reads `0.0001` and not
  /// `0.00010000` in every wallet that shows the raw link.
  static String amountText(int sats) {
    var t = AmountUnits.coinText(sats);
    if (!t.contains('.')) return t;
    t = t.replaceFirst(RegExp(r'0+$'), '');
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    return t;
  }

  /// Whether [text] opens with a scheme this wallet reads. Cheap enough to
  /// call from a field's `onChanged` on every keystroke.
  static bool isPaymentUri(String text) {
    final t = text.trim();
    final colon = t.indexOf(':');
    if (colon <= 0) return false;
    return _schemes.contains(t.substring(0, colon).toLowerCase());
  }

  /// Reads a payment link. Null when [text] is not one — a bare address is
  /// not this function's business, and the caller keeps handling it as the
  /// address it is.
  ///
  /// A query it cannot make sense of is dropped rather than fatal: the
  /// address is the part that must survive, and a link whose amount is
  /// gibberish is still a link to that address.
  static PaymentRequest? parse(String text) {
    final t = text.trim();
    if (!isPaymentUri(t)) return null;
    final Uri uri;
    try {
      uri = Uri.parse(t);
    } on FormatException {
      return null;
    }
    final address = uri.path.trim();
    if (address.isEmpty) return null;
    final Map<String, String> params;
    try {
      params = uri.queryParameters;
    } on FormatException {
      return PaymentRequest(address: address);
    }
    final amount = params['amount'];
    final sats = amount == null ? null : AmountUnits.satsFromCoin(amount);
    final label = params['label']?.trim();
    return PaymentRequest(
      address: address,
      amountSats: (sats == null || sats <= 0) ? null : sats,
      label: (label == null || label.isEmpty) ? null : label,
    );
  }
}
