# Packaging KloggMac for macOS

This documents how to turn the SwiftPM `KloggMac` executable into a standalone
`KloggMac.app` bundle and a distributable `klogg.dmg`, plus the (not-yet-done)
code-signing + notarization steps.

Everything here targets **arm64 / Apple Silicon** on a current macOS.

## Prerequisites

- The C++ engine static libraries must already be built in `build-arm64/`
  (see the build instructions at the top of `macos/KloggMac/Package.swift`).
- Qt 6 installed via Homebrew (`brew install qt`). This provides both the Qt
  frameworks and `macdeployqt`, which the build script uses to bundle them.

## Build the .app bundle

```sh
macos/build_app.sh           # release build (default)
macos/build_app.sh --debug   # debug swift build instead
```

This produces `macos/build/KloggMac.app`. The script:

1. Runs `swift build -c release` in `macos/KloggMac/`.
2. Assembles `KloggMac.app/Contents/{MacOS,Resources,Frameworks}` and copies in
   the executable, `Info.plist` (with the version from
   `build-arm64/generated/version.h` substituted in), and the app icon
   (`Resources/klogg.icns`).
3. Adds an `@executable_path/../Frameworks` rpath to the executable.
4. Runs **`macdeployqt`**, which recursively copies every Qt framework the app
   links, their transitive Homebrew dylib dependencies (icu, glib, pcre2,
   zstd, freetype, harfbuzz, ...), and the required Qt plugins
   (`platforms/`, `imageformats/`, `styles/`, `tls/`, ...) into
   `Contents/Frameworks` / `Contents/PlugIns`, rewriting their install names.
5. **Normalizes** any residual `/opt/homebrew` install-names that macdeployqt
   leaves behind (a few frameworks keep their own `LC_ID_DYLIB` pointing at the
   Homebrew prefix), then audits the whole bundle and fails loud if anything
   still references `/opt/homebrew`.

### Verifying it is standalone

The script prints `otool -L` of the bundled executable; every Qt framework
should resolve via `@executable_path/../Frameworks/...`, e.g.:

```
@executable_path/../Frameworks/QtCore.framework/Versions/A/QtCore
@executable_path/../Frameworks/QtCore5Compat.framework/Versions/A/QtCore5Compat
@executable_path/../Frameworks/QtGui.framework/Versions/A/QtGui
@executable_path/../Frameworks/QtWidgets.framework/Versions/A/QtWidgets
@executable_path/../Frameworks/QtNetwork.framework/Versions/A/QtNetwork
@executable_path/../Frameworks/QtConcurrent.framework/Versions/A/QtConcurrent
```

The final audit line should read
`clean -- no /opt/homebrew references anywhere in the bundle`.

Launch it with a log file to confirm it runs:

```sh
open macos/build/KloggMac.app --args "$PWD/test_data/ansi_colors_example.txt"
```

## Build the .dmg

```sh
macos/make_dmg.sh
```

This rebuilds the app, then stages `KloggMac.app` + an `/Applications` symlink
(and the `packaging/osx/dmg_background.tif` background) and produces a
compressed `macos/build/klogg.dmg` via `hdiutil`. Mount it to sanity-check:

```sh
hdiutil attach macos/build/klogg.dmg -nobrowse
# ... inspect /Volumes/klogg ...
hdiutil detach /Volumes/klogg
```

> The classic styled Finder layout (icon positions, hidden chrome) lives in
> `packaging/osx/dmg_setup.scpt`. The current script ships dependency-free and
> only embeds the background; running the AppleScript against a read-write
> image is an optional polish step that can be folded into the signing flow.

## Build artifacts are NOT committed

`macos/build/` and `*.dmg` are git-ignored (see `.gitignore`). Only the scripts,
`Info.plist`, and this doc are tracked.

---

## TODO: code signing + notarization (NOT done yet)

We do **not** have an Apple Developer identity in this environment, so the
bundle/dmg produced above are **unsigned** and will be blocked by Gatekeeper on
other machines. When you (the user) are ready to distribute, plug your
**Developer ID Application** certificate and **Team ID** into the steps below.

You will need:

- An Apple Developer Program membership.
- A **Developer ID Application** certificate in your login keychain
  (Xcode > Settings > Accounts, or downloaded from the developer portal).
  Find its name with `security find-identity -v -p codesigning`.
- An App Store Connect **API key** (or an app-specific password) for
  `notarytool`.

Replace the placeholders: `DEVELOPER_ID` (e.g.
`"Developer ID Application: Your Name (TEAMID)"`), `TEAMID`, and the notary
credentials.

### 1. Sign the app bundle

Sign inside-out (frameworks/plugins first, then the app) with the hardened
runtime enabled. `--deep` handles the nested frameworks; for finer control sign
each `Contents/Frameworks/*` and `Contents/PlugIns/*` explicitly first.

```sh
DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)"
APP="macos/build/KloggMac.app"

codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" \
    "$APP"

# Verify
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"   # may say "rejected" until notarized
```

> If you add an entitlements file, pass `--entitlements path/to/entitlements.plist`.
> A hardened-runtime Qt app generally needs no special entitlements, but JIT or
> disable-library-validation entitlements may be required for some plugins.

### 2. Build the dmg, then notarize it

Build the dmg AFTER signing the app (so the signed app is what ships), then
notarize the dmg:

```sh
macos/make_dmg.sh           # produces macos/build/klogg.dmg (now containing the signed app)
DMG="macos/build/klogg.dmg"

# Using an App Store Connect API key (recommended):
xcrun notarytool submit "$DMG" \
    --key   /path/to/AuthKey_XXXXXX.p8 \
    --key-id   "YOUR_KEY_ID" \
    --issuer   "YOUR_ISSUER_UUID" \
    --wait

# (Alternative: --apple-id you@example.com --team-id TEAMID --password app-specific-pw)
```

### 3. Staple the ticket

Once notarization succeeds, staple the ticket so the dmg validates offline:

```sh
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# Optionally also staple the app inside, before building the dmg:
# xcrun stapler staple "$APP"
```

After stapling, `spctl --assess --type install --verbose=4 "$DMG"` should
report **accepted**.

### Where this hooks into the scripts

- `macos/build_app.sh` has a `TODO(signing)` marker at the top showing where the
  `codesign` call goes (right after the bundle is assembled).
- `macos/make_dmg.sh` has a matching `TODO(signing/notarization)` marker — the
  app must be signed before `make_dmg.sh` runs, and the resulting dmg is what
  you submit to `notarytool` + `stapler`.
