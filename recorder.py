import sounddevice as sd
import scipy.io.wavfile as wav
import numpy as np
import tempfile

SAMPLE_RATE = 16000  # Whisper works well with 16kHz


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
        self.recording = False
        self.stream.stop()
        self.stream.close()

        if not self.frames:
            return None

        # Concatenate all frames
        audio_data = np.concatenate(self.frames, axis=0)

        # Save to temporary file
        temp_file = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        wav.write(temp_file.name, SAMPLE_RATE, audio_data)

        return temp_file.name

    def is_recording(self) -> bool:
        """Returns True if recording is in progress."""
        return self.recording
