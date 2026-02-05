#!/bin/bash

echo "=================================="
echo "  Whisper Voice - Uninstallation"
echo "=================================="
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

APP_PATH="$HOME/Applications/Whisper Voice.app"
CONFIG_PATH="$HOME/.whisper-voice-config.json"
PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"

# Stop the app
pkill -f "WhisperVoice" 2>/dev/null || true
echo -e "${GREEN}✓${NC} App stopped"

# Remove LaunchAgent
if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo -e "${GREEN}✓${NC} Auto-start removed"
fi

# Remove app
if [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    echo -e "${GREEN}✓${NC} App removed"
fi

# Ask about config
if [ -f "$CONFIG_PATH" ]; then
    read -p "Remove configuration (including API key)? (y/N): " REMOVE_CONFIG
    if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
        rm "$CONFIG_PATH"
        echo -e "${GREEN}✓${NC} Configuration removed"
    else
        echo "Configuration kept at: $CONFIG_PATH"
    fi
fi

# Remove logs
LOGS_PATH="$HOME/Library/Application Support/WhisperVoice"
if [ -d "$LOGS_PATH" ]; then
    rm -rf "$LOGS_PATH"
    echo -e "${GREEN}✓${NC} Logs removed"
fi

echo ""
echo -e "${GREEN}Uninstallation complete!${NC}"
