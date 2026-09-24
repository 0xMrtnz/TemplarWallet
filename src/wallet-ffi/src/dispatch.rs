//! JSON method dispatch — routes incoming FFI calls to the correct handler.

use serde_json::Value;

use crate::handlers::backup;
use crate::handlers::bitcoin;
use crate::handlers::history;
use crate::handlers::hw;
use crate::handlers::liquid;
use crate::handlers::peg;
use crate::handlers::registry as reg;
use crate::handlers::swaps;
use crate::handlers::vault;
use crate::handlers::wallet_ops;
use crate::state::AppFfiState;
use crate::types::{
    BroadcastSignedPsbtParams, BuildUnsignedPsbtParams, BurnAssetParams, CombinePsbtsParams,
    CombinePsetsParams, ConsolidateUtxosParams, CreateMultisigParams, CreateWalletParams,
    CreateWatchOnlyParams, DeleteWalletParams, DeriveCosignerXpubParams,
    DeriveLiquidDescriptorParams, GenerateAddressParams, GenerateMnemonicParams, InspectPsbtParams,
    IssueAssetParams, ListActivityParams, ListUtxosParams, OpenWalletParams, PreviewTxParams,
    PsetParams, ReissueAssetParams, RenameWalletParams, ReregisterAssetParams, SendTxParams,
    SetLiquidNetworkParams, SetUtxosFrozenParams, SignPsbtParams, SyncOutcomeDto, TxOutputSpec,
    UrDecodePartsParams, UrPsbtEncodeParams, UrPsetEncodeParams, ValidateCosignerKeyParams,
    VaultKeyParams, VaultPassphraseParams, VerifyBackupParams, WalletIdParams,
};
#[cfg(feature = "hardware")]
use crate::types::{
    HwFingerprintParams, ImportHwWalletParams, ImportJadeLiquidParams, SetHwiPathParams,
    SignPsbtHwParams, VerifyHwAddressParams,
};

/// Entry point — returns `{"ok": value}` or `{"err": "message"}`.
pub fn dispatch(state: &mut AppFfiState, method: &str, params: &Value) -> Value {
    match try_dispatch(state, method, params) {
        Ok(v) => serde_json::json!({ "ok": v }),
        Err(e) => serde_json::json!({ "err": e }),
    }
}

