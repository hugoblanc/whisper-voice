#!/usr/bin/env python3
"""
Whisper Voice - macOS voice transcription app

Usage:
    python main.py

Shortcut: Option+Space to start/stop recording
"""

import rumps
import threading
import time
from pynput import keyboard
from recorder import Recorder
from transcriber import transcribe
from clipboard import paste_text


def log(msg):
    """Log with timestamp."""
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] {msg}")


class WhisperApp(rumps.App):
    def __init__(self):
        super().__init__("🎤", quit_button=None)
        self.recorder = Recorder()
        self.menu = [
            rumps.MenuItem("Option+Space to record", callback=None),
            None,  # Separator
            rumps.MenuItem("Quit", callback=self.quit_app)
        ]

        # Track pressed keys for hotkey detection
        self.pressed_keys = set()
        self.hotkey_lock = threading.Lock()

        log("App initialized")

        # Start keyboard shortcut listener in a separate thread
        self.hotkey_thread = threading.Thread(target=self.listen_hotkey, daemon=True)
        self.hotkey_thread.start()
        log("Keyboard shortcut listener started")

    def listen_hotkey(self):
        """Listen for global keyboard shortcut using Listener (more stable than GlobalHotKeys)."""
        def on_press(key):
            with self.hotkey_lock:
                self.pressed_keys.add(key)
                # Check for Option+Space
                if keyboard.Key.alt in self.pressed_keys and keyboard.Key.space in self.pressed_keys:
                    self.pressed_keys.clear()  # Reset to avoid repeated triggers
                    # Run toggle in separate thread to not block the listener
                    threading.Thread(target=self.toggle_recording, daemon=True).start()

        def on_release(key):
            with self.hotkey_lock:
                self.pressed_keys.discard(key)

        with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
            listener.join()

    def toggle_recording(self):
        """Start or stop recording."""
        log("Toggle recording called")
        if self.recorder.is_recording():
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        """Start recording."""
        log("▶ Starting recording...")
        self.title = "🔴"
        self.recorder.start()
        log("✓ Recording started")
        rumps.notification(
            title="Whisper Voice",
            subtitle="Recording...",
            message="Option+Space to stop"
        )

    def stop_recording(self):
        """Stop recording and transcribe."""
        log("⏹ Stopping recording...")
        self.title = "⏳"
        audio_path = self.recorder.stop()
        log(f"✓ Audio saved: {audio_path}")

        if audio_path:
            # Transcription in a thread to avoid blocking the UI
            log("→ Starting transcription thread...")
            threading.Thread(target=self.transcribe_audio, args=(audio_path,), daemon=True).start()
        else:
            self.title = "🎤"
            log("✗ No audio recorded")
            rumps.notification(
                title="Whisper Voice",
                subtitle="Error",
                message="No audio recorded"
            )

    def transcribe_audio(self, audio_path):
        """Transcribe audio and paste text."""
        try:
            log("📤 Sending to Whisper API...")
            start_time = time.time()
            text = transcribe(audio_path)
            elapsed = time.time() - start_time
            log(f"✓ Transcription received in {elapsed:.1f}s ({len(text)} characters)")

            log("📋 Pasting text...")
            paste_text(text)
            log("✓ Text pasted")

            self.title = "🎤"
            rumps.notification(
                title="Whisper Voice",
                subtitle="Transcription complete",
                message=text[:50] + "..." if len(text) > 50 else text
            )
        except Exception as e:
            self.title = "🎤"
            log(f"✗ ERROR: {e}")
            rumps.notification(
                title="Whisper Voice",
                subtitle="Error",
                message=str(e)
            )

    def quit_app(self, _):
        """Quit the application."""
        log("Closing application")
        rumps.quit_application()


if __name__ == "__main__":
    log("=" * 50)
    log("🎤 Whisper Voice - Starting")
    log("=" * 50)
    WhisperApp().run()
