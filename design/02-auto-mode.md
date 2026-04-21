# Design — Smart mode auto-detection

> **Status**: design draft. No implementation yet.
> Agent: Plan, 2026-04-21.

## Context

`ModeManager.shared.currentMode` is the single source of truth for which `ProcessingMode` gets applied post-transcription by `TextProcessor.process(...)`. Today that index persists across recordings; the user cycles with Shift while recording (`setupModeSwitchMonitor`). `AppDelegate.startRecording` already fires `ContextCapturer.shared.captureNow` before the audio session starts, stashing a `DictationContext` (app.bundleID, app.name, windowTitle, browserURL, browserTabTitle, cwd, foregroundCmd, gitRemote, gitBranch) into `pendingDictationContext`. That same context is the perfect auto-match input — we just consume it synchronously before `selectedModeForCurrentRecording` is locked in.

## Rule engine

A single ordered list of `AutoMatchRule` evaluated on each recording start; **first match wins**. Precedence (highest → lowest), all within one iteration:

1. **URL-path rule** — `browserURL` regex (e.g. `^https://github\.com/.+/(compare|pull)/`) → Brut
2. **URL-host rule** — host match (`mail.google.com` → Formel, `*.slack.com` → Clean + slack-render)
3. **Window-title rule** — regex against `windowTitle` (e.g. `"— Slack$"` when bundleID is generic Electron)
4. **Terminal signal rule** — `foregroundCmd` matches (`vim|nvim|git commit|ssh` → Brut)
5. **BundleID rule** — exact bundleID → mode (the bulk of defaults)
6. **Bundle-family rule** — prefix match (`com.tinyspeck.slackmacgap.*`)
7. **Fallback** — config flag: `lastUsedModeId` vs. a fixed `defaultAutoMode` (user choice in Prefs)

Rules are pure data: `struct AutoMatchRule { id, kind (.bundle|.urlHost|.urlPath|.windowTitle|.cmd|.default), pattern, modeId, rendererId?, source (.builtin|.user|.learned), priority }`. Engine lives in a new `ModeAutoMatcher` class sitting next to `ModeManager`.

## Built-in default mapping (V1)

| Signal | Kind | Mode | Renderer |
|---|---|---|---|
| `com.tinyspeck.slackmacgap` | bundle | Clean | slack-md |
| host `*.slack.com` | urlHost | Clean | slack-md |
| `com.hnc.Discord` | bundle | Casual | discord-md |
| `net.whatsapp.WhatsApp` | bundle | Casual | — |
| `com.apple.MobileSMS` | bundle | Casual | — |
| `com.facebook.archon` (Messenger) | bundle | Casual | — |
| `com.tdesktop.Telegram` | bundle | Casual | — |
| `com.apple.mail` | bundle | Formel | — |
| `com.microsoft.Outlook` | bundle | Formel | — |
| host `mail.google.com` | urlHost | Formel | — |
| host `outlook.live.com` | urlHost | Formel | — |
| `notion.id` / `md.obsidian` / `net.shinyfrog.bear` | bundle | Markdown | — |
| host `linear.app`, `github.com/*/issues/*` | urlPath | Markdown | gh-md |
| `com.apple.dt.Xcode` / `com.microsoft.VSCode` / `com.todesktop...` (Cursor) | bundle | Brut | — |
| any `knownTerminals` bundle | bundle | Brut | — |
| `com.apple.Terminal` + `foregroundCmd ~ ssh` | cmd | Brut | — |
| urlPath `github\.com/.+/(compare\|pull)` | urlPath | Brut | — |
| default | default | `lastUsedModeId` or Brut | — |

## Renderer as first-class citizen

Two-stage pipeline: **Mode = LLM pass (optional system prompt)**; **Renderer = pure-text transform applied after LLM, before paste**.

New protocol `TextRenderer { func render(_ text: String) -> String }` with registry `RendererRegistry.shared`. Built-in renderers: `slack-md`, `discord-md`, `gh-md`, `identity`.

`ProcessingMode` gets an optional `defaultRendererId: String?` (used when the mode is manually picked). `AutoMatchRule` can override with its own `rendererId`. `AppDelegate.finishWithText` composes: `paste(renderer.render(processed))`. Renderers are not modes themselves — keeps the mode list short and lets any mode + any renderer compose.

## UX flows

**1. Pre-selection visible on recording panel**

```
+---- Recording -----------------------+
|  o  00:03   [~~waveform~~~~]         |
|  [Brut][Clean][Formel][*Casual*][Md] |
|  auto: Casual -- because WhatsApp    |
|  Shift: next   Cmd+.: keep default   |
+--------------------------------------+
```
`ModeSelectorView` gets a second line showing `auto: <Mode> — because <reason>`. Existing Shift-to-cycle still works. When the user Shift-cycles, the `auto:` hint turns into `manual: overridden`.

**2. Preferences › Modes tab, new "Auto-match" subsection**

