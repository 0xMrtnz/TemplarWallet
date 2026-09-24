/// Templar Protocol deep links and requests — the wallet side of the Templar Protocol's
/// `docs/connector-protocol.md` (§3 connect, §4 sign).
///
/// Pure Dart: no bridge, no network. Parsing and validation live here so
/// they can be unit-tested without an app, and so the screen that acts on a
/// request only ever sees one that already passed every check.
library;

/// What a `templar://` link asks the wallet to do.
enum ProtocolAction { connect, sign }

/// A parsed `templar://<action>?url=<https://…>&nonce=<random>` link.
class ProtocolLink {
  const ProtocolLink({required this.action, required this.url, required this.nonce});

  final ProtocolAction action;

  /// Where the request JSON is fetched from (GET, `Accept: application/json`).
  final Uri url;

  /// Random value the site expects back unchanged in the callback.
  final String nonce;

  /// Parses a link, or throws [ProtocolLinkError] with a user-readable reason.
  ///
  /// Accepts `templar://connect?…`, `templar://sign?…` and the path form
  /// `templar:///connect?…` some launchers produce.
  static ProtocolLink parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) {
      throw const ProtocolLinkError('This is not a valid link.');
    }
    if (uri.scheme.toLowerCase() != 'templar') {
      throw ProtocolLinkError('Not a templar:// link (scheme is "${uri.scheme}").');
    }
    final name = uri.host.isNotEmpty
        ? uri.host
        : uri.pathSegments.where((s) => s.isNotEmpty).firstOrNull ?? '';
    final action = switch (name.toLowerCase()) {
      'connect' => ProtocolAction.connect,
      'sign' => ProtocolAction.sign,
      _ => throw ProtocolLinkError(
          'Unknown templar:// action "$name" — expected connect or sign.'),
    };
    final target = uri.queryParameters['url'];
    if (target == null || target.trim().isEmpty) {
      throw const ProtocolLinkError('The link carries no request URL.');
    }
    final url = Uri.tryParse(target.trim());
    if (url == null || !url.hasScheme || url.host.isEmpty) {
      throw const ProtocolLinkError('The request URL in the link is malformed.');
    }
    if (url.scheme != 'https' && url.scheme != 'http') {
      throw ProtocolLinkError(
          'The request URL must be http(s), not "${url.scheme}".');
    }
    final nonce = (uri.queryParameters['nonce'] ?? '').trim();
    if (nonce.isEmpty) {
      throw const ProtocolLinkError('The link carries no nonce.');
    }
    return ProtocolLink(action: action, url: url, nonce: nonce);
  }

  /// The origin the callback must share: scheme, host and port.
  String get origin => _origin(url);

  /// Whether the request can travel unencrypted: only to this machine.
  bool get isLocal => isLocalHost(url.host);

  static bool isLocalHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
  }
}

String _origin(Uri u) => '${u.scheme}://${u.host.toLowerCase()}:${u.port}';

/// A Liquid asset id: 32 bytes, hex.
final RegExp _assetId = RegExp(r'^[0-9a-f]{64}$');

/// One line of the site's human summary (`{"label","amount"}`).
class ProtocolSummaryLine {
  const ProtocolSummaryLine({required this.label, required this.amount});
  final String label;
  final String amount;
}

/// The site's own description of what a signing request does. Shown next
/// to — never instead of — the wallet's inspection of the PSET.
class ProtocolSummary {
  const ProtocolSummary({required this.role, required this.lines});
  final String role;
  final List<ProtocolSummaryLine> lines;
}

/// The escrow contract a signing request touches.
class ProtocolEscrow {
  const ProtocolEscrow({required this.descriptor, required this.address});
  final String descriptor;
  final String address;
}

