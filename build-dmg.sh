#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# Config
APP_NAME="Whisper Voice"
VERSION="3.6.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/WhisperVoice"
BUILD_DIR="$SCRIPT_DIR/build"
DMG_NAME="WhisperVoice-${VERSION}.dmg"

echo -e "${BLUE}${BOLD}"
echo "========================================"
echo "    Whisper Voice - Build DMG          "
echo "         Version $VERSION              "
echo "========================================"
echo -e "${NC}"
echo ""

# Check for Xcode tools
echo -e "${YELLOW}[1/5]${NC} Checking build tools..."
if ! command -v swift &> /dev/null; then
    echo -e "${RED}Error: Swift not found. Install Xcode Command Line Tools.${NC}"
    exit 1
fi
echo -e "${GREEN}OK${NC}"
echo ""

# Clean build directory
echo -e "${YELLOW}[2/5]${NC} Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo -e "${GREEN}OK${NC}"
echo ""

# Build the app for both architectures, lipo together so a single .app works
# on Apple Silicon and Intel.
echo -e "${YELLOW}[3/5]${NC} Building application (arm64 + x86_64)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 || { echo -e "${RED}arm64 build failed${NC}"; exit 1; }
swift build -c release --arch x86_64 || { echo -e "${RED}x86_64 build failed${NC}"; exit 1; }

UNIVERSAL_BIN="$PROJECT_DIR/.build/universal/WhisperVoice"
mkdir -p "$(dirname "$UNIVERSAL_BIN")"
lipo -create \
    "$PROJECT_DIR/.build/arm64-apple-macosx/release/WhisperVoice" \
    "$PROJECT_DIR/.build/x86_64-apple-macosx/release/WhisperVoice" \
    -output "$UNIVERSAL_BIN" || { echo -e "${RED}lipo failed${NC}"; exit 1; }
echo -e "${GREEN}OK${NC} (universal binary: $(lipo -archs "$UNIVERSAL_BIN"))"
echo ""

# Create app bundle
echo -e "${YELLOW}[4/5]${NC} Creating app bundle..."
APP_PATH="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy executable (universal binary)
cp "$UNIVERSAL_BIN" "$APP_PATH/Contents/MacOS/WhisperVoice"

# Copy Info.plist
cp "Info.plist" "$APP_PATH/Contents/"

