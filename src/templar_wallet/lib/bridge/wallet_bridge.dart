// Bridge interface — all wallet-critical operations are routed through here.
// During UI phases this returns mock data.
// Phase 13 replaces implementations with real FFI calls to templar-core.

import '../features/create_wallet/models/hw_device.dart';
import '../features/create_wallet/models/hw_import_result.dart';
import '../features/create_wallet/models/native_device.dart';
import '../features/wallet_picker/models/wallet_summary.dart';
import '../features/dashboard/models/balance_history.dart';
import '../features/dashboard/models/dashboard_data.dart';
import '../features/receive/models/address_info.dart';
import '../features/history/models/transaction.dart';
import '../features/utxos/models/utxo.dart';
import '../features/wallet_info/models/wallet_info.dart';
import '../features/send/models/tx_preview.dart';
import '../features/liquid/models/issue_result.dart';
import '../features/swap/models/swap_offer.dart';
import '../features/peg/models/peg_models.dart';
import '../features/psbt/models/psbt_inspection.dart';
import '../features/psbt/models/pset_inspection.dart';

abstract class WalletBridge {
  /// Generate a fresh BIP39 mnemonic. [wordCount] must be 12 or 24.
  Future<List<String>> generateMnemonic(int wordCount);

  /// Create and persist a new software wallet. Returns the new wallet ID.
  /// If [liquid] is true, also enables a paired Liquid wallet (ELIP151).
  Future<String> createWallet(String name, List<String> mnemonic, {bool liquid = false});

  Future<List<WalletSummary>> listWallets();
  Future<void> openWallet(String walletId);
  Future<DashboardData> getWalletSummary(String walletId);
  /// The wallet's current receive address. With [fresh] the derivation index
  /// advances, so the "New address" button hands out a genuinely new one
  /// (otherwise an unused address is reused rather than burned). Liquid CT
  /// addresses are stable and ignore [fresh].
  Future<AddressInfo> generateReceiveAddress(String walletId, String asset,
      {bool fresh = false});
  Future<List<AddressInfo>> listPreviousAddresses(String walletId, String asset);
  Future<List<Transaction>> listActivity(String walletId, {String? chain, String? asset});
  Future<List<Utxo>> listUtxos(String walletId, String chain);

  /// Freezes ([frozen] true) or unfreezes coins ("txid:vout") on [chain]
  /// ('BTC' | 'Liquid'). A frozen coin stays in the balance, but the engine
  /// never spends it: automatic selection and MAX leave it out, and a
  /// transaction that would spend it is refused — whoever built it.
  Future<void> setUtxosFrozen({
    required String walletId,
    required String chain,
    required List<String> outpoints,
    required bool frozen,
  });
  Future<WalletInfo> getWalletInfo(String walletId);

  /// Native-coin (BTC + L-BTC) balance over time, reconstructed from the
  /// wallet's transaction history. Offline-safe: it reads what is already
  /// stored locally, so it never waits on a chain sync.
  Future<BalanceHistory> getBalanceHistory(String walletId);

  /// Sync every chain the wallet has. Returns the per-chain outcome map:
  /// `{'btc': 'ok'|'skipped'|'error: <reason>', 'liquid': …}` — 'skipped'
  /// means the wallet has no side on that chain. Only throws when the wallet
  /// itself could not be opened.
  Future<Map<String, String>> syncWallet(String walletId);

  /// Build a transaction preview (inputs/outputs/fee) without broadcasting.
  /// [utxos] restricts coin selection to those outpoints ("txid:vout");
  /// null = automatic selection. Multi-output is Bitcoin-only.
  Future<TxPreview> previewTransaction({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  });

  /// Build, sign, and broadcast a transaction. Returns txid.
  Future<String> sendTransaction({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  });

  /// Issue a new Liquid asset.
  Future<IssueResult> issueAsset({
    required String walletId,
    required String name,
    required String ticker,
    required int precision,
    required String domain,
    required int amountSats,
    required int reissuanceTokens,
  });

  /// Mint additional supply of an existing Liquid asset.
  Future<IssueResult> reissueAsset({
    required String walletId,
    required String assetId,
    required int amountSats,
  });

