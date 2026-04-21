import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.whispervoice", category: "main")

// MARK: - Log Manager

class LogManager {
    static let shared = LogManager()

    private let logFileURL: URL
    private var logEntries: [String] = []
    private let maxLogEntries = 1000
    private let queue = DispatchQueue(label: "com.whispervoice.logmanager")

    private init() {
        // Create Application Support directory if needed
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        logFileURL = appSupport.appendingPathComponent("logs.txt")

        // Load existing logs
        loadLogs()
    }

    private func loadLogs() {
        queue.sync {
            if let contents = try? String(contentsOf: logFileURL, encoding: .utf8) {
                logEntries = contents.components(separatedBy: "\n").filter { !$0.isEmpty }
                // Keep only recent entries
                if logEntries.count > maxLogEntries {
                    logEntries = Array(logEntries.suffix(maxLogEntries))
                }
            }
        }
    }

    func log(_ message: String, level: String = "INFO") {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        let entry = "\(timestamp) [\(level)] \(message)"

        queue.async { [weak self] in
            guard let self = self else { return }

            self.logEntries.append(entry)

            // Trim if too many entries
            if self.logEntries.count > self.maxLogEntries {
                self.logEntries = Array(self.logEntries.suffix(self.maxLogEntries))
            }

            // Write to file
            let content = self.logEntries.joined(separator: "\n")
            try? content.write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }

        // Also log to os.log
        switch level {
        case "ERROR":
            logger.error("\(message)")
        case "WARNING":
            logger.warning("\(message)")
        default:
            logger.info("\(message)")
        }
    }

    func getRecentLogs(count: Int = 100) -> [String] {
        return queue.sync {
            return Array(logEntries.suffix(count))
        }
    }

    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.logEntries.removeAll()
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Permission Types

enum PermissionType: Int, CaseIterable {
    case microphone = 0
    case accessibility = 1
    case inputMonitoring = 2

    var title: String {
        switch self {
        case .microphone: return "Microphone Access"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var explanation: String {
        switch self {
        case .microphone:
            return "Whisper Voice needs microphone access to record your voice for transcription."
        case .accessibility:
            return "Whisper Voice needs Accessibility access to paste transcribed text using Cmd+V."
        case .inputMonitoring:
            return "Whisper Voice needs Input Monitoring access to detect global keyboard shortcuts."
        }
    }

    var systemPreferencesURL: URL {
        let baseURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
        switch self {
        case .microphone:
            return URL(string: baseURL + "Microphone")!
        case .accessibility:
            return URL(string: baseURL + "Accessibility")!
        case .inputMonitoring:
            return URL(string: baseURL + "ListenEvent")!
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "hand.raised.fill"
        case .inputMonitoring: return "keyboard"
        }
    }
}

// MARK: - Permission Checker

class PermissionChecker {

    static func checkMicrophonePermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
    }

    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    static func checkInputMonitoringPermission() -> Bool {
        // Input Monitoring can be tested by attempting to add a global event monitor
        // If the permission is not granted, the monitor will fail silently
        // We use a heuristic: if accessibility is granted, input monitoring usually works
        // But the definitive test is trying to create a monitor

        // Note: There's no direct API to check Input Monitoring permission
        // The best we can do is check if we can successfully monitor events
        // For now, we assume if Accessibility is granted, we should prompt for Input Monitoring too
        // macOS will show its own dialog when we try to use it

        // Try to create a test monitor
        var hasPermission = false
        let testMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }
        if testMonitor != nil {
            hasPermission = true
            NSEvent.removeMonitor(testMonitor!)
        }
        return hasPermission
    }

    static func checkPermission(_ type: PermissionType) -> Bool {
        switch type {
        case .microphone:
            return checkMicrophonePermission()
        case .accessibility:
            return checkAccessibilityPermission()
        case .inputMonitoring:
            return checkInputMonitoringPermission()
        }
    }

    static func allPermissionsGranted() -> Bool {
        return PermissionType.allCases.allSatisfy { checkPermission($0) }
    }

    static func missingPermissions() -> [PermissionType] {
        return PermissionType.allCases.filter { !checkPermission($0) }
    }

    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    static func promptAccessibilityPermission() {
        // This will show the system dialog asking user to grant accessibility access
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

// MARK: - Permission Wizard

class PermissionWizard: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var currentStep: Int = 0
    private var permissionsToRequest: [PermissionType] = []
    private var pollingTimer: Timer?
    private var onComplete: (() -> Void)?

    // UI Elements
    private var progressDots: [NSView] = []
    private var iconImageView: NSImageView!
    private var stepLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var explanationLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var openPrefsButton: NSButton!
    private var skipButton: NSButton!
    private var nextButton: NSButton!

    init(permissionsToRequest: [PermissionType], onComplete: @escaping () -> Void) {
        super.init()
        self.permissionsToRequest = permissionsToRequest
        self.onComplete = onComplete
        setupWindow()
    }

    private func setupWindow() {
        // Create window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Voice Setup"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        // Progress dots container
        let dotsContainer = NSView(frame: NSRect(x: 0, y: 300, width: 480, height: 30))
        contentView.addSubview(dotsContainer)

        let totalDots = permissionsToRequest.count
        let dotSize: CGFloat = 12
        let dotSpacing: CGFloat = 20
        let totalWidth = CGFloat(totalDots) * dotSize + CGFloat(totalDots - 1) * dotSpacing
        var dotX = (480 - totalWidth) / 2

        for i in 0..<totalDots {
            let dot = NSView(frame: NSRect(x: dotX, y: 9, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = dotSize / 2
            dot.layer?.backgroundColor = (i == 0 ? NSColor.systemBlue : NSColor.systemGray).cgColor
            dotsContainer.addSubview(dot)
            progressDots.append(dot)
            dotX += dotSize + dotSpacing
        }

        // Icon
        iconImageView = NSImageView(frame: NSRect(x: 200, y: 220, width: 80, height: 80))
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconImageView)

        // Step label
        stepLabel = NSTextField(labelWithString: "")
        stepLabel.frame = NSRect(x: 0, y: 190, width: 480, height: 20)
        stepLabel.alignment = .center
        stepLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stepLabel.textColor = .secondaryLabelColor
        contentView.addSubview(stepLabel)

        // Title label
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.frame = NSRect(x: 40, y: 160, width: 400, height: 24)
        titleLabel.alignment = .center
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        contentView.addSubview(titleLabel)

        // Explanation label
        explanationLabel = NSTextField(wrappingLabelWithString: "")
        explanationLabel.frame = NSRect(x: 40, y: 110, width: 400, height: 40)
        explanationLabel.alignment = .center
        explanationLabel.font = NSFont.systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabelColor
        contentView.addSubview(explanationLabel)

        // Open System Preferences button
        openPrefsButton = NSButton(title: "Open System Preferences", target: self, action: #selector(openSystemPreferences))
        openPrefsButton.bezelStyle = .rounded
        openPrefsButton.frame = NSRect(x: 140, y: 70, width: 200, height: 32)
        contentView.addSubview(openPrefsButton)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 40, y: 40, width: 400, height: 20)
        statusLabel.alignment = .center
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        contentView.addSubview(statusLabel)

        // Skip All button
        skipButton = NSButton(title: "Skip All", target: self, action: #selector(skipAllClicked))
        skipButton.bezelStyle = .rounded
        skipButton.frame = NSRect(x: 20, y: 10, width: 100, height: 32)
        contentView.addSubview(skipButton)

        // Next/Finish button
        nextButton = NSButton(title: "Next", target: self, action: #selector(nextClicked))
        nextButton.bezelStyle = .rounded
        nextButton.frame = NSRect(x: 360, y: 10, width: 100, height: 32)
        nextButton.keyEquivalent = "\r"
        contentView.addSubview(nextButton)

        updateUI()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()

        // For microphone, request permission immediately
        if let currentPermission = currentPermission, currentPermission == .microphone {
            PermissionChecker.requestMicrophonePermission { [weak self] granted in
                if granted {
                    self?.updateUI()
                }
            }
        }
    }

    private var currentPermission: PermissionType? {
        guard currentStep < permissionsToRequest.count else { return nil }
        return permissionsToRequest[currentStep]
    }

    private func updateUI() {
        guard let permission = currentPermission else {
            finishWizard()
            return
        }

        // Update progress dots
        for (i, dot) in progressDots.enumerated() {
            if i < currentStep {
                dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            } else if i == currentStep {
                dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            } else {
                dot.layer?.backgroundColor = NSColor.systemGray.cgColor
            }
        }

        // Update icon
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        iconImageView.image = NSImage(systemSymbolName: permission.iconName, accessibilityDescription: permission.title)?
            .withSymbolConfiguration(config)
        iconImageView.contentTintColor = .systemBlue

        // Update labels
        stepLabel.stringValue = "Step \(currentStep + 1) of \(permissionsToRequest.count)"
        titleLabel.stringValue = permission.title
        explanationLabel.stringValue = permission.explanation

        // Update status
        let isGranted = PermissionChecker.checkPermission(permission)
        if isGranted {
            statusLabel.stringValue = "✓ Permission Granted"
            statusLabel.textColor = .systemGreen
            nextButton.title = (currentStep == permissionsToRequest.count - 1) ? "Finish" : "Next"
            nextButton.isEnabled = true
        } else {
            statusLabel.stringValue = "⚠ Permission Required"
            statusLabel.textColor = .systemOrange
            nextButton.title = (currentStep == permissionsToRequest.count - 1) ? "Finish" : "Next"
            // Allow next even if permission not granted (they can skip)
            nextButton.isEnabled = true
        }
    }

    private func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkCurrentPermission()
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func checkCurrentPermission() {
        guard let permission = currentPermission else { return }

        let isGranted = PermissionChecker.checkPermission(permission)

        // Update status label
        if isGranted {
            statusLabel.stringValue = "✓ Permission Granted"
            statusLabel.textColor = .systemGreen

            // Auto-advance after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                // Verify still granted and still on same step
                if PermissionChecker.checkPermission(permission) {
                    self.advanceToNextStep()
                }
            }
        } else {
            statusLabel.stringValue = "⚠ Permission Required"
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func openSystemPreferences() {
        guard let permission = currentPermission else { return }
        NSWorkspace.shared.open(permission.systemPreferencesURL)

        // For accessibility, also show the system prompt
        if permission == .accessibility {
            PermissionChecker.promptAccessibilityPermission()
        }
    }

    @objc private func skipAllClicked() {
        let alert = NSAlert()
        alert.messageText = "Skip Permission Setup?"
        alert.informativeText = "Whisper Voice may not function correctly without these permissions. You can configure them later in System Preferences."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Skip Anyway")
        alert.addButton(withTitle: "Continue Setup")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            stopPolling()
            window.close()
            onComplete?()
        }
    }

    @objc private func nextClicked() {
        advanceToNextStep()
    }

    private func advanceToNextStep() {
        currentStep += 1

        if currentStep >= permissionsToRequest.count {
            finishWizard()
        } else {
            updateUI()

            // For microphone, request permission immediately
            if let permission = currentPermission, permission == .microphone {
                PermissionChecker.requestMicrophonePermission { [weak self] granted in
                    if granted {
                        self?.updateUI()
                    }
                }
            }
        }
    }

    private func finishWizard() {
        stopPolling()
        window.close()

        // Check if all permissions are granted
        let missing = PermissionChecker.missingPermissions()
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some Permissions Missing"
            alert.informativeText = "The following permissions are still needed:\n\n" +
                missing.map { "• \($0.title)" }.joined(separator: "\n") +
                "\n\nYou can configure them later via the menu bar icon."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Anyway")
            alert.addButton(withTitle: "Re-check Permissions")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                // Restart wizard with missing permissions
                currentStep = 0
                permissionsToRequest = missing
                progressDots.forEach { $0.removeFromSuperview() }
                progressDots.removeAll()
                setupProgressDots()
                updateUI()
                show()
                return
            }
        }

        onComplete?()
    }

    private func setupProgressDots() {
        guard let contentView = window.contentView else { return }

        let totalDots = permissionsToRequest.count
        let dotSize: CGFloat = 12
        let dotSpacing: CGFloat = 20
        let totalWidth = CGFloat(totalDots) * dotSize + CGFloat(totalDots - 1) * dotSpacing
        var dotX = (480 - totalWidth) / 2

        for i in 0..<totalDots {
            let dot = NSView(frame: NSRect(x: dotX, y: 309, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = dotSize / 2
            dot.layer?.backgroundColor = (i == 0 ? NSColor.systemBlue : NSColor.systemGray).cgColor
            contentView.addSubview(dot)
            progressDots.append(dot)
            dotX += dotSize + dotSpacing
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Warn user if closing without completing
        let missing = PermissionChecker.missingPermissions()
        if !missing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Close Permission Setup?"
            alert.informativeText = "Some permissions are still missing. Whisper Voice may not function correctly."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close Anyway")
            alert.addButton(withTitle: "Continue Setup")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return false
            }
        }

        stopPolling()
        onComplete?()
        return true
    }
}

// MARK: - Preferences Window

class PreferencesWindow: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private var tabView: NSTabView!

    // General tab elements
    private var providerPopup: NSPopUpButton!
    private var apiKeyField: NSSecureTextField!
    private var apiKeyLinkButton: NSButton!
    private var testConnectionButton: NSButton!
    private var connectionStatusLabel: NSTextField!

    // Local provider elements (shown when local is selected)
    private var apiKeyLabel: NSTextField!
    private var localSettingsContainer: NSView!
    private var remoteSettingsContainer: NSView!
    private var modelPopup: NSPopUpButton!
    private var downloadButton: NSButton!
    private var downloadProgress: NSProgressIndicator!
    private var downloadStatusLabel: NSTextField!
    private var whisperLanguagePopup: NSPopUpButton!
    private var serverStatusLabel: NSTextField!

    // Custom vocabulary
    private var customVocabularyField: NSTextField!

    // Processing model
    private var processingModelPopup: NSPopUpButton!

    // Launch at login
    private var launchAtLoginCheckbox: NSButton!

    // Shortcuts tab elements
    private var toggleShortcutRecorder: ShortcutRecorderView!
    private var pttKeyRecorder: ShortcutRecorderView!

    // Modes tab elements
    private var modesContainer: NSView!
    private var customModesData: [[String: String]] = []
    private var customModePromptViews: [NSTextView] = []
    private var builtInModeCheckboxes: [String: NSButton] = [:]
    private var customModeNameFields: [NSTextField] = []

    // Logs tab elements
    private var logsTextView: NSTextView!
    private var autoScrollCheckbox: NSButton!
    private var logsRefreshTimer: Timer?

    // Callbacks
    var onSettingsChanged: (() -> Void)?

    // Current config snapshot
    private var currentConfig: Config?

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        // Create window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Voice Preferences"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        // Create tab view
        tabView = NSTabView(frame: NSRect(x: 10, y: 50, width: 480, height: 410))
        contentView.addSubview(tabView)

        // Add tabs
        setupGeneralTab()
        setupShortcutsTab()
        setupModesTab()
        setupProjectsTab()
        setupLogsTab()

        // Bottom buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 310, y: 10, width: 80, height: 32)
        contentView.addSubview(cancelButton)

        let saveButton = NSButton(title: "Save & Apply", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.frame = NSRect(x: 400, y: 10, width: 90, height: 32)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
    }

    private func setupGeneralTab() {
        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"

        // Compact 380px view — fits within the tab's content area without
        // bleeding into the tab bar at the top.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        // === Top: Provider selection (always visible) ===
        let providerLabel = NSTextField(labelWithString: "Transcription Provider:")
        providerLabel.frame = NSRect(x: 20, y: 340, width: 200, height: 20)
        view.addSubview(providerLabel)

        providerPopup = NSPopUpButton(frame: NSRect(x: 20, y: 310, width: 250, height: 26))
        for provider in TranscriptionProviderFactory.availableProviders {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
        view.addSubview(providerPopup)

        // === Middle: Remote & Local containers share the same rect ===
        let containerRect = NSRect(x: 0, y: 80, width: 460, height: 220)

        remoteSettingsContainer = NSView(frame: containerRect)
        view.addSubview(remoteSettingsContainer)

        // API Key
        apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 20, y: 190, width: 200, height: 20)
        remoteSettingsContainer.addSubview(apiKeyLabel)

        apiKeyField = NSSecureTextField(frame: NSRect(x: 20, y: 160, width: 420, height: 26))
        apiKeyField.placeholderString = "sk-..."
        remoteSettingsContainer.addSubview(apiKeyField)

        apiKeyLinkButton = NSButton(frame: NSRect(x: 20, y: 135, width: 420, height: 20))
        apiKeyLinkButton.bezelStyle = .inline
        apiKeyLinkButton.isBordered = false
        apiKeyLinkButton.target = self
        apiKeyLinkButton.action = #selector(openApiKeyPage)
        updateApiKeyLink(for: TranscriptionProviderFactory.availableProviders.first!)
        remoteSettingsContainer.addSubview(apiKeyLinkButton)

        // Custom Vocabulary
        let vocabLabel = NSTextField(labelWithString: "Custom Vocabulary (comma-separated):")
        vocabLabel.frame = NSRect(x: 20, y: 105, width: 300, height: 20)
        remoteSettingsContainer.addSubview(vocabLabel)

        customVocabularyField = NSTextField(frame: NSRect(x: 20, y: 75, width: 420, height: 26))
        customVocabularyField.placeholderString = "PostHog, Kubernetes, Chatwoot..."
        remoteSettingsContainer.addSubview(customVocabularyField)

        // AI Processing Model
        let llmLabel = NSTextField(labelWithString: "AI Processing Model:")
        llmLabel.frame = NSRect(x: 20, y: 40, width: 160, height: 20)
        remoteSettingsContainer.addSubview(llmLabel)

        processingModelPopup = NSPopUpButton(frame: NSRect(x: 180, y: 36, width: 260, height: 26))
        for model in TextProcessor.availableModels {
            processingModelPopup.addItem(withTitle: model.name)
            processingModelPopup.lastItem?.representedObject = model.id
        }
        remoteSettingsContainer.addSubview(processingModelPopup)

        // === Local Provider Settings (hidden by default) ===
        localSettingsContainer = NSView(frame: containerRect)
        localSettingsContainer.isHidden = true
        view.addSubview(localSettingsContainer)

        // Model selection
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 20, y: 190, width: 80, height: 20)
        localSettingsContainer.addSubview(modelLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 100, y: 187, width: 250, height: 26))
        for model in WhisperModelInfo.available {
            let status = WhisperModelManager.shared.isModelDownloaded(model.id) ? " ✓" : ""
            modelPopup.addItem(withTitle: "\(model.name) (\(model.size))\(status)")
            modelPopup.lastItem?.representedObject = model
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelSelectionChanged)
        localSettingsContainer.addSubview(modelPopup)

        // Download button
        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadModelClicked))
        downloadButton.bezelStyle = .rounded
        downloadButton.frame = NSRect(x: 360, y: 187, width: 90, height: 26)
        localSettingsContainer.addSubview(downloadButton)

