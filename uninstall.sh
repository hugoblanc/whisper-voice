#!/bin/bash

echo "=================================="
echo "  Whisper Voice - Uninstallation"
echo "=================================="
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"

# Stop the service
if [ -f "$PLIST_PATH" ]; then
    echo "Stopping service..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo -e "${GREEN}✓ Service stopped and removed${NC}"
else
    echo "No auto-start service found"
fi

# Delete logs
if [ -f "$HOME/.whisper-voice.log" ]; then
    rm "$HOME/.whisper-voice.log"
    echo -e "${GREEN}✓ Logs deleted${NC}"
fi

echo ""
echo -e "${YELLOW}Note:${NC} Project files have not been deleted."
echo "To remove completely, delete the folder manually."
echo ""
echo -e "${GREEN}Uninstallation complete!${NC}"