/// A request fetched from the link's `url`: the connect or sign JSON.
class ProtocolRequest {
  const ProtocolRequest({
    required this.version,
    required this.kind,
    required this.site,
    required this.network,
    required this.nonce,
    required this.callback,
    required this.expiresAt,
    this.id,
    this.action,
    this.loanRef,
    this.summary,
    this.pset,
    this.escrow,
    this.policyAsset,
  });

  final int version;

  /// `connect` | `sign`.
  final String kind;
  final String site;

  /// `liquid-testnet` | `liquid-regtest` — must equal the wallet's network.
  final String network;

  /// L-BTC asset id of the site's chain, hex, lower case. Regtest only: two
  /// `elementsd -chain=liquidregtest` nodes started separately are different
  /// chains with different policy assets, and nothing else in the request
  /// tells them apart. Null when the site did not send one, or sent one that
  /// is not 64 hex characters — a malformed value is no evidence of another
  /// chain, so it is dropped rather than turned into a false mismatch.
  final String? policyAsset;
  final String nonce;
  final Uri callback;

  /// Unix seconds after which the request is dead.
  final int expiresAt;

  // Sign requests only.
  final String? id;

  /// `origination` | `repayment` | `installment` | `default` | `liquidation` | `swap`.
  final String? action;
  final String? loanRef;
  final ProtocolSummary? summary;
  final String? pset;
  final ProtocolEscrow? escrow;

  /// Decodes the JSON, or throws [ProtocolLinkError] naming the missing field.
  static ProtocolRequest fromJson(Map<String, dynamic> j) {
    String str(String key) {
      final v = j[key];
      if (v is! String || v.trim().isEmpty) {
        throw ProtocolLinkError('The request is missing "$key".');
      }
      return v.trim();
    }

    final version = j['version'];
    if (version is! num) {
      throw const ProtocolLinkError('The request is missing "version".');
    }
    final expires = j['expires_at'];
    if (expires is! num) {
      throw const ProtocolLinkError('The request is missing "expires_at".');
    }
    final callback = Uri.tryParse(str('callback'));
    if (callback == null || !callback.hasScheme || callback.host.isEmpty) {
      throw const ProtocolLinkError('The request callback URL is malformed.');
    }

    ProtocolSummary? summary;
    final s = j['summary'];
    if (s is Map<String, dynamic>) {
      final lines = (s['lines'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((l) => ProtocolSummaryLine(
                label: (l['label'] ?? '').toString(),
                amount: (l['amount'] ?? '').toString(),
              ))
          .toList();
      summary = ProtocolSummary(role: (s['role'] ?? '').toString(), lines: lines);
    }
    ProtocolEscrow? escrow;
    final e = j['escrow'];
    if (e is Map<String, dynamic>) {
      escrow = ProtocolEscrow(
        descriptor: (e['descriptor'] ?? '').toString(),
        address: (e['address'] ?? '').toString(),
      );
    }

    return ProtocolRequest(
      version: version.toInt(),
      kind: str('kind'),
      site: (j['site'] as String?)?.trim().isNotEmpty == true
          ? (j['site'] as String).trim()
          : callback.host,
      network: str('network'),
      nonce: str('nonce'),
      callback: callback,
      expiresAt: expires.toInt(),
      id: (j['id'] as String?)?.trim(),
      action: (j['action'] as String?)?.trim(),
      loanRef: (j['loan_ref'] as String?)?.trim(),
      summary: summary,
      pset: (j['pset'] as String?)?.trim(),
      escrow: escrow,
      policyAsset: _policyAsset(j['policy_asset']),
    );
  }

  static String? _policyAsset(Object? v) {
    if (v is! String) return null;
    final hex = v.trim().toLowerCase();
    return _assetId.hasMatch(hex) ? hex : null;
  }

  DateTime get expiresAtTime =>
      DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true);

  /// Human label for the sign action.
  String get actionLabel => switch (action) {
        'origination' => 'Loan origination',
        'repayment' => 'Repayment',
        'installment' => 'Installment',
        'default' => 'Default settlement',
        'liquidation' => 'Liquidation',
        'swap' => 'Swap',
        null => 'Signing request',
        final other => other,
      };
}

/// A refusal the user can read. Every check below produces one.
class ProtocolLinkError implements Exception {
  const ProtocolLinkError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Why the site and the wallet are not on the same chain — which decides
/// what the screen can offer.
enum ProtocolMismatchKind {
  /// Both run in Templar: testnet vs regtest. One switch away.
  network,

