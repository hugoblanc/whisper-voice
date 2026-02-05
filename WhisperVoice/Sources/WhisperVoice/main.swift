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

class PreferencesWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var tabView: NSTabView!

    // General tab elements
    private var providerPopup: NSPopUpButton!
    private var apiKeyField: NSSecureTextField!
    private var apiKeyLinkButton: NSButton!
    private var testConnectionButton: NSButton!
    private var connectionStatusLabel: NSTextField!

    // Shortcuts tab elements
    private var toggleShortcutPopup: NSPopUpButton!
    private var pttKeyPopup: NSPopUpButton!

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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
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
        tabView = NSTabView(frame: NSRect(x: 10, y: 50, width: 480, height: 340))
        contentView.addSubview(tabView)

        // Add tabs
        setupGeneralTab()
        setupShortcutsTab()
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

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        // Provider label
        let providerLabel = NSTextField(labelWithString: "Transcription Provider:")
        providerLabel.frame = NSRect(x: 20, y: 250, width: 200, height: 20)
        view.addSubview(providerLabel)

        // Provider popup
        providerPopup = NSPopUpButton(frame: NSRect(x: 20, y: 220, width: 250, height: 26))
        for provider in TranscriptionProviderFactory.availableProviders {
            providerPopup.addItem(withTitle: provider.displayName)
            providerPopup.lastItem?.representedObject = provider
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)
        view.addSubview(providerPopup)

        // API Key label
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 20, y: 180, width: 200, height: 20)
        view.addSubview(apiKeyLabel)

        // API Key field
        apiKeyField = NSSecureTextField(frame: NSRect(x: 20, y: 150, width: 420, height: 26))
        apiKeyField.placeholderString = "sk-..."
        view.addSubview(apiKeyField)

        // API Key link
        apiKeyLinkButton = NSButton(frame: NSRect(x: 20, y: 125, width: 300, height: 20))
        apiKeyLinkButton.bezelStyle = .inline
        apiKeyLinkButton.isBordered = false
        apiKeyLinkButton.target = self
        apiKeyLinkButton.action = #selector(openApiKeyPage)
        updateApiKeyLink(for: TranscriptionProviderFactory.availableProviders.first!)
        view.addSubview(apiKeyLinkButton)

        // Test connection button
        testConnectionButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnectionClicked))
        testConnectionButton.bezelStyle = .rounded
        testConnectionButton.frame = NSRect(x: 20, y: 80, width: 130, height: 32)
        view.addSubview(testConnectionButton)

        // Connection status label
        connectionStatusLabel = NSTextField(labelWithString: "")
        connectionStatusLabel.frame = NSRect(x: 160, y: 85, width: 280, height: 20)
        connectionStatusLabel.textColor = .secondaryLabelColor
        view.addSubview(connectionStatusLabel)

        generalTab.view = view
        tabView.addTabViewItem(generalTab)
    }

    private func setupShortcutsTab() {
        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = "Shortcuts"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        // Toggle shortcut label
        let toggleLabel = NSTextField(labelWithString: "Toggle Recording Shortcut:")
        toggleLabel.frame = NSRect(x: 20, y: 250, width: 200, height: 20)
        view.addSubview(toggleLabel)

        // Toggle shortcut popup
        toggleShortcutPopup = NSPopUpButton(frame: NSRect(x: 20, y: 220, width: 200, height: 26))
        toggleShortcutPopup.addItems(withTitles: ["Option + Space", "Control + Space", "Cmd + Shift + Space"])
        view.addSubview(toggleShortcutPopup)

        // PTT key label
        let pttLabel = NSTextField(labelWithString: "Push-to-Talk Key:")
        pttLabel.frame = NSRect(x: 20, y: 170, width: 200, height: 20)
        view.addSubview(pttLabel)

        // PTT key popup
        pttKeyPopup = NSPopUpButton(frame: NSRect(x: 20, y: 140, width: 200, height: 26))
        pttKeyPopup.addItems(withTitles: ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"])
        view.addSubview(pttKeyPopup)

        // Note
        let noteLabel = NSTextField(wrappingLabelWithString: "Note: Changes take effect immediately after saving.")
        noteLabel.frame = NSRect(x: 20, y: 80, width: 420, height: 40)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = NSFont.systemFont(ofSize: 12)
        view.addSubview(noteLabel)

        shortcutsTab.view = view
        tabView.addTabViewItem(shortcutsTab)
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
            apiKeyField.placeholderString = provider.id == "openai" ? "sk-..." : "Enter API key"
        }

        // API Key
        apiKeyField.stringValue = config.getCurrentApiKey()

        // Toggle shortcut
        let modifiers = config.shortcutModifiers
        if modifiers & UInt32(controlKey) != 0 {
            toggleShortcutPopup.selectItem(at: 1)
        } else if modifiers & UInt32(cmdKey) != 0 && modifiers & UInt32(shiftKey) != 0 {
            toggleShortcutPopup.selectItem(at: 2)
        } else {
            toggleShortcutPopup.selectItem(at: 0)
        }

        // PTT key
        let pttKeyCodes: [UInt32] = [
            UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
            UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
            UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12)
        ]
        if let pttIndex = pttKeyCodes.firstIndex(of: config.pushToTalkKeyCode) {
            pttKeyPopup.selectItem(at: pttIndex)
        }

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
        apiKeyField.placeholderString = provider.id == "openai" ? "sk-..." : "Enter API key"
        connectionStatusLabel.stringValue = ""
    }

    @objc private func openApiKeyPage() {
        guard let provider = providerPopup.selectedItem?.representedObject as? ProviderInfo else { return }
        NSWorkspace.shared.open(provider.apiKeyHelpUrl)
    }

    @objc private func testConnectionClicked() {
        guard let provider = providerPopup.selectedItem?.representedObject as? ProviderInfo else { return }
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

        // Validate API key
        let validation = TranscriptionProviderFactory.validateApiKey(providerId: provider.id, apiKey: apiKey)
        if !validation.valid {
            showError(validation.error ?? "Invalid API key")
            return
        }

        // Parse toggle shortcut
        let modifiers: UInt32
        switch toggleShortcutPopup.indexOfSelectedItem {
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
        let pttKeyCode = pttKeyCodes[pttKeyPopup.indexOfSelectedItem]

        // Create new config
        let newConfig = Config(
            provider: provider.id,
            apiKey: apiKey,
            providerApiKeys: [:],
            shortcutModifiers: modifiers,
            shortcutKeyCode: UInt32(kVK_Space),
            pushToTalkKeyCode: pttKeyCode
        )
        newConfig.save()

        LogManager.shared.log("Settings saved - Provider: \(provider.displayName), Toggle: \(newConfig.toggleShortcutDescription()), PTT: \(newConfig.pushToTalkDescription())")

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

    var provider: String           // "openai" or "mistral"
    var apiKey: String             // Main API key (backward compatibility)
    var providerApiKeys: [String: String]  // Per-provider API keys
    var shortcutModifiers: UInt32  // e.g., optionKey
    var shortcutKeyCode: UInt32    // e.g., kVK_Space
    var pushToTalkKeyCode: UInt32  // e.g., kVK_F3

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = json["apiKey"] as? String else {
            return nil
        }

        // Backward compatible loading
        let provider = json["provider"] as? String ?? "openai"
        let providerApiKeys = json["providerApiKeys"] as? [String: String] ?? [:]
        let modifiers = json["shortcutModifiers"] as? UInt32 ?? UInt32(optionKey)
        let keyCode = json["shortcutKeyCode"] as? UInt32 ?? UInt32(kVK_Space)
        let pttKeyCode = json["pushToTalkKeyCode"] as? UInt32 ?? UInt32(kVK_F3)

        return Config(
            provider: provider,
            apiKey: apiKey,
            providerApiKeys: providerApiKeys,
            shortcutModifiers: modifiers,
            shortcutKeyCode: keyCode,
            pushToTalkKeyCode: pttKeyCode
        )
    }

    func save() {
        var json: [String: Any] = [
            "provider": provider,
            "apiKey": apiKey,
            "shortcutModifiers": shortcutModifiers,
            "shortcutKeyCode": shortcutKeyCode,
            "pushToTalkKeyCode": pushToTalkKeyCode
        ]
        if !providerApiKeys.isEmpty {
            json["providerApiKeys"] = providerApiKeys
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
    default: return "Key(\(keyCode))"
    }
}

// MARK: - Audio Recorder

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var tempFileURL: URL?

    var isRecording: Bool {
        return audioRecorder?.isRecording ?? false
    }

    func startRecording() -> Bool {
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

// MARK: - Transcription Provider Protocol

protocol TranscriptionProvider {
    var providerId: String { get }
    var displayName: String { get }
    var apiKeyHelpUrl: URL { get }

    func validateApiKeyFormat(_ apiKey: String) -> (valid: Bool, errorMessage: String?)
    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void)
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

    func createMultipartBody(boundary: String, audioData: Data, model: String) -> Data {
        var body = Data()

        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

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

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        transcribeWithRetry(audioURL: audioURL, attempt: 1, completion: completion)
    }

    private func transcribeWithRetry(audioURL: URL, attempt: Int, completion: @escaping (Result<String, Error>) -> Void) {
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

        request.httpBody = createMultipartBody(boundary: boundary, audioData: audioData, model: model)

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
                        self.transcribeWithRetry(audioURL: audioURL, attempt: attempt + 1, completion: completion)
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
                        self.transcribeWithRetry(audioURL: audioURL, attempt: attempt + 1, completion: completion)
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

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        transcribeWithRetry(audioURL: audioURL, attempt: 1, completion: completion)
    }

    private func transcribeWithRetry(audioURL: URL, attempt: Int, completion: @escaping (Result<String, Error>) -> Void) {
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

        request.httpBody = createMultipartBody(boundary: boundary, audioData: audioData, model: model)

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
                        self.transcribeWithRetry(audioURL: audioURL, attempt: attempt + 1, completion: completion)
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
                        self.transcribeWithRetry(audioURL: audioURL, attempt: attempt + 1, completion: completion)
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

// MARK: - Transcription Provider Factory

enum TranscriptionProviderFactory {
    static let availableProviders: [ProviderInfo] = [
        ProviderInfo(id: "openai", displayName: "OpenAI Whisper",
                     apiKeyHelpUrl: URL(string: "https://platform.openai.com/api-keys")!),
        ProviderInfo(id: "mistral", displayName: "Mistral Voxtral",
                     apiKeyHelpUrl: URL(string: "https://console.mistral.ai/api-keys")!)
    ]

    static func create(from config: Config) -> TranscriptionProvider {
        let providerId = config.provider
        let apiKey = config.getCurrentApiKey()
        return create(providerId: providerId, apiKey: apiKey)
    }

    static func create(providerId: String, apiKey: String) -> TranscriptionProvider {
        switch providerId.lowercased() {
        case "mistral":
            return MistralProvider(apiKey: apiKey)
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

    // Permission wizard
    private var permissionWizard: PermissionWizard?

    // Preferences window
    private var preferencesWindow: PreferencesWindow?

    // Menu items that need updating
    private var toggleShortcutMenuItem: NSMenuItem?
    private var pttMenuItem: NSMenuItem?

    private enum AppState {
        case idle, recording, transcribing
    }
    private var state: AppState = .idle
    private var isPushToTalkActive = false  // Track if current recording is from PTT

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check Permissions...", action: #selector(showPermissionStatus), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Version 2.3.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Setup both hotkeys (toggle + push-to-talk)
        setupToggleHotkey()
        setupPushToTalkHotkey()

        LogManager.shared.log("App started - Provider: \(transcriptionProvider?.displayName ?? "unknown")")
        print("Whisper Voice started (dual mode: toggle + push-to-talk)")
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
                pushToTalkKeyCode: pttKeyCode
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

    private func setupAutoStart() {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.whisper-voice.plist")

        let appPath = Bundle.main.bundlePath

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

        try? plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
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

        // Global monitor for key down (start recording)
        pttGlobalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == pttKeyCode && !event.isARepeat {
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
                    if event.type == .keyDown && !event.isARepeat {
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

    private func startRecording(showStopMessage: Bool) {
        LogManager.shared.log("Starting recording (showStopMessage: \(showStopMessage))")

        guard audioRecorder.startRecording() else {
            LogManager.shared.log("Failed to start recording", level: "ERROR")
            showNotification(title: "Error", message: "Failed to start recording")
            return
        }

        state = .recording
        updateStatusIcon()
        updateStatus("Recording...")

        if showStopMessage {
            let shortcut = config?.toggleShortcutDescription() ?? "shortcut"
            showNotification(title: "Recording", message: "\(shortcut) to stop")
        } else {
            showNotification(title: "Recording", message: "Release key to stop")
        }
    }

    private func stopRecording() {
        LogManager.shared.log("Stopping recording")

        guard let audioURL = audioRecorder.stopRecording() else {
            LogManager.shared.log("No audio URL returned from stopRecording", level: "WARNING")
            state = .idle
            updateStatusIcon()
            updateStatus("Idle")
            return
        }

        state = .transcribing
        updateStatusIcon()
        updateStatus("Transcribing...")

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

        transcriptionProvider?.transcribe(audioURL: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                // Cancel safety timeout
                self?.transcriptionTimeoutTimer?.invalidate()
                self?.transcriptionTimeoutTimer = nil

                self?.audioRecorder.cleanup()

                switch result {
                case .success(let text):
                    LogManager.shared.log("Transcription complete: \(text.prefix(50))...")
                    pasteText(text)
                    self?.showNotification(title: "Transcription Complete", message: String(text.prefix(50)))
                case .failure(let error):
                    LogManager.shared.log("Transcription failed: \(error.localizedDescription)", level: "ERROR")
                    self?.showNotification(title: "Error", message: error.localizedDescription)
                }

                self?.state = .idle
                self?.updateStatusIcon()
                self?.updateStatus("Idle")
            }
        }
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
