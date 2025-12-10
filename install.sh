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
echo "========================================"
echo "    Whisper Voice - Installation        "
echo "         Swift Edition v2.1.0           "
echo "========================================"
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
echo -e "${GREEN}OK${NC} $SWIFT_VERSION"
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

echo -e "${GREEN}OK${NC} API key configured"
echo ""

# Step 3: Configure Recording Mode
echo -e "${CYAN}[3/5]${NC} Recording Mode Configuration"
echo ""
echo "Choose how you want to control recording:"
echo ""
echo "  1) Toggle mode (default)"
echo "     Press shortcut to start, press again to stop"
echo ""
echo "  2) Push-to-Talk mode"
echo "     Hold key to record, release to transcribe"
echo ""
read -p "Choose mode (1-2) [1]: " MODE_CHOICE

if [[ "$MODE_CHOICE" == "2" ]]; then
    RECORDING_MODE="pushToTalk"

    echo ""
    echo "Choose Push-to-Talk key:"
    echo "  1) F1       5) F5       9) F9"
    echo "  2) F2       6) F6      10) F10"
    echo "  3) F3       7) F7      11) F11"
    echo "  4) F4       8) F8      12) F12"
    echo ""
    read -p "Choose key (1-12) [3]: " PTT_CHOICE

    case "$PTT_CHOICE" in
        1)  PTT_KEYCODE=122; PTT_DESC="F1" ;;
        2)  PTT_KEYCODE=120; PTT_DESC="F2" ;;
        4)  PTT_KEYCODE=118; PTT_DESC="F4" ;;
        5)  PTT_KEYCODE=96;  PTT_DESC="F5" ;;
        6)  PTT_KEYCODE=97;  PTT_DESC="F6" ;;
        7)  PTT_KEYCODE=98;  PTT_DESC="F7" ;;
        8)  PTT_KEYCODE=100; PTT_DESC="F8" ;;
        9)  PTT_KEYCODE=101; PTT_DESC="F9" ;;
        10) PTT_KEYCODE=109; PTT_DESC="F10" ;;
        11) PTT_KEYCODE=103; PTT_DESC="F11" ;;
        12) PTT_KEYCODE=111; PTT_DESC="F12" ;;
        *)  PTT_KEYCODE=99;  PTT_DESC="F3" ;;
    esac

    SHORTCUT_DESC="$PTT_DESC (hold)"
    # Set default toggle shortcut values (not used in PTT mode but needed for config)
    MODIFIERS=2048
    KEYCODE=49

    echo -e "${GREEN}OK${NC} Push-to-Talk mode with ${BOLD}$PTT_DESC${NC}"
else
    RECORDING_MODE="toggle"
    PTT_KEYCODE=99  # F3 default

    echo ""
    echo "Choose keyboard shortcut:"
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
    KEYCODE=49  # Space

    echo -e "${GREEN}OK${NC} Toggle mode with ${BOLD}$SHORTCUT_DESC${NC}"
fi

echo ""

# Save configuration
cat > "$CONFIG_PATH" << EOF
{
    "apiKey": "$API_KEY",
    "shortcutModifiers": $MODIFIERS,
    "shortcutKeyCode": $KEYCODE,
    "recordingMode": "$RECORDING_MODE",
    "pushToTalkKeyCode": $PTT_KEYCODE
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

echo -e "${GREEN}OK${NC} Build successful"
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

echo -e "${GREEN}OK${NC} App installed at: ~/Applications/$APP_NAME.app"
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
    echo -e "${GREEN}OK${NC} Auto-start enabled"
fi

echo ""
echo -e "${GREEN}${BOLD}"
echo "========================================"
echo "      Installation Complete!            "
echo "========================================"
echo -e "${NC}"
echo ""
echo "To launch the app:"
echo -e "  ${CYAN}open -a \"Whisper Voice\"${NC}"
echo ""
if [[ "$RECORDING_MODE" == "pushToTalk" ]]; then
    echo "Mode: ${BOLD}Push-to-Talk${NC}"
    echo -e "  Hold ${BOLD}$PTT_DESC${NC} to record, release to transcribe"
else
    echo "Mode: ${BOLD}Toggle${NC}"
    echo -e "  ${BOLD}$SHORTCUT_DESC${NC} to start/stop recording"
fi
echo ""
echo -e "${YELLOW}Important:${NC} On first launch, macOS will ask for permissions:"
echo "  - Microphone access"
echo "  - Accessibility access (for paste)"
echo ""
echo "Add ${BOLD}Whisper Voice${NC} to:"
echo "  System Preferences > Privacy & Security > Accessibility"
echo "  System Preferences > Privacy & Security > Input Monitoring"
echo ""

# Ask to launch now
read -p "Launch Whisper Voice now? (Y/n): " LAUNCH_NOW
if [[ ! "$LAUNCH_NOW" =~ ^[Nn]$ ]]; then
    open -a "$APP_NAME"
    echo -e "${GREEN}OK${NC} App launched! Look for the microphone icon in the menu bar."
fi

echo ""
