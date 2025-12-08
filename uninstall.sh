#!/bin/bash

echo "=================================="
echo "  Whisper Voice - Uninstallation"
echo "=================================="
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

APP_NAME="Whisper Voice"
APP_PATH="$HOME/Applications/$APP_NAME.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"

# Kill running process
echo "Stopping application..."
pkill -f "whisper-voice" 2>/dev/null || true
pkill -f "main.py" 2>/dev/null || true
echo -e "${GREEN}✓ Application stopped${NC}"

# Stop and remove LaunchAgent
if [ -f "$PLIST_PATH" ]; then
    echo "Removing auto-start service..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo -e "${GREEN}✓ Service removed${NC}"
else
    echo "No auto-start service found"
fi

# Remove .app bundle
if [ -d "$APP_PATH" ]; then
    echo "Removing application bundle..."
    rm -rf "$APP_PATH"
    echo -e "${GREEN}✓ Application removed from ~/Applications/${NC}"
else
    echo "No application bundle found"
fi

# Delete logs
if [ -f "$HOME/.whisper-voice.log" ]; then
    rm "$HOME/.whisper-voice.log"
    echo -e "${GREEN}✓ Logs deleted${NC}"
fi

echo ""
echo -e "${YELLOW}Note:${NC} Project files have not been deleted."
echo "To remove completely, delete the project folder manually."
echo ""
echo -e "${YELLOW}Reminder:${NC} You may want to remove \"$APP_NAME\" from:"
echo "  System Preferences → Privacy & Security → Accessibility"
echo "  System Preferences → Privacy & Security → Input Monitoring"
echo "  System Preferences → Privacy & Security → Automation"
echo ""
echo -e "${GREEN}Uninstallation complete!${NC}"
