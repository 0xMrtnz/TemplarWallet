//! Templar Protocol connector helpers — the wallet side of
//! `docs/connector-protocol.md` in the Templar Protocol repository.
//!
//! A loan escrow is a per-loan CT descriptor
//!
//! ```text
//! ct(slip77(<view key>),
//!    elwsh(or_d(multi(2, <B>/<0;1>/*, <L>/<0;1>/*),
//!               and_v(v:pk(<L>/<0;1>/*), after(<term_height>)))))
//! ```
//!
//! where `<B>` / `<L>` are the borrower's and lender's **escrow account
//! keys** in keyorigin form `[fingerprint/2121h/1h/0h]tpub…` — a hardened
//! account below the BIP39 master key that never collides with the wallet's
//! spending keys (`84'/1'/0'`) or BIP87 multisig keys (`87'/1'/0'`).
//!
//! Signing needs no descriptor import: the PSET input carries the
//! `witness_script` and `bip32_derivation` entries
//! `[fingerprint/2121h/1h/0h/0/i]`, and `SwSigner::sign` matches on the
//! fingerprint — which is exactly what [`crate::LiquidWalletManager::sign`]
//! already does for multisig co-signing.

use lwk_common::Signer;
use lwk_signer::SwSigner;
use lwk_wollet::bitcoin::bip32::DerivationPath;

use crate::error::{LiquidError, TemplarError};

/// Hardened derivation path (below the master key) of the escrow account a
/// wallet contributes to Templar Protocol loan contracts: `m/2121'/1'/0'`
/// (2121' = Templar Protocol escrow purpose, 1' = test networks).
pub const ESCROW_KEY_PATH: &str = "2121h/1h/0h";

/// Derives the wallet's escrow account key in keyorigin form
/// (`[fingerprint/2121h/1h/0h]tpub…`), the value the connect callback
/// carries as `escrow_xpub`.
pub fn escrow_account_xpub(signer: &SwSigner) -> Result<String, TemplarError> {
    let path: DerivationPath = format!("m/{ESCROW_KEY_PATH}")
        .replace('h', "'")
        .parse()
        .map_err(|e| LiquidError::InvalidDescriptor(format!("escrow path: {e}")))?;
    let xpub = Signer::derive_xpub(signer, &path)
        .map_err(|e| LiquidError::InvalidDescriptor(format!("derive escrow xpub: {e}")))?;
    Ok(format!(
        "[{}/{}]{}",
        signer.fingerprint(),
        ESCROW_KEY_PATH,
        xpub
    ))
}

