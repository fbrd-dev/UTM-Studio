#!/bin/bash
# Builds UTM Studio.app — a double-clickable bundle you can drag to
# /Applications. Re-run this any time you change the Swift sources.
#
# Plain `./build_app.sh` ad-hoc signs, same as always — fine for local use
# and AirDropping between your own Macs, but Gatekeeper will still warn
# other people (right-click > Open needed) since it's not from an
# identified developer.
#
# For a signed, notarized .dmg other people can just download and open
# with no warning, set these two environment variables (see
# DEVELOPMENT.md#signing--notarization for the one-time setup they depend
# on — an Apple Developer Program membership, a Developer ID Application
# certificate, and stored notarytool credentials):
#
#   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="your-stored-notarytool-profile-name" \
#   ./build_app.sh
#
# With both set, this signs with that identity instead of ad-hoc, submits
# the app for notarization and staples the ticket, builds a .dmg, then
# notarizes and staples the .dmg too (Gatekeeper checks the disk image
# itself, not just the app inside it, once it's carried a quarantine flag
# from a browser download).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UTM Studio"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# UTM Studio is Apple Silicon-only by design (see App.swift's arch(arm64)
# gate) — refuse to even attempt a build on an Intel machine rather than
# produce a binary whose only job is to show a "not supported" screen.
# `uname -m` reports the *build* machine's native arch; on an Apple Silicon
# Mac this is arm64 even when the shell itself is running under Rosetta, so
# this only ever blocks a genuinely Intel build host.
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "arm64" ]; then
  echo "ERROR: UTM Studio only builds on Apple Silicon (detected: $HOST_ARCH)." >&2
  echo "This app is Apple Silicon-only by design — see App.swift and README.md." >&2
  exit 1
fi

echo "==> Building release binary..."
swift build -c release

echo "==> Assembling ${APP_NAME}.app..."
rm -rf "dist"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/UTMStudio" "$APP_DIR/Contents/MacOS/UTMStudio"

BINARY_ARCH="$(file -b "$APP_DIR/Contents/MacOS/UTMStudio")"
case "$BINARY_ARCH" in
  *arm64*) ;;
  *)
    echo "ERROR: built binary is not arm64 ($BINARY_ARCH). Refusing to ship it." >&2
    exit 1
    ;;
esac

# The running app ALWAYS reads utm-client.sh from Contents/Resources — it's
# not a Settings field, not auto-detected from anywhere external, deliberately
# (see AppSettings.swift). utm-client.sh itself lives right here in the
# project folder (not as a sibling of it) specifically so that copying,
# AirDropping, or syncing this one folder is always self-contained — no
# separate file to remember to bring along. This copy step isn't optional:
# if it's skipped, the resulting .app is silently broken (no script
# anywhere), and that only surfaces later as a confusing runtime error. Fail
# loudly here instead, at build time, on whichever machine is doing the
# building.
if [ ! -f "utm-client.sh" ]; then
  echo "ERROR: utm-client.sh not found in this folder. The built .app would" >&2
  echo "have no script to run at all." >&2
  exit 1
fi
cp "utm-client.sh" "$APP_DIR/Contents/Resources/utm-client.sh"
chmod +x "$APP_DIR/Contents/Resources/utm-client.sh"

# Single source of truth also embedded into the raw binary itself (see
# Package.swift) so Xcode/`swift run` launches work the same as this bundle.
cp "Info.plist" "$APP_DIR/Contents/Info.plist"

# Version comes from the nearest git tag, not a hand-maintained number, so
# there's exactly one place a version ever gets decided: push a tag (e.g.
# `v1.2.0`) and this picks it up automatically — no separate "also update
# Info.plist" step to remember. Only affects this bundled copy, never the
# source Info.plist, so it doesn't create a git diff on every build. Falls
# back to Info.plist's own version for untagged/dev builds (e.g. no tags
# reachable yet, or building outside git entirely).
GIT_VERSION="$(git describe --tags --always 2>/dev/null || true)"
if [ -n "$GIT_VERSION" ]; then
  APP_VERSION="${GIT_VERSION#v}"
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP_DIR/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$APP_VERSION" "$APP_DIR/Contents/Info.plist"
  echo "==> Version: $APP_VERSION (from git tag)"
else
  APP_VERSION="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
  echo "==> Version: $APP_VERSION (no git tag found, using Info.plist default)"
fi

echo "==> Generating app icon..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
swift generate_icon.swift "$ICONSET_DIR" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

if [ -n "$SIGNING_IDENTITY" ]; then
  echo "==> Signing with Developer ID ($SIGNING_IDENTITY)..."
  # --options runtime (hardened runtime) and --timestamp (secure timestamp)
  # are both required for notarization to accept the signature at all —
  # ad-hoc signing below skips them since a plain "-" identity can't
  # produce a valid secure timestamp anyway.
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  echo "==> Ad-hoc signing (no SIGNING_IDENTITY set — this build will show"
  echo "    Gatekeeper warnings for anyone but you; see DEVELOPMENT.md for"
  echo "    real signing/notarization setup)..."
  codesign --force --deep --sign - "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true
fi

# Rebuilding at the same path repeatedly (same bundle ID, same location) can
# leave Finder showing a stale cached icon from an earlier build, even
# though the .icns file on disk is correct and current — a LaunchServices
# caching quirk, not a build defect. Re-registering after every build makes
# Finder notice the change immediately instead of waiting for it to expire
# on its own.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true
fi
touch "$APP_DIR"

notarize() {
  local target="$1"
  echo "==> Submitting $(basename "$target") for notarization (this can take a few minutes)..."
  xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait
}

staple() {
  local target="$1"
  echo "==> Stapling notarization ticket to $(basename "$target")..."
  xcrun stapler staple "$target"
}

if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  ZIP_PATH="$(mktemp -d)/${APP_NAME}.zip"
  # notarytool only accepts a zip/dmg/pkg, not a raw .app, so the app is
  # zipped just to upload it — but a ticket can only be STAPLED onto the
  # real .app/.dmg/.pkg, never onto that zip wrapper (stapler flatly
  # refuses zip files), so the staple target here is $APP_DIR, not $ZIP_PATH.
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
  notarize "$ZIP_PATH"
  staple "$APP_DIR"
  rm -f "$ZIP_PATH"
elif [ -n "$SIGNING_IDENTITY" ]; then
  echo "==> SIGNING_IDENTITY set but NOTARY_PROFILE isn't — skipping notarization."
  echo "    The app is properly signed but will still show a Gatekeeper warning"
  echo "    for anyone but you until it's notarized too."
fi

echo "==> Creating disk image..."
DMG_PATH="dist/${APP_NAME} - ${APP_VERSION}.dmg"
rm -f "$DMG_PATH"
DMG_STAGING="$(mktemp -d)/dmg"
mkdir -p "$DMG_STAGING"
cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$(dirname "$DMG_STAGING")"

if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  notarize "$DMG_PATH"
  staple "$DMG_PATH"
fi

echo ""
echo "Done: $APP_DIR"
if [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "Signed, notarized, and stapled: $DMG_PATH"
  echo "Anyone can download and open this — no Gatekeeper warning, no"
  echo "right-click bypass needed."
else
  echo "Also built: $DMG_PATH (not notarized — see the note above)."
  echo "Drag the .app to /Applications, then launch it (right-click > Open"
  echo "the first time, since it isn't notarized)."
fi
echo "If Finder still shows a generic/blank icon, that's LaunchServices'"
echo "icon cache lagging, not a broken build — moving the app (e.g. into"
echo "/Applications) or relaunching Finder (killall Finder) clears it."
