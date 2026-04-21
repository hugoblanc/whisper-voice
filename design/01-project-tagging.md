# Design — Project tagging with learning pre-selection

> **Status**: design draft. No implementation yet.
> Agent: Plan, 2026-04-21.

## Context

Every dictation already carries rich context (`app`, `DictationSignals.gitRemote / browserURL / windowTitle / cwd`, `extras`). Users produce dictations across distinct projects (superproper, whisper-voice, linkedin-content, perso…) but entries pool into an undifferentiated history. Tagging unlocks per-project filtering, per-project custom vocabulary / prompts later, and cleaner export consumers. The learning loop is cheap because the raw fingerprint material is captured on every recording.

## North star

**After the first paste, a small `in: SUPERPROPER` chip sits below the `ModeSelectorView`; user hits Enter to accept, Tab to cycle, ⌘P to pick/create. 90% of recordings cost zero extra clicks.**

## Recommended flow

**Primary: during-recording passive confirm, post-paste correctable.** The chip appears in `RecordingWindow` the instant the panel shows (pre-selection derived from the captured `DictationContext` before/during recording). No modal. If prediction confidence < 0.6, chip shows `? pick project` in muted tone; user can ignore (entry tagged `null`) or tab-select. After paste, an ephemeral toast-style affordance (3 s fade) near the menu bar says `Tagged: superproper — ⌘⇧P to change`, letting the user correct without re-opening history. Post-hoc correction in the History viewer is a secondary path only.

Rejected: forcing a confirmation popover post-recording (breaks the "dictate and forget" flow that is the whole product thesis).

## Data model diff

Add a new `projects.json` in `~/Library/Application Support/WhisperVoice/` plus two fields via the existing `extras` bag to keep `history.json` schema-stable.

```swift
// NEW file: projects.json
struct Project: Codable {
    let id: UUID                    // stable across renames
    var name: String                // "superproper"
    var color: String?              // hex, optional
    var createdAt: Date
    var archived: Bool = false
}

struct ProjectMapping: Codable {    // learned rules
    let fingerprint: String         // canonicalized signal string
    let signalKind: SignalKind      // .gitRemote, .bundleID, .browserHost, .windowTitleNGram
    var projectID: UUID
    var hits: Int                   // user-confirmed count
    var lastUsed: Date
    var source: Source              // .explicit | .learned
}

enum SignalKind: String, Codable {
    case gitRemote, bundleID, bundleIDPlusWindow, browserHost, browserPath, slackChannel
}

// projects.json shape:
// { "projects": [...], "mappings": [...], "version": 1 }

// TranscriptionEntry — NO struct change; write into extras:
// extras["projectID"]         = "<uuid>"
// extras["projectName"]       = "superproper"   // denormalized for greppability
// extras["projectSource"]     = "predicted"|"confirmed"|"manual"|"none"
// extras["projectConfidence"] = "0.87"
```

Config additions: `var lastUsedProjectID: String` (fallback when no signal matches), `var projectTaggingEnabled: Bool` (default true).

A new `ProjectStore` singleton owns `projects.json`, mirroring `HistoryManager`'s queue pattern.

## Learning pseudocode

```
predict(ctx: DictationContext) -> (Project?, confidence, reason):
  candidates = []

  // Tier 1 — deterministic (confidence 0.95)
  if ctx.signals.gitRemote:
      if m = mappings.lookup(.gitRemote, normalize(gitRemote)):
          candidates += (m.project, 0.95, "gitRemote:\(m.fingerprint)")

  // Tier 2 — strong probabilistic (0.80)
  if ctx.signals.browserURL:
      host  = host(url); path1 = host + "/" + firstSegment(url)
      if m = mappings.lookup(.browserPath, path1): candidates += (m.project, 0.85, ...)
      elif m = mappings.lookup(.browserHost, host): candidates += (m.project, 0.70, ...)

  // Tier 3 — weak probabilistic (0.50-0.65)
  if ctx.app.bundleID and ctx.signals.windowTitle:
      key = bundleID + "::" + trigramHash(windowTitle)
      if m = mappings.lookup(.bundleIDPlusWindow, key): candidates += (m.project, 0.65, ...)
  if ctx.app.bundleID:
      if m = mappings.lookup(.bundleID, bundleID) and m.hits >= 3: candidates += (m.project, 0.50, ...)

  // Combine: max by confidence; if top two agree, +0.1 boost
  best = argmax(candidates, key=.confidence)
  if best.confidence < 0.60: return (nil, best.confidence, "low")
  return (best.project, best.confidence, best.reason)

record(entry, project, wasPredicted):
  // Always reinforce the deterministic signal first
  upsert(.gitRemote, normalize(ctx.gitRemote), project) if present
  upsert(.browserPath, ...)                             if present
  upsert(.bundleIDPlusWindow, ...)                      if present
  // bundleID-only only upserts after 3rd independent confirmation
  bump hits; lastUsed = now
```

