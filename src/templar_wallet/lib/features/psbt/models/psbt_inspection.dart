/// Whether the previous output an input spends could be read off the PSBT
/// the way the signer reads it (`non_witness_utxo` first, `witness_utxo` as
/// the fallback). Anything but [ok] means the amount on screen is not the
/// amount the signature would commit to — and the engine refuses to sign.
enum PsbtUtxoStatus {
  ok,

  /// The PSBT carries no usable previous-output data for the input.
  missing,

  /// It carries both copies and they disagree.
  conflicting;

  /// The wire spelling (`"ok"`, `"missing"`, `"conflicting"`). Null for an
  /// absent or unknown value, so the caller picks its own default.
  static PsbtUtxoStatus? fromWire(String? value) => switch (value) {
        'ok' => PsbtUtxoStatus.ok,
        'missing' => PsbtUtxoStatus.missing,
        'conflicting' => PsbtUtxoStatus.conflicting,
        _ => null,
      };
}

class PsbtInput {
  const PsbtInput({
    required this.outpoint,
    required this.amountSats,
    required this.displayAmount,
    this.utxoStatus = PsbtUtxoStatus.ok,
    this.isMine,
  });
  final String outpoint;

  /// Null when the PSBT carries no usable previous-output data for this
  /// input, or its two copies of it disagree — see [utxoStatus]. The UI
  /// prints "unknown" for it, never 0.
  final int? amountSats;
  final String displayAmount;
  final PsbtUtxoStatus utxoStatus;

  /// Whether the coin belongs to the open wallet. Null when no wallet was
  /// open to judge.
  final bool? isMine;

  /// What to print for the amount: the engine's text, or "unknown" when it
  /// had no amount to format — a zero here would be a number the engine did
  /// not give us.
  String get amountLabel => amountSats == null ? 'unknown' : displayAmount;
}

class PsbtOutput {
  const PsbtOutput({
    required this.address,
    required this.amountSats,
    required this.displayAmount,
    this.isMine,
  });
  final String address;
  final int amountSats;
  final String displayAmount;

  /// Whether the address belongs to the open wallet. Null when no wallet was
  /// open to judge.
  final bool? isMine;
}

class PsbtSigner {
  const PsbtSigner({required this.fingerprint, required this.hasSigned});
  final String fingerprint;
  final bool hasSigned;
}

class PsbtInspection {
  const PsbtInspection({
    required this.inputs,
    required this.outputs,
    required this.feeSats,
    required this.feeDisplay,
    required this.sigsPresent,
    required this.sigsRequired,
    required this.signers,
    required this.policyHint,
    required this.rawPsbt,
    this.finalized = false,
    this.utxoCheck = PsbtUtxoStatus.ok,
    this.ownershipKnown = false,
  });
  final List<PsbtInput> inputs;
  final List<PsbtOutput> outputs;

  /// Null when any input's amount is unknown: a fee is inputs minus outputs,
  /// and one unknown term makes the difference meaningless.
  final int? feeSats;
  final String feeDisplay;
  final int sigsPresent;
  final int? sigsRequired;
  final List<PsbtSigner> signers;
  final String policyHint;
  final String rawPsbt;

  /// Every input already carries its final witness: a third-party signer
  /// finalized the transaction. Such inputs count as signed in [sigsPresent]
  /// on a current engine; older ones report 0 for them, so this flag is what
  /// says the copy is complete.
  final bool finalized;

  /// The worst [PsbtInput.utxoStatus] across the inputs.
  final PsbtUtxoStatus utxoCheck;

  /// Whether a wallet was open to fill in [PsbtInput.isMine] and
  /// [PsbtOutput.isMine]. False leaves both null and says nothing.
  final bool ownershipKnown;

  /// "unknown" when the engine had no fee to format.
  String get feeLabel => feeSats == null ? 'unknown' : feeDisplay;

  /// Whether what this transaction spends can be shown truthfully. The
  /// per-input statuses are checked too, so an engine that reports one
  /// without the other cannot slip a hidden input past the summary.
  bool get utxoCheckOk =>
      utxoCheck == PsbtUtxoStatus.ok &&
      inputs.every((i) => i.utxoStatus == PsbtUtxoStatus.ok);

  /// The copy carries a signature at all — as a partial signature, or as a
  /// final witness that stripped the partial signatures it was built from.
  bool get carriesSignature => finalized || sigsPresent > 0;

  /// The wallet's own coins go to an address that is not the wallet's: the
  /// shape of a "please co-sign this" that is really a payment out of this
  /// wallet. Only ever true when a wallet was open to judge.
  bool get spendsOwnCoinsElsewhere =>
      ownershipKnown &&
      inputs.any((i) => i.isMine == true) &&
      outputs.any((o) => o.isMine == false);
}
