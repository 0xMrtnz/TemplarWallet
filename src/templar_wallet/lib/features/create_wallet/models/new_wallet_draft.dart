import '../../wallet_picker/models/wallet_summary.dart';

/// Where the wallet's keys live. Derived from the wizard's answers rather than
/// asked as one question — see [NewWalletDraft.kind].
enum WalletKind { software, hardware, watchOnly }

/// Spending structure. Derived from [WalletPath].
enum WalletStructure { singleSig, multisig, customPolicy }

/// How a hardware device talks to the app. Asked as a wizard step (not a
/// pop-up dialog) so the whole new-wallet flow stays one continuous path.
enum HwConnection { usb, airgap }

/// The wizard's first and only structural question: what kind of wallet is
/// this? Watch-only sits apart from the other three — it is not a spending
/// structure but a wallet with no keys at all.
enum WalletPath { singleSig, multisig, customPolicy, watchOnly }

/// The questions the wizard can ask, in the order it asks them.
enum WizardQuestion { structure, kind, coins, connection, vault }

/// Answers collected by the guided new-wallet wizard ([WalletTypeScreen]).
/// The type-specific setup screens that follow read their defaults from here
/// instead of asking the same questions again.
///
/// # Question order
///
/// 1. **Structure** — one key / multisig / (set apart) watch-only.
/// 2. **Keys** — software or hardware. *Single-sig only.* A multisig picks a
///    source per key on its own "Import the keys" step (USB device, paste or
///    scan, app wallet, a new private key, a seed phrase), so asking here
///    would ask for one answer the flow then ignores N times.
/// 3. **Coins** — Bitcoin, or Bitcoin + Liquid.
/// 4. **Connection** — USB or air-gap, hardware single-sig only.
/// 5. **App password** — only while wallet storage is still unencrypted.
///
/// Structure comes first because it decides which later questions exist at
/// all: only a single-sig wallet has one place its keys live, and only a
/// hardware single-sig has a connection. It also settles [totalSteps] on
/// question 1, so the "Step 3 of 8" counter stops moving while the user is
/// still reading it.
///
/// The network (testnet) is deliberately *not* a question: it has exactly one
/// available answer, so it is stated under the coins question — the screen
/// about chains — instead of costing a click. Restore it as a step when
/// mainnet lands.
class NewWalletDraft {
  bool liquidEnabled = true;
  WalletNetwork network = WalletNetwork.testnet;

  /// Question 1.
  WalletPath path = WalletPath.singleSig;

  /// Question 2 — software or hardware, asked for a single-sig wallet only.
  /// Never [WalletKind.watchOnly]: that comes from [path].
  WalletKind keyKind = WalletKind.software;

  HwConnection? hwConnection;

  /// A watch-only wallet built by importing each cosigner's key instead of
  /// pasting one finished descriptor. Chosen inside the watch-only setup, not
  /// in the wizard, and it routes the rest of the flow through the multisig
  /// coordinator screens.
  bool watchOnlyFromCosigners = false;

  /// Where this wallet's keys live, as the setup screens read it.
  WalletKind get kind =>
      path == WalletPath.watchOnly ? WalletKind.watchOnly : keyKind;

  /// The spending structure, as the setup screens read it. A watch-only
  /// wallet built from cosigner keys is an M-of-N wallet like any other —
  /// it just holds none of the keys.
  WalletStructure get structure => switch (path) {
        WalletPath.multisig => WalletStructure.multisig,
        WalletPath.customPolicy => WalletStructure.customPolicy,
        WalletPath.watchOnly => watchOnlyFromCosigners
            ? WalletStructure.multisig
            : WalletStructure.singleSig,
        WalletPath.singleSig => WalletStructure.singleSig,
      };

  /// Whether the wizard shows the app-password step. Set on wizard entry
  /// from [WalletBridge.vaultStatus]: shown only while no vault exists yet.
  /// Stays true for the rest of the flow once shown, so the step counter
  /// doesn't shift after the vault is created mid-flow.
  bool includeVaultStep = false;