  /// Same network name, different chain: two regtest nodes with different
  /// policy assets. Also one switch away, re-applying regtest with the
  /// site's asset id.
  chain,

  /// A network this build does not run: `liquid` mainnet, or a name it does
  /// not know. Nothing to switch to.
  unsupported,
}

/// The network check of §3/§4, as a value the screen can act on instead of a
/// sentence it can only print. Still a [ProtocolLinkError]: a caller that only
/// catches the base type keeps the old behaviour, message included.
class ProtocolNetworkMismatch implements ProtocolLinkError {
  const ProtocolNetworkMismatch({
    required this.kind,
    required this.siteNetwork,
    required this.walletNetwork,
    this.sitePolicyAsset,
    this.walletPolicyAsset,
  });

  final ProtocolMismatchKind kind;

  /// The `network` name the site sent, e.g. `liquid-regtest` or `mock`.
  final String siteNetwork;

  /// The name the wallet's engine reports right now.
  final String walletNetwork;

  /// The site's L-BTC asset id, when it sent one (regtest).
  final String? sitePolicyAsset;

  /// The asset id the wallet's chain is on, when known.
  final String? walletPolicyAsset;

  /// Whether the wallet can be moved to the site's chain from here.
  bool get canSwitch => kind != ProtocolMismatchKind.unsupported;

  /// `testnet` | `regtest` — what `WalletBridge.setLiquidNetwork` takes.
  /// Null when there is nothing to switch to.
  String? get targetShortName => switch (siteNetwork) {
        'liquid-testnet' => 'testnet',
        'liquid-regtest' => 'regtest',
        _ => null,
      };

  /// The asset id to switch with: the site's when it named one, else the
  /// caller's default. Testnet has no choice to make.
  String? policyAssetFor(String stockRegtestDefault) =>
      targetShortName == 'regtest'
          ? (sitePolicyAsset ?? stockRegtestDefault)
          : null;

  @override
  String get message => switch (kind) {
        ProtocolMismatchKind.network =>
          'This site runs on ${_prettyNetwork(siteNetwork)}. This wallet is on '
              '${_prettyNetwork(walletNetwork)}.',
        ProtocolMismatchKind.chain =>
          'This site runs on a different ${_prettyNetwork(siteNetwork)} chain '
              'than this wallet: its L-BTC asset id is '
              '${protocolShortAsset(sitePolicyAsset)}, the wallet is on '
              '${protocolShortAsset(walletPolicyAsset)}.',
        ProtocolMismatchKind.unsupported =>
          'This site runs on ${_prettyNetwork(siteNetwork)}, which this wallet '
              'does not run. It is on ${_prettyNetwork(walletNetwork)}.',
      };

