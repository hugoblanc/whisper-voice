# Whisper Voice

> Voice-to-text for macOS. Press a shortcut, speak, text appears at your cursor.

Native Swift app using OpenAI's Whisper API. No dependencies, lightweight (~2 MB).

**Windows user?** Check out [whisper-voice-windows](https://github.com/hugoblanc/whisper-voice-windows).

## Quick Start

```bash
git clone https://github.com/hugoblanc/whisper-voice.git
cd whisper-voice
./install.sh
```

You'll need an [OpenAI API key](https://platform.openai.com/api-keys).

## How It Works

1. Press **Option+Space** (configurable)
2. Speak
3. Press again to stop
4. Text is pasted at cursor

## Requirements

- macOS 12.0+
- Xcode Command Line Tools (auto-installed)

## Permissions

Grant these in **System Preferences → Privacy & Security**:

| Permission | Why |
|------------|-----|
| Microphone | Record audio |
| Accessibility | Paste text via Cmd+V |
| Input Monitoring | Detect global hotkey |

## Configuration

Stored in `~/.whisper-voice-config.json`:

```json
{
    "apiKey": "sk-...",
    "shortcutModifiers": 2048,
    "shortcutKeyCode": 49
}
```

**Shortcut options** (set during install):
- Option+Space (default)
- Control+Space
- Command+Shift+Space

Run `./install.sh` again to reconfigure.

## Cost

Uses `gpt-4o-mini-transcribe`: **$0.003/min** (half the cost of whisper-1).

## Project Structure

```
whisper-voice/
├── install.sh          # Installation wizard
├── uninstall.sh        # Uninstall script
├── update.sh           # Update to latest version
├── icons/              # Menu bar & app icons
└── WhisperVoice/       # Swift source
    ├── Package.swift
    └── Sources/WhisperVoice/main.swift
```

## Development

```bash
cd WhisperVoice
swift build -c release
```

Binary: `.build/release/WhisperVoice`

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