  /// Liquid rides on the same seed for single-sig; a multisig gets a second
  /// M-of-N wallet on Liquid, built from the same co-signers' BIP87 keys.
  ///
  /// Still gated on the structure: a Miniscript policy has no Liquid form
  /// here, since LWK's confidential descriptors cover `elwsh(multi(...))` and
  /// nothing more expressive.
  ///
  /// Answering yes does not guarantee a Liquid side. The multisig setup screen
  /// drops it when a key comes from a Bitcoin-only device (Ledger, Trezor,
  /// Coldcard, KeepKey), which can neither sign Liquid nor contribute a key
  /// to it, and says so before the wallet is created.
  bool get liquidSupported => structure != WalletStructure.customPolicy;

  /// Liquid as it will actually be built: the answer, narrowed by what the
  /// chosen structure can do. Setup screens should read this, not the raw flag.
  bool get liquidActive => liquidEnabled && liquidSupported;

  /// Whether the signing key for this wallet ends up on this computer. Drives
  /// the app-password step's copy: with keys on a device there is no seed on
  /// disk to warn about.
  ///
  /// True for a multisig too: any of its N slots can be a key generated or
  /// restored here, and the user chooses that after this question is asked.
  bool get seedOnDisk =>
      path == WalletPath.multisig || kind == WalletKind.software;

  String get networksLabel => liquidActive ? 'Bitcoin + Liquid' : 'Bitcoin only';

  String get networkLabel => switch (network) {
        WalletNetwork.testnet => 'Testnet',
        WalletNetwork.mainnet => 'Mainnet',
        WalletNetwork.regtest => 'Regtest',
      };

  // ── Continuous step numbering ─────────────────────────────────────────────
  // The wizard and the setup that follows are one flow with one counter
  // ("Step 5 of 9"), so the setup never feels like a different app. The totals
  // depend on the answers, and update as the user changes them.

  /// Software or hardware is a single-sig question. A multisig answers it per
  /// key while importing them, and a watch-only wallet holds no key at all.
  bool get needsKindStep => path == WalletPath.singleSig;

  /// A hardware single-sig wallet needs one extra question: USB or air-gap?
  bool get needsConnectionStep =>
      needsKindStep && keyKind == WalletKind.hardware;

  /// The questions this wizard will ask, given the answers so far.
  List<WizardQuestion> get questions => [
        WizardQuestion.structure,
        if (needsKindStep) WizardQuestion.kind,
        WizardQuestion.coins,
        if (needsConnectionStep) WizardQuestion.connection,
        // Always last, so it sits directly before the setup it protects.
        if (includeVaultStep) WizardQuestion.vault,
      ];

  int get wizardSteps => questions.length;

  /// The 1-based step a question sits on, or null when it isn't asked.
  int? stepOf(WizardQuestion q) {
    final i = questions.indexOf(q);
    return i < 0 ? null : i + 1;
  }

  /// Steps owned by the setup screen this draft routes to. Kept in sync with
  /// each screen's own stage list.
  int get setupSteps => switch (structure) {
        // threshold, import keys, review, done. Ticking "I hold one of these
        // keys" on the threshold step adds the three seed steps — that choice
        // lives inside the setup, so it isn't counted here.
        WalletStructure.multisig => 4,
        _ => switch (kind) {
            // name+seed, backup, verify, done
            WalletKind.software => 4,
            // details, done
            WalletKind.watchOnly => 2,
            // device/instructions, config, name, done
            WalletKind.hardware => 4,
          },
      };

  int get totalSteps => wizardSteps + setupSteps;
}

/// The single in-flight draft: the wizard writes it, setup screens read it.
/// Values persist across wizard re-entries so Back/Cancel keeps the choices.
final newWalletDraft = NewWalletDraft();
