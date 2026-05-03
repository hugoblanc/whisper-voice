// SwiftUI-based Preferences, replacing the legacy AppKit PreferencesWindow.
// The AppKit class stays in main.swift as a fallback for now (dead code path).
// Entry point: SwiftUIPreferencesWindow (bottom of file).
//
// Pattern: ConfigStore holds a draft `Config` that panes bind to. Cancel reverts
// to disk state; "Save & Apply" flushes draft → disk. Projects/AutoMode mutations
// are immediate (same UX as before) but refresh the draft so Save doesn't clobber.

import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - ConfigStore

@MainActor
final class ConfigStore: ObservableObject {
    @Published var draft: Config
    private var saved: Config

    @Published var launchAtLogin: Bool = false
    @Published var connectionStatus: String = ""
    @Published var connectionStatusColor: ConnectionStatusColor = .neutral
    @Published var isTestingConnection: Bool = false

    enum ConnectionStatusColor { case neutral, success, warning, error }

    init() {
        let loaded = Config.load() ?? ConfigStore.fallbackConfig()
        self.saved = loaded
        self.draft = loaded
        self.launchAtLogin = LaunchAtLogin.isEnabled()
    }

    var hasChanges: Bool { !draft.isEqual(to: saved) }

    func save() {
        draft.save()
        saved = draft
        if LaunchAtLogin.isEnabled() != launchAtLogin {
            if launchAtLogin { LaunchAtLogin.enable() } else { LaunchAtLogin.disable() }
        }
        NotificationCenter.default.post(name: .whisperVoiceConfigDidChange, object: nil)
    }

    func reset() { draft = saved }

    /// Called by panes that write-through to disk immediately (Projects, AutoMode).
    /// Keeps the draft/saved baseline in sync so Save & Apply doesn't clobber.
    func refreshFromDisk() {
        guard let fresh = Config.load() else { return }
        saved = fresh
        draft = fresh
    }

    private static func fallbackConfig() -> Config {
        return Config(
            provider: "openai", apiKey: "", providerApiKeys: [:],
            shortcutModifiers: UInt32(optionKey), shortcutKeyCode: UInt32(kVK_Space),
            pushToTalkKeyCode: UInt32(kVK_F3), pushToTalkModifiers: 0,
            whisperCliPath: "", whisperModelPath: "", whisperLanguage: "fr",
            customVocabulary: [], customModes: [],
            disabledBuiltInModeIds: [],
            projectTaggingEnabled: true, lastUsedProjectID: "",
            appModeOverrides: [:], autoSelectModeEnabled: true, autoModeFallbackToLastUsed: false,
            processingModel: "gpt-5.4-nano",
            postActions: PostAction.defaultActions(), activePostActionId: "builtin-paste",
            skippedUpdateVersion: "", lastUpdateCheck: 0
        )
    }
}

extension Notification.Name {
    static let whisperVoiceConfigDidChange = Notification.Name("com.whisper-voice.configDidChange")
}

