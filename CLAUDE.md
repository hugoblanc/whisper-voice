# Whisper Voice - Project Context

## Overview
Native macOS voice transcription app supporting **OpenAI Whisper** and **Mistral Voxtral** APIs. Two recording modes: Toggle (Option+Space) and Push-to-Talk (F3). Text is automatically pasted at cursor location.

## Tech Stack
- **Swift 5.9+** (native macOS app)
- **AVFoundation**: Audio recording
- **URLSession**: API calls
- **NSStatusBar**: Menu bar app
- **CGEvent**: Keyboard simulation for paste
- **NSWindow/NSTabView**: Preferences window

## Project Structure
```
whisper-voice/
├── install.sh              # Installation wizard
├── uninstall.sh            # Uninstallation script
├── build-dmg.sh            # Build distributable DMG
├── icons/                  # App and menu bar icons
│   ├── AppIcon.icns
│   ├── mic_idle.png
│   └── mic_recording.png
└── WhisperVoice/           # Swift source code
    ├── Package.swift       # Swift Package Manager config
    ├── Info.plist          # macOS app permissions
    └── Sources/
        └── WhisperVoice/
            └── main.swift  # All app code
```

## Key Classes

| Class | Role |
|-------|------|
| `LogManager` | Singleton for logging to file + os.log |
| `PreferencesWindow` | Settings UI with 3 tabs (General, Shortcuts, Logs) |
| `PermissionWizard` | Step-by-step permissions setup |
| `OpenAIProvider` | OpenAI Whisper transcription |
| `MistralProvider` | Mistral Voxtral transcription |
| `AudioRecorder` | WAV recording at 16kHz |
| `AppDelegate` | Main app logic, hotkeys, menu |

## Key Implementation Details

### Menu Bar App
Using `NSStatusBar` with template images that adapt to light/dark mode.

### Global Hotkeys
- Toggle mode: `NSEvent.addGlobalMonitorForEvents` for keyDown
- Push-to-Talk: Separate monitors for keyDown (start) and keyUp (stop)

### Audio Recording
Using `AVAudioRecorder` with 16kHz WAV format for API compatibility.

### Paste via CGEvent
Using `CGEvent` to simulate Cmd+V keystroke (more reliable than AppleScript).

### Multi-Provider Architecture
`TranscriptionProviderFactory` creates the appropriate provider based on config. Both providers share `BaseTranscriptionProvider` for common retry logic.

### Preferences Window
NSTabView with 3 tabs:
- **General**: Provider selection, API key, Test Connection
- **Shortcuts**: Toggle shortcut, PTT key selection
- **Logs**: Real-time log viewer with auto-scroll

## Configuration
Config file: `~/.whisper-voice-config.json`
```json
{
    "provider": "openai",
    "apiKey": "sk-...",
    "shortcutModifiers": 2048,
    "shortcutKeyCode": 49,
    "pushToTalkKeyCode": 99
}
```

Modifier values:
- `2048` = Option
- `4096` = Control
- `cmdKey | shiftKey` = Command + Shift

Logs location: `~/Library/Application Support/WhisperVoice/logs.txt`

## Building
```bash
cd WhisperVoice
swift build -c release
```

Build DMG:
```bash
./build-dmg.sh
```

## App Bundle Location
`~/Applications/Whisper Voice.app`

## macOS Permissions Required
Add **Whisper Voice** in System Settings → Privacy & Security:
1. **Microphone**: For audio recording
2. **Accessibility**: For paste simulation (Cmd+V)
3. **Input Monitoring**: For global hotkey detection

## Common Issues

### App doesn't respond to shortcut
Add **Whisper Voice** to Input Monitoring and Accessibility.

### Text not pasting
Add **Whisper Voice** to Accessibility.

### Settings not applying
Check logs in Preferences → Logs tab. Use "Test Connection" to verify API key.
