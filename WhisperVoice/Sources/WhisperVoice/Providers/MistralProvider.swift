import Foundation

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