        // Progress bar
        downloadProgress = NSProgressIndicator(frame: NSRect(x: 20, y: 160, width: 430, height: 20))
        downloadProgress.style = .bar
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 1
        downloadProgress.isHidden = true
        localSettingsContainer.addSubview(downloadProgress)

        // Download status
        downloadStatusLabel = NSTextField(labelWithString: "")
        downloadStatusLabel.frame = NSRect(x: 20, y: 135, width: 430, height: 20)
        downloadStatusLabel.textColor = .secondaryLabelColor
        downloadStatusLabel.font = NSFont.systemFont(ofSize: 11)
        localSettingsContainer.addSubview(downloadStatusLabel)

        // Language
        let langLabel = NSTextField(labelWithString: "Language:")
        langLabel.frame = NSRect(x: 20, y: 100, width: 80, height: 20)
        localSettingsContainer.addSubview(langLabel)

        whisperLanguagePopup = NSPopUpButton(frame: NSRect(x: 100, y: 97, width: 120, height: 26))
        whisperLanguagePopup.addItems(withTitles: ["French", "English", "Auto-detect"])
        localSettingsContainer.addSubview(whisperLanguagePopup)

        // Server status
        serverStatusLabel = NSTextField(labelWithString: "")
        serverStatusLabel.frame = NSRect(x: 230, y: 100, width: 220, height: 20)
        serverStatusLabel.textColor = .secondaryLabelColor
        serverStatusLabel.font = NSFont.systemFont(ofSize: 11)
        localSettingsContainer.addSubview(serverStatusLabel)

        // Info text
        let infoLabel = NSTextField(wrappingLabelWithString: "Local mode runs 100% offline. The model is loaded once and kept in memory for fast transcriptions.")
        infoLabel.frame = NSRect(x: 20, y: 45, width: 430, height: 35)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        localSettingsContainer.addSubview(infoLabel)

        // === Bottom: controls always visible below containers ===
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
        launchAtLoginCheckbox.frame = NSRect(x: 20, y: 55, width: 200, height: 20)
        launchAtLoginCheckbox.font = NSFont.systemFont(ofSize: 12)
        view.addSubview(launchAtLoginCheckbox)

