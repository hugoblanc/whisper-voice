import SwiftUI
import AppKit

// MARK: - MCP pane

/// One-click registration of the Whisper Voice MCP server in AI clients.
struct MCPPane: View {
    @State private var statuses: [String: MCPInstaller.Status] = [:]
    @State private var claudeCodeStatus: MCPInstaller.Status = .notInstalled
    @State private var message: (text: String, isError: Bool)?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text("Give Claude and other AI assistants access to your dictation history: search what you dictated, filter by app, project or date, and transcribe audio files. The server runs locally from this app; your history never leaves your Mac, except audio you ask to transcribe, which goes to your configured provider.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Desktop apps") {
                ForEach(MCPInstaller.clients) { client in
                    clientRow(client)
                }
                if let message = message {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(message.isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Claude Code") {
                HStack {
                    statusBadge(claudeCodeStatus)
                    Spacer()
                    Button(copied ? "Copied" : "Copy command") { copyClaudeCodeCommand() }
                }
                Text(MCPInstaller.claudeCodeCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Run it once in a terminal. It registers the server for all your projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Other clients") {
                Text("Any MCP client can launch the server over stdio with this command:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("'\(MCPInstaller.executablePath)' --mcp")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func clientRow(_ client: MCPInstaller.Client) -> some View {
        let status = statuses[client.id] ?? .notDetected
        return HStack {
            Text(client.name)
            Spacer()
            statusBadge(status)
            switch status {
            case .notDetected:
                EmptyView()
            case .installed:
                Button("Remove") { run(client, install: false) }
            case .outdated:
                Button("Update") { run(client, install: true) }
            case .notInstalled, .unreadable:
                Button("Add") { run(client, install: true) }
                    .disabled(status != .notInstalled)
            }
        }
        .help(helpText(for: status, client: client))
    }

    @ViewBuilder
    private func statusBadge(_ status: MCPInstaller.Status) -> some View {
        switch status {
        case .notDetected:
            Text("Not installed on this Mac").font(.caption).foregroundStyle(.secondary)
        case .notInstalled:
            Text("Not connected").font(.caption).foregroundStyle(.secondary)
        case .installed:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .outdated:
            Label("Points to another copy of the app", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .unreadable:
            Label("Config not readable", systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    private func helpText(for status: MCPInstaller.Status, client: MCPInstaller.Client) -> String {
        if case .unreadable(let reason) = status { return reason }
        return client.configURL.path
    }

    private func run(_ client: MCPInstaller.Client, install: Bool) {
        do {
            if install {
                try MCPInstaller.install(into: client)
                message = ("Added to \(client.name). \(client.restartHint)", false)
            } else {
                try MCPInstaller.uninstall(from: client)
                message = ("Removed from \(client.name). \(client.restartHint)", false)
            }
        } catch {
            message = (error.localizedDescription, true)
            LogManager.shared.log("[MCP] \(client.name) config update failed: \(error.localizedDescription)", level: "ERROR")
        }
        refresh()
    }

    private func copyClaudeCodeCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPInstaller.claudeCodeCommand, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func refresh() {
        var next: [String: MCPInstaller.Status] = [:]
        for client in MCPInstaller.clients { next[client.id] = MCPInstaller.status(of: client) }
        statuses = next
        claudeCodeStatus = MCPInstaller.claudeCodeStatus
    }
}
