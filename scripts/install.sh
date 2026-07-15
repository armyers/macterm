#!/usr/bin/env bash
set -euo pipefail

# Source app comes from `mise run build`, which exports a Release-signed .app
# under build/export/Macterm.app. The bundle name stays "Macterm" (PRODUCT_NAME),
# but we install it as "CYOTE-arm.app" — the fork's identity (CFBundleDisplayName
# / bundle id are "CYOTE-arm") — so it coexists with an upstream Macterm install
# at /Applications/Macterm.app, which this never touches.
SRC="./build/export/Macterm.app"
DEST="/Applications/CYOTE-arm.app"
if [[ ! -d $SRC ]]; then
  echo "ERROR: $SRC not found — run 'mise run build' first." >&2
  exit 1
fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"

codesign --verify --deep --strict --verbose=2 "$DEST"
