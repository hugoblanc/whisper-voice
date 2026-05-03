import Foundation

// MARK: - Projects

struct Project: Codable, Identifiable {
    let id: UUID
    var name: String
    var color: String?
    var createdAt: Date
    var archived: Bool

    init(id: UUID = UUID(), name: String, color: String? = nil, createdAt: Date = Date(), archived: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.archived = archived
    }
}

/// Owns ~/Library/Application Support/WhisperVoice/projects.json. Same
/// queue pattern as HistoryManager so reads/writes are thread-safe.
class ProjectStore {
    static let shared = ProjectStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.whispervoice.projects")
    private var projectsByID: [UUID: Project] = [:]

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("projects.json")
        loadFromDisk()
    }

    private func loadFromDisk() {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["projects"] as? [[String: Any]] else { return }
            for dict in list {
                guard let idStr = dict["id"] as? String, let id = UUID(uuidString: idStr),
                      let name = dict["name"] as? String else { continue }
                let color = dict["color"] as? String
                let createdAtTS = dict["createdAt"] as? TimeInterval ?? 0
                let archived = dict["archived"] as? Bool ?? false
                let project = Project(id: id, name: name, color: color,
                                      createdAt: Date(timeIntervalSince1970: createdAtTS),
                                      archived: archived)
                projectsByID[id] = project
            }
        }
    }

    private func saveToDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let list: [[String: Any]] = self.projectsByID.values.map { p in
                var d: [String: Any] = [
                    "id": p.id.uuidString,
                    "name": p.name,
                    "createdAt": p.createdAt.timeIntervalSince1970,
                    "archived": p.archived
                ]
                if let c = p.color { d["color"] = c }
                return d
            }
            let root: [String: Any] = ["projects": list, "version": 1]
            if let data = try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted) {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    var all: [Project] {
        queue.sync { projectsByID.values.sorted { $0.createdAt < $1.createdAt } }
    }

    var active: [Project] {
        all.filter { !$0.archived }
    }

    func byID(_ id: UUID) -> Project? {
        queue.sync { projectsByID[id] }
    }

    /// Case-insensitive name lookup on active projects, used to avoid dups when the user types.
    func byName(_ name: String) -> Project? {
        let needle = name.lowercased()
        return queue.sync {
            projectsByID.values.first(where: { $0.name.lowercased() == needle && !$0.archived })
        }
    }

    @discardableResult
    func create(name: String) -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = byName(trimmed) { return existing }
        let project = Project(name: trimmed)
        queue.sync { projectsByID[project.id] = project }
        saveToDisk()
        return project
    }

    func rename(_ id: UUID, to newName: String) {
        queue.sync {
            guard var p = projectsByID[id] else { return }
            p.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            projectsByID[id] = p
        }
        saveToDisk()
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        queue.sync {
            guard var p = projectsByID[id] else { return }
            p.archived = archived
            projectsByID[id] = p
        }
        saveToDisk()
    }

    func delete(_ id: UUID) {
        queue.sync { _ = projectsByID.removeValue(forKey: id) }
        saveToDisk()
    }
}

struct ProjectPrediction {
    let project: Project?
    let confidence: Double
    let reason: String
    /// "predicted" when the top tier found a match, "last-used" for fallback, "none" for neither.
    let source: String
}

/// Stateless predictor. Queries the existing history for entries that share
/// a signal with the current context and returns the most frequently tagged
/// project among them. No separate rule store — the history is the ground truth.
enum ProjectPredictor {
    /// Window of recent entries considered for prediction, seconds.
    private static let recencyWindow: TimeInterval = 90 * 24 * 60 * 60

