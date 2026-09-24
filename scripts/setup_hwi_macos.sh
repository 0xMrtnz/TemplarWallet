#!/bin/bash
# Sets up the app-managed HWI toolchain for USB hardware-wallet support on macOS.
#
# wallet-ffi looks for <app data dir>/venv/bin/hwi at startup (state.rs) and
# exports TEMPLAR_HWI_BIN for the HWI subprocess calls. This script creates that
# venv and installs HWI into it, so Jade/Ledger/Trezor enumeration works when
# the app is launched normally (no shell environment needed).
#
# Usage: ./scripts/setup_hwi_macos.sh
set -euo pipefail

DATA_DIR="$HOME/Library/Containers/dev.templarwallet.templarWallet/Data/Library/Application Support/templar_wallet"
mkdir -p "$DATA_DIR"

VENV="$DATA_DIR/venv"
echo "Creating venv at: $VENV"
python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install hwi

echo
echo "HWI installed: $("$VENV/bin/hwi" --version)"
echo "Connect + unlock your device, then test with:"
echo "  \"$VENV/bin/hwi\" enumerate"
