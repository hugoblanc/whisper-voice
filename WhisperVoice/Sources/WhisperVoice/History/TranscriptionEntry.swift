import Foundation

// MARK: - Transcription History

struct AppInfo: Codable {
    let bundleID: String
    let name: String
}

struct DictationSignals: Codable {
    var windowTitle: String?
    var browserURL: String?
    var browserTabTitle: String?
    var cwd: String?
    var foregroundCmd: String?
    var gitRemote: String?
    var gitBranch: String?
}

struct TranscriptionEntry: Codable {
    let id: UUID
    let timestamp: Date
    let text: String
    let durationSeconds: Double
    let provider: String
    var app: AppInfo?
    var signals: DictationSignals?
    var extras: [String: String]?

    init(text: String,
         durationSeconds: Double,
         provider: String,
         app: AppInfo? = nil,
         signals: DictationSignals? = nil,
         extras: [String: String]? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.text = text
        self.durationSeconds = durationSeconds
        self.provider = provider
        self.app = app
        self.signals = signals
        self.extras = extras
    }
}

class HistoryManager {
    static let shared = HistoryManager()

    private let historyFileURL: URL
    private let exportDirURL: URL
    private let migrationSentinelURL: URL
    private var entries: [TranscriptionEntry] = []
    private let queue = DispatchQueue(label: "com.whispervoice.history")

    // Shared date formatter for JSONL filenames (YYYY-MM-DD in local timezone)
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    // Encoder used for both history.json and JSONL lines; emits dates as Apple
    // reference-date doubles to stay wire-compatible with the legacy file.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        historyFileURL = appSupport.appendingPathComponent("history.json")

        // Exports live under Application Support (no TCC "Folders & Files"
        // permission needed, unlike ~/Documents on Hardened Runtime).
        exportDirURL = appSupport.appendingPathComponent("exports")
        migrationSentinelURL = exportDirURL.appendingPathComponent(".migrated-v1")
        try? FileManager.default.createDirectory(at: exportDirURL, withIntermediateDirectories: true)

        loadHistory()
        migrateToJSONLIfNeeded()
    }

    private func loadHistory() {
        queue.sync {
            guard let data = try? Data(contentsOf: historyFileURL),
                  let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data) else {
                return
            }
            entries = decoded
        }
    }

    private func saveHistory() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? JSONEncoder().encode(self.entries) {
                try? data.write(to: self.historyFileURL)
            }
        }
    }

    func addEntry(_ entry: TranscriptionEntry) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.insert(entry, at: 0)
            self.saveHistory()
            self.appendToJSONL(entry)
        }
    }

    // MARK: JSONL export

    /// Append one entry as a single JSON line to the day's JSONL file.
    /// Called from `queue` — no additional sync needed.
    private func appendToJSONL(_ entry: TranscriptionEntry) {
        do {
            let day = Self.dayFormatter.string(from: entry.timestamp)
            let fileURL = exportDirURL.appendingPathComponent("\(day).jsonl")
            var line = try Self.encoder.encode(entry)
            line.append(0x0A)  // newline

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            LogManager.shared.log("[HistoryManager] JSONL append failed: \(error)", level: "ERROR")
        }
    }

    /// One-time backfill of the JSONL directory from `history.json`.
    /// Writes a sentinel file to guarantee it runs at most once. Existing
    /// JSONL files are preserved (no overwrite) so re-runs are safe.
    private func migrateToJSONLIfNeeded() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.migrationSentinelURL.path) { return }
            guard !self.entries.isEmpty else {
                try? "migrated at \(Date()) — nothing to migrate\n".write(
                    to: self.migrationSentinelURL, atomically: true, encoding: .utf8)
                return
            }

            // Group by day (using each entry's own timestamp, in local tz).
            var byDay: [String: [TranscriptionEntry]] = [:]
            for entry in self.entries {
                let key = Self.dayFormatter.string(from: entry.timestamp)
                byDay[key, default: []].append(entry)
            }

            var totalWritten = 0
            var filesWritten = 0
            var filesSkipped = 0

            for (day, entriesForDay) in byDay {
                let fileURL = self.exportDirURL.appendingPathComponent("\(day).jsonl")
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    filesSkipped += 1
                    continue
                }
                // Chronological order within a day (history.json is newest-first)
                let sorted = entriesForDay.sorted { $0.timestamp < $1.timestamp }
                var blob = Data()
                for entry in sorted {
                    if let data = try? Self.encoder.encode(entry) {
                        blob.append(data)
                        blob.append(0x0A)
                        totalWritten += 1
                    }
                }
                if (try? blob.write(to: fileURL, options: .atomic)) != nil {
                    filesWritten += 1
                }
            }

            let stamp = "migrated at \(Date()) — wrote \(totalWritten) entries across \(filesWritten) files (\(filesSkipped) skipped)\n"
            try? stamp.write(to: self.migrationSentinelURL, atomically: true, encoding: .utf8)
            LogManager.shared.log("[HistoryManager] JSONL migration: \(totalWritten) entries, \(filesWritten) files, \(filesSkipped) skipped")
        }
    }

    func getEntries() -> [TranscriptionEntry] {
        return queue.sync { entries }
    }

    func search(query: String) -> [TranscriptionEntry] {
        return queue.sync {
            if query.isEmpty { return entries }
            return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    func deleteEntry(id: UUID) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll { $0.id == id }
            self.saveHistory()
        }
    }

    func clearHistory() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll()
            self.saveHistory()
        }
    }

    /// Replace an entry in-place (used for retro-tagging). The JSONL export is
    /// append-only raw data so it isn't rewritten — the tag lives in the JSON
    /// history until we add a dedicated update-log later.
    func updateEntry(_ updated: TranscriptionEntry) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.entries.firstIndex(where: { $0.id == updated.id }) {
                self.entries[idx] = updated
                self.saveHistory()
            }
        }
    }

    func updateEntries(_ updates: [TranscriptionEntry]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var dirty = false
            for u in updates {
                if let idx = self.entries.firstIndex(where: { $0.id == u.id }) {
                    self.entries[idx] = u
                    dirty = true
                }
            }
            if dirty { self.saveHistory() }
        }
    }
}
