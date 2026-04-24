# SuperWhisper - Fonctionnalités Avancées

## Transcription de Fichiers

### Formats supportés
- MP3 audio
- MP4 vidéo
- WAV mono 16 kHz

### Méthodes
1. **Barre de menu** → Transcribe File
2. **Finder** : clic droit → Open With → Superwhisper
3. **Ligne de commande** : `open /path/to/file.mp3 -a superwhisper`

## Transcription Temps Réel
- Voir les mots apparaître pendant que vous parlez
- **Requis** : modèles Nova (Cloud) uniquement
- Activation dans paramètres avancés du mode

## Séparation des Locuteurs

### Configuration
1. Activer "Identify Speakers" dans le mode
2. Activer "Record from System Audio" (réunions live)
3. Utiliser modèles Nova pour meilleure précision

### Utilisation
1. Ouvrir historique → onglet Segments
2. Renommer les locuteurs
3. "Copy to Clipboard" pour transcription complète

### Analyse IA
- Exporter vers ChatGPT/Claude
- Ou créer mode personnalisé avec contexte applicatif
- Exemples : résumé par locuteur, éléments d'action assignés

## Sensibilité au Contexte

### 3 types de contexte
1. **Texte sélectionné** : capturé au démarrage
2. **Contexte applicatif** : capturé après traitement vocal
3. **Presse-papiers** : copié dans les 3 sec avant ou pendant

### Disponibilité
- Modes intégrés : désactivé par défaut
- Super Mode : tous les 3 activés par défaut
- Custom Mode : configurable

## Règles d'Activation Automatique
- Basculer automatiquement selon l'app active
- Configurable par mode
- Note : une fois activé pour une app, non remplaçable

## Deep Links
- `superwhisper://settings` : ouvrir paramètres
- `superwhisper://mode?key=YOUR_MODE_KEY` : changer de mode
- `superwhisper://record` : démarrer enregistrement
- Clé du mode : ~/Documents/superwhisper/modes/[mode].json

## Intégrations
- Raycast
- Alfred
- Autres via deep links
