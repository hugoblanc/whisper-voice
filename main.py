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
import os
from pynput import keyboard
from recorder import Recorder
from transcriber import transcribe
from clipboard import paste_text

VERSION = "1.1.0"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ICONS_DIR = os.path.join(SCRIPT_DIR, "icons")


def log(msg):
    """Log with timestamp."""
    timestamp = time.strftime("%H:%M:%S")
    print(f"[{timestamp}] {msg}")


def get_icon_path(name):
    """Get the path to an icon file."""
    path = os.path.join(ICONS_DIR, f"{name}.png")
    if os.path.exists(path):
        return path
    return None


class WhisperApp(rumps.App):
    def __init__(self):
        # Try to use custom icon, fallback to emoji
        icon_path = get_icon_path("mic_idle")

        super().__init__(
            name="Whisper Voice",
            title=None if icon_path else "🎤",
            icon=icon_path,
            template=True,  # Makes icon adapt to light/dark mode
            quit_button=None
        )

        self.recorder = Recorder()
        self.transcription_count = 0
        self.total_duration = 0.0

        # Build menu
        self.menu = [
            rumps.MenuItem("Option+Space to record", callback=None),
            None,  # Separator
            rumps.MenuItem("Status: Idle", callback=None, key=None),
            None,  # Separator
            rumps.MenuItem(f"Version {VERSION}", callback=None),
            rumps.MenuItem("View Logs...", callback=self.open_logs),
            None,  # Separator
            rumps.MenuItem("Quit Whisper Voice", callback=self.quit_app)
        ]

        # Store references to menu items we need to update
        self.status_item = self.menu["Status: Idle"]

        # Track pressed keys for hotkey detection
        self.pressed_keys = set()
        self.hotkey_lock = threading.Lock()

        log("App initialized")

        # Start keyboard shortcut listener in a separate thread
        self.hotkey_thread = threading.Thread(target=self.listen_hotkey, daemon=True)
        self.hotkey_thread.start()
        log("Keyboard shortcut listener started")

    def set_icon(self, state):
        """Update the menu bar icon."""
        icon_names = {
            "idle": "mic_idle",
            "recording": "mic_recording",
            "transcribing": "mic_transcribing"
        }
        emoji_fallbacks = {
            "idle": "🎤",
            "recording": "🔴",
            "transcribing": "⏳"
        }

        icon_path = get_icon_path(icon_names.get(state, "mic_idle"))
        if icon_path:
            self.icon = icon_path
            self.title = None
        else:
            self.icon = None
            self.title = emoji_fallbacks.get(state, "🎤")

    def update_status(self, status):
        """Update the status menu item."""
        self.status_item.title = f"Status: {status}"

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
        self.set_icon("recording")
        self.update_status("Recording...")
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
        self.set_icon("transcribing")
        self.update_status("Transcribing...")
        audio_path = self.recorder.stop()
        log(f"✓ Audio saved: {audio_path}")

        if audio_path:
            # Transcription in a thread to avoid blocking the UI
            log("→ Starting transcription thread...")
            threading.Thread(target=self.transcribe_audio, args=(audio_path,), daemon=True).start()
        else:
            self.set_icon("idle")
            self.update_status("Idle")
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

            # Update stats
            self.transcription_count += 1
            self.total_duration += elapsed

            self.set_icon("idle")
            self.update_status("Idle")
            rumps.notification(
                title="Whisper Voice",
                subtitle="Transcription complete",
                message=text[:50] + "..." if len(text) > 50 else text
            )
        except Exception as e:
            self.set_icon("idle")
            self.update_status("Error")
            log(f"✗ ERROR: {e}")
            rumps.notification(
                title="Whisper Voice",
                subtitle="Error",
                message=str(e)
            )

    def open_logs(self, _):
        """Open the log file in Console."""
        log_path = os.path.expanduser("~/.whisper-voice.log")
        if os.path.exists(log_path):
            os.system(f'open -a Console "{log_path}"')
        else:
            rumps.notification(
                title="Whisper Voice",
                subtitle="No logs",
                message="Log file not found"
            )

    def quit_app(self, _):
        """Quit the application."""
        log("Closing application")
        rumps.quit_application()


if __name__ == "__main__":
    log("=" * 50)
    log(f"🎤 Whisper Voice v{VERSION} - Starting")
    log("=" * 50)
    WhisperApp().run()
