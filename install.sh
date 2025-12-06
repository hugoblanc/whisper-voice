#!/bin/bash

set -e

echo "=================================="
echo "  Whisper Voice - Installation"
echo "=================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check Python
echo "Checking Python..."
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is not installed${NC}"
    echo "Install Python from https://www.python.org/downloads/"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "${GREEN}✓ Python $PYTHON_VERSION found${NC}"

# Install dependencies
echo ""
echo "Installing dependencies..."
pip3 install -r requirements.txt
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Configure API key
echo ""
if [ ! -f .env ]; then
    echo -e "${YELLOW}OpenAI API key configuration${NC}"
    echo "Get your key at: https://platform.openai.com/api-keys"
    echo ""
    read -p "Enter your OpenAI API key: " API_KEY

    if [ -z "$API_KEY" ]; then
        echo -e "${RED}Error: API key required${NC}"
        exit 1
    fi

    echo "OPENAI_API_KEY=$API_KEY" > .env
    echo -e "${GREEN}✓ API key configured${NC}"
else
    echo -e "${GREEN}✓ Existing .env file found${NC}"
fi

# Create Info.plist file for rumps (notifications)
echo ""
echo "Configuring notifications..."
PYTHON_BIN_DIR=$(python3 -c "import sys; print(sys.prefix)")/bin
if [ ! -f "$PYTHON_BIN_DIR/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c 'Create' "$PYTHON_BIN_DIR/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string "whisper-voice"' "$PYTHON_BIN_DIR/Info.plist" 2>/dev/null || true
fi
echo -e "${GREEN}✓ Notifications configured${NC}"

# Auto-start
echo ""
echo -e "${YELLOW}Do you want Whisper Voice to start automatically at login?${NC}"
read -p "(y/n): " AUTO_START

if [ "$AUTO_START" = "y" ] || [ "$AUTO_START" = "Y" ] || [ "$AUTO_START" = "yes" ]; then
    PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"
    PYTHON_PATH=$(which python3)

    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.whisper-voice</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_PATH</string>
        <string>$SCRIPT_DIR/main.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
    <key>StandardOutPath</key>
    <string>$HOME/.whisper-voice.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.whisper-voice.log</string>
</dict>
</plist>
EOF

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"

    echo -e "${GREEN}✓ Auto-start configured${NC}"
    echo "  Logs: ~/.whisper-voice.log"
fi

echo ""
echo "=================================="
echo -e "${GREEN}  Installation complete!${NC}"
echo "=================================="
echo ""
echo "To launch manually:"
echo "  python3 main.py"
echo ""
echo "Shortcut: Option+Space"
echo ""
echo -e "${YELLOW}Important:${NC} On first launch, authorize Terminal in:"
echo "  System Preferences → Privacy & Security → Accessibility"
echo "  System Preferences → Privacy & Security → Input Monitoring"
echo ""