/// [`escrow_account_xpub`] straight from a BIP39 mnemonic (the registry
/// stores the phrase, not a signer).
pub fn escrow_xpub_from_mnemonic(mnemonic: &str) -> Result<String, TemplarError> {
    let signer = SwSigner::new(mnemonic, false)
        .map_err(|e| LiquidError::InvalidDescriptor(format!("SwSigner: {e}")))?;
    escrow_account_xpub(&signer)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use lwk_wollet::elements::confidential::{Asset, Nonce, Value};
    use lwk_wollet::elements::pset::{Input, Output, PartiallySignedTransaction};
    use lwk_wollet::elements::{OutPoint, Script, TxOut, Txid};
    use lwk_wollet::elements_miniscript::psbt::PsbtExt;
    use lwk_wollet::{Chain, WolletDescriptor};
    use std::str::FromStr;

    use crate::liquid::network::LiquidNetwork;
    use crate::liquid::wallet::LiquidWalletManager;

    /// BIP39 test vector, fingerprint 73c5da0a.
    pub(crate) const MNEMONIC_BORROWER: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    pub(crate) const MNEMONIC_LENDER: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
    /// Any 32-byte hex works as the shared SLIP-77 view key of the escrow;
    /// Templar Protocol derives it from the loan commitment hash.
    const VIEW_KEY: &str = "1111111111111111111111111111111111111111111111111111111111111111";
    const TERM_HEIGHT: u32 = 1_700_000;
    /// Per-loan derivation index (Templar Protocol: first byte of the commitment).
    pub(crate) const LOAN_INDEX: u32 = 7;

    /// The §2 contract for the two test mnemonics.
    pub(crate) fn escrow_descriptor() -> String {
        let b = escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap();
        let l = escrow_xpub_from_mnemonic(MNEMONIC_LENDER).unwrap();
        format!(
            "ct(slip77({VIEW_KEY}),elwsh(or_d(multi(2,{b}/<0;1>/*,{l}/<0;1>/*),and_v(v:pk({l}/<0;1>/*),after({TERM_HEIGHT})))))"
        )
    }

    /// A PSET that spends a fake (explicit, unblinded) escrow deposit at
    /// `LOAN_INDEX`, exactly as the protocol's settlement code builds it: the
    /// escrow input carries `witness_utxo`, `witness_script` and the
    /// `[fp/2121h/1h/0h/0/i]` `bip32_derivation` entries of both keys. One
    /// explicit payout to `payout_script` plus the fee output.
    pub(crate) fn escrow_spend_pset(
        network: &LiquidNetwork,
        payout_script: Script,
        value: u64,
        payout: u64,
    ) -> PartiallySignedTransaction {
        let wd: WolletDescriptor = escrow_descriptor().parse().expect("LWK parses §2");
        let definite = wd.definite_descriptor(Chain::External, LOAN_INDEX).unwrap();
        let spk = wd.script_pubkey(Chain::External, LOAN_INDEX).unwrap();
        let lbtc = network.policy_asset();

        let txout = TxOut {
            asset: Asset::Explicit(lbtc),
            value: Value::Explicit(value),
            nonce: Nonce::Null,
            script_pubkey: spk,
            witness: Default::default(),
        };
        let txid =
            Txid::from_str("2222222222222222222222222222222222222222222222222222222222222222")
                .unwrap();
        let mut input = Input::from_prevout(OutPoint::new(txid, 0));
        input.witness_utxo = Some(txout);
        input.asset = Some(lbtc);
        input.amount = Some(value);

        let mut pset = PartiallySignedTransaction::new_v2();
        pset.add_input(input);
        pset.update_input_with_descriptor(0, &definite)
            .expect("witness_script + bip32_derivation");
        pset.add_output(Output::new_explicit(payout_script, payout, lbtc, None));
        pset.add_output(Output::new_explicit(
            Script::default(),
            value - payout,
            lbtc,
            None,
        ));
        pset
    }

    /// p2wpkh-shaped script nobody owns.
    pub(crate) fn dummy_payout_script() -> Script {
        Script::from(vec![
            0u8, 20, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        ])
    }

    #[test]
    fn escrow_xpub_has_the_protocol_shape() {
        let x = escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap();
        assert!(x.starts_with("[73c5da0a/2121h/1h/0h]tpub"), "got {x}");
        // Deterministic, and a different account from the spending keys.
        assert_eq!(x, escrow_xpub_from_mnemonic(MNEMONIC_BORROWER).unwrap());
        let (_, spending) = crate::account_xpub_bip84(MNEMONIC_BORROWER).unwrap();
        assert!(!x.ends_with(&spending));
        assert!(escrow_xpub_from_mnemonic("not a mnemonic").is_err());
    }

    /// The critical check: LWK parses the §2 descriptor, and a plain wallet
    /// signer — knowing nothing about the loan — adds its escrow signature
    /// by fingerprint alone. Once for each party.
    #[test]
    fn both_parties_sign_the_escrow_input_with_their_2121_keys() {
        let network = LiquidNetwork::testnet();
        let mut pset = escrow_spend_pset(&network, dummy_payout_script(), 1_000_000, 999_500);
        let input = &pset.inputs()[0];
        assert!(
            input.witness_script.is_some(),
            "P2WSH input carries its script"
        );
        assert_eq!(input.bip32_derivation.len(), 2, "both escrow keys listed");
        for (fp, path) in input.bip32_derivation.values() {
            let path = path.to_string();
            assert!(
                path.contains("2121'/1'/0'/0/7"),
                "{fp}: {path} is not the escrow account"
            );
        }

        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let lender =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        assert_eq!(borrower.sign(&mut pset).unwrap(), 1, "borrower signs once");
        assert_eq!(lender.sign(&mut pset).unwrap(), 1, "lender signs once");
        assert_eq!(pset.inputs()[0].partial_sigs.len(), 2);
        // Signing again adds nothing — the signature is already there.
        assert_eq!(borrower.sign(&mut pset).unwrap(), 0);

        // A stranger's key is not in the script.
        let stranger = LiquidWalletManager::from_mnemonic_with_persist_on(
            &network,
            "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
            None,
        )
        .unwrap();
        assert_eq!(stranger.sign(&mut pset).unwrap(), 0);
    }

    /// The wallet's own view of an escrow spend, the thing the user sees
    /// next to the site's summary before signing.
    ///
    /// Outputs here are explicit, so none can be the wallet's own: LWK only
    /// accepts a wallet output when it is blinded with proofs (which is how
    /// Templar Protocol builds real ones). Ownership is covered separately below.
    #[test]
    fn inspection_describes_the_escrow_input_and_classifies_outputs() {
        let network = LiquidNetwork::testnet();
        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let mut pset = escrow_spend_pset(&network, dummy_payout_script(), 1_000_000, 999_500);
        // Plus an escrow-shaped output (another loan being funded).
        let escrow_spk = escrow_descriptor()
            .parse::<WolletDescriptor>()
            .unwrap()
            .script_pubkey(Chain::External, 3)
            .unwrap();
        let lbtc = network.policy_asset();
        pset.add_output(Output::new_explicit(escrow_spk, 1, lbtc, None));

        let d = borrower.inspect_pset(&pset).unwrap();
        assert_eq!(d.network, "liquid-testnet");
        assert_eq!(d.inputs.len(), 1);
        let input = &d.inputs[0];
        assert!(input.is_ours, "borrower's 2121' key is in the script");
        assert_eq!(input.script_type, "p2wsh");
        assert!(input.witness_script.is_some());
        assert!(input
            .witness_script_asm
            .as_deref()
            .unwrap()
            .contains("OP_CHECKMULTISIG"));
        assert_eq!(input.amount, Some(1_000_000));
        assert_eq!(input.asset.as_deref(), Some(crate::TESTNET_POLICY_ASSET));
        assert_eq!(input.key_fingerprints.len(), 2);
        assert!(input.key_fingerprints.contains(&"73c5da0a".to_string()));
        assert!(input.signed_by.is_empty());
        assert!(input.outpoint.ends_with(":0"));
        assert_eq!(d.our_inputs().len(), 1);
        assert!(d.touches_escrow());

        let kinds: Vec<&str> = d.outputs.iter().map(|o| o.kind.as_str()).collect();
        assert_eq!(kinds, ["external", "fee", "escrow"], "{:?}", d.outputs);
        assert_eq!(d.outputs[0].script_type, "p2wpkh");
        assert!(d.outputs[0].address.is_some());
        assert_eq!(d.outputs[0].amount, Some(999_500));
        assert_eq!(d.outputs[1].amount, Some(500));
        assert_eq!(d.outputs[2].script_type, "p2wsh");
        assert_eq!(d.outputs[2].amount, Some(1));
        assert!(d.outputs[2].address.as_deref().unwrap().starts_with("tex1"));

        // After the borrower signs, the input reports it.
        borrower.sign(&mut pset).unwrap();
        let d = borrower.inspect_pset(&pset).unwrap();
        assert_eq!(d.inputs[0].signed_by, vec!["73c5da0a".to_string()]);

        // The lender sees the same input as theirs too; a stranger does not.
        let lender =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        assert!(lender.inspect_pset(&pset).unwrap().inputs[0].is_ours);
        let stranger = LiquidWalletManager::from_mnemonic_with_persist_on(
            &network,
            "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
            None,
        )
        .unwrap();
        let s = stranger.inspect_pset(&pset).unwrap();
        assert!(!s.inputs[0].is_ours);
    }

    /// Output ownership follows LWK's rule — the output's key derivation
    /// reproduces one of the wallet's scripts — which is how Templar Protocol marks
    /// the payee's outputs (`add_details`) in origination and settlement.
    #[test]
    fn own_outputs_are_recognised_by_their_derivation() {
        let network = LiquidNetwork::testnet();
        let borrower =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_BORROWER, None)
                .unwrap();
        let own_script = borrower
            .wollet
            .address(Some(5))
            .unwrap()
            .address()
            .script_pubkey();
        let mut pset = escrow_spend_pset(&network, own_script.clone(), 1_000, 500);
        let own_definite = borrower
            .wollet
            .wollet_descriptor()
            .definite_descriptor(Chain::External, 5)
            .unwrap();
        pset.update_output_with_descriptor(0, &own_definite)
            .unwrap();
        let output = &pset.outputs()[0];
        assert!(!output.bip32_derivation.is_empty());
        let known = std::collections::HashSet::new();
        assert!(borrower.script_is_ours(&own_script, &output.bip32_derivation, &known));
        // Same derivation, someone else's script: not ours.
        assert!(!borrower.script_is_ours(&dummy_payout_script(), &output.bip32_derivation, &known));
        // No derivation at all: only a script the wallet already received
        // on counts.
        let empty = Default::default();
        assert!(!borrower.script_is_ours(&own_script, &empty, &known));
        let mut known = std::collections::HashSet::new();
        known.insert(own_script.clone());
        assert!(borrower.script_is_ours(&own_script, &empty, &known));
        // The lender's wallet does not own the borrower's script.
        let lender =
            LiquidWalletManager::from_mnemonic_with_persist_on(&network, MNEMONIC_LENDER, None)
                .unwrap();
        assert!(!lender.script_is_ours(&own_script, &output.bip32_derivation, &Default::default()));
    }

    /// A PSET built for testnet must not be signable by a regtest wallet,
    /// and the other way round — the fee and explicit assets give it away.
    #[test]
    fn inspection_refuses_a_pset_from_another_network() {
        let testnet_pset =
            escrow_spend_pset(&LiquidNetwork::testnet(), dummy_payout_script(), 1_000, 500);
        let regtest_wallet = LiquidWalletManager::from_mnemonic_with_persist_on(
            &LiquidNetwork::regtest_default(),
            MNEMONIC_BORROWER,
            None,
        )
        .unwrap();
        let err = regtest_wallet
            .inspect_pset(&testnet_pset)
            .unwrap_err()
            .to_string();
        assert!(err.contains("Network mismatch"), "{err}");
        assert!(err.contains("liquid-regtest"), "{err}");

        let regtest_pset = escrow_spend_pset(
            &LiquidNetwork::regtest_default(),
            dummy_payout_script(),
            1_000,
            500,
        );
        let testnet_wallet = LiquidWalletManager::from_mnemonic_with_persist_on(
            &LiquidNetwork::testnet(),
            MNEMONIC_BORROWER,
            None,
        )
        .unwrap();
        let err = testnet_wallet
            .inspect_pset(&regtest_pset)
            .unwrap_err()
            .to_string();
        assert!(err.contains("Network mismatch"), "{err}");
        // And each wallet reads its own network's PSET fine.
        assert_eq!(
            regtest_wallet.inspect_pset(&regtest_pset).unwrap().network,
            "liquid-regtest"
        );
        assert_eq!(
            testnet_wallet.inspect_pset(&testnet_pset).unwrap().network,
            "liquid-testnet"
        );
    }

    /// Prints the base64 of the testnet escrow-spend fixture, the one the
    /// wallet-ffi contract tests pin (`cargo test -p templar-core
    /// print_escrow_fixture -- --ignored --nocapture`).
    #[test]
    #[ignore = "fixture generator"]
    fn print_escrow_fixture() {
        let pset = escrow_spend_pset(
            &LiquidNetwork::testnet(),
            dummy_payout_script(),
            1_000_000,
            999_500,
        );
        println!(
            "ESCROW_FIXTURE={}",
            LiquidWalletManager::pset_to_base64(&pset).unwrap()
        );
    }
}