fn try_dispatch(state: &mut AppFfiState, method: &str, params: &Value) -> Result<Value, String> {
    // Version handshake — pure metadata, no state touched. Answered before
    // the startup-error gate so the UI can always tell "engine loaded but
    // init failed" apart from "dylib missing/unloadable".
    if method == "version" {
        return Ok(Value::String(env!("CARGO_PKG_VERSION").to_string()));
    }
    // A fatal init condition (second instance holds the data dir, corrupt
    // registry) fails every call with the real reason. Anything else would
    // show an empty wallet list whose first save destroys the data on disk.
    if let Some(err) = &state.startup_error {
        return Err(err.clone());
    }
    match method {
        // ── Liquid network (testnet / regtest) ───────────────────────────────
        "get_liquid_network" => Ok(serde_json::to_value(liquid::network_info(state)).unwrap()),

        "set_liquid_network" => {
            let p: SetLiquidNetworkParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            liquid::set_network(state, &p.network, p.policy_asset.as_deref())?;
            Ok(serde_json::to_value(liquid::network_info(state)).unwrap())
        }

        // ── Vault (at-rest encryption, C1) ───────────────────────────────────
        "vault_status" => Ok(vault::status(state)),

        "setup_vault" => {
            let p: VaultPassphraseParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            vault::setup(state, &p.passphrase)?;
            Ok(Value::Null)
        }

        "unlock_vault" => {
            let p: VaultPassphraseParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            vault::unlock(state, &p.passphrase)?;
            Ok(Value::Null)
        }

        // Stored-key unlock (mobile biometric unlock): opens the vault from the
        // key a prior `export_vault_key` handed to the platform keystore, with
        // no passphrase and no Argon2id. Same post-unlock work and the same
        // `null` payload as `unlock_vault`; on any error the UI falls back to
        // the passphrase screen.
        "unlock_vault_with_key" => {
            let p: VaultKeyParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            vault::unlock_with_key(state, p.key_hex)?;
            Ok(Value::Null)
        }

        // The unlocked vault key, for the app to keep in the platform
        // keystore. Fails unless the vault is set up and unlocked.
        "export_vault_key" => {
            let key_hex = vault::export_key(state)?;
            Ok(serde_json::json!({ "key_hex": key_hex.as_str() }))
        }

        "lock_vault" => {
            vault::lock(state);
            Ok(Value::Null)
        }

        // Proves the app password without granting a session — the gate in
        // front of every seed reveal. Rate-limited inside the handler.
        "verify_vault_passphrase" => {
            let p: VaultPassphraseParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            vault::verify(state, &p.passphrase)?;
            Ok(Value::Null)
        }

        // The stored-key twin of `verify_vault_passphrase`: proves the key the
        // platform keystore released after a biometric check, without granting
        // a session. Behind every Touch ID confirmation gate.
        "verify_vault_key" => {
            let p: VaultKeyParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            vault::verify_key(state, p.key_hex)?;
            Ok(Value::Null)
        }

        // ── Backup verification ─────────────────────────────────────────────
        "verify_backup" => {
            let p: VerifyBackupParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            backup::verify_backup(state, &p.wallet_id, &p.mnemonic)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Registry ────────────────────────────────────────────────────────
        "list_wallets" => {
            reg::reload_registry(state)?;
            reg::list_wallets(state).map(|v| serde_json::to_value(v).unwrap())
        }

        "generate_mnemonic" => {
            let p: GenerateMnemonicParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::generate_mnemonic(p.word_count).map(|v| serde_json::to_value(v).unwrap())
        }

        "rename_wallet" => {
            let p: RenameWalletParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::rename_wallet(state, &p.wallet_id, &p.new_name)?;
            Ok(Value::Null)
        }

        "delete_wallet" => {
            let p: DeleteWalletParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::delete_wallet(state, &p.wallet_id)?;
            Ok(Value::Null)
        }

        // Adds the Liquid side to a software wallet that was created or
        // restored Bitcoin-only, deriving the descriptor from the seed already
        // in the registry.
        "enable_liquid" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::enable_liquid(state, &p.wallet_id)?;
            Ok(Value::Null)
        }

        "create_wallet" => {
            let p: CreateWalletParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::create_wallet(state, &p.name, &p.mnemonic, p.liquid)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "create_multisig_wallet" => {
            let p: CreateMultisigParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            // Prefer the multi-key form; fall back to the legacy single key.
            let local_mnemonics: Vec<String> = p
                .local_mnemonics
                .unwrap_or_else(|| p.local_mnemonic.into_iter().collect());
            reg::create_multisig_wallet(
                state,
                &p.name,
                p.required_sigs,
                p.total_signers,
                &p.cosigner_xpubs,
                &local_mnemonics,
                &p.liquid_xpubs,
                p.liquid_capable_keys,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        "derive_cosigner_xpub" => {
            let p: DeriveCosignerXpubParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::derive_cosigner_xpub(&p.mnemonic).map(serde_json::Value::String)
        }

        "derive_liquid_cosigner_xpub" => {
            let p: DeriveCosignerXpubParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::derive_liquid_cosigner_xpub(&p.mnemonic).map(serde_json::Value::String)
        }

        "get_liquid_cosigner_xpub" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::reload_registry(state)?;
            reg::get_liquid_cosigner_xpub(state, &p.wallet_id).map(serde_json::Value::String)
        }

        "get_cosigner_xpub" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::reload_registry(state)?;
            reg::get_cosigner_xpub(state, &p.wallet_id).map(serde_json::Value::String)
        }

        "get_mnemonic" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::reload_registry(state)?;
            reg::get_mnemonic(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        "get_private_key" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::reload_registry(state)?;
            reg::get_private_key(state, &p.wallet_id).map(serde_json::Value::String)
        }

        // ── Wallet lifecycle ─────────────────────────────────────────────────
        "open_wallet" => {
            let p: OpenWalletParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            wallet_ops::open_wallet(state, &p.wallet_id)?;
            Ok(Value::Null)
        }

        "sync_wallet" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            if state.active_wallet_id.as_deref() != Some(&p.wallet_id) {
                wallet_ops::open_wallet(state, &p.wallet_id)?;
            }
            // Attempt both chains even if one fails — a flaky Bitcoin server
            // must not starve the Liquid side (or vice versa). Report each
            // outcome truthfully instead of collapsing to one success flag;
            // the call itself only fails when the wallet could not be opened.
            let btc = wallet_ops::sync_bitcoin(state);
            let liquid = wallet_ops::sync_liquid(state);
            state.last_sync_btc = Some(btc.clone());
            state.last_sync_liquid = Some(liquid.clone());
            state.last_sync_at = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .ok()
                .map(|d| d.as_secs());
            let outcome = SyncOutcomeDto {
                btc: btc.to_wire(),
                liquid: liquid.to_wire(),
            };
            Ok(serde_json::to_value(outcome).unwrap())
        }

        // ── Dashboard ────────────────────────────────────────────────────────
        "get_wallet_summary" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::get_dashboard(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Addresses ────────────────────────────────────────────────────────
        "generate_receive_address" => {
            let p: GenerateAddressParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::generate_receive_address(state, &p.asset, p.fresh)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "list_previous_addresses" => {
            let p: GenerateAddressParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::list_previous_addresses(state, &p.asset)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Activity ─────────────────────────────────────────────────────────
        "list_activity" => {
            let p: ListActivityParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::list_transactions(state).map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Balance history (portfolio chart) ────────────────────────────────
        "get_balance_history" => {
            let p: history::BalanceHistoryParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            history::get_balance_history(state).map(|v| serde_json::to_value(v).unwrap())
        }

        // ── UTXOs ────────────────────────────────────────────────────────────
        "list_utxos" => {
            let p: ListUtxosParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::list_utxos(state, &p.chain).map(|v| serde_json::to_value(v).unwrap())
        }

        "set_utxos_frozen" => {
            let p: SetUtxosFrozenParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::set_utxos_frozen(state, &p.wallet_id, &p.chain, &p.outpoints, p.frozen)?;
            Ok(Value::Null)
        }

        // Two-phase consolidation: build here, sign with "sign_psbt", broadcast
        // with "broadcast_signed_psbt" — so the transaction can be reviewed
        // unsigned and then signed before it goes anywhere.
        "build_consolidation_psbt" => {
            let p: ConsolidateUtxosParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::build_consolidation_psbt(state, &p.outpoints, &p.chain, p.fee_rate)
                .map(serde_json::Value::String)
        }

        "consolidate_utxos" => {
            let p: ConsolidateUtxosParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::consolidate_utxos(state, &p.outpoints, &p.chain, p.fee_rate)
                .map(serde_json::Value::String)
        }

        // ── Wallet info ───────────────────────────────────────────────────────
        "get_wallet_info" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::get_wallet_info(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Send ─────────────────────────────────────────────────────────────
        "preview_transaction" => {
            let p: PreviewTxParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            let specs = resolve_output_specs(p.outputs, &p.address, p.amount_sats)?;
            if p.asset_id == "BTC" {
                bitcoin::preview_send(state, &btc_outputs(&specs), p.fee_rate, p.utxos)
                    .map(|v| serde_json::to_value(v).unwrap())
            } else {
                liquid::preview_send(state, &specs, &p.asset_id)
                    .map(|v| serde_json::to_value(v).unwrap())
            }
        }

        "send_transaction" => {
            let p: SendTxParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            let specs = resolve_output_specs(p.outputs, &p.address, p.amount_sats)?;
            if p.asset_id == "BTC" {
                bitcoin::send_bitcoin(state, &btc_outputs(&specs), p.fee_rate, p.utxos)
                    .map(|v| serde_json::to_value(v).unwrap())
            } else {
                liquid::send_liquid(state, &p.wallet_id, &specs, &p.asset_id)
                    .map(|v| serde_json::to_value(v).unwrap())
            }
        }

        // ── Air-gap QR (BC-UR v2) ────────────────────────────────────────────
        "ur_psbt_encode" => {
            let p: UrPsbtEncodeParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            templar_core::psbt_to_ur_parts(&p.psbt_base64, p.max_fragment_len)
                .map(|parts| serde_json::to_value(parts).unwrap())
                .map_err(|e| e.to_string())
        }

        "ur_pset_encode" => {
            let p: UrPsetEncodeParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            templar_core::pset_to_ur_parts(&p.pset_base64, p.max_fragment_len)
                .map(|parts| serde_json::to_value(parts).unwrap())
                .map_err(|e| e.to_string())
        }

        "repair_multisig_wallet" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::repair_multisig_wallet(state, &p.wallet_id)
                .map(|w| serde_json::to_value(w).unwrap())
        }

        "validate_cosigner_key" => {
            let p: ValidateCosignerKeyParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::validate_cosigner_key(&p.key, p.liquid)
                .map(|info| serde_json::to_value(info).unwrap())
        }

        "ur_decode_parts" => {
            let p: UrDecodePartsParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            templar_core::decode_ur_parts(&p.parts)
                .map(|r| serde_json::to_value(r).unwrap())
                .map_err(|e| e.to_string())
        }

        // ── PSET / Co-sign (Liquid) ──────────────────────────────────────────
        // Every one of these needs the wallet open: PSET amounts are blinded,
        // and finalize/broadcast go through the wallet's own descriptor.
        // ── Templar Protocol connector ─────────────────────────────
        "get_protocol_escrow_xpub" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            liquid::protocol_escrow_xpub(state, &p.wallet_id).map(Value::String)
        }

        "inspect_pset" => {
            let p: PsetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::inspect_pset(state, &p.wallet_id, &p.pset_base64)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "sign_pset" => {
            let p: PsetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::reload_registry(state)?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::sign_pset(state, &p.wallet_id, &p.pset_base64).map(serde_json::Value::String)
        }

        #[cfg(feature = "hardware")]
        "sign_pset_hw" => {
            let p: PsetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            reg::reload_registry(state)?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::sign_pset_hw(state, &p.wallet_id, &p.pset_base64).map(serde_json::Value::String)
        }

        "combine_psets" => {
            let p: CombinePsetsParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::combine_psets(state, &p.psets).map(serde_json::Value::String)
        }

        "broadcast_pset" => {
            let p: PsetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::broadcast_pset(state, &p.pset_base64).map(serde_json::Value::String)
        }

        // ── PSBT / Co-sign ────────────────────────────────────────────────────
        "inspect_psbt" => {
            let p: InspectPsbtParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            bitcoin::inspect_psbt_handler(state, &p.psbt_base64)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "sign_psbt" => {
            let p: SignPsbtParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            bitcoin::sign_psbt_handler(state, &p.wallet_id, &p.psbt_base64)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        // Fold co-signers' copies into the one being handed out. No wallet
        // needed: two PSBTs of the same transaction combine on their own.
        "combine_psbts" => {
            let p: CombinePsbtsParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            bitcoin::combine_psbts_handler(&p.psbts).map(serde_json::Value::String)
        }

        #[cfg(feature = "hardware")]
        "send_transaction_hw" => {
            let p: SendTxParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            ensure_bitcoin_asset(&p.asset_id)?;
            let specs = resolve_output_specs(p.outputs, &p.address, p.amount_sats)?;
            bitcoin::send_bitcoin_hw(
                state,
                &p.wallet_id,
                &btc_outputs(&specs),
                p.fee_rate,
                p.utxos,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        #[cfg(feature = "hardware")]
        "sign_transaction_hw" => {
            let p: SendTxParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            ensure_bitcoin_asset(&p.asset_id)?;
            let specs = resolve_output_specs(p.outputs, &p.address, p.amount_sats)?;
            bitcoin::sign_transaction_hw(
                state,
                &p.wallet_id,
                &btc_outputs(&specs),
                p.fee_rate,
                p.utxos,
            )
            .map(serde_json::Value::String)
        }

        #[cfg(feature = "hardware")]
        "sign_psbt_hw" => {
            let p: SignPsbtHwParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::sign_psbt_hw(state, &p.fingerprint, &p.psbt_base64).map(serde_json::Value::String)
        }

        "build_unsigned_psbt" => {
            let p: BuildUnsignedPsbtParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            ensure_bitcoin_asset(&p.asset_id)?;
            let specs = resolve_output_specs(p.outputs, &p.address, p.amount_sats)?;
            bitcoin::build_unsigned_psbt(state, &btc_outputs(&specs), p.fee_rate, p.utxos)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "broadcast_signed_psbt" => {
            let p: BroadcastSignedPsbtParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::broadcast_signed_psbt(state, &p.psbt_base64)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Liquid asset operations ───────────────────────────────────────────
        "issue_asset" => {
            let p: IssueAssetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::issue_asset(
                state,
                &p.name,
                &p.ticker,
                p.precision,
                &p.domain,
                positive_amount(p.amount_sats, "amount")?,
                non_negative_amount(p.reissuance_tokens, "reissuance tokens")?,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        "reissue_asset" => {
            let p: ReissueAssetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::reissue_asset(
                state,
                &p.asset_id,
                positive_amount(p.amount_sats, "amount")?,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        "burn_asset" => {
            let p: BurnAssetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            liquid::burn_asset(
                state,
                &p.asset_id,
                positive_amount(p.amount_sats, "amount")?,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        "reregister_asset" => {
            state.require_liquid_testnet("The Liquid asset registry")?;
            let p: ReregisterAssetParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            let ok = liquid::reregister_asset(
                state,
                &p.asset_id,
                &p.name,
                &p.ticker,
                p.precision,
                &p.domain,
            );
            Ok(serde_json::json!({ "registered": ok }))
        }

        // ── Hardware wallet ───────────────────────────────────────────────────
        #[cfg(feature = "hardware")]
        "enumerate_hw_devices" => {
            hw::enumerate_hw_devices().map(|v| serde_json::to_value(v).unwrap())
        }

        #[cfg(feature = "hardware")]
        "enumerate_native_devices" => {
            hw::enumerate_native_devices().map(|v| serde_json::to_value(v).unwrap())
        }

        // ── Jade / Liquid (native serial, no HWI) ────────────────────────────
        #[cfg(feature = "hardware")]
        "jade_ports" => Ok(serde_json::to_value(hw::jade_ports()).unwrap()),

        #[cfg(feature = "hardware")]
        "import_jade_liquid_wallet" => {
            let p: ImportJadeLiquidParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::import_jade_liquid_wallet(state, &p.name).map(|v| serde_json::to_value(v).unwrap())
        }

        #[cfg(feature = "hardware")]
        "get_hw_cosigner_xpub" => {
            let p: HwFingerprintParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::get_hw_cosigner_xpub(&p.fingerprint).map(serde_json::Value::String)
        }

        #[cfg(feature = "hardware")]
        "get_jade_liquid_cosigner_xpub" => {
            let p: HwFingerprintParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            let expect = Some(p.fingerprint.trim()).filter(|f| !f.is_empty());
            hw::get_jade_liquid_cosigner_xpub(&state.liquid_network, expect)
                .map(serde_json::Value::String)
        }

        "derive_liquid_descriptor" => {
            let p: DeriveLiquidDescriptorParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::derive_liquid_descriptor(&p.btc_desc).map(serde_json::Value::String)
        }

        // ── HWI toolchain (auto-install support) ─────────────────────────────
        "get_data_dir" => Ok(serde_json::Value::String(
            state.data_dir.to_string_lossy().to_string(),
        )),

        // `resolved_bin` is kept at the top level for older callers; the
        // diagnostics object carries version + platform + udev state too.
        "hwi_status" => Ok(hw::hwi_diagnostics()),

        #[cfg(feature = "hardware")]
        "set_hwi_path" => {
            let p: SetHwiPathParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::set_hwi_path(&p.path)?;
            Ok(Value::Null)
        }

        #[cfg(feature = "hardware")]
        "import_hw_wallet" => {
            let p: ImportHwWalletParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::import_hw_wallet(state, &p.name, &p.fingerprint, p.liquid)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        // Pair the Liquid side onto a hardware wallet that was set up
        // Bitcoin-only, on the same registry entry.
        #[cfg(feature = "hardware")]
        "add_liquid_to_wallet" => {
            let p: WalletIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::add_liquid_to_wallet(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        "create_watch_only_wallet" => {
            let p: CreateWatchOnlyParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            hw::create_watch_only_wallet(
                state,
                &p.name,
                &p.recv_desc,
                &p.change_desc,
                &p.liquid_ct_desc,
                p.airgap,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        #[cfg(feature = "hardware")]
        "verify_hw_address" => {
            let p: VerifyHwAddressParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            bitcoin::get_hw_address(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        // Without the `hardware` feature (Android) every USB route stays in
        // the contract and answers with one stable tag, so the UI can explain
        // instead of showing "Unknown method".
        #[cfg(not(feature = "hardware"))]
        "sign_pset_hw"
        | "send_transaction_hw"
        | "sign_transaction_hw"
        | "sign_psbt_hw"
        | "enumerate_hw_devices"
        | "enumerate_native_devices"
        | "jade_ports"
        | "import_jade_liquid_wallet"
        | "get_hw_cosigner_xpub"
        | "get_jade_liquid_cosigner_xpub"
        | "set_hwi_path"
        | "import_hw_wallet"
        | "add_liquid_to_wallet"
        | "verify_hw_address" => Err(hw::HW_UNSUPPORTED.to_string()),

        // Peg-in / peg-out — simulated provider (no real funds move).
        // The peg provider bridges Bitcoin testnet and Liquid testnet; a local
        // regtest has no counterpart on either side.
        "peg_quote" => {
            state.require_liquid_testnet("Peg-in / peg-out")?;
            let p: peg::PegQuoteParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            peg::quote(&p.direction, p.amount_sats).map(|v| serde_json::to_value(v).unwrap())
        }

        "peg_start" => {
            state.require_liquid_testnet("Peg-in / peg-out")?;
            let p: peg::PegStartParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            peg::start(
                state,
                &p.wallet_id,
                &p.direction,
                p.amount_sats,
                &p.payout_address,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        "peg_status" => {
            state.require_liquid_testnet("Peg-in / peg-out")?;
            let p: peg::PegOrderIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            peg::status(state, &p.order_id).map(|v| serde_json::to_value(v).unwrap())
        }

        "peg_list" => {
            state.require_liquid_testnet("Peg-in / peg-out")?;
            let p: peg::PegListParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            peg::list(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        "peg_cancel" => {
            state.require_liquid_testnet("Peg-in / peg-out")?;
            let p: peg::PegOrderIdParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            peg::cancel(state, &p.order_id).map(|v| serde_json::to_value(v).unwrap())
        }

        // ── LiquiDEX swaps / order book ───────────────────────────────────────
        "list_swaps" => {
            let p: swaps::ListSwapsParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            swaps::list_swaps(state, p.include_unavailable)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "swap_verify" => {
            let p: swaps::SwapVerifyParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            swaps::verify(state, &p.proposal_json, p.deep).map(|v| serde_json::to_value(v).unwrap())
        }

        "swap_take_preview" => {
            let p: swaps::SwapTakeParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            swaps::take_preview(state, &p.proposal_json, p.fee_rate)
                .map(|v| serde_json::to_value(v).unwrap())
        }

        "swap_take" => {
            let p: swaps::SwapTakeParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            swaps::take(state, &p.proposal_json, p.fee_rate).map(serde_json::Value::String)
        }

        "swap_make" => {
            let p: swaps::SwapMakeParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            swaps::make(
                state,
                &p.wallet_id,
                &p.utxo,
                &p.want_asset_id,
                p.want_amount_sats,
            )
            .map(|v| serde_json::to_value(v).unwrap())
        }

        "swap_make_prepare" => {
            let p: swaps::SwapMakePrepareParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            swaps::make_prepare(state, &p.asset_id, p.amount_sats, p.fee_rate)
                .map(serde_json::Value::String)
        }

        "list_my_offers" => {
            let p: swaps::ListMyOffersParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            swaps::list_my_offers(state, &p.wallet_id).map(|v| serde_json::to_value(v).unwrap())
        }

        "swap_cancel" => {
            let p: swaps::SwapCancelParams =
                serde_json::from_value(params.clone()).map_err(|e| e.to_string())?;
            ensure_wallet_open(state, &p.wallet_id)?;
            swaps::cancel(state, &p.wallet_id, &p.offer_id).map(serde_json::Value::String)
        }

        _ => Err(format!("Unknown method: {}", method)),
    }
}

fn ensure_wallet_open(state: &mut AppFfiState, wallet_id: &str) -> Result<(), String> {
    if state.active_wallet_id.as_deref() != Some(wallet_id) {
        wallet_ops::open_wallet(state, wallet_id)?;
    }
    Ok(())
}

/// Resolves the recipients of a send: prefers the multi-output `outputs`
/// param, falling back to the legacy single `address`/`amount_sats` pair.
/// Validates addresses, amounts (zero allowed only on a MAX output), and
/// that at most one output sends MAX.
/// Reject non-Bitcoin assets on the hardware and air-gap signing paths.
///
/// Those paths are Bitcoin-only by construction — they build a BDK PSBT and
/// hand it to HWI or to a QR signer, neither of which knows anything about
/// Liquid. The UI hides Liquid assets for these wallets, but the guard lives
/// here as well: the send screen used to branch on wallet *type* alone, so
/// picking L-BTC on an air-gap wallet quietly built a Bitcoin transaction.
/// A backend that can't be talked into it is the durable fix.
fn ensure_bitcoin_asset(asset_id: &str) -> Result<(), String> {
    let a = asset_id.trim();
    if a.is_empty() || a.eq_ignore_ascii_case("btc") || a.eq_ignore_ascii_case("bitcoin") {
        return Ok(());
    }
    Err(format!(
        "{}: {}",
        templar_core::ERR_LIQUID_HW_UNSUPPORTED,
        templar_core::liquid_hw_unsupported_reason()
    ))
}

/// JSON amounts arrive as `i64`; a bare `as u64` would turn a negative
/// number into ~1.8e19 units and hand that to the transaction builder.
fn positive_amount(v: i64, what: &str) -> Result<u64, String> {
    match u64::try_from(v) {
        Ok(n) if n > 0 => Ok(n),
        _ => Err(format!("The {what} must be a positive number")),
    }
}

fn non_negative_amount(v: i64, what: &str) -> Result<u64, String> {
    u64::try_from(v).map_err(|_| format!("The {what} cannot be negative"))
}

fn resolve_output_specs(
    outputs: Option<Vec<TxOutputSpec>>,
    address: &str,
    amount_sats: i64,
) -> Result<Vec<TxOutputSpec>, String> {
    let list: Vec<TxOutputSpec> = match outputs {
        Some(outs) if !outs.is_empty() => outs,
        _ if !address.is_empty() => vec![TxOutputSpec {
            address: address.to_string(),
            amount_sats,
            asset_id: None,
            send_max: false,
        }],
        _ => return Err("No outputs given".into()),
    };
    if list.iter().any(|o| o.address.is_empty()) {
        return Err("Every output needs an address".into());
    }
    if list.iter().any(|o| !o.send_max && o.amount_sats <= 0) {
        return Err("Every output needs a non-zero amount (or MAX)".into());
    }
    if list.iter().filter(|o| o.send_max).count() > 1 {
        return Err("Only one output can send the maximum".into());
    }
    Ok(list)
}

/// Bitcoin wire shape: `(address, amount_sats, send_max)` per recipient.
fn btc_outputs(specs: &[TxOutputSpec]) -> Vec<(String, u64, bool)> {
    specs
        .iter()
        .map(|o| (o.address.clone(), o.amount_sats.max(0) as u64, o.send_max))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(address: &str, amount: i64, asset: Option<&str>, send_max: bool) -> TxOutputSpec {
        TxOutputSpec {
            address: address.into(),
            amount_sats: amount,
            asset_id: asset.map(Into::into),
            send_max,
        }
    }

    #[test]
    fn legacy_single_address_still_resolves() {
        let list = resolve_output_specs(None, "tb1qaddr", 5000).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].address, "tb1qaddr");
        assert_eq!(list[0].amount_sats, 5000);
        assert!(!list[0].send_max);
    }

    #[test]
    fn max_output_allows_zero_amount() {
        let list =
            resolve_output_specs(Some(vec![spec("tb1qaddr", 0, None, true)]), "", 0).unwrap();
        assert!(list[0].send_max);
    }

    #[test]
    fn zero_amount_without_max_rejected() {
        let err =
            resolve_output_specs(Some(vec![spec("tb1qaddr", 0, None, false)]), "", 0).unwrap_err();
        assert!(err.contains("non-zero amount"));
    }

    #[test]
    fn two_max_outputs_rejected() {
        let err = resolve_output_specs(
            Some(vec![
                spec("tb1qa", 0, None, true),
                spec("tb1qb", 0, None, true),
            ]),
            "",
            0,
        )
        .unwrap_err();
        assert!(err.contains("one output"));
    }

    #[test]
    fn per_output_assets_survive() {
        let list = resolve_output_specs(
            Some(vec![
                spec("tlq1a", 100, Some("aaaa"), false),
                spec("tlq1b", 200, Some("bbbb"), false),
            ]),
            "",
            0,
        )
        .unwrap();
        assert_eq!(list[0].asset_id.as_deref(), Some("aaaa"));
        assert_eq!(list[1].asset_id.as_deref(), Some("bbbb"));
    }

    /// The hardware and air-gap paths are Bitcoin-only. An empty asset id is
    /// how older callers say "BTC", so it must pass.
    #[test]
    fn bitcoin_asset_guard_accepts_bitcoin() {
        assert!(ensure_bitcoin_asset("").is_ok());
        assert!(ensure_bitcoin_asset("BTC").is_ok());
        assert!(ensure_bitcoin_asset("btc").is_ok());
        assert!(ensure_bitcoin_asset(" Bitcoin ").is_ok());
    }

    /// A Liquid asset id must be refused with the stable tag the UI keys on,
    /// so an air-gap or hardware wallet can never build a Bitcoin transaction
    /// while the user believes they are sending L-BTC.
    #[test]
    fn bitcoin_asset_guard_rejects_liquid() {
        // L-BTC testnet.
        let lbtc = "144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49";
        let err = ensure_bitcoin_asset(lbtc).unwrap_err();
        assert!(err.starts_with("LIQUID_HW_UNSUPPORTED: "), "got: {err}");
        // The message must name the device that *can* do it, otherwise the
        // user is told "no" with nowhere to go.
        assert!(err.contains("Jade"), "got: {err}");
    }
}