        // Test connection button
        testConnectionButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnectionClicked))
        testConnectionButton.bezelStyle = .rounded
        testConnectionButton.frame = NSRect(x: 20, y: 10, width: 130, height: 32)
        view.addSubview(testConnectionButton)

        // Connection status label
        connectionStatusLabel = NSTextField(labelWithString: "")
        connectionStatusLabel.frame = NSRect(x: 160, y: 15, width: 280, height: 20)
        connectionStatusLabel.textColor = .secondaryLabelColor
        view.addSubview(connectionStatusLabel)

        generalTab.view = view
        tabView.addTabViewItem(generalTab)
    }

    @objc private func modelSelectionChanged() {
        updateDownloadButtonState()
    }

    private func updateDownloadButtonState() {
        guard let model = modelPopup.selectedItem?.representedObject as? WhisperModelInfo else { return }
        let isDownloaded = WhisperModelManager.shared.isModelDownloaded(model.id)
        downloadButton.title = isDownloaded ? "Downloaded" : "Download"
        downloadButton.isEnabled = !isDownloaded
    }

    @objc private func downloadModelClicked() {
        guard let model = modelPopup.selectedItem?.representedObject as? WhisperModelInfo else { return }

        downloadButton.isEnabled = false
        downloadProgress.isHidden = false
        downloadProgress.doubleValue = 0
        downloadStatusLabel.stringValue = "Starting download..."

        WhisperModelManager.shared.onProgress = { [weak self] progress, status in
            self?.downloadProgress.doubleValue = progress
            self?.downloadStatusLabel.stringValue = "Downloading: \(status)"
        }

        WhisperModelManager.shared.onComplete = { [weak self] success, error in
            self?.downloadProgress.isHidden = true

            if success {
                self?.downloadStatusLabel.stringValue = "Download complete!"
                self?.downloadStatusLabel.textColor = .systemGreen
                self?.refreshModelList()
            } else {
                self?.downloadStatusLabel.stringValue = "Download failed: \(error ?? "Unknown error")"
                self?.downloadStatusLabel.textColor = .systemRed
                self?.downloadButton.isEnabled = true
            }
        }

        WhisperModelManager.shared.downloadModel(model)
    }

    private func refreshModelList() {
        let selectedIndex = modelPopup.indexOfSelectedItem
        modelPopup.removeAllItems()

        for model in WhisperModelInfo.available {
            let status = WhisperModelManager.shared.isModelDownloaded(model.id) ? " ✓" : ""
            modelPopup.addItem(withTitle: "\(model.name) (\(model.size))\(status)")
            modelPopup.lastItem?.representedObject = model
        }

        modelPopup.selectItem(at: selectedIndex)
        updateDownloadButtonState()
    }

    private func setupShortcutsTab() {
        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = "Shortcuts"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        // Toggle shortcut label
        let toggleLabel = NSTextField(labelWithString: "Toggle Recording Shortcut:")
        toggleLabel.frame = NSRect(x: 20, y: 250, width: 200, height: 20)
        view.addSubview(toggleLabel)

        // Toggle shortcut recorder — toggle needs modifiers so it can't be
        // triggered by just typing the key.
        toggleShortcutRecorder = ShortcutRecorderView(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            allowsBareKeys: false
        )
        toggleShortcutRecorder.frame = NSRect(x: 20, y: 220, width: 240, height: 30)
        view.addSubview(toggleShortcutRecorder)

        let toggleHint = NSTextField(labelWithString: "Click and press the combination you want. Esc cancels.")
        toggleHint.textColor = .secondaryLabelColor
        toggleHint.font = NSFont.systemFont(ofSize: 11)
        toggleHint.frame = NSRect(x: 20, y: 200, width: 420, height: 16)
        view.addSubview(toggleHint)

        // PTT key label
        let pttLabel = NSTextField(labelWithString: "Push-to-Talk Key:")
        pttLabel.frame = NSRect(x: 20, y: 160, width: 200, height: 20)
        view.addSubview(pttLabel)

        // PTT recorder — bare keys allowed (F3 alone is fine).
        pttKeyRecorder = ShortcutRecorderView(
            keyCode: UInt32(kVK_F3),
            modifiers: 0,
            allowsBareKeys: true
        )
        pttKeyRecorder.frame = NSRect(x: 20, y: 130, width: 240, height: 30)
        view.addSubview(pttKeyRecorder)

        let pttHint = NSTextField(labelWithString: "Any single key or combination works.")
        pttHint.textColor = .secondaryLabelColor
        pttHint.font = NSFont.systemFont(ofSize: 11)
        pttHint.frame = NSRect(x: 20, y: 110, width: 420, height: 16)
        view.addSubview(pttHint)

        // Note
        let noteLabel = NSTextField(wrappingLabelWithString: "Note: Changes take effect after clicking Save & Apply.")
        noteLabel.frame = NSRect(x: 20, y: 60, width: 420, height: 40)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 12)
        view.addSubview(noteLabel)

        shortcutsTab.view = view
        tabView.addTabViewItem(shortcutsTab)
    }

    private func setupModesTab() {
        let modesTab = NSTabViewItem(identifier: "modes")
        modesTab.label = "Modes"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        // === Built-in modes section ===
        let builtInLabel = NSTextField(labelWithString: "Built-in Modes")
        builtInLabel.font = NSFont.boldSystemFont(ofSize: 13)
        builtInLabel.frame = NSRect(x: 20, y: 350, width: 300, height: 20)
        view.addSubview(builtInLabel)

        let builtInHint = NSTextField(labelWithString: "Disable modes you don't use to keep the Super-key picker short.")
        builtInHint.textColor = .secondaryLabelColor
        builtInHint.font = NSFont.systemFont(ofSize: 11)
        builtInHint.frame = NSRect(x: 20, y: 330, width: 420, height: 16)
        view.addSubview(builtInHint)

        // 3 columns × 2 rows of checkboxes for the 6 built-in modes
        let columns = 3
        let cellW: CGFloat = 140
        let cellH: CGFloat = 24
        let startX: CGFloat = 20
        let startY: CGFloat = 300
        for (index, mode) in ModeManager.builtInModes.enumerated() {
            let col = index % columns
            let row = index / columns
            let x = startX + CGFloat(col) * cellW
            let y = startY - CGFloat(row) * (cellH + 4)
            let cb = NSButton(checkboxWithTitle: mode.name, target: nil, action: nil)
            cb.frame = NSRect(x: x, y: y, width: cellW - 8, height: cellH)
            cb.state = .on
            view.addSubview(cb)
            builtInModeCheckboxes[mode.id] = cb
        }

        // === Custom modes section ===
        let titleLabel = NSTextField(labelWithString: "Custom Processing Modes")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 20, y: 240, width: 300, height: 20)
        view.addSubview(titleLabel)

        let addButton = NSButton(title: "+ Add Mode", target: self, action: #selector(addCustomMode))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 350, y: 235, width: 100, height: 26)
        view.addSubview(addButton)

        // Scrollable container for custom modes
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 10, width: 420, height: 215))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        modesContainer = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 215))
        modesContainer.autoresizingMask = [.width]

        let clipView = NSClipView()
        clipView.documentView = modesContainer
        scrollView.contentView = clipView
        view.addSubview(scrollView)

        modesTab.view = view
        tabView.addTabViewItem(modesTab)
    }

    @objc private func addCustomMode() {
        let newMode: [String: String] = [
            "id": "custom_\(Int(Date().timeIntervalSince1970))",
            "name": "",
            "icon": "star",
            "prompt": "",
            "enabled": "true"
        ]
        customModesData.append(newMode)
        refreshModesUI()
    }

    private func refreshModesUI() {
        // Clear existing subviews and tracked views
        modesContainer.subviews.forEach { $0.removeFromSuperview() }
        customModePromptViews.removeAll()
        customModeNameFields.removeAll()

        let modeHeight: CGFloat = 140
        let spacing: CGFloat = 10
        let totalHeight = max(CGFloat(customModesData.count) * (modeHeight + spacing) + 10, modesContainer.enclosingScrollView?.frame.height ?? 250)
        modesContainer.frame = NSRect(x: 0, y: 0, width: 420, height: totalHeight)

        // Available SF Symbol icons
        let availableIcons = ["star", "envelope", "doc.text", "globe", "hammer", "wrench", "lightbulb", "book", "pencil", "text.bubble", "brain.head.profile", "list.bullet"]

        for (index, modeData) in customModesData.enumerated() {
            let yPos = totalHeight - CGFloat(index + 1) * (modeHeight + spacing)

            let isEnabled = (modeData["enabled"] ?? "true") == "true"

            // Mode card container
            let card = NSView(frame: NSRect(x: 5, y: yPos, width: 395, height: modeHeight))
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            card.layer?.cornerRadius = 6
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.separatorColor.cgColor

            // Enable/Disable checkbox
            let enableCheckbox = NSButton(checkboxWithTitle: "Activé", target: self, action: #selector(customModeEnabledChanged(_:)))
            enableCheckbox.frame = NSRect(x: 10, y: 110, width: 80, height: 20)
            enableCheckbox.font = NSFont.systemFont(ofSize: 11)
            enableCheckbox.state = isEnabled ? .on : .off
            enableCheckbox.tag = index
            card.addSubview(enableCheckbox)

            // Name field
            let nameLabel = NSTextField(labelWithString: "Name:")
            nameLabel.frame = NSRect(x: 100, y: 110, width: 45, height: 20)
            nameLabel.font = NSFont.systemFont(ofSize: 11)
            card.addSubview(nameLabel)

            let nameField = NSTextField(frame: NSRect(x: 145, y: 108, width: 100, height: 22))
            nameField.stringValue = modeData["name"] ?? ""
            nameField.placeholderString = "Email"
            nameField.font = NSFont.systemFont(ofSize: 11)
            nameField.tag = index * 100 + 1
            nameField.target = self
            nameField.action = #selector(customModeFieldChanged(_:))
            card.addSubview(nameField)

            // Icon popup
            let iconLabel = NSTextField(labelWithString: "Icon:")
            iconLabel.frame = NSRect(x: 255, y: 110, width: 35, height: 20)
            iconLabel.font = NSFont.systemFont(ofSize: 11)
            card.addSubview(iconLabel)

            let iconPopup = NSPopUpButton(frame: NSRect(x: 290, y: 107, width: 65, height: 22))
            iconPopup.font = NSFont.systemFont(ofSize: 11)
            for icon in availableIcons {
                iconPopup.addItem(withTitle: icon)
            }
            if let currentIcon = modeData["icon"], let iconIndex = availableIcons.firstIndex(of: currentIcon) {
                iconPopup.selectItem(at: iconIndex)
            }
            iconPopup.tag = index * 100 + 2
            iconPopup.target = self
            iconPopup.action = #selector(customModeIconChanged(_:))
            card.addSubview(iconPopup)

            // Delete button
            let deleteButton = NSButton(title: "✕", target: self, action: #selector(deleteCustomMode(_:)))
            deleteButton.bezelStyle = .inline
            deleteButton.frame = NSRect(x: 365, y: 108, width: 25, height: 22)
            deleteButton.tag = index
            card.addSubview(deleteButton)

            // Prompt text area
            let promptLabel = NSTextField(labelWithString: "System Prompt:")
            promptLabel.frame = NSRect(x: 10, y: 82, width: 100, height: 16)
            promptLabel.font = NSFont.systemFont(ofSize: 11)
            card.addSubview(promptLabel)

            let promptScrollView = NSScrollView(frame: NSRect(x: 10, y: 5, width: 375, height: 75))
            promptScrollView.hasVerticalScroller = true
            promptScrollView.borderType = .bezelBorder

            let promptTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 375, height: 75))
            promptTextView.string = modeData["prompt"] ?? ""
            promptTextView.font = NSFont.systemFont(ofSize: 11)
            promptTextView.isEditable = true
            promptTextView.isRichText = false
            promptTextView.autoresizingMask = [.width, .height]
            promptTextView.delegate = self

            promptScrollView.documentView = promptTextView
            card.addSubview(promptScrollView)

            // Track fields for syncing before save
            customModeNameFields.append(nameField)
            customModePromptViews.append(promptTextView)

            // Visual dimming when disabled
            if !isEnabled {
                card.alphaValue = 0.5
            }

            modesContainer.addSubview(card)
        }

        // If no custom modes, show a hint
        if customModesData.isEmpty {
            let hintLabel = NSTextField(wrappingLabelWithString: "No custom modes yet. Click '+ Add Mode' to create your own processing mode with a custom system prompt.")
            hintLabel.frame = NSRect(x: 20, y: totalHeight - 60, width: 370, height: 40)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.font = NSFont.systemFont(ofSize: 12)
            modesContainer.addSubview(hintLabel)
        }
    }

    @objc private func customModeFieldChanged(_ sender: NSTextField) {
        let index = sender.tag / 100
        guard index < customModesData.count else { return }
        customModesData[index]["name"] = sender.stringValue
        // Also update the id based on name if it's a new mode
        let currentId = customModesData[index]["id"] ?? ""
        if currentId.hasPrefix("custom_") {
            let sanitizedName = sender.stringValue.lowercased().replacingOccurrences(of: " ", with: "_")
            if !sanitizedName.isEmpty {
                customModesData[index]["id"] = "custom_\(sanitizedName)"
            }
        }
    }

    @objc private func customModeIconChanged(_ sender: NSPopUpButton) {
        let index = sender.tag / 100
        guard index < customModesData.count else { return }
        let availableIcons = ["star", "envelope", "doc.text", "globe", "hammer", "wrench", "lightbulb", "book", "pencil", "text.bubble", "brain.head.profile", "list.bullet"]
        let iconIndex = sender.indexOfSelectedItem
        if iconIndex < availableIcons.count {
            customModesData[index]["icon"] = availableIcons[iconIndex]
        }
    }

    @objc private func customModeEnabledChanged(_ sender: NSButton) {
        let index = sender.tag
        guard index < customModesData.count else { return }
        customModesData[index]["enabled"] = sender.state == .on ? "true" : "false"
        refreshModesUI()
    }

    @objc private func deleteCustomMode(_ sender: NSButton) {
        let index = sender.tag
        guard index < customModesData.count else { return }
        customModesData.remove(at: index)
        refreshModesUI()
    }

    // MARK: - Projects tab

    private var projectsTableView: NSTableView!

    private func setupProjectsTab() {
        let tab = NSTabViewItem(identifier: "projects")
        tab.label = "Projects"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        let titleLabel = NSTextField(labelWithString: "Projects")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 20, y: 350, width: 300, height: 20)
        view.addSubview(titleLabel)

        let hint = NSTextField(labelWithString: "Created projects can be assigned during recording or retroactively from the History viewer.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.frame = NSRect(x: 20, y: 330, width: 420, height: 16)
        view.addSubview(hint)

        let addButton = NSButton(title: "+ New project", target: self, action: #selector(newProjectClicked))
        addButton.bezelStyle = .rounded
        addButton.frame = NSRect(x: 320, y: 345, width: 120, height: 26)
        view.addSubview(addButton)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 50, width: 420, height: 270))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        projectsTableView = NSTableView()
        projectsTableView.rowHeight = 28
        projectsTableView.headerView = NSTableHeaderView()
        projectsTableView.dataSource = self
        projectsTableView.delegate = self
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p-name"))
        nameCol.title = "Name"
        nameCol.width = 210
        projectsTableView.addTableColumn(nameCol)
        let countCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p-count"))
        countCol.title = "Entries"
        countCol.width = 70
        projectsTableView.addTableColumn(countCol)
        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("p-status"))
        statusCol.title = "Status"
        statusCol.width = 120
        projectsTableView.addTableColumn(statusCol)
        scroll.documentView = projectsTableView
        view.addSubview(scroll)

        let renameBtn = NSButton(title: "Rename", target: self, action: #selector(renameSelectedProject))
        renameBtn.bezelStyle = .rounded
        renameBtn.frame = NSRect(x: 20, y: 12, width: 90, height: 28)
        view.addSubview(renameBtn)

        let archiveBtn = NSButton(title: "Archive / Restore", target: self, action: #selector(toggleArchiveSelectedProject))
        archiveBtn.bezelStyle = .rounded
        archiveBtn.frame = NSRect(x: 118, y: 12, width: 150, height: 28)
        view.addSubview(archiveBtn)

        let deleteBtn = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedProject))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.frame = NSRect(x: 276, y: 12, width: 80, height: 28)
        view.addSubview(deleteBtn)

        tab.view = view
        tabView.addTabViewItem(tab)
    }

    @objc private func newProjectClicked() {
        let alert = NSAlert()
        alert.messageText = "New project"
        alert.informativeText = "Enter a name:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = ProjectStore.shared.create(name: name)
        projectsTableView?.reloadData()
    }

    @objc private func renameSelectedProject() {
        let all = ProjectStore.shared.all
        let row = projectsTableView.selectedRow
        guard row >= 0 && row < all.count else { return }
        let project = all[row]
        let alert = NSAlert()
        alert.messageText = "Rename \(project.name)"
        alert.informativeText = "New name:"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = project.name
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        ProjectStore.shared.rename(project.id, to: name)
        projectsTableView?.reloadData()
    }

    @objc private func toggleArchiveSelectedProject() {
        let all = ProjectStore.shared.all
        let row = projectsTableView.selectedRow
        guard row >= 0 && row < all.count else { return }
        let project = all[row]
        ProjectStore.shared.setArchived(project.id, !project.archived)
        projectsTableView?.reloadData()
    }

    @objc private func deleteSelectedProject() {
        let all = ProjectStore.shared.all
        let row = projectsTableView.selectedRow
        guard row >= 0 && row < all.count else { return }
        let project = all[row]
        let alert = NSAlert()
        alert.messageText = "Delete “\(project.name)”?"
        alert.informativeText = "Tagged entries keep their tag but the project disappears from filters. Can\'t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ProjectStore.shared.delete(project.id)
        projectsTableView?.reloadData()
    }

    // MARK: NSTableViewDataSource / Delegate (projects table)

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === projectsTableView else { return 0 }
        return ProjectStore.shared.all.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === projectsTableView, let col = tableColumn else { return nil }
        let projects = ProjectStore.shared.all
        guard row < projects.count else { return nil }
        let project = projects[row]

        // Count tagged entries for this project (cheap — one pass over history)
        let count = HistoryManager.shared.getEntries().filter { $0.projectID == project.id }.count

        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        switch col.identifier.rawValue {
        case "p-name":   tf.stringValue = project.name
        case "p-count":  tf.stringValue = String(count)
        case "p-status": tf.stringValue = project.archived ? "Archived" : "Active"
        default: tf.stringValue = ""
        }
        if project.archived { tf.textColor = .secondaryLabelColor }
        return cell
    }

    private func setupLogsTab() {
        let logsTab = NSTabViewItem(identifier: "logs")
        logsTab.label = "Logs"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        // Clear logs button
        let clearButton = NSButton(title: "Clear Logs", target: self, action: #selector(clearLogsClicked))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 20, y: 265, width: 100, height: 26)
        view.addSubview(clearButton)

        // Auto-scroll checkbox
        autoScrollCheckbox = NSButton(checkboxWithTitle: "Auto-scroll", target: nil, action: nil)
        autoScrollCheckbox.frame = NSRect(x: 350, y: 265, width: 100, height: 26)
        autoScrollCheckbox.state = .on
        view.addSubview(autoScrollCheckbox)

        // Logs scroll view
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 10, width: 420, height: 250))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        logsTextView = NSTextView(frame: scrollView.bounds)
        logsTextView.isEditable = false
        logsTextView.isSelectable = true
        logsTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logsTextView.textColor = .labelColor
        logsTextView.backgroundColor = .textBackgroundColor
        logsTextView.autoresizingMask = [.width, .height]

        scrollView.documentView = logsTextView
        view.addSubview(scrollView)

        logsTab.view = view
        tabView.addTabViewItem(logsTab)
    }

    func show() {
        // Load current config
        currentConfig = Config.load()
        populateFields()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start logs refresh timer
        startLogsRefresh()
    }

    private func populateFields() {
        guard let config = currentConfig else { return }

        // Provider
        let providerIndex = TranscriptionProviderFactory.availableProviders.firstIndex { $0.id == config.provider } ?? 0
        providerPopup.selectItem(at: providerIndex)
        if let provider = TranscriptionProviderFactory.availableProviders[safe: providerIndex] {
            updateApiKeyLink(for: provider)
            providerSelectionChanged() // Update UI visibility
        }

        // API Key
        apiKeyField.stringValue = config.getCurrentApiKey()

        // Local whisper settings - select model based on saved path
        refreshModelList()
        if !config.whisperModelPath.isEmpty {
            // Try to find matching model by path
            for (index, model) in WhisperModelInfo.available.enumerated() {
                let expectedPath = WhisperModelManager.shared.modelPath(for: model.id).path
                if config.whisperModelPath == expectedPath || config.whisperModelPath.contains("ggml-\(model.id).bin") {
                    modelPopup.selectItem(at: index)
                    break
                }
            }
        }
        updateDownloadButtonState()

        // Update server status
        if WhisperServerManager.shared.isRunning {
            serverStatusLabel.stringValue = "Server running"
            serverStatusLabel.textColor = .systemGreen
        } else {
            serverStatusLabel.stringValue = ""
        }

        // Language
        switch config.whisperLanguage {
        case "en": whisperLanguagePopup.selectItem(at: 1)
        case "auto": whisperLanguagePopup.selectItem(at: 2)
        default: whisperLanguagePopup.selectItem(at: 0) // French
        }

        // Toggle shortcut + PTT — load into the recorders
        toggleShortcutRecorder.setBinding(
            keyCode: config.shortcutKeyCode,
            modifiers: config.shortcutModifiers
        )
        pttKeyRecorder.setBinding(
            keyCode: config.pushToTalkKeyCode,
            modifiers: config.pushToTalkModifiers
        )

        // Custom vocabulary
        customVocabularyField.stringValue = config.customVocabulary.joined(separator: ", ")

        // Processing model
        if let modelIndex = TextProcessor.availableModels.firstIndex(where: { $0.id == config.processingModel }) {
            processingModelPopup.selectItem(at: modelIndex)
        }

        // Custom modes
        customModesData = config.customModes
        refreshModesUI()

        // Built-in modes enable/disable state
        let disabledIds = Set(config.disabledBuiltInModeIds)
        for (modeId, cb) in builtInModeCheckboxes {
            cb.state = disabledIds.contains(modeId) ? .off : .on
        }

        // Launch at login
        let launchAgentExists = FileManager.default.fileExists(atPath: AppDelegate.launchAgentPath.path)
        launchAtLoginCheckbox.state = launchAgentExists ? .on : .off

        // Reset connection status
        connectionStatusLabel.stringValue = ""

        // Refresh logs
        refreshLogs()
    }

    private func updateApiKeyLink(for provider: ProviderInfo) {
        let host = provider.apiKeyHelpUrl.host ?? "provider website"
        apiKeyLinkButton.title = "Get your API key from \(host)"
        apiKeyLinkButton.attributedTitle = NSAttributedString(
            string: apiKeyLinkButton.title,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
    }

    @objc private func providerSelectionChanged() {
        guard let provider = providerPopup.selectedItem?.representedObject as? ProviderInfo else { return }
        updateApiKeyLink(for: provider)
        connectionStatusLabel.stringValue = ""

        let isLocal = provider.id == "local"

        // Toggle the two settings containers — only one visible at a time.
        remoteSettingsContainer.isHidden = isLocal
        localSettingsContainer.isHidden = !isLocal

        if isLocal {
            testConnectionButton.title = "Test Setup"
        } else {
            testConnectionButton.title = "Test Connection"
            apiKeyField.placeholderString = provider.id == "openai" ? "sk-..." : "Enter API key"
        }
    }

    @objc private func openApiKeyPage() {
        guard let provider = providerPopup.selectedItem?.representedObject as? ProviderInfo else { return }
        NSWorkspace.shared.open(provider.apiKeyHelpUrl)
    }

    @objc private func testConnectionClicked() {
        guard let provider = providerPopup.selectedItem?.representedObject as? ProviderInfo else { return }

        // Handle local provider differently
        if provider.id == "local" {
            testLocalSetup()
            return
        }

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate format first
        let validation = TranscriptionProviderFactory.validateApiKey(providerId: provider.id, apiKey: apiKey)
        if !validation.valid {
            connectionStatusLabel.stringValue = "Invalid: \(validation.error ?? "Unknown error")"
            connectionStatusLabel.textColor = .systemRed
            return
        }

        connectionStatusLabel.stringValue = "Testing..."
        connectionStatusLabel.textColor = .secondaryLabelColor
        testConnectionButton.isEnabled = false

        // Test with a minimal API call
        testApiConnection(providerId: provider.id, apiKey: apiKey) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.testConnectionButton.isEnabled = true
                if success {
                    self?.connectionStatusLabel.stringValue = "Connected"
                    self?.connectionStatusLabel.textColor = .systemGreen
                } else {
                    self?.connectionStatusLabel.stringValue = "Failed: \(error ?? "Unknown error")"
                    self?.connectionStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    private func testLocalSetup() {
        guard let model = modelPopup.selectedItem?.representedObject as? WhisperModelInfo else {
            connectionStatusLabel.stringValue = "No model selected"
            connectionStatusLabel.textColor = .systemRed
            return
        }

        let modelPath = WhisperModelManager.shared.modelPath(for: model.id).path
        let localProvider = LocalWhisperProvider(modelPath: modelPath)
        let validation = localProvider.validateSetup()

        if validation.valid {
            connectionStatusLabel.stringValue = "Setup OK - Ready to use"
            connectionStatusLabel.textColor = .systemGreen
        } else {
            connectionStatusLabel.stringValue = validation.errorMessage ?? "Invalid setup"
            connectionStatusLabel.textColor = .systemRed
        }
    }

    private func testApiConnection(providerId: String, apiKey: String, completion: @escaping (Bool, String?) -> Void) {
        // For OpenAI, we test the models endpoint
        // For Mistral, we test the models endpoint too
        let url: URL
        let authHeader: String
        let authValue: String

        switch providerId.lowercased() {
        case "mistral":
            url = URL(string: "https://api.mistral.ai/v1/models")!
            authHeader = "x-api-key"
            authValue = apiKey
        default: // openai
            url = URL(string: "https://api.openai.com/v1/models")!
            authHeader = "Authorization"
            authValue = "Bearer \(apiKey)"
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authValue, forHTTPHeaderField: authHeader)
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    completion(true, nil)
                } else if httpResponse.statusCode == 401 {
                    completion(false, "Invalid API key")
                } else {
                    completion(false, "HTTP \(httpResponse.statusCode)")
                }
            } else {
                completion(false, "No response")
            }
        }.resume()
    }

    @objc private func clearLogsClicked() {
        LogManager.shared.clearLogs()
        logsTextView.string = ""
    }

    private func startLogsRefresh() {
        logsRefreshTimer?.invalidate()
        logsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Only refresh if logs tab is selected
            if self?.tabView.selectedTabViewItem?.identifier as? String == "logs" {
                self?.refreshLogs()
            }
        }
    }

    private func stopLogsRefresh() {
        logsRefreshTimer?.invalidate()
        logsRefreshTimer = nil
    }

    private func refreshLogs() {
        let logs = LogManager.shared.getRecentLogs(count: 100)
        logsTextView.string = logs.joined(separator: "\n")

        // Auto-scroll if enabled
        if autoScrollCheckbox.state == .on {
            logsTextView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func cancelClicked() {
        window.close()
    }

    @objc private func saveClicked() {
        guard let provider = providerPopup.selectedItem?.representedObject as? ProviderInfo else {
            showError("Please select a provider")
            return
        }

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Local whisper settings
        var modelPath = ""
        let language: String
        switch whisperLanguagePopup.indexOfSelectedItem {
        case 1: language = "en"
        case 2: language = "auto"
        default: language = "fr"
        }

        // Validation based on provider type
        if provider.id == "local" {
            // Get selected model
            guard let model = modelPopup.selectedItem?.representedObject as? WhisperModelInfo else {
                showError("Please select a model")
                return
            }

            modelPath = WhisperModelManager.shared.modelPath(for: model.id).path

            // Validate local setup
            let localProvider = LocalWhisperProvider(modelPath: modelPath)
            let validation = localProvider.validateSetup()
            if !validation.valid {
                showError(validation.errorMessage ?? "Invalid local setup")
                return
            }

            // Stop existing server if running (will restart with new settings)
            WhisperServerManager.shared.stopServer()
        } else {
            // Validate API key for cloud providers
            let validation = TranscriptionProviderFactory.validateApiKey(providerId: provider.id, apiKey: apiKey)
            if !validation.valid {
                showError(validation.error ?? "Invalid API key")
                return
            }
        }

        // Shortcut bindings — come directly from the recorders
        let toggleKeyCode = toggleShortcutRecorder.keyCode
        let toggleModifiers = toggleShortcutRecorder.modifiers
        let pttKeyCode = pttKeyRecorder.keyCode
        let pttModifiers = pttKeyRecorder.modifiers

        // Preserve existing providerApiKeys if they exist
        let existingProviderKeys = currentConfig?.providerApiKeys ?? [:]

        // Parse custom vocabulary from comma-separated field
        let vocabularyText = customVocabularyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let customVocabulary: [String] = vocabularyText.isEmpty ? [] :
            vocabularyText.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // Sync name fields from UI (action only fires on Enter, not on Save click)
        for (index, nameField) in customModeNameFields.enumerated() where index < customModesData.count {
            customModesData[index]["name"] = nameField.stringValue
            let sanitizedName = nameField.stringValue.lowercased().replacingOccurrences(of: " ", with: "_")
            if !sanitizedName.isEmpty {
                customModesData[index]["id"] = "custom_\(sanitizedName)"
            }
        }

        // Filter valid custom modes (must have name and prompt)
        let validCustomModes = customModesData.filter { mode in
            let name = mode["name"] ?? ""
            let prompt = mode["prompt"] ?? ""
            return !name.isEmpty && !prompt.isEmpty
        }

        // Create new config with all settings
        let newConfig = Config(
            provider: provider.id,
            apiKey: apiKey,
            providerApiKeys: existingProviderKeys,
            shortcutModifiers: toggleModifiers,
            shortcutKeyCode: toggleKeyCode,
            pushToTalkKeyCode: pttKeyCode,
            pushToTalkModifiers: pttModifiers,
            whisperCliPath: "",  // No longer used, kept for compatibility
            whisperModelPath: modelPath,
            whisperLanguage: language,
            customVocabulary: customVocabulary,
            customModes: validCustomModes,
            disabledBuiltInModeIds: builtInModeCheckboxes.compactMap { $0.value.state == .off ? $0.key : nil },
            projectTaggingEnabled: currentConfig?.projectTaggingEnabled ?? true,
            lastUsedProjectID: currentConfig?.lastUsedProjectID ?? "",
            processingModel: processingModelPopup.selectedItem?.representedObject as? String ?? "gpt-4.1-nano",
            skippedUpdateVersion: currentConfig?.skippedUpdateVersion ?? "",
            lastUpdateCheck: currentConfig?.lastUpdateCheck ?? 0
        )
        newConfig.save()

        // Update launch at login
        if launchAtLoginCheckbox.state == .on {
            (NSApp.delegate as? AppDelegate)?.setupAutoStart()
        } else {
            (NSApp.delegate as? AppDelegate)?.removeAutoStart()
        }

        // Reload custom modes in ModeManager
        ModeManager.shared.reloadModes()

        if provider.id == "local" {
            LogManager.shared.log("Settings saved - Provider: Local (whisper.cpp), Model: \(modelPath), Language: \(language)")
        } else {
            LogManager.shared.log("Settings saved - Provider: \(provider.displayName), Toggle: \(newConfig.toggleShortcutDescription()), PTT: \(newConfig.pushToTalkDescription())")
        }

        // Notify delegate
        onSettingsChanged?()

        // Close window
        window.close()

        // Show confirmation
        showNotification(title: "Settings Saved", message: "Your preferences have been applied")
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Invalid Settings"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        // Update prompt text for custom mode
        if let index = customModePromptViews.firstIndex(where: { $0 === textView }), index < customModesData.count {
            customModesData[index]["prompt"] = textView.string
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopLogsRefresh()
    }
}

// Safe array access extension
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
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

    // LLM model for AI processing modes
    var processingModel: String

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

        // Processing model
        let processingModel = json["processingModel"] as? String ?? "gpt-4.1-nano"

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
            processingModel: processingModel,
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
        if processingModel != "gpt-4.1-nano" {
            json["processingModel"] = processingModel
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

/// Clickable control that captures a key combo when focused. Replaces the
/// fixed-list dropdowns in the Shortcuts tab — user can bind any combo.
class ShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var monitor: Any?

    var keyCode: UInt32
    var modifiers: UInt32
    var allowsBareKeys: Bool

    init(keyCode: UInt32, modifiers: UInt32, allowsBareKeys: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.allowsBareKeys = allowsBareKeys
        super.init(frame: .zero)

        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        label.stringValue = "Press keys…"
        label.textColor = .secondaryLabelColor
        layer?.borderColor = NSColor.systemBlue.cgColor
        window?.makeFirstResponder(self)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            if Int(event.keyCode) == kVK_Escape {
                self.stopRecording()
                return nil
            }
            let mods = carbonModifiers(from: event.modifierFlags.rawValue)
            if !self.allowsBareKeys && mods == 0 {
                // Require a modifier: flash red briefly, keep recording.
                self.layer?.borderColor = NSColor.systemRed.cgColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.layer?.borderColor = NSColor.systemBlue.cgColor
                }
                return nil
            }
            self.keyCode = UInt32(event.keyCode)
            self.modifiers = mods
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.textColor = .labelColor
        updateDisplay()
    }

    private func updateDisplay() {
        let combo = modifiersToString(modifiers) + (modifiers != 0 ? " " : "") + keyCodeToString(keyCode)
        label.stringValue = combo
    }

    func setBinding(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        updateDisplay()
    }
}

// MARK: - Processing Modes

struct ProcessingMode {
    let id: String
    let name: String
    let icon: String  // SF Symbol name
    let systemPrompt: String?  // nil = no AI processing (voice-to-text only)

    var requiresProcessing: Bool { systemPrompt != nil }
}

class ModeManager {
    static let shared = ModeManager()

    private init() {
        reloadModes()
    }

    /// Check if OpenAI API key is configured for AI processing modes
    var hasOpenAIKey: Bool {
        guard let config = Config.load() else { return false }
        let openaiKey = config.providerApiKeys["openai"] ?? ""
        // If using OpenAI as transcription provider, the main apiKey works too
        if config.provider == "openai" && !config.apiKey.isEmpty {
            return true
        }
        return !openaiKey.isEmpty && openaiKey.hasPrefix("sk-")
    }

    /// Get the OpenAI API key for processing
    var openAIKey: String? {
        guard let config = Config.load() else { return nil }
        // First check providerApiKeys
        if let key = config.providerApiKeys["openai"], !key.isEmpty, key.hasPrefix("sk-") {
            return key
        }
        // Fall back to main apiKey if using OpenAI as provider
        if config.provider == "openai" && !config.apiKey.isEmpty {
            return config.apiKey
        }
        return nil
    }

    static let builtInModes: [ProcessingMode] = [
        ProcessingMode(
            id: "voice-to-text",
            name: "Brut",
            icon: "waveform",
            systemPrompt: nil
        ),
        ProcessingMode(
            id: "clean",
            name: "Clean",
            icon: "sparkles",
            systemPrompt: """
            Tu es un assistant qui nettoie des transcriptions vocales.
            Règles:
            - Supprime les hésitations (euh, hmm, ben, bah, genre, en fait répété)
            - Corrige la ponctuation et les majuscules
            - Garde le sens et le ton exact du message
            - Ne reformule PAS, ne résume PAS
            - Réponds UNIQUEMENT avec le texte corrigé, rien d'autre
            """
        ),
        ProcessingMode(
            id: "formal",
            name: "Formel",
            icon: "briefcase",
            systemPrompt: """
            Tu es un assistant qui transforme des transcriptions vocales en texte professionnel.
            Règles:
            - Adopte un ton professionnel et structuré
            - Corrige grammaire, ponctuation, majuscules
            - Structure le texte si nécessaire (paragraphes)
            - Garde le message original intact
            - Ne change PAS le tutoiement en vouvoiement (et inversement). Respecte le registre d'adresse original.
            - Réponds UNIQUEMENT avec le texte transformé, rien d'autre
            """
        ),
        ProcessingMode(
            id: "casual",
            name: "Casual",
            icon: "face.smiling",
            systemPrompt: """
            Tu es un assistant qui nettoie des transcriptions vocales en gardant un ton décontracté.
            Règles:
            - Garde un ton naturel et amical
            - Supprime les hésitations excessives mais garde le naturel
            - Corrige les erreurs évidentes seulement
            - Préserve les expressions familières
            - Réponds UNIQUEMENT avec le texte nettoyé, rien d'autre
            """
        ),
        ProcessingMode(
            id: "markdown",
            name: "Markdown",
            icon: "text.badge.checkmark",
            systemPrompt: """
            Tu es un assistant qui convertit des transcriptions vocales en Markdown structuré.
            Règles:
            - Utilise des headers (#, ##) si le contenu a une structure
            - Utilise des listes (-, *) pour les énumérations
            - Utilise **gras** pour les points importants
            - Utilise `code` pour les termes techniques
            - Corrige grammaire et ponctuation
            - Réponds UNIQUEMENT avec le texte en Markdown, rien d'autre
            """
        ),
        ProcessingMode(
            id: "super",
            name: "Super",
            icon: "bolt.fill",
            systemPrompt: "dynamic"  // Placeholder - actual prompt is built dynamically with context
        )
    ]

    private(set) var modes: [ProcessingMode] = ModeManager.builtInModes

    private(set) var currentModeIndex: Int = 0

    var currentMode: ProcessingMode {
        modes[currentModeIndex]
    }

    /// Number of built-in modes (for reference in UI)
    var builtInModeCount: Int { ModeManager.builtInModes.count }

    /// Reload modes from config (built-in + custom modes)
    func reloadModes() {
        let config = Config.load()
        let disabledBuiltIns = Set(config?.disabledBuiltInModeIds ?? [])
        var allModes = ModeManager.builtInModes.filter { !disabledBuiltIns.contains($0.id) }

        // Load custom modes from config
        if let config = config {
            for modeDict in config.customModes {
                guard let id = modeDict["id"], !id.isEmpty,
                      let name = modeDict["name"], !name.isEmpty,
                      let prompt = modeDict["prompt"], !prompt.isEmpty else { continue }
                // Skip disabled modes
                let enabled = modeDict["enabled"] ?? "true"
                guard enabled == "true" else { continue }
                let icon = modeDict["icon"] ?? "star"
                let mode = ProcessingMode(id: id, name: name, icon: icon, systemPrompt: prompt)
                allModes.append(mode)
            }
        }

        modes = allModes

        // Reset index if out of bounds
        if currentModeIndex >= modes.count {
            currentModeIndex = 0
        }
    }

    /// Check if a mode is available (AI modes require OpenAI key)
    func isModeAvailable(_ mode: ProcessingMode) -> Bool {
        if mode.requiresProcessing {
            return hasOpenAIKey
        }
        return true
    }

    func isModeAvailable(at index: Int) -> Bool {
        guard index >= 0 && index < modes.count else { return false }
        return isModeAvailable(modes[index])
    }

    func nextMode() -> ProcessingMode {
        // Find next available mode
        var nextIndex = (currentModeIndex + 1) % modes.count
        var attempts = 0

        while !isModeAvailable(at: nextIndex) && attempts < modes.count {
            nextIndex = (nextIndex + 1) % modes.count
            attempts += 1
        }

        // If no available mode found, stay on current or go to voice-to-text
        if attempts >= modes.count {
            currentModeIndex = 0  // Voice-to-text is always available
        } else {
            currentModeIndex = nextIndex
        }

        return currentMode
    }

    func setMode(index: Int) {
        guard index >= 0 && index < modes.count else { return }
        guard isModeAvailable(at: index) else { return }
        currentModeIndex = index
    }

    func setMode(id: String) {
        if let index = modes.firstIndex(where: { $0.id == id }) {
            setMode(index: index)
        }
    }
}

// MARK: - Text Processor (GPT API)

class TextProcessor {
    static let shared = TextProcessor()

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// Available LLM models for processing. Ordered cheapest/fastest → premium,
    /// with legacy GPT-4o kept at the bottom for users who already rely on it.
    static let availableModels: [(id: String, name: String)] = [
        ("gpt-4.1-nano", "GPT-4.1 Nano (le plus rapide et économique)"),
        ("gpt-4.1-mini", "GPT-4.1 Mini (équilibre qualité/coût)"),
        ("gpt-4.1", "GPT-4.1 (premium)"),
        ("gpt-4o-mini", "GPT-4o Mini (ancien)"),
        ("gpt-4o", "GPT-4o (ancien)")
    ]

    private var model: String {
        Config.load()?.processingModel ?? "gpt-4.1-nano"
    }

    func process(text: String, mode: ProcessingMode, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        process(text: text, mode: mode, context: nil, apiKey: apiKey, completion: completion)
    }

    func process(text: String, mode: ProcessingMode, context: String?, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let systemPrompt = mode.systemPrompt else {
            // No processing needed
            completion(.success(text))
            return
        }

        LogManager.shared.log("[TextProcessor] Processing with mode: \(mode.name)")

        // Build system prompt - for Super mode with context, use dynamic prompt
        let effectivePrompt: String
        if mode.id == "super", let context = context, !context.isEmpty {
            effectivePrompt = """
            Tu es un assistant intelligent. L'utilisateur a sélectionné le texte suivant :
            ---
            \(context)
            ---
            Il te donne une instruction vocale à appliquer sur ce texte.
            Réponds UNIQUEMENT avec le résultat, rien d'autre.
            """
        } else if mode.id == "super" {
            // Super mode without context - act as general assistant
            effectivePrompt = """
            Tu es un assistant intelligent. L'utilisateur te donne une instruction vocale.
            Réponds UNIQUEMENT avec le résultat demandé, rien d'autre.
            """
        } else {
            effectivePrompt = systemPrompt
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": effectivePrompt],
            ["role": "user", "content": text]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 2048
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(NSError(domain: "TextProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request"])))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                LogManager.shared.log("[TextProcessor] Network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "TextProcessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    LogManager.shared.log("[TextProcessor] Success - processed \(text.count) -> \(content.count) chars")
                    completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let error = json["error"] as? [String: Any],
                          let message = error["message"] as? String {
                    LogManager.shared.log("[TextProcessor] API error: \(message)")
                    completion(.failure(NSError(domain: "TextProcessor", code: -3, userInfo: [NSLocalizedDescriptionKey: message])))
                } else {
                    completion(.failure(NSError(domain: "TextProcessor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])))
                }
            } catch {
                LogManager.shared.log("[TextProcessor] Parse error: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Mode Selector View

class ModeSelectorView: NSView {
    private var modeViews: [NSView] = []
    private var modeLabels: [NSTextField] = []
    private var hintLabel: NSTextField!

    var onModeChanged: ((Int) -> Void)?

    private let expandedWidth: CGFloat = 90
    private let collapsedWidth: CGFloat = 32
    private let itemHeight: CGFloat = 28
    private let spacing: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let modes = ModeManager.shared.modes
        let hasOpenAI = ModeManager.shared.hasOpenAIKey
        var xOffset: CGFloat = 8

        for (index, mode) in modes.enumerated() {
            let isSelected = index == ModeManager.shared.currentModeIndex
            let isAvailable = ModeManager.shared.isModeAvailable(at: index)
            let width = isSelected ? expandedWidth : collapsedWidth

            // Container for each mode
            let container = NSView(frame: NSRect(x: xOffset, y: 4, width: width, height: itemHeight))
            container.wantsLayer = true
            container.layer?.cornerRadius = 6
            container.alphaValue = isAvailable ? 1.0 : 0.35

            if isSelected && isAvailable {
                container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            }

            // Icon
            let iconSize: CGFloat = 16
            let iconX: CGFloat = isSelected ? 8 : (width - iconSize) / 2
            let iconView = NSImageView(frame: NSRect(x: iconX, y: (itemHeight - iconSize) / 2, width: iconSize, height: iconSize))
            if let image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: mode.name) {
                iconView.image = image
                iconView.contentTintColor = isSelected && isAvailable ? .white : .white.withAlphaComponent(0.6)
            }
            container.addSubview(iconView)

            // Label (only for selected)
            let label = NSTextField(labelWithString: mode.name)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.frame = NSRect(x: 28, y: (itemHeight - 14) / 2, width: 60, height: 14)
            label.alphaValue = isSelected ? 1 : 0
            container.addSubview(label)
            modeLabels.append(label)

            addSubview(container)
            modeViews.append(container)

            xOffset += width + spacing
        }

        // Hint label - show different message if no OpenAI key
        let hintText = hasOpenAI ? "⇧ switch" : "⇧ (need OpenAI key)"
        hintLabel = NSTextField(labelWithString: hintText)
        hintLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        hintLabel.textColor = hasOpenAI ? .white.withAlphaComponent(0.4) : .systemOrange.withAlphaComponent(0.7)
        hintLabel.frame = NSRect(x: xOffset + 4, y: 11, width: hasOpenAI ? 50 : 110, height: 12)
        addSubview(hintLabel)
    }

    func updateSelection(animated: Bool = true) {
        let selectedIndex = ModeManager.shared.currentModeIndex

        var xOffset: CGFloat = 8

        let updateBlock = {
            for (index, container) in self.modeViews.enumerated() {
                let isSelected = index == selectedIndex
                let isAvailable = ModeManager.shared.isModeAvailable(at: index)
                let width = isSelected ? self.expandedWidth : self.collapsedWidth

                container.frame = NSRect(x: xOffset, y: 4, width: width, height: self.itemHeight)
                container.alphaValue = isAvailable ? 1.0 : 0.35
                container.layer?.backgroundColor = isSelected && isAvailable
                    ? NSColor.white.withAlphaComponent(0.15).cgColor
                    : NSColor.clear.cgColor

                // Update icon position and color
                if let iconView = container.subviews.first as? NSImageView {
                    let iconX: CGFloat = isSelected ? 8 : (width - 16) / 2
                    iconView.frame.origin.x = iconX
                    iconView.contentTintColor = isSelected && isAvailable ? .white : .white.withAlphaComponent(0.6)
                }

                // Update label visibility
                self.modeLabels[index].alphaValue = isSelected ? 1 : 0

                xOffset += width + self.spacing
            }

            // Update hint position
            self.hintLabel.frame.origin.x = xOffset + 4
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                updateBlock()
            }
        } else {
            updateBlock()
        }

        onModeChanged?(selectedIndex)
    }

    func cycleMode() {
        _ = ModeManager.shared.nextMode()
        updateSelection(animated: true)
    }
}

// MARK: - Transcription History

struct AppInfo: Codable {
    let bundleID: String
    let name: String
}

struct DictationSignals: Codable {
    var windowTitle: String?
    var browserURL: String?
    var browserTabTitle: String?
    var cwd: String?
    var foregroundCmd: String?
    var gitRemote: String?
    var gitBranch: String?
}

struct TranscriptionEntry: Codable {
    let id: UUID
    let timestamp: Date
    let text: String
    let durationSeconds: Double
    let provider: String
    var app: AppInfo?
    var signals: DictationSignals?
    var extras: [String: String]?

    init(text: String,
         durationSeconds: Double,
         provider: String,
         app: AppInfo? = nil,
         signals: DictationSignals? = nil,
         extras: [String: String]? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.text = text
        self.durationSeconds = durationSeconds
        self.provider = provider
        self.app = app
        self.signals = signals
        self.extras = extras
    }
}

class HistoryManager {
    static let shared = HistoryManager()

    private let historyFileURL: URL
    private let exportDirURL: URL
    private let migrationSentinelURL: URL
    private var entries: [TranscriptionEntry] = []
    private let queue = DispatchQueue(label: "com.whispervoice.history")

    // Shared date formatter for JSONL filenames (YYYY-MM-DD in local timezone)
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    // Encoder used for both history.json and JSONL lines; emits dates as Apple
    // reference-date doubles to stay wire-compatible with the legacy file.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        historyFileURL = appSupport.appendingPathComponent("history.json")

        // Exports live under Application Support (no TCC "Folders & Files"
        // permission needed, unlike ~/Documents on Hardened Runtime).
        exportDirURL = appSupport.appendingPathComponent("exports")
        migrationSentinelURL = exportDirURL.appendingPathComponent(".migrated-v1")
        try? FileManager.default.createDirectory(at: exportDirURL, withIntermediateDirectories: true)

        loadHistory()
        migrateToJSONLIfNeeded()
    }

    private func loadHistory() {
        queue.sync {
            guard let data = try? Data(contentsOf: historyFileURL),
                  let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) else {
                return
            }
            entries = decoded
        }
    }

    private func saveHistory() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(self.entries) {
                try? data.write(to: self.historyFileURL)
            }
        }
    }

    func addEntry(_ entry: TranscriptionEntry) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.insert(entry, at: 0)
            self.saveHistory()
            self.appendToJSONL(entry)
        }
    }

    // MARK: JSONL export

    /// Append one entry as a single JSON line to the day's JSONL file.
    /// Called from `queue` — no additional sync needed.
    private func appendToJSONL(_ entry: TranscriptionEntry) {
        do {
            let day = Self.dayFormatter.string(from: entry.timestamp)
            let fileURL = exportDirURL.appendingPathComponent("\(day).jsonl")
            var line = try Self.encoder.encode(entry)
            line.append(0x0A)  // newline

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            LogManager.shared.log("[HistoryManager] JSONL append failed: \(error)", level: "ERROR")
        }
    }

    /// One-time backfill of the JSONL directory from `history.json`.
    /// Writes a sentinel file to guarantee it runs at most once. Existing
    /// JSONL files are preserved (no overwrite) so re-runs are safe.
    private func migrateToJSONLIfNeeded() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.migrationSentinelURL.path) { return }
            guard !self.entries.isEmpty else {
                try? "migrated at \(Date()) — nothing to migrate\n".write(
                    to: self.migrationSentinelURL, atomically: true, encoding: .utf8)
                return
            }

            // Group by day (using each entry's own timestamp, in local tz).
            var byDay: [String: [TranscriptionEntry]] = [:]
            for entry in self.entries {
                let key = Self.dayFormatter.string(from: entry.timestamp)
                byDay[key, default: []].append(entry)
            }

            var totalWritten = 0
            var filesWritten = 0
            var filesSkipped = 0

            for (day, entriesForDay) in byDay {
                let fileURL = self.exportDirURL.appendingPathComponent("\(day).jsonl")
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    filesSkipped += 1
                    continue
                }
                // Chronological order within a day (history.json is newest-first)
                let sorted = entriesForDay.sorted { $0.timestamp < $1.timestamp }
                var blob = Data()
                for entry in sorted {
                    if let data = try? Self.encoder.encode(entry) {
                        blob.append(data)
                        blob.append(0x0A)
                        totalWritten += 1
                    }
                }
                if (try? blob.write(to: fileURL, options: .atomic)) != nil {
                    filesWritten += 1
                }
            }

            let stamp = "migrated at \(Date()) — wrote \(totalWritten) entries across \(filesWritten) files (\(filesSkipped) skipped)\n"
            try? stamp.write(to: self.migrationSentinelURL, atomically: true, encoding: .utf8)
            LogManager.shared.log("[HistoryManager] JSONL migration: \(totalWritten) entries, \(filesWritten) files, \(filesSkipped) skipped")
        }
    }

    func getEntries() -> [TranscriptionEntry] {
        return queue.sync { entries }
    }

    func search(query: String) -> [TranscriptionEntry] {
        return queue.sync {
            if query.isEmpty { return entries }
            return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    func deleteEntry(id: UUID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll { $0.id == id }
            self.saveHistory()
        }
    }

    func clearHistory() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll()
            self.saveHistory()
        }
    }

    /// Replace an entry in-place (used for retro-tagging). The JSONL export is
    /// append-only raw data so it isn't rewritten — the tag lives in the JSON
    /// history until we add a dedicated update-log later.
    func updateEntry(_ updated: TranscriptionEntry) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.entries.firstIndex(where: { $0.id == updated.id }) {
                self.entries[idx] = updated
                self.saveHistory()
            }
        }
    }

    func updateEntries(_ updates: [TranscriptionEntry]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var dirty = false
            for u in updates {
                if let idx = self.entries.firstIndex(where: { $0.id == u.id }) {
                    self.entries[idx] = u
                    dirty = true
                }
            }
            if dirty { self.saveHistory() }
        }
    }
}

