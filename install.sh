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

APP_NAME="Whisper Voice"
APP_PATH="$HOME/Applications/$APP_NAME.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"
VERSION="1.1.0"

# Check Python
echo "Checking Python..."
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: Python 3 is not installed${NC}"
    echo "Install Python from https://www.python.org/downloads/"
    exit 1
fi

PYTHON_PATH=$(which python3)
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "${GREEN}✓ Python $PYTHON_VERSION found ($PYTHON_PATH)${NC}"

# Install dependencies
echo ""
echo "Installing dependencies..."
pip3 install -r requirements.txt --quiet
echo -e "${GREEN}✓ Dependencies installed${NC}"

# Generate icons if needed
echo ""
echo "Checking icons..."
if [ ! -f "$SCRIPT_DIR/icons/AppIcon.icns" ]; then
    echo "Generating icons..."
    pip3 install Pillow --quiet
    python3 "$SCRIPT_DIR/generate_icons.py"
    echo -e "${GREEN}✓ Icons generated${NC}"
else
    echo -e "${GREEN}✓ Icons found${NC}"
fi

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

# Create .app bundle
echo ""
echo "Creating application bundle..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy app icon
if [ -f "$SCRIPT_DIR/icons/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/icons/AppIcon.icns" "$APP_PATH/Contents/Resources/"
fi

# Create executable
cat > "$APP_PATH/Contents/MacOS/whisper-voice" << EOF
#!/bin/bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
cd "$SCRIPT_DIR"
exec $PYTHON_PATH -u main.py 2>&1 | tee -a ~/.whisper-voice.log
EOF

chmod +x "$APP_PATH/Contents/MacOS/whisper-voice"

# Create Info.plist with app icon
cat > "$APP_PATH/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>whisper-voice</string>
    <key>CFBundleIdentifier</key>
    <string>com.whisper-voice</string>
    <key>CFBundleName</key>
    <string>Whisper Voice</string>
    <key>CFBundleDisplayName</key>
    <string>Whisper Voice</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Whisper Voice needs microphone access to record audio for transcription.</string>
</dict>
</plist>
EOF

echo -e "${GREEN}✓ Application created at ~/Applications/$APP_NAME.app${NC}"

# Auto-start
echo ""
echo -e "${YELLOW}Do you want Whisper Voice to start automatically at login?${NC}"
read -p "(y/n): " AUTO_START

if [ "$AUTO_START" = "y" ] || [ "$AUTO_START" = "Y" ] || [ "$AUTO_START" = "yes" ]; then
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
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"

    echo -e "${GREEN}✓ Auto-start configured${NC}"
fi

echo ""
echo "=================================="
echo -e "${GREEN}  Installation complete!${NC}"
echo "=================================="
echo ""
echo "To launch:"
echo "  open -a \"$APP_NAME\""
echo ""
echo "Shortcut: Option+Space"
echo ""
echo -e "${YELLOW}Important:${NC} Add \"$APP_NAME\" to:"
echo "  System Preferences → Privacy & Security → Accessibility"
echo "  System Preferences → Privacy & Security → Input Monitoring"
echo "  System Preferences → Privacy & Security → Automation → System Events"
echo ""
echo "Logs: ~/.whisper-voice.log"
echo ""