  /// Permanently destroy units of a Liquid asset. Returns txid.
  Future<String> burnAsset({
    required String walletId,
    required String assetId,
    required int amountSats,
  });

  /// Fetch the live LiquiDEX (v0) order book from liquidex.it. Read-only and
  /// wallet-independent. Set [includeUnavailable] to also list filled orders.
  Future<List<SwapOffer>> listSwaps({bool includeUnavailable = false});

  /// Enumerate connected USB hardware wallet devices through HWI. Entries
  /// carry a master fingerprint, so they can be matched to a wallet.
  Future<List<HwDevice>> enumerateHwDevices();

  /// Devices the OS can see, read in-process from USB descriptors — no HWI,
  /// no subprocess, works where spawning one is impossible.
  ///
  /// Detection only: no fingerprint, so these cannot be matched to a wallet.
  /// Used to explain an empty [enumerateHwDevices] result truthfully rather
  /// than reporting "no device found" at someone holding one.
  Future<List<NativeDevice>> enumerateNativeDevices();

  /// Pair a hardware wallet by fingerprint, reading its descriptors.
  ///
  /// Creates **one** wallet with the sides the device can hold. [liquid] adds
  /// the Liquid side, which only a **Jade** can provide — the confidential
  /// descriptor is read from the device so the Jade can spend from it. Both
  /// sides come from a single device session, so the user is asked for the PIN
  /// once. A Liquid failure leaves the Bitcoin wallet in place and reports the
  /// reason in [HwImportResult.liquidError].
  Future<HwImportResult> importHwWallet(String name, String fingerprint, {bool liquid = false});

  /// Add a Liquid side to a hardware wallet paired Bitcoin-only.
  ///
  /// Reconnects the device, checks it is the one this wallet belongs to, and
  /// stores its CT descriptor on the same wallet. Jade only.
  Future<WalletSummary> addLiquidToWallet(String walletId);

  /// Serial ports that may carry a Blockstream Jade. Does not open them, so
  /// it is safe to call while deciding what to show the user.
  Future<List<String>> jadePorts();

  /// Create a **Liquid-only** wallet from a connected Jade, over USB serial.
  ///
  /// Independent of HWI, so this is the one hardware flow that also works on
  /// macOS. The user unlocks the Jade during the call.
  Future<WalletSummary> importJadeLiquidWallet(String name);

  /// Create a watch-only wallet from descriptors (air-gap: SeedSigner / Jade / manual xpub).
  ///
  /// [recvDesc] may be a bare xpub/tpub (wrapped into a native-SegWit descriptor
  /// by the core) or a full output descriptor. If [changeDesc] is empty it is
  /// derived from the receive descriptor. When [liquidCtDescriptor] is non-null
  /// a paired Liquid watch-only wallet is also created from that CT descriptor.
  /// [airgap] marks the wallet as air-gap (signs via QR, keeps Send); false
  /// creates a pure watch-only wallet (view-only, Send hidden).
  Future<WalletSummary> createWatchOnlyWallet(
    String name,
    String recvDesc,
    String changeDesc, {
    String? liquidCtDescriptor,
    bool airgap = false,
  });

  /// Create an M-of-N multisig wallet from cosigner keyorigin xpubs.
  /// [cosignerXpubs] entries are `[fingerprint/path]xpub` strings (no wildcard).
  /// [localMnemonics] holds the seed of every key this device signs with —
  /// each must correspond to one of the xpubs; one sign pass signs with all.
  /// Empty/null (and null [localMnemonic]) = watch-only coordinator.
  /// [localMnemonic] is the legacy single-key form, superseded by
  /// [localMnemonics].
  ///
  /// [liquidXpubs] are the same cosigners' BIP87 keys
  /// (`[fp/87'/1'/0']tpub…`) in the same order — Liquid derives from a
  /// different account than Bitcoin, so a wallet that spans both chains
  /// carries two keys per co-signer. Empty = Bitcoin-only.
  /// [liquidCapableKeys] counts the keys that can actually produce an Elements
  /// signature (seeds held here, plus Jades); the backend refuses a Liquid
  /// side whose threshold exceeds it, because those funds could never be
  /// spent.
  Future<WalletSummary> createMultisigWallet({
    required String name,
    required int requiredSigs,
    required int totalSigners,
    required List<String> cosignerXpubs,
    String? localMnemonic,
    List<String>? localMnemonics,
    List<String> liquidXpubs = const [],
    int? liquidCapableKeys,
  });

