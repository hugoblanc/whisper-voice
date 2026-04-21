# Design — Project tagging with learning pre-selection

> **Status**: design v2 — open questions answered, V1 scope simplified.
> Agent: Plan, 2026-04-21. Revised after user review.

## Context

Every dictation already carries rich context (`app`, `DictationSignals.gitRemote / browserURL / windowTitle / cwd`, `extras`). Users produce dictations across distinct projects (superproper, whisper-voice, linkedin-content, perso…) but entries pool into an undifferentiated history. Tagging unlocks per-project filtering, per-project custom vocabulary / prompts later, and cleaner export consumers. The learning loop is cheap because the raw fingerprint material is captured on every recording.

## North star

**After the first paste, a small `in: SUPERPROPER` chip sits below the `ModeSelectorView`; user hits Enter to accept, Tab to cycle, ⌘P to pick/create. 90% of recordings cost zero extra clicks.**

## Decisions (post-review)

| Question | Answer |
|---|---|
| Default when no signal matches | **Last-used project**. User can explicitly pick "Untagged" or "Create new…". |
| Rules contradict each other / user overrides | **Do not build a rule-mapping store for V1.** Prediction is derived from the history itself: query recent entries with matching signals, return the most common project. Implicit learning. |
| Project name casing | **No normalization.** Whatever the user types is stored and displayed verbatim. |
| Multi-signal conflicts (git + browser) | Non-issue in practice — one active app = one dominant signal. Use the highest tier available. |
| Archived projects | **Skipped from predictions entirely.** Still visible in History filter for browsing old entries. |

## Recommended flow

**Primary: during-recording passive confirm, History retro-tag secondary.** The chip appears in `RecordingWindow` the instant the panel shows (pre-selection derived from the captured `DictationContext`). No modal. If no prediction is possible, chip shows `in: (untagged)` as muted text; user can ignore or tab-pick.

