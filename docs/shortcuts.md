# Raccourcis & Push-to-Talk

## Deux modes d'enregistrement

| Mode | Comportement | Raccourci par défaut |
|---|---|---|
| **Toggle** | Un appui pour démarrer, un autre pour arrêter | **Option + Espace** |
| **Push-to-Talk (PTT)** | Maintenir enfoncé pendant qu'on parle, relâcher pour arrêter | **F3** |

Les deux modes cohabitent — tu peux utiliser l'un ou l'autre indifféremment.

## Configurer

`Préférences → Shortcuts`. Cliquer dans le champ pour **enregistrer** un raccourci : tape la combinaison voulue (ex : `⌃⌥Space`). Escape pour annuler, Delete pour vider.

- Toggle : **requiert un modifier** (Cmd/Option/Ctrl/Shift). Une touche nue est refusée.
- PTT : **peut être une touche nue** (F3, F4…), ou avec modifier.

## Autres raccourcis pendant l'enregistrement

| Touche | Action |
|---|---|
| **Shift** | Cycler entre les modes |
| **Escape** | Annuler (pas de transcription, pas de paste) |
| **Enter** | Valider (équivalent à presser Stop) |

## Pourquoi le raccourci ne se déclenche pas ?

1. `System Settings → Privacy & Security → Input Monitoring` — **Whisper Voice** doit être coché
2. `System Settings → Privacy & Security → Accessibility` — même chose (requis pour le paste via Cmd+V simulé)
3. Si tu rebuilds l'app, les permissions doivent être re-accordées — le CDHash change à chaque build

Logs : `Préférences → Logs` affiche `Starting recording (showStopMessage: ...)` au déclenchement. Si rien n'apparaît, c'est un problème d'autorisation, pas de code.

## Changer de raccourci sans redémarrer

Sauvegarder dans Préférences applique immédiatement — pas besoin de relancer l'app. Si le nouveau raccourci ne répond pas, check le log `Shortcut registered: …`.
