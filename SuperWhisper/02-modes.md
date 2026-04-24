# SuperWhisper - Système de Modes

## Concept
Les modes adaptent le traitement vocal pour optimiser la dictée selon le contexte d'utilisation.

## Modes disponibles

### Voice to Text (Transcription pure)
- Dictation optimisée en vitesse avec formatage de base
- Pas de traitement IA, transcription uniquement
- Idéal pour : entrées rapides, transcriptions longues

### Super Mode
- Mode avancé avec sensibilité au contexte
- Capture 3 types de contexte :
  1. **Contexte applicatif** : identifie l'app active, lit les champs d'entrée
  2. **Texte sélectionné** : utilise le texte en surbrillance
  3. **Presse-papiers** : texte copié dans les 3 dernières secondes
- Corrige l'orthographe, convertit URLs/emails, préserve le ton

### Message Mode
- Supprime les artefacts vocaux et mots de remplissage
- Correction grammaire et ponctuation
- Formatage pour meilleure lisibilité
- Préserve le flux conversationnel naturel

### Email Mode
- Ajoute automatiquement salutations et formules de politesse
- Préserve le ton naturel
- Met en évidence les éléments d'action
- Correction orthographique et grammaticale

### Note Mode
- Transforme les idées parlées en notes structurées
- Organisation en listes et points à puces
- Met en évidence les points essentiels
- Idéal pour : cours, réunions, brainstorming

### Meeting Mode
- Enregistre l'audio des réunions
- Génère des résumés avec éléments d'action
- Option de séparation des locuteurs (via paramètres avancés)
- Capture les décisions clés

### Custom Mode (Mode personnalisé)
- Contrôle total sur les instructions IA
- Configuration de la sensibilité au contexte
- Instructions personnalisables avec balises XML
- Possibilité d'ajouter des exemples

## Changement de modes
4 méthodes :
1. **Raccourci clavier** : pendant ou avant la dictée
2. **Barre de menu** : clic sur l'icône SuperWhisper
3. **Règles automatiques** : basculement selon l'app active
4. **Deep Links** : `superwhisper://mode?key=YOUR_MODE_KEY`
