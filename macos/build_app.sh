#!/usr/bin/env bash
#
# build_app.sh -- assemble a standalone KloggMac.app bundle.
#
# Produces macos/build/KloggMac.app: a self-contained application that bundles
# the Qt frameworks (and their transitive Homebrew dependencies + Qt plugins)
# inside Contents/Frameworks, with all install names rewritten to
# @executable_path/../Frameworks via Qt's own macdeployqt. The result runs on a
# machine without Homebrew/Qt installed.
#
# Usage:   macos/build_app.sh [--debug]
#   --debug   use the debug swift build instead of release (faster, larger)
#
# Prerequisites (already satisfied in this repo):
#   * The C++ engine static libs in build-arm64/output (cmake build).
#   * Qt 6 installed via Homebrew (provides macdeployqt + the frameworks).
#
# ---------------------------------------------------------------------------
# TODO(signing): this script produces an UNSIGNED bundle. After it completes,
# the code-signing + notarization step plugs in here. See macos/PACKAGING.md.
# Roughly:
#   codesign --force --deep --options runtime --timestamp \
#       --sign "Developer ID Application: <NAME> (<TEAMID>)" \
#       "$APP_BUNDLE"
#   # then notarize the .dmg (see make_dmg.sh / PACKAGING.md).
# ---------------------------------------------------------------------------

set -euo pipefail

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
    CONFIG="debug"
fi

# --- paths ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # macos/
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$SCRIPT_DIR/KloggMac"                                # SwiftPM package
BUILD_DIR="$SCRIPT_DIR/build"                                 # bundle output dir
APP_BUNDLE="$BUILD_DIR/KloggMac.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"

QT_PREFIX="$(brew --prefix qt)"
MACDEPLOYQT="$QT_PREFIX/bin/macdeployqt"
if [[ ! -x "$MACDEPLOYQT" ]]; then
    MACDEPLOYQT="$(command -v macdeployqt || true)"
fi
if [[ -z "$MACDEPLOYQT" || ! -x "$MACDEPLOYQT" ]]; then
    echo "error: macdeployqt not found (looked in $QT_PREFIX/bin and PATH)" >&2
    exit 1
fi

echo "==> Building SwiftPM executable ($CONFIG)"
( cd "$PKG_DIR" && swift build -c "$CONFIG" )
EXE="$PKG_DIR/.build/arm64-apple-macosx/$CONFIG/KloggMac"
if [[ ! -x "$EXE" ]]; then
    echo "error: built executable not found at $EXE" >&2
    exit 1
fi

# --- version (read from generated header) ---------------------------------
VERSION_H="$REPO_ROOT/build-arm64/generated/version.h"
KLOGG_VERSION="$(sed -n 's/^#define KLOGG_VERSION "\(.*\)"/\1/p' "$VERSION_H" 2>/dev/null || true)"
KLOGG_VERSION="${KLOGG_VERSION:-24.11.0.0}"
# CFBundleShortVersionString wants at most three components (x.y.z).
SHORT_VERSION="$(echo "$KLOGG_VERSION" | cut -d. -f1-3)"
echo "==> klogg version: $KLOGG_VERSION (short $SHORT_VERSION)"

# --- assemble skeleton ----------------------------------------------------
echo "==> Assembling bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR"

cp "$EXE" "$MACOS_DIR/KloggMac"

# Info.plist with versions substituted in.
sed -e "s#<string>24\.11\.0</string>#<string>$SHORT_VERSION</string>#" \
    -e "s#<string>24\.11\.0\.0</string>#<string>$KLOGG_VERSION</string>#" \
    "$SCRIPT_DIR/Info.plist" > "$CONTENTS/Info.plist"

# App icon. The repo ships a real klogg.icns under Resources/.
ICON_SRC="$REPO_ROOT/Resources/klogg.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RES_DIR/klogg.icns"
else
    # TODO(art): no klogg.icns found -- the bundle will use a generic icon.
    echo "warning: $ICON_SRC missing; bundle will have no custom icon" >&2
fi

# PkgInfo (classic, harmless, expected by some tools).
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- ensure the executable can find bundled frameworks --------------------
# Add @executable_path/../Frameworks as an rpath so the Qt libs (whose install
# names macdeployqt rewrites to @rpath/...) resolve inside the bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$MACOS_DIR/KloggMac" 2>/dev/null || true

# --- bundle Qt with macdeployqt -------------------------------------------
# macdeployqt recursively copies the Qt frameworks the binary links, their
# transitive Homebrew dylib deps (icu, glib, pcre2, zstd, ...) and the required
# Qt plugins, then rewrites every install name to @executable_path/../Frameworks
# (or @rpath). It is the canonical, robust way to make a Qt app standalone.
echo "==> Running macdeployqt"
"$MACDEPLOYQT" "$APP_BUNDLE" -verbose=1 || {
    echo "error: macdeployqt failed" >&2
    exit 1
}

