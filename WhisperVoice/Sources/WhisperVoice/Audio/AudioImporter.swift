import Foundation
import AVFoundation

// MARK: - Audio Importer
//
// Robust pre-transcription pass for arbitrary audio files (MP3, M4A, Opus,
// WhatsApp voice notes, etc.). Tries to transcode to a canonical 16 kHz mono
// PCM WAV via AVFoundation. If decoding fails but the source format is one
// the transcription API accepts natively, the original file is forwarded
// unchanged.

enum AudioImporterError: LocalizedError {
    case noAudioTrack
    case readerSetupFailed(String)
    case writerSetupFailed(String)
    case conversionFailed(String)
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "File contains no audio track."
        case .readerSetupFailed(let m): return "Could not read audio: \(m)"
        case .writerSetupFailed(let m): return "Could not prepare audio for transcription: \(m)"
        case .conversionFailed(let m): return "Audio conversion failed: \(m)"
        case .unreadableFile: return "File could not be opened."
        }
    }
}

struct PreparedAudio {
    let url: URL
    let isTemporary: Bool
}

enum AudioImporter {
    /// Extensions the transcription APIs (OpenAI Whisper + Mistral Voxtral)
    /// accept natively. Used as a fall-back set when on-device transcoding
    /// fails — the bytes are forwarded as-is with the correct MIME type.
    static let apiSupportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "mpeg", "mpga",
        "oga", "ogg", "opus", "flac", "webm", "aac"
    ]

    /// Common audio formats the file picker should accept. Anything
    /// AVFoundation can decode will be transcoded; anything it can't but the
    /// API still accepts will be forwarded raw.
    static let pickerExtensions: [String] = [
        "wav", "aiff", "aif", "caf",
        "mp3", "m4a", "aac", "mp4",
        "ogg", "oga", "opus",
        "flac", "webm", "amr", "3gp"
    ]

    /// Prepare a user-imported audio file for upload. Runs off the main
    /// thread; the completion is invoked on a background queue — callers
    /// should hop back to main themselves if needed.
    static func prepare(_ sourceURL: URL,
                        completion: @escaping (Result<PreparedAudio, Error>) -> Void) {
        let ext = sourceURL.pathExtension.lowercased()

        Task.detached(priority: .userInitiated) {
            do {
                let prepared = try await transcodeToWav(sourceURL)
                completion(.success(prepared))
            } catch {
                LogManager.shared.log(
                    "[AudioImporter] Transcode failed for .\(ext): \(error.localizedDescription)",
                    level: "WARN")
                if apiSupportedExtensions.contains(ext) {
                    LogManager.shared.log(
                        "[AudioImporter] Forwarding original file (.\(ext) is API-supported)")
                    completion(.success(PreparedAudio(url: sourceURL, isTemporary: false)))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Transcoding

    private static func transcodeToWav(_ sourceURL: URL) async throws -> PreparedAudio {
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw AudioImporterError.unreadableFile
        }

        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioImporterError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString).wav")

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioImporterError.readerSetupFailed(error.localizedDescription)
        }

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        guard reader.canAdd(readerOutput) else {
            throw AudioImporterError.readerSetupFailed("output unsupported")
        }
        reader.add(readerOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        } catch {
            throw AudioImporterError.writerSetupFailed(error.localizedDescription)
        }

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw AudioImporterError.writerSetupFailed("input unsupported")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "startReading failed"
            throw AudioImporterError.conversionFailed(msg)
        }
        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "startWriting failed"
            throw AudioImporterError.conversionFailed(msg)
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.whispervoice.audioimporter.write")
        let pumpError: AudioImporterError? = await withCheckedContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if reader.status != .reading {
                        writerInput.markAsFinished()
                        continuation.resume(returning: nil)
                        return
                    }
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(sample) {
                            let msg = writer.error?.localizedDescription ?? "append failed"
                            writerInput.markAsFinished()
                            continuation.resume(returning: .conversionFailed(msg))
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume(returning: nil)
                        return
                    }
                }
            }
        }

        if let pumpError = pumpError {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw pumpError
        }

        await writer.finishWriting()

        if writer.status != .completed || reader.status == .failed {
            let msg = writer.error?.localizedDescription
                ?? reader.error?.localizedDescription
                ?? "writer status \(writer.status.rawValue)"
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioImporterError.conversionFailed(msg)
        }

        LogManager.shared.log(
            "[AudioImporter] Transcoded \(sourceURL.lastPathComponent) → 16kHz mono WAV")
        return PreparedAudio(url: outputURL, isTemporary: true)
    }
}
