# Whisper Voice

Native macOS app for voice transcription using OpenAI's Whisper API.

Press **Option+Space** to record your voice, and the transcribed text is automatically pasted at the cursor location.

## Features

- Native Swift app (no Python dependency)
- Global keyboard shortcut (configurable)
- Menu bar icon with status indicator
- Automatic text pasting
- Secure API key storage
- Lightweight (~2 MB)
- Auto-start at login (optional)

## Requirements

- macOS 12.0+
- Xcode Command Line Tools (installed automatically)
- OpenAI API key ([get one here](https://platform.openai.com/api-keys))

## Installation

```bash
git clone https://github.com/hugoblanc/whisper-voice.git
cd whisper-voice
./install.sh
```

The installer will guide you through:
1. Checking Swift/Xcode tools
2. Configuring your OpenAI API key
3. Choosing a keyboard shortcut
4. Building and installing the app
5. Setting up auto-start (optional)

## Keyboard Shortcuts

Choose during installation:
- **Option + Space** (default)
- **Control + Space**
- **Command + Shift + Space**

## Usage

### Launch

```bash
open -a "Whisper Voice"
```

Or find it in `~/Applications/` and double-click.

### Recording

1. Press your configured shortcut (default: **Option+Space**)
2. Speak your text
3. Press the shortcut again to stop
4. Text is automatically pasted at your cursor

### Menu Bar Icons

| Icon | State |
|------|-------|
| 🎤 | Idle |
| 🔴 | Recording |
| ⏳ | Transcribing |

## macOS Permissions

On first launch, grant these permissions to **Whisper Voice**:

| Permission | Location | Why |
|------------|----------|-----|
| Microphone | Privacy → Microphone | Record audio |
| Accessibility | Privacy → Accessibility | Paste text (Cmd+V) |
| Input Monitoring | Privacy → Input Monitoring | Global hotkey detection |

## Configuration

Configuration is stored in `~/.whisper-voice-config.json`:

```json
{
    "apiKey": "sk-...",
    "shortcutModifiers": 2048,
    "shortcutKeyCode": 49
}
```

To reconfigure, run `./install.sh` again or edit the JSON file.

## Uninstallation

```bash
./uninstall.sh
```

This removes:
- The application (`~/Applications/Whisper Voice.app`)
- Auto-start configuration
- Optionally, the config file with your API key

## Building Manually

```bash
cd WhisperVoice
swift build -c release
```

The binary will be at `.build/release/WhisperVoice`.

## Cost

Uses the `gpt-4o-mini-transcribe` model at **$0.003/minute** (50% cheaper than whisper-1).

## Project Structure

```
whisper-voice/
├── install.sh              # Installation wizard
├── uninstall.sh            # Uninstallation script
├── icons/                  # App and menu bar icons
│   ├── AppIcon.icns
│   ├── mic_idle.png
│   ├── mic_recording.png
│   └── mic_transcribing.png
└── WhisperVoice/           # Swift source code
    ├── Package.swift
    ├── Info.plist
    └── Sources/
        └── WhisperVoice/
            └── main.swift
```

## License

MIT
