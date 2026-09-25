#!/usr/bin/env bash
# Controls the Pale Blue Dot wallpaper.
#
#   ./wallpaper.sh install     build the player, set the matching still, start it now and at every login
#   ./wallpaper.sh start       start it again after stopping
#   ./wallpaper.sh stop        stop it (it still starts at the next login)
#   ./wallpaper.sh uninstall   stop it, remove the login item, go back to a plain gray desktop
#
# launchd runs the only copy, so starting twice never opens a second one.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.danishpuri.pale-blue-dot"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$DIR/build/pale-blue-dot"
VIDEO="$DIR/cosmos.mp4"
STILL="$DIR/cosmos.png"
DOMAIN="gui/$(id -u)"

set_desktop() {
    osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$1\"" >/dev/null
}

# macOS caches the desktop picture by path, so point it elsewhere first to pick up a re-rendered still.
refresh_desktop() {
    set_desktop "/System/Library/Desktop Pictures/Solid Colors/Black.png"
    set_desktop "$1"
}

case "${1:-}" in
    install)
        [ -f "$VIDEO" ] || { echo "No cosmos.mp4 yet. Run ./render-video.sh first."; exit 1; }
        mkdir -p "$DIR/build"
        swiftc -O "$DIR/wallpaper.swift" -o "$BIN"
        cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>$VIDEO</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        # Wait until launchd has fully let go of the old copy, or bootstrap fails.
        for _ in $(seq 20); do
            launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
            sleep 0.25
        done
        launchctl bootstrap "$DOMAIN" "$PLIST"
        refresh_desktop "$STILL"
        echo "Installed. The wallpaper is running and will start at every login."
        ;;
    start)
        launchctl kickstart "$DOMAIN/$LABEL"
        ;;
    stop)
        launchctl kill TERM "$DOMAIN/$LABEL" 2>/dev/null || echo "It wasn't running."
        ;;
    uninstall)
        launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        set_desktop "/System/Library/Desktop Pictures/Solid Colors/Space Gray.png"
        echo "Removed. The desktop is plain gray again."
        ;;
    *)
        echo "usage: $0 {install|start|stop|uninstall}"
        exit 1
        ;;
esac