  /// Fetch the BIP48 cosigner xpub (`[fp/48'/1'/0'/2']tpub…`) from a
  /// connected USB hardware device.
  Future<String> getHwCosignerXpub(String fingerprint);

  /// Fetch a Jade's BIP87 key (`[fp/87'/1'/0']tpub…`) for a Liquid multisig.
  /// Jade-only: no other USB signer can produce an Elements signature, so no
  /// other device has a Liquid key worth enrolling. Pass [expectFingerprint]
  /// to make sure the Liquid key comes from the same device that gave the
  /// Bitcoin one.
  Future<String> getJadeLiquidCosignerXpub({String? expectFingerprint});

  /// Derive a Liquid CT descriptor — `ct(elip151,wpkh(…/<0;1>/*))` — from a
  /// Bitcoin xpub or wpkh descriptor. ELIP151 needs no seed and matches this
  /// app's hardware-import convention; wallets with a seed-derived SLIP77
  /// blinding key must export their own CT descriptor instead.
  Future<String> deriveLiquidDescriptor(String btcDescriptor);

  // ── HWI toolchain (auto-install support) ────────────────────────────────

  /// What the backend knows about the HWI toolchain right now: which binary
  /// will actually run, its version, and — on Linux — whether udev rules are
  /// installed. One round trip so the setup screen can show the right remedy
  /// on every platform instead of only "missing / not missing".
  Future<HwiStatus> hwiStatus();

  /// Activate a freshly installed `hwi` binary without restarting the app.
  Future<void> setHwiPath(String path);

  /// The backend data directory (registry, wallet DBs, `hwi/` install dir).
  Future<String> getDataDir();

  /// Version of the native wallet engine (wallet-ffi crate). Throws when the
  /// dylib cannot be reached — the About screen uses that to surface an
  /// "engine unreachable" warning.
  Future<String> getVersion();

  /// Derive the BIP48 keyorigin xpub (`[fp/48'/1'/0'/2']tpub…`) from a mnemonic.
  /// Used to turn generated or existing seeds into multisig cosigner keys.
  Future<String> deriveCosignerXpub(List<String> mnemonic);

  /// Get the BIP48 cosigner xpub of an existing software wallet in the registry.
  Future<String> getCosignerXpub(String walletId);

  /// Derive the BIP87 Liquid keyorigin xpub (`[fp/87'/1'/0']tpub…`) from a
  /// mnemonic — the Liquid half of a multisig enrolment.
  Future<String> deriveLiquidCosignerXpub(List<String> mnemonic);

  /// Get the BIP87 Liquid cosigner xpub of an existing software wallet.
  Future<String> getLiquidCosignerXpub(String walletId);

  /// Rebuild a multisig wallet's descriptors from the cosigner keys it stores.
  ///
  /// For a wallet created before those keys were checked: a scanned air-gap
  /// export went in as a whole descriptor, was nested inside the wallet's own,
  /// and every open since has failed on it. The keys are intact, so this gives
  /// back the same wallet — same addresses — without going to the devices
  /// again. Throws when there is nothing to repair, or when repairing would
  /// drop a signing key this app holds.
  Future<WalletSummary> repairMultisigWallet(String walletId);

  /// Check one cosigner key before it can reach a wallet.
  ///
  /// Same rules the engine applies at creation, so the wizard can report them
  /// while the user still has the field in front of them: the key is reduced
  /// to `[fingerprint/path]tpub…` (a scanned air-gap export arrives as a whole
  /// descriptor), and anything unusable throws with the reason. A key that is
  /// merely suspicious — a singlesig account key, an unusual path — comes back
  /// with a [CosignerKeyInfo.warning] instead.
  Future<CosignerKeyInfo> validateCosignerKey(String key, {bool liquid = false});

