# Design — UI modernization

> **Status**: design draft, 2026-04-23.
> Pragmatic migration: keep AppKit for the things that work (recording panel,
> status bar item), move what looks dated to SwiftUI (Preferences, History,
> wizards).

## Context

The recording panel (RecordingWindow) feels right — dense, waveform-centric, stays out of the way. Everything else carries AppKit visual debt:

- Preferences tabs: horizontal NSTabView, frame-based layout (`x: 20, y: 350, width: 420`…), buttons truncate ("Save & A…", "Del…"), hint text collides with + buttons, no resize support. Feels like macOS Yosemite.
- History window: same pattern (resize bug we already patched with manual layout).
- Permission wizard and Update window: similar.
- No main menu (LSUIElement) → Cmd+C/V/A/Z don't route in text fields. *(Fixed in 3.5.x: proper main menu now installed.)*
- Inconsistent spacing, no shared design tokens, no dark/light refinement beyond default.

Apple's built-in System Settings and modern third-party apps (Ice, BetterDisplay, Shottr) use a **sidebar-navigation Preferences pattern**: NavigationSplitView left, `Form { Section {} }` right, rounded controls, generous whitespace, SF Symbols consistently.

## North star

**Migrate Preferences and History to SwiftUI with a modern sidebar pattern, while leaving the recording panel and status bar in AppKit.** NSHostingController lets us drop SwiftUI views into the existing NSWindow-based architecture without a rewrite.

## Scope

### In (V1)

- **PreferencesView** (SwiftUI) with sidebar: General, Shortcuts, Modes, Auto-mode, Projects, Logs
- **HistoryView** (SwiftUI): search, filter, resize-safe, detail panel on the right
- Shared design tokens: `Spacing.s / .m / .l` (4/8/16/24), `Colors.Accent`, SF Symbol names
- Native `NavigationSplitView`, `Form`, `Section`, `Toggle`, `Picker`, `TextField`

### Out (stays AppKit)

- RecordingWindow (works, changing it risks regressions on the critical path)
- Status bar item + menu (`NSStatusItem` + `NSMenu` — SwiftUI `MenuBarExtra` is more restrictive)
- Global hotkey registration, audio capture, paste pipeline

### Deferred

- Permission wizard (small, low usage after first run)
- Update window (infrequent)
- Fully SwiftUI app architecture (would require reworking AppDelegate lifecycle)

## Architecture

```
AppDelegate (AppKit, unchanged)
├─ NSStatusItem (AppKit)
├─ RecordingWindow (AppKit)
├─ HistoryWindow:
│   └─ NSHostingController<HistoryView>   ← SwiftUI
└─ PreferencesWindow:
    └─ NSHostingController<PreferencesView>  ← SwiftUI
```

Data flow:
- `Config.load()` / `Config.save()` stays as-is
- SwiftUI views use `@State` / `@StateObject` bound to a thin `ConfigStore: ObservableObject` that wraps `Config` + publishes changes
- On save, `ConfigStore` calls `Config.save()` and posts a `Notification.Name.configDidChange` so AppKit listeners refresh

## Data stores (SwiftUI observables)

```swift
final class ConfigStore: ObservableObject {
    @Published var provider: String
    @Published var apiKey: String
    @Published var customVocabulary: [String]
    @Published var appModeOverrides: [String: String]
    @Published var autoSelectModeEnabled: Bool
    // …one published property per Config field

    init() { self.load() }
    func load() { /* Config.load() → self */ }
    func save() { /* self → Config → save() */ }
}

final class ProjectStoreObservable: ObservableObject {
    @Published var projects: [Project] = []
    // thin wrapper over existing ProjectStore.shared
}

final class HistoryStoreObservable: ObservableObject {
    @Published var entries: [TranscriptionEntry] = []
    // listens to HistoryManager notifications
}
```

## PreferencesView sketch

