import Cocoa

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