  /// Return the BIP39 seed words of a software wallet (plain text registry).
  Future<List<String>> getMnemonic(String walletId);

  /// Return the raw master extended private key (xprv/tprv) of a software
  /// wallet. Anyone with this key controls all funds — handle like the seed.
  Future<String> getPrivateKey(String walletId);

  /// Parse a base64 PSBT and return its decoded structure.
  Future<PsbtInspection> inspectPsbt(String psbtBase64);

  /// Sign a PSBT with the active wallet's key. Returns the signed PSBT as base64.
  Future<String> signPsbt(String walletId, String psbtBase64);

  /// Sign a PSBT with a connected USB device, addressed by [fingerprint] and
  /// independent of which wallet is open. This is how a hardware device
  /// co-signs a multisig PSBT.
  Future<String> signPsbtHw(String fingerprint, String psbtBase64);

  /// Merge signed copies of one PSBT — the copy being handed out first, then
  /// what came back from co-signers, in turn or in parallel. Every partial
  /// signature survives; a copy of a different transaction throws with the
  /// reason. No wallet needed, unlike [combinePsets].
  Future<String> combinePsbts(List<String> psbtsBase64);

  // ── Liquid PSET co-signing ──────────────────────────────────────────────
  // The Liquid counterpart of the PSBT calls above. All of them need the
  // wallet open: PSET amounts are blinded, and only the wallet holding the
  // blinding key can read — or finalize — one.

  /// Decode a base64 PSET: fee, recipients, and how close it is to spendable.
  Future<PsetInspection> inspectPset(String walletId, String psetBase64);

  /// Add this wallet's software signature(s) to a PSET. Returns base64.
  Future<String> signPset(String walletId, String psetBase64);

  /// Sign a PSET on a connected Jade. A multisig is registered on the device
  /// first — without that the device refuses to sign for it at all.
  Future<String> signPsetHw(String walletId, String psetBase64);

  /// Merge signed copies of one PSET (co-signers who signed in parallel).
  Future<String> combinePsets(String walletId, List<String> psetsBase64);

  /// Finalize a fully-signed PSET and broadcast it. Returns the txid.
  Future<String> broadcastPset(String walletId, String psetBase64);

  /// Build a transaction and sign it on the wallet's USB device. Returns the
  /// **signed PSBT** — broadcast separately with [broadcastSignedPsbt] so a
  /// failed broadcast can be retried without re-approving on the device.
  Future<String> signTransactionHw({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  });

  /// Build, sign via connected hardware wallet (HWI), and broadcast. Returns txid.
  ///
  /// Prefer [signTransactionHw] + [broadcastSignedPsbt]: this one-shot form
  /// loses the signed PSBT when only the broadcast leg fails.
  Future<String> sendTransactionHw({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  });

  /// Build an unsigned PSBT for air-gap signing. Returns base64 PSBT.
  /// [assetId] is rejected by the backend unless it is Bitcoin — air-gap
  /// signing has no Liquid path.
  Future<String> buildUnsignedPsbt({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required double feeRate,
    String assetId = 'BTC',
    List<String>? utxos,
  });

  /// Consolidate selected UTXOs into a single output sent back to own wallet. Returns txid.
  Future<String> consolidateUtxos({
    required String walletId,
    required List<String> outpoints,
    required String chain,
    required double feeRate,
  });

  /// Broadcast a PSBT signed by an air-gap device. Returns txid.
  Future<String> broadcastSignedPsbt({
    required String walletId,
    required String psbtBase64,
  });

  /// Re-submit asset contract to the Liquid registry (after domain proof is live).
  Future<bool> reregisterAsset({
    required String walletId,
    required String assetId,
    required String name,
    required String ticker,
    required int precision,
    required String domain,
  });

  /// Show the next receive address on the connected hardware wallet screen.
  /// Returns the address string confirmed by the device.
  Future<String> verifyHwAddress(String walletId);

  /// Rename a wallet in the registry.
  Future<void> renameWallet(String walletId, String newName);

  /// Permanently delete a wallet from the registry.
  Future<void> deleteWallet(String walletId);

