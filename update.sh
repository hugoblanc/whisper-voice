#!/bin/bash

set -e

echo "🔄 Updating Whisper Voice..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pull latest changes
echo "Fetching updates..."
git pull

# Rebuild
echo ""
echo "Rebuilding..."
cd WhisperVoice
swift build -c release 2>&1 | grep -v "^Build complete"

# Update app bundle
APP_PATH="$HOME/Applications/Whisper Voice.app"
if [ -d "$APP_PATH" ]; then
    echo "Updating app bundle..."
    pkill -f "WhisperVoice" 2>/dev/null || true
    sleep 1
    cp ".build/release/WhisperVoice" "$APP_PATH/Contents/MacOS/WhisperVoice"
    codesign --force --deep --sign - "$APP_PATH"
fi

echo ""
echo "✅ Update complete!"
echo ""
echo "Restart the app:"
echo "  open -a \"Whisper Voice\""
