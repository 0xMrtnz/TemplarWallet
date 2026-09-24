# Templar Wallet × Templar Protocol — guide

Templar Wallet is the signing wallet of the **Templar Protocol**, the
peer-to-peer Liquid lending protocol. Your keys never leave the wallet: the
site builds loan transactions, Templar shows them to you and signs only after
you confirm. This guide covers what changed and how to use it.

**Test networks only.** Liquid testnet or a local regtest. No real money.

---

## 1. What is new in this build

| Area | Change |
|---|---|
| Liquid network | Settings › Network & Sync has a **Liquid network** card: `Testnet` (public) or `Regtest` (a local node, for the Templar Protocol demo). The shell shows an amber strip while on regtest. |
| Templar Protocol connection | Clicking **Connect Templar Wallet** on the site opens Templar through a `templar://` link. You choose a wallet, see exactly what is shared, confirm with your app password. |
| Loan signing | Every step that needs your signature (origination, repayment, default, liquidation) opens a **review screen**: the site's summary on the left, the wallet's own reading of the transaction on the right. You tick a statement, press *Sign and send*, enter the app password. The site broadcasts; the wallet never does. |
| Wallet Info | Shows the Liquid network the wallet is open on. |
| Co-sign screen | Liquid transactions now list their inputs, tagged *your coin* / *escrow · your key* / *not yours*, and outputs as *This wallet* / *Escrow contract* / *External*. |
| Peg, public swap book, asset registry | Unavailable on regtest (clear error, not a crash). |

---

## 2. Before you start

1. Install this build (macOS DMG, Windows **installer** — the zip does not register `templar://` links — or the Linux tarball).
2. First launch: set the **app password** (it encrypts wallet storage and is asked again before every signature).
3. Create or restore a **software wallet with Liquid enabled**. Loans need the wallet's seed on this computer: hardware, watch-only and multisig wallets cannot connect to Templar Protocol yet (a Jade can sign, but not connect).
4. Pick the Liquid network that matches the Templar Protocol site you test against:
   - hosted demo on Liquid testnet → **Testnet** (default);
   - local demo (the protocol's regtest node and site, started from its repository) → **Regtest**, stock policy asset prefilled.

   Switching closes the open wallet: open it again and press **Sync**.
5. Get test coins:
   - testnet: https://liquidtestnet.com/faucet or https://faucet.vulpem.com, paste a Liquid receive address from *Receive › L-BTC*;
   - regtest: fund your `el1…` address from the protocol's regtest node, then Sync.

Linux only: install the desktop entry once so the browser can open the wallet:

```bash
cp packaging/linux/dev.templarwallet.templar_wallet.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications
xdg-mime default dev.templarwallet.templar_wallet.desktop x-scheme-handler/templar
```

---

## 3. Connect the wallet to Templar Protocol

1. Register on the site, open **/wallet**, click **Connect Templar Wallet**.
2. Templar comes to the front on the *Connect wallet* screen. If storage is locked it asks for the app password first; if no wallet qualifies it tells you why.
3. Pick the wallet. The screen lists what the site will receive:
   - a **watch-only** descriptor (the site can see this wallet's Liquid balance and history — it cannot spend),
   - the **escrow key** (`m/2121'/1'/0'`), a separate account used only inside loan contracts,
   - a receive address and the wallet name.
4. Tick the statement, press **Share with …**, enter the app password.
5. *Wallet connected* → **Open in browser** takes you back to the site.

Nothing secret leaves the computer at any point.

---

## 4. Sign a loan step

When a loan needs your signature the site shows a **Sign with Templar** link (and a QR). Click it.

1. Templar opens the request. Left: *What the site says* (role, amounts, term). Right: *What your wallet reads* from the transaction itself:
   - inputs: **escrow · your key** means the loan contract is asking for your signature; **your coin** is one of your own coins; **not yours** needs someone else's key;
   - outputs: **This wallet**, **Escrow contract**, **External**, **Network fee**;
   - fee, network, how many signatures the transaction already has.
2. Compare both sides. If they describe different things, press **Cancel** and report it.
3. Tick *I compared the site's summary with the wallet's reading…*, press **Sign and send to …**, enter the app password.
4. *Signature sent*. Go back to the site: once every party has signed, the site broadcasts and the loan page shows the transaction id.

If nothing on the right is tagged *your key* the button stays disabled: the request was sent to the wrong wallet.

---

## 5. If the link does not open the wallet

- Open Templar, go to **Settings › Templar Protocol › Open a request**, paste the link from the site (right-click the button → copy link).
- Windows: reinstall with the installer, not the zip.
- Linux: run the three commands in section 2.

---

## 6. Errors you may see (all expected, all safe)

| Message | Meaning |
|---|---|
| *Network mismatch: the site is on … but this wallet runs on …* | Switch the Liquid network in Settings to the site's network. |
| *This request expired at …* | Go back to the site and start the step again. |
| *… rejected the answer (HTTP 4xx): …* | The site refused the signature (already signed, wrong request, expired). Retry from the site. |
| *Could not reach …* | Site down or offline. Nothing was sent. |
| *Nothing here is for this wallet to sign* | Open the wallet that took part in the loan. |
| *Signing failed: …* | Report it with the request id shown under *Request*. |

---

## 7. What to report

Please send, for every problem:

- app version (Settings › About), OS, Liquid network (testnet / regtest);
- the site's **loan reference** and the **request id** shown on the review screen;
- a screenshot of the review screen (both columns);
- what you expected vs what happened.

Especially useful: any case where the two columns disagree, any signature that the site did not accept, and anything that felt unclear on the screens.

---

## 8. Known limits in this alpha

- Connect works with software wallets only; a Jade can sign but cannot connect.
- The wallet shows the site's summary next to its own reading; it does not reconcile the two automatically — that is your job on the review screen.
- Link registration on Linux and Windows has not been exercised by us yet; the paste fallback (section 5) always works.
- No lending screens inside the wallet, no wallet-side broadcast, no mainnet.
