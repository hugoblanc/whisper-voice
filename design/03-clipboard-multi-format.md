# Design — Multi-format clipboard (mode-aware)

> **Status**: design draft. No implementation yet.
> 2026-04-23.

## Context

Today `pasteText` writes two clipboard formats when Slack-style markup is detected:

- `public.utf8-plain-text` — always, the markdown source
- `public.html` — if `*bold*`, `_italic_`, `` ` `` or list markers are found, via `slackMarkdownToHTML`

The detector is Slack-flavored only. The Markdown built-in mode emits CommonMark (`**bold**`, `# header`, `[lien](url)`) which the current detector **ignores** — so Notion, Gmail, Mail all receive raw `**bold**` as plain text. We exploit maybe 10% of the multi-format pressepapier potential.

## North star

**Each mode declares its markdown "flavor". `pasteText` picks the right HTML converter based on that flavor. Plain text always written. HTML/RTF written when relevant.** No more guessing from the output text alone.

## Proposal — 3 levels of ambition

### Level 1 — Add CommonMark to the existing detector

Extend `slackMarkupDetected` + `slackMarkdownToHTML` to also catch `**bold**`, `# headers`, `[link](url)`, numbered lists. ~30 lines. Covers 95% of cases but the detector heuristics get fragile (mixing dialects → false positives like `**` in regex snippets).

### Level 2 — Per-mode flavor declaration (recommended)

Add a property on `ProcessingMode`:

```swift
enum MarkdownFlavor: String, Codable { case none, slack, commonmark }
struct ProcessingMode {
    ...
    var flavor: MarkdownFlavor = .none
}
```

Built-in mapping:
- Slack custom mode → `.slack`
- Markdown built-in → `.commonmark`
- Brut / Clean / Formel / Casual / Super → `.none`
- Custom modes → user-editable, default `.commonmark`

`pasteText(text:flavor:)` dispatches to the right converter. No detector needed — the mode tells us upfront.

Converter split:
- `slackToHTML(md)` — current code
- `commonmarkToHTML(md)` — new; handles `**x**`, `*x*`, `` `x` `` , `# h1`, `## h2`, `[text](url)`, `- / 1.` lists, `> quote`, ` ```fenced``` `

### Level 3 — Add RTF + destination-aware system prompts

Additions over level 2:

- Write `public.rtf` alongside plain + HTML for TextEdit/Pages/Keynote/older Mail clients.
- **Inject the destination's markdown dialect into the LLM system prompt** based on auto-mode. If `com.apple.mail` → prompt says *"emit standard markdown"*. If `com.tinyspeck.slackmacgap` → *"emit Slack syntax (`*bold*`, `_italic_`)"*. Closes the loop: one custom mode can serve multiple apps because the prompt adapts.

Level 3 requires moving some auto-mode wiring into `TextProcessor` (currently auto-mode only swaps modes). Non-trivial but consistent.

## Data model changes (level 2)

```swift
// ProcessingMode (existing)
struct ProcessingMode {
    let id: String
    let name: String
    let icon: String
    let systemPrompt: String?
    var flavor: MarkdownFlavor = .none   // NEW
}

// Config.customModes (existing dict-encoded list)
// Add a "flavor" key per custom mode entry:
//   [..., "flavor": "commonmark"]
// Absent → default to "commonmark" (safe default for user-authored modes).
```

No new files. Converter functions live next to `pasteText` in `main.swift`.

## Clipboard contract

```
Always:     public.utf8-plain-text  (source of truth)
If flavor != .none
  AND markup characters are present
  AND converter returns non-empty:
            public.html             (rendered HTML fragment)
Level 3:    public.rtf              (same content, NSAttributedString → RTF data)
```

Apps pick what they can consume (Slack, Notion, Gmail → HTML; Terminal, VSCode → plain; TextEdit/Pages → RTF if present, else HTML).

## Consumer behavior table (expected)

| App | Preferred format | Renders |
|---|---|---|
| Slack (WYSIWYG off) | plain | markup visible |
| Slack (WYSIWYG on) | HTML | styled |
| Notion | HTML | styled |
| Gmail web | HTML | styled |
| Apple Mail | HTML / RTF | styled |
| TextEdit | RTF > HTML | styled |
| Pages / Keynote | RTF > HTML | styled |
| Terminal / iTerm | plain | raw |
| VSCode / Xcode | plain | raw |
| Chrome `<textarea>` | plain | raw |

## Preferences UX (level 2)

Per custom mode in the Prefs table, add a small dropdown:

```
Name: [Slack      ] Icon: [star ▾] Flavor: [Slack ▾]    [x] Enabled
Prompt: ...
```

Default flavor for new custom modes = `commonmark`. Built-in modes show the flavor read-only.

## Fallbacks / edge cases

- Converter returns nil (e.g. malformed regex on pathological input) → drop HTML silently, write plain only, log warning.
- User sets flavor but mode returns pure prose → detector skip, plain only written (expected).
- Destination app doesn't read HTML → plain text wins (free fallback, no action required).
- Pre-existing clipboard content is overwritten regardless of level — same as today.

## V1 scope (level 2 implementation)

- `MarkdownFlavor` enum + property on `ProcessingMode`.
- Default flavor for each built-in mode (Slack → slack, Markdown → commonmark, rest → none).
- New `commonmarkToHTML(_:)` function (mirror structure of `slackMarkdownToHTML`).
- Refactor `pasteText` to accept or look up flavor from `selectedModeForCurrentRecording`.
- Prefs: add flavor picker per custom mode, read-only cell for built-ins.
- CLAUDE.md: document flavor field + converter split.
- `docs/clipboard.md`: update with per-mode flavor behavior.

## Deferred to V3

- RTF output.
- Destination-aware prompt injection (would require extending `TextProcessor` to receive DictationContext).
- Per-destination user overrides (e.g. "always emit Slack syntax in Notion" — niche).
- Image/file passthrough (out of scope for a text app).

## Critical files

- `WhisperVoice/Sources/WhisperVoice/main.swift`:
  - `ProcessingMode` struct (~L2459) — add `flavor`
  - `ModeManager.builtInModes` (~L2492) — set flavor per built-in
  - `ModeManager.reloadModes` (~L2580) — read flavor from customModes dict
  - `pasteText` (~L5944) — accept flavor, new dispatch
  - Add `commonmarkToHTML(_:)` near `slackMarkdownToHTML`
  - `PreferencesWindow.refreshModesUI` (~L999) — add flavor dropdown per custom mode card
- `CLAUDE.md` — Key Classes / Configuration sections
- `docs/clipboard.md` — user doc
