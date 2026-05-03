import Cocoa
import ApplicationServices

// MARK: - Context Capture

struct DictationContext {
    let app: AppInfo?
    let signals: DictationSignals?
    let extras: [String: String]?
}

class ContextCapturer {
    static let shared = ContextCapturer()

    private static let knownBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.kagi.kagimacOS",           // Orion
    ]

    private static let knownTerminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.alacritty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
    ]

    private let queue = DispatchQueue(label: "com.whispervoice.context", qos: .userInitiated)

    /// Capture dictation context off the main thread. Completion fires on main queue.
    func captureNow(completion: @escaping (DictationContext?) -> Void) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            completion(nil)
            return
        }
        let appInfo = AppInfo(bundleID: bundleID, name: frontApp.localizedName ?? bundleID)
        let pid = frontApp.processIdentifier

        queue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var signals = DictationSignals()
            signals.windowTitle = self.focusedWindowTitle(pid: pid)

            if Self.knownBrowsers.contains(bundleID) {
                if let tab = self.captureBrowserURL(bundleID: bundleID) {
                    signals.browserURL = tab.url
                    signals.browserTabTitle = tab.title
                }
            } else if Self.knownTerminals.contains(bundleID) {
                let term = self.captureTerminalContext(rootPid: pid)
                signals.cwd = term.cwd
                signals.foregroundCmd = term.foregroundCmd
                signals.gitRemote = term.gitRemote
                signals.gitBranch = term.gitBranch
            }

            let ctx = DictationContext(app: appInfo, signals: signals, extras: nil)
            DispatchQueue.main.async { completion(ctx) }
        }
    }

    // MARK: Window title via AXUIElement

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowRef = focused else {
            return nil
        }
        let window = windowRef as! AXUIElement
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    // MARK: Browser URL via AppleScript

    private func captureBrowserURL(bundleID: String) -> (url: String, title: String)? {
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                set tabURL to URL of current tab of front window
                set tabName to name of current tab of front window
                return tabURL & linefeed & tabName
            end tell
            """
        case "company.thebrowser.Browser":
            script = """
            tell application "Arc"
                if (count of windows) is 0 then return ""
                set tabURL to URL of active tab of front window
                set tabTitle to title of active tab of front window
                return tabURL & linefeed & tabTitle
            end tell
            """
        default:
            let appName: String
            switch bundleID {
            case "com.google.Chrome": appName = "Google Chrome"
            case "com.google.Chrome.canary": appName = "Google Chrome Canary"
            case "com.brave.Browser": appName = "Brave Browser"
            case "com.vivaldi.Vivaldi": appName = "Vivaldi"
            case "com.microsoft.edgemac": appName = "Microsoft Edge"
            case "com.operasoftware.Opera": appName = "Opera"
            default: return nil   // Firefox / Orion: no reliable AppleScript URL API
            }
            script = """
            tell application "\(appName)"
                if (count of windows) is 0 then return ""
                set tabURL to URL of active tab of front window
                set tabTitle to title of active tab of front window
                return tabURL & linefeed & tabTitle
            end tell
            """
        }

        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let descriptor = appleScript.executeAndReturnError(&errorDict)
        if let err = errorDict {
            LogManager.shared.log("[ContextCapturer] AppleScript error for \(bundleID): \(err)", level: "DEBUG")
            return nil
        }
        guard let raw = descriptor.stringValue, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 2 else { return nil }
        return (url: parts[0], title: parts.dropFirst().joined(separator: "\n"))
    }

    // MARK: Terminal context via process tree + lsof

    private struct TerminalSnapshot {
        var cwd: String?
        var foregroundCmd: String?
        var gitRemote: String?
        var gitBranch: String?
    }

    private func captureTerminalContext(rootPid: pid_t) -> TerminalSnapshot {
        var snap = TerminalSnapshot()
        guard let leaf = findDeepestDescendant(of: rootPid) else { return snap }
        snap.foregroundCmd = processName(pid: leaf)
        snap.cwd = cwdForPid(leaf)
        if let cwd = snap.cwd, let git = gitInfo(cwd: cwd) {
            snap.gitRemote = git.remote
            snap.gitBranch = git.branch
        }
        return snap
    }

    private func findDeepestDescendant(of rootPid: pid_t) -> pid_t? {
        guard let output = runProcess("/bin/ps", args: ["-eo", "pid,ppid"]) else { return nil }
        var children: [pid_t: [pid_t]] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        var deepest: (pid: pid_t, depth: Int) = (rootPid, 0)
        var stack: [(pid_t, Int)] = [(rootPid, 0)]
        while let (pid, depth) = stack.popLast() {
            if depth > deepest.depth { deepest = (pid, depth) }
            for child in children[pid] ?? [] {
                stack.append((child, depth + 1))
            }
        }
        return deepest.pid == rootPid ? nil : deepest.pid
    }

    private func processName(pid: pid_t) -> String? {
        guard let raw = runProcess("/bin/ps", args: ["-o", "comm=", "-p", String(pid)]) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return (trimmed as NSString).lastPathComponent
    }

    private func cwdForPid(_ pid: pid_t) -> String? {
        guard let output = runProcess("/usr/sbin/lsof", args: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else {
            return nil
        }
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private func gitInfo(cwd: String) -> (remote: String?, branch: String?)? {
        var dir = cwd
        let fm = FileManager.default
        while !dir.isEmpty && dir != "/" {
            let head = dir + "/.git/HEAD"
            if fm.fileExists(atPath: head) {
                let branch = readGitBranch(headPath: head)
                let remote = readGitRemote(configPath: dir + "/.git/config")
                return (remote: remote, branch: branch)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private func readGitBranch(headPath: String) -> String? {
        guard let content = try? String(contentsOfFile: headPath) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(12))
    }

    private func readGitRemote(configPath: String) -> String? {
        guard let content = try? String(contentsOfFile: configPath) else { return nil }
        var inOrigin = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[remote") {
                inOrigin = line.contains("\"origin\"")
            } else if inOrigin, line.hasPrefix("url") {
                if let eq = line.firstIndex(of: "=") {
                    return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    // MARK: Process runner with timeout

    private func runProcess(_ path: String, args: [String], timeout: TimeInterval = 0.3) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        do {
            try task.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
