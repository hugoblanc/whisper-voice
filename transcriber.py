import os
import time
from openai import OpenAI
from dotenv import load_dotenv

load_dotenv()


def log(msg):
    """Log avec timestamp."""
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] [transcriber] {msg}")


def transcribe(audio_path: str) -> str:
    """
    Envoie un fichier audio à l'API Whisper et retourne la transcription.

    Args:
        audio_path: Chemin vers le fichier audio WAV

    Returns:
        Le texte transcrit
    """
    # Taille du fichier
    file_size = os.path.getsize(audio_path)
    log(f"Fichier audio: {file_size / 1024:.1f} KB")

    log("Création client OpenAI...")
    client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))

    log("Ouverture du fichier audio...")
    with open(audio_path, "rb") as audio_file:
        log("Appel API Whisper...")
        start = time.time()
        transcription = client.audio.transcriptions.create(
            model="whisper-1",
            file=audio_file,
            language="fr"
        )
        elapsed = time.time() - start
        log(f"Réponse API reçue en {elapsed:.1f}s")

    log("Suppression fichier temporaire...")
    os.unlink(audio_path)

    log(f"Texte: {transcription.text[:100]}..." if len(transcription.text) > 100 else f"Texte: {transcription.text}")
    return transcription.text
