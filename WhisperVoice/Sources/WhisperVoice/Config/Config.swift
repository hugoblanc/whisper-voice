import Cocoa
import Carbon.HIToolbox

// MARK: - Post-transcription actions

struct PostAction {
    var id: String
    var label: String
    var type: String   // "paste" | "pasteEnter" | "command"
    var command: String

    static let builtInPaste = PostAction(id: "builtin-paste", label: "Paste", type: "paste", command: "")
    static let builtInPasteEnter = PostAction(id: "builtin-paste-enter", label: "Paste + ⏎", type: "pasteEnter", command: "")
    static let builtInCopyOnly = PostAction(id: "builtin-copy", label: "Copy only", type: "copy", command: "")
    static let builtInPasteTab = PostAction(id: "builtin-paste-tab", label: "Paste + ⇥", type: "pasteTab", command: "")
    static let builtInPasteSend = PostAction(id: "builtin-paste-send", label: "Paste + Send", type: "pasteSend", command: "")
    static let builtInPasteEscape = PostAction(id: "builtin-paste-escape", label: "Paste + Esc", type: "pasteEscape", command: "")
    static let builtIns: [PostAction] = [builtInPaste, builtInPasteEnter, builtInCopyOnly, builtInPasteTab, builtInPasteSend, builtInPasteEscape]

    var isBuiltIn: Bool { id.hasPrefix("builtin-") }

    func toDict() -> [String: String] {
        ["id": id, "label": label, "type": type, "command": command]
    }

    static func from(_ dict: [String: String]) -> PostAction? {
        guard let id = dict["id"], let label = dict["label"], let type = dict["type"] else { return nil }
        return PostAction(id: id, label: label, type: type, command: dict["command"] ?? "")
    }

    static func defaultActions() -> [[String: String]] {
        builtIns.map { $0.toDict() }
    }

    static func resolved(from dicts: [[String: String]], activeId: String) -> PostAction {
        if let dict = dicts.first(where: { $0["id"] == activeId }),
           let action = PostAction.from(dict) {
            return action
        }
        return builtInPaste
    }
}

// MARK: - Configuration

struct Config {
    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whisper-voice-config.json")

    var provider: String           // "openai", "mistral", or "local"
    var apiKey: String             // Main API key (backward compatibility)
    var providerApiKeys: [String: String]  // Per-provider API keys
    var shortcutModifiers: UInt32  // e.g., optionKey
    var shortcutKeyCode: UInt32    // e.g., kVK_Space
    var pushToTalkKeyCode: UInt32  // e.g., kVK_F3
    var pushToTalkModifiers: UInt32  // 0 = bare key

    // Local whisper.cpp settings
    var whisperCliPath: String     // Path to whisper-cli binary
    var whisperModelPath: String   // Path to ggml model file
    var whisperLanguage: String    // Language code (e.g., "fr", "en", "auto")

    // Custom vocabulary for better recognition
    var customVocabulary: [String]

    // Custom processing modes
    var customModes: [[String: String]]

    // Built-in mode IDs the user has hidden from the UI (empty by default).
    var disabledBuiltInModeIds: [String]

    // Project tagging
    var projectTaggingEnabled: Bool
    var lastUsedProjectID: String  // UUID string; "" = none

    // Auto-select mode by app: bundleID -> modeId
    var appModeOverrides: [String: String]
    var autoSelectModeEnabled: Bool
    /// When no mapping matches the current app, what should we do?
    /// false (default) → reset to Brut so Slack's mode doesn't leak into unrelated apps
    /// true            → keep the last-used mode (pre-3.6.2 behavior)
    var autoModeFallbackToLastUsed: Bool

    // LLM model for AI processing modes
    var processingModel: String

    // Post-transcription actions
    var postActions: [[String: String]]
    var activePostActionId: String

    // Update tracking
    var skippedUpdateVersion: String
    var lastUpdateCheck: Double  // TimeInterval since 1970

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // API key is optional for local provider
        let apiKey = json["apiKey"] as? String ?? ""
        let provider = json["provider"] as? String ?? "openai"

        // For cloud providers, API key is required
        if provider != "local" && apiKey.isEmpty {
            return nil
        }

