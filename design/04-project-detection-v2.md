# Design — Project detection v2 (keyword-based)

> **Status**: design draft, 2026-04-23.
> Supersedes the "auto-learning from overrides" idea rejected in review
> (too heavy, too few signals to learn from).

## Context

Today `ProjectPredictor.predict(ctx:)` uses 5 tiers — gitRemote → browserHost → workspaceHint → bundleID (with strict thresholds) → lastUsedProjectID. Two failure modes observed in practice:

1. **Two VSCode instances open** on different workspaces → `frontmostApplication` returns the same bundleID for both; `focusedWindowTitle(pid:)` via AXUIElement should return the right window title, but `workspaceHint` extraction can fail if the window title format doesn't match `… — folder` (e.g. unsaved file, full path, no separator). → Detection falls back to bundleID tier → wrong project.
2. **Terminal in an untracked directory** or multi-pane tmux → no gitRemote, cwd might be `~/` → no usable signal → lastUsedProjectID fallback regardless of actual work context.

## North star

**The user is the expert on what makes a project recognizable.** Let them declare 2-5 distinctive keywords per project (repo slug, product name, core domain). The predictor matches these keywords against **all available signals** (windowTitle, cwd, browserURL, gitRemote, foregroundCmd) AND against **the transcribed text itself**.

Concrete example: project `superproper` with keywords `["superproper", "moteur immo"]`. If any of those appear in the window title OR the dictation says "J'ai cassé le scoring sur superproper", the tag is near-certain.

## Data model

Extend the existing `Project` struct:

```swift
struct Project: Codable {
    let id: UUID
    var name: String
    var color: String?
    var createdAt: Date
    var archived: Bool = false
    var keywords: [String] = []   // NEW — user-declared distinctive words
}
```

Backward-compat: missing key decodes as `[]` via Codable optional semantics.

## New predictor pipeline

Insert two keyword tiers into the existing chain:

```
predict(ctx) -> (project, confidence, reason):
    // Tier 1 — gitRemote exact (existing, 0.95)
    // Tier 2 — keyword match against signals (NEW, 0.90)
    for each non-archived project:
        for each keyword in project.keywords:
            if any of [windowTitle, browserURL, browserTabTitle, cwd, foregroundCmd, gitRemote] contains keyword (case-insensitive):
                return (project, 0.90, "keyword:\(keyword) in \(signal)")
    // Tier 3 — browserHost (existing, 0.80)
    // Tier 4 — workspaceHint (existing, 0.70)
    // Tier 5 — bundleID+threshold (existing, 0.55)
    // Tier 6 — lastUsedProjectID (existing, 0.30)
    // Tier 7 — none

Post-transcription re-prediction:
    onTranscriptionComplete(text, currentPrediction):
        if currentPrediction.confidence >= 0.90: return currentPrediction
        for each non-archived project:
            for each keyword in project.keywords:
                if text.lowercased().contains(keyword.lowercased()):
                    return (project, 0.92, "keyword:\(keyword) in transcribed text")
        return currentPrediction
```

Post-transcription re-prediction is a second pass that can **upgrade** a weak tag but never downgrade a strong one. Runs before `finishWithText` writes the entry.

## UX

### Preferences → Projects

Each row in the projects table gets a clickable column "Keywords: 2" → opens a small popover with a multi-line text field (one keyword per line). Saved verbatim (no normalization, case-insensitive match).

### Recording panel

No UI change. The project chip already displays the inferred project and confidence. If the re-prediction upgrades the tag after transcription, the chip updates before paste — small animation would be nice but not required.

### History → Details popover

The reason line already exists (`projectReason`). Now it can say `keyword:superproper in text` or `keyword:moteur immo in windowTitle` — so the user can see exactly why the tag stuck.

## Fallback behavior

- A keyword like "api" would match too broadly → document that keywords should be **distinctive**, 2+ characters, ideally unique to the project.
- Two projects share a keyword → first match wins (deterministic by `projects.json` order). Low-confidence case; user can rename keywords.
- No keywords declared → pipeline behaves exactly as today. Zero regression.

## VSCode multi-window fix (separate sub-task)

The keyword approach masks the workspaceHint bug but doesn't fix it. Investigate:

1. Log `windowTitle` in every captured context to see the actual format per IDE.
2. VSCode title format can be overridden by user's `window.title` setting — we may need to handle multiple separators or fall back to the full title as slug.
3. If `focusedWindowTitle(pid:)` returns the wrong window when multiple VSCode windows are stacked, the bug is upstream (AXUIElement weirdness with Electron apps). Try `kAXWindowsAttribute` + find the main window differently.

Track as its own issue — the keyword tier is a user-facing mitigation in the meantime.

## V1 scope

- `Project.keywords: [String]` field + Codable migration
- Predictor tier 2 (pre-transcription keyword match against signals)
- Post-transcription re-prediction pass
- Prefs UI: per-project keyword editor (popover with multi-line text)
- `docs/projects.md` update with keyword section
- `CLAUDE.md` — add keyword tier to predictor docs

## Deferred

- VSCode windowTitle diagnostics (separate ticket).
- Fuzzy matching (Levenshtein) — too many false positives for short strings.
- Auto-suggest keywords from history entries already tagged to a project.
- "Exclude keywords" to veto a project when a term appears (niche).

## Critical files

- `WhisperVoice/Sources/WhisperVoice/main.swift`:
  - `Project` struct (~L3200)
  - `ProjectStore` load/save (handle new field)
  - `ProjectPredictor.predict` (~L3578) — insert tier 2
  - `ProjectPredictor.rePredictAfterTranscription(text:current:)` (NEW)
  - `AppDelegate.finishWithText` (~L7075) — call re-prediction before writing entry
  - `PreferencesWindow.setupProjectsTab` (~L1160) — add keyword column + editor popover
- `docs/projects.md`
- `CLAUDE.md`