// MARK: - Context Capture

struct DictationContext {
    let app: AppInfo?
    let signals: DictationSignals?
    let extras: [String: String]?
}

class ContextCapturer {
    static let shared = ContextCapturer()

    private static let knownBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.kagi.kagimacOS",           // Orion
    ]

    private static let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.alacritty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    private let queue = DispatchQueue(label: "com.whispervoice.context", qos: .userInitiated)

    /// Capture dictation context off the main thread. Completion fires on main queue.
    func captureNow(completion: @escaping (DictationContext?) -> Void) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            completion(nil)
            return
        }
        let appInfo = AppInfo(bundleID: bundleID, name: frontApp.localizedName ?? bundleID)
        let pid = frontApp.processIdentifier

        queue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var signals = DictationSignals()
            signals.windowTitle = self.focusedWindowTitle(pid: pid)

            if Self.knownBrowsers.contains(bundleID) {
                if let tab = self.captureBrowserURL(bundleID: bundleID) {
                    signals.browserURL = tab.url
                    signals.browserTabTitle = tab.title
                }
            } else if Self.knownTerminals.contains(bundleID) {
                let term = self.captureTerminalContext(rootPid: pid)
                signals.cwd = term.cwd
                signals.foregroundCmd = term.foregroundCmd
                signals.gitRemote = term.gitRemote
                signals.gitBranch = term.gitBranch
            }

            let ctx = DictationContext(app: appInfo, signals: signals, extras: nil)
            DispatchQueue.main.async { completion(ctx) }
        }
    }

    // MARK: Window title via AXUIElement

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowRef = focused else {
            return nil
        }
        let window = windowRef as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    // MARK: Browser URL via AppleScript

    private func captureBrowserURL(bundleID: String) -> (url: String, title: String)? {
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                set tabURL to URL of current tab of front window
                set tabName to name of current tab of front window
                return tabURL & linefeed & tabName
            end tell
            """
        case "company.thebrowser.Browser":
            script = """
            tell application "Arc"
                if (count of windows) is 0 then return ""
                set tabURL to URL of active tab of front window
                set tabTitle to title of active tab of front window
                return tabURL & linefeed & tabTitle
            end tell
            """
        default:
            let appName: String
            switch bundleID {
            case "com.google.Chrome": appName = "Google Chrome"
            case "com.google.Chrome.canary": appName = "Google Chrome Canary"
            case "com.brave.Browser": appName = "Brave Browser"
            case "com.vivaldi.Vivaldi": appName = "Vivaldi"
            case "com.microsoft.edgemac": appName = "Microsoft Edge"
            case "com.operasoftware.Opera": appName = "Opera"
            default: return nil   // Firefox / Orion: no reliable AppleScript URL API
            }
            script = """
            tell application "\(appName)"
                if (count of windows) is 0 then return ""
                set tabURL to URL of active tab of front window
                set tabTitle to title of active tab of front window
                return tabURL & linefeed & tabTitle
            end tell
            """
        }

        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let descriptor = appleScript.executeAndReturnError(&errorDict)
        if let err = errorDict {
            LogManager.shared.log("[ContextCapturer] AppleScript error for \(bundleID): \(err)", level: "DEBUG")
            return nil
        }
        guard let raw = descriptor.stringValue, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 2 else { return nil }
        return (url: parts[0], title: parts.dropFirst().joined(separator: "\n"))
    }

    // MARK: Terminal context via process tree + lsof

    private struct TerminalSnapshot {
        var cwd: String?
        var foregroundCmd: String?
        var gitRemote: String?
        var gitBranch: String?
    }

    private func captureTerminalContext(rootPid: pid_t) -> TerminalSnapshot {
        var snap = TerminalSnapshot()
        guard let leaf = findDeepestDescendant(of: rootPid) else { return snap }
        snap.foregroundCmd = processName(pid: leaf)
        snap.cwd = cwdForPid(leaf)
        if let cwd = snap.cwd, let git = gitInfo(cwd: cwd) {
            snap.gitRemote = git.remote
            snap.gitBranch = git.branch
        }
        return snap
    }

    private func findDeepestDescendant(of rootPid: pid_t) -> pid_t? {
        guard let output = runProcess("/bin/ps", args: ["-eo", "pid,ppid"]) else { return nil }
        var children: [pid_t: [pid_t]] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        var deepest: (pid: pid_t, depth: Int) = (rootPid, 0)
        var stack: [(pid_t, Int)] = [(rootPid, 0)]
        while let (pid, depth) = stack.popLast() {
            if depth > deepest.depth { deepest = (pid, depth) }
            for child in children[pid] ?? [] {
                stack.append((child, depth + 1))
            }
        }
        return deepest.pid == rootPid ? nil : deepest.pid
    }

    private func processName(pid: pid_t) -> String? {
        guard let raw = runProcess("/bin/ps", args: ["-o", "comm=", "-p", String(pid)]) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return (trimmed as NSString).lastPathComponent
    }

    private func cwdForPid(_ pid: pid_t) -> String? {
        guard let output = runProcess("/usr/sbin/lsof", args: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else {
            return nil
        }
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private func gitInfo(cwd: String) -> (remote: String?, branch: String?)? {
        var dir = cwd
        let fm = FileManager.default
        while !dir.isEmpty && dir != "/" {
            let head = dir + "/.git/HEAD"
            if fm.fileExists(atPath: head) {
                let branch = readGitBranch(headPath: head)
                let remote = readGitRemote(configPath: dir + "/.git/config")
                return (remote: remote, branch: branch)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private func readGitBranch(headPath: String) -> String? {
        guard let content = try? String(contentsOfFile: headPath) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(12))
    }

    private func readGitRemote(configPath: String) -> String? {
        guard let content = try? String(contentsOfFile: configPath) else { return nil }
        var inOrigin = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[remote") {
                inOrigin = line.contains("\"origin\"")
            } else if inOrigin, line.hasPrefix("url") {
                if let eq = line.firstIndex(of: "=") {
                    return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    // MARK: Process runner with timeout

    private func runProcess(_ path: String, args: [String], timeout: TimeInterval = 0.3) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        do {
            try task.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Projects

struct Project: Codable {
    let id: UUID
    var name: String
    var color: String?
    var createdAt: Date
    var archived: Bool

    init(id: UUID = UUID(), name: String, color: String? = nil, createdAt: Date = Date(), archived: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.archived = archived
    }
}

/// Owns ~/Library/Application Support/WhisperVoice/projects.json. Same
/// queue pattern as HistoryManager so reads/writes are thread-safe.
class ProjectStore {
    static let shared = ProjectStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.whispervoice.projects")
    private var projectsByID: [UUID: Project] = [:]

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("projects.json")
        loadFromDisk()
    }

    private func loadFromDisk() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["projects"] as? [[String: Any]] else { return }
            for dict in list {
                guard let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr),
                      let name = dict["name"] as? String else { continue }
                let color = dict["color"] as? String
                let createdAtTS = dict["createdAt"] as? TimeInterval ?? 0
                let archived = dict["archived"] as? Bool ?? false
                let project = Project(id: id, name: name, color: color,
                                      createdAt: Date(timeIntervalSince1970: createdAtTS),
                                      archived: archived)
                projectsByID[id] = project
            }
        }
    }

    private func saveToDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let list: [[String: Any]] = self.projectsByID.values.map { p in
                var d: [String: Any] = [
                    "id": p.id.uuidString,
                    "name": p.name,
                    "createdAt": p.createdAt.timeIntervalSince1970,
                    "archived": p.archived
                ]
                if let c = p.color { d["color"] = c }
                return d
            }
            let root: [String: Any] = ["projects": list, "version": 1]
            if let data = try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    var all: [Project] {
        queue.sync { projectsByID.values.sorted { $0.createdAt < $1.createdAt } }
    }

    var active: [Project] {
        all.filter { !$0.archived }
    }

    func byID(_ id: UUID) -> Project? {
        queue.sync { projectsByID[id] }
    }

    /// Case-insensitive name lookup on active projects, used to avoid dups when the user types.
    func byName(_ name: String) -> Project? {
        let needle = name.lowercased()
        return queue.sync {
            projectsByID.values.first(where: { $0.name.lowercased() == needle && !$0.archived })
        }
    }

    @discardableResult
    func create(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = byName(trimmed) { return existing }
        let project = Project(name: trimmed)
        queue.sync { projectsByID[project.id] = project }
        saveToDisk()
        return project
    }

    func rename(_ id: UUID, to newName: String) {
        queue.sync {
            guard var p = projectsByID[id] else { return }
            p.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            projectsByID[id] = p
        }
        saveToDisk()
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        queue.sync {
            guard var p = projectsByID[id] else { return }
            p.archived = archived
            projectsByID[id] = p
        }
        saveToDisk()
    }

    func delete(_ id: UUID) {
        queue.sync { _ = projectsByID.removeValue(forKey: id) }
        saveToDisk()
    }
}

struct ProjectPrediction {
    let project: Project?
    let confidence: Double
    let reason: String
    /// "predicted" when the top tier found a match, "last-used" for fallback, "none" for neither.
    let source: String
}

/// Stateless predictor. Queries the existing history for entries that share
/// a signal with the current context and returns the most frequently tagged
/// project among them. No separate rule store — the history is the ground truth.
enum ProjectPredictor {
    /// Window of recent entries considered for prediction, seconds.
    private static let recencyWindow: TimeInterval = 90 * 24 * 60 * 60

    static func predict(ctx: DictationContext?) -> ProjectPrediction {
        guard let ctx = ctx else { return fallback(reason: "no-context") }

        let now = Date()
        let entries = HistoryManager.shared.getEntries().filter {
            now.timeIntervalSince($0.timestamp) <= recencyWindow
        }
        let activeIDs = Set(ProjectStore.shared.active.map { $0.id })

        // Tier 1 — gitRemote (deterministic)
        if let remote = ctx.signals?.gitRemote, !remote.isEmpty {
            let key = normalize(remote)
            let matches = entries.filter { normalize($0.signals?.gitRemote ?? "") == key && activeIDs.contains($0.projectID ?? UUID()) }
            if let best = mostCommonProject(in: matches) {
                return ProjectPrediction(project: best.project, confidence: 0.95,
                                         reason: "gitRemote: \(remote)", source: "predicted")
            }
        }

        // Tier 2 — browser host
        if let url = ctx.signals?.browserURL, let host = urlHost(url) {
            let matches = entries.filter {
                guard let otherURL = $0.signals?.browserURL, let otherHost = urlHost(otherURL) else { return false }
                return otherHost == host && activeIDs.contains($0.projectID ?? UUID())
            }
            if matches.count >= 2, let best = mostCommonProject(in: matches) {
                return ProjectPrediction(project: best.project, confidence: 0.80,
                                         reason: "host: \(host)", source: "predicted")
            }
        }

        // Tier 3 — bundleID (only if strong agreement to avoid "Slack → always perso" locks)
        if let bundleID = ctx.app?.bundleID {
            let matches = entries.filter { $0.app?.bundleID == bundleID && activeIDs.contains($0.projectID ?? UUID()) }
            if matches.count >= 3 {
                if let best = mostCommonProject(in: matches), best.ratio >= 0.6 {
                    return ProjectPrediction(project: best.project, confidence: 0.55,
                                             reason: "app: \(ctx.app?.name ?? bundleID)", source: "predicted")
                }
            }
        }

        return fallback(reason: "no-match")
    }

    /// When the user tags a previously-untagged entry in History, offer to tag the
    /// other untagged entries that share a strong signal. Returns matches grouped
    /// by signal so the UI can describe what's being propagated.
    static func findPropagationCandidates(for seed: TranscriptionEntry) -> (gitRemote: [TranscriptionEntry], browserHost: [TranscriptionEntry], bundleID: [TranscriptionEntry]) {
        let pool = HistoryManager.shared.getEntries().filter { $0.projectID == nil && $0.id != seed.id }
        var git: [TranscriptionEntry] = []
        var host: [TranscriptionEntry] = []
        var bundle: [TranscriptionEntry] = []

        if let remote = seed.signals?.gitRemote, !remote.isEmpty {
            let key = normalize(remote)
            git = pool.filter { normalize($0.signals?.gitRemote ?? "") == key }
        }
        if let url = seed.signals?.browserURL, let h = urlHost(url) {
            host = pool.filter {
                guard let otherURL = $0.signals?.browserURL, let otherHost = urlHost(otherURL) else { return false }
                return otherHost == h
            }
        }
        if let bID = seed.app?.bundleID {
            bundle = pool.filter { $0.app?.bundleID == bID }
        }
        return (git, host, bundle)
    }

    // MARK: helpers

    private static func fallback(reason: String) -> ProjectPrediction {
        let config = Config.load()
        if let idStr = config?.lastUsedProjectID, !idStr.isEmpty, let uuid = UUID(uuidString: idStr),
           let p = ProjectStore.shared.byID(uuid), !p.archived {
            return ProjectPrediction(project: p, confidence: 0.30, reason: "last-used", source: "last-used")
        }
        return ProjectPrediction(project: nil, confidence: 0.0, reason: reason, source: "none")
    }

    private static func mostCommonProject(in entries: [TranscriptionEntry]) -> (project: Project, count: Int, ratio: Double)? {
        var counts: [UUID: Int] = [:]
        var total = 0
        for e in entries {
            if let id = e.projectID { counts[id, default: 0] += 1; total += 1 }
        }
        guard total > 0,
              let (winnerID, winnerCount) = counts.max(by: { $0.value < $1.value }),
              let project = ProjectStore.shared.byID(winnerID) else { return nil }
        return (project, winnerCount, Double(winnerCount) / Double(total))
    }

    private static func normalize(_ remote: String) -> String {
        var s = remote.lowercased().trimmingCharacters(in: .whitespaces)
        // Strip .git suffix, prefixes, protocol variations
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        s = s.replacingOccurrences(of: "https://", with: "")
        s = s.replacingOccurrences(of: "http://", with: "")
        s = s.replacingOccurrences(of: "ssh://", with: "")
        s = s.replacingOccurrences(of: "git@", with: "")
        s = s.replacingOccurrences(of: ":", with: "/")  // github.com:user/repo → github.com/user/repo
        return s
    }

    private static func urlHost(_ urlString: String) -> String? {
        guard let u = URL(string: urlString), let host = u.host else { return nil }
        return host.lowercased()
    }
}

extension TranscriptionEntry {
    /// Convenience accessor — project tag is stored in extras for backward compat.
    var projectID: UUID? {
        guard let s = extras?["projectID"], let id = UUID(uuidString: s) else { return nil }
        return id
    }
    var projectName: String? { extras?["projectName"] }

    /// Return a copy with the project tag set (or cleared if nil).
    func tagged(with project: Project?, source: String) -> TranscriptionEntry {
        var copy = self
        var newExtras = copy.extras ?? [:]
        if let project = project {
            newExtras["projectID"] = project.id.uuidString
            newExtras["projectName"] = project.name
            newExtras["projectSource"] = source
        } else {
            newExtras.removeValue(forKey: "projectID")
            newExtras.removeValue(forKey: "projectName")
            newExtras.removeValue(forKey: "projectSource")
        }
        copy.extras = newExtras.isEmpty ? nil : newExtras
        return copy
    }
}

// MARK: - History Window

class HistoryWindow: NSObject, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var searchField: NSSearchField!
    private var projectFilterPopup: NSPopUpButton!
    /// Selected filter: nil = all, "untagged" = only entries without a project,
    /// or a UUID string for a specific project.
    private var projectFilterKey: String? = nil
    private var tableView: NSTableView!
    private var entries: [TranscriptionEntry] = []
    private var filteredEntries: [TranscriptionEntry] = []

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcription History"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)

        guard let contentView = window.contentView else { return }

        // Search field (left)
        searchField = NSSearchField(frame: NSRect(x: 16, y: 410, width: 358, height: 28))
        searchField.placeholderString = "Search transcriptions..."
        searchField.delegate = self
        contentView.addSubview(searchField)

        // Project filter popup (right)
        projectFilterPopup = NSPopUpButton(frame: NSRect(x: 384, y: 410, width: 200, height: 28))
        projectFilterPopup.target = self
        projectFilterPopup.action = #selector(projectFilterChanged)
        contentView.addSubview(projectFilterPopup)
        reloadProjectFilterPopup()

        // Table view with scroll
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 50, width: 568, height: 350))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 60
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(copySelectedEntry)
        tableView.target = self

        // Columns
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Transcription"
        textColumn.width = 380
        textColumn.minWidth = 200
        textColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(textColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date"
        dateColumn.width = 150
        dateColumn.minWidth = 150
        dateColumn.maxWidth = 150
        dateColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(dateColumn)

        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // Right-click menu (dynamic — built on open)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        // Buttons
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copySelectedEntry))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: 16, y: 12, width: 80, height: 28)
        contentView.addSubview(copyButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedEntry))
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 104, y: 12, width: 80, height: 28)
        contentView.addSubview(deleteButton)

        let clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAllHistory))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 504, y: 12, width: 80, height: 28)
        contentView.addSubview(clearButton)
    }

    func show() {
        reloadData()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reloadData() {
        entries = HistoryManager.shared.getEntries()
        applyFilters()
    }

    private func applyFilters() {
        let search = searchField?.stringValue.lowercased() ?? ""
        let key = projectFilterKey
        filteredEntries = entries.filter { e in
            // Project filter
            if let key = key {
                if key == "untagged" {
                    if e.projectID != nil { return false }
                } else {
                    guard let pid = e.projectID?.uuidString, pid == key else { return false }
                }
            }
            // Text filter
            if !search.isEmpty, !e.text.lowercased().contains(search) { return false }
            return true
        }
        tableView.reloadData()
    }

    private func reloadProjectFilterPopup() {
        let prior = projectFilterKey
        projectFilterPopup.removeAllItems()

        let allItem = NSMenuItem(title: "All projects", action: nil, keyEquivalent: "")
        allItem.representedObject = nil as String?
        projectFilterPopup.menu?.addItem(allItem)

        let untaggedItem = NSMenuItem(title: "Untagged", action: nil, keyEquivalent: "")
        untaggedItem.representedObject = "untagged"
        projectFilterPopup.menu?.addItem(untaggedItem)

        projectFilterPopup.menu?.addItem(.separator())

        for project in ProjectStore.shared.active {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.representedObject = project.id.uuidString
            projectFilterPopup.menu?.addItem(item)
        }

        // Restore prior selection
        if let prior = prior, let match = projectFilterPopup.menu?.items.first(where: { ($0.representedObject as? String) == prior }) {
            projectFilterPopup.select(match)
        } else {
            projectFilterPopup.selectItem(at: 0)
            projectFilterKey = nil
        }
    }

    @objc private func projectFilterChanged() {
        projectFilterKey = projectFilterPopup.selectedItem?.representedObject as? String
        applyFilters()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredEntries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredEntries.count, let column = tableColumn else { return nil }
        let entry = filteredEntries[row]

        let cellIdentifier = column.identifier
        var cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView

        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = cellIdentifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.truncatesLastVisibleLine = true
            textField.maximumNumberOfLines = 2
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(textField)
            cellView?.textField = textField

            // Use constraints for proper sizing
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
            ])
        }

        if column.identifier.rawValue == "text" {
            cellView?.textField?.stringValue = entry.text
            cellView?.textField?.font = NSFont.systemFont(ofSize: 12)
            cellView?.textField?.textColor = .labelColor
        } else if column.identifier.rawValue == "date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            cellView?.textField?.stringValue = formatter.string(from: entry.timestamp)
            cellView?.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.textField?.alignment = .right
        }

        return cellView
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilters()
    }

    // MARK: - NSMenuDelegate (right-click on entries)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0 && row < filteredEntries.count else { return }
        let entry = filteredEntries[row]

        let header = NSMenuItem(title: entry.projectName.map { "Tagged: \($0)" } ?? "Untagged", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let tagAs = NSMenuItem(title: "Tag as…", action: nil, keyEquivalent: "")
        let tagMenu = NSMenu()
        for project in ProjectStore.shared.active {
            let it = NSMenuItem(title: project.name, action: #selector(tagEntryAs(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ["entryID": entry.id.uuidString, "projectID": project.id.uuidString]
            if entry.projectID == project.id { it.state = .on }
            tagMenu.addItem(it)
        }
        if !ProjectStore.shared.active.isEmpty { tagMenu.addItem(.separator()) }
        let create = NSMenuItem(title: "Create new project…", action: #selector(createAndTagEntry(_:)), keyEquivalent: "")
        create.target = self
        create.representedObject = entry.id.uuidString
        tagMenu.addItem(create)
        tagAs.submenu = tagMenu
        menu.addItem(tagAs)

        if entry.projectID != nil {
            let untag = NSMenuItem(title: "Untag", action: #selector(untagEntry(_:)), keyEquivalent: "")
            untag.target = self
            untag.representedObject = entry.id.uuidString
            menu.addItem(untag)
        }

        menu.addItem(.separator())

        let copyItem = NSMenuItem(title: "Copy text", action: #selector(copyRow(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.representedObject = entry.id.uuidString
        menu.addItem(copyItem)

        let del = NSMenuItem(title: "Delete", action: #selector(deleteRow(_:)), keyEquivalent: "")
        del.target = self
        del.representedObject = entry.id.uuidString
        menu.addItem(del)
    }

    @objc private func tagEntryAs(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let entryIDStr = payload["entryID"], let entryID = UUID(uuidString: entryIDStr),
              let projectIDStr = payload["projectID"], let projectID = UUID(uuidString: projectIDStr),
              let entry = entries.first(where: { $0.id == entryID }),
              let project = ProjectStore.shared.byID(projectID) else { return }
        applyTag(to: entry, project: project)
    }

    @objc private func untagEntry(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        let updated = entry.tagged(with: nil, source: "manual")
        HistoryManager.shared.updateEntry(updated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
    }

    @objc private func createAndTagEntry(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "New project"
        alert.informativeText = "Enter a name for the new project:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let project = ProjectStore.shared.create(name: name)
        applyTag(to: entry, project: project)
    }

    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    @objc private func deleteRow(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr) else { return }
        HistoryManager.shared.deleteEntry(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
    }

    /// Apply a project to an entry. If the entry was previously untagged, offer to
    /// propagate the tag to other untagged entries with matching signals.
    private func applyTag(to entry: TranscriptionEntry, project: Project) {
        let wasUntagged = entry.projectID == nil
        let updated = entry.tagged(with: project, source: "manual")
        HistoryManager.shared.updateEntry(updated)
        reloadProjectFilterPopup()

        if wasUntagged {
            let candidates = ProjectPredictor.findPropagationCandidates(for: entry)
            promptPropagation(project: project, candidates: candidates)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
        }
    }

    private func promptPropagation(project: Project, candidates: (gitRemote: [TranscriptionEntry], browserHost: [TranscriptionEntry], bundleID: [TranscriptionEntry])) {
        // Pick the tightest signal that has matches.
        let matches: [TranscriptionEntry]
        let desc: String
        if !candidates.gitRemote.isEmpty {
            matches = candidates.gitRemote; desc = "same gitRemote"
        } else if !candidates.browserHost.isEmpty {
            matches = candidates.browserHost; desc = "same website"
        } else if !candidates.bundleID.isEmpty {
            matches = candidates.bundleID; desc = "same app"
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Tag \(matches.count) other untagged entr\(matches.count == 1 ? "y" : "ies") with \(project.name)?"
        alert.informativeText = "They share the \(desc). You can always change them later."
        alert.addButton(withTitle: "Tag all")
        alert.addButton(withTitle: "Only this one")
        alert.alertStyle = .informational
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            let updates = matches.map { $0.tagged(with: project, source: "retro") }
            HistoryManager.shared.updateEntries(updates)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
    }

    // MARK: - Actions

    @objc private func copySelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else {
            if !filteredEntries.isEmpty {
                // Copy first entry if nothing selected
                copyToClipboard(filteredEntries[0].text)
            }
            return
        }
        copyToClipboard(filteredEntries[row].text)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        NSSound(named: "Pop")?.play()
    }

    @objc private func deleteSelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else { return }

        let entry = filteredEntries[row]
        HistoryManager.shared.deleteEntry(id: entry.id)
        reloadData()
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This will permanently delete all transcription history. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            HistoryManager.shared.clearHistory()
            reloadData()
        }
    }
}

// MARK: - Audio Recorder

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var tempFileURL: URL?

    var isRecording: Bool {
        return audioRecorder?.isRecording ?? false
    }

    /// Get current audio level (0.0 to 1.0) for waveform visualization
    var currentLevel: Float {
        guard let recorder = audioRecorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        // Convert decibels (-160 to 0) to linear (0 to 1)
        let minDb: Float = -60
        let level = max(0, (decibels - minDb) / (-minDb))
        return min(1, level)
    }

    func startRecording() -> Bool {
        // Make sure mic permission is granted; on .notDetermined, trigger the macOS
        // system prompt. First call returns false but macOS will show the prompt —
        // user grants, next press works normally.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                LogManager.shared.log("[AudioRecorder] Mic permission \(granted ? "granted" : "denied") after prompt")
            }
            LogManager.shared.log("[AudioRecorder] Requesting mic permission — accept the macOS prompt then try again", level: "WARN")
            return false
        case .denied, .restricted:
            LogManager.shared.log("[AudioRecorder] Mic permission denied — open System Settings > Privacy > Microphone to grant", level: "ERROR")
            return false
        case .authorized:
            break
        @unknown default:
            break
        }

        let tempDir = FileManager.default.temporaryDirectory
        tempFileURL = tempDir.appendingPathComponent("whisper_recording_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: tempFileURL!, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true  // Enable metering for waveform
            audioRecorder?.record()
            return true
        } catch {
            print("Failed to start recording: \(error)")
            return false
        }
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempFileURL = nil
    }
}

// MARK: - Waveform View

class WaveformView: NSView {
    private var levels: [CGFloat] = Array(repeating: 0, count: 48)
    private var currentIndex = 0
    private var smoothedLevels: [CGFloat] = Array(repeating: 0, count: 48)

    var baseColor: NSColor = NSColor.systemRed
    var accentColor: NSColor = NSColor.systemOrange

    func addLevel(_ level: Float) {
        levels[currentIndex] = CGFloat(level)

        // Smooth the levels for nicer animation
        for i in 0..<smoothedLevels.count {
            let target = levels[i]
            let current = smoothedLevels[i]
            // Fast rise, slow fall for natural look
            if target > current {
                smoothedLevels[i] = current + (target - current) * 0.6
            } else {
                smoothedLevels[i] = current + (target - current) * 0.12
            }
        }

        currentIndex = (currentIndex + 1) % levels.count
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: 0, count: levels.count)
        smoothedLevels = Array(repeating: 0, count: smoothedLevels.count)
        currentIndex = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(bounds)

        // Draw bars - sleek design
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 3
        let totalBarWidth = barWidth + barSpacing
        let numBars = smoothedLevels.count
        let startX = (bounds.width - CGFloat(numBars) * totalBarWidth) / 2
        let minHeight: CGFloat = 4
        let maxHeight = bounds.height

        for i in 0..<numBars {
            let displayIndex = (currentIndex + i) % numBars
            let level = smoothedLevels[displayIndex]

            // More dramatic height variation with curve
            let boostedLevel = pow(level, 0.6)  // Boost low levels for visibility
            let barHeight = max(minHeight, boostedLevel * maxHeight)
            let x = startX + CGFloat(i) * totalBarWidth
            let y = (bounds.height - barHeight) / 2

            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)

            // Gradient color based on level - red to orange to yellow for peaks
            let color: NSColor
            if level > 0.7 {
                // Peak - bright orange/yellow
                color = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
            } else if level > 0.4 {
                // Medium-high - orange blend
                let t = (level - 0.4) / 0.3
                color = NSColor(
                    red: 0.9 + 0.1 * t,
                    green: 0.3 + 0.3 * t,
                    blue: 0.2,
                    alpha: 1.0
                )
            } else {
                // Low to medium - base red
                color = baseColor
            }

            // Subtle glow for high levels
            if level > 0.5 {
                let glowRect = barRect.insetBy(dx: -1.5, dy: -1.5)
                let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: (barWidth + 3) / 2, yRadius: (barWidth + 3) / 2)
                color.withAlphaComponent(0.25).setFill()
                glowPath.fill()
            }

            // Main bar with rounded caps
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            color.setFill()
            path.fill()
        }
    }
}

// MARK: - Recording Window

class RecordingWindow: NSObject {
    private var window: NSPanel!
    private var waveformView: WaveformView!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var timerLabel: NSTextField!
    private var stopButton: NSButton!
    private var cancelButton: NSButton!
    private var modeSelector: ModeSelectorView!
    private var projectChip: ProjectChipView!
    private var projectPicker: NSPopover?

    /// Called when user picks a different project (or nil = untag) for the
    /// current recording. AppDelegate uses this to update its pending tag.
    var onProjectChanged: ((Project?, String) -> Void)?

    private var updateTimer: Timer?
    private var recordingStartTime: Date?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var audioLevelProvider: (() -> Float)?
    var onModeChanged: ((ProcessingMode) -> Void)?

    enum RecordingStatus {
        case recording
        case processing
        case completed
    }

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        // Create floating panel — taller to fit mode selector and project chip.
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 216),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = NSColor(white: 0.08, alpha: 0.95)
        window.hasShadow = true

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 14

        // Waveform view at top (below title bar area)
        waveformView = WaveformView(frame: NSRect(x: 16, y: 156, width: 328, height: 45))
        contentView.addSubview(waveformView)

        // Status row: dot + label + timer
        statusDot = NSView(frame: NSRect(x: 16, y: 132, width: 10, height: 10))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        contentView.addSubview(statusDot)

        statusLabel = NSTextField(labelWithString: "Recording")
        statusLabel.frame = NSRect(x: 32, y: 129, width: 120, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        contentView.addSubview(statusLabel)

        timerLabel = NSTextField(labelWithString: "0:00")
        timerLabel.frame = NSRect(x: 290, y: 129, width: 55, height: 18)
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        timerLabel.alignment = .right
        contentView.addSubview(timerLabel)

        // Mode selector
        modeSelector = ModeSelectorView(frame: NSRect(x: 12, y: 88, width: 336, height: 36))
        modeSelector.onModeChanged = { [weak self] index in
            let mode = ModeManager.shared.modes[index]
            self?.onModeChanged?(mode)
        }
        contentView.addSubview(modeSelector)

        // Project chip — between mode selector and action buttons
        projectChip = ProjectChipView(frame: NSRect(x: 12, y: 48, width: 336, height: 30))
        projectChip.onClick = { [weak self] in self?.showProjectPicker() }
        contentView.addSubview(projectChip)

        // Cancel button
        cancelButton = NSButton(frame: NSRect(x: 16, y: 12, width: 80, height: 28))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1b}"  // Escape key
        contentView.addSubview(cancelButton)

        // Stop button
        stopButton = NSButton(frame: NSRect(x: 264, y: 12, width: 80, height: 28))
        stopButton.title = "Stop"
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.keyEquivalent = "\r"  // Enter key
        contentView.addSubview(stopButton)
    }

    func show() {
        recordingStartTime = Date()
        waveformView.reset()
        modeSelector.updateSelection(animated: false)
        setStatus(.recording)

        // Position at top center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - window.frame.width / 2
            let y = screenFrame.maxY - window.frame.height - 50
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.orderFront(nil)

        // Start update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateWaveform()
        }

        // Play start sound
        playSound(named: "Tink")
    }

    func hide() {
        updateTimer?.invalidate()
        updateTimer = nil
        window.orderOut(nil)
    }

    func setStatus(_ status: RecordingStatus) {
        switch status {
        case .recording:
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = "Recording"
            waveformView.baseColor = NSColor.systemRed
            waveformView.accentColor = NSColor.systemOrange
            startPulsingDot()
        case .processing:
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            let mode = ModeManager.shared.currentMode
            statusLabel.stringValue = mode.requiresProcessing ? "Processing (\(mode.name))..." : "Transcribing..."
            waveformView.baseColor = NSColor.systemBlue
            waveformView.accentColor = NSColor.systemCyan
            stopPulsingDot()
        case .completed:
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "Done"
            waveformView.baseColor = NSColor.systemGreen
            waveformView.accentColor = NSColor.systemGreen
            stopPulsingDot()
            // Play completion sound
            playSound(named: "Glass")
        }
    }

    func cycleMode() {
        modeSelector.cycleMode()
    }

    private func updateWaveform() {
        // Update waveform with current audio level
        if let level = audioLevelProvider?() {
            waveformView.addLevel(level)
        }

        // Update timer
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            timerLabel.stringValue = String(format: "%d:%02d", minutes, seconds)
        }
    }

    private var pulseTimer: Timer?

    private func startPulsingDot() {
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let dot = self?.statusDot else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                dot.animator().alphaValue = 0.3
            }, completionHandler: {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.4
                    dot.animator().alphaValue = 1.0
                })
            })
        }
    }

    private func stopPulsingDot() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusDot.alphaValue = 1.0
    }

    private func playSound(named name: String) {
        NSSound(named: name)?.play()
    }

    @objc private func stopClicked() {
        hide()
        onStop?()
    }

    @objc private func cancelClicked() {
        hide()
        onCancel?()
    }

    // MARK: - Project tagging

    func setProject(_ project: Project?, reason: String, confidence: Double) {
        projectChip?.set(project: project, reason: reason, confidence: confidence)
    }

    private func showProjectPicker() {
        guard let chip = projectChip else { return }
        let picker = ProjectPickerViewController(
            current: chip.currentProject,
            onPick: { [weak self] project, source in
                self?.projectPicker?.performClose(nil)
                self?.projectPicker = nil
                let reason = project == nil ? "cleared" : "manual"
                self?.projectChip?.set(project: project, reason: reason, confidence: 1.0)
                self?.onProjectChanged?(project, source)
            }
        )
        let popover = NSPopover()
        popover.contentViewController = picker
        popover.behavior = .transient
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY)
        projectPicker = popover
    }
}

// MARK: - Project chip + picker

/// Small pill shown inside RecordingWindow. Click opens the picker popover.
class ProjectChipView: NSView {
    private(set) var currentProject: Project?
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        set(project: nil, reason: "no-signal", confidence: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.16).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func set(project: Project?, reason: String, confidence: Double) {
        currentProject = project
        let muted = NSColor.white.withAlphaComponent(0.5)
        let primary = NSColor.white
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "in: ", attributes: [.foregroundColor: muted]))
        if let project = project {
            let dotColor = project.color.flatMap { NSColor.fromHex($0) } ?? NSColor.systemGreen
            attr.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dotColor]))
            attr.append(NSAttributedString(string: project.name, attributes: [.foregroundColor: primary]))
            if confidence > 0 && reason != "manual" && reason != "cleared" {
                let hint = reason == "last-used" ? "   (last-used)" : "   \(Int(confidence * 100))%"
                attr.append(NSAttributedString(string: hint, attributes: [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 11)]))
            }
        } else {
            attr.append(NSAttributedString(string: "(untagged)   click to pick", attributes: [.foregroundColor: muted]))
        }
        label.attributedStringValue = attr
    }
}

/// Floating picker. NSTableView of active projects + search field that doubles
/// as "Create new…" input (⏎ creates when name is new). "Untag" button clears.
class ProjectPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let current: Project?
    private let onPick: (Project?, String) -> Void

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let untagButton = NSButton(title: "Untag", target: nil, action: nil)
    private var filtered: [Project] = []

    init(current: Project?, onPick: @escaping (Project?, String) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 320))

        searchField.placeholderString = "Filter or type to create…"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchEnter)
        searchField.frame = NSRect(x: 10, y: 280, width: 260, height: 24)
        root.addSubview(searchField)

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 46, width: 260, height: 228))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView.headerView = nil
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        col.width = 240
        tableView.addTableColumn(col)
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        scroll.documentView = tableView
        root.addSubview(scroll)

        untagButton.target = self
        untagButton.action = #selector(untagClicked)
        untagButton.bezelStyle = .rounded
        untagButton.frame = NSRect(x: 10, y: 10, width: 80, height: 28)
        root.addSubview(untagButton)

        let createLabel = NSTextField(labelWithString: "⏎ creates if name is new")
        createLabel.textColor = .secondaryLabelColor
        createLabel.font = NSFont.systemFont(ofSize: 10)
        createLabel.frame = NSRect(x: 100, y: 14, width: 170, height: 20)
        root.addSubview(createLabel)

        self.view = root
        refreshList()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.searchField)
        }
    }

    private func refreshList() {
        let query = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        let all = ProjectStore.shared.active
        if query.isEmpty { filtered = all } else { filtered = all.filter { $0.name.lowercased().contains(query) } }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tv: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: filtered[row].name)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if filtered[row].id == current?.id {
            tf.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        return cell
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filtered.count else { return }
        onPick(filtered[row], "manual")
    }

    @objc private func untagClicked() {
        onPick(nil, "manual")
    }

    @objc private func searchEnter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return }
        if let existing = ProjectStore.shared.byName(query) {
            onPick(existing, "manual")
        } else {
            let created = ProjectStore.shared.create(name: query)
            onPick(created, "manual")
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshList()
    }
}

extension NSColor {
    /// Parse "#rrggbb" or "rrggbb" into an NSColor, nil on malformed input.
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Transcription Provider Protocol

protocol TranscriptionProvider {
    var providerId: String { get }
    var displayName: String { get }
    var apiKeyHelpUrl: URL { get }

    func validateApiKeyFormat(_ apiKey: String) -> (valid: Bool, errorMessage: String?)
    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void)
    func transcribe(audioURL: URL, prompt: String?, completion: @escaping (Result<String, Error>) -> Void)
}

extension TranscriptionProvider {
    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        transcribe(audioURL: audioURL, prompt: nil, completion: completion)
    }
}

// MARK: - Provider Info (for UI)

struct ProviderInfo {
    let id: String
    let displayName: String
    let apiKeyHelpUrl: URL
}

// MARK: - Base Transcription Provider

class BaseTranscriptionProvider {
    let apiKey: String
    let maxRetries = 3
    let minFileSizeBytes = 1000

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func createSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    func validateAudioFile(_ url: URL) -> Error? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int else {
            return NSError(domain: "TranscriptionProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read audio file"])
        }

        LogManager.shared.log("Audio file size: \(fileSize) bytes")

        if fileSize < minFileSizeBytes {
            LogManager.shared.log("Audio file too small, likely empty recording", level: "WARNING")
            return NSError(domain: "TranscriptionProvider", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Recording too short"])
        }
        return nil
    }

    func createMultipartBody(boundary: String, audioData: Data, model: String, prompt: String? = nil) -> Data {
        var body = Data()

        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Prompt field (custom vocabulary)
        if let prompt = prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

// MARK: - OpenAI Provider

class OpenAIProvider: BaseTranscriptionProvider, TranscriptionProvider {
    var providerId: String { "openai" }
    var displayName: String { "OpenAI Whisper" }
    var apiKeyHelpUrl: URL { URL(string: "https://platform.openai.com/api-keys")! }

    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let model = "gpt-4o-mini-transcribe"

    func validateApiKeyFormat(_ apiKey: String) -> (valid: Bool, errorMessage: String?) {
        if apiKey.isEmpty {
            return (false, "API key is required.")
        }
        if !apiKey.hasPrefix("sk-") {
            return (false, "OpenAI API key should start with 'sk-'")
        }
        return (true, nil)
    }

    func transcribe(audioURL: URL, prompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        transcribeWithRetry(audioURL: audioURL, prompt: prompt, attempt: 1, completion: completion)
    }

    private func transcribeWithRetry(audioURL: URL, prompt: String?, attempt: Int, completion: @escaping (Result<String, Error>) -> Void) {
        LogManager.shared.log("[\(self.displayName)] Transcription attempt \(attempt)/\(self.maxRetries)")

        if let error = validateAudioFile(audioURL) {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(.failure(NSError(domain: "OpenAI", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot read audio file"])))
            return
        }

        request.httpBody = createMultipartBody(boundary: boundary, audioData: audioData, model: model, prompt: prompt)

        LogManager.shared.log("[\(self.displayName)] Sending request (attempt \(attempt))...")

        let session = createSession()
        session.dataTask(with: request) { [weak self] data, response, error in
            session.invalidateAndCancel()

            guard let self = self else { return }

            if let error = error {
                LogManager.shared.log("[\(self.displayName)] Request failed (attempt \(attempt)): \(error.localizedDescription)", level: "ERROR")

                if attempt < self.maxRetries {
                    LogManager.shared.log("[\(self.displayName)] Retrying in 1 second...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.transcribeWithRetry(audioURL: audioURL, prompt: prompt, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(.failure(error))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.log("[\(self.displayName)] Response status: \(httpResponse.statusCode)")

                if httpResponse.statusCode >= 500 && attempt < self.maxRetries {
                    LogManager.shared.log("[\(self.displayName)] Server error, retrying...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.transcribeWithRetry(audioURL: audioURL, prompt: prompt, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "OpenAI", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    LogManager.shared.log("[\(self.displayName)] Transcription successful")
                    completion(.success(text))
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "Unknown error"
                    LogManager.shared.log("[\(self.displayName)] API error: \(responseStr)", level: "ERROR")
                    completion(.failure(NSError(domain: "OpenAI", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: responseStr])))
                }
            } catch {
                LogManager.shared.log("[\(self.displayName)] JSON parsing error: \(error.localizedDescription)", level: "ERROR")
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Mistral Provider

class MistralProvider: BaseTranscriptionProvider, TranscriptionProvider {
    var providerId: String { "mistral" }
    var displayName: String { "Mistral Voxtral" }
    var apiKeyHelpUrl: URL { URL(string: "https://console.mistral.ai/api-keys")! }

    private let endpoint = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!
    private let model = "voxtral-mini-latest"

    func validateApiKeyFormat(_ apiKey: String) -> (valid: Bool, errorMessage: String?) {
        if apiKey.isEmpty {
            return (false, "API key is required.")
        }
        if apiKey.count < 10 {
            return (false, "Mistral API key appears too short.")
        }
        return (true, nil)
    }

    func transcribe(audioURL: URL, prompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        transcribeWithRetry(audioURL: audioURL, prompt: prompt, attempt: 1, completion: completion)
    }

    private func transcribeWithRetry(audioURL: URL, prompt: String?, attempt: Int, completion: @escaping (Result<String, Error>) -> Void) {
        LogManager.shared.log("[\(self.displayName)] Transcription attempt \(attempt)/\(self.maxRetries)")

        if let error = validateAudioFile(audioURL) {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Mistral uses x-api-key header (NOT Bearer token!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(.failure(NSError(domain: "Mistral", code: -1,
                               userInfo: [NSLocalizedDescriptionKey: "Cannot read audio file"])))
            return
        }

        request.httpBody = createMultipartBody(boundary: boundary, audioData: audioData, model: model, prompt: prompt)

        LogManager.shared.log("[\(self.displayName)] Sending request (attempt \(attempt))...")

        let session = createSession()
        session.dataTask(with: request) { [weak self] data, response, error in
            session.invalidateAndCancel()

            guard let self = self else { return }

            if let error = error {
                LogManager.shared.log("[\(self.displayName)] Request failed (attempt \(attempt)): \(error.localizedDescription)", level: "ERROR")

                if attempt < self.maxRetries {
                    LogManager.shared.log("[\(self.displayName)] Retrying in 1 second...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.transcribeWithRetry(audioURL: audioURL, prompt: prompt, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(.failure(error))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.log("[\(self.displayName)] Response status: \(httpResponse.statusCode)")

                if httpResponse.statusCode >= 500 && attempt < self.maxRetries {
                    LogManager.shared.log("[\(self.displayName)] Server error, retrying...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.transcribeWithRetry(audioURL: audioURL, prompt: prompt, attempt: attempt + 1, completion: completion)
                    }
                    return
                }
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "Mistral", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    LogManager.shared.log("[\(self.displayName)] Transcription successful")
                    completion(.success(text))
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "Unknown error"
                    LogManager.shared.log("[\(self.displayName)] API error: \(responseStr)", level: "ERROR")
                    completion(.failure(NSError(domain: "Mistral", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: responseStr])))
                }
            } catch {
                LogManager.shared.log("[\(self.displayName)] JSON parsing error: \(error.localizedDescription)", level: "ERROR")
                completion(.failure(error))
            }
        }.resume()
    }
}

// MARK: - Whisper Model Info

struct WhisperModelInfo {
    let id: String
    let name: String
    let size: String
    let sizeBytes: Int64
    let downloadUrl: URL

    static let available: [WhisperModelInfo] = [
        WhisperModelInfo(
            id: "tiny",
            name: "Tiny",
            size: "75 MB",
            sizeBytes: 75_000_000,
            downloadUrl: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!
        ),
        WhisperModelInfo(
            id: "base",
            name: "Base",
            size: "142 MB",
            sizeBytes: 142_000_000,
            downloadUrl: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!
        ),
        WhisperModelInfo(
            id: "small",
            name: "Small",
            size: "466 MB",
            sizeBytes: 466_000_000,
            downloadUrl: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
        ),
        WhisperModelInfo(
            id: "medium",
            name: "Medium (Recommended)",
            size: "1.5 GB",
            sizeBytes: 1_530_000_000,
            downloadUrl: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!
        ),
        WhisperModelInfo(
            id: "large",
            name: "Large",
            size: "3 GB",
            sizeBytes: 3_090_000_000,
            downloadUrl: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
        )
    ]
}

// MARK: - Whisper Model Manager

class WhisperModelManager {
    static let shared = WhisperModelManager()

    private let modelsDir: URL
    private var downloadTask: URLSessionDownloadTask?
    var onProgress: ((Double, String) -> Void)?
    var onComplete: ((Bool, String?) -> Void)?

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDir = appSupport.appendingPathComponent("WhisperVoice/models")
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }

    var modelsDirectory: URL { modelsDir }

    func modelPath(for modelId: String) -> URL {
        return modelsDir.appendingPathComponent("ggml-\(modelId).bin")
    }

    func isModelDownloaded(_ modelId: String) -> Bool {
        return FileManager.default.fileExists(atPath: modelPath(for: modelId).path)
    }

    func downloadedModels() -> [String] {
        return WhisperModelInfo.available.filter { isModelDownloaded($0.id) }.map { $0.id }
    }

    func downloadModel(_ model: WhisperModelInfo) {
        let destinationPath = modelPath(for: model.id)

        LogManager.shared.log("[ModelManager] Starting download: \(model.name) from \(model.downloadUrl)")

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: nil, delegateQueue: .main)

        downloadTask = session.downloadTask(with: model.downloadUrl) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                LogManager.shared.log("[ModelManager] Download failed: \(error.localizedDescription)", level: "ERROR")
                self.onComplete?(false, error.localizedDescription)
                return
            }

            guard let tempURL = tempURL else {
                self.onComplete?(false, "No file downloaded")
                return
            }

            do {
                // Remove existing file if present
                if FileManager.default.fileExists(atPath: destinationPath.path) {
                    try FileManager.default.removeItem(at: destinationPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationPath)
                LogManager.shared.log("[ModelManager] Download complete: \(destinationPath.path)")
                self.onComplete?(true, nil)
            } catch {
                LogManager.shared.log("[ModelManager] Failed to save model: \(error.localizedDescription)", level: "ERROR")
                self.onComplete?(false, error.localizedDescription)
            }
        }

        // Progress tracking via KVO
        downloadTask?.resume()

        // Poll progress
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let task = self?.downloadTask else {
                timer.invalidate()
                return
            }

            if task.state == .completed || task.state == .canceling {
                timer.invalidate()
                return
            }

            let received = task.countOfBytesReceived
            let total = task.countOfBytesExpectedToReceive
            if total > 0 {
                let progress = Double(received) / Double(total)
                let receivedMB = Double(received) / 1_000_000
                let totalMB = Double(total) / 1_000_000
                let status = String(format: "%.1f / %.1f MB", receivedMB, totalMB)
                self?.onProgress?(progress, status)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }
}

// MARK: - Whisper Server Manager

class WhisperServerManager {
    static let shared = WhisperServerManager()

    private var serverProcess: Process?
    private let serverPort: Int = 8178
    private var isStarting = false

    private init() {}

    var isRunning: Bool {
        return serverProcess?.isRunning ?? false
    }

    var serverURL: URL {
        return URL(string: "http://127.0.0.1:\(serverPort)")!
    }

    /// Get the path to whisper-server (bundled or custom)
    func getServerPath() -> String? {
        // First check bundled binary in app Resources
        if let bundlePath = Bundle.main.resourcePath {
            let bundledServer = "\(bundlePath)/whisper-server"
            if FileManager.default.isExecutableFile(atPath: bundledServer) {
                return bundledServer
            }
        }

        // Check in app's MacOS folder
        if let execPath = Bundle.main.executablePath {
            let macosDir = (execPath as NSString).deletingLastPathComponent
            let serverInMacOS = "\(macosDir)/whisper-server"
            if FileManager.default.isExecutableFile(atPath: serverInMacOS) {
                return serverInMacOS
            }
        }

        // Fallback to config path
        if let config = Config.load(), !config.whisperCliPath.isEmpty {
            // Convert whisper-cli path to whisper-server path
            let serverPath = config.whisperCliPath.replacingOccurrences(of: "whisper-cli", with: "whisper-server")
            if FileManager.default.isExecutableFile(atPath: serverPath) {
                return serverPath
            }
            // Or use CLI path directly if it's actually pointing to server
            if FileManager.default.isExecutableFile(atPath: config.whisperCliPath) {
                return config.whisperCliPath
            }
        }

        return nil
    }

    func startServer(modelPath: String, language: String, completion: @escaping (Bool, String?) -> Void) {
        if isRunning {
            LogManager.shared.log("[WhisperServer] Server already running")
            completion(true, nil)
            return
        }

        if isStarting {
            LogManager.shared.log("[WhisperServer] Server is starting...")
            completion(false, "Server is starting...")
            return
        }

        guard let serverPath = getServerPath() else {
            let error = "whisper-server not found"
            LogManager.shared.log("[WhisperServer] \(error)", level: "ERROR")
            completion(false, error)
            return
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            let error = "Model not found at: \(modelPath)"
            LogManager.shared.log("[WhisperServer] \(error)", level: "ERROR")
            completion(false, error)
            return
        }

        isStarting = true
        LogManager.shared.log("[WhisperServer] Starting server with model: \(modelPath)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: serverPath)
            process.arguments = [
                "-m", modelPath,
                "-l", language,
                "--port", String(self.serverPort),
                "--host", "127.0.0.1"
            ]

            // Redirect output to /dev/null to avoid blocking
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                self.serverProcess = process

                // Wait for server to be ready (poll health endpoint)
                var ready = false
                for _ in 0..<30 {  // 15 seconds max
                    Thread.sleep(forTimeInterval: 0.5)
                    if self.checkServerHealth() {
                        ready = true
                        break
                    }
                }

                self.isStarting = false

                DispatchQueue.main.async {
                    if ready {
                        LogManager.shared.log("[WhisperServer] Server started successfully on port \(self.serverPort)")
                        completion(true, nil)
                    } else {
                        LogManager.shared.log("[WhisperServer] Server failed to become ready", level: "ERROR")
                        self.stopServer()
                        completion(false, "Server failed to start")
                    }
                }
            } catch {
                self.isStarting = false
                LogManager.shared.log("[WhisperServer] Failed to start: \(error.localizedDescription)", level: "ERROR")
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private func checkServerHealth() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isHealthy = false

        var request = URLRequest(url: serverURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                isHealthy = true
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2)

        return isHealthy
    }

    func stopServer() {
        if let process = serverProcess, process.isRunning {
            LogManager.shared.log("[WhisperServer] Stopping server...")
            process.terminate()
            serverProcess = nil
        }
    }

    func transcribe(audioURL: URL, prompt: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let inferenceURL = serverURL.appendingPathComponent("inference")

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(.failure(NSError(domain: "WhisperServer", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "Audio file not found"])))
            return
        }

        guard let audioData = try? Data(contentsOf: audioURL) else {
            completion(.failure(NSError(domain: "WhisperServer", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: "Cannot read audio file"])))
            return
        }

        // Create multipart form data
        let boundary = UUID().uuidString
        var body = Data()

        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Add prompt (custom vocabulary) if provided
        if let prompt = prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(prompt)\r\n".data(using: .utf8)!)
        }

        // Add response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        LogManager.shared.log("[WhisperServer] Sending transcription request...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                LogManager.shared.log("[WhisperServer] Request failed: \(error.localizedDescription)", level: "ERROR")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "WhisperServer", code: -3,
                                               userInfo: [NSLocalizedDescriptionKey: "No response data"])))
                }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    LogManager.shared.log("[WhisperServer] Transcription successful: \(trimmedText.prefix(50))...")
                    DispatchQueue.main.async {
                        completion(.success(trimmedText))
                    }
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "Unknown error"
                    LogManager.shared.log("[WhisperServer] Invalid response: \(responseStr)", level: "ERROR")
                    DispatchQueue.main.async {
                        completion(.failure(NSError(domain: "WhisperServer", code: -4,
                                                   userInfo: [NSLocalizedDescriptionKey: "Invalid response: \(responseStr)"])))
                    }
                }
            } catch {
                LogManager.shared.log("[WhisperServer] JSON parse error: \(error.localizedDescription)", level: "ERROR")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
}

// MARK: - Local Whisper Provider (whisper.cpp server)

class LocalWhisperProvider: TranscriptionProvider {
    var providerId: String { "local" }
    var displayName: String { "Local (whisper.cpp)" }
    var apiKeyHelpUrl: URL { URL(string: "https://github.com/ggerganov/whisper.cpp")! }

    private let modelPath: String
    private let language: String
    private let serverManager = WhisperServerManager.shared

    init(modelPath: String, language: String = "fr") {
        self.modelPath = modelPath
        self.language = language
    }

    // Legacy init for compatibility
    convenience init(cliPath: String, modelPath: String, language: String = "fr") {
        self.init(modelPath: modelPath, language: language)
    }

    func validateApiKeyFormat(_ apiKey: String) -> (valid: Bool, errorMessage: String?) {
        return (true, nil)
    }

    func validateSetup() -> (valid: Bool, errorMessage: String?) {
        // Check server binary exists
        guard serverManager.getServerPath() != nil else {
            return (false, "whisper-server not found. Please download or build it.")
        }

        // Check model exists
        if modelPath.isEmpty {
            return (false, "No model selected. Please download a model in Preferences.")
        }
        if !FileManager.default.fileExists(atPath: modelPath) {
            return (false, "Model not found at: \(modelPath)")
        }

        return (true, nil)
    }

    func transcribe(audioURL: URL, prompt: String?, completion: @escaping (Result<String, Error>) -> Void) {
        LogManager.shared.log("[LocalWhisper] Starting transcription...")

        // Validate setup first
        let validation = validateSetup()
        if !validation.valid {
            LogManager.shared.log("[LocalWhisper] Setup invalid: \(validation.errorMessage ?? "")", level: "ERROR")
            completion(.failure(NSError(domain: "LocalWhisper", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: validation.errorMessage ?? "Invalid setup"])))
            return
        }

        // If server is running, use it directly
        if serverManager.isRunning {
            serverManager.transcribe(audioURL: audioURL, prompt: prompt, completion: completion)
            return
        }

        // Start server and then transcribe
        serverManager.startServer(modelPath: modelPath, language: language) { [weak self] success, error in
            guard let self = self else { return }

            if success {
                self.serverManager.transcribe(audioURL: audioURL, prompt: prompt, completion: completion)
            } else {
                completion(.failure(NSError(domain: "LocalWhisper", code: -2,
                                           userInfo: [NSLocalizedDescriptionKey: error ?? "Failed to start server"])))
            }
        }
    }
}

// MARK: - Transcription Provider Factory

enum TranscriptionProviderFactory {
    static let availableProviders: [ProviderInfo] = [
        ProviderInfo(id: "openai", displayName: "OpenAI Whisper",
                     apiKeyHelpUrl: URL(string: "https://platform.openai.com/api-keys")!),
        ProviderInfo(id: "mistral", displayName: "Mistral Voxtral",
                     apiKeyHelpUrl: URL(string: "https://console.mistral.ai/api-keys")!),
        ProviderInfo(id: "local", displayName: "Local (whisper.cpp)",
                     apiKeyHelpUrl: URL(string: "https://github.com/ggerganov/whisper.cpp")!)
    ]

    static func create(from config: Config) -> TranscriptionProvider {
        let providerId = config.provider
        if providerId == "local" {
            return LocalWhisperProvider(
                cliPath: config.whisperCliPath,
                modelPath: config.whisperModelPath,
                language: config.whisperLanguage
            )
        }
        let apiKey = config.getCurrentApiKey()
        return create(providerId: providerId, apiKey: apiKey)
    }

    static func create(providerId: String, apiKey: String) -> TranscriptionProvider {
        switch providerId.lowercased() {
        case "mistral":
            return MistralProvider(apiKey: apiKey)
        case "local":
            // For direct creation without config, use empty paths (will fail validation)
            return LocalWhisperProvider(cliPath: "", modelPath: "")
        default:
            return OpenAIProvider(apiKey: apiKey)
        }
    }

    static func validateApiKey(providerId: String, apiKey: String) -> (valid: Bool, error: String?) {
        let provider = create(providerId: providerId, apiKey: apiKey)
        let result = provider.validateApiKeyFormat(apiKey)
        return (valid: result.valid, error: result.errorMessage)
    }

    static func getProviderInfo(for providerId: String) -> ProviderInfo? {
        return availableProviders.first { $0.id == providerId }
    }
}

// MARK: - Clipboard & Paste

func pasteText(_ text: String) {
    // Copy to clipboard
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    // Simulate Cmd+V
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

// MARK: - Auto Update

struct UpdateInfo {
    let version: String
    let downloadURL: URL?
    let releaseNotes: String
}

class UpdateChecker {
    static let currentVersion = "3.4.0"
    private static let repoOwner = "hugoblanc"
    private static let repoName = "whisper-voice"

    static func checkForUpdates(completion: @escaping (UpdateInfo?) -> Void) {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Parse version from tag (e.g., "v3.2.0" -> "3.2.0")
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            // Compare versions
            guard isVersion(remoteVersion, newerThan: currentVersion) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Find DMG download URL from assets
            let downloadURL: URL? = {
                guard let assets = json["assets"] as? [[String: Any]] else { return nil }
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                       let urlStr = asset["browser_download_url"] as? String,
                       let url = URL(string: urlStr) {
                        return url
                    }
                }
                return nil
            }()

            let releaseNotes = json["body"] as? String ?? ""

            DispatchQueue.main.async {
                completion(UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: releaseNotes))
            }
        }.resume()
    }

    private static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(parts1.count, parts2.count)

        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
}

class UpdateWindow: NSObject, URLSessionDownloadDelegate {
    private var window: NSWindow!
    private var progressBar: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var downloadButton: NSButton!
    private var laterButton: NSButton!
    private let updateInfo: UpdateInfo
    private var downloadTask: URLSessionDownloadTask?

    init(updateInfo: UpdateInfo) {
        self.updateInfo = updateInfo
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Update Available"
        window.center()
        window.isReleasedWhenClosed = false

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        // Title
        let titleLabel = NSTextField(labelWithString: "Whisper Voice v\(updateInfo.version) is available!")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 15)
        titleLabel.frame = NSRect(x: 20, y: 260, width: 380, height: 25)
        contentView.addSubview(titleLabel)

        let currentLabel = NSTextField(labelWithString: "You are currently running v\(UpdateChecker.currentVersion)")
        currentLabel.font = NSFont.systemFont(ofSize: 12)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.frame = NSRect(x: 20, y: 238, width: 380, height: 20)
        contentView.addSubview(currentLabel)

        // Release notes
        let notesLabel = NSTextField(labelWithString: "Release Notes:")
        notesLabel.font = NSFont.boldSystemFont(ofSize: 12)
        notesLabel.frame = NSRect(x: 20, y: 212, width: 380, height: 18)
        contentView.addSubview(notesLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 90, width: 380, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let notesTextView = NSTextView(frame: scrollView.bounds)
        notesTextView.string = updateInfo.releaseNotes.isEmpty ? "No release notes available." : updateInfo.releaseNotes
        notesTextView.isEditable = false
        notesTextView.font = NSFont.systemFont(ofSize: 12)
        notesTextView.autoresizingMask = [.width, .height]
        scrollView.documentView = notesTextView
        contentView.addSubview(scrollView)

        // Progress bar (hidden initially)
        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 62, width: 380, height: 20))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        contentView.addSubview(progressBar)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 42, width: 380, height: 18)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        contentView.addSubview(statusLabel)

        // Buttons
        laterButton = NSButton(title: "Later", target: self, action: #selector(laterClicked))
        laterButton.bezelStyle = .rounded
        laterButton.frame = NSRect(x: 220, y: 10, width: 80, height: 32)
        contentView.addSubview(laterButton)

        downloadButton = NSButton(title: "Download & Install", target: self, action: #selector(downloadClicked))
        downloadButton.bezelStyle = .rounded
        downloadButton.frame = NSRect(x: 310, y: 10, width: 100, height: 32)
        downloadButton.keyEquivalent = "\r"
        contentView.addSubview(downloadButton)

        if updateInfo.downloadURL == nil {
            downloadButton.isEnabled = false
            statusLabel.stringValue = "No DMG download available for this release."
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func laterClicked() {
        downloadTask?.cancel()
        // Remember skipped version so we don't prompt again until next release
        if var config = Config.load() {
            config.skippedUpdateVersion = updateInfo.version
            config.save()
        }
        window.close()
    }

    @objc private func downloadClicked() {
        guard let downloadURL = updateInfo.downloadURL else { return }

        downloadButton.isEnabled = false
        laterButton.title = "Cancel"
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        statusLabel.stringValue = "Downloading..."

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: downloadURL)
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperVoice-\(updateInfo.version).dmg")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)

        do {
            try FileManager.default.moveItem(at: location, to: destURL)
            statusLabel.stringValue = "Installing update..."
            LogManager.shared.log("[Update] Downloaded update to \(destURL.path)")

            // Auto-install from DMG
            DispatchQueue.global().async { [weak self] in
                self?.installFromDMG(dmgPath: destURL.path)
            }
        } catch {
            statusLabel.stringValue = "Failed to save download: \(error.localizedDescription)"
            downloadButton.isEnabled = true
            LogManager.shared.log("[Update] Failed to save DMG: \(error.localizedDescription)", level: "ERROR")
        }
    }

    private func installFromDMG(dmgPath: String) {
        // 1. Mount DMG silently
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", dmgPath, "-nobrowse", "-plist"]
        let pipe = Pipe()
        mountProcess.standardOutput = pipe
        mountProcess.standardError = FileHandle.nullDevice

        do {
            try mountProcess.run()
        } catch {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Failed to mount DMG."
                self.downloadButton.isEnabled = true
            }
            return
        }
        mountProcess.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()

        // 2. Parse mount point from plist output
        guard let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Failed to find mounted volume."
                self.downloadButton.isEnabled = true
            }
            return
        }

        // 3. Find .app in mounted volume
        let volumeURL = URL(fileURLWithPath: mountPoint)
        let appName = "Whisper Voice.app"
        let sourceApp = volumeURL.appendingPathComponent(appName).path
        let destApp = "/Applications/\(appName)"

        guard FileManager.default.fileExists(atPath: sourceApp) else {
            // Unmount and fail
            Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-quiet"])
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "App not found in DMG."
                self.downloadButton.isEnabled = true
            }
            return
        }

        // 4. Remove old app, copy new one
        do {
            if FileManager.default.fileExists(atPath: destApp) {
                try FileManager.default.removeItem(atPath: destApp)
            }
            try FileManager.default.copyItem(atPath: sourceApp, toPath: destApp)
            LogManager.shared.log("[Update] Installed update to \(destApp)")
        } catch {
            Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-quiet"])
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Failed to install: \(error.localizedDescription)"
                self.downloadButton.isEnabled = true
            }
            return
        }

        // 5. Unmount DMG
        Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-quiet"])

        // 6. UI: propose restart
        DispatchQueue.main.async {
            self.progressBar.isHidden = true
            self.statusLabel.stringValue = "Update installed! Restart to apply."
            self.downloadButton.title = "Restart"
            self.downloadButton.isEnabled = true
            self.downloadButton.target = self
            self.downloadButton.action = #selector(self.restartApp)
            self.laterButton.title = "Later"
        }
    }

    @objc private func restartApp() {
        let appPath = "/Applications/Whisper Voice.app"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appPath]
            try? task.run()
        }
        NSApp.terminate(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressBar.doubleValue = progress
            let mb = Double(totalBytesWritten) / 1_000_000
            let totalMb = Double(totalBytesExpectedToWrite) / 1_000_000
            statusLabel.stringValue = String(format: "Downloading... %.1f / %.1f MB", mb, totalMb)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            statusLabel.stringValue = "Download cancelled."
            progressBar.isHidden = true
            downloadButton.isEnabled = true
            laterButton.title = "Later"
        } else if let error = error {
            statusLabel.stringValue = "Download failed: \(error.localizedDescription)"
            progressBar.isHidden = true
            downloadButton.isEnabled = true
            laterButton.title = "Later"
        }
    }
}

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

    // Permission wizard
    private var permissionWizard: PermissionWizard?

    // Preferences window
    private var preferencesWindow: PreferencesWindow?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "History...", action: #selector(showHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check Permissions...", action: #selector(showPermissionStatus), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""))
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
                processingModel: "gpt-4.1-nano",
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

    private func startRecording(showStopMessage: Bool) {
        LogManager.shared.log("Starting recording (showStopMessage: \(showStopMessage))")

        // Capture dictation context (app, window, URL or terminal cwd/git) before audio starts.
        // Runs off-main; completion arrives asynchronously and attaches to pending entry.
        pendingDictationContext = nil
        ContextCapturer.shared.captureNow { [weak self] ctx in
            guard let self = self else { return }
            self.pendingDictationContext = ctx
            // Predict project from the captured context + history.
            let prediction = ProjectPredictor.predict(ctx: ctx)
            self.pendingProject = prediction.project
            self.pendingProjectSource = prediction.source
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

        // Setup cancel hotkey (Escape) and mode switch (Shift)
        setupCancelHotkey()
        setupModeSwitchMonitor()
    }

    private func stopRecording() {
        LogManager.shared.log("Stopping recording")

        // Remove hotkeys
        removeCancelHotkey()
        removeModeSwitchMonitor()

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
                            self?.finishWithText(text)
                            return
                        }

                        // Process with GPT
                        TextProcessor.shared.process(text: text, mode: mode, context: self?.capturedContext, apiKey: apiKey) { processResult in
                            DispatchQueue.main.async {
                                switch processResult {
                                case .success(let processedText):
                                    LogManager.shared.log("Processing complete: \(processedText.prefix(50))...")
                                    self?.finishWithText(processedText)
                                case .failure(let error):
                                    LogManager.shared.log("Processing failed: \(error.localizedDescription), using raw text", level: "WARNING")
                                    // Fall back to raw transcription
                                    self?.finishWithText(text)
                                }
                            }
                        }
                    } else {
                        // No processing needed, use raw transcription
                        self?.finishWithText(text)
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

    private func finishWithText(_ text: String) {
        // Trim leading/trailing whitespace before pasting
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Save to history
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let provider = config?.provider ?? "unknown"
        let modeName = selectedModeForCurrentRecording?.name ?? "Voice-to-Text"
        let ctx = pendingDictationContext
        pendingDictationContext = nil
        let project = pendingProject
        let projectSource = pendingProjectSource
        pendingProject = nil
        pendingProjectSource = "none"

        var extras = ctx?.extras ?? [:]
        if let project = project {
            extras["projectID"] = project.id.uuidString
            extras["projectName"] = project.name
            extras["projectSource"] = projectSource
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

        // Persist last-used project (even for manual picks and last-used fallbacks)
        // so that it survives restarts and feeds the no-signal fallback next time.
        if let project = project, var cfg = Config.load(), cfg.lastUsedProjectID != project.id.uuidString {
            cfg.lastUsedProjectID = project.id.uuidString
            cfg.save()
        }

        // Play completion sound
        NSSound(named: "Glass")?.play()
        pasteText(trimmedText)

        state = .idle
        updateStatusIcon()
        updateStatus("Idle")
    }

    private func cancelRecording() {
        LogManager.shared.log("Recording cancelled by user")

        // Remove hotkeys
        removeCancelHotkey()
        removeModeSwitchMonitor()

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
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow()
            preferencesWindow?.onSettingsChanged = { [weak self] in
                self?.reloadSettings()
            }
        }
        preferencesWindow?.show()
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
        LogManager.shared.log("Settings reloaded successfully")
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