        // Backward compatible loading
        let providerApiKeys = json["providerApiKeys"] as? [String: String] ?? [:]
        // Modifiers migration: a previous build briefly saved NSEvent.ModifierFlags
        // rawValues (>= 65536) instead of Carbon values (<= 4096). Convert back.
        func normalizeModifiers(_ raw: UInt32) -> UInt32 {
            guard raw >= 65536 else { return raw }
            return carbonModifiers(from: UInt(raw))
        }
        let modifiers = normalizeModifiers(json["shortcutModifiers"] as? UInt32 ?? UInt32(optionKey))
        let keyCode = json["shortcutKeyCode"] as? UInt32 ?? UInt32(kVK_Space)
        let pttKeyCode = json["pushToTalkKeyCode"] as? UInt32 ?? UInt32(kVK_F3)
        let pttModifiers = normalizeModifiers(json["pushToTalkModifiers"] as? UInt32 ?? 0)

        // Local whisper.cpp settings
        let whisperCliPath = json["whisperCliPath"] as? String ?? ""
        let whisperModelPath = json["whisperModelPath"] as? String ?? ""
        let whisperLanguage = json["whisperLanguage"] as? String ?? "fr"

        // Custom vocabulary
        let customVocabulary = json["customVocabulary"] as? [String] ?? []

        // Custom modes (default enabled = true for backwards compatibility)
        var customModes = json["customModes"] as? [[String: String]] ?? []
        customModes = customModes.map { mode in
            var m = mode
            if m["enabled"] == nil { m["enabled"] = "true" }
            return m
        }

        // Disabled built-in modes
        let disabledBuiltInModeIds = json["disabledBuiltInModeIds"] as? [String] ?? []

        // Project tagging
        let projectTaggingEnabled = json["projectTaggingEnabled"] as? Bool ?? true
        let lastUsedProjectID = json["lastUsedProjectID"] as? String ?? ""

        // Auto-select mode by app
        let appModeOverrides = json["appModeOverrides"] as? [String: String] ?? [:]
        let autoSelectModeEnabled = json["autoSelectModeEnabled"] as? Bool ?? true
        let autoModeFallbackToLastUsed = json["autoModeFallbackToLastUsed"] as? Bool ?? false

        // Processing model
        let processingModel = json["processingModel"] as? String ?? "gpt-5.4-nano"

        // Post-transcription actions
        let postActions = json["postActions"] as? [[String: String]] ?? PostAction.defaultActions()
        let activePostActionId = json["activePostActionId"] as? String ?? "builtin-paste"

        // Update tracking
        let skippedUpdateVersion = json["skippedUpdateVersion"] as? String ?? ""
        let lastUpdateCheck = json["lastUpdateCheck"] as? Double ?? 0

        return Config(
            provider: provider,
            apiKey: apiKey,
            providerApiKeys: providerApiKeys,
            shortcutModifiers: modifiers,
            shortcutKeyCode: keyCode,
            pushToTalkKeyCode: pttKeyCode,
            pushToTalkModifiers: pttModifiers,
            whisperCliPath: whisperCliPath,
            whisperModelPath: whisperModelPath,
            whisperLanguage: whisperLanguage,
            customVocabulary: customVocabulary,
            customModes: customModes,
            disabledBuiltInModeIds: disabledBuiltInModeIds,
            projectTaggingEnabled: projectTaggingEnabled,
            lastUsedProjectID: lastUsedProjectID,
            appModeOverrides: appModeOverrides,
            autoSelectModeEnabled: autoSelectModeEnabled,
            autoModeFallbackToLastUsed: autoModeFallbackToLastUsed,
            processingModel: processingModel,
            postActions: postActions,
            activePostActionId: activePostActionId,
            skippedUpdateVersion: skippedUpdateVersion,
            lastUpdateCheck: lastUpdateCheck
        )
    }

    func save() {
        var json: [String: Any] = [
            "provider": provider,
            "apiKey": apiKey,
            "shortcutModifiers": shortcutModifiers,
            "shortcutKeyCode": shortcutKeyCode,
            "pushToTalkKeyCode": pushToTalkKeyCode,
            "pushToTalkModifiers": pushToTalkModifiers
        ]
        if !providerApiKeys.isEmpty {
            json["providerApiKeys"] = providerApiKeys
        }
        // Save local whisper settings
        if !whisperCliPath.isEmpty {
            json["whisperCliPath"] = whisperCliPath
        }
        if !whisperModelPath.isEmpty {
            json["whisperModelPath"] = whisperModelPath
        }
        if !whisperLanguage.isEmpty {
            json["whisperLanguage"] = whisperLanguage
        }
        if !customVocabulary.isEmpty {
            json["customVocabulary"] = customVocabulary
        }
        if !customModes.isEmpty {
            json["customModes"] = customModes
        }
        if !disabledBuiltInModeIds.isEmpty {
            json["disabledBuiltInModeIds"] = disabledBuiltInModeIds
        }
        if !projectTaggingEnabled {
            json["projectTaggingEnabled"] = false
        }
        if !lastUsedProjectID.isEmpty {
            json["lastUsedProjectID"] = lastUsedProjectID
        }
        if !appModeOverrides.isEmpty {
            json["appModeOverrides"] = appModeOverrides
        }
        if !autoSelectModeEnabled {
            json["autoSelectModeEnabled"] = false
        }
        if autoModeFallbackToLastUsed {
            json["autoModeFallbackToLastUsed"] = true
        }
        if processingModel != "gpt-5.4-nano" {
            json["processingModel"] = processingModel
        }
        if !postActions.isEmpty {
            json["postActions"] = postActions
        }
        if activePostActionId != "builtin-paste" {
            json["activePostActionId"] = activePostActionId
        }
        if !skippedUpdateVersion.isEmpty {
            json["skippedUpdateVersion"] = skippedUpdateVersion
        }
        if lastUpdateCheck > 0 {
            json["lastUpdateCheck"] = lastUpdateCheck
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: Config.configPath)
        }
    }

    /// Get API key for the specified provider, falling back to main apiKey
    func getApiKey(for providerId: String) -> String {
        if let key = providerApiKeys[providerId], !key.isEmpty {
            return key
        }
        return apiKey
    }

    /// Get API key for the current provider
    func getCurrentApiKey() -> String {
        return getApiKey(for: provider)
    }

    func toggleShortcutDescription() -> String {
        var parts: [String] = []
        if shortcutModifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        if shortcutModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if shortcutModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if shortcutModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        parts.append(keyCodeToString(shortcutKeyCode))
        return parts.joined(separator: "+")
    }

    func pushToTalkDescription() -> String {
        return keyCodeToString(pushToTalkKeyCode) + " (hold)"
    }
}

