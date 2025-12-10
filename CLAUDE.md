# Whisper Voice - Project Context

## Overview
Native macOS voice transcription app using OpenAI's Whisper API. Press **Option+Space** to record, and the transcribed text is automatically pasted at cursor location.

## Tech Stack
- **Swift 5.9+** (native macOS app)
- **AVFoundation**: Audio recording
- **URLSession**: API calls
- **NSStatusBar**: Menu bar app
- **CGEvent**: Keyboard simulation for paste

## Project Structure
```
whisper-voice/
├── install.sh              # Installation wizard
├── uninstall.sh            # Uninstallation script
├── icons/                  # App and menu bar icons
│   ├── AppIcon.icns
│   ├── mic_idle.png
│   └── mic_recording.png
└── WhisperVoice/           # Swift source code
    ├── Package.swift       # Swift Package Manager config
    ├── Info.plist          # macOS app permissions
    └── Sources/
        └── WhisperVoice/
            └── main.swift  # All app code (~350 lines)
```

## Key Implementation Details

### Menu Bar App
Using `NSStatusBar` with template images that adapt to light/dark mode.

### Global Hotkey
Using `NSEvent.addGlobalMonitorForEvents` to detect Option+Space globally.

### Audio Recording
Using `AVAudioRecorder` with 16kHz WAV format for Whisper API compatibility.

### Paste via CGEvent
Using `CGEvent` to simulate Cmd+V keystroke (more reliable than AppleScript for native apps).

### API Model
Using `gpt-4o-mini-transcribe` ($0.003/min) instead of `whisper-1` ($0.006/min).

## Configuration
Config file: `~/.whisper-voice-config.json`
```json
{
    "apiKey": "sk-...",
    "shortcutModifiers": 2048,
    "shortcutKeyCode": 49
}
```

Modifier values:
- `2048` = Option
- `4096` = Control
- `1310984` = Command + Shift

## Building
```bash
cd WhisperVoice
swift build -c release
```

## App Bundle Location
`~/Applications/Whisper Voice.app`

## macOS Permissions Required
Add **Whisper Voice** in System Preferences → Privacy & Security:
1. **Microphone**: For audio recording
2. **Accessibility**: For paste simulation (Cmd+V)
3. **Input Monitoring**: For global hotkey detection

## Common Issues

### App doesn't respond to shortcut
Add **Whisper Voice** to Input Monitoring and Accessibility.

### Text not pasting
Add **Whisper Voice** to Accessibility.

### No microphone prompt
Restart the app. macOS should prompt for microphone access on first recording.
