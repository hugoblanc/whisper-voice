# Design — Post-transcription actions (hooks)

> **Status**: design draft, 2026-04-29.

## Context

Aujourd'hui, après transcription + processing (mode), Whisper Voice fait toujours la même chose : coller le texte au curseur via `CGEvent` Cmd+V. Ça couvre 90% des cas, mais il y a deux manques concrets :

1. **Paste + Enter** : l'utilisateur dicte une réponse Slack, attend que ça colle, puis appuie sur Entrée manuellement. Ça casse le flow "dictate and forget".
2. **Lancer un agent** : l'utilisateur copie du contexte (message Slack, extrait de code…), dicte une instruction ("investigue ce truc"), et veut que ça lance automatiquement un agent (Claude Code, script custom…) avec la transcription comme input.

Le point commun : ce qui se passe après la transcription devrait être configurable.

## North star

**L'utilisateur choisit une "action" qui s'exécute après transcription. Par défaut c'est "Coller" (comportement actuel). Il peut configurer "Coller + Entrée" ou une commande shell custom avec des variables.**

## Non-goals (V1)

- ❌ Actions per-app (combiner avec 02-auto-mode) — V2, quand les deux features sont stables
- ❌ Webhook / HTTP natif — un `curl` dans la commande shell suffit si quelqu'un en veut
- ❌ Chaîner plusieurs actions séquentiellement
- ❌ UI de résultat (afficher la sortie de la commande shell)
- ❌ Marketplace / partage d'actions entre utilisateurs
- ❌ AppleScript natif — `osascript -e '...'` dans une commande shell suffit

## Actions

Trois types, du plus simple au plus puissant :

| Type | Comportement | Use case |
|------|-------------|----------|
| `paste` | Coller au curseur (Cmd+V). **Défaut, comportement actuel.** | Dictée classique |
| `pasteEnter` | Coller au curseur + simuler Entrée (↩). | Slack, search bars, chat apps — envoyer directement |
| `command` | Exécuter une commande shell avec variables d'environnement. Pas de paste. | Lancer un agent, automatiser un workflow |

### Variables d'environnement (type `command`)

La commande shell est exécutée avec ces variables :

| Variable | Contenu |
|----------|---------|
| `$WV_TRANSCRIPTION` | Le texte transcrit (après processing du mode) |
| `$WV_RAW_TRANSCRIPTION` | Le texte brut avant processing |
| `$WV_APP_BUNDLE_ID` | Bundle ID de l'app source (ex: `com.tinyspeck.slackmacgap`) |
| `$WV_APP_NAME` | Nom de l'app source (ex: `Slack`) |
| `$WV_MODE` | Mode utilisé (ex: `clean`, `formal`) |
| `$WV_PROJECT` | Nom du projet taggé, si applicable |

Le clipboard n'est pas exposé en variable — il est déjà accessible via `pbpaste` dans la commande si besoin. Pas de duplication.

### Exemples concrets

**Lancer Claude Code avec la transcription :**
```bash
open -a "Terminal" && claude -p "$WV_TRANSCRIPTION"
```

**Lancer Claude Code avec contexte du clipboard :**
```bash
claude -p "Contexte (copié depuis $WV_APP_NAME): $(pbpaste)\n\nInstruction: $WV_TRANSCRIPTION"
```

**Poster dans un channel Slack via webhook :**
```bash
curl -s -X POST "$SLACK_WEBHOOK_URL" -d "{\"text\": \"$WV_TRANSCRIPTION\"}"
```

**Ajouter à un fichier de notes :**
```bash
echo "$(date): $WV_TRANSCRIPTION" >> ~/Desktop/voice-notes.txt
```

## Data model

Ajout à `Config` :

