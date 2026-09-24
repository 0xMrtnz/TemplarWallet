# Templar Protocol connector

Templar Wallet is the user-held signing wallet of the Templar Protocol, the
peer-to-peer Liquid lending protocol. The contract between the two is
`docs/connector-protocol.md` in the Templar Protocol repository; this guide is
the wallet side of it.

## What the wallet does

| Step | Where | What |
|---|---|---|
| Liquid network | Settings › Templar Protocol (and Network & Sync) | `testnet` (public) or `regtest` (a local `elementsd`, what the Templar Protocol runs for development). The wallet refuses any request whose `network` differs — and offers the switch on the spot (see *When the networks disagree*). |
| `templar://connect` | opened from the site's "Connect Templar Wallet" link | Fetches the request, checks version / nonce / origin / transport / expiry, lets the user pick a **software** Liquid wallet, shows the watch-only CT descriptor, the escrow key `[fp/2121h/1h/0h]tpub…` and a receive address, and POSTs them after the app password. |
| `templar://sign` | opened from a loan page | Fetches the request, shows the site's summary **next to** the wallet's own reading of the PSET (`inspect_pset`: which inputs ask for our key, which outputs are ours / an escrow / external, fee, network), requires the checkbox + app password, signs with `sign_pset` (or `sign_pset_hw` on a Jade) and POSTs the signed PSET. Never broadcasts, never stores the PSET. |

Settings › Templar Protocol (`/settings/protocol`, also one tap from the dashboard's
Liquid panel) is where all of this is visible: readiness, the paste box, the
connected sites, what was signed, and the wallet that answers by default.

The escrow key is a dedicated hardened account (`m/2121'/1'/0'`) below the
seed: it never collides with spending keys (`84'`) or multisig keys (`87'`),
and a plain `sign_pset` finds it by fingerprint, so no descriptor import is
needed to sign a loan.

FFI methods: `get_protocol_escrow_xpub {wallet_id}`, `inspect_pset` (now with
`network`, `inputs[]`, `outputs[]`), `sign_pset` / `sign_pset_hw`.

## When the networks disagree

`validateProtocolRequest` throws a typed `ProtocolNetworkMismatch`
(`features/protocol/models/protocol_link.dart`) instead of a sentence, and the
request screen renders `ProtocolNetworkMismatchCard` instead of the generic
error. Three kinds:

| Kind | When | What the card offers |
|---|---|---|
| `network` | The site is on the other network Templar runs (`liquid-testnet` ↔ `liquid-regtest`). | **Switch this wallet to Liquid regtest/testnet**, then the request is fetched again by itself. |
| `chain` | Both say `liquid-regtest` but the policy assets differ — two `elementsd` instances started separately are different chains. | **Switch this wallet to the site's chain**, re-applying regtest with the site's asset id. |
| `unsupported` | `liquid` (mainnet) or a name this build does not know. | Only **Open Network settings** — no button that cannot work. |

Two extra cases: when `TEMPLAR_LIQUID_NETWORK` fixes the network for the run,
the card explains that and drops the switch; and when the site's token died
while the network was being switched, the request screen's refusal offers
**Open \<site\>**, because a single-use token is handed out again there, not
here.

The switch itself is `switchLiquidNetwork` in
`features/settings/liquid_network_switch.dart` — the same confirmation, the
same closing of the open wallet, shared with Settings › Network & Sync so the
two cannot drift. After it, the wallet list is read again and the wallet
chosen anew: the engine closed whatever was open.

### `policy_asset`

On regtest the connect and sign JSON may carry an optional `policy_asset`: the
L-BTC asset id of the site's chain, 64 hex characters, lower case.

```json
{
  "version": 1,
  "kind": "connect",
  "network": "liquid-regtest",
  "policy_asset": "5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225",
  "…": "…"
}
```

The wallet uses it twice: to notice a same-name, different-chain mismatch, and
to prefill the asset id the switch applies (editable in the card; without it
the stock `liquidregtest` id is offered). A value that is not 64 hex characters
is ignored rather than treated as another chain. It is meaningless on testnet
and is not read there.

## Settings › Templar Protocol