  /// Build the unsigned consolidation PSBT (base64) for the given coins.
  /// Signing and broadcasting are separate calls, so the transaction can be
  /// reviewed — and shown as a QR — before any key touches it.
  Future<String> buildConsolidationPsbt({
    required String walletId,
    required List<String> outpoints,
    required String chain,
    required double feeRate,
  });

  /// Add the Liquid side to a software wallet created or restored
  /// Bitcoin-only. Derives the descriptor from the seed already in the
  /// registry; idempotent, and rejected for hardware/multisig wallets whose
  /// Liquid keys have to be collected at setup time.
  Future<void> enableLiquid(String walletId);

  // ── At-rest encryption / vault (C1) ─────────────────────────────────────────

  /// Vault state: `{initialized, unlocked}`. `initialized` = a passphrase has
  /// been set and secrets are encrypted at rest; `unlocked` = the key is loaded
  /// in memory for this session.
  Future<VaultStatus> vaultStatus();

  /// First-time setup: derive the vault key from [passphrase] (Argon2id),
  /// migrate any existing wallets into the encrypted store, and unlock.
  Future<void> setupVault(String passphrase);

  /// Unlock the vault with [passphrase] and load the encrypted registry.
  /// Throws if the passphrase is wrong.
  Future<void> unlockVault(String passphrase);

  /// Lock the vault: wipe the in-memory key and every decrypted secret.
  Future<void> lockVault();

  /// The raw vault key as 64 hex characters — what the Android biometric
  /// store keeps so a fingerprint can stand in for the passphrase at launch.
  /// Only answers while the vault is unlocked; throws otherwise. Anyone
  /// holding this string can open the vault: treat it like the passphrase,
  /// never log it, never persist it outside hardware-backed storage.
  Future<String> exportVaultKey();

  /// Unlock with a key from [exportVaultKey] instead of the passphrase. Same
  /// outcome as [unlockVault]. Throws on malformed hex, and with a message
  /// containing "does not match" when the key no longer opens this vault
  /// (the vault was re-created since the key was exported).
  Future<void> unlockVaultWithKey(String keyHex);

  /// Prove the app password without starting a session — the gate in front of
  /// every seed reveal. Throws with a human message on a wrong password, and
  /// again once the attempt limit is hit (rate-limited engine-side).
  Future<void> verifyVaultPassphrase(String passphrase);

  /// Prove a key from [exportVaultKey] without starting a session — the
  /// Touch ID counterpart of [verifyVaultPassphrase]: the platform keystore
  /// only releases the key after a biometric check, so a key that opens this
  /// vault is proof of presence. Throws with "does not match" when the key
  /// no longer opens this vault (it was re-created since the key was stored).
  Future<void> verifyVaultKey(String keyHex);

  /// Check a typed recovery phrase against this wallet's stored public keys.
  ///
  /// Derives the account xpub from [mnemonic] and compares it with the keys the
  /// wallet already uses, so nothing secret crosses the boundary and the check
  /// works for hardware and air-gap wallets too — the engine never needs to
  /// hold their seed to answer.
  Future<BackupVerification> verifyBackup(String walletId, String mnemonic);

  // ── Air-gap QR (BC-UR v2: Jade, SeedSigner, Keystone…) ─────────────────────

  /// Encode a PSBT as a cycle of `ur:crypto-psbt` fragments for an animated QR.
  Future<List<String>> urPsbtEncode(String psbtBase64, {int maxFragmentLen = 100});

  /// A Liquid PSET as animated `ur:bytes` frames. The UR registry has no
  /// PSET type and no hardware signer reads one over QR, so this is Templar's
  /// own transport — a co-signer's phone scanning the coordinator's screen.
  Future<List<String>> urPsetEncode(String psetBase64, {int maxFragmentLen = 100});

  /// Feed every UR fragment scanned so far (any order); returns progress until
  /// the payload completes as a PSBT or a wallet descriptor. Plain-text QR
  /// payloads (bare xpub / descriptor) complete immediately.
  Future<UrDecodeResult> urDecodeParts(List<String> parts);

