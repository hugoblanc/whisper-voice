import sounddevice as sd
import scipy.io.wavfile as wav
import numpy as np
import tempfile
import os

SAMPLE_RATE = 16000  # Whisper fonctionne bien avec 16kHz


class Recorder:
    def __init__(self):
        self.recording = False
        self.frames = []

    def start(self):
        """Démarre l'enregistrement audio."""
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
        """Callback appelé pour chaque bloc audio."""
        if self.recording:
            self.frames.append(indata.copy())

    def stop(self) -> str:
        """Arrête l'enregistrement et sauvegarde en WAV. Retourne le chemin du fichier."""
        self.recording = False
        self.stream.stop()
        self.stream.close()

        if not self.frames:
            return None

        # Concatène tous les frames
        audio_data = np.concatenate(self.frames, axis=0)

        # Sauvegarde dans un fichier temporaire
        temp_file = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        wav.write(temp_file.name, SAMPLE_RATE, audio_data)

        return temp_file.name

    def is_recording(self) -> bool:
        """Retourne True si l'enregistrement est en cours."""
        return self.recording