```swift
// Nouvelle struct
struct PostAction: Codable, Identifiable {
    var id: String              // UUID string, auto-generated
    var label: String           // "Coller", "Coller + Entrée", "Launch Agent"…
    var type: String            // "paste" | "pasteEnter" | "command"
    var command: String?        // seulement pour type "command"
    var isDefault: Bool         // une seule action marquée default à la fois
}

// Dans Config
var postActions: [PostAction] = [
    PostAction(id: "builtin-paste", label: "Paste", type: "paste", command: nil, isDefault: true),
    PostAction(id: "builtin-paste-enter", label: "Paste + Enter", type: "pasteEnter", command: nil, isDefault: false)
]
var activePostActionId: String = "builtin-paste"   // pointe vers l'action active
```

Les deux built-in (`paste`, `pasteEnter`) sont toujours présents et non-supprimables. L'utilisateur peut ajouter autant d'actions `command` qu'il veut.

Migration : `postActions` absent = on injecte les deux built-in + `activePostActionId = "builtin-paste"`. Rétro-compatible.

## Logique d'exécution

Dans `AppDelegate`, après transcription + processing, remplacer le paste direct par :

```swift
func executePostAction(text: String, rawText: String, context: DictationContext?) {
    let action = Config.shared.activePostAction  // lookup by activePostActionId
    
    switch action.type {
    case "paste":
        pasteText(text)
        
    case "pasteEnter":
        pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.simulateEnterKey()
        }
        
    case "command":
        guard let command = action.command, !command.isEmpty else { return }
        executeShellCommand(command, env: [
            "WV_TRANSCRIPTION": text,
            "WV_RAW_TRANSCRIPTION": rawText,
            "WV_APP_BUNDLE_ID": context?.app?.bundleID ?? "",
            "WV_APP_NAME": context?.app?.name ?? "",
            "WV_MODE": ModeManager.shared.currentMode.id,
            "WV_PROJECT": context?.projectName ?? ""
        ])
        
    default:
        pasteText(text)  // fallback safe
    }
}

func simulateEnterKey() {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)  // 0x24 = Return
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
    keyDown?.post(tap: .cgi)
    keyUp?.post(tap: .cgi)
}

func executeShellCommand(_ command: String, env: [String: String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                LogManager.shared.log("Post-action command exited with status \(process.terminationStatus)")
            }
        } catch {
            LogManager.shared.log("Post-action command failed: \(error.localizedDescription)")
        }
    }
}
```

Le `asyncAfter(0.15)` pour pasteEnter laisse le temps au paste de se compléter avant d'envoyer Enter. Même pattern que le délai existant pour le paste.

## UX

### Sélection rapide : dans le menu bar

Ajouter un sous-menu "Action" dans le menu status bar, à côté du mode :

```
┌──────────────────────────┐
│ ● Whisper Voice          │
│ ─────────────────────────│
│ Mode: Clean            ▸ │
│ Action: Paste          ▸ │  ← NEW
│ Project: superproper   ▸ │
│ ─────────────────────────│
│ Preferences…             │
│ Quit                     │
└──────────────────────────┘
```

Sous-menu "Action" :

```
┌─────────────────────┐
│ ✓ Paste             │
│   Paste + Enter     │
│ ──────────────────  │
│   Launch Agent      │  ← custom actions
│   Voice Notes       │
│ ──────────────────  │
│   Manage…           │  → ouvre Prefs
└─────────────────────┘
```

### Configuration : Préférences › nouvel onglet "Actions"

```
Actions                                           
──────────────────────────────────────────────────────
After transcription, execute:

  Name                  Type              Command
  ● Paste               Built-in          —                    
  ● Paste + Enter       Built-in          —                    
  ● Launch Agent        Command           claude -p "$WV_TR…   [Edit] [✕]
  ● Voice Notes         Command           echo "$(date): $W…   [Edit] [✕]
  ─────────────────────────────────────────────────────
  [+ Add action]

  Active action: [Paste          ▾]

Variables available in commands:
  $WV_TRANSCRIPTION  — processed text
  $WV_RAW_TRANSCRIPTION — raw text before mode processing
  $WV_APP_BUNDLE_ID — source app bundle ID  
  $WV_APP_NAME — source app name
  $WV_MODE — current mode
  $WV_PROJECT — tagged project name
  Tip: use $(pbpaste) to include clipboard content
```