```swift
struct PreferencesView: View {
    @StateObject private var store = ConfigStore()
    @State private var selection: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch selection {
            case .general:    GeneralPane(store: store)
            case .shortcuts:  ShortcutsPane(store: store)
            case .modes:      ModesPane(store: store)
            case .autoMode:   AutoModePane(store: store)
            case .projects:   ProjectsPane()
            case .logs:       LogsPane()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.load() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { store.save() } }
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case general, shortcuts, modes, autoMode, projects, logs
    var id: String { rawValue }
    var title: String { /* localized */ }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .modes: return "sparkles"
        case .autoMode: return "app.badge.checkmark"
        case .projects: return "folder"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}
```

Each pane is ~50-100 lines of `Form { Section { ... } }` declarative code vs. ~150-300 lines of imperative AppKit today.

## Visual design tokens

```swift
enum Spacing { static let s: CGFloat = 4, m: CGFloat = 8, l: CGFloat = 16, xl: CGFloat = 24 }
enum Icon {
    static let record = "mic.fill"
    static let project = "folder"
    static let app = "app.badge"
    static let log = "doc.text.magnifyingglass"
    // …
}
```

Rely on system defaults otherwise (no custom fonts, no custom color palette).

## Migration plan

1. **Add SwiftUI views in parallel**, behind a feature flag (`Config.useSwiftUIPrefs: Bool = false`). Ship both, let power users opt in.
2. **Iterate on one pane at a time** — start with Shortcuts (simplest: 2 controls) to validate the pattern, then General, Modes, Auto-mode, Projects, Logs.
3. **Once all panes are SwiftUI**, flip the flag on by default and remove the AppKit code (~1500 lines of `PreferencesWindow` disappear).
4. **History window**: migrate after Preferences is stable — same NSHostingController pattern.

Step 1 alone is shippable. Each subsequent step reduces AppKit legacy without breaking anything.

## Risks / unknowns

- **Text field editing shortcuts** (Cmd+C/V/A/Z) already work thanks to the main menu fix (3.5.x). SwiftUI inherits them.
- **Log tail updating in real time**: `LogsPane` needs a timer-backed `@State` refresh or listen to `LogManager` notifications. Minor.
- **NSTableView → List performance**: the history list can have thousands of entries. SwiftUI `List` handles 10k+ fine on macOS 13+. If perf drops, fall back to `LazyVStack` or keep AppKit `NSTableView` wrapped in `NSViewRepresentable`.
- **Binding custom AppKit controls** (ShortcutRecorderView) into SwiftUI requires wrapping in `NSViewRepresentable`. ~30 lines, standard pattern.

## V1 scope

- `ConfigStore: ObservableObject` wrapper over `Config`
- `PreferencesView` with `NavigationSplitView` + 6 panes
- `NSViewRepresentable` wrapper for `ShortcutRecorderView` (reused as-is)
- `NSHostingController<PreferencesView>` instantiated from `AppDelegate.showPreferences()` behind a `Config.useSwiftUIPrefs` flag
- Feature parity with current Preferences (all knobs present, saving/cancel works)
- `docs/` pages updated with screenshots of the new UI

## Deferred to V2+

- HistoryView SwiftUI migration (separate ship)
- Recording panel redesign (probably stays AppKit forever — it's fine)
- Permission wizard / Update window migration
- Full app lifecycle in SwiftUI (`@main struct App { WindowGroup {} }`) — requires massive AppDelegate rework for questionable gain

## Critical files

New:
- `WhisperVoice/Sources/WhisperVoice/UI/ConfigStore.swift`
- `WhisperVoice/Sources/WhisperVoice/UI/PreferencesView.swift`
- `WhisperVoice/Sources/WhisperVoice/UI/Panes/*.swift` (one file per pane)
- `WhisperVoice/Sources/WhisperVoice/UI/Representables/ShortcutRecorderRepresentable.swift`

Modified:
- `main.swift`:
  - `Config` — add `useSwiftUIPrefs: Bool`
  - `AppDelegate.showPreferences` — branch on the flag, instantiate `NSHostingController` if true
- `CLAUDE.md` — document the AppKit/SwiftUI split
