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
VERSION="3.2.0"
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

# Build the app
echo -e "${YELLOW}[3/5]${NC} Building application..."
cd "$PROJECT_DIR"
swift build -c release

if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi
echo -e "${GREEN}OK${NC}"
echo ""

# Create app bundle
echo -e "${YELLOW}[4/5]${NC} Creating app bundle..."
APP_PATH="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy executable
cp ".build/release/WhisperVoice" "$APP_PATH/Contents/MacOS/WhisperVoice"

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

# Sign the app with Developer ID certificate
DEVELOPER_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$DEVELOPER_ID" ]; then
    echo -e "Signing with: ${YELLOW}$DEVELOPER_ID${NC}"
    codesign --force --deep --options runtime --sign "$DEVELOPER_ID" "$APP_PATH"
else
    echo -e "${YELLOW}Warning: Developer ID not found, using ad-hoc signing${NC}"
    codesign --force --deep --sign - "$APP_PATH"
fi

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

# Create DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP" \
    -ov -format UDZO \
    "$BUILD_DIR/$DMG_NAME"

# Cleanup
rm -rf "$DMG_TEMP"

echo -e "${GREEN}OK${NC}"
echo ""

echo -e "${GREEN}${BOLD}"
echo "========================================"
echo "         Build Complete!               "
echo "========================================"
echo -e "${NC}"
echo ""
echo -e "DMG created at: ${CYAN}$BUILD_DIR/$DMG_NAME${NC}"
echo ""
echo "To install:"
echo "  1. Open the DMG"
echo "  2. Drag 'Whisper Voice' to Applications"
echo "  3. Launch the app - it will ask for your API key"
echo ""
echo "File size: $(du -h "$BUILD_DIR/$DMG_NAME" | cut -f1)"
echo ""
