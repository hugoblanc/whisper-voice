import Cocoa
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import os.log

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
