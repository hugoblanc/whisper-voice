# Whisper Voice

Application macOS de transcription vocale utilisant l'API OpenAI Whisper.

**Option+Espace** pour enregistrer votre voix, et le texte transcrit est automatiquement collé à l'emplacement du curseur.

## Fonctionnalités

- Raccourci clavier global (Option+Espace)
- Icône dans la barre de menu (🎤 → 🔴 → ⏳)
- Notifications macOS
- Collage automatique du texte transcrit

## Prérequis

- macOS
- Python 3.10+
- Une clé API OpenAI ([obtenir une clé](https://platform.openai.com/api-keys))

## Installation

```bash
# Cloner le repo
git clone https://github.com/VOTRE_USERNAME/whisper-voice.git
cd whisper-voice

# Lancer l'installation
./install.sh
```

Le script d'installation va :
1. Installer les dépendances Python
2. Vous demander votre clé API OpenAI
3. Configurer le démarrage automatique (optionnel)

## Utilisation

### Lancement manuel

```bash
python main.py
```

### Raccourci

| Action | Raccourci |
|--------|-----------|
| Démarrer/Arrêter l'enregistrement | **Option+Espace** |

### Indicateurs visuels (barre de menu)

| Icône | État |
|-------|------|
| 🎤 | En attente |
| 🔴 | Enregistrement en cours |
| ⏳ | Transcription en cours |

## Permissions macOS

Au premier lancement, macOS demandera d'autoriser :

1. **Microphone** : pour enregistrer votre voix
2. **Accessibilité** : Préférences Système → Confidentialité et sécurité → Accessibilité → Ajouter Terminal
3. **Surveillance de l'entrée** : Préférences Système → Confidentialité et sécurité → Surveillance de l'entrée → Ajouter Terminal

## Désinstallation

```bash
./uninstall.sh
```

## Configuration

Le fichier `.env` contient votre clé API :

```
OPENAI_API_KEY=sk-votre-clé-ici
```

## Dépannage

### Le raccourci ne fonctionne pas

Vérifiez que Terminal est bien ajouté dans :
- Préférences Système → Confidentialité et sécurité → Accessibilité
- Préférences Système → Confidentialité et sécurité → Surveillance de l'entrée

### Erreur "This process is not trusted"

Ajoutez Terminal dans les préférences d'Accessibilité, puis relancez l'application.

## Licence

MIT
