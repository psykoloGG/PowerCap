#!/bin/bash
# Builds build/PowerCap.app. Pass --install to copy it to ~/Applications and relaunch it.
# Set POWERCAP_SIGN_IDENTITY to sign with a real certificate and the hardened runtime;
# otherwise the app is signed ad hoc for local use.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PowerCap.app"
INSTALL_PATH="$HOME/Applications/PowerCap.app"

swift build -c release --package-path "$ROOT"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PowerCap" "$APP/Contents/MacOS/PowerCap"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${POWERCAP_SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$POWERCAP_SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
    # SIGTERM makes the running copy quit cleanly and resume limited apps first.
    pkill -TERM -x PowerCap || true
    for _ in {1..40}; do
        pgrep -x PowerCap > /dev/null || break
        sleep 0.25
    done
    rm -rf "$INSTALL_PATH"
    ditto "$APP" "$INSTALL_PATH"
    open "$INSTALL_PATH"
fi
