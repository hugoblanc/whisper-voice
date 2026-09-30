import Foundation
import SQLite3

// MARK: - Voice Message Finder

/// Finds voice messages already on this Mac, so an MCP client can transcribe
/// them without the user exporting anything: WhatsApp desktop's own media
/// store, and audio files saved to ~/Downloads (where Slack clips and
/// WhatsApp Web exports land).
///
/// WhatsApp's store is opened read-only and its schema is not a public
/// contract: any failure becomes a note next to what the other source found,
/// never an error for the whole listing.
enum VoiceMessageFinder {

    enum Source: String, CaseIterable {
        case whatsapp
        case downloads
    }

    struct VoiceMessage {
        let path: String
        let source: Source
        let timestamp: Date
        var durationSeconds: Int?
        /// WhatsApp conversation name (contact or group).
        var chat: String?
        /// Who recorded it, when it is not the user.
        var sender: String?
        var fromMe = false
    }

    struct Listing {
        var messages: [VoiceMessage] = []
        var notes: [String] = []
    }

    /// Audio-only extensions: ~/Downloads also holds mp4/webm videos that are not voice messages.
    private static let downloadExtensions: Set<String> = [
        "wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "ogg", "oga", "opus", "flac", "amr",
    ]

    /// Regular WhatsApp and WhatsApp Business keep the same layout in their group container.
    private static let whatsAppContainers = [
        "group.net.whatsapp.WhatsApp.shared",
        "group.net.whatsapp.WhatsAppSMB.shared",
    ]

    /// Upper bound on rows read from WhatsApp before filtering by name.
    private static let whatsAppRowLimit = 2000

    static func find(sources: Set<Source>, since: Date?) -> Listing {
        var listing = Listing()
        if sources.contains(.whatsapp) { collectWhatsApp(since: since, into: &listing) }
        if sources.contains(.downloads) { collectDownloads(since: since, into: &listing) }
        listing.messages.sort { $0.timestamp > $1.timestamp }
        return listing
    }

    // MARK: WhatsApp

    /// ZMESSAGETYPE 3 is an audio message. ZMEDIALOCALPATH is only set once the
    /// media has been downloaded, and is relative to the container's Message folder.
    private static let whatsAppQuery = """
    SELECT mi.ZMEDIALOCALPATH, mi.ZMOVIEDURATION, m.ZMESSAGEDATE, m.ZISFROMME,
           c.ZPARTNERNAME, gm.Z_PK, gm.ZCONTACTNAME, pn.ZPUSHNAME, gm.ZFIRSTNAME
    FROM ZWAMESSAGE m
    JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK
    JOIN ZWACHATSESSION c ON m.ZCHATSESSION = c.Z_PK
    LEFT JOIN ZWAGROUPMEMBER gm ON m.ZGROUPMEMBER = gm.Z_PK
    LEFT JOIN ZWAPROFILEPUSHNAME pn ON pn.ZJID = gm.ZMEMBERJID
    WHERE m.ZMESSAGETYPE = 3 AND mi.ZMEDIALOCALPATH IS NOT NULL AND m.ZMESSAGEDATE >= ?
    ORDER BY m.ZMESSAGEDATE DESC
    LIMIT ?
    """

    private static func collectWhatsApp(since: Date?, into listing: inout Listing) {
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
        var foundStore = false
        for name in whatsAppContainers {
            let container = containers.appendingPathComponent(name)
            let database = container.appendingPathComponent("ChatStorage.sqlite")
            guard FileManager.default.fileExists(atPath: database.path) else { continue }
            foundStore = true
            if let problem = readWhatsApp(database: database,
                                          mediaRoot: container.appendingPathComponent("Message"),
                                          since: since, into: &listing) {
                listing.notes.append("WhatsApp: \(problem)")
            }
        }
        if !foundStore {
            // A denied container looks the same as a missing one from here.
            listing.notes.append("WhatsApp: no local message store found. Either WhatsApp desktop is not installed, or macOS denied the app running this MCP server access to WhatsApp's data.")
        }
    }

    /// Returns a description of what went wrong, or nil.
    private static func readWhatsApp(database: URL, mediaRoot: URL, since: Date?, into listing: inout Listing) -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return "could not open the message store (\(String(cString: sqlite3_errmsg(db))))."
        }
        // WhatsApp writes to this database while we read it.
        sqlite3_busy_timeout(db, 2000)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, whatsAppQuery, -1, &statement, nil) == SQLITE_OK else {
            return "could not query the message store, its format may have changed (\(String(cString: sqlite3_errmsg(db))))."
        }
        // Core Data stores dates as seconds since 2001, same as Date's reference date.
        sqlite3_bind_double(statement, 1, since?.timeIntervalSinceReferenceDate ?? 0)
        sqlite3_bind_int(statement, 2, Int32(whatsAppRowLimit))

        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            guard let relativePath = text(statement, 0) else { continue }
            let file = mediaRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }

            var message = VoiceMessage(path: file.path, source: .whatsapp,
                                       timestamp: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)))
            let duration = Int(sqlite3_column_int64(statement, 1))
            if duration > 0 { message.durationSeconds = duration }
            message.fromMe = sqlite3_column_int(statement, 3) != 0
            message.chat = text(statement, 4)
            if !message.fromMe {
                let isGroupMessage = sqlite3_column_type(statement, 5) != SQLITE_NULL
                message.sender = isGroupMessage
                    ? text(statement, 6) ?? text(statement, 7) ?? text(statement, 8)
                    : message.chat
            }
            listing.messages.append(message)
        }
        guard status == SQLITE_DONE else {
            return "reading the message store stopped early (\(String(cString: sqlite3_errmsg(db))))."
        }
        return nil
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: Downloads

    private static func collectDownloads(since: Date?, into listing: inout Listing) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])
        } catch {
            listing.notes.append("Downloads: could not list \(folder.path) (\(error.localizedDescription)).")
            return
        }
        for file in files where downloadExtensions.contains(file.pathExtension.lowercased()) {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // "Date added" is when the download landed; the other dates can come from the sender.
            guard let date = values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate else { continue }
            if let since = since, date < since { continue }
            listing.messages.append(VoiceMessage(path: file.path, source: .downloads, timestamp: date))
        }
    }
}
