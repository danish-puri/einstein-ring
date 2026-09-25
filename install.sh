#!/usr/bin/env bash
# Installs the Einstein Ring wallpaper with one command, no cloning, Xcode, or rendering needed.
#
#   curl -fsSL https://raw.githubusercontent.com/danish-puri/einstein-ring/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/danish-puri/einstein-ring/main/install.sh | bash -s uninstall
#
# It downloads the rendered loop, its matching still, the prebuilt player, and wallpaper.sh from the
# latest release into ~/Library/Application Support/Einstein Ring, then runs wallpaper.sh install there.
#
# After changing wallpaper.swift or wallpaper.sh, rebuild the player and upload both to the release.
#   swiftc -O -target arm64-apple-macos12 wallpaper.swift -o pale-blue-dot
#   gh release upload v1.0 pale-blue-dot wallpaper.sh --clobber
set -euo pipefail

RELEASE="https://github.com/danish-puri/einstein-ring/releases/latest/download"
DIR="$HOME/Library/Application Support/Einstein Ring"

fail() { echo "$1" >&2; exit 1; }

# Downloads to a temporary name first, so a dropped connection never leaves half a file behind.
fetch() {
    curl -fL --progress-bar "$RELEASE/$1" -o "$2.part"
    mv "$2.part" "$2"
}

# Everything runs from here, so bash has read the whole script before any of it runs,
# even when it arrives through a pipe.
main() {
    if [ "${1:-}" = uninstall ]; then
        if [ -x "$DIR/wallpaper.sh" ]; then
            "$DIR/wallpaper.sh" uninstall </dev/null
        fi
        rm -rf "$DIR"
        echo "Einstein Ring is gone, including its downloaded files."
        return
    fi

    [ "$(uname -s)" = Darwin ] || fail "Einstein Ring only runs on macOS."
    # Checks the hardware rather than uname -m, which says x86_64 inside a Rosetta terminal.
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || fail "Einstein Ring needs a Mac with Apple silicon."

    mkdir -p "$DIR/build"
    echo "Downloading the video, about 130 MB."
    fetch cosmos.mp4 "$DIR/cosmos.mp4"
    echo "Downloading the still and the player."
    fetch cosmos.png "$DIR/cosmos.png"
    fetch pale-blue-dot "$DIR/build/pale-blue-dot"
    fetch wallpaper.sh "$DIR/wallpaper.sh"
    chmod +x "$DIR/build/pale-blue-dot" "$DIR/wallpaper.sh"

    "$DIR/wallpaper.sh" install </dev/null
    echo "To remove it later, run the same command with 'bash -s uninstall' at the end."
}

main "$@"
