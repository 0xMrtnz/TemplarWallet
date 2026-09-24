/// One output of a Liquid PSET, decoded for review before signing.
///
/// Every field is nullable because a PSET is confidential: amounts and assets
/// are blinded, and only a wallet holding the blinding key can read them. A
/// row of nulls means "this output is not ours to unblind", not "empty".
class PsetRecipient {
  const PsetRecipient({
    required this.address,
    required this.assetId,
    required this.ticker,
    required this.amountSats,
    required this.displayAmount,
    this.unverified = false,
  });

  factory PsetRecipient.fromJson(Map<String, dynamic> j) => PsetRecipient(
        address: j['address'] as String?,
        assetId: j['asset_id'] as String?,
        ticker: j['ticker'] as String?,
        amountSats: (j['amount_sats'] as num?)?.toInt(),
        displayAmount: j['display_amount'] as String?,
        unverified: j['unverified'] as bool? ?? false,
      );

  final String? address;
  final String? assetId;
  final String? ticker;
  final int? amountSats;
  final String? displayAmount;

  /// The PSET's amount/asset for this row could not be tied to its
  /// commitments; the engine refuses to sign while any output is like this.
  final bool unverified;
}

/// One input of a PSET, as far as the wallet can read it.
///
/// `isOurs` means one of this wallet's master fingerprints appears in the
/// input's key derivations — the input is asking for *our* signature. That
/// covers plain spends from this wallet and, for a Templar Protocol loan, the
/// escrow (P2WSH) input whose script names our `2121'` escrow key.
class PsetInput {
  const PsetInput({
    required this.index,
    required this.outpoint,
    required this.isOurs,
    required this.scriptType,
    this.witnessScript,
    this.witnessScriptAsm,
    this.assetId,
    this.ticker,
    this.amountSats,
    this.displayAmount,
    this.keyFingerprints = const [],
    this.signedBy = const [],
    this.threshold,
    this.unverified = false,
  });

  factory PsetInput.fromJson(Map<String, dynamic> j) => PsetInput(
        index: (j['index'] as num?)?.toInt() ?? 0,
        outpoint: j['outpoint'] as String? ?? '',
        isOurs: j['is_ours'] as bool? ?? false,
        scriptType: j['script_type'] as String? ?? 'unknown',
        witnessScript: j['witness_script'] as String?,
        witnessScriptAsm: j['witness_script_asm'] as String?,
        assetId: j['asset_id'] as String?,
        ticker: j['ticker'] as String?,
        amountSats: (j['amount_sats'] as num?)?.toInt(),
        displayAmount: j['display_amount'] as String?,
        keyFingerprints:
            (j['key_fingerprints'] as List<dynamic>? ?? const []).cast<String>(),
        signedBy: (j['signed_by'] as List<dynamic>? ?? const []).cast<String>(),
        threshold: (j['threshold'] as num?)?.toInt(),
        unverified: j['unverified'] as bool? ?? false,
      );

  final int index;
  final String outpoint;
  final bool isOurs;

  /// `p2wsh` | `p2wpkh` | `p2sh` | `other`.
  final String scriptType;

  /// Raw witness script (hex) of a P2WSH input — the escrow contract.
  final String? witnessScript;
  final String? witnessScriptAsm;
  final String? assetId;
  final String? ticker;
  final int? amountSats;
  final String? displayAmount;

  /// The PSET's amount/asset for this row could not be tied to its
  /// commitments; the engine refuses to sign while any output is like this.
  final bool unverified;

  /// Master fingerprints of every key the input's derivations name.
  final List<String> keyFingerprints;

  /// Fingerprints that already signed this input.
  final List<String> signedBy;

  /// `k` of a `k-of-n` multisig witness script, read off the script itself.
  final int? threshold;

  /// A script-hash input: multisig or a loan escrow, never a plain spend.
  bool get isScriptHash => scriptType == 'p2wsh';
}

/// One output of a PSET, classified from the wallet's point of view.
class PsetOutput {
  const PsetOutput({
    required this.index,
    required this.kind,
    required this.scriptType,
    this.address,
    this.assetId,
    this.ticker,
    this.amountSats,
    this.displayAmount,
    this.unverified = false,
  });

  factory PsetOutput.fromJson(Map<String, dynamic> j) => PsetOutput(
        index: (j['index'] as num?)?.toInt() ?? 0,
        kind: j['kind'] as String? ?? 'external',
        scriptType: j['script_type'] as String? ?? 'unknown',
        address: j['address'] as String?,
        assetId: j['asset_id'] as String?,
        ticker: j['ticker'] as String?,
        amountSats: (j['amount_sats'] as num?)?.toInt(),
        displayAmount: j['display_amount'] as String?,
        unverified: j['unverified'] as bool? ?? false,
      );

