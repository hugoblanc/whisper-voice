import Foundation

// MARK: - MCP Tools

/// Tool definitions and handlers for the MCP server. History and projects are
/// re-read from disk on every call: the app process owns those files and keeps
/// writing them while the MCP process is alive. The MCP side never writes them,
/// so it cannot clobber the app's in-memory copy.
final class MCPTools {

    struct Outcome {
        let payload: Any
        let isError: Bool

        static func ok(_ payload: [String: Any]) -> Outcome { Outcome(payload: payload, isError: false) }
        static func failure(_ message: String) -> Outcome { Outcome(payload: message, isError: true) }

        func asResult() -> [String: Any] {
            if isError {
                return ["content": [["type": "text", "text": payload as? String ?? "Error"]], "isError": true]
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            let text = String(data: data, encoding: .utf8) ?? "{}"
            return ["content": [["type": "text", "text": text]], "structuredContent": payload, "isError": false]
        }
    }

    private static let defaultLimit = 20
    private static let maxLimit = 200
    private static let defaultVoiceMessages = 10
    private static let maxVoiceMessages = 50

    // MARK: Definitions

    static let definitions: [[String: Any]] = [
        [
            "name": "search_transcriptions",
            "title": "Search dictation history",
            "description": """
            Search the user's Whisper Voice dictation history, newest first. All filters are optional and combined with AND; \
            with no filter it returns the latest dictations. Each result has the dictated text, its local timestamp, \
            the app it was dictated into and its project tag.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Words that must all appear in the text (case- and accent-insensitive)."],
                    "since": ["type": "string",
                              "description": "Only dictations at or after this local date or datetime, ISO 8601 (e.g. 2026-09-01 or 2026-09-01T14:00)."],
                    "until": ["type": "string",
                              "description": "Only dictations at or before this local date or datetime, ISO 8601. A bare date includes the whole day."],
                    "app": ["type": "string",
                            "description": "App name or bundle ID the dictation went into (substring match, e.g. \"Slack\")."],
                    "project": ["type": "string",
                                "description": "Project name (exact, case-insensitive) or project ID. Use \"none\" for untagged dictations."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": maxLimit,
                              "description": "Maximum results to return (default \(defaultLimit))."],
                    "offset": ["type": "integer", "minimum": 0,
                               "description": "Number of matching results to skip, for pagination."],
                ],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_transcription",
            "title": "Get one dictation",
            "description": """
            Get one dictation by ID with its full capture context: focused window title, browser URL and tab title, \
            terminal working directory, foreground command and git remote/branch, plus project tagging details.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Dictation ID, as returned by search_transcriptions."],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_projects",
            "title": "List projects",
            "description": "List the project tags the user files dictations under, with how many dictations each has and when it was last used.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "includeArchived": ["type": "boolean", "description": "Include archived projects (default false)."],
                ],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "transcribe_audio_file",
            "title": "Transcribe an audio file",
            "description": """
            Transcribe an audio file (wav, mp3, m4a, ogg/opus from WhatsApp, flac, webm…) with the transcription \
            provider configured in Whisper Voice (OpenAI Whisper or Mistral Voxtral) and the user's custom vocabulary. \
            Give either path, for a file on this Mac (list_voice_messages returns such paths), or url, for a file to download first. \
            The audio is sent to that provider's API. The result is returned only; it is not added to the dictation history.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to the audio file. A leading ~ is expanded."],
                    "url": ["type": "string",
                            "description": "http(s) URL of the audio file, downloaded to a temporary file that is deleted afterwards."],
                    "headers": ["type": "object", "additionalProperties": ["type": "string"],
                                "description": "HTTP headers for the url download, e.g. {\"Authorization\": \"Bearer xoxp-…\"} for a Slack url_private_download link."],
                ],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": true],
        ],
        [
            "name": "list_voice_messages",
            "title": "Find voice messages on this Mac",
            "description": """
            List voice messages already on this Mac, newest first, so they can be passed to transcribe_audio_file by path: \
            voice notes received in WhatsApp desktop (with the chat, the sender and the duration) and audio files in ~/Downloads \
            (Slack clips, WhatsApp Web exports). Use it when the user asks to transcribe "the last voice message" or one from a given person.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": ["type": "string", "enum": VoiceMessageFinder.Source.allCases.map(\.rawValue),
                               "description": "Only look in this place (default: all)."],
                    "chat": ["type": "string",
                             "description": "Words that must all appear in the WhatsApp chat or sender name, or in the file name for Downloads (case- and accent-insensitive)."],
                    "since": ["type": "string",
                              "description": "Only voice messages at or after this local date or datetime, ISO 8601 (e.g. 2026-09-01 or 2026-09-01T14:00)."],
                    "includeSent": ["type": "boolean",
                                    "description": "Also list the WhatsApp voice notes the user recorded themselves (default false)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": maxVoiceMessages,
                              "description": "Maximum results to return (default \(defaultVoiceMessages))."],
                ],
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]

    // MARK: Dispatch

    func call(name: String, arguments: [String: Any]) -> Outcome {
        switch name {
        case "search_transcriptions": return searchTranscriptions(arguments)
        case "get_transcription": return getTranscription(arguments)
        case "list_projects": return listProjects(arguments)
        case "transcribe_audio_file": return transcribeAudioFile(arguments)
        case "list_voice_messages": return listVoiceMessages(arguments)
        default: return .failure("Unknown tool: \(name)")
        }
    }

    // MARK: search_transcriptions

    private func searchTranscriptions(_ args: [String: Any]) -> Outcome {
        let projects = ProjectStore.readProjectsFromDisk()
        var entries = HistoryManager.readEntriesFromDisk()
        entries.sort { $0.timestamp > $1.timestamp }

        if let raw = nonEmptyString(args["since"]) {
            guard let since = Self.parseDate(raw, endOfDay: false) else {
                return .failure("Invalid since \"\(raw)\": expected an ISO 8601 date such as 2026-09-01 or 2026-09-01T14:00.")
            }
            entries = entries.filter { $0.timestamp >= since }
        }
        if let raw = nonEmptyString(args["until"]) {
            guard let until = Self.parseDate(raw, endOfDay: true) else {
                return .failure("Invalid until \"\(raw)\": expected an ISO 8601 date such as 2026-09-30 or 2026-09-30T18:00.")
            }
            entries = entries.filter { $0.timestamp <= until }
        }
        if let query = nonEmptyString(args["query"]) {
            let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            entries = entries.filter { entry in
                words.allSatisfy { entry.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        if let app = nonEmptyString(args["app"]) {
            entries = entries.filter { entry in
                guard let info = entry.app else { return false }
                return info.name.localizedCaseInsensitiveContains(app) || info.bundleID.localizedCaseInsensitiveContains(app)
            }
        }
        if let project = nonEmptyString(args["project"]) {
            if project.lowercased() == "none" {
                entries = entries.filter { $0.projectID == nil }
            } else {
                let match = projects.first { $0.id.uuidString.caseInsensitiveCompare(project) == .orderedSame }
                    ?? projects.first { $0.name.caseInsensitiveCompare(project) == .orderedSame }
                guard let target = match else {
                    let names = projects.filter { !$0.archived }.map(\.name).joined(separator: ", ")
                    return .failure("No project named \"\(project)\". Known projects: \(names.isEmpty ? "none" : names).")
                }
                entries = entries.filter { $0.projectID == target.id }
            }
        }

        let limit = min(max(intValue(args["limit"]) ?? Self.defaultLimit, 1), Self.maxLimit)
        let offset = max(intValue(args["offset"]) ?? 0, 0)
        let page = entries.dropFirst(offset).prefix(limit)
        let projectNames = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })

        return .ok([
            "total": entries.count,
            "offset": offset,
            "returned": page.count,
            "transcriptions": page.map { summary(of: $0, projectNames: projectNames) },
        ])
    }

    // MARK: get_transcription

    private func getTranscription(_ args: [String: Any]) -> Outcome {
        guard let raw = nonEmptyString(args["id"]), let id = UUID(uuidString: raw) else {
            return .failure("id must be a dictation ID (UUID) as returned by search_transcriptions.")
        }
        guard let entry = HistoryManager.readEntriesFromDisk().first(where: { $0.id == id }) else {
            return .failure("No dictation with id \(raw). It may have been deleted from the history.")
        }
        let projects = ProjectStore.readProjectsFromDisk()
        var result = summary(of: entry, projectNames: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) }))
        result["provider"] = entry.provider
        if let app = entry.app { result["appBundleID"] = app.bundleID }
        if let s = entry.signals {
            var context: [String: Any] = [:]
            context["windowTitle"] = s.windowTitle
            context["browserURL"] = s.browserURL
            context["browserTabTitle"] = s.browserTabTitle
            context["cwd"] = s.cwd
            context["foregroundCommand"] = s.foregroundCmd
            context["gitRemote"] = s.gitRemote
            context["gitBranch"] = s.gitBranch
            if !context.isEmpty { result["context"] = context }
        }
        if let extras = entry.extras, !extras.isEmpty { result["extras"] = extras }
        return .ok(result)
    }

    // MARK: list_projects

    private func listProjects(_ args: [String: Any]) -> Outcome {
        let includeArchived = args["includeArchived"] as? Bool ?? false
        let entries = HistoryManager.readEntriesFromDisk()
        var counts: [UUID: Int] = [:]
        var lastUsed: [UUID: Date] = [:]
        for entry in entries {
            guard let pid = entry.projectID else { continue }
            counts[pid, default: 0] += 1
            if lastUsed[pid].map({ entry.timestamp > $0 }) ?? true { lastUsed[pid] = entry.timestamp }
        }
        let projects = ProjectStore.readProjectsFromDisk()
            .filter { includeArchived || !$0.archived }
            .map { p -> [String: Any] in
                var d: [String: Any] = [
                    "id": p.id.uuidString,
                    "name": p.name,
                    "archived": p.archived,
                    "transcriptionCount": counts[p.id] ?? 0,
                ]
                if let last = lastUsed[p.id] { d["lastUsedAt"] = Self.formatDate(last) }
                return d
            }
        return .ok(["projects": projects])
    }

    // MARK: transcribe_audio_file

    private func transcribeAudioFile(_ args: [String: Any]) -> Outcome {
        let rawPath = nonEmptyString(args["path"])
        let rawURL = nonEmptyString(args["url"])
        guard (rawPath == nil) != (rawURL == nil) else {
            return .failure("Give exactly one of path (a file on this Mac) or url (a file to download).")
        }
        guard let config = Config.load() else {
            return .failure("Whisper Voice is not configured yet. Open Whisper Voice and set a provider and API key first.")
        }
        guard config.provider != "local" else {
            // The local provider drives a whisper-server process owned by the app;
            // starting a second one from here would fight over its port and leak memory.
            return .failure("Whisper Voice is set to the local whisper.cpp provider, which the MCP server does not support yet. Switch to OpenAI or Mistral in Whisper Voice preferences.")
        }

        let file: URL
        // What the caller named, for error messages: the temporary download path means nothing to them.
        let origin: String
        var downloaded: URL?
        defer { if let downloaded = downloaded { try? FileManager.default.removeItem(at: downloaded) } }

        if let rawURL = rawURL {
            switch download(rawURL, headers: args["headers"] as? [String: Any] ?? [:]) {
            case .failure(let error): return .failure(error.message)
            case .success(let url):
                file = url
                downloaded = url
                origin = rawURL
            }
        } else {
            let path = ((rawPath ?? "") as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                return .failure("path must be absolute, got \"\(rawPath ?? "")\".")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .failure("No file at \(path).")
            }
            file = URL(fileURLWithPath: path)
            origin = path
        }

        let provider = TranscriptionProviderFactory.create(from: config)
        let prompt = config.customVocabulary.isEmpty ? nil : config.customVocabulary.joined(separator: ", ")
        let done = DispatchSemaphore(value: 0)
        var outcome = Outcome.failure("Transcription did not complete.")

        AudioImporter.prepare(file) { prepared in
            switch prepared {
            case .failure(let error):
                outcome = .failure("Could not read audio from \(origin): \(error.localizedDescription)")
                done.signal()
            case .success(let audio):
                provider.transcribe(audioURL: audio.url, prompt: prompt) { result in
                    if audio.isTemporary { try? FileManager.default.removeItem(at: audio.url) }
                    switch result {
                    case .success(let text):
                        outcome = .ok(["text": text.trimmingCharacters(in: .whitespacesAndNewlines),
                                       "provider": provider.displayName])
                    case .failure(let error):
                        outcome = .failure("\(provider.displayName) transcription failed: \(error.localizedDescription)")
                    }
                    done.signal()
                }
            }
        }
        done.wait()
        return outcome
    }

    private struct DownloadError: Error {
        let message: String
    }

    private static let audioExtensions = AudioImporter.apiSupportedExtensions.union(AudioImporter.pickerExtensions)

    /// Downloads a remote audio file to a temporary file the caller deletes.
    /// The file keeps a real audio extension: AudioImporter and the providers
    /// both pick the decoder / MIME type from it.
    private func download(_ rawURL: String, headers: [String: Any]) -> Result<URL, DownloadError> {
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return .failure(DownloadError(message: "url must be an http(s) URL, got \"\(rawURL)\". For a file on this Mac use path."))
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        for (name, value) in headers {
            guard let value = value as? String else {
                return .failure(DownloadError(message: "headers must map header names to strings; \"\(name)\" is not a string."))
            }
            request.setValue(value, forHTTPHeaderField: name)
        }

        let done = DispatchSemaphore(value: 0)
        var result: Result<URL, DownloadError> = .failure(DownloadError(message: "Download of \(rawURL) did not complete."))
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }
            guard let location = location, let http = response as? HTTPURLResponse else {
                result = .failure(DownloadError(message: "Could not download \(rawURL): \(error?.localizedDescription ?? "no response")."))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(DownloadError(message: "Could not download \(rawURL): HTTP \(http.statusCode)."))
                return
            }
            let mimeType = http.mimeType?.lowercased() ?? "unknown"
            // Private links (Slack, Drive…) answer 200 with their sign-in page when the request is not authenticated.
            guard !mimeType.hasPrefix("text/"), mimeType != "application/json" else {
                result = .failure(DownloadError(message: "\(rawURL) returned \(mimeType), not audio. The link probably needs authentication: pass headers, or download the file and use path."))
                return
            }
            // suggestedFilename already accounts for Content-Disposition and the MIME type.
            let suggested = URL(fileURLWithPath: http.suggestedFilename ?? "").pathExtension
            let candidates = [suggested, url.pathExtension].map { $0.lowercased() }
            guard let ext = candidates.first(where: { Self.audioExtensions.contains($0) }) else {
                result = .failure(DownloadError(message: "\(rawURL) is not a recognised audio file (Content-Type \(mimeType))."))
                return
            }
            // The download is removed when this handler returns: move it somewhere we own.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp_download_\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                result = .success(destination)
            } catch {
                result = .failure(DownloadError(message: "Could not store the download of \(rawURL): \(error.localizedDescription)"))
            }
        }.resume()
        done.wait()
        return result
    }

    // MARK: list_voice_messages

    private func listVoiceMessages(_ args: [String: Any]) -> Outcome {
        var sources = Set(VoiceMessageFinder.Source.allCases)
        if let raw = nonEmptyString(args["source"]) {
            guard let source = VoiceMessageFinder.Source(rawValue: raw.lowercased()) else {
                let known = VoiceMessageFinder.Source.allCases.map(\.rawValue).joined(separator: ", ")
                return .failure("Unknown source \"\(raw)\". Known sources: \(known).")
            }
            sources = [source]
        }
        var since: Date?
        if let raw = nonEmptyString(args["since"]) {
            guard let date = Self.parseDate(raw, endOfDay: false) else {
                return .failure("Invalid since \"\(raw)\": expected an ISO 8601 date such as 2026-09-01 or 2026-09-01T14:00.")
            }
            since = date
        }
        let includeSent = args["includeSent"] as? Bool ?? false

        let listing = VoiceMessageFinder.find(sources: sources, since: since)
        var messages = listing.messages.filter { includeSent || !$0.fromMe }
        if let chat = nonEmptyString(args["chat"]) {
            let words = chat.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            messages = messages.filter { message in
                let haystack = message.source == .whatsapp
                    ? [message.chat, message.sender].compactMap { $0 }.joined(separator: " ")
                    : (message.path as NSString).lastPathComponent
                return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }

        let limit = min(max(intValue(args["limit"]) ?? Self.defaultVoiceMessages, 1), Self.maxVoiceMessages)
        let page = messages.prefix(limit).map { message -> [String: Any] in
            var d: [String: Any] = [
                "path": message.path,
                "source": message.source.rawValue,
                "timestamp": Self.formatDate(message.timestamp),
            ]
            if let duration = message.durationSeconds { d["durationSeconds"] = duration }
            if let chat = message.chat { d["chat"] = chat }
            if let sender = message.sender { d["sender"] = sender }
            if message.fromMe { d["fromMe"] = true }
            return d
        }
        var result: [String: Any] = ["total": messages.count, "returned": page.count, "voiceMessages": page]
        if !listing.notes.isEmpty { result["notes"] = listing.notes }
        return .ok(result)
    }

    // MARK: Helpers

    private func summary(of entry: TranscriptionEntry, projectNames: [UUID: String]) -> [String: Any] {
        var d: [String: Any] = [
            "id": entry.id.uuidString,
            "timestamp": Self.formatDate(entry.timestamp),
            "text": entry.text,
            "durationSeconds": (entry.durationSeconds * 10).rounded() / 10,
        ]
        if let app = entry.app { d["app"] = app.name }
        // Prefer the project's current name: the one stored on the entry is a snapshot from tagging time.
        if let pid = entry.projectID, let name = projectNames[pid] ?? entry.projectName { d["project"] = name }
        return d
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Local time with offset, e.g. 2026-09-28T14:03:12+02:00: unambiguous and still readable.
    private static let outputFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func formatDate(_ date: Date) -> String { outputFormatter.string(from: date) }

    /// Accepts a bare date (local day) or a datetime with or without seconds and
    /// timezone. Without a timezone the value is read as local time, which is
    /// what "since 14:00" means to the user.
    static func parseDate(_ raw: String, endOfDay: Bool) -> Date? {
        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let d = withZone.date(from: raw) { return d }
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withZone.date(from: raw) { return d }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: raw) { return d }
        }
        local.dateFormat = "yyyy-MM-dd"
        guard let day = local.date(from: raw) else { return nil }
        if !endOfDay { return day }
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: day)
    }
}