func keyCodeToString(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_Space: return "Space"
    case kVK_Return: return "Return"
    case kVK_Tab: return "Tab"
    case kVK_Delete: return "Delete"
    case kVK_ForwardDelete: return "Fwd Delete"
    case kVK_Escape: return "Esc"
    case kVK_LeftArrow: return "←"
    case kVK_RightArrow: return "→"
    case kVK_UpArrow: return "↑"
    case kVK_DownArrow: return "↓"
    case kVK_Home: return "Home"
    case kVK_End: return "End"
    case kVK_PageUp: return "PgUp"
    case kVK_PageDown: return "PgDn"
    case kVK_F1: return "F1"
    case kVK_F2: return "F2"
    case kVK_F3: return "F3"
    case kVK_F4: return "F4"
    case kVK_F5: return "F5"
    case kVK_F6: return "F6"
    case kVK_F7: return "F7"
    case kVK_F8: return "F8"
    case kVK_F9: return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    case kVK_F13: return "F13"
    case kVK_F14: return "F14"
    case kVK_F15: return "F15"
    case kVK_F16: return "F16"
    case kVK_F17: return "F17"
    case kVK_F18: return "F18"
    case kVK_F19: return "F19"
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    case kVK_ANSI_Minus: return "-"
    case kVK_ANSI_Equal: return "="
    case kVK_ANSI_LeftBracket: return "["
    case kVK_ANSI_RightBracket: return "]"
    case kVK_ANSI_Semicolon: return ";"
    case kVK_ANSI_Quote: return "'"
    case kVK_ANSI_Comma: return ","
    case kVK_ANSI_Period: return "."
    case kVK_ANSI_Slash: return "/"
    case kVK_ANSI_Backslash: return "\\"
    case kVK_ANSI_Grave: return "`"
    default: return "Key(\(keyCode))"
    }
}

/// Format a Carbon-encoded modifier mask (optionKey, cmdKey, etc.) for display.
func modifiersToString(_ modifiers: UInt32) -> String {
    var parts: [String] = []
    if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
    if modifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
    if modifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
    if modifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
    return parts.joined()
}

/// Convert NSEvent.ModifierFlags rawValue to the Carbon mask the rest of the
/// codebase (Config, runtime matchers) expects. Only keeps the four main bits.
func carbonModifiers(from nsFlags: UInt) -> UInt32 {
    var m: UInt32 = 0
    if nsFlags & NSEvent.ModifierFlags.command.rawValue != 0 { m |= UInt32(cmdKey) }
    if nsFlags & NSEvent.ModifierFlags.option.rawValue != 0  { m |= UInt32(optionKey) }
    if nsFlags & NSEvent.ModifierFlags.control.rawValue != 0 { m |= UInt32(controlKey) }
    if nsFlags & NSEvent.ModifierFlags.shift.rawValue != 0   { m |= UInt32(shiftKey) }
    return m
}