  final int index;

  /// `own` (back to this wallet) | `escrow` (a P2WSH contract) |
  /// `external` (someone else) | `fee`.
  final String kind;
  final String scriptType;
  final String? address;
  final String? assetId;
  final String? ticker;
  final int? amountSats;
  final String? displayAmount;

  /// The PSET's amount/asset for this row could not be tied to its
  /// commitments; the engine refuses to sign while any output is like this.
  final bool unverified;

  bool get isOwn => kind == 'own';
  bool get isEscrow => kind == 'escrow';
  bool get isFee => kind == 'fee';

  /// Short label for the review screen.
  String get kindLabel => switch (kind) {
        'own' => 'This wallet',
        'escrow' => 'Escrow contract',
        'fee' => 'Network fee',
        _ => 'External',
      };
}

/// A decoded Liquid PSET: what it pays, what it costs, and who still has to
/// sign it.
class PsetInspection {
  const PsetInspection({
    required this.feeSats,
    required this.feeDisplay,
    required this.recipients,
    required this.sigsHave,
    required this.sigsNeeded,
    required this.signersPresent,
    required this.signersMissing,
    required this.canFinalize,
    required this.rawPset,
    this.network = 'liquid-testnet',
    this.inputs = const [],
    this.outputs = const [],
    this.hasUnverifiedOutputs = false,
  });

  factory PsetInspection.fromJson(Map<String, dynamic> j) => PsetInspection(
        feeSats: (j['fee_sats'] as num?)?.toInt() ?? 0,
        feeDisplay: j['fee_display'] as String? ?? '',
        recipients: (j['recipients'] as List<dynamic>? ?? const [])
            .map((e) => PsetRecipient.fromJson(e as Map<String, dynamic>))
            .toList(),
        sigsHave: (j['sigs_have'] as num?)?.toInt() ?? 0,
        sigsNeeded: (j['sigs_needed'] as num?)?.toInt() ?? 1,
        signersPresent:
            (j['signers_present'] as List<dynamic>? ?? const []).cast<String>(),
        signersMissing:
            (j['signers_missing'] as List<dynamic>? ?? const []).cast<String>(),
        canFinalize: j['can_finalize'] as bool? ?? false,
        rawPset: j['raw_pset'] as String? ?? '',
        network: j['network'] as String? ?? 'liquid-testnet',
        inputs: (j['inputs'] as List<dynamic>? ?? const [])
            .map((e) => PsetInput.fromJson(e as Map<String, dynamic>))
            .toList(),
        outputs: (j['outputs'] as List<dynamic>? ?? const [])
            .map((e) => PsetOutput.fromJson(e as Map<String, dynamic>))
            .toList(),
        hasUnverifiedOutputs: j['has_unverified_outputs'] as bool? ?? false,
      );

  /// Some output claims an amount or asset its commitment does not prove.
  /// What it really pays cannot be shown, and the engine will not sign it.
  final bool hasUnverifiedOutputs;

  /// `liquid-testnet` | `liquid-regtest` — the network the wallet read the
  /// PSET on. The engine refuses PSETs carrying another network's assets.
  final String network;

  /// Every input, with whether it asks for this wallet's signature.
  final List<PsetInput> inputs;

  /// Every output, classified (own / escrow / external / fee).
  final List<PsetOutput> outputs;

  /// Inputs this wallet is asked to sign.
  List<PsetInput> get ourInputs => inputs.where((i) => i.isOurs).toList();

  /// True when the PSET touches a P2WSH contract on either side — a loan
  /// escrow being funded or spent.
  bool get touchesEscrow =>
      inputs.any((i) => i.isScriptHash) || outputs.any((o) => o.isEscrow);

  /// Signatures on the least-signed input — the count that has to reach
  /// [sigsNeeded].
  final int sigsHave;

  /// The wallet's threshold (M of M-of-N); 1 for singlesig.
  final int sigsNeeded;
  final int feeSats;
  final String feeDisplay;
  final List<PsetRecipient> recipients;
  final List<String> signersPresent;

  /// Keys that have not signed. On an M-of-N wallet the N-M keys that never
  /// sign stay listed here — read it as "who could still sign".
  final List<String> signersMissing;
  final bool canFinalize;
  final String rawPset;

  int get sigsRemaining =>
      (sigsNeeded - sigsHave) < 0 ? 0 : sigsNeeded - sigsHave;
}