  // ── LiquiDEX v0 swaps ───────────────────────────────────────────────────────

  /// Verify a LiquiDEX v0 proposal. Offline checks only unless [deep], which
  /// also fetches the maker's prevout via testnet Electrum for chain checks.
  Future<SwapAnalysis> swapVerify(String proposalJson, {bool deep = false});

  /// Deep-verify and build the real (unsigned) taker transaction to preview
  /// legs, fee, and change honestly. Errors when the order is not takeable.
  Future<SwapTakePreview> swapTakePreview(String walletId, String proposalJson, {double? feeRate});

  /// Complete, sign, and broadcast the taker transaction. Returns txid.
  /// Refuses orders that are not on Liquid testnet.
  Future<String> swapTake(String walletId, String proposalJson, {double? feeRate});

  /// Create, sign, and persist a maker offer from a wallet UTXO ("txid:vout"),
  /// offering the utxo's full amount for [wantAmountSats] of [wantAssetId].
  Future<MyOffer> swapMake(String walletId, String utxo, String wantAssetId, int wantAmountSats);

  /// Self-send that creates an exact-amount UTXO of [assetId] to offer next.
  /// Returns txid; the UI re-syncs before picking the fresh coin.
  Future<String> swapMakePrepare(String walletId, String assetId, int amountSats, {double? feeRate});

  /// This wallet's maker offers, statuses refreshed best-effort from chain.
  Future<List<MyOffer>> listMyOffers(String walletId);

  /// Cancel an open offer by self-spending its UTXO (invalidates the
  /// proposal). Returns the cancel txid.
  Future<String> swapCancel(String walletId, String offerId);

  // ── Peg-in / peg-out (simulated provider) ───────────────────────────────────

  /// Quote a peg. [direction] is "in" (BTC → L-BTC) or "out" (L-BTC → BTC).
  /// Errors when [amountSats] is outside the provider's min/max bounds.
  Future<PegQuote> pegQuote(String direction, int amountSats);

  /// Start a peg order; returned in `awaiting_deposit` state with the
  /// (simulated) deposit address to pay.
  Future<PegOrder> pegStart(String walletId, String direction, int amountSats, String payoutAddress);

  /// Refresh a single peg order (the provider advances its lifecycle).
  Future<PegOrder> pegStatus(String orderId);

  /// All peg orders of a wallet, newest first.
  Future<List<PegOrder>> pegList(String walletId);

  /// Cancel a peg order; only allowed while `awaiting_deposit`.
  Future<PegOrder> pegCancel(String orderId);

  // ── Liquid network (testnet / regtest) ─────────────────────────────────────

  /// The Liquid network the engine runs on and how it reaches the chain.
  Future<LiquidNetworkInfo> getLiquidNetwork();

  /// Switch the Liquid network. `network` is `testnet` or `regtest`;
  /// `policyAsset` (regtest only) overrides the stock `liquidregtest` L-BTC
  /// id. The engine closes the open wallet: reopen it and sync afterwards.
  Future<LiquidNetworkInfo> setLiquidNetwork(String network, {String? policyAsset});

  // ── Templar Protocol ─────────────────────────────────────────────

  /// The wallet's loan-escrow account key, `[fingerprint/2121h/1h/0h]tpub…`
  /// — what a `templar://connect` answer carries as `escrow_xpub`. Software
  /// wallets only.
  Future<String> getProtocolEscrowXpub(String walletId);
}

/// Result of [WalletBridge.getLiquidNetwork] / [WalletBridge.setLiquidNetwork].
class LiquidNetworkInfo {
  const LiquidNetworkInfo({
    required this.network,
    required this.shortName,
    required this.policyAsset,
    required this.backend,
    required this.backendDescription,
    this.envLocked = false,
    this.regtestDefaultPolicyAsset = '',
  });

  /// `liquid-testnet` | `liquid-regtest` — the connector-protocol name.
  final String network;

  /// `testnet` | `regtest`.
  final String shortName;

  /// L-BTC asset id (hex) on this network.
  final String policyAsset;

  /// `electrum` | `elements_rpc`.
  final String backend;

