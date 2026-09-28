import Foundation

// MARK: - MCP Client Installer

/// Registers the Whisper Voice MCP server in the config file of desktop MCP
/// clients. Every client gets the same entry: this app's own executable, run
/// with `--mcp`. Pointing at the executable inside the installed .app means an
/// app update also updates the server, with nothing else to install.
enum MCPInstaller {
    static let serverKey = MCPServer.serverName

    struct Client: Identifiable {
        let id: String
        let name: String
        /// The client's config file.
        let configURL: URL
        /// Present only when the client is installed; we never create it.
        let detectionURL: URL
        /// Top-level object holding the servers: "mcpServers" for most clients, "servers" for VS Code.
        let rootKey: String
        let needsTypeField: Bool
        let restartHint: String
    }

    enum Status: Equatable {
        case notDetected
        case notInstalled
        case installed
        /// Registered, but with another command (the app moved, or an older entry).
        case outdated
        case unreadable(String)
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let clients: [Client] = [
        Client(id: "claude-desktop", name: "Claude Desktop",
               configURL: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
               detectionURL: home.appendingPathComponent("Library/Application Support/Claude"),
               rootKey: "mcpServers", needsTypeField: false,
               restartHint: "Quit and reopen Claude Desktop to load it."),
        Client(id: "cursor", name: "Cursor",
               configURL: home.appendingPathComponent(".cursor/mcp.json"),
               detectionURL: home.appendingPathComponent(".cursor"),
               rootKey: "mcpServers", needsTypeField: false,
               restartHint: "Cursor picks it up in Settings → MCP."),
        Client(id: "windsurf", name: "Windsurf",
               configURL: home.appendingPathComponent(".codeium/windsurf/mcp_config.json"),
               detectionURL: home.appendingPathComponent(".codeium/windsurf"),
               rootKey: "mcpServers", needsTypeField: false,
               restartHint: "Refresh the MCP list in Windsurf's Cascade panel."),
        Client(id: "vscode", name: "VS Code",
               configURL: home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"),
               detectionURL: home.appendingPathComponent("Library/Application Support/Code/User"),
               rootKey: "servers", needsTypeField: true,
               restartHint: "Start it from the MCP view in VS Code."),
    ]

    /// This very binary. When running from the installed app it resolves to
    /// /Applications/Whisper Voice.app/Contents/MacOS/WhisperVoice.
    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Whisper Voice.app/Contents/MacOS/WhisperVoice"
    }

    /// Claude Code keeps user-scoped servers in ~/.claude.json, a large file it
    /// rewrites constantly, so we hand the user its own CLI command instead of editing it.
    static var claudeCodeCommand: String {
        "claude mcp add --scope user \(serverKey) -- '\(executablePath)' --mcp"
    }

    static var claudeCodeStatus: Status {
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .notInstalled }
        guard let entry = (root["mcpServers"] as? [String: Any])?[serverKey] as? [String: Any] else { return .notInstalled }
        return isCurrent(entry) ? .installed : .outdated
    }

    static func status(of client: Client) -> Status {
        guard FileManager.default.fileExists(atPath: client.detectionURL.path) else { return .notDetected }
        switch readConfig(client) {
        case .failure(let error):
            return .unreadable(error.localizedDescription)
        case .success(let root):
            guard let entry = (root[client.rootKey] as? [String: Any])?[serverKey] as? [String: Any] else {
                return .notInstalled
            }
            return isCurrent(entry) ? .installed : .outdated
        }
    }

    static func install(into client: Client) throws {
        var root = try readConfig(client).get()
        var servers = root[client.rootKey] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": executablePath, "args": ["--mcp"]]
        if client.needsTypeField { entry["type"] = "stdio" }
        servers[serverKey] = entry
        root[client.rootKey] = servers
        try writeConfig(root, for: client)
        LogManager.shared.log("[MCP] Registered server in \(client.name) (\(client.configURL.path))")
    }

    static func uninstall(from client: Client) throws {
        var root = try readConfig(client).get()
        guard var servers = root[client.rootKey] as? [String: Any], servers[serverKey] != nil else { return }
        servers.removeValue(forKey: serverKey)
        root[client.rootKey] = servers
        try writeConfig(root, for: client)
        LogManager.shared.log("[MCP] Removed server from \(client.name)")
    }

    // MARK: Private

    private static func isCurrent(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String) == executablePath && (entry["args"] as? [String]) == ["--mcp"]
    }

    /// A missing file is an empty config. A file we cannot parse (comments,
    /// trailing commas…) is an error: rewriting it would lose the user's other servers.
    private static func readConfig(_ client: Client) -> Result<[String: Any], Error> {
        guard FileManager.default.fileExists(atPath: client.configURL.path) else { return .success([:]) }
        do {
            let data = try Data(contentsOf: client.configURL)
            if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .success([:]) }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(InstallerError.notAnObject(client.configURL.path))
            }
            return .success(root)
        } catch {
            return .failure(InstallerError.unparsable(client.configURL.path))
        }
    }

    private static func writeConfig(_ root: [String: Any], for client: Client) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: client.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: client.configURL.path) {
            let backup = client.configURL.appendingPathExtension("whispervoice-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: client.configURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: client.configURL, options: .atomic)
    }

    enum InstallerError: LocalizedError {
        case unparsable(String)
        case notAnObject(String)

        var errorDescription: String? {
            switch self {
            case .unparsable(let path): return "\(path) is not plain JSON (comments or trailing commas?). Add the server by hand."
            case .notAnObject(let path): return "\(path) does not contain a JSON object."
            }
        }
    }
}