Start purely rule-based. Only add ML (e.g. a tiny centroid/embedding over windowTitle+URL) if V2 metrics show >15% low-confidence rate.

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
Low confidence state: `in: ○ ? pick project   ⇥`

**2. Post-paste correction toast:**
```
┌──────────────────────────────┐
│ Tagged: superproper ● ⌘⇧P ✕  │
└──────────────────────────────┘
```
Menu-bar-anchored, 3 s fade. ⌘⇧P opens a Spotlight-style project picker with `Create new…` row.

**3. Preferences › Projects tab:**
```
Projects                                 [+ New]
────────────────────────────────────────────────
● superproper          42 tags   [Rename][Merge][Archive]
● whisper-voice        19 tags   [Rename][Merge][Archive]
● linkedin-content      7 tags   [Rename][Merge][Archive]
● perso                 3 tags   [Rename][Merge][Archive]
────────────────────────────────────────────────
Learned rules (auto-maintained, read-only):
  gitRemote:superproper/user-calls → superproper  (42 hits)
  host:linkedin.com                 → linkedin-content (7)
  bundleID:com.apple.MobileSMS      → perso (low conf, needs 2 more)
  [ Forget selected rule ]
```

## V1 scope

- `Project`, `ProjectMapping`, `ProjectStore` (file + queue).
- Pre-selection: `.gitRemote` + `.browserHost` + `.bundleID` tiers only.
- `ProjectChipView` inside `RecordingWindow` (below `ModeSelectorView`) with Tab cycle + `+` create-inline.
- Write `projectID`/`projectName`/`projectSource` into `entry.extras`.
- Auto-seed projects from unique `gitRemote` slugs the first time seen.
- Preferences › Projects tab: create/rename/archive, list learned rules.
- History viewer: filter-by-project dropdown + right-click "retag".

## Deferred to V2

- Post-paste toast (V1 ships chip-only; toast is nice-to-have).
- `.bundleIDPlusWindow` trigram learning, Slack channel extraction.
- Per-project custom vocabulary / prompt prefix injection.
- Merge projects operation (V1 archive only).
- Retroactive bulk tagging of old entries (script-only, documented).
- ML-based disambiguator.
- Cross-device sync.

## Open questions

1. Should the chip default to the *last-used project* when no signals match, or always "untagged"? *(Reco: last-used, 10-min decay.)*
2. When user manually picks a project that contradicts a learned rule, do we delete the rule, demote it, or add a negative example? *(Reco: demote: hits = max(0, hits − 2).)*
3. Project names — case-sensitive or normalized to lowercase slug with display label? *(Reco: slug + label.)*
4. For multi-signal contexts (git + browser), which wins when they point to different projects? *(Reco: higher tier wins; log conflicts for debugging.)*
5. Should archived projects still accept predictions or be fully skipped?

## Critical files for implementation

- `WhisperVoice/Sources/WhisperVoice/main.swift`:
  - `TranscriptionEntry` (~L2216), `HistoryManager` (~L2261)
  - `RecordingWindow` (~L2677), `ModeSelectorView` (~L2083)
  - `Config` (~L1586), `AppDelegate.finishWithText` (~L5467)
  - `ContextCapturer` (~L2335)
- `CLAUDE.md` — update Project Structure + Key Classes
- `~/Library/Application Support/WhisperVoice/projects.json` — new persistent store