    static func predict(ctx: DictationContext?) -> ProjectPrediction {
        guard let ctx = ctx else { return fallback(reason: "no-context") }

        let now = Date()
        let entries = HistoryManager.shared.getEntries().filter {
            now.timeIntervalSince($0.timestamp) <= recencyWindow
        }
        let activeIDs = Set(ProjectStore.shared.active.map { $0.id })

        // Tier 1 — gitRemote (deterministic)
        if let remote = ctx.signals?.gitRemote, !remote.isEmpty {
            let key = normalize(remote)
            let matches = entries.filter { normalize($0.signals?.gitRemote ?? "") == key && activeIDs.contains($0.projectID ?? UUID()) }
            if let best = mostCommonProject(in: matches) {
                return ProjectPrediction(project: best.project, confidence: 0.95,
                                         reason: "gitRemote: \(remote)", source: "predicted")
            }
        }

        // Tier 2 — browser host
        if let url = ctx.signals?.browserURL, let host = urlHost(url) {
            let matches = entries.filter {
                guard let otherURL = $0.signals?.browserURL, let otherHost = urlHost(otherURL) else { return false }
                return otherHost == host && activeIDs.contains($0.projectID ?? UUID())
            }
            if matches.count >= 2, let best = mostCommonProject(in: matches) {
                return ProjectPrediction(project: best.project, confidence: 0.80,
                                         reason: "host: \(host)", source: "predicted")
            }
        }

        // Tier 3 — workspace hint (bundleID + derived-from-windowTitle workspace slug)
        // Covers IDEs / terminals where the same app hosts multiple projects.
        if let bundleID = ctx.app?.bundleID,
           let hint = workspaceHint(bundleID: bundleID, windowTitle: ctx.signals?.windowTitle) {
            let matches = entries.filter {
                guard $0.app?.bundleID == bundleID,
                      let other = workspaceHint(bundleID: bundleID, windowTitle: $0.signals?.windowTitle) else { return false }
                return other == hint && activeIDs.contains($0.projectID ?? UUID())
            }
            if matches.count >= 2, let best = mostCommonProject(in: matches), best.ratio >= 0.6 {
                return ProjectPrediction(project: best.project, confidence: 0.75,
                                         reason: "\(ctx.app?.name ?? bundleID) · \(hint)",
                                         source: "predicted")
            }
        }

        // Tier 4 — bundleID alone, only when user has overwhelmingly tagged
        // this app with one project (>= 5 matches, >= 80% agreement). Higher
        // bars than V1 because bundleID-only is the tier most likely to leak
        // tags across similar apps (e.g. every VSCode dictation as superproper).
        if let bundleID = ctx.app?.bundleID {
            let matches = entries.filter { $0.app?.bundleID == bundleID && activeIDs.contains($0.projectID ?? UUID()) }
            if matches.count >= 5 {
                if let best = mostCommonProject(in: matches), best.ratio >= 0.8 {
                    return ProjectPrediction(project: best.project, confidence: 0.50,
                                             reason: "app: \(ctx.app?.name ?? bundleID)", source: "predicted")
                }
            }
        }

        return fallback(reason: "no-match")
    }

    /// When the user tags a previously-untagged entry in History, offer to tag the
    /// other untagged entries that share a strong signal. Returns matches grouped
    /// by signal so the UI can describe (and pick) what's being propagated.
    struct PropagationCandidates {
        var gitRemote: [TranscriptionEntry] = []
        var browserHost: [TranscriptionEntry] = []
        /// bundleID + workspace slug (IDE/Terminal): tighter than bundleID alone.
        var workspace: [TranscriptionEntry] = []
        var workspaceKey: String? = nil
        /// bundleID alone: the loosest signal, offered last.
        var bundleID: [TranscriptionEntry] = []
    }

    static func findPropagationCandidates(for seed: TranscriptionEntry) -> PropagationCandidates {
        let pool = HistoryManager.shared.getEntries().filter { $0.projectID == nil && $0.id != seed.id }
        var out = PropagationCandidates()

        if let remote = seed.signals?.gitRemote, !remote.isEmpty {
            let key = normalize(remote)
            out.gitRemote = pool.filter { normalize($0.signals?.gitRemote ?? "") == key }
        }
        if let url = seed.signals?.browserURL, let h = urlHost(url) {
            out.browserHost = pool.filter {
                guard let otherURL = $0.signals?.browserURL, let otherHost = urlHost(otherURL) else { return false }
                return otherHost == h
            }
        }
        if let bID = seed.app?.bundleID,
           let hint = workspaceHint(bundleID: bID, windowTitle: seed.signals?.windowTitle) {
            out.workspaceKey = hint
            out.workspace = pool.filter {
                $0.app?.bundleID == bID &&
                    workspaceHint(bundleID: bID, windowTitle: $0.signals?.windowTitle) == hint
            }
        }
        if let bID = seed.app?.bundleID {
            out.bundleID = pool.filter { $0.app?.bundleID == bID }
        }
        return out
    }

