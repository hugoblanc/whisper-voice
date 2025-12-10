#!/bin/bash

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/WhisperVoice"
APP_NAME="Whisper Voice"
APP_PATH="$HOME/Applications/$APP_NAME.app"
CONFIG_PATH="$HOME/.whisper-voice-config.json"
ICONS_DIR="$SCRIPT_DIR/icons"

# Header
clear
echo -e "${BLUE}${BOLD}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                                                           ║"
echo "║             🎤 Whisper Voice - Installation               ║"
echo "║                      Swift Edition                        ║"
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# Step 1: Check Xcode Command Line Tools
echo -e "${CYAN}[1/5]${NC} Checking build tools..."
if ! command -v swift &> /dev/null; then
    echo -e "${YELLOW}Swift not found. Installing Xcode Command Line Tools...${NC}"
    xcode-select --install
    echo ""
    echo -e "${YELLOW}Please complete the installation popup, then run this script again.${NC}"
    exit 1
fi
SWIFT_VERSION=$(swift --version | head -1)
echo -e "${GREEN}✓${NC} $SWIFT_VERSION"
echo ""

# Step 2: Configure API Key
echo -e "${CYAN}[2/5]${NC} OpenAI API Configuration"
echo ""

CURRENT_KEY=""
if [ -f "$CONFIG_PATH" ]; then
    CURRENT_KEY=$(cat "$CONFIG_PATH" 2>/dev/null | grep -o '"apiKey"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
fi

if [ -n "$CURRENT_KEY" ]; then
    MASKED_KEY="${CURRENT_KEY:0:7}...${CURRENT_KEY: -4}"
    echo -e "Current API key: ${YELLOW}$MASKED_KEY${NC}"
    read -p "Keep this key? (Y/n): " KEEP_KEY
    if [[ "$KEEP_KEY" =~ ^[Nn]$ ]]; then
        CURRENT_KEY=""
    fi
fi

if [ -z "$CURRENT_KEY" ]; then
    echo ""
    echo "Get your API key at: https://platform.openai.com/api-keys"
    echo ""
    read -p "Enter your OpenAI API key: " API_KEY

    if [ -z "$API_KEY" ]; then
        echo -e "${RED}Error: API key is required${NC}"
        exit 1
    fi
else
    API_KEY="$CURRENT_KEY"
fi

echo -e "${GREEN}✓${NC} API key configured"
echo ""

# Step 3: Configure Shortcut
echo -e "${CYAN}[3/5]${NC} Keyboard Shortcut Configuration"
echo ""
echo "Current shortcut: ${BOLD}Option + Space${NC}"
echo ""
echo "Available shortcuts:"
echo "  1) Option + Space (default)"
echo "  2) Control + Space"
echo "  3) Command + Shift + Space"
echo ""
read -p "Choose shortcut (1-3) [1]: " SHORTCUT_CHOICE

case "$SHORTCUT_CHOICE" in
    2)
        MODIFIERS=4096   # controlKey
        SHORTCUT_DESC="Control + Space"
        ;;
    3)
        MODIFIERS=1310984  # cmdKey + shiftKey
        SHORTCUT_DESC="Command + Shift + Space"
        ;;
    *)
        MODIFIERS=2048   # optionKey
        SHORTCUT_DESC="Option + Space"
        ;;
esac

echo -e "${GREEN}✓${NC} Shortcut set to: ${BOLD}$SHORTCUT_DESC${NC}"
echo ""

# Save configuration
cat > "$CONFIG_PATH" << EOF
{
    "apiKey": "$API_KEY",
    "shortcutModifiers": $MODIFIERS,
    "shortcutKeyCode": 49
}
EOF
chmod 600 "$CONFIG_PATH"

# Step 4: Build the app
echo -e "${CYAN}[4/5]${NC} Building application..."
echo ""

cd "$PROJECT_DIR"

# Build in release mode
swift build -c release 2>&1 | while read line; do
    if [[ "$line" == *"error"* ]]; then
        echo -e "${RED}$line${NC}"
    elif [[ "$line" == *"warning"* ]]; then
        echo -e "${YELLOW}$line${NC}"
    else
        echo "$line"
    fi
done

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Build successful"
echo ""

# Step 5: Create app bundle
echo -e "${CYAN}[5/5]${NC} Creating application bundle..."

# Remove old app if exists
rm -rf "$APP_PATH"

# Create app structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy executable
cp ".build/release/WhisperVoice" "$APP_PATH/Contents/MacOS/WhisperVoice"

# Copy Info.plist
cp "Info.plist" "$APP_PATH/Contents/"

# Copy icon if exists
if [ -f "$ICONS_DIR/AppIcon.icns" ]; then
    cp "$ICONS_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/"
fi

# Sign the app
codesign --force --deep --sign - "$APP_PATH"

echo -e "${GREEN}✓${NC} App installed at: ~/Applications/$APP_NAME.app"
echo ""

# Setup auto-start option
echo -e "${YELLOW}Do you want Whisper Voice to start automatically at login?${NC}"
read -p "(y/N): " AUTO_START

if [[ "$AUTO_START" =~ ^[Yy]$ ]]; then
    PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"

    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.whisper-voice</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    echo -e "${GREEN}✓${NC} Auto-start enabled"
fi

echo ""
echo -e "${GREEN}${BOLD}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                                                           ║"
echo "║              ✅ Installation Complete!                    ║"
echo "║                                                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo "To launch the app:"
echo -e "  ${CYAN}open -a \"Whisper Voice\"${NC}"
echo ""
echo "Shortcut:"
echo -e "  ${BOLD}$SHORTCUT_DESC${NC} - Start/Stop recording"
echo ""
echo -e "${YELLOW}Important:${NC} On first launch, macOS will ask for permissions:"
echo "  • Microphone access"
echo "  • Accessibility access (for paste)"
echo ""
echo "Add ${BOLD}Whisper Voice${NC} to:"
echo "  System Preferences → Privacy & Security → Accessibility"
echo "  System Preferences → Privacy & Security → Input Monitoring"
echo ""

# Ask to launch now
read -p "Launch Whisper Voice now? (Y/n): " LAUNCH_NOW
if [[ ! "$LAUNCH_NOW" =~ ^[Nn]$ ]]; then
    open -a "$APP_NAME"
    echo -e "${GREEN}✓${NC} App launched! Look for the microphone icon in the menu bar."
fi

echo ""
