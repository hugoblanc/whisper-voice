import sounddevice as sd
import scipy.io.wavfile as wav
import numpy as np
import tempfile
import time

SAMPLE_RATE = 16000  # Whisper works well with 16kHz


def log(msg):
    """Log with timestamp."""
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] [recorder] {msg}")


class Recorder:
    def __init__(self):
        self.recording = False
        self.frames = []

    def start(self):
        """Start audio recording."""
        self.frames = []
        self.recording = True
        self.stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype=np.int16,
            callback=self._callback
        )
        self.stream.start()

    def _callback(self, indata, frames, time, status):
        """Callback called for each audio block."""
        if self.recording:
            self.frames.append(indata.copy())

    def stop(self) -> str:
        """Stop recording and save as WAV. Returns the file path."""
        log("Setting recording flag to False...")
        self.recording = False

        log("Stopping stream...")
        self.stream.stop()

        log("Closing stream...")
        self.stream.close()

        log(f"Frames collected: {len(self.frames)}")
        if not self.frames:
            return None

        log("Concatenating audio frames...")
        audio_data = np.concatenate(self.frames, axis=0)
        log(f"Audio data shape: {audio_data.shape}, duration: {len(audio_data)/SAMPLE_RATE:.1f}s")

        log("Creating temp file...")
        temp_file = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)

        log("Writing WAV file...")
        wav.write(temp_file.name, SAMPLE_RATE, audio_data)

        log(f"WAV saved: {temp_file.name}")
        return temp_file.name

    def is_recording(self) -> bool:
        """Returns True if recording is in progress."""
        return self.recording