  /// Endpoint without credentials, e.g. `electrum ssl://host:port`.
  final String backendDescription;

  /// True when `TEMPLAR_LIQUID_NETWORK` fixes the network for this run and
  /// the setting cannot be changed from the app.
  final bool envLocked;

  /// Stock regtest L-BTC id, the form's default.
  final String regtestDefaultPolicyAsset;

  bool get isRegtest => shortName == 'regtest';

  factory LiquidNetworkInfo.fromJson(Map<String, dynamic> j) => LiquidNetworkInfo(
        network: j['network'] as String? ?? 'liquid-testnet',
        shortName: j['short_name'] as String? ?? 'testnet',
        policyAsset: j['policy_asset'] as String? ?? '',
        backend: j['backend'] as String? ?? 'electrum',
        backendDescription: j['backend_description'] as String? ?? '',
        envLocked: j['env_locked'] as bool? ?? false,
        regtestDefaultPolicyAsset: j['regtest_default_policy_asset'] as String? ?? '',
      );
}

/// Result of [WalletBridge.hwiStatus] — the backend's view of the hardware
/// toolchain, used to pick which remedy the UI offers.
class HwiStatus {
  const HwiStatus({
    this.resolvedBin,
    this.version,
    this.platform = 'unknown',
    this.udevRulesInstalled,
    this.liquidHwSigning = false,
    this.hidDeviceCount = 0,
    this.nativeFamilies = const [],
    this.hwiUsable = true,
    this.hardwareSupported = true,
  });

  /// Absolute path of the `hwi` binary that will actually be spawned, or null
  /// when nothing resolved (the install card's cue).
  final String? resolvedBin;

  /// e.g. "3.2.0". Null when hwi is missing or did not answer `--version`.
  final String? version;

  /// "macos" | "windows" | "linux" | "unknown", as seen by the *backend* —
  /// authoritative for anything the Rust side does.
  final String platform;

  /// Linux only: whether any known HWI udev rules file is present. Null
  /// elsewhere, where udev is not a concept.
  final bool? udevRulesInstalled;

  /// Whether this build can sign Liquid transactions on a hardware device.
  /// False today — the Liquid side of a hardware wallet is watch-only.
  final bool liquidHwSigning;

  /// Total HID devices the backend can see, wallet or not. Zero on a laptop
  /// means HID access is being denied at the OS level rather than "nothing is
  /// plugged in" — a distinction worth having in a bug report.
  final int hidDeviceCount;

  /// Device families the backend drives in-process, with no helper binary —
  /// these work over USB on every platform.
  final List<String> nativeFamilies;

  /// Whether the HWI fallback can be spawned here at all. False on macOS,
  /// where the App Sandbox blocks it; the families that still need HWI are
  /// unavailable there, while the native ones are not.
  final bool hwiUsable;

  /// Whether this build carries the USB hardware stack at all. False on
  /// Android (built without the `hardware` feature): every hardware route
  /// answers `HW_UNSUPPORTED`, and the UI should not offer the flow.
  final bool hardwareSupported;

  bool get installed => resolvedBin != null && resolvedBin!.isNotEmpty;

  /// True only when we positively know rules are missing on Linux.
  bool get needsUdevRules => udevRulesInstalled == false;

