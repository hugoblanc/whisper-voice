#!/bin/bash

set -e

echo "=================================="
echo "  Whisper Voice - Installation"
echo "=================================="
echo ""

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Répertoire du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Vérifier Python
echo "Vérification de Python..."
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Erreur: Python 3 n'est pas installé${NC}"
    echo "Installez Python depuis https://www.python.org/downloads/"
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo -e "${GREEN}✓ Python $PYTHON_VERSION trouvé${NC}"

# Installer les dépendances
echo ""
echo "Installation des dépendances..."
pip3 install -r requirements.txt
echo -e "${GREEN}✓ Dépendances installées${NC}"

# Configurer la clé API
echo ""
if [ ! -f .env ]; then
    echo -e "${YELLOW}Configuration de la clé API OpenAI${NC}"
    echo "Obtenez votre clé sur: https://platform.openai.com/api-keys"
    echo ""
    read -p "Entrez votre clé API OpenAI: " API_KEY

    if [ -z "$API_KEY" ]; then
        echo -e "${RED}Erreur: Clé API requise${NC}"
        exit 1
    fi

    echo "OPENAI_API_KEY=$API_KEY" > .env
    echo -e "${GREEN}✓ Clé API configurée${NC}"
else
    echo -e "${GREEN}✓ Fichier .env existant${NC}"
fi

# Créer le fichier Info.plist pour rumps (notifications)
echo ""
echo "Configuration des notifications..."
PYTHON_BIN_DIR=$(python3 -c "import sys; print(sys.prefix)")/bin
if [ ! -f "$PYTHON_BIN_DIR/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c 'Create' "$PYTHON_BIN_DIR/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string "whisper-voice"' "$PYTHON_BIN_DIR/Info.plist" 2>/dev/null || true
fi
echo -e "${GREEN}✓ Notifications configurées${NC}"

# Démarrage automatique
echo ""
echo -e "${YELLOW}Voulez-vous que Whisper Voice démarre automatiquement au login ?${NC}"
read -p "(o/n): " AUTO_START

if [ "$AUTO_START" = "o" ] || [ "$AUTO_START" = "O" ] || [ "$AUTO_START" = "oui" ]; then
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

    echo -e "${GREEN}✓ Démarrage automatique configuré${NC}"
    echo "  Logs: ~/.whisper-voice.log"
fi

echo ""
echo "=================================="
echo -e "${GREEN}  Installation terminée !${NC}"
echo "=================================="
echo ""
echo "Pour lancer manuellement:"
echo "  python3 main.py"
echo ""
echo "Raccourci: Option+Espace"
echo ""
echo -e "${YELLOW}Important:${NC} Au premier lancement, autorisez Terminal dans:"
echo "  Préférences Système → Confidentialité et sécurité → Accessibilité"
echo "  Préférences Système → Confidentialité et sécurité → Surveillance de l'entrée"
echo ""
