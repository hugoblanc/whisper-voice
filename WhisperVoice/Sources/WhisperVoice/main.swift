import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import os.log


// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var audioRecorder = AudioRecorder()
    private var transcriptionProvider: TranscriptionProvider?
    private var config: Config?

    // Toggle mode monitors
    private var toggleGlobalMonitor: Any?
    private var toggleLocalMonitor: Any?

    // Push-to-talk monitors
    private var pttGlobalKeyDownMonitor: Any?
    private var pttGlobalKeyUpMonitor: Any?
    private var pttLocalMonitor: Any?

    // Cancel monitor (Escape key)
    private var cancelGlobalMonitor: Any?
    private var cancelLocalMonitor: Any?
    private var modeSwitchGlobalMonitor: Any?
    private var modeSwitchLocalMonitor: Any?
    private var selectedModeForCurrentRecording: ProcessingMode?

    // Enter key tap: cycle post-actions during recording (suppresses key propagation)
    private var enterEventTap: CFMachPort?
    private var enterRunLoopSource: CFRunLoopSource?
    private var postActionOverrideId: String?

    // Live transcript via OpenAI Realtime API
    private var realtimeTranscriber: RealtimeTranscriber?

    // Permission wizard
    private var permissionWizard: PermissionWizard?

    // Preferences window
    private var swiftUIPreferencesWindow: SwiftUIPreferencesWindow?

    // Recording window (waveform display)
    private var recordingWindow: RecordingWindow?

    // History window
    private var historyWindow: HistoryWindow?

    // Update window
    private var updateWindow: UpdateWindow?

    // Recording start time for duration tracking
    private var recordingStartTime: Date?

    // Menu items that need updating
    private var toggleShortcutMenuItem: NSMenuItem?
    private var pttMenuItem: NSMenuItem?

    private enum AppState {
        case idle, recording, transcribing
    }
    private var state: AppState = .idle
    private var isPushToTalkActive = false  // Track if current recording is from PTT
    private var capturedContext: String?  // Context captured for Super Mode
    private var pendingDictationContext: DictationContext?  // Captured at recording start, attached on save
    private var pendingProject: Project?  // User-facing project chip selection; nil = untagged
    private var pendingProjectSource: String = "none"  // "predicted" | "manual" | "last-used" | "none"
    private var pendingProjectReason: String = ""      // What triggered the prediction — for details popover
    private var pendingProjectConfidence: Double = 0
    private var pendingAutoModeReason: String?         // e.g. "auto: Clean (Slack)"; nil once user overrides

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install a proper main menu so text fields get standard editing
        // shortcuts (Cmd+C/V/A/Z) and the app menu bar looks native when any
        // of our windows becomes key. LSUIElement=true means the menu bar is
        // hidden by default, but Cocoa still needs the menu installed to route
        // the editing commands through NSResponder.
        NSApp.mainMenu = buildMainMenu()

        // Eagerly init HistoryManager so the JSONL export dir is created and the
        // one-time migration from history.json runs on first launch after update.
        _ = HistoryManager.shared

        // Load config or show setup wizard
        if let config = Config.load() {
            self.config = config
            self.transcriptionProvider = TranscriptionProviderFactory.create(from: config)
            logger.info("Using transcription provider: \(self.transcriptionProvider?.displayName ?? "unknown")")
            checkPermissionsAndSetup()
        } else {
            showConfigError()
        }
    }

    /// Build the standard macOS main menu: App / Edit / Window / Help.
    /// Without this, Cmd+C/V/A/Z don't work in text fields because Cocoa
    /// wires those selectors through the main menu responder chain.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // ── App menu (shows as "Whisper Voice")
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Whisper Voice")
        appMenu.addItem(NSMenuItem(title: "About Whisper Voice", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Whisper Voice", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Whisper Voice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        // ── Edit menu (critical for text field editing shortcuts)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        // ── Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "h"))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        main.addItem(windowItem)

        // ── Help menu (same links as the status-bar Help submenu)
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let helpLinks: [(String, String)] = [
            ("Documentation", "https://github.com/hugoblanc/whisper-voice/tree/main/docs"),
            ("Modes", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/modes.md"),
            ("Auto-mode by app", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/auto-mode.md"),
            ("Projects", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/projects.md"),
            ("Custom vocabulary", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/vocabulary.md"),
            ("Pressepapier multi-format", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/clipboard.md"),
            ("Raccourcis & Push-to-Talk", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/shortcuts.md"),
        ]
        for (title, url) in helpLinks {
            let item = NSMenuItem(title: title, action: #selector(openHelpURL(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            helpMenu.addItem(item)
        }
        helpMenu.addItem(.separator())
        let issues = NSMenuItem(title: "Report an Issue…", action: #selector(openHelpURL(_:)), keyEquivalent: "")
        issues.target = self
        issues.representedObject = "https://github.com/hugoblanc/whisper-voice/issues"
        helpMenu.addItem(issues)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        main.addItem(helpItem)

        return main
    }

    private func checkPermissionsAndSetup() {
        let missingPermissions = PermissionChecker.missingPermissions()

        if missingPermissions.isEmpty {
            logger.info("All permissions granted, starting app")
            setupStatusBar()
        } else {
            logger.info("Missing permissions: \(missingPermissions.map { $0.title }.joined(separator: ", "))")
            showPermissionWizard(permissions: missingPermissions)
        }
    }

    private func showPermissionWizard(permissions: [PermissionType]) {
        permissionWizard = PermissionWizard(permissionsToRequest: permissions) { [weak self] in
            self?.permissionWizard = nil
            self?.setupStatusBar()
        }
        permissionWizard?.show()
    }

    private func showConfigError() {
        // Show setup wizard instead of error
        if let config = showSetupWizard() {
            self.config = config
            self.transcriptionProvider = TranscriptionProviderFactory.create(from: config)
            logger.info("Using transcription provider: \(self.transcriptionProvider?.displayName ?? "unknown")")
            checkPermissionsAndSetup()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func setupStatusBar() {
        guard let config = config else { return }

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        // Create menu
        let menu = NSMenu()

        toggleShortcutMenuItem = NSMenuItem(title: "\(config.toggleShortcutDescription()) to toggle", action: nil, keyEquivalent: "")
        menu.addItem(toggleShortcutMenuItem!)

        pttMenuItem = NSMenuItem(title: "\(config.pushToTalkDescription()) to record", action: nil, keyEquivalent: "")
        menu.addItem(pttMenuItem!)

        menu.addItem(NSMenuItem.separator())

        let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        // Action submenu
        let actionItem = NSMenuItem(title: "Action", action: nil, keyEquivalent: "")
        let actionMenu = NSMenu(title: "Action")
        let actions = config.postActions.compactMap { PostAction.from($0) }
        for action in actions {
            let item = NSMenuItem(title: action.label, action: #selector(selectPostAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.id
            item.state = action.id == config.activePostActionId ? .on : .off
            actionMenu.addItem(item)
        }
        actionItem.submenu = actionMenu
        actionItem.tag = 200
        menu.addItem(actionItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "History...", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check Permissions...", action: #selector(showPermissionStatus), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))

        // Help submenu — links to the GitHub docs so users can find feature-specific pages.
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        let helpLinks: [(String, String)] = [
            ("Documentation index", "https://github.com/hugoblanc/whisper-voice/tree/main/docs"),
            ("Modes", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/modes.md"),
            ("Auto-mode by app", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/auto-mode.md"),
            ("Projects", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/projects.md"),
            ("Custom vocabulary", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/vocabulary.md"),
            ("Pressepapier multi-format", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/clipboard.md"),
            ("Raccourcis & Push-to-Talk", "https://github.com/hugoblanc/whisper-voice/blob/main/docs/shortcuts.md"),
        ]
        for (title, url) in helpLinks {
            let item = NSMenuItem(title: title, action: #selector(openHelpURL(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            helpMenu.addItem(item)
        }
        helpMenu.addItem(NSMenuItem.separator())
        let issuesItem = NSMenuItem(title: "Report an issue…", action: #selector(openHelpURL(_:)), keyEquivalent: "")
        issuesItem.target = self
        issuesItem.representedObject = "https://github.com/hugoblanc/whisper-voice/issues"
        helpMenu.addItem(issuesItem)
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Version \(UpdateChecker.currentVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Setup both hotkeys (toggle + push-to-talk)
        setupToggleHotkey()
        setupPushToTalkHotkey()

        LogManager.shared.log("App started - Provider: \(transcriptionProvider?.displayName ?? "unknown")")
        print("Whisper Voice started (dual mode: toggle + push-to-talk)")

        // Silent update check on launch
        checkForUpdatesSilently()
    }

    // Store selected provider info for link button
    private var selectedProviderInfo: ProviderInfo?

    private func showSetupWizard() -> Config? {
        let alert = NSAlert()
        alert.messageText = "Whisper Voice Setup"
        alert.informativeText = "Configure your voice transcription settings"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save & Start")
        alert.addButton(withTitle: "Cancel")

        // Create accessory view for inputs
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 240))

        // Provider selection label
        let providerLabel = NSTextField(labelWithString: "Transcription Provider:")
        providerLabel.frame = NSRect(x: 0, y: 210, width: 350, height: 20)
        accessoryView.addSubview(providerLabel)

        // Provider popup
        let providerPopup = NSPopUpButton(frame: NSRect(x: 0, y: 185, width: 200, height: 24))
        for provider in TranscriptionProviderFactory.availableProviders {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider
        }
        providerPopup.selectItem(at: 0)
        selectedProviderInfo = TranscriptionProviderFactory.availableProviders.first
        accessoryView.addSubview(providerPopup)

        // API Key label
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 0, y: 155, width: 350, height: 20)
        accessoryView.addSubview(apiKeyLabel)

        // API Key field
        let apiKeyField = NSSecureTextField(frame: NSRect(x: 0, y: 130, width: 350, height: 24))
        apiKeyField.placeholderString = "sk-..."
        accessoryView.addSubview(apiKeyField)

        // API Key link
        let linkButton = NSButton(frame: NSRect(x: 0, y: 105, width: 300, height: 20))
        linkButton.bezelStyle = .inline
        linkButton.isBordered = false
        linkButton.target = self
        linkButton.action = #selector(openAPIKeyPage)
        updateLinkButton(linkButton, for: TranscriptionProviderFactory.availableProviders.first!)
        accessoryView.addSubview(linkButton)

        // Provider change handler - update link and placeholder when provider changes
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        objc_setAssociatedObject(providerPopup, "linkButton", linkButton, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(providerPopup, "apiKeyField", apiKeyField, .OBJC_ASSOCIATION_RETAIN)

        // Toggle shortcut label
        let shortcutLabel = NSTextField(labelWithString: "Toggle Shortcut:")
        shortcutLabel.frame = NSRect(x: 0, y: 70, width: 150, height: 20)
        accessoryView.addSubview(shortcutLabel)

        // Toggle shortcut popup
        let shortcutPopup = NSPopUpButton(frame: NSRect(x: 0, y: 45, width: 160, height: 24))
        shortcutPopup.addItems(withTitles: ["Option+Space", "Control+Space", "Cmd+Shift+Space"])
        shortcutPopup.selectItem(at: 0)
        accessoryView.addSubview(shortcutPopup)

        // PTT key label
        let pttLabel = NSTextField(labelWithString: "Push-to-Talk Key:")
        pttLabel.frame = NSRect(x: 180, y: 70, width: 150, height: 20)
        accessoryView.addSubview(pttLabel)

        // PTT key popup
        let pttPopup = NSPopUpButton(frame: NSRect(x: 180, y: 45, width: 160, height: 24))
        pttPopup.addItems(withTitles: ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"])
        pttPopup.selectItem(at: 2) // F3 default
        accessoryView.addSubview(pttPopup)

        // Auto-start checkbox
        let autoStartCheck = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
        autoStartCheck.frame = NSRect(x: 0, y: 10, width: 200, height: 20)
        accessoryView.addSubview(autoStartCheck)

        alert.accessoryView = accessoryView

        // Show dialog
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            // Get selected provider
            guard let selectedProvider = providerPopup.selectedItem?.representedObject as? ProviderInfo else {
                return showSetupWizard()
            }

            // Provider-specific validation
            let validation = TranscriptionProviderFactory.validateApiKey(providerId: selectedProvider.id, apiKey: apiKey)
            if !validation.valid {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Invalid API Key"
                errorAlert.informativeText = validation.error ?? "Please check your API key."
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
                return showSetupWizard() // Retry
            }

            // Parse shortcut
            let modifiers: UInt32
            switch shortcutPopup.indexOfSelectedItem {
            case 1: modifiers = UInt32(controlKey)
            case 2: modifiers = UInt32(cmdKey | shiftKey)
            default: modifiers = UInt32(optionKey)
            }

            // Parse PTT key
            let pttKeyCodes: [UInt32] = [
                UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
                UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
                UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12)
            ]
            let pttKeyCode = pttKeyCodes[pttPopup.indexOfSelectedItem]

            let config = Config(
                provider: selectedProvider.id,
                apiKey: apiKey,
                providerApiKeys: [:],
                shortcutModifiers: modifiers,
                shortcutKeyCode: UInt32(kVK_Space),
                pushToTalkKeyCode: pttKeyCode,
                pushToTalkModifiers: 0,
                whisperCliPath: "",
                whisperModelPath: "",
                whisperLanguage: "fr",
                customVocabulary: [],
                customModes: [],
                disabledBuiltInModeIds: [],
                projectTaggingEnabled: true,
                lastUsedProjectID: "",
                appModeOverrides: [:],
                autoSelectModeEnabled: true,
                autoModeFallbackToLastUsed: false,
                processingModel: "gpt-5.4-nano",
                postActions: PostAction.defaultActions(),
                activePostActionId: "builtin-paste",
                skippedUpdateVersion: "",
                lastUpdateCheck: 0
            )
            config.save()

            // Setup auto-start if checked
            if autoStartCheck.state == .on {
                setupAutoStart()
            }

            return config
        }

        return nil
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let provider = sender.selectedItem?.representedObject as? ProviderInfo else { return }
        selectedProviderInfo = provider

        // Update link button
        if let linkButton = objc_getAssociatedObject(sender, "linkButton") as? NSButton {
            updateLinkButton(linkButton, for: provider)
        }

        // Update placeholder
        if let apiKeyField = objc_getAssociatedObject(sender, "apiKeyField") as? NSTextField {
            apiKeyField.placeholderString = provider.id == "openai" ? "sk-..." : "Enter API key"
        }
    }

    private func updateLinkButton(_ button: NSButton, for provider: ProviderInfo) {
        let host = provider.apiKeyHelpUrl.host ?? "provider website"
        button.title = "Get your API key from \(host)"
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        )
    }

    @objc private func openAPIKeyPage() {
        if let url = selectedProviderInfo?.apiKeyHelpUrl {
            NSWorkspace.shared.open(url)
        }
    }

    static let launchAgentPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.whisper-voice.plist")

    func setupAutoStart() {
        let appPath = "/Applications/Whisper Voice.app"

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.whisper-voice</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        try? plistContent.write(to: AppDelegate.launchAgentPath, atomically: true, encoding: .utf8)
        LogManager.shared.log("Launch at login enabled")
    }

    func removeAutoStart() {
        try? FileManager.default.removeItem(at: AppDelegate.launchAgentPath)
        LogManager.shared.log("Launch at login disabled")
    }

    private var isAutoStartEnabled: Bool {
        FileManager.default.fileExists(atPath: AppDelegate.launchAgentPath.path)
    }

    private func updateStatusIcon() {
        if let button = statusItem.button {
            switch state {
            case .idle:
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
                button.contentTintColor = nil
            case .recording:
                button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
                button.contentTintColor = .systemRed
            case .transcribing:
                button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Transcribing")
                button.contentTintColor = .systemOrange
            }
        }
    }

    private func updateStatus(_ text: String) {
        if let menu = statusItem.menu,
           let item = menu.item(withTag: 100) {
            item.title = "Status: \(text)"
        }
    }

    // MARK: - Toggle Mode (press to start, press again to stop)

    private func setupToggleHotkey() {
        guard config != nil else { return }

        // Global monitor for key down
        toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesToggleShortcut(event) == true {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
            }
        }

        // Local monitor for key down
        toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesToggleShortcut(event) == true {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
                return nil
            }
            return event
        }
    }

    private func matchesToggleShortcut(_ event: NSEvent) -> Bool {
        guard let config = config else { return false }

        let keyMatches = event.keyCode == UInt16(config.shortcutKeyCode)

        // Check modifiers
        let modifiers = config.shortcutModifiers
        var modifiersMatch = true

        if modifiers & UInt32(optionKey) != 0 {
            modifiersMatch = modifiersMatch && event.modifierFlags.contains(.option)
        }
        if modifiers & UInt32(controlKey) != 0 {
            modifiersMatch = modifiersMatch && event.modifierFlags.contains(.control)
        }
        if modifiers & UInt32(cmdKey) != 0 {
            modifiersMatch = modifiersMatch && event.modifierFlags.contains(.command)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            modifiersMatch = modifiersMatch && event.modifierFlags.contains(.shift)
        }

        return keyMatches && modifiersMatch
    }

    private func toggleRecording() {
        switch state {
        case .idle:
            isPushToTalkActive = false
            startRecording(showStopMessage: true)
        case .recording:
            // Only stop if not in PTT mode (PTT uses key release to stop)
            if !isPushToTalkActive {
                stopRecording()
            }
        case .transcribing:
            break
        }
    }

    // MARK: - Push-to-Talk Mode (hold to record, release to stop)

    private func setupPushToTalkHotkey() {
        guard let config = config else { return }
        let pttKeyCode = UInt16(config.pushToTalkKeyCode)
        let pttMods = config.pushToTalkModifiers
        // On keyDown we also require the configured modifiers (if any) so a
        // bare letter doesn't fire PTT unintentionally. On keyUp we match on
        // the key only — user may release the modifier before the key.
        let matchesDown: (NSEvent) -> Bool = { event in
            guard event.keyCode == pttKeyCode else { return false }
            if pttMods == 0 { return true }
            let eventMods = carbonModifiers(from: event.modifierFlags.rawValue)
            return (eventMods & pttMods) == pttMods
        }

        // Global monitor for key down (start recording)
        pttGlobalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if matchesDown(event) && !event.isARepeat {
                DispatchQueue.main.async {
                    self?.startPushToTalk()
                }
            }
        }

        // Global monitor for key up (stop recording)
        pttGlobalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == pttKeyCode {
                DispatchQueue.main.async {
                    self?.stopPushToTalk()
                }
            }
        }

        // Local monitors
        pttLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if event.keyCode == pttKeyCode {
                DispatchQueue.main.async {
                    if event.type == .keyDown && !event.isARepeat && matchesDown(event) {
                        self?.startPushToTalk()
                    } else if event.type == .keyUp {
                        self?.stopPushToTalk()
                    }
                }
                return nil
            }
            return event
        }
    }

    private func startPushToTalk() {
        guard state == .idle else { return }
        isPushToTalkActive = true
        startRecording(showStopMessage: false)
    }

    private func stopPushToTalk() {
        guard state == .recording && isPushToTalkActive else { return }
        isPushToTalkActive = false
        stopRecording()
    }

    // MARK: - Recording

    private var transcriptionTimeoutTimer: Timer?

    private func setupRecordingWindow() {
        recordingWindow = RecordingWindow()
        recordingWindow?.audioLevelProvider = { [weak self] in
            return self?.audioRecorder.currentLevel ?? 0
        }
        recordingWindow?.onStop = { [weak self] in
            self?.stopRecording()
        }
        recordingWindow?.onCancel = { [weak self] in
            self?.cancelRecording()
        }
        recordingWindow?.onModeChanged = { [weak self] mode in
            self?.selectedModeForCurrentRecording = mode
            self?.pendingAutoModeReason = nil
            self?.recordingWindow?.setAutoModeReason(nil)
            LogManager.shared.log("Mode switched to: \(mode.name)")
        }
        recordingWindow?.onProjectChanged = { [weak self] project, source in
            self?.pendingProject = project
            self?.pendingProjectSource = source
        }
    }

    /// Capture currently selected text in the active app by simulating Cmd+C
    private func captureSelectedText() -> String? {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // Clear clipboard
        pasteboard.clearContents()

        // Simulate Cmd+C to copy selection
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update
        Thread.sleep(forTimeInterval: 0.15)

        // Read the new clipboard content
        let capturedText = pasteboard.string(forType: .string)

        // Restore original clipboard
        pasteboard.clearContents()
        if !savedItems.isEmpty {
            for (typeRaw, data) in savedItems {
                let type = NSPasteboard.PasteboardType(rawValue: typeRaw)
                pasteboard.setData(data, forType: type)
            }
        }

        if let text = capturedText, !text.isEmpty {
            LogManager.shared.log("[SuperMode] Captured context: \(text.prefix(100))...")
            return text
        }

        LogManager.shared.log("[SuperMode] No text selection captured")
        return nil
    }

    /// Look up bundleID in Config.appModeOverrides and switch to the mapped mode.
    /// Stashes a human-readable reason in pendingAutoModeReason for the panel label.
    private func applyAutoSelectMode(for ctx: DictationContext?) {
        guard let config = Config.load(), config.autoSelectModeEnabled else { return }

        let bundleID = ctx?.app?.bundleID
        let mappedId = bundleID.flatMap { config.appModeOverrides[$0] }
        let mappedMode = mappedId.flatMap { id in
            ModeManager.shared.modes.first(where: { $0.id == id && ModeManager.shared.isModeAvailable($0) })
        }

        if let mode = mappedMode, let bundleID = bundleID {
            // Explicit mapping wins.
            ModeManager.shared.setMode(id: mode.id)
            selectedModeForCurrentRecording = mode
            recordingWindow?.updateModeSelection()
            let appName = ctx?.app?.name ?? bundleID
            pendingAutoModeReason = "auto: \(mode.name) (\(appName))"
            recordingWindow?.setAutoModeReason(pendingAutoModeReason)
            LogManager.shared.log("[AutoMode] bundleID=\(bundleID) → \(mode.name) (locked as recording mode)")
            return
        }

        // No mapping matches. Per the `autoModeFallbackToLastUsed` toggle, either
        // leave the current (last-used) mode alone, or reset to Brut so the
        // previous app's mode (e.g. Slack) doesn't leak into unrelated dictations.
        if config.autoModeFallbackToLastUsed {
            return  // keep current mode, historical behavior
        }

        let brutId = "voice-to-text"
        guard let brut = ModeManager.shared.modes.first(where: { $0.id == brutId }) else { return }
        // Only act if we're NOT already on Brut — avoid unnecessary churn + logs.
        if ModeManager.shared.currentMode.id != brutId {
            ModeManager.shared.setMode(id: brutId)
            selectedModeForCurrentRecording = brut
            recordingWindow?.updateModeSelection()
            LogManager.shared.log("[AutoMode] no mapping for bundleID=\(bundleID ?? "?") → reset to Brut")
        } else {
            // Still make sure the recording-locked mode is Brut (may have been
            // overridden by a previous Shift-cycle that left selectedMode stale).
            selectedModeForCurrentRecording = brut
        }
    }

    private func startRecording(showStopMessage: Bool) {
        LogManager.shared.log("Starting recording (showStopMessage: \(showStopMessage))")

        // Capture dictation context (app, window, URL or terminal cwd/git) before audio starts.
        // Runs off-main; completion arrives asynchronously and attaches to pending entry.
        pendingDictationContext = nil
        pendingAutoModeReason = nil
        ContextCapturer.shared.captureNow { [weak self] ctx in
            guard let self = self else { return }
            self.pendingDictationContext = ctx
            // Auto-select mode based on bundleID → modeId mapping.
            self.applyAutoSelectMode(for: ctx)
            // Predict project from the captured context + history.
            let prediction = ProjectPredictor.predict(ctx: ctx)
            self.pendingProject = prediction.project
            self.pendingProjectSource = prediction.source
            self.pendingProjectReason = prediction.reason
            self.pendingProjectConfidence = prediction.confidence
            // Reflect the prediction in the recording panel if it's up.
            self.recordingWindow?.setProject(prediction.project,
                                             reason: prediction.reason,
                                             confidence: prediction.confidence)
        }

        // Capture context for Super Mode before starting recording
        capturedContext = nil
        if ModeManager.shared.currentMode.id == "super" {
            capturedContext = captureSelectedText()
        }

        guard audioRecorder.startRecording() else {
            LogManager.shared.log("Failed to start recording", level: "ERROR")
            showNotification(title: "Error", message: "Failed to start recording")
            return
        }

        state = .recording
        recordingStartTime = Date()  // Track recording duration
        updateStatusIcon()
        updateStatus("Recording...")

        // Show recording window with waveform
        if recordingWindow == nil {
            setupRecordingWindow()
        }
        recordingWindow?.show()

        // Setup cancel hotkey (Escape), mode switch (Shift), and Enter action toggle
        setupCancelHotkey()
        setupModeSwitchMonitor()
        setupEnterToggleMonitor()
        startLiveTranscript()
    }

    private func stopRecording() {
        LogManager.shared.log("Stopping recording")

        // Remove hotkeys
        removeCancelHotkey()
        removeModeSwitchMonitor()
        removeEnterToggleMonitor()
        stopLiveTranscript()

        guard let audioURL = audioRecorder.stopRecording() else {
            LogManager.shared.log("No audio URL returned from stopRecording", level: "WARNING")
            recordingWindow?.hide()
            state = .idle
            updateStatusIcon()
            updateStatus("Idle")
            return
        }

        state = .transcribing
        updateStatusIcon()
        updateStatus("Transcribing...")

        // Hide recording window immediately when stopping
        // (user feedback: don't show processing state, looks like still listening)
        recordingWindow?.hide()

        // Safety timeout: reset state after 45 seconds if still transcribing
        transcriptionTimeoutTimer?.invalidate()
        transcriptionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                if self?.state == .transcribing {
                    LogManager.shared.log("Transcription timeout - resetting state", level: "ERROR")
                    self?.audioRecorder.cleanup()
                    self?.showNotification(title: "Error", message: "Transcription timeout")
                    self?.state = .idle
                    self?.updateStatusIcon()
                    self?.updateStatus("Idle")
                }
            }
        }

        // Build prompt from custom vocabulary
        let vocabPrompt: String? = {
            guard let vocab = self.config?.customVocabulary, !vocab.isEmpty else { return nil }
            let prompt = vocab.joined(separator: ", ")
            LogManager.shared.log("Using custom vocabulary prompt: \(prompt)")
            return prompt
        }()

        transcriptionProvider?.transcribe(audioURL: audioURL, prompt: vocabPrompt) { [weak self] result in
            DispatchQueue.main.async {
                // Cancel safety timeout
                self?.transcriptionTimeoutTimer?.invalidate()
                self?.transcriptionTimeoutTimer = nil

                self?.audioRecorder.cleanup()

                switch result {
                case .success(let text):
                    LogManager.shared.log("Transcription complete: \(text.prefix(50))...")

                    // Get the mode that was selected during recording
                    let mode = self?.selectedModeForCurrentRecording ?? ModeManager.shared.currentMode

                    // Check if we need AI processing
                    if mode.requiresProcessing {
                        LogManager.shared.log("Processing with mode: \(mode.name)")

                        // Get API key for OpenAI (for text processing)
                        guard let apiKey = ModeManager.shared.openAIKey else {
                            LogManager.shared.log("No OpenAI API key for processing, using raw text", level: "WARNING")
                            self?.finishWithText(text, rawText: text)
                            return
                        }

                        // Process with GPT
                        TextProcessor.shared.process(
                            text: text,
                            mode: mode,
                            context: self?.capturedContext,
                            dictationContext: self?.pendingDictationContext,
                            vocabulary: self?.config?.customVocabulary,
                            apiKey: apiKey
                        ) { processResult in
                            DispatchQueue.main.async {
                                switch processResult {
                                case .success(let processedText):
                                    LogManager.shared.log("Processing complete: \(processedText.prefix(50))...")
                                    self?.finishWithText(processedText, rawText: text)
                                case .failure(let error):
                                    LogManager.shared.log("Processing failed: \(error.localizedDescription), using raw text", level: "WARNING")
                                    self?.finishWithText(text, rawText: text)
                                }
                            }
                        }
                    } else {
                        // No processing needed, use raw transcription
                        self?.finishWithText(text, rawText: text)
                    }

                case .failure(let error):
                    LogManager.shared.log("Transcription failed: \(error.localizedDescription)", level: "ERROR")
                    self?.showNotification(title: "Error", message: error.localizedDescription)
                    self?.state = .idle
                    self?.updateStatusIcon()
                    self?.updateStatus("Idle")
                }
            }
        }
    }

    private func finishWithText(_ text: String, rawText: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Save to history
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let provider = config?.provider ?? "unknown"
        let modeName = selectedModeForCurrentRecording?.name ?? "Voice-to-Text"
        let ctx = pendingDictationContext
        pendingDictationContext = nil
        let project = pendingProject
        let projectSource = pendingProjectSource
        let projectReason = pendingProjectReason
        let projectConfidence = pendingProjectConfidence
        pendingProject = nil
        pendingProjectSource = "none"
        pendingProjectReason = ""
        pendingProjectConfidence = 0

        var extras = ctx?.extras ?? [:]
        if let project = project {
            extras["projectID"] = project.id.uuidString
            extras["projectName"] = project.name
            extras["projectSource"] = projectSource
            if !projectReason.isEmpty { extras["projectReason"] = projectReason }
            if projectConfidence > 0 {
                extras["projectConfidence"] = String(format: "%.2f", projectConfidence)
            }
        }
        let entry = TranscriptionEntry(
            text: trimmedText,
            durationSeconds: duration,
            provider: "\(provider) + \(modeName)",
            app: ctx?.app,
            signals: ctx?.signals,
            extras: extras.isEmpty ? nil : extras
        )
        HistoryManager.shared.addEntry(entry)

        if let project = project, var cfg = Config.load(), cfg.lastUsedProjectID != project.id.uuidString {
            cfg.lastUsedProjectID = project.id.uuidString
            cfg.save()
        }

        NSSound(named: "Glass")?.play()

        let activeId = postActionOverrideId ?? config?.activePostActionId ?? "builtin-paste"
        let action = PostAction.resolved(
            from: config?.postActions ?? PostAction.defaultActions(),
            activeId: activeId
        )
        postActionOverrideId = nil
        executePostAction(action: action, text: trimmedText, rawText: trimmedRaw, context: ctx)

        state = .idle
        updateStatusIcon()
        updateStatus("Idle")
    }

    private func cancelRecording() {
        LogManager.shared.log("Recording cancelled by user")

        // Remove hotkeys
        removeCancelHotkey()
        removeModeSwitchMonitor()
        removeEnterToggleMonitor()
        stopLiveTranscript()

        // Stop and discard recording
        _ = audioRecorder.stopRecording()
        audioRecorder.cleanup()

        // Hide window
        recordingWindow?.hide()

        // Reset state
        state = .idle
        isPushToTalkActive = false
        updateStatusIcon()
        updateStatus("Idle")

        // Play cancel sound
        NSSound(named: "Basso")?.play()
    }

    // MARK: - Live Transcript (OpenAI Realtime API)

    private func startLiveTranscript() {
        guard let apiKey = ModeManager.shared.openAIKey else { return }
        let transcriber = RealtimeTranscriber()
        transcriber.onTranscript = { [weak self] text in
            self?.recordingWindow?.updateTranscript(text)
        }
        transcriber.start(apiKey: apiKey, language: "fr", vocabulary: config?.customVocabulary)
        realtimeTranscriber = transcriber
    }

    private func stopLiveTranscript() {
        realtimeTranscriber?.stop()
        realtimeTranscriber = nil
    }

    private func setupCancelHotkey() {
        // Global monitor for Escape key
        cancelGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async {
                    if self?.state == .recording {
                        self?.cancelRecording()
                    }
                }
            }
        }

        // Local monitor for Escape key
        cancelLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async {
                    if self?.state == .recording {
                        self?.cancelRecording()
                    }
                }
                return nil
            }
            return event
        }
    }

    private func removeCancelHotkey() {
        if let m = cancelGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = cancelLocalMonitor { NSEvent.removeMonitor(m) }
        cancelGlobalMonitor = nil
        cancelLocalMonitor = nil
    }

    private func setupModeSwitchMonitor() {
        // Store the current mode at start of recording
        selectedModeForCurrentRecording = ModeManager.shared.currentMode

        // Global monitor for Shift key to cycle modes
        modeSwitchGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Detect Shift key press (not release)
            if event.modifierFlags.contains(.shift) && !(event.modifierFlags.rawValue & UInt(NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK) == 0) {
                DispatchQueue.main.async {
                    if self?.state == .recording {
                        self?.recordingWindow?.cycleMode()
                        self?.selectedModeForCurrentRecording = ModeManager.shared.currentMode
                        self?.pendingAutoModeReason = nil
                        self?.recordingWindow?.setAutoModeReason(nil)
                        LogManager.shared.log("Mode switched to: \(ModeManager.shared.currentMode.name)")
                    }
                }
            }
        }

        // Local monitor for Shift key
        modeSwitchLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            if event.modifierFlags.contains(.shift) {
                DispatchQueue.main.async {
                    if self?.state == .recording {
                        self?.recordingWindow?.cycleMode()
                        self?.selectedModeForCurrentRecording = ModeManager.shared.currentMode
                        self?.pendingAutoModeReason = nil
                        self?.recordingWindow?.setAutoModeReason(nil)
                        LogManager.shared.log("Mode switched to: \(ModeManager.shared.currentMode.name)")
                    }
                }
            }
            return event
        }
    }

    private func removeModeSwitchMonitor() {
        if let m = modeSwitchGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = modeSwitchLocalMonitor { NSEvent.removeMonitor(m) }
        modeSwitchGlobalMonitor = nil
        modeSwitchLocalMonitor = nil
    }

    private func setupEnterToggleMonitor() {
        let actions = (config?.postActions ?? PostAction.defaultActions()).compactMap { PostAction.from($0) }
        guard actions.count > 1 else { return }

        let defaultId = config?.activePostActionId ?? "builtin-paste"
        postActionOverrideId = nil

        enterToggleHandler = { [weak self] in
            guard let self = self, self.state == .recording else { return }
            let currentId = self.postActionOverrideId ?? defaultId
            let currentIndex = actions.firstIndex(where: { $0.id == currentId }) ?? 0
            let nextIndex = (currentIndex + 1) % actions.count
            let next = actions[nextIndex]
            self.postActionOverrideId = next.id
            self.recordingWindow?.setAutoModeReason("⏎ \(next.label)")
            LogManager.shared.log("Enter toggle: switched to \(next.label)")
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: enterKeyTapCallback,
            userInfo: nil
        ) else {
            LogManager.shared.log("Failed to create Enter key event tap — check accessibility permissions", level: "WARNING")
            return
        }

        enterEventTap = tap
        enterEventTapGlobal = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        enterRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEnterToggleMonitor() {
        if let tap = enterEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = enterRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        enterEventTap = nil
        enterEventTapGlobal = nil
        enterRunLoopSource = nil
        enterToggleHandler = nil
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc private func showPermissionStatus() {
        let missingPermissions = PermissionChecker.missingPermissions()

        if missingPermissions.isEmpty {
            let alert = NSAlert()
            alert.messageText = "All Permissions Granted"
            alert.informativeText = "Whisper Voice has all the permissions it needs:\n\n" +
                "✓ Microphone Access\n" +
                "✓ Accessibility\n" +
                "✓ Input Monitoring"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            // Build status message
            var statusLines: [String] = []
            for permission in PermissionType.allCases {
                let isGranted = PermissionChecker.checkPermission(permission)
                let symbol = isGranted ? "✓" : "✗"
                statusLines.append("\(symbol) \(permission.title)")
            }

            let alert = NSAlert()
            alert.messageText = "Permission Status"
            alert.informativeText = statusLines.joined(separator: "\n") +
                "\n\nWould you like to configure the missing permissions?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Configure Permissions")
            alert.addButton(withTitle: "Later")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                showPermissionWizard(permissions: missingPermissions)
            }
        }
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            historyWindow = HistoryWindow()
        }
        historyWindow?.show()
    }

    @objc private func showPreferences() {
        if swiftUIPreferencesWindow == nil {
            swiftUIPreferencesWindow = SwiftUIPreferencesWindow()
            swiftUIPreferencesWindow?.onSettingsChanged = { [weak self] in
                self?.reloadSettings()
            }
        }
        swiftUIPreferencesWindow?.show()
    }

    private func reloadSettings() {
        // Reload config
        guard let newConfig = Config.load() else {
            LogManager.shared.log("Failed to reload config", level: "ERROR")
            return
        }

        let providerChanged = config?.provider != newConfig.provider ||
                              config?.getCurrentApiKey() != newConfig.getCurrentApiKey()
        let shortcutsChanged = config?.shortcutModifiers != newConfig.shortcutModifiers ||
                               config?.shortcutKeyCode != newConfig.shortcutKeyCode ||
                               config?.pushToTalkKeyCode != newConfig.pushToTalkKeyCode

        self.config = newConfig

        if providerChanged {
            reloadProvider()
        }

        if shortcutsChanged {
            reloadHotkeys()
        }

        // Recreate recording window to pick up new modes
        recordingWindow = nil

        updateMenuDescriptions()
        rebuildActionSubmenu()
        LogManager.shared.log("Settings reloaded successfully")
    }

    private func rebuildActionSubmenu() {
        guard let menu = statusItem.menu,
              let actionItem = menu.items.first(where: { $0.tag == 200 }) else { return }
        let submenu = NSMenu(title: "Action")
        let actions = (config?.postActions ?? PostAction.defaultActions()).compactMap { PostAction.from($0) }
        let activeId = config?.activePostActionId ?? "builtin-paste"
        for action in actions {
            let item = NSMenuItem(title: action.label, action: #selector(selectPostAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.id
            item.state = action.id == activeId ? .on : .off
            submenu.addItem(item)
        }
        actionItem.submenu = submenu
    }

    private func reloadProvider() {
        guard let config = config else { return }
        transcriptionProvider = TranscriptionProviderFactory.create(from: config)
        LogManager.shared.log("Provider reloaded: \(transcriptionProvider?.displayName ?? "unknown")")
    }

    private func reloadHotkeys() {
        // Remove existing monitors
        if let m = toggleGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = toggleLocalMonitor { NSEvent.removeMonitor(m) }
        if let m = pttGlobalKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = pttGlobalKeyUpMonitor { NSEvent.removeMonitor(m) }
        if let m = pttLocalMonitor { NSEvent.removeMonitor(m) }

        toggleGlobalMonitor = nil
        toggleLocalMonitor = nil
        pttGlobalKeyDownMonitor = nil
        pttGlobalKeyUpMonitor = nil
        pttLocalMonitor = nil

        // Re-setup hotkeys
        setupToggleHotkey()
        setupPushToTalkHotkey()

        LogManager.shared.log("Hotkeys reloaded: Toggle=\(config?.toggleShortcutDescription() ?? "?"), PTT=\(config?.pushToTalkDescription() ?? "?")")
    }

    private func updateMenuDescriptions() {
        guard let config = config else { return }
        toggleShortcutMenuItem?.title = "\(config.toggleShortcutDescription()) to toggle"
        pttMenuItem?.title = "\(config.pushToTalkDescription()) to record"
    }

    @objc private func checkForUpdates() {
        LogManager.shared.log("[Update] Checking for updates...")
        UpdateChecker.checkForUpdates { [weak self] updateInfo in
            if let info = updateInfo {
                LogManager.shared.log("[Update] New version available: \(info.version)")
                self?.updateWindow = UpdateWindow(updateInfo: info)
                self?.updateWindow?.show()
            } else {
                LogManager.shared.log("[Update] Already up to date")
                self?.showNotification(title: "Whisper Voice", message: "You're running the latest version (\(UpdateChecker.currentVersion))")
            }
        }
    }

    private func checkForUpdatesSilently() {
        // Skip if checked less than 24h ago
        if let config = Config.load() {
            let lastCheck = config.lastUpdateCheck
            let now = Date().timeIntervalSince1970
            if lastCheck > 0 && (now - lastCheck) < 86400 {
                LogManager.shared.log("[Update] Skipping check (last check < 24h ago)")
                return
            }
        }

        UpdateChecker.checkForUpdates { [weak self] updateInfo in
            // Save last check time
            self?.saveUpdateCheckTime()

            if let info = updateInfo {
                // Skip if user already dismissed this version
                if let config = Config.load(), config.skippedUpdateVersion == info.version {
                    LogManager.shared.log("[Update] Skipping v\(info.version) (dismissed by user)")
                    return
                }
                LogManager.shared.log("[Update] New version available: \(info.version)")
                self?.updateWindow = UpdateWindow(updateInfo: info)
                self?.updateWindow?.show()
            }
        }
    }

    private func saveUpdateCheckTime() {
        guard var config = Config.load() else { return }
        config.lastUpdateCheck = Date().timeIntervalSince1970
        config.save()
    }

    @objc private func selectPostAction(_ sender: NSMenuItem) {
        guard let actionId = sender.representedObject as? String else { return }
        config?.activePostActionId = actionId
        config?.save()
        refreshActionMenu()
        LogManager.shared.log("Active post-action changed to: \(actionId)")
    }

    private func refreshActionMenu() {
        guard let menu = statusItem.menu,
              let actionItem = menu.items.first(where: { $0.tag == 200 }),
              let submenu = actionItem.submenu else { return }
        let activeId = config?.activePostActionId ?? "builtin-paste"
        for item in submenu.items {
            item.state = (item.representedObject as? String) == activeId ? .on : .off
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openHelpURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