# Copy icon if exists
if [ -f "$SCRIPT_DIR/icons/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/icons/AppIcon.icns" "$APP_PATH/Contents/Resources/"
fi

# Copy whisper-server if exists
if [ -f "$PROJECT_DIR/Resources/whisper-server" ]; then
    cp "$PROJECT_DIR/Resources/whisper-server" "$APP_PATH/Contents/MacOS/"
    chmod +x "$APP_PATH/Contents/MacOS/whisper-server"
    echo -e "  ${GREEN}+${NC} whisper-server included"
fi

# Sign the app with Developer ID certificate + entitlements.
# NOTE: --timestamp is critical for notarization — Apple refuses submissions
# that don't have a secure Apple-signed timestamp embedded in the signature.
ENTITLEMENTS_PATH="$PROJECT_DIR/WhisperVoice.entitlements"
DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$DEVELOPER_ID" ]; then
    echo -e "Signing with: ${YELLOW}$DEVELOPER_ID${NC}"
    if [ -f "$ENTITLEMENTS_PATH" ]; then
        codesign --force --deep --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS_PATH" \
            --sign "$DEVELOPER_ID" "$APP_PATH"
    else
        echo -e "${RED}Warning: $ENTITLEMENTS_PATH not found — signing without entitlements (mic/AppleScript may fail)${NC}"
        codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_PATH"
    fi
else
    echo -e "${YELLOW}Warning: Developer ID not found, using ad-hoc signing (NOT distributable)${NC}"
    codesign --force --deep --sign - "$APP_PATH"
fi

# Verify signing is valid before we even think about notarizing.
codesign --verify --deep --strict --verbose=2 "$APP_PATH" || {
    echo -e "${RED}codesign verification failed — aborting${NC}"
    exit 1
}

echo -e "${GREEN}OK${NC}"
echo ""

# Create DMG
echo -e "${YELLOW}[5/5]${NC} Creating DMG..."
cd "$BUILD_DIR"

# Create temporary DMG directory
DMG_TEMP="$BUILD_DIR/dmg_temp"
mkdir -p "$DMG_TEMP"

# Copy app to temp directory
cp -R "$APP_PATH" "$DMG_TEMP/"

# Create symbolic link to Applications
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG (single file, then duplicate with arch-suffixed names so
# GitHub release URLs WhisperVoice-${VERSION}-AppleSilicon.dmg and
# -Intel.dmg both resolve — both are the same universal artifact).
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$BUILD_DIR/$DMG_NAME"

# Cleanup temp before notarization so only the DMG remains
rm -rf "$DMG_TEMP"

echo -e "${GREEN}OK${NC}"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# Notarization + stapling
# ────────────────────────────────────────────────────────────────────────────
# macOS Gatekeeper rejects unnotarized apps with "cannot be opened because the
# developer cannot be verified" — and for downloads with the quarantine flag,
# the app gets MOVED TO TRASH on open. Notarization is how Apple scans + signs
# off on the bundle. Stapling embeds the notary ticket so offline installs work.
#
# Requires credentials stored once via:
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#       --apple-id <email> --team-id 3V5QFA3LEY --password <app-specific-pwd>
NOTARY_PROFILE="whispervoice-notary"

echo -e "${YELLOW}[+]${NC} Notarizing DMG with Apple (this usually takes 1-3 minutes)..."
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    echo -e "${RED}Notarization credentials not found for profile '$NOTARY_PROFILE'.${NC}"
    echo -e "${YELLOW}Run this once to set them up:${NC}"
    echo ""
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\"
    echo "      --apple-id <your-apple-id-email> \\"
    echo "      --team-id 3V5QFA3LEY \\"
    echo "      --password <app-specific-password from appleid.apple.com>"
    echo ""
    echo -e "${YELLOW}Skipping notarization. The DMG is signed but will be rejected by Gatekeeper on other Macs.${NC}"
    SKIP_NOTARIZATION=1
else
    SKIP_NOTARIZATION=0
    SUBMIT_OUTPUT=$(xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1)
    echo "$SUBMIT_OUTPUT"

    STATUS=$(echo "$SUBMIT_OUTPUT" | awk '/status:/ {print $2}' | tail -1)
    if [ "$STATUS" != "Accepted" ]; then
        echo -e "${RED}Notarization failed (status: $STATUS). Run this for details:${NC}"
        SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | awk '/id:/ {print $2}' | head -1)
        echo "  xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE"
        exit 1
    fi

    echo -e "${YELLOW}[+]${NC} Stapling notarization ticket to the DMG..."
    xcrun stapler staple "$BUILD_DIR/$DMG_NAME" || {
        echo -e "${RED}Stapling failed${NC}"
        exit 1
    }
    echo -e "${GREEN}OK${NC} — Gatekeeper will now accept the DMG offline"
fi

# Duplicate the notarized + stapled DMG to arch-named copies for GitHub URLs.
# Both are the same universal artifact so no need to re-notarize.
cp "$BUILD_DIR/$DMG_NAME" "$BUILD_DIR/WhisperVoice-${VERSION}-AppleSilicon.dmg"
cp "$BUILD_DIR/$DMG_NAME" "$BUILD_DIR/WhisperVoice-${VERSION}-Intel.dmg"

# Final Gatekeeper assessment so the user sees it PASS (or why it didn't).
echo ""
echo -e "${YELLOW}[+]${NC} Final Gatekeeper check:"
spctl -a -vv --type open --context context:primary-signature \
    "$BUILD_DIR/$DMG_NAME" 2>&1 || true
echo ""

echo -e "${GREEN}${BOLD}"
echo "========================================"
echo "         Build Complete!               "
echo "========================================"
echo -e "${NC}"
echo ""
echo -e "DMG created at: ${CYAN}$BUILD_DIR/$DMG_NAME${NC}"
if [ "$SKIP_NOTARIZATION" = "1" ]; then
    echo -e "${RED}⚠ Not notarized — users on other Macs will see Gatekeeper warnings.${NC}"
fi
echo ""
echo "To install:"
echo "  1. Open the DMG"
echo "  2. Drag 'Whisper Voice' to Applications"
echo "  3. Launch the app - it will ask for your API key"
echo ""
echo "File size: $(du -h "$BUILD_DIR/$DMG_NAME" | cut -f1)"
echo ""
