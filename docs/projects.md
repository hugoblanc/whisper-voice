# Projets

Ajouter un **contexte de projet** à chaque dictée pour filtrer l'historique par activité (ex : `superproper`, `whisper-voice`, `perso`). Orthogonal aux modes.

## Configurer

`Préférences → Projects` → **+ New project**. Pas de validation du nom (libre).

## Assignation automatique (prédiction)

À chaque enregistrement, Whisper Voice regarde le contexte capturé (`gitRemote`, `browserURL`, `windowTitle`, `bundleID`) et requête ton historique : *"quel projet est le plus souvent associé à ce signal ?"*. Tier de certitude décroissant :

1. **gitRemote** exact match → confiance haute
2. **browserHost** (domaine principal) → confiance moyenne
3. **workspace hint** (nom extrait du titre de fenêtre IDE/terminal) → confiance moyenne
4. **bundleID seul** + seuils stricts (≥5 matches, 80% accord) → confiance basse
5. **lastUsedProjectID** → fallback

Le mini-chip `in: ● <projet>` dans le panneau d'enregistrement reflète la prédiction ; click pour changer ou créer à la volée.

## Rétro-tagging (tagger l'historique)

Fenêtre `History` → clic droit sur une entrée → **Tag as…**. Whisper Voice propose ensuite de **propager le tag sur toutes les entrées similaires non taggées** (même gitRemote, même host, même workspace hint). Un clic peut en tagger des dizaines d'un coup.

## Archive / supprimer

`Préférences → Projects` :
- **Rename** : renomme sans perdre les entrées (UUID stable)
- **Archive** : le projet n'apparaît plus dans les prédictions, mais reste visible dans le filtre History
- **Untag all entries** : détag toutes les entrées du projet, garde le projet
- **Delete** : le projet disparaît, les entrées gardent leur tag orphelin (récupérable manuellement)

## Données stockées

`~/Library/Application Support/WhisperVoice/projects.json` — list de `{id, name, color, createdAt, archived}`.

Le lien entrée ↔ projet vit dans `history.json` via `entry.extras["projectID"]` (UUID). Aucun changement au struct `TranscriptionEntry`.
