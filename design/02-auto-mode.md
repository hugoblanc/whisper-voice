# Design — Auto-select mode by app (MVP)

> **Status**: design v2 — scope drastiquement réduit après review.
> Previous v1 (rule engine + renderer + learning) archivé dans l'historique git.
> 2026-04-23.

## Context

`ModeManager.shared.currentMode` est la seule source de vérité pour le `ProcessingMode` appliqué après transcription. Aujourd'hui le mode persiste entre enregistrements ; l'utilisateur cycle avec Shift pendant l'enregistrement.

`AppDelegate.startRecording` capture déjà un `DictationContext` (via `ContextCapturer`) avant le démarrage audio, qui contient `app.bundleID`. C'est tout ce dont on a besoin pour un MVP honnête.

## North star

**"Quand je dicte dans Slack, utilise Clean. Quand je dicte dans Mail, utilise Formel."** L'utilisateur configure un mapping `bundleID → modeId` dans les Préférences. Point barre.

## Non-goals (V1)

Les features suivantes étaient dans v1 du design, retirées pour tenir le scope MVP :

- ❌ Rule engine avec types `bundle|urlHost|urlPath|windowTitle|cmd`
- ❌ Renderer pipeline (`TextRenderer` protocol, slack-md, discord-md…)
- ❌ Built-in defaults (Slack→Clean, Mail→Formel, etc.)
- ❌ Apprentissage depuis les overrides
- ❌ URL host / path matching (Gmail web, Linear, GitHub PR…)
- ❌ Terminal / `foregroundCmd` matching
- ❌ `workspaceHint` multi-projet dans la même app
- ❌ Post-hoc "Fix last mode" dans le menubar

L'utilisateur configure ce qu'il veut, aucune magie. Si les données le justifient, on ajoutera des tiers plus tard (même philosophie que `01-project-tagging.md` : partir minimal, enrichir quand le besoin émerge).

## Data model

Un seul ajout à `Config` :

```swift
// Dans Config (WhisperVoice/Sources/WhisperVoice/main.swift ~L1625)
var appModeOverrides: [String: String] = [:]   // bundleID -> modeId
var autoSelectModeEnabled: Bool = true
```

Migration : absent = `[:]` + `true` par défaut, rétro-compatible (Codable optional decode).

Pas de nouveau fichier, pas de nouveau struct, pas de singleton supplémentaire.

## Logique de sélection

Dans `AppDelegate.startRecording`, juste après que `pendingDictationContext` soit set :

```swift
if Config.shared.autoSelectModeEnabled,
   let bundleID = pendingDictationContext?.app?.bundleID,
   let modeId = Config.shared.appModeOverrides[bundleID],
   ModeManager.shared.isModeAvailable(id: modeId) {
    ModeManager.shared.setMode(id: modeId)
    pendingAutoModeReason = "auto: \(mode.name) (\(appDisplayName))"
} else {
    pendingAutoModeReason = nil   // mode courant inchangé = lastUsed implicite
}
```

Si `isModeAvailable` est false (mode désactivé, pas de clé API pour le provider) → on n'applique pas, on tombe sur le mode courant. Pas d'erreur remontée.

Si l'utilisateur Shift-cycle pendant l'enregistrement → `pendingAutoModeReason = nil` (override pris en compte, on n'affiche plus la raison auto).

## UX

**1. Label sur le panneau d'enregistrement**

Ajouter une ligne sous `ModeSelectorView` (similaire à `ProjectChipView`) :

```
┌─── Recording ──────────────── 0:07 ┐
│   ~~~~WAVEFORM~~~~~~~~~~~~~~~~~~   │
│  ● Recording                        │
│  [Brut][Clean*][Formel][Markdown]   │  <- ModeSelectorView
│  auto: Clean (Slack)                │  <- NEW (muted)
│  in: ● superproper  ⇥ change  94%   │  <- ProjectChipView existant
│  [Cancel]                   [Stop]  │
└─────────────────────────────────────┘
```

Quand l'utilisateur Shift-cycle : le label disparaît (ou passe en `manual: overridden`, à décider pendant l'impl).

Pas de "why?" popover, pas de confidence — la logique est déterministe, affichable en une ligne.

**2. Préférences › Modes tab, nouvelle section**