**"+ Add action"** ouvre un mini formulaire inline :
- Champ "Name" (texte libre)
- Champ "Command" (text area, monospace, 3-4 lignes)
- Bouton "Test" qui exécute la commande avec des valeurs fictives et affiche exit code + stderr

**"Edit"** : même formulaire, pré-rempli.

**"✕"** : supprime l'action custom (confirmation si c'est l'action active).

Les built-in ne sont ni éditables ni supprimables.

## Raccourci clavier pour cycler

Comme Shift cycle les modes pendant l'enregistrement, on pourrait utiliser une autre touche pour cycler les actions. Mais c'est du polish — **déféré à V2**. En V1, on change l'action depuis le menu bar ou les Prefs.

## Fichiers modifiés

| Fichier | Zone | Action |
|---|---|---|
| `main.swift` | `Config` (~L1625) | Ajouter `PostAction` struct + `postActions` + `activePostActionId` |
| `main.swift` | `AppDelegate` (après transcription, ~zone paste) | Remplacer le paste direct par `executePostAction(…)` |
| `main.swift` | `AppDelegate` | Ajouter `simulateEnterKey()` + `executeShellCommand(…)` |
| `main.swift` | `AppDelegate.setupStatusBarMenu` | Ajouter sous-menu "Action" |
| `main.swift` | `PreferencesWindow` | Nouvel onglet "Actions" avec table + formulaire |
| `CLAUDE.md` | Key Classes / Configuration | Mentionner la feature |

**Pas de nouveau fichier Swift.** Ajout estimé ~250–300 lignes.

## Sécurité

- Les commandes shell s'exécutent avec les droits de l'utilisateur (pas d'escalade).
- Les variables sont passées via `Process.environment`, pas via interpolation dans le shell → **pas d'injection possible** via le contenu de la transcription.
- Le champ `command` est saisi par l'utilisateur lui-même dans les Prefs — même modèle de confiance que les commandes tapées dans Terminal.

## Vérification

1. Build : `swift build -c release` clean.
2. Action par défaut "Paste" → comportement identique à avant (régression zéro).
3. "Paste + Enter" → dicter dans Slack → le message est collé ET envoyé.
4. Action custom `echo "$WV_TRANSCRIPTION" >> /tmp/test.txt` → vérifier que le fichier contient la transcription.
5. Commande avec `pbpaste` → le contenu du clipboard est bien accessible.
6. Commande qui fail (exit code ≠ 0) → log dans Preferences › Logs, pas de crash.
7. Supprimer l'action active → l'app fallback sur "Paste".
8. Migration : ouvrir avec un ancien config sans `postActions` → les deux built-in apparaissent, action active = Paste.

## Déférés à V2+ (si les données le justifient)

1. **Actions per-app** : combiner avec 02-auto-mode — Slack → pasteEnter, VSCode → paste, Terminal → launch agent.
2. **Raccourci clavier** pour cycler les actions pendant l'enregistrement.
3. **Timeout configurable** pour les commandes shell (défaut : 30s).
4. **Feedback visuel** : notification macOS quand une commande custom se termine (succès/échec).
5. **Import/export d'actions** : partager des configurations entre machines ou utilisateurs.
6. **Action "Copy" (sans paste)** : juste mettre dans le clipboard sans coller — niche mais demandé parfois.

## Open questions

1. Le délai de 150ms entre paste et Enter dans `pasteEnter` est-il suffisant pour toutes les apps ? *(Reco: commencer à 150ms, rendre configurable si ça pose problème.)*
2. Faut-il un timeout par défaut sur les commandes shell ? *(Reco: oui, 30s, loguer si dépassé.)*
3. L'onglet "Actions" est-il séparé ou une section dans l'onglet "General" ? *(Reco: onglet séparé, c'est un concept first-class.)*
