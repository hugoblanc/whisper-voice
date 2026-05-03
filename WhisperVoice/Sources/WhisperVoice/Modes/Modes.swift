import Cocoa

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
    /// with legacy families kept at the bottom for users who already rely on them.
    static let availableModels: [(id: String, name: String)] = [
        ("gpt-5.4-nano", "GPT-5.4 Nano (le plus rapide et économique)"),
        ("gpt-5.4-mini", "GPT-5.4 Mini (équilibre qualité/coût)"),
        ("gpt-5.4", "GPT-5.4 (premium)"),
        ("gpt-4.1-nano", "GPT-4.1 Nano (ancien, rapide)"),
        ("gpt-4.1-mini", "GPT-4.1 Mini (ancien)"),
        ("gpt-4.1", "GPT-4.1 (ancien)"),
        ("gpt-4o-mini", "GPT-4o Mini (legacy)"),
        ("gpt-4o", "GPT-4o (legacy)")
    ]

    private var model: String {
        Config.load()?.processingModel ?? "gpt-5.4-nano"
    }

    func process(text: String, mode: ProcessingMode, apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        process(text: text, mode: mode, context: nil, dictationContext: nil, vocabulary: nil, apiKey: apiKey, completion: completion)
    }

    func process(text: String,
                 mode: ProcessingMode,
                 context: String?,
                 dictationContext: DictationContext? = nil,
                 vocabulary: [String]? = nil,
                 apiKey: String,
                 completion: @escaping (Result<String, Error>) -> Void) {
        guard let systemPrompt = mode.systemPrompt else {
            // No processing needed
            completion(.success(text))
            return
        }

        LogManager.shared.log("[TextProcessor] Processing with mode: \(mode.name)")

        // Build system prompt - for Super mode with context, use dynamic prompt
        var effectivePrompt: String
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

        // Super mode: append ambient context (app, git repo, URL, cwd) so the
        // assistant can act like a real co-pilot instead of a plain reformatter.
        if mode.id == "super", let ctx = dictationContext {
            var lines: [String] = []
            if let app = ctx.app { lines.append("- Active app: \(app.name) (\(app.bundleID))") }
            if let t = ctx.signals?.windowTitle, !t.isEmpty { lines.append("- Window title: \(t)") }
            if let url = ctx.signals?.browserURL, !url.isEmpty { lines.append("- Browser URL: \(url)") }
            if let tab = ctx.signals?.browserTabTitle, !tab.isEmpty { lines.append("- Browser tab: \(tab)") }
            if let cwd = ctx.signals?.cwd, !cwd.isEmpty { lines.append("- Terminal cwd: \(cwd)") }
            if let cmd = ctx.signals?.foregroundCmd, !cmd.isEmpty { lines.append("- Foreground command: \(cmd)") }
            if let git = ctx.signals?.gitRemote, !git.isEmpty {
                var g = git
                if let b = ctx.signals?.gitBranch, !b.isEmpty { g += " @ \(b)" }
                lines.append("- Git: \(g)")
            }
            if !lines.isEmpty {
                effectivePrompt += "\n\nContexte ambient au moment de la dictée (tu peux t'en servir si pertinent) :\n" + lines.joined(separator: "\n")
            }
        }

        // Custom vocabulary: tell the LLM to preserve these spellings verbatim,
        // even if Whisper got them phonetically wrong. Same list as the Whisper
        // prompt, but at the LLM layer so reformatting modes don't "correct" them.
        if let vocab = vocabulary, !vocab.isEmpty {
            effectivePrompt += "\n\nTermes à préserver exactement (restaure l'orthographe d'origine si elle a été déformée) : " + vocab.joined(separator: ", ") + "."
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": effectivePrompt],
            ["role": "user", "content": text]
        ]

        // GPT-5 family requires `max_completion_tokens`; older GPT-4 family still uses `max_tokens`.
        let tokenKey = model.hasPrefix("gpt-5") ? "max_completion_tokens" : "max_tokens"
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            tokenKey: 2048
        ]

        // Pipeline audit log: model + token param + input + prompt head — so logs tell the full story.
        LogManager.shared.log("[TextProcessor] model=\(model) tokenParam=\(tokenKey) mode=\(mode.name)")
        LogManager.shared.log("[TextProcessor] INPUT (\(text.count) chars): \(text)")
        LogManager.shared.log("[TextProcessor] SYSTEM PROMPT HEAD: \(effectivePrompt.prefix(240))\(effectivePrompt.count > 240 ? " …[+\(effectivePrompt.count - 240) chars]" : "")")

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
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    let changed = trimmed != text
                    LogManager.shared.log("[TextProcessor] SUCCESS \(text.count)→\(trimmed.count) chars  changed=\(changed)")
                    LogManager.shared.log("[TextProcessor] OUTPUT: \(trimmed)")
                    completion(.success(trimmed))
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
