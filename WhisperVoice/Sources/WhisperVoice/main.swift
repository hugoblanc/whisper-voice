import Cocoa
import AVFoundation
import Carbon.HIToolbox
import os.log

private let logger = Logger(subsystem: "com.whispervoice", category: "main")

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

        logger.info("Audio file size: \(fileSize) bytes")

        if fileSize < minFileSizeBytes {
            logger.warning("Audio file too small, likely empty recording")
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
        logger.info("[\(self.displayName)] Transcription attempt \(attempt)/\(self.maxRetries) for: \(audioURL.lastPathComponent)")

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

        logger.info("[\(self.displayName)] Sending request (attempt \(attempt))...")

        let session = createSession()
        session.dataTask(with: request) { [weak self] data, response, error in
            session.invalidateAndCancel()

            guard let self = self else { return }

            if let error = error {
                logger.error("[\(self.displayName)] Request failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < self.maxRetries {
                    logger.info("[\(self.displayName)] Retrying in 1 second...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.transcribeWithRetry(audioURL: audioURL, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(.failure(error))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                logger.info("[\(self.displayName)] Response status: \(httpResponse.statusCode)")

                if httpResponse.statusCode >= 500 && attempt < self.maxRetries {
                    logger.info("[\(self.displayName)] Server error, retrying...")
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
                    logger.info("[\(self.displayName)] Transcription successful: \(text.prefix(50))...")
                    completion(.success(text))
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "Unknown error"
                    logger.error("[\(self.displayName)] API error: \(responseStr)")
                    completion(.failure(NSError(domain: "OpenAI", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: responseStr])))
                }
            } catch {
                logger.error("[\(self.displayName)] JSON parsing error: \(error.localizedDescription)")
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
        logger.info("[\(self.displayName)] Transcription attempt \(attempt)/\(self.maxRetries) for: \(audioURL.lastPathComponent)")

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

        logger.info("[\(self.displayName)] Sending request (attempt \(attempt))...")

        let session = createSession()
        session.dataTask(with: request) { [weak self] data, response, error in
            session.invalidateAndCancel()

            guard let self = self else { return }

            if let error = error {
                logger.error("[\(self.displayName)] Request failed (attempt \(attempt)): \(error.localizedDescription)")

                if attempt < self.maxRetries {
                    logger.info("[\(self.displayName)] Retrying in 1 second...")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        self.transcribeWithRetry(audioURL: audioURL, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    completion(.failure(error))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                logger.info("[\(self.displayName)] Response status: \(httpResponse.statusCode)")

                if httpResponse.statusCode >= 500 && attempt < self.maxRetries {
                    logger.info("[\(self.displayName)] Server error, retrying...")
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
                    logger.info("[\(self.displayName)] Transcription successful: \(text.prefix(50))...")
                    completion(.success(text))
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "Unknown error"
                    logger.error("[\(self.displayName)] API error: \(responseStr)")
                    completion(.failure(NSError(domain: "Mistral", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: responseStr])))
                }
            } catch {
                logger.error("[\(self.displayName)] JSON parsing error: \(error.localizedDescription)")
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
            setupStatusBar()
        } else {
            showConfigError()
        }
    }

    private func showConfigError() {
        // Show setup wizard instead of error
        if let config = showSetupWizard() {
            self.config = config
            self.transcriptionProvider = TranscriptionProviderFactory.create(from: config)
            logger.info("Using transcription provider: \(self.transcriptionProvider?.displayName ?? "unknown")")
            setupStatusBar()
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

        menu.addItem(NSMenuItem(title: "\(config.toggleShortcutDescription()) to toggle", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "\(config.pushToTalkDescription()) to record", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Version 2.2.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Setup both hotkeys (toggle + push-to-talk)
        setupToggleHotkey()
        setupPushToTalkHotkey()

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
        logger.info("Starting recording (showStopMessage: \(showStopMessage))")

        guard audioRecorder.startRecording() else {
            logger.error("Failed to start recording")
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
        logger.info("Stopping recording")

        guard let audioURL = audioRecorder.stopRecording() else {
            logger.warning("No audio URL returned from stopRecording")
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
                    logger.error("Transcription timeout - resetting state")
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
                    logger.info("Transcription complete, pasting text")
                    pasteText(text)
                    self?.showNotification(title: "Transcription Complete", message: String(text.prefix(50)))
                case .failure(let error):
                    logger.error("Transcription failed: \(error.localizedDescription)")
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