  @override
  String toString() => message;
}

/// An asset id as a line of text names it: `5ac9…b225`.
String protocolShortAsset(String? id) {
  final hex = (id ?? '').trim();
  if (hex.isEmpty) return 'unknown';
  if (hex.length <= 12) return hex;
  return '${hex.substring(0, 4)}…${hex.substring(hex.length - 4)}';
}

/// The checks §3/§4 require before a request is acted on. Throws
/// [ProtocolLinkError] on the first failure.
///
/// [activeNetwork] is the wallet's Liquid network name (`liquid-testnet` |
/// `liquid-regtest`), [activePolicyAsset] the L-BTC asset id of the chain it
/// is on (regtest only; null skips the chain check); [now] is injectable for
/// tests.
///
/// A network disagreement throws [ProtocolNetworkMismatch] — a [ProtocolLinkError]
/// carrying both sides, so the screen can offer the switch instead of a dead
/// end.
void validateProtocolRequest(
  ProtocolLink link,
  ProtocolRequest request, {
  required String activeNetwork,
  String? activePolicyAsset,
  DateTime? now,
}) {
  if (request.version != 1) {
    throw ProtocolLinkError(
        'This request uses protocol version ${request.version}; this wallet '
        'speaks version 1. Update Templar Wallet.');
  }
  final expectedKind = link.action == ProtocolAction.connect ? 'connect' : 'sign';
  if (request.kind != expectedKind) {
    throw ProtocolLinkError(
        'The link asks to $expectedKind but the site sent a "${request.kind}" '
        'request.');
  }
  if (request.nonce != link.nonce) {
    throw const ProtocolLinkError(
        'The site answered with a different nonce than the link carried — '
        'the request may have been tampered with.');
  }
  if (request.network != activeNetwork) {
    throw ProtocolNetworkMismatch(
      kind: _templarRuns(request.network)
          ? ProtocolMismatchKind.network
          : ProtocolMismatchKind.unsupported,
      siteNetwork: request.network,
      walletNetwork: activeNetwork,
      sitePolicyAsset: request.policyAsset,
      walletPolicyAsset: activePolicyAsset,
    );
  }
  // Same name, other chain: two regtest nodes started separately share the
  // network name and nothing else. Signing across them would spend coins of
  // an asset the other chain has never heard of.
  final sitePolicy = request.policyAsset;
  if (request.network == 'liquid-regtest' &&
      sitePolicy != null &&
      activePolicyAsset != null &&
      activePolicyAsset.isNotEmpty &&
      sitePolicy != activePolicyAsset.trim().toLowerCase()) {
    throw ProtocolNetworkMismatch(
      kind: ProtocolMismatchKind.chain,
      siteNetwork: request.network,
      walletNetwork: activeNetwork,
      sitePolicyAsset: sitePolicy,
      walletPolicyAsset: activePolicyAsset,
    );
  }
  final linkOrigin = link.origin;
  final callbackOrigin = _origin(request.callback);
  if (callbackOrigin != linkOrigin) {
    throw ProtocolLinkError(
        'The callback ($callbackOrigin) is on a different host than the '
        'request ($linkOrigin). Refusing to send anything there.');
  }
  for (final (name, uri) in [('request', link.url), ('callback', request.callback)]) {
    if (uri.scheme != 'https' && !ProtocolLink.isLocalHost(uri.host)) {
      throw ProtocolLinkError(
          'The $name URL is plain http on a remote host (${uri.host}). Only '
          'https, or a server on this machine, is accepted.');
    }
  }
  final nowTime = (now ?? DateTime.now()).toUtc();
  if (!request.expiresAtTime.isAfter(nowTime)) {
    throw ProtocolLinkError(
        'This request expired at ${request.expiresAtTime.toLocal()}. Go back '
        'to the site and start again.');
  }
  if (link.action == ProtocolAction.sign) {
    if ((request.id ?? '').isEmpty) {
      throw const ProtocolLinkError('The signing request has no id.');
    }
    if ((request.pset ?? '').isEmpty) {
      throw const ProtocolLinkError('The signing request carries no PSET.');
    }
  }
}

/// Whether this build can run the site's network at all.
bool _templarRuns(String name) =>
    name == 'liquid-testnet' || name == 'liquid-regtest';

String _prettyNetwork(String name) => switch (name) {
      'liquid-testnet' => 'Liquid testnet',
      'liquid-regtest' => 'Liquid regtest',
      'liquid' => 'Liquid mainnet',
      _ => '"$name"',
    };

/// Human network name for display.
String protocolNetworkLabel(String name) => _prettyNetwork(name);
