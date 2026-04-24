# SuperWhisper - Dépannage & Performance

## Hallucinations

### Causes transcription
- Périodes de silence qui confondent le modèle
- Trop de mots dans le vocabulaire personnalisé

### Solution
- Activer "Remove Silence" dans paramètres Sound
- Garder vocabulaire minimal

### Causes traitement IA
- Prompts imprécis sans exemples
- Directives conflictuelles
- Modèle local moins performant que cloud
- Confusion liée au contexte applicatif/presse-papiers

### Bonnes pratiques
- Instructions claires avec 2-3 exemples
- Modèles cloud (Claude, GPT) pour meilleurs résultats
- Activer contexte sélectivement

## Performance

### Facteurs clés
1. Puissance CPU, RAM, mémoire disponible
2. Connexion internet (pour modèles cloud)
3. Choix du modèle
4. Type de traitement (transcription vs IA)

### Modèles locaux
- Ajuster durée active (10 sec → 1 heure)
- S'assurer d'avoir assez de RAM
- Fonctionnent hors ligne

### Modèles cloud
- Nécessitent connexion stable
- Généralement plus rapides

### Optimisation
1. Désactiver traitement IA si non nécessaire
2. Choisir modèle selon besoin :
   - Ultra Cloud : dictées courtes
   - Parakeet : usage hors ligne
   - Nova : enregistrements longs
3. Utiliser historique pour identifier goulots d'étranglement

## Contexte - Problèmes courants

### Texte sélectionné non capturé
- Vérifier le focus de la fenêtre
- Sélectionner AVANT de démarrer

### Contexte applicatif incorrect
- Ne pas changer de fenêtre pendant dictation

### Presse-papiers non pris en compte
- Copier dans les 3 secondes avant dictation
- Ou pendant la dictation
