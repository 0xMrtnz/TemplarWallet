# Android port — build plan (lean)

Port the existing Flutter + Rust FFI app to Android. Testnet only, same as
desktop. Grounded in the 2026-09-04 codebase survey. **No hardware wallets in
v1** (decided 2026-09-04).

## 1. Scope

**v1 ships:** everything that is software custody today — Bitcoin (BDK `wsh`
Miniscript) + Liquid (LWK): singlesig, multisig, watch-only; PSBT/PSET two-phase
build → inspect → sign → broadcast; vault (Argon2id + XChaCha20) + app password;
LiquiDEX swaps + order book (browse only); **QR air-gap** as the external-signer
story (pure Rust, no USB).

**v1 defers:** Jade / Ledger / HWI (desktop USB, serial, Python CLI — none run on
stock Android; later phase = Jade over BLE or USB-OTG transport rewrite); peg and
asset-registry submission; `templar://` connector mobile UX (plumbing stays).

**Branch:** `feature/android` off `build-alpha2-security`.

## 2. Layout — no reorganization

- `src/wallet-ffi` is already `crate-type = ["cdylib"]` → `libwallet_ffi.so`.
- Flutter platform folders are siblings (`macos/ linux/ windows/`); add
  `android/` next to them:
  `cd src/templar_wallet && flutter create --platforms=android --org dev.templarwallet .`
  then `applicationId = "dev.templarwallet.templarWallet"`.

## 3. Blockers, in order (each verifiable on desktop, no Android toolchain)

1. **OpenSSL in graph** ✅ done (8ebce13): `reqwest` on `rustls-tls`,
   `cargo tree -i openssl-sys --target aarch64-linux-android` is empty.
2. **Feature-gate the USB hardware stack** ✅ done. `templar-core` feature
   `hardware` (default on) owns `hidapi`, `serialport`, `lwk_jade`
   (`sync`+`serial`), `ledger_bitcoin_client`, `bitcoin_032`, `serde_cbor`;
   `bitcoin::{device,hardware}` are gated whole, `liquid::hardware` keeps its
   pure items (`is_jade_model`, error tags) and gates `JadeLiquidSigner`.
   `lwk_signer` is `default-features = false` (its `jade` default dragged
   `lwk_jade` + docker test infra into every build). `wallet-ffi` mirrors the
   feature: USB routes stay in the contract and answer `HW_UNSUPPORTED: …`,
   `hwi_status` adds `hardware_supported` (Dart `HwiStatus.hardwareSupported`).
   `liquid_descriptor_from_wpkh` moved to `watch_only.rs` so watch-only
   Liquid derivation works without hardware. Verified: default 246+82 tests,
   `--no-default-features` 205+75, both clippy-clean of new warnings.
3. **Data-dir injection** ✅ done. `wallet_set_data_dir(const char*) -> i32`
   (0 ok, 1 bad string, 2 empty, 3 too late) fills a process `OnceCell` that
   `AppFfiState::new()` consults before `TEMPLAR_DATA_DIR`; config, registry,
   vault and sled all live under it. `main.dart` resolves
   `getApplicationSupportDirectory()` once, feeds it to `CrashLog.init` and
   `FfiWalletBridge.setDataDir` before the bridge is constructed.
4. **Dart glue** ✅ done: `bridge_provider.dart` builds the real bridge on
   Android; `_loadLib()` opens `libwallet_ffi.so` by soname (main isolate and
   `_callBg` alike).

## 4. Build recipe

```bash
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk            # 4.x: platform flag is --platform, not -p
./scripts/build_android.sh [--release|--so-only]   # .so per ABI → jniLibs,
#   checks wallet_call/wallet_free_string/wallet_set_data_dir are exported,
#   then `flutter build apk`. Needs NDK 28.2.13676358 under $ANDROID_HOME/ndk.
# Output: one APK per ABI in src/templar_wallet/build/app/outputs/flutter-apk/
# (app-arm64-v8a-<mode>.apk for phones, app-x86_64-… for an x86 AVD). Debug
# .so ~57 MB/ABI (debuginfo stripped). Gradle warns that mobile_scanner,
# shared_preferences and url_launcher still apply KGP — plugin bumps, later.
```

Keep `panic = "unwind"` (`wallet_call` uses `catch_unwind`). ABIs: `arm64-v8a`
(devices) + `x86_64` (emulator); drop `armeabi-v7a` (sled 0.34 on 32-bit).

## 5. Manifest & Gradle

