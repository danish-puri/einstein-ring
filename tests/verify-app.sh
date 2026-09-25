#!/usr/bin/env bash
# Check a distributable app without opening windows, changing login items, or touching the desktop.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$DIR/build/app-package/Einstein Ring.app}"
BIN="$APP/Contents/MacOS/EinsteinRing"

# Verify Finder metadata, architecture, signature, and real AVFoundation media loading.
plutil -lint "$APP/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "com.danishpuri.einstein-ring"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" = "13.0"
lipo "$BIN" -verify_arch arm64
codesign --verify --deep --strict "$APP"
test -s "$APP/Contents/Resources/AppIcon.icns"
"$BIN" --check-resources

# Exercise damaged downloads only in a disposable copy of the app.
mkdir -p "$DIR/build"
CASE_DIR="$(mktemp -d "$DIR/build/app-check.XXXXXX")"
trap 'rm -rf "$CASE_DIR"' EXIT
ditto "$APP" "$CASE_DIR/Einstein Ring.app"
CASE_APP="$CASE_DIR/Einstein Ring.app"
CASE_BIN="$CASE_APP/Contents/MacOS/EinsteinRing"
RESOURCES="$CASE_APP/Contents/Resources"

# Each failure must report the intended media problem, rather than merely crashing.
expect_failure() {
    local expected="$1" output
    if output=$("$CASE_BIN" --check-resources 2>&1); then
        echo "FAIL: expected validation failure: $expected" >&2
        exit 1
    fi
    if [[ "$output" != *"$expected"* ]]; then
        echo "FAIL: unexpected diagnostic: $output" >&2
        exit 1
    fi
}

# Missing video, missing still, and corrupt video are distinct user-facing failure cases.
mv "$RESOURCES/cosmos.mp4" "$CASE_DIR/cosmos.mp4"
expect_failure "Video not found"
mv "$CASE_DIR/cosmos.mp4" "$RESOURCES/cosmos.mp4"
mv "$RESOURCES/cosmos.png" "$CASE_DIR/cosmos.png"
expect_failure "bundled still image is missing or invalid"
mv "$CASE_DIR/cosmos.png" "$RESOURCES/cosmos.png"
printf 'This is not a video.\n' > "$RESOURCES/cosmos.mp4"
expect_failure "FAIL:"
echo "PASS: app metadata, signature, valid assets, and damaged-download diagnostics."
