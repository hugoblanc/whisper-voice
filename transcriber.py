import os
import time
from openai import OpenAI
from dotenv import load_dotenv

load_dotenv()


def log(msg):
    """Log with timestamp."""
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] [transcriber] {msg}")


def transcribe(audio_path: str) -> str:
    """
    Send an audio file to the Whisper API and return the transcription.

    Args:
        audio_path: Path to the WAV audio file

    Returns:
        The transcribed text
    """
    # File size
    file_size = os.path.getsize(audio_path)
    log(f"Audio file: {file_size / 1024:.1f} KB")

    log("Creating OpenAI client...")
    client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

    log("Opening audio file...")
    with open(audio_path, "rb") as audio_file:
        log("Calling Whisper API...")
        start = time.time()
        transcription = client.audio.transcriptions.create(
            model="gpt-4o-mini-transcribe",
            file=audio_file
        )
        elapsed = time.time() - start
        log(f"API response received in {elapsed:.1f}s")

    log("Deleting temporary file...")
    os.unlink(audio_path)

    log(f"Text: {transcription.text[:100]}..." if len(transcription.text) > 100 else f"Text: {transcription.text}")
    return transcription.text
