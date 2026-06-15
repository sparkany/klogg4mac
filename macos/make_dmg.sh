#!/usr/bin/env bash
#
# make_dmg.sh -- build KloggMac.app then package it into a distributable
# klogg.dmg containing the app plus an /Applications symlink, so the user can
# drag-install. Uses only stock macOS tooling (hdiutil); no third-party deps.
#
# Usage:   macos/make_dmg.sh [--debug]
#   --debug   forward to build_app.sh (debug swift build)
#
# ---------------------------------------------------------------------------
# TODO(signing/notarization): this produces an UNSIGNED dmg. The app inside
# should be code-signed BEFORE the dmg is built; then the dmg itself is
# notarized + stapled. See macos/PACKAGING.md for the exact commands and where
# to plug in your Developer ID / Team ID. Do NOT ship this dmg unsigned.
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # macos/
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/KloggMac.app"
PKG_ASSETS="$(cd "$SCRIPT_DIR/.." && pwd)/packaging/osx"

VOL_NAME="klogg"
DMG_OUT="$BUILD_DIR/klogg.dmg"
STAGING="$BUILD_DIR/dmg-staging"

# 1. Build (or rebuild) the app bundle.
echo "==> Building app bundle"
"$SCRIPT_DIR/build_app.sh" "$@"
[[ -d "$APP_BUNDLE" ]] || { echo "error: $APP_BUNDLE missing after build" >&2; exit 1; }

# 2. Lay out the dmg staging directory: the .app + a symlink to /Applications.
echo "==> Staging dmg contents"
rm -rf "$STAGING" "$DMG_OUT"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Optional: drop the dmg background image in for a styled layout. The classic
# Finder window styling (icon positions, hidden chrome) is applied by
# packaging/osx/dmg_setup.scpt, which expects an attached read-write image; we
# keep this script dependency-free and just ship the background so a future
# styling pass (or the signing step) can run the AppleScript if desired.
if [[ -f "$PKG_ASSETS/dmg_background.tif" ]]; then
    mkdir -p "$STAGING/.background"
    cp "$PKG_ASSETS/dmg_background.tif" "$STAGING/.background/background.tif"
fi

# 3. Build a compressed dmg straight from the folder.
echo "==> Creating $DMG_OUT"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_OUT"

rm -rf "$STAGING"

echo "==> Done: $DMG_OUT"
ls -lh "$DMG_OUT"
