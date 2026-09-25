#!/usr/bin/env bash
# Build a self-contained Apple-silicon app and drag-to-Applications disk image.
# End users need neither these tools nor a network connection to play the wallpaper.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$DIR/build/app-package"
APP="$BUILD/Einstein Ring.app"
CONTENTS="$APP/Contents"
DIST="$DIR/dist"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

# Fail before packaging if the maintainer has not supplied both rendered assets.
for asset in cosmos.mp4 cosmos.png; do
    if [ ! -s "$DIR/$asset" ]; then
        echo "Missing $asset. Download the v1.0 media assets or run ./render-video.sh first." >&2
        exit 1
    fi
done
for tool in swiftc sips iconutil codesign hdiutil ditto; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Notarization requires a Developer ID SIGNING_IDENTITY." >&2
    exit 1
fi
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$DIST"

# Target Ventura explicitly; this also catches accidental use of newer-only APIs.
swiftc -O -target arm64-apple-macos13.0 "$DIR/wallpaper.swift" -o "$CONTENTS/MacOS/EinsteinRing"
cp "$DIR/app/Info.plist" "$CONTENTS/Info.plist"
cp "$DIR/cosmos.mp4" "$DIR/cosmos.png" "$DIR/LICENSE" "$CONTENTS/Resources/"
plutil -lint "$CONTENTS/Info.plist"

# Generate all standard Retina and non-Retina icon sizes from the native drawing.
swiftc -O "$DIR/app/make-icon.swift" -o "$BUILD/make-icon"
"$BUILD/make-icon" "$BUILD/icon.png"
mkdir -p "$BUILD/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$BUILD/icon.png" --out "$BUILD/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

# Ad-hoc signing makes a runnable arm64 app. Developer ID adds notarizable identity.
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
"$CONTENTS/MacOS/EinsteinRing" --check-resources

# When credentials are available, staple Apple's ticket before creating either download.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
    xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

# The DMG contains one app, an Applications shortcut, and short offline instructions.
STAGE="$BUILD/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Einstein Ring.app"
ln -sfn /Applications "$STAGE/Applications"
cp "$DIR/app/Install.txt" "$STAGE/How to Install.txt"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    cp "$DIR/app/Install-notarized.txt" "$STAGE/How to Install.txt"
fi
hdiutil create -volname "Einstein Ring" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Einstein-Ring.dmg"

# A signed and notarized outer disk image also passes Gatekeeper assessment itself.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    codesign --timestamp --sign "$SIGNING_IDENTITY" "$DIST/Einstein-Ring.dmg"
    xcrun notarytool submit "$DIST/Einstein-Ring.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DIST/Einstein-Ring.dmg"
    xcrun stapler validate "$DIST/Einstein-Ring.dmg"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Einstein-Ring.zip"
(cd "$DIST" && shasum -a 256 Einstein-Ring.dmg Einstein-Ring.zip > SHA256SUMS.txt)
echo "Built $DIST/Einstein-Ring.dmg and $DIST/Einstein-Ring.zip"
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "This build is not notarized. See app/Install.txt for the first-open approval."
fi