  factory HwiStatus.fromJson(Map<String, dynamic> j) => HwiStatus(
        resolvedBin: j['resolved_bin'] as String?,
        version: j['version'] as String?,
        platform: j['platform'] as String? ?? 'unknown',
        udevRulesInstalled: j['udev_rules_installed'] as bool?,
        liquidHwSigning: j['liquid_hw_signing'] as bool? ?? false,
        hidDeviceCount: (j['hid_device_count'] as num?)?.toInt() ?? 0,
        nativeFamilies: (j['native_families'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        hwiUsable: j['hwi_usable'] as bool? ?? true,
        hardwareSupported: j['hardware_supported'] as bool? ?? true,
      );
}

/// Result of [WalletBridge.urDecodeParts].
class UrDecodeResult {
  const UrDecodeResult({
    required this.progress,
    required this.complete,
    required this.kind,
    this.psbtBase64,
    this.psetBase64,
    this.descriptor,
    this.keyorigin,
  });

  /// 0.0–1.0 (fountain decoding: estimate, not linear).
  final double progress;
  final bool complete;

  /// "psbt", "pset", "descriptor", or "" while incomplete.
  final String kind;
  final String? psbtBase64;

  /// Base64 PSET when the QR carried a Liquid transaction (`ur:bytes` with
  /// the `pset\xff` magic, or bare base64 text).
  final String? psetBase64;
  final String? descriptor;

  /// The same key as [descriptor] reduced to `[fingerprint/path]tpub…`, when
  /// the QR carried an account key. A cosigner slot wants this one: the
  /// multisig builder appends its own derivation, so a descriptor there
  /// creates a wallet that cannot be opened again.
  final String? keyorigin;

  factory UrDecodeResult.fromJson(Map<String, dynamic> j) => UrDecodeResult(
        progress: (j['progress'] as num?)?.toDouble() ?? 0.0,
        complete: j['complete'] as bool? ?? false,
        kind: j['kind'] as String? ?? '',
        psbtBase64: j['psbt_base64'] as String?,
        psetBase64: j['pset_base64'] as String?,
        descriptor: j['descriptor'] as String?,
        keyorigin: j['keyorigin'] as String?,
      );
}

/// One cosigner key, as the engine reads it. See
/// [WalletBridge.validateCosignerKey].
class CosignerKeyInfo {
  const CosignerKeyInfo({
    required this.normalized,
    required this.fingerprint,
    required this.path,
    this.warning,
  });

  /// `[fingerprint/path]tpub…` — the form the wallet is actually built from.
  final String normalized;
  final String fingerprint;

  /// Origin path without the leading `m/`.
  final String path;

  /// Set when the key works but is probably not the one the user meant.
  final String? warning;

  factory CosignerKeyInfo.fromJson(Map<String, dynamic> j) => CosignerKeyInfo(
        normalized: j['normalized'] as String? ?? '',
        fingerprint: j['fingerprint'] as String? ?? '',
        path: j['path'] as String? ?? '',
        warning: j['warning'] as String?,
      );
}

/// Result of [WalletBridge.vaultStatus].
class VaultStatus {
  const VaultStatus({
    required this.initialized,
    required this.unlocked,
    this.plaintextSeedWallets = 0,
  });
  final bool initialized;
  final bool unlocked;

  /// Recovery phrases sitting in the *plaintext* registry right now.
  ///
  /// Only ever non-zero on an install made before encryption became
  /// mandatory: the engine refuses to write new seeds unencrypted, but that
  /// check cannot reach back and protect phrases an older build already
  /// stored. Setting a passphrase migrates and shreds them.
  final int plaintextSeedWallets;

  /// This device is holding seeds in the clear and must be migrated before the
  /// app is usable.
  bool get needsMigration => plaintextSeedWallets > 0;
}

/// Result of [WalletBridge.verifyBackup].
class BackupVerification {
  const BackupVerification({
    required this.matched,
    required this.reason,
    required this.derivedFingerprint,
    required this.expectedFingerprint,
    required this.fingerprintMatch,
  });

  /// The typed phrase reproduces this wallet.
  final bool matched;

  /// `ok` · `checksum` (words wrong or out of order) · `mismatch` (a valid
  /// phrase, but for a different wallet) · `no_reference` (this wallet records
  /// no extended key to compare against).
  final String reason;

  /// Master fingerprint the typed phrase derives to — the useful thing to show
  /// on a failure when the user has several backups in front of them.
  final String derivedFingerprint;
  final String expectedFingerprint;
  final bool fingerprintMatch;

  factory BackupVerification.fromJson(Map<String, dynamic> j) => BackupVerification(
        matched: j['matched'] as bool? ?? false,
        reason: j['reason'] as String? ?? 'mismatch',
        derivedFingerprint: j['derived_fingerprint'] as String? ?? '',
        expectedFingerprint: j['expected_fingerprint'] as String? ?? '',
        fingerprintMatch: j['fingerprint_match'] as bool? ?? false,
      );
}