    /// Extract a stable workspace slug from a windowTitle for apps where the
    /// bundleID alone is too broad (same app hosts many projects). Returns
    /// nil when we can't extract anything reliable.
    static func workspaceHint(bundleID: String?, windowTitle: String?) -> String? {
        guard let title = windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        guard let bundleID = bundleID else { return nil }

        // Known IDE / editor bundles — title format is usually "file — folder".
        let ideBundles: Set<String> = [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",          // Cursor
            "com.apple.dt.Xcode",
            "com.sublimetext.4",
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.jetbrains.webstorm",
            "com.jetbrains.goland",
            "co.codeedit.CodeEdit",
            "dev.zed.Zed",
        ]

        if ideBundles.contains(bundleID) {
            // Try em-dash first, then en-dash, then hyphen-with-spaces.
            for sep in [" — ", " – ", " - "] {
                if title.contains(sep) {
                    if let last = title.components(separatedBy: sep).last {
                        let slug = last.trimmingCharacters(in: .whitespaces).lowercased()
                        if !slug.isEmpty && slug.count < 80 { return slug }
                    }
                }
            }
            // No separator — title IS the slug (e.g. just a folder name)
            return title.lowercased()
        }

        // Known terminal bundles — the first segment before the em-dash is
        // usually the cwd folder (Terminal.app / iTerm2 / Ghostty / Warp…).
        let terminalBundles: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "dev.warp.Warp", "io.alacritty",
            "com.github.wez.wezterm", "net.kovidgoyal.kitty", "co.zeit.hyper",
        ]
        if terminalBundles.contains(bundleID) {
            for sep in [" — ", " – ", " - "] {
                if title.contains(sep) {
                    if let first = title.components(separatedBy: sep).first {
                        let slug = first.trimmingCharacters(in: .whitespaces).lowercased()
                        if !slug.isEmpty && slug.count < 80 { return slug }
                    }
                }
            }
            return title.lowercased()
        }

        // Unknown app — don't attempt extraction. Caller falls through to
        // bundleID-only matching (which has a higher confidence threshold).
        return nil
    }

    // MARK: helpers

    private static func fallback(reason: String) -> ProjectPrediction {
        let config = Config.load()
        if let idStr = config?.lastUsedProjectID, !idStr.isEmpty, let uuid = UUID(uuidString: idStr),
           let p = ProjectStore.shared.byID(uuid), !p.archived {
            return ProjectPrediction(project: p, confidence: 0.30, reason: "last-used", source: "last-used")
        }
        return ProjectPrediction(project: nil, confidence: 0.0, reason: reason, source: "none")
    }

    private static func mostCommonProject(in entries: [TranscriptionEntry]) -> (project: Project, count: Int, ratio: Double)? {
        var counts: [UUID: Int] = [:]
        var total = 0
        for e in entries {
            if let id = e.projectID { counts[id, default: 0] += 1; total += 1 }
        }
        guard total > 0,
              let (winnerID, winnerCount) = counts.max(by: { $0.value < $1.value }),
              let project = ProjectStore.shared.byID(winnerID) else { return nil }
        return (project, winnerCount, Double(winnerCount) / Double(total))
    }

    private static func normalize(_ remote: String) -> String {
        var s = remote.lowercased().trimmingCharacters(in: .whitespaces)
        // Strip .git suffix, prefixes, protocol variations
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        s = s.replacingOccurrences(of: "https://", with: "")
        s = s.replacingOccurrences(of: "http://", with: "")
        s = s.replacingOccurrences(of: "ssh://", with: "")
        s = s.replacingOccurrences(of: "git@", with: "")
        s = s.replacingOccurrences(of: ":", with: "/")  // github.com:user/repo → github.com/user/repo
        return s
    }

    private static func urlHost(_ urlString: String) -> String? {
        guard let u = URL(string: urlString), let host = u.host else { return nil }
        return host.lowercased()
    }
}

extension TranscriptionEntry {
    /// Convenience accessor — project tag is stored in extras for backward compat.
    var projectID: UUID? {
        guard let s = extras?["projectID"], let id = UUID(uuidString: s) else { return nil }
        return id
    }
    var projectName: String? { extras?["projectName"] }

    /// Return a copy with the project tag set (or cleared if nil).
    func tagged(with project: Project?, source: String) -> TranscriptionEntry {
        var copy = self
        var newExtras = copy.extras ?? [:]
        if let project = project {
            newExtras["projectID"] = project.id.uuidString
            newExtras["projectName"] = project.name
            newExtras["projectSource"] = source
        } else {
            newExtras.removeValue(forKey: "projectID")
            newExtras.removeValue(forKey: "projectName")
            newExtras.removeValue(forKey: "projectSource")
        }
        copy.extras = newExtras.isEmpty ? nil : newExtras
        return copy
    }
}
