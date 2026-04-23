# Design — MCP server exposing dictation history

> **Status**: design draft, 2026-04-23.
> Biggest item on the roadmap. Unlocks a new interaction model: **voice as
> structured long-term input**, queryable by any MCP-compatible agent.

## Context

Whisper Voice's `history.json` is already rich: each entry carries `text`, `timestamp`, `durationSeconds`, `provider` + mode, and an `extras` bag with `projectID`/`projectName`/`projectSource`/`projectReason`/`projectConfidence` + a `signals` object (`windowTitle`, `browserURL`, `cwd`, `gitRemote`, `gitBranch`, `foregroundCmd`, `app.bundleID`, `app.name`). Plus the JSONL per-day export under `~/Library/Application Support/WhisperVoice/exports/`.

Today this data is searchable only through the app's History viewer. Exposing it via [MCP](https://modelcontextprotocol.io) lets Claude Code (and any other MCP client) answer questions like:

- *"Summarize what I dictated about superproper this week"*
- *"Find the dictation where I mentioned Rage Clicks in PostHog"*
- *"What was the last thing I said to Tim on Slack yesterday?"*
- *"Compare my dictations from the PR #143 review with what I said in the follow-up Slack thread"*

Voice stops being a keyboard-replacement and becomes a **personal knowledge stream** the agent can mine.

## North star

**Ship a local MCP server alongside Whisper Voice that exposes history as structured, queryable data. Zero network egress — everything stays on-device.**

## Architecture

Two runtime options:

### Option A — In-process MCP server

Whisper Voice itself runs an MCP server on a local Unix domain socket (or stdio for single-client direct launch). Pros: zero extra binary, always in sync with the live history. Cons: requires MCP SDK integration in Swift; JSON-RPC plumbing; the app process becomes a network surface.

### Option B — Standalone Swift binary `whispervoice-mcp` (recommended)

A separate Swift executable that reads `history.json` + JSONL exports from the shared Application Support dir. Pros: clean isolation; can be spawned by Claude Code via stdio as any normal MCP server; no changes to the main app runtime; can be kept up-to-date even if the main app is closed. Cons: a second binary to build and sign.

**Pick Option B.** The Claude Code config would look like:

```json
{
  "mcpServers": {
    "whisper-voice": {
      "command": "/Applications/Whisper Voice.app/Contents/Resources/whispervoice-mcp",
      "args": []
    }
  }
}
```

## Tool surface (MVP)

| Tool | Signature | Purpose |
|---|---|---|
| `list_dictations` | `(from?: date, to?: date, project?: string, app?: string, limit?: int)` | Paginated listing with basic filters |
| `search_dictations` | `(query: string, semantic?: bool, limit?: int)` | Full-text search (grep-like first; embedding-based later) |
| `get_dictation` | `(id: uuid)` | Full record incl. signals + extras |
| `list_projects` | `()` | All projects, tagged counts, active/archived |
| `list_apps` | `(min_count?: int)` | Distinct bundleIDs seen + counts (for discovery) |
| `stats` | `(from?: date, to?: date, group_by?: "day"/"project"/"app")` | Aggregates: total duration, word count, dictations per bucket |

## Resources (MCP concept)

Expose read-only resources too:

- `whispervoice://history/today` — today's dictations as newline-JSON
- `whispervoice://history/project/<id>` — entries tagged to a project
- `whispervoice://schema` — the JSON schema documenting the entry shape (self-documenting)

## Data access

Read-only. The server **never writes** to `history.json` — mutation stays the app's job. This keeps consistency simple (no locking between two processes).

Implementation:

1. Watch the file mtime; re-read on change (simple polling every 2s is fine for a personal tool).
2. Maintain an in-memory index: by date, by project, by bundleID.
3. For search: start with substring match over `text` + `windowTitle`. Move to embeddings (see below) once the library grows.

## Privacy / scope

- Default deny on PII-sensitive signals: `extras["projectReason"]` and signal paths might leak local filesystem layout. Make them opt-in via a capability flag returned to the MCP client at `initialize` time.
- No remote calls from the MCP server. Everything local.
- The user can disable the server per-project via `Project.mcpExposed: Bool = true` (niche, defer to V2).

## Semantic search (V2)

When the history grows past a few thousand entries, grep is cheap but dumb. Add embedding-based search:

1. On every new entry: generate a 512/1024-dim embedding (`text-embedding-3-small` or local `bge-small-en`) and persist to `embeddings.sqlite` or `embeddings.jsonl`.
2. `search_dictations(query, semantic: true)`: embed the query, brute-force cosine similarity against the corpus, return top-K.
3. Keep grep as the default; semantic is opt-in.

Cost check: 10k entries × ~200 tokens × $0.02/1M tokens = ~$0.04 total for OpenAI embedding. Negligible.

## Data freshness

If the user dictates while Claude Code is mid-conversation with the MCP server:

- `list_dictations` re-reads on each call, so the new entry shows up on the next tool call.
- No push/streaming notifications in MVP (MCP supports them but overkill for a single user).

## Build / ship

- New Swift target in the same package: `WhisperVoiceMCP` (executableTarget).
- Same `build-dmg.sh` logic: build arm64 + x86_64 + lipo, copy into `Whisper Voice.app/Contents/Resources/whispervoice-mcp`.
- A Prefs tab shows the exact snippet to paste into `claude_desktop_config.json` / `.claude/mcp.json`.
- Version the tool surface (`whispervoice-mcp --version`) so clients can check compatibility.

## V1 scope

- Standalone Swift binary, stdio transport, JSON-RPC 2.0 per MCP spec
- Tools: `list_dictations`, `search_dictations` (grep-only), `get_dictation`, `list_projects`, `stats`
- Resources: `whispervoice://history/today`, `whispervoice://schema`
- Read-only access to `history.json` + JSONL exports, no writes
- `docs/mcp.md` user guide (install, Claude Code config, available tools)
- Prefs "MCP integration" section with copy-paste config snippet

## Deferred to V2+

- Semantic search (embeddings)
- Push notifications via MCP subscriptions
- Write tools (e.g. `tag_dictation`, `create_project`) — requires coordinating with the main app process
- Audio retrieval (return raw .wav bytes for a dictation — blocks on audio retention policy)
- Authentication / multi-user (out of scope for a personal macOS app)
- Cross-machine MCP bridge (requires secure transport — defer until actually needed)

## Open questions

1. Should `search_dictations` return full text or snippets with highlighting? *(Reco: snippets + full on `get_dictation`.)*
2. How to handle archived projects in MCP queries? *(Reco: included by default, filterable via `include_archived: false`.)*
3. Rate-limiting — do we care? *(Reco: no, local single-user.)*
4. Should we cache parsed entries or re-parse on each call? *(Reco: cache + mtime watch.)*
5. What about the old pre-tagging entries (no signals)? *(Reco: expose them as-is; downstream decides relevance.)*

## Critical files

- `WhisperVoice/Package.swift` — add `WhisperVoiceMCP` executableTarget
- `WhisperVoice/Sources/WhisperVoiceMCP/main.swift` — MCP server entry
- `WhisperVoice/Sources/WhisperVoiceMCP/JSONRPC.swift` — transport
- `WhisperVoice/Sources/WhisperVoiceMCP/Tools.swift` — tool implementations
- `build-dmg.sh` — build + lipo the mcp binary, embed in Resources
- `docs/mcp.md`
