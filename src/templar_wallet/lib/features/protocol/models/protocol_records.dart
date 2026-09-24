/// What the wallet remembers about Templar Protocol, and nothing more.
///
/// Two records, both written on this device only (see `ProtocolStore`):
///
///   * [ProtocolConnectedSite] — a site that holds a watch-only view of one
///     wallet, so the user can see who has one and drop the local entry.
///   * [ProtocolSignRecord] — that a signing request happened and how it ended.
///
/// Deliberately absent: the PSET, the amounts, the site's summary lines, the
/// CT descriptor and the escrow xpub. A history that keeps them is a second
/// copy of the loan on disk with none of its protections; the outcome and the
/// loan reference are enough to answer "did I sign that, and when". The
/// escrow key appears as its fingerprint alone — the same four bytes the
/// signing screen shows — because that is what identifies it in a PSET.
library;

/// How a signing request ended.
enum ProtocolSignOutcome {
  /// Signed and accepted by the site.
  signed,

  /// The user declined at the confirm gate.
  refused,

  /// The request was dead before it could be answered.
  expired,

  /// Signing or the callback failed.
  failed,
}

extension ProtocolSignOutcomeLabel on ProtocolSignOutcome {
  String get label => switch (this) {
        ProtocolSignOutcome.signed => 'Signed',
        ProtocolSignOutcome.refused => 'Refused by you',
        ProtocolSignOutcome.expired => 'Expired',
        ProtocolSignOutcome.failed => 'Failed',
      };

  String get wire => name;

  static ProtocolSignOutcome parse(Object? v) =>
      ProtocolSignOutcome.values.firstWhere((o) => o.name == v,
          orElse: () => ProtocolSignOutcome.failed);
}

/// A site this wallet has shared a watch-only descriptor with.
class ProtocolConnectedSite {
  const ProtocolConnectedSite({
    required this.site,
    required this.origin,
    required this.network,
    required this.walletId,
    required this.walletName,
    required this.connectedAt,
    this.escrowFingerprint = '',
    this.receiveAddress = '',
    this.sharedDescriptor = true,
  });

  /// The site's own name, e.g. `Templar Protocol demo`.
  final String site;

  /// `scheme://host:port` — what actually received the descriptor, and what
  /// makes the record unique together with [walletId].
  final String origin;

  /// `liquid-testnet` | `liquid-regtest` at the time of the connection.
  final String network;
  final String walletId;
  final String walletName;
  final DateTime connectedAt;

  /// The escrow key's fingerprint, not the key.
  final String escrowFingerprint;

  /// The one address handed over, so the user can recognise it on the site.
  final String receiveAddress;

  /// Whether the watch-only CT descriptor went with it (it always does in
  /// v1; the flag keeps the row honest if that ever changes).
  final bool sharedDescriptor;

  /// One record per site and wallet: reconnecting the same pair replaces it.
  String get key => '$origin|$walletId';

  Map<String, dynamic> toJson() => {
        'site': site,
        'origin': origin,
        'network': network,
        'wallet_id': walletId,
        'wallet_name': walletName,
        'at': connectedAt.toUtc().toIso8601String(),
        'escrow_fingerprint': escrowFingerprint,
        'receive_address': receiveAddress,
        'shared_descriptor': sharedDescriptor,
      };

  static ProtocolConnectedSite? fromJson(Map<String, dynamic> j) {
    final origin = (j['origin'] as String?)?.trim() ?? '';
    final walletId = (j['wallet_id'] as String?)?.trim() ?? '';
    if (origin.isEmpty || walletId.isEmpty) return null;
    return ProtocolConnectedSite(
      site: (j['site'] as String?)?.trim().isNotEmpty == true
          ? (j['site'] as String).trim()
          : origin,
      origin: origin,
      network: (j['network'] as String?)?.trim() ?? '',
      walletId: walletId,
      walletName: (j['wallet_name'] as String?)?.trim() ?? '',
      connectedAt: _date(j['at']),
      escrowFingerprint: (j['escrow_fingerprint'] as String?)?.trim() ?? '',
      receiveAddress: (j['receive_address'] as String?)?.trim() ?? '',
      sharedDescriptor: j['shared_descriptor'] as bool? ?? true,
    );
  }
}

/// One signing request, after the fact.
class ProtocolSignRecord {
  const ProtocolSignRecord({
    required this.site,
    required this.origin,
    required this.walletName,
    required this.at,
    required this.outcome,
    this.loanRef = '',
    this.action = '',
  });

  final String site;
  final String origin;
  final String walletName;
  final DateTime at;
  final ProtocolSignOutcome outcome;

  /// `SQ-42`, when the site named one.
  final String loanRef;

  /// `origination` | `repayment` | … — the raw name; the screen prettifies it.
  final String action;

  Map<String, dynamic> toJson() => {
        'site': site,
        'origin': origin,
        'wallet_name': walletName,
        'at': at.toUtc().toIso8601String(),
        'outcome': outcome.wire,
        'loan_ref': loanRef,
        'action': action,
      };

  static ProtocolSignRecord? fromJson(Map<String, dynamic> j) {
    final site = (j['site'] as String?)?.trim() ?? '';
    if (site.isEmpty) return null;
    return ProtocolSignRecord(
      site: site,
      origin: (j['origin'] as String?)?.trim() ?? '',
      walletName: (j['wallet_name'] as String?)?.trim() ?? '',
      at: _date(j['at']),
      outcome: ProtocolSignOutcomeLabel.parse(j['outcome']),
      loanRef: (j['loan_ref'] as String?)?.trim() ?? '',
      action: (j['action'] as String?)?.trim() ?? '',
    );
  }
}

DateTime _date(Object? v) =>
    DateTime.tryParse(v is String ? v : '')?.toUtc() ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// The fingerprint out of a keyorigin xpub (`[fp/2121h/1h/0h]tpub…`), which
/// is all a record keeps of an escrow key. Empty when the string is not in
/// that form — never a slice of the key itself.
String protocolKeyFingerprint(String? keyorigin) {
  final s = (keyorigin ?? '').trim();
  if (!s.startsWith('[')) return '';
  final close = s.indexOf(']');
  if (close < 0) return '';
  final inside = s.substring(1, close);
  final fp = inside.split('/').first.toLowerCase();
  return RegExp(r'^[0-9a-f]{8}$').hasMatch(fp) ? fp : '';
}
