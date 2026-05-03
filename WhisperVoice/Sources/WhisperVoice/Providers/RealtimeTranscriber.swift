import AVFoundation
import Foundation

class RealtimeTranscriber {
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var accumulatedText: String = ""
    private var isRunning = false

    var onTranscript: ((String) -> Void)?

    func start(apiKey: String, language: String = "fr", vocabulary: [String]? = nil) {
        guard !isRunning else { return }
        isRunning = true
        accumulatedText = ""

        connectWebSocket(apiKey: apiKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.sendSessionConfig(language: language, vocabulary: vocabulary)
            self.startAudioCapture()
        }
    }

    func stop() {
        isRunning = false
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        converter = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    // MARK: - WebSocket

    private func connectWebSocket(apiKey: String) {
        let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        webSocketTask?.resume()
        listenForMessages()
        LogManager.shared.log("[RealtimeTranscriber] WebSocket connecting…")
    }

    private func sendSessionConfig(language: String, vocabulary: [String]?) {
        var transcription: [String: Any] = [
            "model": "gpt-4o-mini-transcribe",
            "language": language,
        ]
        if let vocab = vocabulary, !vocab.isEmpty {
            transcription["prompt"] = vocab.joined(separator: ", ")
        }

        let config: [String: Any] = [
            "type": "transcription_session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": transcription,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500,
                ],
                "input_audio_noise_reduction": [
                    "type": "near_field"
                ],
            ],
        ]
        sendJSON(config)
    }

    // MARK: - Audio capture → WebSocket

    private func startAudioCapture() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        ) else { return }

        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            LogManager.shared.log("[RealtimeTranscriber] Cannot create audio converter", level: "ERROR")
            return
        }
        self.converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 4800, format: hwFormat) { [weak self] buffer, _ in
            self?.convertAndSend(buffer: buffer, targetFormat: targetFormat)
        }

        do {
            try engine.start()
            LogManager.shared.log("[RealtimeTranscriber] Audio engine started (hw: \(hwFormat.sampleRate)Hz → 24kHz pcm16)")
        } catch {
            LogManager.shared.log("[RealtimeTranscriber] Engine start failed: \(error)", level: "ERROR")
        }
    }

    private func convertAndSend(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter = self.converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, converted.frameLength > 0,
              let int16 = converted.int16ChannelData else { return }

        let data = Data(bytes: int16[0], count: Int(converted.frameLength) * 2)
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ]
        sendJSON(event)
    }

    // MARK: - Receive events

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isRunning else { return }
            switch result {
            case .success(.string(let text)):
                self.handleEvent(text)
                self.listenForMessages()
            case .success:
                self.listenForMessages()
            case .failure(let error):
                LogManager.shared.log("[RealtimeTranscriber] WS closed: \(error.localizedDescription)", level: "WARNING")
            }
        }
    }

    private func handleEvent(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                appendTranscript(transcript)
            }
        case "transcription_session.created", "transcription_session.updated":
            LogManager.shared.log("[RealtimeTranscriber] Session ready (\(type))")
        case "input_audio_buffer.speech_started":
            LogManager.shared.log("[RealtimeTranscriber] Speech detected")
        case "error":
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                LogManager.shared.log("[RealtimeTranscriber] API error: \(msg)", level: "ERROR")
            }
        default:
            break
        }
    }

    private func appendTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if accumulatedText.isEmpty {
            accumulatedText = trimmed
        } else {
            accumulatedText += " " + trimmed
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onTranscript?(self.accumulatedText)
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { error in
            if let error = error {
                LogManager.shared.log("[RealtimeTranscriber] Send error: \(error.localizedDescription)", level: "ERROR")
            }
        }
    }
}
