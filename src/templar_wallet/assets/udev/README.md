# Bundled HWI udev rules (Linux)

Verbatim copies of `hwilib/udev/*.rules` from
[bitcoin-core/HWI](https://github.com/bitcoin-core/HWI) tag **3.2.0** (MIT).

## Why they are vendored

On Linux a non-root process cannot open a hardware wallet's USB/HID/serial node
until udev grants access. Without these rules `hwi enumerate` returns an empty
list or a permission error, which is the single most common first-run failure
on the platform — and the one users are least likely to diagnose themselves.

They are bundled rather than downloaded at install time so the fix works
offline, is reviewable in this repository, and cannot change under us between
releases. HWI 3.x dropped the `installudevrules` subcommand, so shelling out to
HWI is no longer an option either.

`lib/services/udev_installer.dart` writes these files to
`/etc/udev/rules.d/` via `pkexec`, then reloads udev. Nothing is installed
without the user pressing the button and authenticating.

## Updating

Re-download from the HWI tag the app is tested against and update the tag above:

```bash
TAG=3.2.0
for f in 20-hw1 51-coinkite 51-hid-digitalbitbox 51-trezor 51-usb-keepkey \
         52-hid-digitalbitbox 53-hid-bitbox02 54-hid-bitbox02 55-usb-jade; do
  curl -sfL -o "$f.rules" \
    "https://raw.githubusercontent.com/bitcoin-core/HWI/$TAG/hwilib/udev/$f.rules"
done
```

Keep the file list in sync with `udev_rules_installed()` in
`src/wallet-ffi/src/handlers/hw.rs`, which probes for these names to decide
whether to offer the fix.
