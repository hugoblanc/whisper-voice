# Auto-select mode by app

**Quand je dicte dans Slack, utilise le mode Slack. Quand je dicte dans Mail, utilise Formel.** Point barre.

## Configurer

`Préférences → Auto-mode`

1. **+ Add app** → choisis une .app dans `/Applications` → Whisper Voice lit le bundle identifier automatiquement
2. Choisis le mode à appliquer dans cette app
3. `Enable auto-select` est coché par défaut

Tu peux désactiver globalement le toggle sans perdre ton mapping.

## Comment ça marche sous le capot

Au démarrage d'un enregistrement :

1. `ContextCapturer` lit l'app frontmost (via `NSWorkspace`)
2. Si `bundleID` correspond à une entrée de ton mapping → `ModeManager.setMode(…)`
3. Le panneau d'enregistrement affiche `auto: <Mode> (<App>)` en muted
4. Shift pour cycler manuellement → le label auto disparaît (override pris en compte)

Si aucun match, c'est le mode courant (= dernier utilisé) qui reste actif.

## Logs

`Préférences → Logs` :

```
[AutoMode] bundleID=com.tinyspeck.slackmacgap → Slack (locked as recording mode)
```

Si tu ne vois pas cette ligne au bon moment, c'est que le mapping n'est pas matché (mauvais bundleID) ou que le toggle est off.

## Cas non gérés (V1)

- Différentes URLs dans le navigateur (Gmail vs GitHub) partagent le même bundleID → même mode appliqué. Pas de granularité par site.
- Slack workspace A vs B : même mode pour les deux.
- Workspace multi-projet dans VSCode : le mode est global à l'app, pas par fenêtre.

Ces cas pourraient être ajoutés en V2 (matching par `windowTitle` / `browserURL`). Pas prévu tant que le besoin n'est pas clair — voir [roadmap des design docs](https://github.com/hugoblanc/whisper-voice/tree/main/design).

## Limite / piège

Si le mode cible est désactivé (dans `Préférences → Modes`) ou nécessite une clé API absente → l'auto-switch **est skippé silencieusement** et le mode courant reste. Pas d'alerte modal. Vérifie les logs si tu ne comprends pas pourquoi un mode ne s'applique pas.
