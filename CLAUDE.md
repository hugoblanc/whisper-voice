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
`/Applications/Whisper Voice.app` (canonical). Never keep duplicate copies in `~/Applications/` or `build/` — each copy is a distinct TCC identity, and `tccutil reset` then reports multiple stale entries for the same bundle ID.

## macOS Permissions Required
Add **Whisper Voice** in System Settings → Privacy & Security:
1. **Microphone**: For audio recording
2. **Accessibility**: For paste simulation (Cmd+V)
3. **Input Monitoring**: For global hotkey detection

## ⚠️ Distribution: Signing + Notarization — READ BEFORE SHIPPING

**Signing alone is NOT enough.** macOS Gatekeeper rejects unnotarized Developer ID apps downloaded from the web — users see *"cannot be opened because the developer cannot be verified"* and for quarantined downloads the app gets **moved to Trash on open**. Every shipped DMG must be:

1. **Signed** with Developer ID Application + `--options runtime` + `--timestamp` + entitlements
2. **Notarized** via `xcrun notarytool submit ... --wait` (uploads to Apple, usually 1–3 min)
3. **Stapled** via `xcrun stapler staple <dmg>` so offline installs work

`build-dmg.sh` does all three automatically, but needs notary credentials stored once:

```bash
xcrun notarytool store-credentials "whispervoice-notary" \
    --apple-id <email> --team-id 3V5QFA3LEY \
    --password <app-specific-password from appleid.apple.com>
```

Verify a DMG is Gatekeeper-clean before uploading to GitHub:
```bash
spctl -a -vv --type open --context context:primary-signature build/WhisperVoice-*.dmg
# Expect: "accepted" source="Notarized Developer ID"
```

If you see `source=Unnotarized Developer ID` → the DMG will reject on users' Macs. Re-run `build-dmg.sh` with credentials set up.

## ⚠️ Signing & Entitlements — READ BEFORE REBUILDING

The app uses **Hardened Runtime** (`codesign --options runtime`). Without an entitlements file, macOS silently denies microphone access — `AVCaptureDevice.authorizationStatus` returns `.denied` immediately, no system prompt fires, and **no amount of `tccutil reset` will fix it**. The block is at the signature layer, not TCC.

**Every codesign invocation must pass `--entitlements WhisperVoice/WhisperVoice.entitlements`.** `build-dmg.sh` already does. For ad-hoc resigning:

```bash
codesign --force --options runtime \
  --entitlements WhisperVoice/WhisperVoice.entitlements \
  --sign "Developer ID Application: Hugo Blanc (3V5QFA3LEY)" \
  "/Applications/Whisper Voice.app"
```

Verify after signing:
```bash
codesign -d --entitlements - "/Applications/Whisper Voice.app"
# Must show com.apple.security.device.audio-input + com.apple.security.automation.apple-events
```

Each rebuild changes the CDHash → **all previously granted TCC permissions become invalid**. Expected. Re-grant Mic / Accessibility / Input Monitoring via the wizard after every rebuild. If the mic prompt refuses to fire: check entitlements FIRST, TCC state second — 99% of the time it's the entitlements.

## Common Issues

### App doesn't respond to shortcut
Add **Whisper Voice** to Input Monitoring and Accessibility.

### Text not pasting
Add **Whisper Voice** to Accessibility.

### Settings not applying
Check logs in Preferences → Logs tab. Use "Test Connection" to verify API key.

### Mic prompt never appears (stuck `.denied`)
Check `codesign -d --entitlements -` shows `com.apple.security.device.audio-input`. If missing → re-sign with the entitlements file (see above). `tccutil reset` will NOT help in this case.

## Common Issues

### App doesn't respond to shortcut
Add **Whisper Voice** to Input Monitoring and Accessibility.

### Text not pasting
Add **Whisper Voice** to Accessibility.

### Settings not applying
Check logs in Preferences → Logs tab. Use "Test Connection" to verify API key.
