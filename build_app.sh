#!/bin/bash
# Builds UTM Studio.app — a double-clickable bundle you can drag to
# /Applications. Re-run this any time you change the Swift sources.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UTM Studio"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"

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
  echo "==> Version: $(plutil -extract CFBundleShortVersionString raw Info.plist) (no git tag found, using Info.plist default)"
fi

echo "==> Generating app icon..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
swift generate_icon.swift "$ICONSET_DIR" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true

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

echo ""
echo "Done: $APP_DIR"
echo "Drag it to /Applications, then launch it (right-click > Open the first"
echo "time, since it isn't notarized)."
echo "If Finder still shows a generic/blank icon, that's LaunchServices'"
echo "icon cache lagging, not a broken build — moving the app (e.g. into"
echo "/Applications) or relaunching Finder (killall Finder) clears it."
