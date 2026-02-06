#!/bin/bash
# Dev script - Build and hot-reload with preserved permissions
# Usage: ./dev.sh
#
# Uses your Apple Development certificate for consistent signing
# This preserves macOS permissions across rebuilds!

set -e

APP_NAME="Whisper Voice"
APP_PATH="/Applications/$APP_NAME.app"
BINARY_NAME="WhisperVoice"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICONS_DIR="$SCRIPT_DIR/../icons"

# Find a valid code signing identity
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [ -z "$SIGN_IDENTITY" ]; then
    echo "No Apple Development certificate found."
    echo "Falling back to ad-hoc signing (may require re-granting permissions)."
    SIGN_IDENTITY="-"
else
    echo "Using: $SIGN_IDENTITY"
fi

echo "Building..."
swift build -c release

# Create app bundle if it doesn't exist
if [ ! -d "$APP_PATH" ]; then
    echo "Creating app bundle..."
    mkdir -p "$APP_PATH/Contents/MacOS"
    mkdir -p "$APP_PATH/Contents/Resources"
    cp "Info.plist" "$APP_PATH/Contents/"
    if [ -f "$ICONS_DIR/AppIcon.icns" ]; then
        cp "$ICONS_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/"
    fi
fi

# Kill existing instance if running
if pgrep -x "$BINARY_NAME" > /dev/null; then
    echo "Stopping running instance..."
    pkill -x "$BINARY_NAME" || true
    sleep 0.5
fi

# Update binary
echo "Updating binary..."
cp .build/release/$BINARY_NAME "$APP_PATH/Contents/MacOS/$BINARY_NAME"

# Sign with consistent identity
echo "Signing..."
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_PATH"

# Relaunch
echo "Launching..."
open "$APP_PATH"

echo ""
echo "Done! Permissions preserved."
