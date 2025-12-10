import Cocoa
import AVFoundation
import Carbon.HIToolbox

// MARK: - Configuration

enum RecordingMode: String {
    case toggle = "toggle"
    case pushToTalk = "pushToTalk"
}

struct Config {
    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whisper-voice-config.json")

    var apiKey: String
    var shortcutModifiers: UInt32  // e.g., optionKey
    var shortcutKeyCode: UInt32    // e.g., kVK_Space
    var recordingMode: RecordingMode
    var pushToTalkKeyCode: UInt32  // e.g., kVK_F3

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = json["apiKey"] as? String else {
            return nil
        }

        let modifiers = json["shortcutModifiers"] as? UInt32 ?? UInt32(optionKey)
        let keyCode = json["shortcutKeyCode"] as? UInt32 ?? UInt32(kVK_Space)
        let modeStr = json["recordingMode"] as? String ?? "toggle"
        let mode = RecordingMode(rawValue: modeStr) ?? .toggle
        let pttKeyCode = json["pushToTalkKeyCode"] as? UInt32 ?? UInt32(kVK_F3)

        return Config(
            apiKey: apiKey,
            shortcutModifiers: modifiers,
            shortcutKeyCode: keyCode,
            recordingMode: mode,
            pushToTalkKeyCode: pttKeyCode
        )
    }

    func save() {
        let json: [String: Any] = [
            "apiKey": apiKey,
            "shortcutModifiers": shortcutModifiers,
            "shortcutKeyCode": shortcutKeyCode,
            "recordingMode": recordingMode.rawValue,
            "pushToTalkKeyCode": pushToTalkKeyCode
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: Config.configPath)
        }
    }

    func shortcutDescription() -> String {
        if recordingMode == .pushToTalk {
            return keyCodeToString(pushToTalkKeyCode) + " (hold)"
        }

        var parts: [String] = []
        if shortcutModifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        if shortcutModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if shortcutModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if shortcutModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        parts.append(keyCodeToString(shortcutKeyCode))
        return parts.joined(separator: "+")
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

// MARK: - Whisper API

class WhisperAPI {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("gpt-4o-mini-transcribe\r\n".data(using: .utf8)!)

        // Audio file
        if let audioData = try? Data(contentsOf: audioURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "WhisperAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = json["text"] as? String {
                    completion(.success(text))
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "Unknown error"
                    completion(.failure(NSError(domain: "WhisperAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: responseStr])))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
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
    private var whisperAPI: WhisperAPI?
    private var config: Config?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var flagsEventMonitor: Any?

    private enum AppState {
        case idle, recording, transcribing
    }
    private var state: AppState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load config
        guard let config = Config.load() else {
            showConfigError()
            return
        }
        self.config = config
        self.whisperAPI = WhisperAPI(apiKey: config.apiKey)

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        // Create menu
        let menu = NSMenu()

        let shortcutDesc = config.shortcutDescription()
        menu.addItem(NSMenuItem(title: "\(shortcutDesc) to record", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let modeDesc = config.recordingMode == .pushToTalk ? "Push-to-Talk" : "Toggle"
        let modeMenuItem = NSMenuItem(title: "Mode: \(modeDesc)", action: nil, keyEquivalent: "")
        modeMenuItem.tag = 101
        menu.addItem(modeMenuItem)

        let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Version 2.1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu

        // Setup hotkeys based on mode
        if config.recordingMode == .pushToTalk {
            setupPushToTalkHotkey()
        } else {
            setupToggleHotkey()
        }

        print("Whisper Voice started (mode: \(config.recordingMode.rawValue))")
    }

    private func showConfigError() {
        let alert = NSAlert()
        alert.messageText = "Configuration Required"
        alert.informativeText = "Please run the install script first:\n./install.sh"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
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
        guard let config = config else { return }

        // Global monitor for key down
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matchesToggleShortcut(event) == true {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
            }
        }

        // Local monitor for key down
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
            startRecording(showStopMessage: true)
        case .recording:
            stopRecording()
        case .transcribing:
            break
        }
    }

    // MARK: - Push-to-Talk Mode (hold to record, release to stop)

    private func setupPushToTalkHotkey() {
        guard let config = config else { return }
        let pttKeyCode = UInt16(config.pushToTalkKeyCode)

        // Global monitor for key down (start recording)
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == pttKeyCode && !event.isARepeat {
                DispatchQueue.main.async {
                    self?.startPushToTalk()
                }
            }
        }

        // Global monitor for key up (stop recording)
        flagsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if event.keyCode == pttKeyCode {
                DispatchQueue.main.async {
                    self?.stopPushToTalk()
                }
            }
        }

        // Local monitors
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
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
        startRecording(showStopMessage: false)
    }

    private func stopPushToTalk() {
        guard state == .recording else { return }
        stopRecording()
    }

    // MARK: - Recording

    private func startRecording(showStopMessage: Bool) {
        guard audioRecorder.startRecording() else {
            showNotification(title: "Error", message: "Failed to start recording")
            return
        }

        state = .recording
        updateStatusIcon()
        updateStatus("Recording...")

        if showStopMessage {
            let shortcut = config?.shortcutDescription() ?? "shortcut"
            showNotification(title: "Recording", message: "\(shortcut) to stop")
        } else {
            showNotification(title: "Recording", message: "Release key to stop")
        }
    }

    private func stopRecording() {
        guard let audioURL = audioRecorder.stopRecording() else {
            state = .idle
            updateStatusIcon()
            updateStatus("Idle")
            return
        }

        state = .transcribing
        updateStatusIcon()
        updateStatus("Transcribing...")

        whisperAPI?.transcribe(audioURL: audioURL) { [weak self] result in
            DispatchQueue.main.async {
                self?.audioRecorder.cleanup()

                switch result {
                case .success(let text):
                    pasteText(text)
                    self?.showNotification(title: "Transcription Complete", message: String(text.prefix(50)))
                case .failure(let error):
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