After paste, nothing blocks. If the user wants to correct or tag retroactively, they open History, right-click an untagged entry, pick a project — and the app offers to **propagate the tag to all other untagged entries with matching signals** (same gitRemote, or same browserHost, or same bundleID depending on what's available). One click can retro-tag dozens of entries. This is the main "learning" mechanism; the engine is literally "count what's already tagged".

Rejected: blocking post-recording popovers (breaks the "dictate and forget" thesis); a separate rule-mapping store (too much machinery for questionable gain given the messiness user acknowledged).

## Data model

Add a `projects.json` in `~/Library/Application Support/WhisperVoice/`. **No rule store**, no `ProjectMapping` struct — the history itself is the source of truth for what signal maps to what project.

```swift
// NEW file: projects.json
struct Project: Codable {
    let id: UUID                 // stable across renames
    var name: String             // "superproper" / "SuperProper" / whatever the user typed
    var color: String?           // hex, optional
    var createdAt: Date
    var archived: Bool = false   // if true: never surfaced in predictions, still browsable
}

// projects.json shape:
// { "projects": [...], "version": 1 }

// TranscriptionEntry — NO struct change. Write into existing extras bag:
// extras["projectID"]   = "<uuid>"        // absent = untagged
// extras["projectName"] = "superproper"   // denormalized for greppability/export
// extras["projectSource"] = "predicted" | "confirmed" | "manual" | "retro"
```

Config additions:
- `lastUsedProjectID: String?`
- `projectTaggingEnabled: Bool` (default `true`)

A new `ProjectStore` singleton owns `projects.json`, mirroring `HistoryManager`'s queue pattern.

## Prediction logic (no rule store — query the history)

```
predict(ctx: DictationContext) -> (Project?, confidence, reason):
    // Only consider entries tagged with non-archived projects.
    // Window the history to the last ~90 days for relevance; weight by recency.

    // Tier 1 — deterministic (confidence 0.95)
    if ctx.signals.gitRemote:
        matches = entries where signals.gitRemote == ctx.gitRemote AND projectID != nil
        if matches: return (most-common-project(matches), 0.95, "gitRemote")

    // Tier 2 — strong probabilistic (0.70-0.85)
    if ctx.signals.browserURL:
        host = host(ctx.browserURL)
        matches = entries where host(signals.browserURL) == host AND projectID != nil
        if count(matches) >= 2: return (most-common-project(matches), 0.80, "browserHost:\(host)")

    // Tier 3 — weak probabilistic (0.50-0.65)
    if ctx.app.bundleID:
        matches = entries where app.bundleID == ctx.bundleID AND projectID != nil
        if count(matches) >= 3 AND agreement-ratio(matches) >= 0.6:
            return (most-common-project(matches), 0.55, "bundleID:\(bundleID)")

    // Fallback
    if let last = Config.lastUsedProjectID where not archived:
        return (Project(id=last), 0.30, "last-used")

    return (nil, 0.0, "no-signal")
```

Retro-tag propagation:
```
onUserTagRetroactively(entry, project):
    entry.extras["projectID"] = project.id
    entry.extras["projectSource"] = "retro"

    // Offer to apply the same tag to other untagged entries with matching signals.
    similar = entries where projectID == nil AND
        (signals.gitRemote == entry.signals.gitRemote OR
         host(signals.browserURL) == host(entry.signals.browserURL) OR
         app.bundleID == entry.app.bundleID)
    if count(similar) > 0:
        showPrompt("Tag \(count) similar entries with \(project.name)?") {
            for e in similar: e.extras["projectID"] = project.id
        }
```

Zero ML, zero separate rule store. Just `most-common-project()` over history slices.

## Wireframes

**1. In-panel selector (during recording):**

```
┌─── Recording ──────────────── 0:07 ┐
│   ~~~~WAVEFORM~~~~~~~~~~~~~~~~~~   │
│  ● Recording                        │
│  [Dictée▸] [Smart] [Email] [Reply]  │  <- ModeSelectorView
│  in: ● superproper  ⇥ change  94%   │  <- NEW: ProjectChipView
│  [Cancel]                   [Stop]  │
└─────────────────────────────────────┘
```

States:
- **Predicted**: `in: ● superproper   ⇥ change   94%`
- **Last-used fallback**: `in: ○ superproper   ⇥ change   (last)`
- **No signal**: `in: (untagged)   ⇥ pick`

**2. Project picker (⌘P or Tab-and-hold):**

```
┌─── Pick project ────────────────┐
│ 🔍 Type to filter…              │
│ ────────────────────────────────│
│ ● superproper           (94%)   │  <- highlighted prediction
│ ● whisper-voice                 │
│ ● linkedin-content              │
│ ● perso                         │
│ ────────────────────────────────│
│ + Create new…                   │
│ × Untag this dictation          │
└─────────────────────────────────┘
```

Free-form name input — no validation except non-empty.

**3. History › retro-tag flow:**

```
Right-click untagged entry:
┌─────────────────────────┐
│ Tag as → ● superproper  │
│          ● whisper-voice│
│          + Create new…  │
│ ─────────────────────── │
│ Delete                  │
└─────────────────────────┘

After picking a project:
┌──────────────────────────────────────────┐
│ Tag 14 similar untagged entries too?     │
│ (same gitRemote: github.com/.../...)     │
│                    [ Only this ] [ Yes ] │
└──────────────────────────────────────────┘
```

**4. Preferences › Projects tab:**

```
Projects                                 [+ New]
────────────────────────────────────────────────
● superproper          42 tags   [Rename][Archive]
● whisper-voice        19 tags   [Rename][Archive]
● linkedin-content      7 tags   [Rename][Archive]
● perso                 3 tags   [Rename][Archive]
────────────────────────────────────────────────
Archived:
  old-consulting-gig   11 tags   [Rename][Unarchive][Delete]
```

No "learned rules" panel in V1 — there are no rules, the history is the ground truth.

## V1 scope

- `Project` struct + `ProjectStore` singleton (file + queue pattern like `HistoryManager`).
- `ProjectChipView` inside `RecordingWindow` (below `ModeSelectorView`). Shows prediction; Tab opens picker; ⌘P opens picker; typing into picker creates new inline.
- Prediction logic (3 tiers, history-derived, no rule store).
- Write `projectID`, `projectName`, `projectSource` into `entry.extras`.
- Config: `lastUsedProjectID`, `projectTaggingEnabled`.
- History viewer: project filter dropdown + right-click *"Tag as…"* + retro-tag-similar prompt.
- Preferences › Projects tab: create/rename/archive/unarchive; archived projects not predicted.
- Auto-seed a project the first time `+ Create new…` is used with a name matching a gitRemote slug (saves one manual step).

## Deferred to V2+

- Per-project custom vocabulary / prompt prefix injection.
- `bundleIDPlusWindow` trigram matching (Slack channel from window title etc).
- Project merge operation.
- Retroactive bulk tagging without a starting entry (script / Prefs button).
- Cross-device sync of projects.json.
- Color customisation beyond the creation dialog.
- Per-project analytics (words dictated, most common apps, etc).

## Critical files for implementation

- `WhisperVoice/Sources/WhisperVoice/main.swift`:
  - `TranscriptionEntry` (~L2216), `HistoryManager` (~L2261) — **do not change the struct**; read/write via `entry.extras`.
  - `RecordingWindow` (~L2677), `ModeSelectorView` (~L2083) — insert `ProjectChipView` below mode selector.
  - `Config` (~L1586) — add `lastUsedProjectID`, `projectTaggingEnabled`.
  - `AppDelegate.startRecording` (~L5327) — after `pendingDictationContext` is set, call `ProjectPredictor.predict(ctx)`.
  - `AppDelegate.finishWithText` (~L5467) — write the resolved project into `entry.extras` before passing to `HistoryManager.addEntry`.
  - `ContextCapturer` (~L2335) — no change.
  - `HistoryWindow` (~L2307) — add filter dropdown + right-click menu + retro-tag dialog.
- New class block next to `ModeManager`: `ProjectStore` + `ProjectPredictor`.
- `CLAUDE.md` — update *Key Classes* and *Configuration* sections.
- `~/Library/Application Support/WhisperVoice/projects.json` — new persistent store.
