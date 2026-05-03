import Cocoa
import AVFoundation

// MARK: - Audio Recorder

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var tempFileURL: URL?

    var isRecording: Bool {
        return audioRecorder?.isRecording ?? false
    }

    /// Get current audio level (0.0 to 1.0) for waveform visualization
    var currentLevel: Float {
        guard let recorder = audioRecorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        // Convert decibels (-160 to 0) to linear (0 to 1)
        let minDb: Float = -60
        let level = max(0, (decibels - minDb) / (-minDb))
        return min(1, level)
    }

    func startRecording() -> Bool {
        // Make sure mic permission is granted; on .notDetermined, trigger the macOS
        // system prompt. First call returns false but macOS will show the prompt —
        // user grants, next press works normally.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                LogManager.shared.log("[AudioRecorder] Mic permission \(granted ? "granted" : "denied") after prompt")
            }
            LogManager.shared.log("[AudioRecorder] Requesting mic permission — accept the macOS prompt then try again", level: "WARN")
            return false
        case .denied, .restricted:
            LogManager.shared.log("[AudioRecorder] Mic permission denied — open System Settings > Privacy > Microphone to grant", level: "ERROR")
            return false
        case .authorized:
            break
        @unknown default:
            break
        }

        let tempDir = FileManager.default.temporaryDirectory
        tempFileURL = tempDir.appendingPathComponent("whisper_recording_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: tempFileURL!, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true  // Enable metering for waveform
            audioRecorder?.record()
            return true
        } catch {
            print("Failed to start recording: \(error)")
            return false
        }
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        return tempFileURL
    }

    func cleanup() {
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        tempFileURL = nil
    }
}