// Helper to compare configs without conforming to Equatable (Config has many fields).
extension Config {
    func isEqual(to other: Config) -> Bool {
        return provider == other.provider
            && apiKey == other.apiKey
            && providerApiKeys == other.providerApiKeys
            && shortcutModifiers == other.shortcutModifiers
            && shortcutKeyCode == other.shortcutKeyCode
            && pushToTalkKeyCode == other.pushToTalkKeyCode
            && pushToTalkModifiers == other.pushToTalkModifiers
            && whisperLanguage == other.whisperLanguage
            && whisperModelPath == other.whisperModelPath
            && customVocabulary == other.customVocabulary
            && customModes.map { $0["id"] ?? "" } == other.customModes.map { $0["id"] ?? "" }
            && customModes.map { $0["prompt"] ?? "" } == other.customModes.map { $0["prompt"] ?? "" }
            && customModes.map { $0["name"] ?? "" } == other.customModes.map { $0["name"] ?? "" }
            && customModes.map { $0["icon"] ?? "" } == other.customModes.map { $0["icon"] ?? "" }
            && customModes.map { $0["enabled"] ?? "" } == other.customModes.map { $0["enabled"] ?? "" }
            && disabledBuiltInModeIds == other.disabledBuiltInModeIds
            && projectTaggingEnabled == other.projectTaggingEnabled
            && appModeOverrides == other.appModeOverrides
            && autoSelectModeEnabled == other.autoSelectModeEnabled
            && autoModeFallbackToLastUsed == other.autoModeFallbackToLastUsed
            && processingModel == other.processingModel
            && postActions.map { $0["id"] ?? "" } == other.postActions.map { $0["id"] ?? "" }
            && postActions.map { $0["label"] ?? "" } == other.postActions.map { $0["label"] ?? "" }
            && postActions.map { $0["type"] ?? "" } == other.postActions.map { $0["type"] ?? "" }
            && postActions.map { $0["command"] ?? "" } == other.postActions.map { $0["command"] ?? "" }
            && activePostActionId == other.activePostActionId
    }
}

// MARK: - Launch at login helper (minimal, SMAppService on macOS 13+, fallback on older)

enum LaunchAtLogin {
    static func isEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
    static func enable() {
        if #available(macOS 13.0, *) { try? SMAppService.mainApp.register() }
    }
    static func disable() {
        if #available(macOS 13.0, *) { try? SMAppService.mainApp.unregister() }
    }
}

import ServiceManagement

// MARK: - ShortcutRecorder wrapper

struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    var allowsBareKeys: Bool = true

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView(keyCode: keyCode, modifiers: modifiers, allowsBareKeys: allowsBareKeys)
        v.onChange = { newKey, newMods in
            DispatchQueue.main.async {
                self.keyCode = newKey
                self.modifiers = newMods
            }
        }
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        if nsView.keyCode != keyCode { nsView.keyCode = keyCode }
        if nsView.modifiers != modifiers { nsView.modifiers = modifiers }
        nsView.updateDisplay()
    }
}

// MARK: - Preferences root

enum PreferencePane: String, CaseIterable, Identifiable {
    case general, shortcuts, modes, autoMode, actions, projects, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .modes: return "Modes"
        case .autoMode: return "Auto-mode"
        case .actions: return "Actions"
        case .projects: return "Projects"
        case .logs: return "Logs"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .modes: return "sparkles"
        case .autoMode: return "app.badge.checkmark"
        case .actions: return "bolt.circle"
        case .projects: return "folder"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

struct PreferencesView: View {
    @StateObject private var store = ConfigStore()
    @State private var selection: PreferencePane = .general