- `INTERNET` permission (Flutter only injects it in debug/profile, not release).
- `<queries>` for `VIEW https` so `canLaunchUrl` works on API 30+.
- `templar://` intent-filter on `MainActivity` (VIEW + BROWSABLE + DEFAULT).
- `CAMERA` merges from `mobile_scanner`; add `uses-feature camera required=false`.
- `android:allowBackup="false"` — never let Auto Backup copy vault/sled files.
- `minSdk 24`, `targetSdk 34`, `compileSdk 36`; ABIs via `--target-platform` in the script (no fixed `abiFilters`: conflicts with `--split-per-abi`).

## 6. UI: desktop → mobile (largest workstream)

Shell is hard-wired wide: runners pin 1024×720, `app/shell.dart` wraps every
screen in a `Row` with a fixed 220/60 px sidebar, no `SafeArea` anywhere.

Decided with the owner on 2026-09-05 (prototype approved):
1. ✅ `AppSpacing.pagePadding(context)`: 16 <600 dp, 24 <905, else 32; all 27
   hardcoded sites converted (desktop unchanged at 32).
2. ✅ Mobile shell (`MobileShell` in `app/shell.dart`, Android/iOS only, ALSO on
   tablets/landscape — no rail/sidebar on mobile by decision): thin header
   (wallet name → picker, sync pill → sync) + **bottom carousel nav**
   (`shared/widgets/carousel_nav.dart`): 3 visible icons, circular list,
   snap-to-centre changes page, swipe only on the bar, side tap = jump, centre
   tap = scroll to top, haptic on change; crimson tint for wallet/system items,
   Liquid teal for Liquid/LiquiDEX/Peg. Lock/theme live in Settings.
3. ✅ Back button: `app/back_handler.dart` registry + `PopScope` on the shell —
   Send wizard steps back, any section → Dashboard, Dashboard → exit.
4. ✅ Edge-to-edge (`SystemUiMode.edgeToEdge`, transparent bars) with
   `SafeArea` in the shell header and on the pre-shell screens.
5. ✅ Biometric vault unlock: `export_vault_key` / `unlock_vault_with_key` FFI
   routes, key kept in `biometric_storage` (Keystore, per-use auth), Settings
   toggle, fingerprint at launch and on the unlock screen; passphrase still
   required for seed reveal and signing. KDF unchanged (256 MiB) by decision.
6. ✅ Launcher: adaptive icon (gradient squircle + crimson cross + monochrome),
   Android 12 splash, black launch window — `scripts/generate_icons.sh`.
7. ✅ Phase 3 (2026-09-05/06) — per-screen phone layouts, all gated on
   `AppLayout.isPhone(context)` (`lib/theme/app_layout.dart`, re-exported by
   `app_spacing.dart`) so desktop trees are unchanged:
   - Foundation: `AppTypography.*Of(context)` phone-scaled styles;
     `showAppDialog` + `AppDialog` + `AppSheet` (`shared/widgets/glass_dialog.dart`)
     — dialog on desktop, bottom sheet on a phone (`GlassDialog` renders as a
     sheet only inside a sheet route, so a stray `showDialog` degrades to the
     dialog); compact `PageHeader`; `services/file_export.dart`
     (`FileExport.saveOrShare*` → share sheet on Android, since
     `file_selector` has no `getSaveLocation` there; `pickFile` accepts any
     file on Android — no MIME type for `.psbt`/`.pset`);
     `services/screen_security.dart` (`SecureScreen` → `FLAG_SECURE` via a
     MethodChannel in `MainActivity.kt`) around seed and private-key views.
   - Shell: carousel 86 dp + inset, header 52 dp, text scale clamped at 1.3.
   - Screens: dashboard hero (no duplicate title, tap-to-pin chart, half-width
     Send/Receive); Receive stacked with a column-wide QR, Copy + Share,
     previous-address list, chain-switch race fixed; UTXOs stat tiles +
     full-width Consolidate + uniform coin cards; Activity two-line rows,
     detail sheet on the root navigator; Send compact stepper, stacked
     cards, 2×2 fee grid, vertical tx diagram, keyboard hygiene for address
     fields; sign/confirm/success/air-gap dialogs as sheets, full-screen QR
     scanner with torch; wallet picker single-column rows; wizards (network
     cards stacked, hardware option hidden on Android, air-gap Row →
     Column, multisig source picker as chips, seed fields without
     autocorrect, Restore under a SafeArea); LiquiDEX toolbar wrap + offer
     cards + flows on the root navigator; Settings four-tab strip, no nested
     Scaffold, every dialog a sheet; Wallet Info export via share sheet,
     descriptors unclipped; Liquid single-column assets, scrollable detail
     sheet; Peg two-line order rows and stacked deposit block; welcome /
     vault unlock / PIN top-biased with phone-sized titles.
   - Debug-only `--dart-define=TEMPLAR_MOCK_BRIDGE=true` forces the mock
     bridge (populated screens on the emulator without funding a wallet).
   Still open: `BackdropFilter` reduce-effects default on low-end devices;
   the crash-log export on Android; the remaining "this computer" copy;
   psbt/cosign and protocol screens were not audited (session limit).
