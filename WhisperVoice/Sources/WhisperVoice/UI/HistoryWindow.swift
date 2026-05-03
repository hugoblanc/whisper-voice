import Cocoa

// MARK: - History Entry Details popover

/// Read-only popover that dumps every captured signal for a single entry.
/// Used from the History right-click menu so the user can understand *why*
/// a dictation was categorised the way it was.
class HistoryEntryDetailViewController: NSViewController {
    private let entry: TranscriptionEntry

    init(entry: TranscriptionEntry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))

        let scroll = NSScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(buildDetails())
        scroll.documentView = textView

        root.addSubview(scroll)
        self.view = root
    }

    private func buildDetails() -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(header("Transcription"))
        out.append(body(entry.text))
        out.append(NSAttributedString(string: "\n"))

        out.append(header("Meta"))
        out.append(kv("Recorded",  formatDate(entry.timestamp)))
        out.append(kv("Duration",  String(format: "%.1f s", entry.durationSeconds)))
        out.append(kv("Provider",  entry.provider))
        out.append(NSAttributedString(string: "\n"))

        out.append(header("App"))
        if let app = entry.app {
            out.append(kv("Name",      app.name))
            out.append(kv("Bundle ID", app.bundleID))
        } else {
            out.append(muted("(not captured)"))
        }
        out.append(NSAttributedString(string: "\n"))

        out.append(header("Signals"))
        if let s = entry.signals {
            if let v = s.windowTitle, !v.isEmpty      { out.append(kv("Window",        v)) }
            if let v = s.browserURL, !v.isEmpty       { out.append(kv("Browser URL",   v)) }
            if let v = s.browserTabTitle, !v.isEmpty  { out.append(kv("Browser Tab",   v)) }
            if let v = s.cwd, !v.isEmpty              { out.append(kv("cwd",           v)) }
            if let v = s.foregroundCmd, !v.isEmpty    { out.append(kv("Foreground",    v)) }
            if let v = s.gitRemote, !v.isEmpty        { out.append(kv("git remote",    v)) }
            if let v = s.gitBranch, !v.isEmpty        { out.append(kv("git branch",    v)) }
        } else {
            out.append(muted("(none)"))
        }
        out.append(NSAttributedString(string: "\n"))

        out.append(header("Project tag"))
        if let name = entry.projectName {
            out.append(kv("Project", name))
            if let src = entry.extras?["projectSource"] { out.append(kv("Source", src)) }
            if let reason = entry.extras?["projectReason"] { out.append(kv("Reason", reason)) }
            if let conf = entry.extras?["projectConfidence"] { out.append(kv("Confidence", conf)) }
            if let hint = ProjectPredictor.workspaceHint(bundleID: entry.app?.bundleID, windowTitle: entry.signals?.windowTitle) {
                out.append(kv("Workspace hint", hint))
            }
        } else {
            out.append(muted("Untagged"))
            if let hint = ProjectPredictor.workspaceHint(bundleID: entry.app?.bundleID, windowTitle: entry.signals?.windowTitle) {
                out.append(kv("Workspace hint", hint))
            }
        }

        // Dump extras that aren't part of the project block — future-proofing
        // so new signals land here automatically.
        if let extras = entry.extras {
            let shown: Set<String> = ["projectID", "projectName", "projectSource", "projectConfidence"]
            let remainder = extras.filter { !shown.contains($0.key) }
            if !remainder.isEmpty {
                out.append(NSAttributedString(string: "\n"))
                out.append(header("Extras"))
                for (k, v) in remainder.sorted(by: { $0.key < $1.key }) {
                    out.append(kv(k, v))
                }
            }
        }
        return out
    }

    private func header(_ s: String) -> NSAttributedString {
        NSAttributedString(string: "\(s)\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
    }
    private func body(_ s: String) -> NSAttributedString {
        NSAttributedString(string: "\(s)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
    }
    private func muted(_ s: String) -> NSAttributedString {
        NSAttributedString(string: "\(s)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
    private func kv(_ key: String, _ value: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "\(key): ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        out.append(NSAttributedString(string: "\(value)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]))
        return out
    }
    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: d)
    }
}