| Card | What it does |
|---|---|
| Status | "Ready for Liquid regtest · policy asset 5ac9…b225", the chain endpoint, **Change network** (the shared switch), or the env-locked notice. |
| Open a request | Paste a `templar://` link or scan its QR — the fallback for when the site could not open Templar itself. |
| Connected sites | Every site holding a watch-only view: name, origin, network, wallet, when, and what it received. **Forget** removes the local record only, and says so: nothing in the protocol revokes a descriptor, and the site keeps it until the wallet is removed there. |
| Signing history | The last 50 requests: loan ref, action, site, wallet, date, outcome (signed / refused by you / expired / failed). **Clear history**. |
| Preferred wallet | The wallet a signing request is answered with and the one offered first on connect. It never replaces the confirm gate: password plus checkbox, every time. |
| How it works | Three steps and a link to this guide. |

The records live in SharedPreferences (`services/protocol_store.dart`:
`protocol_sites_v1`, `protocol_history_v1`, `protocol_preferred_wallet_v1`) — no secret,
so no vault and no keychain. They are local to the device: not in a backup, not
on another machine. What they never hold: the PSET, the amounts, the site's
summary, the CT descriptor or any key — the escrow key appears as its
fingerprint alone. Deleting a wallet deletes its records with it.

## URL scheme registration

| OS | Registration | Notes |
|---|---|---|
| macOS | `macos/Runner/Info.plist` `CFBundleURLTypes` (`templar`) | Launch Services registers the scheme when the `.app` is built or copied to `/Applications`. |
| Linux | `packaging/linux/dev.templarwallet.templar_wallet.desktop` (`MimeType=x-scheme-handler/templar;`, `Exec=templar_wallet %u`) | Install the file into `~/.local/share/applications/` (or `/usr/share/applications/`) with the executable on `PATH`, then `xdg-mime default dev.templarwallet.templar_wallet.desktop x-scheme-handler/templar`. The runner is a unique `GApplication`; a second launch forwards the link to the running window. |
| Windows | `packaging/windows/templar-wallet.iss` `[Registry]` (`HKA\Software\Classes\templar`) | The installer registers the scheme; the plain zip does not. A second launch hands the link to the running instance (`windows/runner/main.cpp`). |

Links are received by the `app_links` package (`lib/services/protocol_link_service.dart`)
and delivered only once the vault is unlocked; links that arrive earlier
wait. A link can also be pasted or scanned from Settings ›
Templar Protocol › Open a request.

## Testing without the web side

The fixtures in `docs/fixtures/protocol/` stand in for a protocol site:

```bash
python3 scripts/protocol_fixture_server.py          # serves the fixtures on 127.0.0.1:8765
                                                 # and prints every callback body
open "templar://connect?url=http://127.0.0.1:8765/connect.json&nonce=fixture-nonce-connect"
open "templar://sign?url=http://127.0.0.1:8765/sign.json&nonce=fixture-nonce-sign"
```

The fixtures are on **Liquid testnet**. The sign fixture spends a fake loan
escrow whose contract names the key of the BIP39 test vector
`abandon abandon … about` (fingerprint `73c5da0a`); restore that phrase as a
software wallet with Liquid enabled and the request shows the escrow input as
*escrow · your key*. Any other wallet sees *contract · not yours* and the
gate stays disabled.

Plain `http://` is accepted only for `localhost` / `127.0.0.1`; a remote site
must use `https://`.

## Against the Templar Protocol on regtest

Start the protocol's local regtest node and site as its repository describes
(the node listens on `127.0.0.1:18884` with RPC user and password `templar`,
the wallet's defaults). Then, in Templar: Settings › Network & Sync › Liquid
network → Regtest, reopen the wallet, sync, and fund a Liquid receive address
from the node.

Register on the site, click "Connect Templar Wallet" on `/wallet`, pick the
wallet, confirm. Take an offer as that user; the origination signing request
opens through `templar://sign`.

## Limits (v1)

- Connect needs a software wallet: a device (Jade) cannot yet export the
  `2121'` escrow key. Signing accepts software wallets and a Jade.
- The site's summary is free text; the wallet shows it beside its own
  reading of the PSET and asks the user to compare — it cannot reconcile the
  two arithmetically.
- No in-wallet lending screens, no wallet-side broadcast, no mainnet.
- Forgetting a connected site is local bookkeeping: the protocol has no
  revocation, so the site keeps the watch-only descriptor until the user
  removes the wallet there.
- The signing history is this device's alone — it is not a ledger of your
  loans, which live on the site and on the chain.