# macdeployqt leaves a handful of residual /opt/homebrew references behind --
# typically a framework's own LC_ID_DYLIB, plus a few cross-references between
# the libs it copied. Normalize the whole bundle: for every Mach-O file under
# Frameworks/ and PlugIns/ (and the main executable), rewrite any /opt/homebrew
# install-name (id) or dependency reference to the equivalent bundled path.
# This is what makes the bundle truly standalone (and cleanly signable).
echo "==> Normalizing install names across the bundle"

# Map an absolute /opt/homebrew dependency string to its bundled @rpath form,
# or echo nothing if the target isn't actually present in the bundle.
bundled_path_for() {
    local dep="$1" base fw_name rel
    if [[ "$dep" == *".framework/"* ]]; then
        fw_name="$(basename "${dep%%.framework/*}").framework"   # QtFoo.framework
        rel="${dep#*"$fw_name"/}"                                # Versions/A/QtFoo
        [[ -e "$FRAMEWORKS_DIR/$fw_name/$rel" ]] && echo "@rpath/$fw_name/$rel"
    else
        base="$(basename "$dep")"                                # libfoo.N.dylib
        [[ -e "$FRAMEWORKS_DIR/$base" ]] && echo "@rpath/$base"
    fi
}

normalize_macho() {
    local f="$1"
    file "$f" 2>/dev/null | grep -q "Mach-O" || return 0

    # Fix the dylib's own id if it still points at homebrew.
    local cur_id new_id
    cur_id="$(otool -D "$f" 2>/dev/null | tail -n +2)"
    if [[ "$cur_id" == /opt/homebrew/* ]]; then
        new_id="$(bundled_path_for "$cur_id")"
        [[ -n "$new_id" ]] && install_name_tool -id "$new_id" "$f" 2>/dev/null || true
    fi

    # Fix each dependency reference that still points at homebrew.
    local dep new_dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        new_dep="$(bundled_path_for "$dep")"
        if [[ -n "$new_dep" ]]; then
            install_name_tool -change "$dep" "$new_dep" "$f" 2>/dev/null || true
        else
            echo "    note: $(basename "$f") -> $dep is not bundled; leaving as-is" >&2
        fi
    done < <(otool -L "$f" 2>/dev/null | awk '/\/opt\/homebrew/ {print $1}')
}

while IFS= read -r f; do
    normalize_macho "$f"
done < <(find "$FRAMEWORKS_DIR" "$CONTENTS/PlugIns" -type f 2>/dev/null)
normalize_macho "$MACOS_DIR/KloggMac"

# --- report ----------------------------------------------------------------
echo "==> otool -L of bundled executable (Qt should be @rpath/@executable_path):"
otool -L "$MACOS_DIR/KloggMac" | grep -iE "qt|homebrew" || echo "    (no Qt/homebrew refs -- good)"

# Audit the entire bundle for any remaining absolute Homebrew references.
echo "==> Auditing whole bundle for residual /opt/homebrew references"
residual=0
while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" || continue
    if otool -L "$f" 2>/dev/null | grep -q "/opt/homebrew" \
       || otool -D "$f" 2>/dev/null | tail -n +2 | grep -q "/opt/homebrew"; then
        echo "    RESIDUAL: ${f#"$APP_BUNDLE"/}" >&2
        residual=1
    fi
done < <(find "$FRAMEWORKS_DIR" "$CONTENTS/PlugIns" "$MACOS_DIR" -type f 2>/dev/null)
if [[ "$residual" -eq 0 ]]; then
    echo "    clean -- no /opt/homebrew references anywhere in the bundle"
else
    echo "WARNING: bundle still has /opt/homebrew references (see RESIDUAL above)" >&2
fi

# --- ad-hoc code signing ---------------------------------------------------
# install_name_tool rewrites above INVALIDATE each Mach-O's signature, and on
# Apple Silicon an invalid/absent signature makes the binary refuse to launch
# ("code signature invalid" / killed). Re-sign ad-hoc (no Developer ID): the app
# then runs locally and on other Macs after the user clears the download
# quarantine. (For a notarised, Gatekeeper-clean build, set KLOGG_SIGN_IDENTITY
# to a "Developer ID Application: …" identity — see the header TODO.)
echo "==> Ad-hoc code-signing the bundle (nested code first, then the app)"
SIGN_ID="${KLOGG_SIGN_IDENTITY:--}"   # "-" = ad-hoc
while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" || continue
    codesign --force --timestamp=none --sign "$SIGN_ID" "$f" 2>/dev/null || true
done < <(find "$FRAMEWORKS_DIR" "$CONTENTS/PlugIns" -type f 2>/dev/null)
find "$FRAMEWORKS_DIR" -maxdepth 1 -name '*.framework' -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --timestamp=none --sign "$SIGN_ID" {} 2>/dev/null || true
codesign --force --timestamp=none --sign "$SIGN_ID" "$MACOS_DIR/KloggMac" 2>/dev/null || true
codesign --force --timestamp=none --sign "$SIGN_ID" "$APP_BUNDLE"
echo "==> codesign verify:"; codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE" 2>&1 | tail -2 || true

echo "==> Done: $APP_BUNDLE"