    var body: some View {
        NavigationSplitView {
            List(PreferencePane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch selection {
                case .general:   GeneralPane(store: store)
                case .shortcuts: ShortcutsPane(store: store)
                case .modes:     ModesPane(store: store)
                case .autoMode:  AutoModePane(store: store)
                case .actions:   ActionsPane(store: store)
                case .projects:  ProjectsPane(store: store)
                case .logs:      LogsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.reset() }
                        .disabled(!store.hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Apply") { store.save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.hasChanges)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - General pane

struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    @State private var showApiKey = false

    private var providers: [ProviderInfo] { TranscriptionProviderFactory.availableProviders }

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Provider", selection: $store.draft.provider) {
                    ForEach(providers, id: \.id) { p in Text(p.displayName).tag(p.id) }
                }
                Group {
                    if showApiKey {
                        TextField("API Key", text: apiKeyBinding)
                    } else {
                        SecureField("API Key", text: apiKeyBinding)
                    }
                }
                Toggle("Show API key", isOn: $showApiKey)
                if let url = apiKeyURL {
                    Link("Get your API key →", destination: url)
                        .font(.caption)
                }
            }

            Section("Custom vocabulary") {
                TextField("PostHog, Kubernetes, Chatwoot…", text: Binding(
                    get: { store.draft.customVocabulary.joined(separator: ", ") },
                    set: { store.draft.customVocabulary = $0
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    }
                ), axis: .vertical)
                .lineLimit(2...4)
                Text("Separated by commas. Sent to Whisper (biases transcription) and to the LLM (preserves spelling in reformatted output).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI processing") {
                Picker("Model", selection: $store.draft.processingModel) {
                    ForEach(TextProcessor.availableModels, id: \.id) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                Toggle("Launch at login", isOn: $store.launchAtLogin)
            }

            Section("Connection") {
                HStack(spacing: 12) {
                    Button {
                        testConnection()
                    } label: {
                        if store.isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(store.isTestingConnection)

                    if !store.connectionStatus.isEmpty {
                        Text(store.connectionStatus)
                            .font(.caption)
                            .foregroundStyle(connectionColor)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var apiKeyBinding: Binding<String> {
        Binding(get: { store.draft.apiKey }, set: { store.draft.apiKey = $0 })
    }

    private var apiKeyURL: URL? {
        switch store.draft.provider {
        case "openai": return URL(string: "https://platform.openai.com/api-keys")
        case "mistral": return URL(string: "https://console.mistral.ai/api-keys")
        default: return nil
        }
    }

    private var connectionColor: Color {
        switch store.connectionStatusColor {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }

    private func testConnection() {
        let provider = store.draft.provider
        let key = store.draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            store.connectionStatus = "API key is empty"
            store.connectionStatusColor = .error
            return
        }
        let validation = TranscriptionProviderFactory.validateApiKey(providerId: provider, apiKey: key)
        guard validation.valid else {
            store.connectionStatus = "Invalid: \(validation.error ?? "Unknown")"
            store.connectionStatusColor = .error
            return
        }

        store.isTestingConnection = true
        store.connectionStatus = "Testing…"
        store.connectionStatusColor = .neutral

        var req: URLRequest
        switch provider.lowercased() {
        case "mistral":
            req = URLRequest(url: URL(string: "https://api.mistral.ai/v1/models")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        default:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, response, err in
            DispatchQueue.main.async {
                store.isTestingConnection = false
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    store.connectionStatus = "Connected"
                    store.connectionStatusColor = .success
                } else if let err = err {
                    store.connectionStatus = "Failed: \(err.localizedDescription)"
                    store.connectionStatusColor = .error
                } else if let http = response as? HTTPURLResponse {
                    store.connectionStatus = "HTTP \(http.statusCode)"
                    store.connectionStatusColor = .error
                } else {
                    store.connectionStatus = "No response"
                    store.connectionStatusColor = .error
                }
            }
        }.resume()
    }
}

// MARK: - Shortcuts pane

struct ShortcutsPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("Toggle recording") {
                ShortcutRecorderRepresentable(
                    keyCode: $store.draft.shortcutKeyCode,
                    modifiers: $store.draft.shortcutModifiers,
                    allowsBareKeys: false
                )
                .frame(height: 40)
                Text("Click the field, then press the combination. Requires a modifier (Cmd / Option / Ctrl / Shift).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Push-to-Talk") {
                ShortcutRecorderRepresentable(
                    keyCode: $store.draft.pushToTalkKeyCode,
                    modifiers: $store.draft.pushToTalkModifiers,
                    allowsBareKeys: true
                )
                .frame(height: 40)
                Text("Any single key works (F3, F4…) or a combination. Hold to record, release to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Changes apply after clicking Save & Apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Modes pane

struct ModesPane: View {
    @ObservedObject var store: ConfigStore
    @State private var editingIndex: Int? = nil

    var body: some View {
        Form {
            Section("Built-in modes") {
                Text("Uncheck modes you don't use to keep the Shift-cycle picker short.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 8) {
                    ForEach(ModeManager.builtInModes, id: \.id) { mode in
                        Toggle(mode.name, isOn: builtInToggle(id: mode.id))
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Text("Custom modes")
                        .font(.headline)
                    Spacer()
                    Button {
                        let newMode: [String: String] = [
                            "id": "custom_\(Int(Date().timeIntervalSince1970))",
                            "name": "", "icon": "star", "prompt": "", "enabled": "true"
                        ]
                        store.draft.customModes.append(newMode)
                        editingIndex = store.draft.customModes.count - 1
                    } label: { Label("Add custom mode", systemImage: "plus") }
                }

                ForEach(store.draft.customModes.indices, id: \.self) { idx in
                    CustomModeRow(
                        mode: Binding(
                            get: { store.draft.customModes[idx] },
                            set: { store.draft.customModes[idx] = $0 }
                        ),
                        onDelete: { store.draft.customModes.remove(at: idx) }
                    )
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func builtInToggle(id: String) -> Binding<Bool> {
        Binding(
            get: { !store.draft.disabledBuiltInModeIds.contains(id) },
            set: { enabled in
                if enabled {
                    store.draft.disabledBuiltInModeIds.removeAll { $0 == id }
                } else if !store.draft.disabledBuiltInModeIds.contains(id) {
                    store.draft.disabledBuiltInModeIds.append(id)
                }
            }
        )
    }
}

struct CustomModeRow: View {
    @Binding var mode: [String: String]
    var onDelete: () -> Void

    @State private var showPromptSheet = false

    private let iconChoices = ["star", "envelope", "doc.text", "globe", "hammer", "wrench", "lightbulb", "book", "pencil", "text.bubble", "brain.head.profile", "list.bullet"]

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { (mode["enabled"] ?? "true") == "true" },
            set: { mode["enabled"] = $0 ? "true" : "false" }
        )
    }
    private var nameBinding: Binding<String> {
        Binding(get: { mode["name"] ?? "" }, set: { mode["name"] = $0 })
    }
    private var iconBinding: Binding<String> {
        Binding(get: { mode["icon"] ?? "star" }, set: { mode["icon"] = $0 })
    }
    private var promptBinding: Binding<String> {
        Binding(get: { mode["prompt"] ?? "" }, set: { mode["prompt"] = $0 })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Row 1 — metadata: enable toggle, name, icon, delete
                HStack(spacing: 10) {
                    Toggle("", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(enabledBinding.wrappedValue ? "Mode enabled" : "Mode disabled")

                    TextField("Mode name", text: nameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)

                    Picker("", selection: iconBinding) {
                        ForEach(iconChoices, id: \.self) { icon in
                            Label(icon, systemImage: icon).tag(icon)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    Spacer()

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this custom mode")
                }

                // Row 2 — system prompt, clearly labeled, framed, with an "expand" button
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("System prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(promptBinding.wrappedValue.count) chars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            showPromptSheet = true
                        } label: {
                            Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Open full-screen editor")
                    }

                    TextEditor(text: promptBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: 180)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .cornerRadius(6)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showPromptSheet) {
            PromptEditorSheet(
                modeName: nameBinding.wrappedValue.isEmpty ? "Untitled mode" : nameBinding.wrappedValue,
                prompt: promptBinding,
                isPresented: $showPromptSheet
            )
        }
    }
}

/// Full-height sheet editor for a mode's system prompt — much easier to iterate
/// on long prompts than the inline TextEditor.
struct PromptEditorSheet: View {
    let modeName: String
    @Binding var prompt: String
    @Binding var isPresented: Bool
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System prompt").font(.headline)
                    Text(modeName).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(draft.count) chars").font(.caption).foregroundStyle(.secondary)
            }

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 360)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(8)

            Text("Tip: start with \u{201C}Réponds UNIQUEMENT avec le texte, sans préambule\u{201D} to avoid the LLM prefixing its answer.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Apply") {
                    prompt = draft
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { draft = prompt }
    }
}

// MARK: - Auto-mode pane

struct AutoModeRow: Identifiable {
    let bundleID: String
    let modeId: String
    let displayName: String
    var id: String { bundleID }
}

struct AutoModePane: View {
    @ObservedObject var store: ConfigStore
    @State private var selected: String? = nil

    private var rows: [AutoModeRow] {
        store.draft.appModeOverrides
            .map { AutoModeRow(bundleID: $0.key, modeId: $0.value, displayName: displayName(for: $0.key)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Auto-select mode by app").font(.headline)
                    Spacer()
                    Button { addApp() } label: { Label("Add app", systemImage: "plus") }
                }
                Text("Pick an app, pick a mode. When you dictate in that app, the mode switches automatically. No match → current mode (last-used).")
                    .font(.caption).foregroundStyle(.secondary)

                Table(rows, selection: $selected) {
                    TableColumn("App") { row in
                        VStack(alignment: .leading) {
                            Text(row.displayName).bold()
                            Text(row.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("Mode") { row in
                        Text(modeName(for: row.modeId))
                    }
                }
                .frame(minHeight: 200)

                HStack {
                    Button("Change mode…") { changeMode() }
                        .disabled(selected == nil)
                    Button("Remove") { removeSelected() }
                        .disabled(selected == nil)
                    Spacer()
                }
            }

            Section {
                Toggle("Enable auto-select", isOn: $store.draft.autoSelectModeEnabled)
                Toggle("Keep the last-used mode when no rule matches", isOn: $store.draft.autoModeFallbackToLastUsed)
                    .disabled(!store.draft.autoSelectModeEnabled)
                Text(store.draft.autoModeFallbackToLastUsed
                     ? "When you open an app without a rule, Whisper Voice keeps whatever mode was active. Slack's mode may leak into unrelated dictations."
                     : "When you open an app without a rule, Whisper Voice resets to Brut so modes don't leak across contexts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(rows.map(\.bundleID).joined())  // re-render when map changes
    }

    private func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let b = Bundle(url: url),
           let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String), !name.isEmpty {
            return name
        }
        return bundleID
    }

    private func modeName(for id: String) -> String {
        ModeManager.shared.modes.first(where: { $0.id == id })?.name ?? id
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        guard let modeId = pickMode(title: "Mode for \(displayName(for: bundleID))", current: nil) else { return }
        store.draft.appModeOverrides[bundleID] = modeId
    }

    private func changeMode() {
        guard let bundleID = selected, let current = store.draft.appModeOverrides[bundleID] else { return }
        guard let modeId = pickMode(title: "Mode for \(displayName(for: bundleID))", current: current) else { return }
        store.draft.appModeOverrides[bundleID] = modeId
    }

    private func removeSelected() {
        guard let bundleID = selected else { return }
        store.draft.appModeOverrides.removeValue(forKey: bundleID)
        selected = nil
    }

    private func pickMode(title: String, current: String?) -> String? {
        let modes = ModeManager.shared.modes.filter { ModeManager.shared.isModeAvailable($0) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Pick the processing mode to apply in this app."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        for mode in modes {
            popup.addItem(withTitle: mode.name)
            popup.lastItem?.representedObject = mode.id
        }
        if let current = current, let idx = modes.firstIndex(where: { $0.id == current }) {
            popup.selectItem(at: idx)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? String
    }
}

// MARK: - Actions pane

struct ActionsPane: View {
    @ObservedObject var store: ConfigStore
    @State private var editingAction: PostAction? = nil
    @State private var showEditor = false

    private var actions: [PostAction] {
        store.draft.postActions.compactMap { PostAction.from($0) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Post-transcription actions").font(.headline)
                    Spacer()
                    Button { addAction() } label: { Label("Add action", systemImage: "plus") }
                }
                Text("After transcription, Whisper Voice executes the active action. Default is Paste.")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(actions, id: \.id) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.id == store.draft.activePostActionId ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(action.id == store.draft.activePostActionId ? .blue : .secondary)
                            .onTapGesture { store.draft.activePostActionId = action.id }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.label).bold()
                            if action.isBuiltIn {
                                Text(actionTypeLabel(action.type))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(action.command.isEmpty ? "No command" : action.command)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        if !action.isBuiltIn {
                            Button { editAction(action) } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            Button(role: .destructive) { removeAction(action) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
            }

            Section("Variables") {
                Text("""
                    Commands receive these environment variables:
                    $WV_TRANSCRIPTION — processed text
                    $WV_RAW_TRANSCRIPTION — raw text before mode processing
                    $WV_APP_BUNDLE_ID — source app bundle ID
                    $WV_APP_NAME — source app name
                    $WV_MODE — current mode
                    $WV_PROJECT — tagged project name
                    Use $(pbpaste) to include clipboard content.
                    """)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showEditor) {
            ActionEditorSheet(
                action: editingAction ?? PostAction(id: UUID().uuidString, label: "", type: "command", command: ""),
                isPresented: $showEditor,
                isNew: editingAction == nil
            ) { saved in
                saveAction(saved)
            }
        }
    }

    private func actionTypeLabel(_ type: String) -> String {
        switch type {
        case "paste": return "Paste text at cursor (Cmd+V)"
        case "pasteEnter": return "Paste text then press Enter"
        case "command": return "Run shell command"
        default: return type
        }
    }

    private func addAction() {
        editingAction = nil
        showEditor = true
    }

    private func editAction(_ action: PostAction) {
        editingAction = action
        showEditor = true
    }

    private func removeAction(_ action: PostAction) {
        store.draft.postActions.removeAll { $0["id"] == action.id }
        if store.draft.activePostActionId == action.id {
            store.draft.activePostActionId = "builtin-paste"
        }
    }

    private func saveAction(_ action: PostAction) {
        let dict = action.toDict()
        if let idx = store.draft.postActions.firstIndex(where: { $0["id"] == action.id }) {
            store.draft.postActions[idx] = dict
        } else {
            store.draft.postActions.append(dict)
        }
    }
}

struct ActionEditorSheet: View {
    @State var action: PostAction
    @Binding var isPresented: Bool
    let isNew: Bool
    let onSave: (PostAction) -> Void

    @State private var testOutput: String = ""
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New action" : "Edit action").font(.headline)

            TextField("Name", text: $action.label)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Shell command").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $action.command)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .cornerRadius(6)
            }

            HStack {
                Button {
                    testCommand()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test", systemImage: "play.circle")
                    }
                }
                .disabled(action.command.isEmpty || isTesting)

                if !testOutput.isEmpty {
                    Text(testOutput)
                        .font(.caption)
                        .foregroundStyle(testOutput.starts(with: "OK") ? .green : .red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Save") {
                    if action.label.isEmpty { action.label = "Custom action" }
                    action.type = "command"
                    onSave(action)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action.command.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    private func testCommand() {
        isTesting = true
        testOutput = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", action.command]
        var env = ProcessInfo.processInfo.environment
        env["WV_TRANSCRIPTION"] = "Test transcription from Whisper Voice"
        env["WV_RAW_TRANSCRIPTION"] = "Test transcription from Whisper Voice"
        env["WV_APP_BUNDLE_ID"] = "com.example.test"
        env["WV_APP_NAME"] = "TestApp"
        env["WV_MODE"] = "brut"
        env["WV_PROJECT"] = "test-project"
        process.environment = env

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                process.waitUntilExit()
                let status = process.terminationStatus
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    isTesting = false
                    if status == 0 {
                        testOutput = "OK (exit 0)"
                    } else {
                        testOutput = "Exit \(status): \(stderr.prefix(100))"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isTesting = false
                    testOutput = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Projects pane

struct ProjectsPane: View {
    @ObservedObject var store: ConfigStore
    @State private var projects: [Project] = ProjectStore.shared.all
    @State private var selection: UUID? = nil

    private var counts: [UUID: Int] {
        let entries = HistoryManager.shared.getEntries()
        var dict: [UUID: Int] = [:]
        for e in entries {
            if let pid = e.projectID { dict[pid, default: 0] += 1 }
        }
        return dict
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Projects").font(.headline)
                    Spacer()
                    Button { newProject() } label: { Label("New project", systemImage: "plus") }
                }
                Text("Created projects can be assigned during recording or retroactively from the History viewer.")
                    .font(.caption).foregroundStyle(.secondary)

                Table(projects, selection: $selection) {
                    TableColumn("Name") { p in
                        Text(p.name).foregroundStyle(p.archived ? .secondary : .primary)
                    }
                    TableColumn("Entries") { p in
                        Text("\(counts[p.id] ?? 0)")
                    }
                    TableColumn("Status") { p in
                        Text(p.archived ? "Archived" : "Active").foregroundStyle(p.archived ? .secondary : .primary)
                    }
                }
                .frame(minHeight: 220)

                HStack {
                    Button("Rename") { rename() }.disabled(selection == nil)
                    Button("Archive / Restore") { toggleArchive() }.disabled(selection == nil)
                    Button("Untag all") { untagAll() }.disabled(selection == nil)
                    Spacer()
                    Button("Delete", role: .destructive) { delete() }.disabled(selection == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private func refresh() {
        projects = ProjectStore.shared.all
    }

    private func newProject() {
        guard let name = promptText(title: "New project", message: "Enter a name:", placeholder: "e.g. superproper") else { return }
        _ = ProjectStore.shared.create(name: name)
        refresh()
    }

    private func rename() {
        guard let id = selection, let p = ProjectStore.shared.byID(id) else { return }
        guard let newName = promptText(title: "Rename \(p.name)", message: "New name:", initial: p.name) else { return }
        ProjectStore.shared.rename(id, to: newName)
        refresh()
    }

    private func toggleArchive() {
        guard let id = selection, let p = ProjectStore.shared.byID(id) else { return }
        ProjectStore.shared.setArchived(id, !p.archived)
        refresh()
    }

    private func untagAll() {
        guard let id = selection, let p = ProjectStore.shared.byID(id) else { return }
        let tagged = HistoryManager.shared.getEntries().filter { $0.projectID == id }
        guard !tagged.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Untag \(tagged.count) entr\(tagged.count == 1 ? "y" : "ies") from “\(p.name)”?"
        alert.informativeText = "The project stays. You can retag the entries individually later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Untag all")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryManager.shared.updateEntries(tagged.map { $0.tagged(with: nil, source: "manual") })
        refresh()
    }

    private func delete() {
        guard let id = selection, let p = ProjectStore.shared.byID(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(p.name)”?"
        alert.informativeText = "Tagged entries keep their tag but the project disappears from filters. Can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProjectStore.shared.delete(id)
        selection = nil
        refresh()
    }

    private func promptText(title: String, message: String, initial: String = "", placeholder: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

// MARK: - Logs pane

struct LogsPane: View {
    @State private var logs: String = ""
    @State private var autoScroll: Bool = true
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Clear logs") {
                    try? "".write(to: logFileURL(), atomically: true, encoding: .utf8)
                    refresh()
                }
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logs)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("logs-bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                .onChange(of: logs) { _ in
                    if autoScroll { proxy.scrollTo("logs-bottom", anchor: .bottom) }
                }
            }
        }
        .onAppear {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                refresh()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice/logs.txt")
    }

    private func refresh() {
        if let contents = try? String(contentsOf: logFileURL(), encoding: .utf8) {
            // Tail: keep last ~300 lines to stay snappy
            let lines = contents.components(separatedBy: "\n")
            logs = lines.suffix(300).joined(separator: "\n")
        }
    }
}

// MARK: - Hosting window

final class SwiftUIPreferencesWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onSettingsChanged: (() -> Void)?
    private var configChangeObserver: NSObjectProtocol?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PreferencesView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Whisper Voice Preferences"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 820, height: 560))
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w

            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .whisperVoiceConfigDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onSettingsChanged?()
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
