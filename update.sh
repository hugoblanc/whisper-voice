#!/bin/bash
#
# Rebuild local Swift sources and swap the binary inside the installed app
# bundle, preserving Developer ID signing + entitlements (the combo required
# for the mic prompt and hardened-runtime checks — see CLAUDE.md).
#
# This script intentionally does NOT run `git pull` — it ships the current
# working tree. Use it for local dev iterations; use build-dmg.sh for
# release/distribution.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "🔄 Updating Whisper Voice (local rebuild)..."
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/WhisperVoice"
ENTITLEMENTS_PATH="$PROJECT_DIR/WhisperVoice.entitlements"
APP_PATH="/Applications/Whisper Voice.app"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: $APP_PATH not found.${NC}"
    echo "Install the app first (build-dmg.sh + install the DMG, or run install.sh)."
    exit 1
fi

if [ ! -f "$ENTITLEMENTS_PATH" ]; then
    echo -e "${RED}Error: entitlements file missing at $ENTITLEMENTS_PATH${NC}"
    echo "Signing without entitlements silently denies mic access — refusing to proceed."
    exit 1
fi

# Rebuild
echo -e "${CYAN}Rebuilding (release)...${NC}"
cd "$PROJECT_DIR"
swift build -c release 2>&1 | grep -v "^Build complete" || true

BIN_PATH=".build/release/WhisperVoice"
if [ ! -f "$BIN_PATH" ]; then
    echo -e "${RED}Error: build produced no binary at $BIN_PATH${NC}"
    exit 1
fi

# Kill running instance
echo -e "${CYAN}Stopping running instance...${NC}"
pkill -f "Whisper Voice.app/Contents/MacOS/WhisperVoice" 2>/dev/null || true
pkill -x WhisperVoice 2>/dev/null || true
sleep 1

# Swap the binary
echo -e "${CYAN}Swapping binary in $APP_PATH...${NC}"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/WhisperVoice"

# Re-sign with Developer ID + entitlements when available; fall back to
# ad-hoc + entitlements otherwise (mic still works, but not distributable).
DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$DEVELOPER_ID" ]; then
    echo -e "${CYAN}Signing with:${NC} ${YELLOW}$DEVELOPER_ID${NC}"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_PATH" \
        --sign "$DEVELOPER_ID" \
        "$APP_PATH"
else
    echo -e "${YELLOW}Developer ID not found — falling back to ad-hoc signing with entitlements.${NC}"
    echo -e "${YELLOW}(Mic access will work locally, but the app is NOT distributable.)${NC}"
    codesign --force --options runtime \
        --entitlements "$ENTITLEMENTS_PATH" \
        --sign - \
        "$APP_PATH"
fi

# Verify signature
echo -e "${CYAN}Verifying signature...${NC}"
codesign --verify --strict --verbose=2 "$APP_PATH" 2>&1 | tail -3
codesign -d --entitlements - "$APP_PATH" 2>&1 | grep -E "audio-input|automation" || {
    echo -e "${RED}Warning: mic / AppleScript entitlements missing from signed binary.${NC}"
}

echo ""
echo -e "${GREEN}✅ Local update complete!${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} the new CDHash invalidates previously granted TCC permissions."
echo "Re-grant Mic / Accessibility / Input Monitoring if the app misbehaves."
echo ""
echo "Launch:  open -a \"Whisper Voice\""
