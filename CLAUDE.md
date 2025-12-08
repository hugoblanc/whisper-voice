# Whisper Voice - Project Context

## Overview
macOS voice transcription app using OpenAI's Whisper API. Press **Option+Space** to record, and the transcribed text is automatically pasted at cursor location.

## Tech Stack
- **Python 3.10+**
- **rumps**: Menu bar app framework
- **pynput**: Keyboard shortcuts (using `Listener`, not `GlobalHotKeys` - more stable)
- **sounddevice + scipy**: Audio recording
- **openai**: Whisper API (`gpt-4o-mini-transcribe` model - 50% cheaper than whisper-1)

## Project Structure
```
whisper-voice/
├── main.py           # Menu bar app + hotkey listener
├── recorder.py       # Audio recording (16kHz WAV)
├── transcriber.py    # OpenAI Whisper API calls
├── clipboard.py      # Paste text via pbcopy + AppleScript Cmd+V
├── install.sh        # Installation script (creates .app bundle)
├── uninstall.sh      # Uninstallation script
├── requirements.txt
├── .env              # OPENAI_API_KEY (not in git)
└── .env.example
```

## Application Bundle
The install script creates a macOS `.app` bundle for easier permission management:
```
~/Applications/Whisper Voice.app/
├── Contents/
│   ├── MacOS/
│   │   └── whisper-voice    # Bash launcher script
│   ├── Resources/
│   └── Info.plist
```

## Key Implementation Details

### Hotkey Detection (main.py)
Using `keyboard.Listener` instead of `GlobalHotKeys` to avoid pynput compatibility bugs:
```python
def on_press(key):
    with self.hotkey_lock:
        self.pressed_keys.add(key)
        if keyboard.Key.alt in self.pressed_keys and keyboard.Key.space in self.pressed_keys:
            self.pressed_keys.clear()
            threading.Thread(target=self.toggle_recording, daemon=True).start()
```

### Paste via AppleScript (clipboard.py)
Using AppleScript instead of pynput for reliable keystroke simulation:
```python
subprocess.run([
    "osascript", "-e",
    'tell application "System Events" to keystroke "v" using command down'
])
```

### Menu Bar Icons
- 🎤 = Idle
- 🔴 = Recording
- ⏳ = Transcribing

### API Model
Using `gpt-4o-mini-transcribe` ($0.003/min) instead of `whisper-1` ($0.006/min).

## LaunchAgent (Auto-start)
Location: `~/Library/LaunchAgents/com.whisper-voice.plist`

Uses `open -a` to launch the app bundle (not direct Python).

Commands:
```bash
# Start service
launchctl load ~/Library/LaunchAgents/com.whisper-voice.plist

# Stop service
launchctl unload ~/Library/LaunchAgents/com.whisper-voice.plist

# Check status
launchctl list | grep whisper

# View logs
tail -f ~/.whisper-voice.log
```

## macOS Permissions Required
Add **Whisper Voice** (the .app) in System Preferences → Privacy & Security:
1. **Accessibility**: For paste simulation (Cmd+V)
2. **Input Monitoring**: For global hotkey detection
3. **Automation → System Events**: For AppleScript keystroke simulation
4. **Microphone**: For audio recording (prompted automatically)

## Common Issues

### "This process is not trusted"
Add **Whisper Voice** app to Accessibility preferences.

### Text not pasting
Add **Whisper Voice** app to Automation → System Events.

### Shortcut not detected
Add **Whisper Voice** app to Input Monitoring.
