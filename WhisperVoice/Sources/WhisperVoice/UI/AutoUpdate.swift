import Cocoa

// MARK: - Auto Update

struct UpdateInfo {
    let version: String
    let downloadURL: URL?
    let releaseNotes: String
}

class UpdateChecker {
    static let currentVersion = "3.6.1"
    private static let repoOwner = "hugoblanc"
    private static let repoName = "whisper-voice"

    static func checkForUpdates(completion: @escaping (UpdateInfo?) -> Void) {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Parse version from tag (e.g., "v3.2.0" -> "3.2.0")
            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            // Compare versions
            guard isVersion(remoteVersion, newerThan: currentVersion) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Find DMG download URL from assets
            let downloadURL: URL? = {
                guard let assets = json["assets"] as? [[String: Any]] else { return nil }
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                       let urlStr = asset["browser_download_url"] as? String,
                       let url = URL(string: urlStr) {
                        return url
                    }
                }
                return nil
            }()

            let releaseNotes = json["body"] as? String ?? ""

            DispatchQueue.main.async {
                completion(UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: releaseNotes))
            }
        }.resume()
    }

    private static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(parts1.count, parts2.count)

        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
}

class UpdateWindow: NSObject, URLSessionDownloadDelegate {
    private var window: NSWindow!
    private var progressBar: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var downloadButton: NSButton!
    private var laterButton: NSButton!
    private let updateInfo: UpdateInfo
    private var downloadTask: URLSessionDownloadTask?

    init(updateInfo: UpdateInfo) {
        self.updateInfo = updateInfo
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Update Available"
        window.center()
        window.isReleasedWhenClosed = false

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true

        // Title
        let titleLabel = NSTextField(labelWithString: "Whisper Voice v\(updateInfo.version) is available!")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 15)
        titleLabel.frame = NSRect(x: 20, y: 260, width: 380, height: 25)
        contentView.addSubview(titleLabel)

        let currentLabel = NSTextField(labelWithString: "You are currently running v\(UpdateChecker.currentVersion)")
        currentLabel.font = NSFont.systemFont(ofSize: 12)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.frame = NSRect(x: 20, y: 238, width: 380, height: 20)
        contentView.addSubview(currentLabel)