```
Modes                                             [+ Custom]
────────────────────────────────────────────────────────────
Built-in modes  [table existante]
Custom modes    [table existante]
────────────────────────────────────────────────────────────
Auto-select mode by app                           [+ Add app]

  App                          Mode
  ● Slack                      [Clean      ▾]   [✕]
  ● Mail                       [Formel     ▾]   [✕]
  ● VSCode                     [Brut       ▾]   [✕]
  ─────────────────────────────────────────
  [x] Enable auto-select

No match → current mode (last-used).
```

**Ajouter une app** : NSOpenPanel pointé sur `/Applications`, user pick une `.app`, on lit son `CFBundleIdentifier` depuis l'`Info.plist` de l'app. Alternative bonus si trivial : liste déroulante des bundleIDs déjà vus dans l'historique (`HistoryManager.allEntries.compactMap { $0.app?.bundleID }.unique`).

**Mode dropdown** : lit `ModeManager.shared.allAvailableModes` (built-in + custom, filtre les disabled).

## Fichiers modifiés

| Fichier | Zone | Action |
|---|---|---|
| `main.swift` | `Config` (~L1625) | Ajouter `appModeOverrides: [String: String]` + `autoSelectModeEnabled: Bool` |
| `main.swift` | `AppDelegate.startRecording` (~L5327 après capture du contexte) | Lookup + `setMode` + stash `pendingAutoModeReason` |
| `main.swift` | `AppDelegate.setupModeSwitchMonitor` (~existant) | Clear `pendingAutoModeReason` au Shift override |
| `main.swift` | `RecordingWindow` / `ModeSelectorView` (~L2083/L3667) | Afficher label `auto: X (Y)` quand `pendingAutoModeReason != nil` |
| `main.swift` | `PreferencesWindow.setupModesTab` | Section "Auto-select mode by app" — NSTableView avec colonnes App/Mode/Delete + `+ Add app` (NSOpenPanel) + toggle Enable |
| `CLAUDE.md` | Key Classes / Configuration | Mentionner la feature |

**Aucun nouveau struct, aucun nouveau singleton, aucun nouveau fichier.** Ça reste < ~200 lignes de code à tout casser.

## Vérification

1. Build : `swift build -c release` clean.
2. Ajouter Slack + Mode Clean dans Prefs → dicter dans Slack → vérifier que le panneau montre `auto: Clean (Slack)` et que le texte finit processé par Clean.
3. Dicter dans une app non configurée → pas de label auto, le mode précédent est utilisé.
4. Shift-cycle pendant l'enregistrement → label auto disparaît, le mode choisi est appliqué.
5. Désactiver le toggle `Enable auto-select` → même en étant dans Slack, le mode courant reste celui utilisé au dernier enregistrement.
6. Configurer un mode puis le désactiver depuis l'onglet Modes → la prochaine dictée dans cette app tombe silencieusement sur le mode courant (pas de crash, pas d'alerte).
7. Supprimer une ligne de la table → mapping disparaît de `Config.appModeOverrides`, persisté.

## Déférés à V2+ (si les données le justifient)

Par ordre de priorité si on voit que ça coince :

1. **Built-in seeds** : proposer Slack/Mail/Outlook/Messages pré-remplis à la première ouverture de l'onglet (avec bouton "Import defaults").
2. **URL host matching** (Gmail web, Linear…) — seulement si les users se plaignent que `com.google.Chrome` n'est pas assez granulaire.
3. **Workspace hint** (VSCode whisper-voice vs linkedin-content avec modes différents) — seulement si quelqu'un a besoin de modes différents dans la même IDE.
4. **Renderer pipeline** (slack-md etc.) — feature orthogonale, séparée.
5. **Apprentissage implicite** depuis les overrides Shift-cycle — seulement après qu'on ait accumulé assez de données pour que ce soit utile.
6. **Post-hoc "Always use X here"** dans le menubar.

## Critical files for implementation

- `WhisperVoice/Sources/WhisperVoice/main.swift`:
  - `Config` struct (~L1625) — ajouter les 2 champs
  - `AppDelegate.startRecording` (~L5327) — branchement auto-select
  - `AppDelegate.pendingAutoModeReason: String?` — property
  - `AppDelegate.setupModeSwitchMonitor` — clear reason on override
  - `RecordingWindow` (~L2677) — label auto (pattern `ProjectChipView` en plus simple)
  - `PreferencesWindow.setupModesTab` (~L558 et suivants) — section table + controls
  - `ModeManager.allAvailableModes` / `isModeAvailable(id:)` — réutilisés tels quels
- `CLAUDE.md` — update sections *Key Classes* + *Configuration*