```
+-- Preferences / Modes ---------------+
| Built-in modes   [table]             |
| Custom modes     [table]             |
| ------------------------------------ |
| Auto-match rules                     |
|  When I'm in...           Use mode   |
|  [Slack (com.tinyspeck...)] [Clean v]|
|  [mail.google.com]        [Formel v] |
|  [*.notion.so]            [Markdown v]                    
|  [ + Add rule ]   [ Reset defaults ] |
|                                      |
| Fallback when nothing matches:       |
|  (*) Last-used mode  ( ) [Brut v]    |
|                                      |
| [ ] Learn from my overrides          |
+--------------------------------------+
```

**3. Post-hoc teach**

Status-bar submenu on the last dictation: *"Mode was wrong — always use **Markdown** here (notion.so)"*. Adds a learned rule with `source=.learned` at priority just above defaults.

## Fallbacks

- Rule references a disabled/deleted mode → skip rule, continue evaluating (treat as no-match).
- `frontApp` / bundleID is nil → use `lastUsedModeId` or configured default.
- SSH in Terminal: `foregroundCmd=ssh` → Brut (matches terminal rule; remote shell details unknowable).
- Rule evaluation throws (bad regex in user rule) → log via `LogManager`, disable that rule for the session, continue.
- No API key but matched mode needs LLM → downgrade to Brut silently (mirrors `isModeAvailable` logic).

## Data model

New fields on `Config` (persisted in `.whisper-voice-config.json`):
- `autoMatchEnabled: Bool` (default true)
- `autoMatchFallback: String` (`"last-used"` or a modeId)
- `autoMatchLearnFromOverrides: Bool`
- `autoMatchUserRules: [[String: String]]` (kind, pattern, modeId, rendererId, priority)
- `autoMatchLearnedRules: [[String: String]]` (same shape, separate bucket so user can clear learned without losing manual)

Built-in defaults live in code (`ModeAutoMatcher.builtInRules`), not in config — upgrades stay automatic. Per-mode `defaultRendererId` goes on `ProcessingMode` and, for custom modes, is a new key in the `customModes` dict.

## Integration points

- `ProcessingMode` struct → add `defaultRendererId: String?`.
- `Config` struct → add fields above + migration in `load()` / `save()`.
- **New**: `ModeAutoMatcher` class next to `ModeManager`: `matchingMode(for: DictationContext?) -> (mode, rendererId?, reason)?`.
- **New**: `TextRenderer` protocol + `RendererRegistry` near `TextProcessor`.
- `AppDelegate.startRecording` — after `pendingDictationContext` is set, call `ModeAutoMatcher.shared.matchingMode(for: ctx)`, then `ModeManager.shared.setMode(id:)` and stash `autoReason` + `pendingRendererId` on AppDelegate.
- `setupModeSwitchMonitor` — when user Shift-cycles, mark `autoReason = nil` (user took over).
- `AppDelegate.finishWithText` — after `TextProcessor.process` returns, apply renderer: `let out = RendererRegistry.shared.renderer(id: pendingRendererId).render(processed)` before paste.
- `ModeSelectorView` — new label row for `auto: X — because Y`.
- `PreferencesWindow.setupModesTab` — add "Auto-match rules" section with table + `+ Add rule` / `Reset defaults` / fallback picker / `learn` toggle; writes to `Config.autoMatchUserRules`.
- `ModeManager.reloadModes` — also call `ModeAutoMatcher.shared.reload()` and `RendererRegistry.shared.reload()`.
- Menubar status menu — "Fix last mode" submenu that writes a `.learned` rule keyed on whichever signal is most specific from the just-finished `DictationContext`.

## V1 scope

**Ship**:
- `AutoMatchRule` + `ModeAutoMatcher` with `bundle`, `urlHost`, `default` kinds only.
- ~15 built-in rules from the table above (bundle + urlHost only, no regex URL paths, no cmd).
- `ProcessingMode.defaultRendererId` + two renderers: `identity`, `slack-md`.
- Recording panel `auto: X — because Y` label and Shift-override marking it manual.
- Preferences toggle *"Enable auto mode"* + fallback picker (last-used vs fixed). **No user-editable rules UI yet.**
- `Config` migration + fallback to Brut when matched mode is disabled/unavailable.

**Defer to V2+**:
- `urlPath` regex rules and `cmd` / `windowTitle` rules.
- User-editable rules table in Prefs (power users can edit config JSON in the meantime).
- "Learn from my overrides" auto-derivation.
- Additional renderers (`discord-md`, `gh-md`).
- Post-hoc "always use X here" submenu action.
- Per-workspace Slack rules (`slack.com` workspace ID via cookie/URL parsing).

## Open questions

1. When the user Shift-cycles past auto-selected mode, should the override persist as a learned rule or only apply to this one recording? *(Reco V1 = one-shot; V2 = learn if toggle on.)*
2. Should renderers run even when the mode is manually picked? *(Reco: yes, use `mode.defaultRendererId`; auto-rule `rendererId` takes precedence only when auto matched.)*
3. For Slack in a browser tab vs. Slack desktop app: both → Clean+slack-md, or only desktop gets slack-md (since web Slack renders `**bold**` correctly)? *(Reco: both on slack-md; worth confirming.)*
4. Where should `DictationContext` flow for the "auto reason" string — is leaking `bundleID` / URL host into the recording panel UI acceptable privacy-wise? *(Reco: only show app.name or host, never full URL path.)*
5. Should `autoMatchEnabled = false` completely skip matching, or still show "suggested: X" without applying?
