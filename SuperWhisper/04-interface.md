# SuperWhisper - Interface

## Barre de Menu

### Indicateur de statut (point coloré)
- **Jaune** : Chargement du modèle en cours
- **Rouge** : Enregistrement actif
- **Bleu** : Traitement de la dictation
- **Vert** : Traitement terminé

### Options du menu
1. **Contrôles d'enregistrement** : démarrer/arrêter
2. **Gestion de fichiers** : transcrire fichiers, accéder historique
3. **Paramètres** : réglages, périphérique d'entrée, mode actif, mises à jour

### Modes d'interaction
- **Clic standard** : ouvre le menu complet
- **Quick Recording** : clic gauche = toggle enregistrement, clic droit = menu

## Fenêtre d'Enregistrement
- Peut être désactivée pour réduire les distractions
- Option mini fenêtre minimaliste
- Fermeture automatique après dictation (optionnel)

## Panneau d'Historique

### Accès
- Via fenêtre des paramètres
- Via barre de menu
- Via menu contextuel de la mini-fenêtre

### Fonctionnalités
- **Recherche** : filtre la dictation originale (pas les résultats IA)
- **Retraitement** : clic droit → "Process Again"
- **Suppression** : via barre latérale ou Finder
- **Vue Segments** : séparation des locuteurs, renommage des intervenants
- **Détails** : métadonnées, prompts IA utilisés

## Vocabulaire Personnalisé

### Vocabulary Words
- Aide l'IA à reconnaître des termes spécialisés
- Noms de société, acronymes, terminologie technique
- **Attention** : trop de mots peut dégrader la qualité

### Replacements (Remplacements)
- Appliqués APRÈS transcription (pas d'IA)
- Insensible à la casse
- Résultats garantis et cohérents
- Idéal pour corriger erreurs persistantes
