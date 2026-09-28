import Foundation

// MARK: - MCP Server (stdio)

/// Model Context Protocol server, started when the app binary is launched with
/// `--mcp` by an MCP client (Claude Desktop, Claude Code, Cursor…). It speaks
/// JSON-RPC 2.0 over stdin/stdout, one message per line. stdout carries protocol
/// messages only: anything else written there corrupts the stream, which is why
/// LogManager is switched to stderr before the server starts.
///
/// Supports both protocol eras: the stateless one (`server/discover`, version in
/// each request's `_meta`) and the legacy `initialize` handshake.
final class MCPServer {
    static let serverName = "whisper-voice"

    /// Newest first. The first legacy entry is what we answer to an `initialize`
    /// asking for a version we don't know.
    static let supportedVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let latestLegacyVersion = "2025-11-25"
    private static let versionMetaKey = "io.modelcontextprotocol/protocolVersion"
    private static let serverInfoMetaKey = "io.modelcontextprotocol/serverInfo"

    private static let instructions = """
    Whisper Voice is the user's macOS dictation app. Every dictation is kept in a local history \
    with the text, the time, the app it was dictated into and an optional project tag. \
    Use search_transcriptions to find what the user dictated (filter by words, date range, app or project), \
    get_transcription for one entry's full context (window title, browser URL, terminal directory), \
    list_projects to see the project tags, and transcribe_audio_file to turn a local audio file into text \
    with the user's configured provider.
    """

    private let tools = MCPTools()
    private let outputQueue = DispatchQueue(label: "com.whispervoice.mcp.output")
    private let workQueue = DispatchQueue(label: "com.whispervoice.mcp.work", attributes: .concurrent)
    private let inFlight = DispatchGroup()

    private var serverInfo: [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return ["name": Self.serverName, "title": "Whisper Voice", "version": version]
    }

    /// Blocks forever. Exits the process when stdin closes (the client went away).
    func run() -> Never {
        LogManager.shared.log("[MCP] Server started (pid \(ProcessInfo.processInfo.processIdentifier))")
        let reader = Thread { [self] in
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                inFlight.enter()
                workQueue.async { [self] in
                    defer { inFlight.leave() }
                    handle(line: trimmed)
                }
            }
            // stdin closed: let running tool calls answer, then leave.
            inFlight.wait()
            outputQueue.sync {}
            LogManager.shared.log("[MCP] stdin closed, exiting")
            exit(0)
        }
        reader.start()
        dispatchMain()
    }

    // MARK: Dispatch

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(error: -32700, message: "Parse error", id: NSNull())
            return
        }
        guard let method = message["method"] as? String else {
            // A response to a server-initiated request. We never send any.
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else {
            // Notification (notifications/initialized, notifications/cancelled…): nothing to answer.
            return
        }

        let meta = params["_meta"] as? [String: Any]
        let requestedVersion = meta?[Self.versionMetaKey] as? String
        if let requested = requestedVersion, !Self.supportedVersions.contains(requested) {
            send(error: -32022, message: "Unsupported protocol version", id: id,
                 data: ["supported": Self.supportedVersions, "requested": requested])
            return
        }
        // Stateless-era clients expect the server to identify itself in every result.
        let isModern = requestedVersion != nil

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? Self.latestLegacyVersion
            let version = Self.supportedVersions.contains(asked) ? asked : Self.latestLegacyVersion
            send(result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": serverInfo,
                "instructions": Self.instructions,
            ], id: id, modern: false)

        case "server/discover":
            send(result: [
                "supportedVersions": Self.supportedVersions,
                "capabilities": ["tools": [String: Any]()],
                "instructions": Self.instructions,
            ], id: id, modern: true)

        case "ping":
            send(result: [:], id: id, modern: isModern)

        case "tools/list":
            send(result: ["tools": MCPTools.definitions], id: id, modern: isModern)

        case "tools/call":
            guard let name = params["name"] as? String else {
                send(error: -32602, message: "Missing tool name", id: id)
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard MCPTools.definitions.contains(where: { $0["name"] as? String == name }) else {
                send(error: -32602, message: "Unknown tool: \(name)", id: id)
                return
            }
            let started = Date()
            let outcome = tools.call(name: name, arguments: arguments)
            LogManager.shared.log(String(format: "[MCP] %@ %@ in %.2fs", name,
                                         outcome.isError ? "failed" : "ok", Date().timeIntervalSince(started)))
            send(result: outcome.asResult(), id: id, modern: isModern)

        default:
            send(error: -32601, message: "Method not found: \(method)", id: id)
        }
    }

    // MARK: Output

    private func send(result: [String: Any], id: Any, modern: Bool) {
        var result = result
        result["resultType"] = "complete"
        if modern {
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta[Self.serverInfoMetaKey] = serverInfo
            result["_meta"] = meta
        }
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(error code: Int, message: String, id: Any, data: [String: Any]? = nil) {
        var error: [String: Any] = ["code": code, "message": message]
        if let data = data { error["data"] = data }
        write(["jsonrpc": "2.0", "id": id, "error": error])
    }

    private func write(_ object: [String: Any]) {
        // .withoutEscapingSlashes keeps paths readable; JSONSerialization never
        // emits raw newlines, which the line-delimited transport forbids.
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else {
            LogManager.shared.log("[MCP] Failed to encode a response", level: "ERROR")
            return
        }
        data.append(0x0A)
        outputQueue.sync {
            FileHandle.standardOutput.write(data)
        }
    }
}
