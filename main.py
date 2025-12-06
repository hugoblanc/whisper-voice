#!/usr/bin/env python3
"""
Whisper Voice - Application de transcription vocale pour Mac

Usage:
    python main.py

Raccourci: Option+Espace pour démarrer/arrêter l'enregistrement
"""

import rumps
import threading
import time
from pynput import keyboard
from recorder import Recorder
from transcriber import transcribe
from clipboard import paste_text


def log(msg):
    """Log avec timestamp."""
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] {msg}")


class WhisperApp(rumps.App):
    def __init__(self):
        super().__init__("🎤", quit_button=None)
        self.recorder = Recorder()
        self.menu = [
            rumps.MenuItem("Option+Espace pour enregistrer", callback=None),
            None,  # Séparateur
            rumps.MenuItem("Quitter", callback=self.quit_app)
        ]

        log("App initialisée")

        # Lance l'écoute du raccourci clavier dans un thread séparé
        self.hotkey_thread = threading.Thread(target=self.listen_hotkey, daemon=True)
        self.hotkey_thread.start()
        log("Écoute du raccourci clavier démarrée")

    def listen_hotkey(self):
        """Écoute le raccourci clavier global."""
        with keyboard.GlobalHotKeys({
            '<alt>+<space>': self.toggle_recording
        }) as hotkey:
            hotkey.join()

    def toggle_recording(self):
        """Démarre ou arrête l'enregistrement."""
        log("Toggle recording appelé")
        if self.recorder.is_recording():
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        """Démarre l'enregistrement."""
        log("▶ Démarrage enregistrement...")
        self.title = "🔴"
        self.recorder.start()
        log("✓ Enregistrement démarré")
        rumps.notification(
            title="Whisper Voice",
            subtitle="Enregistrement...",
            message="Option+Espace pour arrêter"
        )

    def stop_recording(self):
        """Arrête l'enregistrement et transcrit."""
        log("⏹ Arrêt enregistrement...")
        self.title = "⏳"
        audio_path = self.recorder.stop()
        log(f"✓ Audio sauvegardé: {audio_path}")

        if audio_path:
            # Transcription dans un thread pour ne pas bloquer l'UI
            log("→ Lancement thread de transcription...")
            threading.Thread(target=self.transcribe_audio, args=(audio_path,), daemon=True).start()
        else:
            self.title = "🎤"
            log("✗ Aucun audio enregistré")
            rumps.notification(
                title="Whisper Voice",
                subtitle="Erreur",
                message="Aucun audio enregistré"
            )

    def transcribe_audio(self, audio_path):
        """Transcrit l'audio et colle le texte."""
        try:
            log("📤 Envoi à l'API Whisper...")
            start_time = time.time()
            text = transcribe(audio_path)
            elapsed = time.time() - start_time
            log(f"✓ Transcription reçue en {elapsed:.1f}s ({len(text)} caractères)")

            log("📋 Collage du texte...")
            paste_text(text)
            log("✓ Texte collé")

            self.title = "🎤"
            rumps.notification(
                title="Whisper Voice",
                subtitle="Transcription terminée",
                message=text[:50] + "..." if len(text) > 50 else text
            )
        except Exception as e:
            self.title = "🎤"
            log(f"✗ ERREUR: {e}")
            rumps.notification(
                title="Whisper Voice",
                subtitle="Erreur",
                message=str(e)
            )

    def quit_app(self, _):
        """Quitte l'application."""
        log("Fermeture de l'application")
        rumps.quit_application()


if __name__ == "__main__":
    log("=" * 50)
    log("🎤 Whisper Voice - Démarrage")
    log("=" * 50)
    WhisperApp().run()
