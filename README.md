# Whisper Voice

> Voice-to-text for macOS. Press a shortcut, speak, text appears at your cursor.

Native Swift app supporting **OpenAI Whisper** and **Mistral Voxtral**. No dependencies, lightweight (~2 MB).

![Whisper Voice](logo_whisper_voice.png)

**Windows user?** Check out [whisper-voice-windows](https://github.com/hugoblanc/whisper-voice-windows).

---

## Download

### Easy Install (Recommended)

1. **[Download WhisperVoice-2.3.0.dmg](https://github.com/hugoblanc/whisper-voice/releases/latest/download/WhisperVoice-2.3.0.dmg)**
2. Open the DMG file
3. Drag **Whisper Voice** to your Applications folder
4. Launch the app - a setup wizard will guide you

### Build from Source

```bash
git clone https://github.com/hugoblanc/whisper-voice.git
cd whisper-voice
./install.sh
```

---

## How It Works

### Toggle Mode (default)
1. Press **Option+Space** (configurable)
2. Speak
3. Press again to stop
4. Text is pasted at cursor

### Push-to-Talk Mode
1. Hold **F3** (configurable)
2. Speak while holding
3. Release to transcribe
4. Text is pasted at cursor

---

## Features

- **Multi-provider support**: Choose between OpenAI Whisper or Mistral Voxtral
- **Two recording modes**: Toggle or Push-to-Talk
- **Preferences window**: Change settings without editing config files (Cmd+,)
- **Built-in logs**: Debug issues easily from the Preferences window
- **Setup wizard**: Guided first-time configuration
- **Permission wizard**: Step-by-step macOS permissions setup

---

## Supported Providers

| Provider | Model | Cost | Get API Key |
|----------|-------|------|-------------|
| **OpenAI** | gpt-4o-mini-transcribe | $0.003/min | [platform.openai.com](https://platform.openai.com/api-keys) |
| **Mistral** | voxtral-mini-latest | Free tier available | [console.mistral.ai](https://console.mistral.ai/api-keys) |

You can switch providers anytime from the Preferences window.

---

## Requirements

- macOS 12.0+
- API key from OpenAI or Mistral

---

## Permissions

On first launch, a wizard will guide you through granting these permissions in **System Settings → Privacy & Security**:

| Permission | Why |
|------------|-----|
| Microphone | Record your voice |
| Accessibility | Paste text via Cmd+V |
| Input Monitoring | Detect global hotkeys |

---

## Configuration

Settings are stored in `~/.whisper-voice-config.json` but you can change everything from the **Preferences window** (Cmd+, or click menu bar icon → Preferences).

### Shortcut Options
- **Toggle**: Option+Space, Control+Space, or Cmd+Shift+Space
- **Push-to-Talk**: F1 through F12

---

## Troubleshooting

### App doesn't respond to shortcuts
Add **Whisper Voice** to Input Monitoring and Accessibility in System Settings.

### Text not pasting
Add **Whisper Voice** to Accessibility in System Settings.

### Check logs
Open Preferences (Cmd+,) → Logs tab to see what's happening.

---

## Development

```bash
cd WhisperVoice
swift build -c release
```

Build DMG for distribution:
```bash
./build-dmg.sh
```

---

## Project Structure

```
whisper-voice/
├── install.sh          # Installation wizard
├── uninstall.sh        # Uninstall script
├── build-dmg.sh        # Build distributable DMG
├── icons/              # Menu bar & app icons
└── WhisperVoice/       # Swift source
    ├── Package.swift
    └── Sources/WhisperVoice/main.swift
```

---

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

---

## Uninstall

```bash
./uninstall.sh
```

Or manually:
- Delete **Whisper Voice.app** from Applications
- Delete `~/.whisper-voice-config.json`
- Delete `~/Library/Application Support/WhisperVoice/`

---

## License

MIT
