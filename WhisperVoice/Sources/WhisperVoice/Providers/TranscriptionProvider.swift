import Foundation

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
