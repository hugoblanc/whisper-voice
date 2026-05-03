import Cocoa
import os.log

let logger = Logger(subsystem: "com.whispervoice", category: "main")

// MARK: - Log Manager

class LogManager {
    static let shared = LogManager()

    private let logFileURL: URL
    private var logEntries: [String] = []
    private let maxLogEntries = 1000
    private let queue = DispatchQueue(label: "com.whispervoice.logmanager")

    private init() {
        // Create Application Support directory if needed
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        logFileURL = appSupport.appendingPathComponent("logs.txt")

        // Load existing logs
        loadLogs()
    }

    private func loadLogs() {
        queue.sync {
            if let contents = try? String(contentsOf: logFileURL, encoding: .utf8) {
                logEntries = contents.components(separatedBy: "\n").filter { !$0.isEmpty }
                // Keep only recent entries
                if logEntries.count > maxLogEntries {
                    logEntries = Array(logEntries.suffix(maxLogEntries))
                }
            }
        }
    }

    func log(_ message: String, level: String = "INFO") {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: Date())
        let entry = "\(timestamp) [\(level)] \(message)"

        queue.async { [weak self] in
            guard let self = self else { return }

            self.logEntries.append(entry)

            // Trim if too many entries
            if self.logEntries.count > self.maxLogEntries {
                self.logEntries = Array(self.logEntries.suffix(self.maxLogEntries))
            }

            // Write to file
            let content = self.logEntries.joined(separator: "\n")
            try? content.write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }

        // Also log to os.log
        switch level {
        case "ERROR":
            logger.error("\(message)")
        case "WARNING":
            logger.warning("\(message)")
        default:
            logger.info("\(message)")
        }
    }

    func getRecentLogs(count: Int = 100) -> [String] {
        return queue.sync {
            return Array(logEntries.suffix(count))
        }
    }

    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.logEntries.removeAll()
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }
    }
}

// Safe array access extension
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}


extension NSColor {
    /// Parse "#rrggbb" or "rrggbb" into an NSColor, nil on malformed input.
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xff) / 255
        let g = CGFloat((v >> 8) & 0xff) / 255
        let b = CGFloat(v & 0xff) / 255
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }
}