8. ✅ Phone UI round 2 (2026-09-06, decided with the owner):
   - Carousel slimmed to **Dashboard · Activity · UTXOs · Liquid · Settings**
     (`mobileNavItems` in `app/shell.dart`). Send and Receive live on the
     Dashboard hero; Wallet Info is the first row of Settings; LiquiDEX and
     Peg share the Liquid slot behind a tab strip (`_LiquidHubTabs`, routes
     unchanged, Peg dimmed on a Liquid-only wallet).
   - Sub-pages (Send, Receive, Wallet info, Settings › X, Liquid
     issue/reissue/burn/asset-ops) keep the carousel visible, centred on the
     parent, and the header's left half becomes "‹ Title". The arrow, the
     system back and the Send wizard's own Back all go through
     `_MobileShellState._goBack`: wizard step → parent route
     (`mobileParentRouteFor`) → Dashboard → exit. `mobileNavRouteFor` /
     `mobileSubPageTitle` are the rest of the map (`test/mobile_routes_test.dart`).
   - Settings on a phone is a list (`_SettingsHome`): solid coloured plates
     from the palette, name, one-line summary, chevron; a "Lock wallet
     storage" row when the vault is open. Sections are routes
     (`/settings/network|security|appearance|about`, `SettingsSection`);
     desktop keeps its two panes and opens on the routed section.
   - Dashboard hero: fingerprint badge gone on a phone (Settings › Wallet
     info); the balance tap flips fiat ⇄ coin for the chart too
     (`_PortfolioChart.fiatOverride`); range as a row of words
     (`_TextChips`, 1D 1W 1M 3M 1Y ALL) with the delta on the same row;
     All/BTC/Liquid words only for two-chain wallets; Send/Receive as two
     56-dp tiles (`_HeroActions`).
   - Round 3 (same day, after the owner's reference shots): `design.md` at the
     repo root is now the rule set (gallery surfaces, one Action colour, chrome
     recedes, one shadow, small rewards). `AppScheme.panel` / `panelInset` are
     the two phone surface steps; `HeroPanel` no longer paints its specular
     gradient *instead of* its fill on a phone. Dashboard hero: eyebrow
     (`TOTAL BALANCE · TESTNET`) + big figure with a quiet unit + "≈ other unit
     · last move 2h ago", a 136-dp chart with three grid rules and a dot that
     lands on the newest sample (`ValueChart.gridLines` / `markLatest`), the
     range words, then Send (filled crimson, the app's one shadow) and Receive
     (neutral tile). Below it the two chain panels became one **Assets** list
     and one **Recent activity** list built from the shared row grammar in
     `shared/widgets/list_rows.dart` (`ListSectionLabel` / `ListCard` /
     `ListRow` / `ListAmount` / `ListSwitch`), with the section link on the
     header ("Liquid →", "All →"). Settings root: labelled groups with the same
     rows, inline switches (biometrics via the extracted
     `features/settings/biometric_unlock_tile.dart`, reduce effects,
     auto-sync), muted glyph tiles instead of solid plates. Carousel: opaque
     surface, ringed centre plate, readable side glyphs, a landing pop.
     `shared/relative_time.dart` + tests for the activity ages.
   - Round 4 (2026-09-06, "soft mobile") — the owner's three decisions, taken
     against a Claude Design mockup of all ten phone screens: buttons filled
     54 dp / radius 16 (`AppSpacing.phoneControlHeight`, `radiusPhoneControl`),
     fields filled `panelInset` radius 14 / 56 dp with no rest border and a
     1.5 px accent ring on focus, and the Send stepper as dots. Same icon set
     and palette as the desktop by explicit instruction — only the phone's
     FEEL changes. Foundation: `AppTheme.phoneBuilder` (a phone-only Theme
     overlay wired into all six MaterialApps in main.dart) carries the field
     and raw-Material-button geometry; `buttons.dart` inverts the tile
     grammar on a phone (filled, no border, accent = crimson slab + the app's
     one glow, `dense` = 44 dp for inline runs); cards radius 14, segmented
     tracks and code boxes on `panelInset`, `AppScheme.chrome` names the bar's
     tone. Then ten screens in parallel: Send (dots + grey chips + sheets),
     Receive, Activity, UTXOs, Liquid, Peg, LiquiDEX, Wallet info, the
     Settings sections and the four pre-shell screens. Verified by an
     adversarial pass (5 lenses × 3 refuting skeptics over the diff): 18 of 54
     findings survived, all fixed except two intended cross-platform items
     (the fiat ⇅ chip and its equivalence line, which ship on both by design)
     and one belonging to another session (`cosign_view.dart`'s signer donut,
     which replaced `QuorumMeter` ungated).
   - Send: BTC/L-BTC amount fields take **fiat** — the ⇅ unit chip
     (`shared/widgets/unit_chip.dart`) flips the field and converts the typed
     figure, a line under it shows the other reading, totals carry ≈ fiat.
     Pure arithmetic in `shared/amount_units.dart` (accepts a decimal comma;
     `test/amount_units_test.dart`). Same code on desktop and Android.
   - Receive: a **payment request** — the *Request an amount* disclosure under
     the address takes an amount (with the same ⇅ chip) and a note, and the
     QR, Copy and Share carry a BIP21 link instead of the bare address.
     Send accepts such a link wherever it accepts an address, filling the
     amount with it. `shared/payment_uri.dart` builds and parses;
     `test/payment_uri_test.dart` pins the round trip and
     `test/receive_request_test.dart` drives the screen. Both platforms, one
     code path — the phone only adds its labels above the fields.

## 7. Runtime hardening

- **KDF:** new vaults use Argon2id m=256 MiB on create and unlock. Android
  profile m=64 MiB (params live in `VaultHeader`, unlock stays correct).
- **Lifecycle:** add a flush FFI export, call on `paused/detached` so sled,
  registry and vault writes are durable. Internal app-private storage only.
- **Camera:** request at first scan; Android branch in `ur_qr.dart` gate.
  ✅ (alpha.13) the scanner's error view prints the plugin's error code and
  message, offers *Try again* and *Open app settings* (permission denied for
  good), and logs every failure to `templar.log`; `CAMERA` is declared in the
  app manifest; `mobile_scanner` 7.4.1 (7.2.1 fixed the camera not resuming
  after the activity was paused — which the permission prompt does).
- **Crash log:** `crash_log.dart` Android path via `path_provider`.

## 8. CI & distribution

✅ `android` job in `.github/workflows/release.yml`: a GitHub-hosted Ubuntu
runner builds the engine (`scripts/build_android.sh --release --so-only`),
then the two APKs signed with the release key from repository secrets
(`--apk-only`), and a `vX.Y.Z` tag publishes them as
`TemplarWallet-android-arm64.apk` / `TemplarWallet-android-x86_64.apk`.
The key, the secrets and a local signed build: `docs/build/RELEASE.md` § 4.
Play Store (AAB) later.

## 9. Phases

| Phase | Deliverable | Needs |
|---|---|---|
| 0 Rust unblock ✅ | rustls; hardware feature-gate; `wallet_set_data_dir` | — |
| 1 It boots ✅ | debug APK boots on the API 35 emulator with the real engine (`bridge: FfiWalletBridge`, `app.lock` in the injected dir); create/receive/sync on a phone still to be exercised | 0 |
| 2 Usable shell ✅ | carousel nav, header, SafeArea/edge-to-edge, padding, back, biometric unlock, icon+splash | 1 |
| 3 Screens ✅ | per-screen phone layouts (see §6.7); KDF profile + flush still open | 2 |
| 4 Pipeline | CI APK job, signing | 1 |
| 5 Later | HW over BLE/OTG; connector mobile UX | 3 |

## 10. Local toolchain status (2026-09-04, evening)

Installed via CLI into `~/Library/Android/sdk`: cmdline-tools, platform-tools,
platforms 34/35/36, build-tools 34/35/36, NDK 28.2.13676358 (27.2 also present), emulator, system
image `android-35;google_apis;arm64-v8a`, AVD `templar_api35` (pixel_6).
Java = Android Studio JBR 21 (`/Applications/Android Studio.app/Contents/jbr`).
`flutter doctor` ✓ Android toolchain. Rust targets + `cargo-ndk 4.1.2` present.
`android/` scaffolded (`applicationId dev.templarwallet.templarWallet`, minSdk
24, targetSdk 34, abiFilters arm64-v8a+x86_64, INTERNET, `templar://` filter,
`allowBackup=false`); `jniLibs/` is gitignored.