// MARK: - History Window

class HistoryWindow: NSObject, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var searchField: NSSearchField!
    private var projectFilterPopup: NSPopUpButton!
    /// Selected filter: nil = all, "untagged" = only entries without a project,
    /// or a UUID string for a specific project.
    private var projectFilterKey: String? = nil
    private var tableView: NSTableView!
    private var entries: [TranscriptionEntry] = []
    private var filteredEntries: [TranscriptionEntry] = []
    // Held refs for windowDidResize-based manual layout
    private var scrollView: NSScrollView!
    private var copyButton: NSButton!
    private var deleteButton: NSButton!
    private var clearButton: NSButton!

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcription History"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)

        guard let contentView = window.contentView else { return }

        // Search field (left)
        searchField = NSSearchField(frame: NSRect(x: 16, y: 410, width: 358, height: 28))
        searchField.placeholderString = "Search transcriptions..."
        searchField.delegate = self
        contentView.addSubview(searchField)

        // Project filter popup (right)
        projectFilterPopup = NSPopUpButton(frame: NSRect(x: 384, y: 410, width: 200, height: 28))
        projectFilterPopup.target = self
        projectFilterPopup.action = #selector(projectFilterChanged)
        contentView.addSubview(projectFilterPopup)
        reloadProjectFilterPopup()

        // Table view with scroll — frames recomputed in layoutSubviewsForSize on resize.
        scrollView = NSScrollView(frame: NSRect(x: 16, y: 50, width: 568, height: 350))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 60
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(copySelectedEntry)
        tableView.target = self

        // Columns
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Transcription"
        textColumn.width = 290
        textColumn.minWidth = 180
        textColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(textColumn)

        let projectColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        projectColumn.title = "Project"
        projectColumn.width = 130
        projectColumn.minWidth = 80
        projectColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(projectColumn)

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date"
        dateColumn.width = 140
        dateColumn.minWidth = 120
        dateColumn.maxWidth = 160
        dateColumn.resizingMask = .userResizingMask
        tableView.addTableColumn(dateColumn)

        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // Right-click menu (dynamic — built on open)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        // Buttons
        copyButton = NSButton(title: "Copy", target: self, action: #selector(copySelectedEntry))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: 16, y: 12, width: 80, height: 28)
        contentView.addSubview(copyButton)

        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedEntry))
        deleteButton.bezelStyle = .rounded
        deleteButton.frame = NSRect(x: 104, y: 12, width: 80, height: 28)
        contentView.addSubview(deleteButton)

        clearButton = NSButton(title: "Clear All", target: self, action: #selector(clearAllHistory))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 504, y: 12, width: 80, height: 28)
        contentView.addSubview(clearButton)

        // Initial layout pass + resize observer
        layoutSubviewsForSize(window.contentView!.bounds.size)
    }

    /// Manual layout — reproducible and simpler than autoresizingMask juggling
    /// with two top-row controls. Invoked on window resize and once at setup.
    private func layoutSubviewsForSize(_ size: NSSize) {
        let margin: CGFloat = 16
        let topY = size.height - 12 - 28          // top row 12px below window top
        let popupW: CGFloat = 200
        let searchW = max(120, size.width - margin * 3 - popupW)
        searchField.frame = NSRect(x: margin, y: topY, width: searchW, height: 28)
        projectFilterPopup.frame = NSRect(x: margin + searchW + margin, y: topY, width: popupW, height: 28)

        let tableTop = topY - 8                    // scrollview ends 8px below top row
        let tableBottomY: CGFloat = 50
        scrollView.frame = NSRect(x: margin, y: tableBottomY, width: size.width - margin * 2, height: tableTop - tableBottomY)

        copyButton.frame = NSRect(x: margin, y: 12, width: 80, height: 28)
        deleteButton.frame = NSRect(x: margin + 88, y: 12, width: 80, height: 28)
        clearButton.frame = NSRect(x: size.width - margin - 80, y: 12, width: 80, height: 28)
    }

    func windowDidResize(_ notification: Notification) {
        if let contentView = window.contentView {
            layoutSubviewsForSize(contentView.bounds.size)
        }
    }

    func show() {
        reloadData()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reloadData() {
        entries = HistoryManager.shared.getEntries()
        applyFilters()
    }

    private func applyFilters() {
        let search = searchField?.stringValue.lowercased() ?? ""
        let key = projectFilterKey
        filteredEntries = entries.filter { e in
            // Project filter
            if let key = key {
                if key == "untagged" {
                    if e.projectID != nil { return false }
                } else {
                    guard let pid = e.projectID?.uuidString, pid == key else { return false }
                }
            }
            // Text filter
            if !search.isEmpty, !e.text.lowercased().contains(search) { return false }
            return true
        }
        tableView.reloadData()
    }

    private func reloadProjectFilterPopup() {
        let prior = projectFilterKey
        projectFilterPopup.removeAllItems()

        let allItem = NSMenuItem(title: "All projects", action: nil, keyEquivalent: "")
        allItem.representedObject = nil as String?
        projectFilterPopup.menu?.addItem(allItem)

        let untaggedItem = NSMenuItem(title: "Untagged", action: nil, keyEquivalent: "")
        untaggedItem.representedObject = "untagged"
        projectFilterPopup.menu?.addItem(untaggedItem)

        projectFilterPopup.menu?.addItem(.separator())

        for project in ProjectStore.shared.active {
            let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            item.representedObject = project.id.uuidString
            projectFilterPopup.menu?.addItem(item)
        }

        // Restore prior selection
        if let prior = prior, let match = projectFilterPopup.menu?.items.first(where: { ($0.representedObject as? String) == prior }) {
            projectFilterPopup.select(match)
        } else {
            projectFilterPopup.selectItem(at: 0)
            projectFilterKey = nil
        }
    }

    @objc private func projectFilterChanged() {
        projectFilterKey = projectFilterPopup.selectedItem?.representedObject as? String
        applyFilters()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredEntries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredEntries.count, let column = tableColumn else { return nil }
        let entry = filteredEntries[row]

        let cellIdentifier = column.identifier
        var cellView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView

        if cellView == nil {
            cellView = NSTableCellView()
            cellView?.identifier = cellIdentifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.truncatesLastVisibleLine = true
            textField.maximumNumberOfLines = 2
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView?.addSubview(textField)
            cellView?.textField = textField

            // Use constraints for proper sizing
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView!.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView!.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView!.centerYAnchor)
            ])
        }

        if column.identifier.rawValue == "text" {
            cellView?.textField?.stringValue = entry.text
            cellView?.textField?.font = NSFont.systemFont(ofSize: 12)
            cellView?.textField?.textColor = .labelColor
            cellView?.textField?.alignment = .left
        } else if column.identifier.rawValue == "project" {
            if let name = entry.projectName {
                let attr = NSMutableAttributedString()
                attr.append(NSAttributedString(string: "● ",
                    attributes: [.foregroundColor: NSColor.systemGreen]))
                attr.append(NSAttributedString(string: name,
                    attributes: [.foregroundColor: NSColor.labelColor,
                                 .font: NSFont.systemFont(ofSize: 12)]))
                if let src = entry.extras?["projectSource"], src != "manual" {
                    attr.append(NSAttributedString(string: "  \(Self.shortSourceLabel(src))",
                        attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                     .font: NSFont.systemFont(ofSize: 10)]))
                }
                cellView?.textField?.attributedStringValue = attr
            } else {
                cellView?.textField?.stringValue = "—"
                cellView?.textField?.textColor = .tertiaryLabelColor
                cellView?.textField?.font = NSFont.systemFont(ofSize: 12)
            }
            cellView?.textField?.alignment = .left
        } else if column.identifier.rawValue == "date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            cellView?.textField?.stringValue = formatter.string(from: entry.timestamp)
            cellView?.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView?.textField?.textColor = .secondaryLabelColor
            cellView?.textField?.alignment = .right
        }

        return cellView
    }

    /// Short label for the projectSource extras value ("predicted" → "auto", etc).
    private static func shortSourceLabel(_ source: String) -> String {
        switch source {
        case "predicted": return "auto"
        case "retro":     return "retro"
        case "last-used": return "last"
        default:          return source
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilters()
    }

    // MARK: - NSMenuDelegate (right-click on entries)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0 && row < filteredEntries.count else { return }
        let entry = filteredEntries[row]

        let header = NSMenuItem(title: entry.projectName.map { "Tagged: \($0)" } ?? "Untagged", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let tagAs = NSMenuItem(title: "Tag as…", action: nil, keyEquivalent: "")
        let tagMenu = NSMenu()
        for project in ProjectStore.shared.active {
            let it = NSMenuItem(title: project.name, action: #selector(tagEntryAs(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = ["entryID": entry.id.uuidString, "projectID": project.id.uuidString]
            if entry.projectID == project.id { it.state = .on }
            tagMenu.addItem(it)
        }
        if !ProjectStore.shared.active.isEmpty { tagMenu.addItem(.separator()) }
        let create = NSMenuItem(title: "Create new project…", action: #selector(createAndTagEntry(_:)), keyEquivalent: "")
        create.target = self
        create.representedObject = entry.id.uuidString
        tagMenu.addItem(create)
        tagAs.submenu = tagMenu
        menu.addItem(tagAs)

        if entry.projectID != nil {
            let untag = NSMenuItem(title: "Untag", action: #selector(untagEntry(_:)), keyEquivalent: "")
            untag.target = self
            untag.representedObject = entry.id.uuidString
            menu.addItem(untag)
        }

        menu.addItem(.separator())

        let details = NSMenuItem(title: "Show details…", action: #selector(showRowDetails(_:)), keyEquivalent: "")
        details.target = self
        details.representedObject = entry.id.uuidString
        menu.addItem(details)

        let copyItem = NSMenuItem(title: "Copy text", action: #selector(copyRow(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.representedObject = entry.id.uuidString
        menu.addItem(copyItem)

        let del = NSMenuItem(title: "Delete", action: #selector(deleteRow(_:)), keyEquivalent: "")
        del.target = self
        del.representedObject = entry.id.uuidString
        menu.addItem(del)
    }

    @objc private func tagEntryAs(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let entryIDStr = payload["entryID"], let entryID = UUID(uuidString: entryIDStr),
              let projectIDStr = payload["projectID"], let projectID = UUID(uuidString: projectIDStr),
              let entry = entries.first(where: { $0.id == entryID }),
              let project = ProjectStore.shared.byID(projectID) else { return }
        applyTag(to: entry, project: project)
    }

    @objc private func untagEntry(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        let updated = entry.tagged(with: nil, source: "manual")
        HistoryManager.shared.updateEntry(updated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
    }

    @objc private func createAndTagEntry(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "New project"
        alert.informativeText = "Enter a name for the new project:"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let project = ProjectStore.shared.create(name: name)
        applyTag(to: entry, project: project)
    }

    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    @objc private func showRowDetails(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr),
              let entry = entries.first(where: { $0.id == id }) else { return }
        showDetailsPopover(for: entry)
    }

    private func showDetailsPopover(for entry: TranscriptionEntry) {
        let vc = HistoryEntryDetailViewController(entry: entry)
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        // Anchor to the clicked row if possible, else the table.
        let row = filteredEntries.firstIndex(where: { $0.id == entry.id }) ?? tableView.clickedRow
        let rect: NSRect
        let anchor: NSView
        if row >= 0, let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) {
            anchor = rowView
            rect = rowView.bounds
        } else {
            anchor = tableView
            rect = tableView.visibleRect
        }
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxX)
    }

    @objc private func deleteRow(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String, let id = UUID(uuidString: idStr) else { return }
        HistoryManager.shared.deleteEntry(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
    }

    /// Apply a project to an entry. If the entry was previously untagged, offer to
    /// propagate the tag to other untagged entries with matching signals.
    private func applyTag(to entry: TranscriptionEntry, project: Project) {
        let wasUntagged = entry.projectID == nil
        let updated = entry.tagged(with: project, source: "manual")
        HistoryManager.shared.updateEntry(updated)
        reloadProjectFilterPopup()

        if wasUntagged {
            let candidates = ProjectPredictor.findPropagationCandidates(for: entry)
            promptPropagation(project: project, candidates: candidates)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
        }
    }

    private func promptPropagation(project: Project, candidates: ProjectPredictor.PropagationCandidates) {
        // Pick the tightest signal that has matches. gitRemote is authoritative
        // (one repo = one project); then browserHost; then "same app + same
        // workspace hint" (derived from windowTitle); bundleID alone is the
        // loosest and often crosses projects (all VSCode windows share one
        // bundleID), so it's last.
        let matches: [TranscriptionEntry]
        let desc: String
        if !candidates.gitRemote.isEmpty {
            matches = candidates.gitRemote; desc = "same git remote"
        } else if !candidates.browserHost.isEmpty {
            matches = candidates.browserHost; desc = "same website"
        } else if !candidates.workspace.isEmpty, let key = candidates.workspaceKey {
            matches = candidates.workspace; desc = "same workspace “\(key)”"
        } else if !candidates.bundleID.isEmpty {
            matches = candidates.bundleID
            desc = "same app — may cross projects, review the preview"
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
            return
        }

        // Preview of the first few titles so the user can spot misses before
        // committing. Using up to 3 bullets.
        let previewLines: [String] = matches.prefix(3).map { e in
            let ctxHint = e.signals?.windowTitle ?? e.app?.name ?? "?"
            let textSnippet = e.text.prefix(40).trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(ctxHint) — \(textSnippet)…"
        }
        let moreSuffix = matches.count > 3 ? "\n…and \(matches.count - 3) more" : ""

        let alert = NSAlert()
        alert.messageText = "Tag \(matches.count) other untagged entr\(matches.count == 1 ? "y" : "ies") with “\(project.name)”?"
        alert.informativeText = "They share the \(desc).\n\n\(previewLines.joined(separator: "\n"))\(moreSuffix)"
        alert.addButton(withTitle: "Tag all")
        alert.addButton(withTitle: "Only this one")
        alert.alertStyle = .informational
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            let updates = matches.map { $0.tagged(with: project, source: "retro") }
            HistoryManager.shared.updateEntries(updates)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reloadData() }
    }

    // MARK: - Actions

    @objc private func copySelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else {
            if !filteredEntries.isEmpty {
                // Copy first entry if nothing selected
                copyToClipboard(filteredEntries[0].text)
            }
            return
        }
        copyToClipboard(filteredEntries[row].text)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        NSSound(named: "Pop")?.play()
    }

    @objc private func deleteSelectedEntry() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else { return }

        let entry = filteredEntries[row]
        HistoryManager.shared.deleteEntry(id: entry.id)
        reloadData()
    }

    @objc private func clearAllHistory() {
        let count = entries.count
        if count == 0 { return }

        // Scary confirmation — users should almost never want to nuke the whole
        // history. Single entries can be removed via Delete / right-click.
        let alert = NSAlert()
        alert.messageText = "⚠️ Delete ALL \(count) transcription\(count == 1 ? "" : "s")?"
        alert.informativeText = """
            Cette action supprime définitivement toutes tes dictées, leur contexte (projet, app, git, URL), et les exports JSONL associés. Irréversible, aucun backup.

            Pour supprimer une entrée seule, ferme cette fenêtre puis utilise Delete ou le menu clic-droit → Delete.

            Tape DELETE ci-dessous pour confirmer.
            """
        alert.alertStyle = .critical

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "DELETE"
        alert.accessoryView = input

        let cancelButton = alert.addButton(withTitle: "Cancel")          // First = default = Cancel
        let deleteButton = alert.addButton(withTitle: "Delete everything") // Destructive
        deleteButton.hasDestructiveAction = true
        alert.window.initialFirstResponder = input
        _ = cancelButton  // silence unused

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }
        guard input.stringValue.trimmingCharacters(in: .whitespaces) == "DELETE" else {
            let err = NSAlert()
            err.messageText = "Confirmation failed"
            err.informativeText = "Tu dois taper DELETE exactement (majuscules). Rien n'a été supprimé."
            err.alertStyle = .warning
            err.addButton(withTitle: "OK")
            err.runModal()
            return
        }
        HistoryManager.shared.clearHistory()
        reloadData()
    }
}
