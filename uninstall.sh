#!/bin/bash

echo "=================================="
echo "  Whisper Voice - Désinstallation"
echo "=================================="
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PLIST_PATH="$HOME/Library/LaunchAgents/com.whisper-voice.plist"

# Arrêter le service
if [ -f "$PLIST_PATH" ]; then
    echo "Arrêt du service..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm "$PLIST_PATH"
    echo -e "${GREEN}✓ Service arrêté et supprimé${NC}"
else
    echo "Aucun service de démarrage automatique trouvé"
fi

# Supprimer les logs
if [ -f "$HOME/.whisper-voice.log" ]; then
    rm "$HOME/.whisper-voice.log"
    echo -e "${GREEN}✓ Logs supprimés${NC}"
fi

echo ""
echo -e "${YELLOW}Note:${NC} Les fichiers du projet n'ont pas été supprimés."
echo "Pour supprimer complètement, supprimez le dossier manuellement."
echo ""
echo -e "${GREEN}Désinstallation terminée !${NC}"
