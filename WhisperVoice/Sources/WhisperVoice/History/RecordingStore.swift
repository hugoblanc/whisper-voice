import Foundation

class RecordingStore {
    static let shared = RecordingStore()

    private let maxRecordings = 5
    private let recordingsDir: URL
    private let metadataURL: URL
    private let queue = DispatchQueue(label: "com.whispervoice.recordingstore")

    struct RecordingMetadata: Codable {
        let id: UUID
        let timestamp: Date
        let filename: String
        let durationSeconds: Double
        let provider: String
        let modeName: String
        var transcriptionStatus: String  // "pending", "success", "failed"
        var transcribedText: String?
        var lastError: String?
    }

    private(set) var recordings: [RecordingMetadata] = []

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperVoice")
        recordingsDir = appSupport.appendingPathComponent("recordings")
        metadataURL = recordingsDir.appendingPathComponent("recordings.json")
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        loadMetadata()
    }

    private func loadMetadata() {
        queue.sync {
            guard let data = try? Data(contentsOf: metadataURL),
                  let decoded = try? JSONDecoder().decode([RecordingMetadata].self, from: data) else {
                return
            }
            recordings = decoded
        }
    }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(recordings) {
            try? data.write(to: metadataURL)
        }
    }

    func saveRecording(from tempURL: URL, duration: Double, provider: String, modeName: String) -> RecordingMetadata? {
        let id = UUID()
        let ext = tempURL.pathExtension.isEmpty ? "wav" : tempURL.pathExtension.lowercased()
        let filename = "recording_\(id.uuidString).\(ext)"
        let destURL = recordingsDir.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        } catch {
            LogManager.shared.log("[RecordingStore] Failed to save recording: \(error)", level: "ERROR")
            return nil
        }

        let metadata = RecordingMetadata(
            id: id,
            timestamp: Date(),
            filename: filename,
            durationSeconds: duration,
            provider: provider,
            modeName: modeName,
            transcriptionStatus: "pending"
        )

        queue.sync {
            recordings.insert(metadata, at: 0)
            enforceLimit()
            saveMetadata()
        }

        LogManager.shared.log("[RecordingStore] Saved recording \(filename) (\(Int(duration))s)")
        return metadata
    }

    func markSuccess(id: UUID, text: String) {
        queue.sync {
            guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
            recordings[idx].transcriptionStatus = "success"
            recordings[idx].transcribedText = text
            recordings[idx].lastError = nil
            saveMetadata()
        }
    }

    func markFailed(id: UUID, error: String) {
        queue.sync {
            guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
            recordings[idx].transcriptionStatus = "failed"
            recordings[idx].lastError = error
            saveMetadata()
        }
    }

    func audioURL(for recording: RecordingMetadata) -> URL {
        recordingsDir.appendingPathComponent(recording.filename)
    }

    func audioExists(for recording: RecordingMetadata) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: recording).path)
    }

    func deleteRecording(id: UUID) {
        queue.sync {
            guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
            let recording = recordings[idx]
            let url = recordingsDir.appendingPathComponent(recording.filename)
            try? FileManager.default.removeItem(at: url)
            recordings.remove(at: idx)
            saveMetadata()
        }
    }

    func getRecordings() -> [RecordingMetadata] {
        queue.sync { recordings }
    }

    private func enforceLimit() {
        while recordings.count > maxRecordings {
            let oldest = recordings.removeLast()
            let url = recordingsDir.appendingPathComponent(oldest.filename)
            try? FileManager.default.removeItem(at: url)
            LogManager.shared.log("[RecordingStore] Rotated out old recording: \(oldest.filename)")
        }
    }
}