        // Release notes
        let notesLabel = NSTextField(labelWithString: "Release Notes:")
        notesLabel.font = NSFont.boldSystemFont(ofSize: 12)
        notesLabel.frame = NSRect(x: 20, y: 212, width: 380, height: 18)
        contentView.addSubview(notesLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 90, width: 380, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let notesTextView = NSTextView(frame: scrollView.bounds)
        notesTextView.string = updateInfo.releaseNotes.isEmpty ? "No release notes available." : updateInfo.releaseNotes
        notesTextView.isEditable = false
        notesTextView.font = NSFont.systemFont(ofSize: 12)
        notesTextView.autoresizingMask = [.width, .height]
        scrollView.documentView = notesTextView
        contentView.addSubview(scrollView)

        // Progress bar (hidden initially)
        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 62, width: 380, height: 20))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        contentView.addSubview(progressBar)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 42, width: 380, height: 18)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        contentView.addSubview(statusLabel)

        // Buttons
        laterButton = NSButton(title: "Later", target: self, action: #selector(laterClicked))
        laterButton.bezelStyle = .rounded
        laterButton.frame = NSRect(x: 220, y: 10, width: 80, height: 32)
        contentView.addSubview(laterButton)

        downloadButton = NSButton(title: "Download & Install", target: self, action: #selector(downloadClicked))
        downloadButton.bezelStyle = .rounded
        downloadButton.frame = NSRect(x: 310, y: 10, width: 100, height: 32)
        downloadButton.keyEquivalent = "\r"
        contentView.addSubview(downloadButton)

        if updateInfo.downloadURL == nil {
            downloadButton.isEnabled = false
            statusLabel.stringValue = "No DMG download available for this release."
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func laterClicked() {
        downloadTask?.cancel()
        // Remember skipped version so we don't prompt again until next release
        if var config = Config.load() {
            config.skippedUpdateVersion = updateInfo.version
            config.save()
        }
        window.close()
    }

    @objc private func downloadClicked() {
        guard let downloadURL = updateInfo.downloadURL else { return }

        downloadButton.isEnabled = false
        laterButton.title = "Cancel"
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        statusLabel.stringValue = "Downloading..."

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadTask = session.downloadTask(with: downloadURL)
        downloadTask?.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperVoice-\(updateInfo.version).dmg")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)

        do {
            try FileManager.default.moveItem(at: location, to: destURL)
            statusLabel.stringValue = "Installing update..."
            LogManager.shared.log("[Update] Downloaded update to \(destURL.path)")

            // Auto-install from DMG
            DispatchQueue.global().async { [weak self] in
                self?.installFromDMG(dmgPath: destURL.path)
            }
        } catch {
            statusLabel.stringValue = "Failed to save download: \(error.localizedDescription)"
            downloadButton.isEnabled = true
            LogManager.shared.log("[Update] Failed to save DMG: \(error.localizedDescription)", level: "ERROR")
        }
    }

    private func installFromDMG(dmgPath: String) {
        // 1. Mount DMG silently
        let mountProcess = Process()
        mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountProcess.arguments = ["attach", dmgPath, "-nobrowse", "-plist"]
        let pipe = Pipe()
        mountProcess.standardOutput = pipe
        mountProcess.standardError = FileHandle.nullDevice

        do {
            try mountProcess.run()
        } catch {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Failed to mount DMG."
                self.downloadButton.isEnabled = true
            }
            return
        }
        mountProcess.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()

        // 2. Parse mount point from plist output
        guard let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Failed to find mounted volume."
                self.downloadButton.isEnabled = true
            }
            return
        }

        // 3. Find .app in mounted volume
        let volumeURL = URL(fileURLWithPath: mountPoint)
        let appName = "Whisper Voice.app"
        let sourceApp = volumeURL.appendingPathComponent(appName).path
        let destApp = "/Applications/\(appName)"

        guard FileManager.default.fileExists(atPath: sourceApp) else {
            // Unmount and fail
            Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-quiet"])
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "App not found in DMG."
                self.downloadButton.isEnabled = true
            }
            return
        }

        // 4. Remove old app, copy new one
        do {
            if FileManager.default.fileExists(atPath: destApp) {
                try FileManager.default.removeItem(atPath: destApp)
            }
            try FileManager.default.copyItem(atPath: sourceApp, toPath: destApp)
            LogManager.shared.log("[Update] Installed update to \(destApp)")
        } catch {
            Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-quiet"])
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "Failed to install: \(error.localizedDescription)"
                self.downloadButton.isEnabled = true
            }
            return
        }

        // 5. Unmount DMG
        Process.launchedProcess(launchPath: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-quiet"])

        // 6. UI: propose restart
        DispatchQueue.main.async {
            self.progressBar.isHidden = true
            self.statusLabel.stringValue = "Update installed! Restart to apply."
            self.downloadButton.title = "Restart"
            self.downloadButton.isEnabled = true
            self.downloadButton.target = self
            self.downloadButton.action = #selector(self.restartApp)
            self.laterButton.title = "Later"
        }
    }

    @objc private func restartApp() {
        let appPath = "/Applications/Whisper Voice.app"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appPath]
            try? task.run()
        }
        NSApp.terminate(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressBar.doubleValue = progress
            let mb = Double(totalBytesWritten) / 1_000_000
            let totalMb = Double(totalBytesExpectedToWrite) / 1_000_000
            statusLabel.stringValue = String(format: "Downloading... %.1f / %.1f MB", mb, totalMb)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            statusLabel.stringValue = "Download cancelled."
            progressBar.isHidden = true
            downloadButton.isEnabled = true
            laterButton.title = "Later"
        } else if let error = error {
            statusLabel.stringValue = "Download failed: \(error.localizedDescription)"
            progressBar.isHidden = true
            downloadButton.isEnabled = true
            laterButton.title = "Later"
        }
    }
}
