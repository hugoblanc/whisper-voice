import Cocoa
import Carbon.HIToolbox

// MARK: - Clipboard & Paste

func pasteText(_ text: String) {
    // Copy to clipboard — dual format when markup is detected.
    // Plain text: the markdown source (consumed by Terminal, Claude Code, editors).
    // HTML: rendered Slack-flavored markup (consumed by Slack WYSIWYG, Notion, Gmail…).
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if slackMarkupDetected(text), let html = slackMarkdownToHTML(text) {
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(html, forType: .html)
        LogManager.shared.log("[Paste] wrote plain + HTML (\(html.count) chars)")
    } else {
        pasteboard.setString(text, forType: .string)
    }

    // Simulate Cmd+V
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

/// Cheap check: does this string contain any Slack-style markup worth rendering?
/// Returns false for plain prose to avoid burning HTML clipboard unnecessarily.
private func slackMarkupDetected(_ s: String) -> Bool {
    if s.contains("```") { return true }
    if s.contains("`") { return true }
    // Single-asterisk bold like *foo* (Slack syntax). Avoid matching isolated `*`.
    if s.range(of: #"\*[^\s*][^*]*\*"#, options: .regularExpression) != nil { return true }
    // Underscore italic like _foo_ — must be word-boundary to avoid snake_case hits.
    if s.range(of: #"(^|\s)_[^\s_][^_]*_(\s|$|[.,!?;:])"#, options: .regularExpression) != nil { return true }
    // Blockquote or bullet list line.
    if s.range(of: #"(^|\n)(>|•|-\s)"#, options: .regularExpression) != nil { return true }
    return false
}

/// Slack-flavored markdown → HTML. Supports: ```fenced```, `inline code`, *bold*,
/// _italic_, >blockquote, • / - bullets, paragraph breaks.
/// Not a general markdown parser — scoped to what our Slack mode prompt emits.
private func slackMarkdownToHTML(_ md: String) -> String? {
    // Step 1: pull out fenced code blocks (```...```) as placeholders so their
    // content escapes unchanged and inner markup is not re-parsed.
    var codeBlocks: [String] = []
    var inlineCodes: [String] = []
    func escapeHTML(_ s: String) -> String {
        return s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
    }
    var work = md
    // Fenced code blocks
    while let range = work.range(of: #"```([\s\S]*?)```"#, options: .regularExpression) {
        let matched = String(work[range])
        let inner = String(matched.dropFirst(3).dropLast(3))
        let escaped = escapeHTML(inner).trimmingCharacters(in: .newlines)
        codeBlocks.append("<pre><code>\(escaped)</code></pre>")
        work.replaceSubrange(range, with: "\u{0001}CB\(codeBlocks.count - 1)\u{0001}")
    }
    // Inline code
    while let range = work.range(of: #"`([^`\n]+)`"#, options: .regularExpression) {
        let matched = String(work[range])
        let inner = String(matched.dropFirst().dropLast())
        inlineCodes.append("<code>\(escapeHTML(inner))</code>")
        work.replaceSubrange(range, with: "\u{0001}IC\(inlineCodes.count - 1)\u{0001}")
    }
    // Now escape the remaining content (outside code).
    work = escapeHTML(work)

    // Bold *foo* → <strong>foo</strong>
    work = work.replacingOccurrences(of: #"\*([^\s*][^*]*?)\*"#, with: "<strong>$1</strong>", options: .regularExpression)
    // Italic _foo_ → <em>foo</em>  (word-boundary safe)
    work = work.replacingOccurrences(of: #"(^|\s)_([^\s_][^_]*?)_(\s|$|[.,!?;:])"#, with: "$1<em>$2</em>$3", options: .regularExpression)

    // Line-based passes: blockquotes, bullets, paragraphs.
    let lines = work.components(separatedBy: "\n")
    var html = ""
    var inList = false
    var inQuote = false
    func closeBlocks() {
        if inList { html += "</ul>"; inList = false }
        if inQuote { html += "</blockquote>"; inQuote = false }
    }
    for raw in lines {
        let line = raw
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("&gt;") {
            if !inQuote { closeBlocks(); html += "<blockquote>"; inQuote = true }
            let content = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            html += content + "<br>"
        } else if trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") {
            if inQuote { html += "</blockquote>"; inQuote = false }
            if !inList { html += "<ul>"; inList = true }
            let content = String(trimmed.dropFirst(2))
            html += "<li>\(content)</li>"
        } else if trimmed.isEmpty {
            closeBlocks()
            html += "<p></p>"
        } else {
            closeBlocks()
            html += "<p>\(line)</p>"
        }
    }
    closeBlocks()

    // Re-insert placeholders
    for (i, block) in codeBlocks.enumerated() {
        html = html.replacingOccurrences(of: "\u{0001}CB\(i)\u{0001}", with: block)
    }
    for (i, code) in inlineCodes.enumerated() {
        html = html.replacingOccurrences(of: "\u{0001}IC\(i)\u{0001}", with: code)
    }
    // Wrap in minimal HTML so clipboard consumers see a valid fragment.
    return "<html><body>\(html)</body></html>"
}

// MARK: - Enter key tap (CGEvent-level, suppresses propagation)

var enterToggleHandler: (() -> Void)?
var enterEventTapGlobal: CFMachPort?

func enterKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = enterEventTapGlobal {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let hasCommand = event.flags.contains(.maskCommand)

    if keyCode == Int64(kVK_Return) && !hasCommand {
        if type == .keyDown {
            DispatchQueue.main.async { enterToggleHandler?() }
        }
        return nil
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Post-transcription action execution

func simulateKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    if !flags.isEmpty {
        keyDown?.flags = flags
        keyUp?.flags = flags
    }
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

func simulateEnterKey() {
    simulateKey(CGKeyCode(kVK_Return))
}

func copyToClipboard(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}

func executePostAction(action: PostAction, text: String, rawText: String, context: DictationContext?) {
    switch action.type {
    case "paste":
        pasteText(text)

    case "pasteEnter":
        pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            simulateEnterKey()
        }

    case "copy":
        copyToClipboard(text)

    case "pasteTab":
        pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            simulateKey(CGKeyCode(kVK_Tab))
        }

    case "pasteSend":
        pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            simulateKey(CGKeyCode(kVK_Return), flags: .maskCommand)
        }

    case "pasteEscape":
        pasteText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            simulateKey(CGKeyCode(kVK_Escape))
        }

    case "command":
        guard let command = action.command.nilIfEmpty else {
            LogManager.shared.log("[PostAction] Command action has empty command, falling back to paste", level: "WARNING")
            pasteText(text)
            return
        }
        let env: [String: String] = [
            "WV_TRANSCRIPTION": text,
            "WV_RAW_TRANSCRIPTION": rawText,
            "WV_APP_BUNDLE_ID": context?.app?.bundleID ?? "",
            "WV_APP_NAME": context?.app?.name ?? "",
            "WV_MODE": ModeManager.shared.currentMode.id,
            "WV_PROJECT": context?.extras?["projectName"] ?? ""
        ]
        executeShellCommand(command, env: env)

    default:
        pasteText(text)
    }
}

private func executeShellCommand(_ command: String, env: [String: String]) {
    LogManager.shared.log("[PostAction] Running command: \(command.prefix(120))")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

    let pipe = Pipe()
    process.standardError = pipe

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try process.run()
            process.waitUntilExit()
            let status = process.terminationStatus
            if status != 0 {
                let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                LogManager.shared.log("[PostAction] Command exited with status \(status): \(stderr.prefix(200))", level: "WARNING")
            } else {
                LogManager.shared.log("[PostAction] Command completed successfully")
            }
        } catch {
            LogManager.shared.log("[PostAction] Command failed: \(error.localizedDescription)", level: "ERROR")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
