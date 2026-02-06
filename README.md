# Whisper Voice

> Voice-to-text for macOS with AI processing modes. Press a shortcut, speak, text appears at your cursor.

Native Swift app supporting **OpenAI Whisper** and **Mistral Voxtral**. No dependencies, lightweight (~2 MB).

![Whisper Voice](logo_whisper_voice.png)

**Windows user?** Check out [whisper-voice-windows](https://github.com/hugoblanc/whisper-voice-windows).

---

## Download

### Easy Install (Recommended)

1. **[Download WhisperVoice-3.0.0.dmg](https://github.com/hugoblanc/whisper-voice/releases/latest/download/WhisperVoice-3.0.0.dmg)**
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
2. Speak - a recording window with waveform appears
3. Press **Shift** to cycle through AI modes (optional)
4. Press again to stop → Text is processed and pasted

### Push-to-Talk Mode
1. Hold **F3** (configurable)
2. Speak while holding
3. Release to transcribe and paste

---

## Features

### Recording Window
- **Live waveform visualization** with animated audio levels
- **Recording timer** showing elapsed time
- **Status indicators**: red (recording), blue (processing), green (done)
- **Cancel button** or press Escape to abort

### AI Processing Modes
Switch modes by pressing **Shift** during recording:

| Mode | Description |
|------|-------------|
| **Brut** | Raw transcription, no processing |
| **Clean** | Removes filler words (um, uh), fixes punctuation |
| **Formel** | Professional tone, proper structure |
| **Casual** | Natural, friendly tone |
| **Markdown** | Converts to headers, lists, code blocks |

> AI modes require an OpenAI API key (uses GPT-4o-mini for processing)

### Transcription History
- **Cmd+H** to open history window
- Search through past transcriptions
- Copy or delete entries
- Shows provider and mode used

### Other Features
- **Multi-provider support**: OpenAI Whisper or Mistral Voxtral
- **Preferences window**: Change settings without editing config (Cmd+,)
- **Built-in logs**: Debug issues from Preferences → Logs tab
- **Setup wizard**: Guided first-time configuration
- **Permission wizard**: Step-by-step macOS permissions setup

---

## Supported Providers

| Provider | Model | Cost | Get API Key |
|----------|-------|------|-------------|
| **OpenAI** | whisper-1 | ~$0.006/min | [platform.openai.com](https://platform.openai.com/api-keys) |
| **Mistral** | voxtral | ~$0.001/min | [console.mistral.ai](https://console.mistral.ai/api-keys) |

> **Note**: You provide your own API key. For AI processing modes, you need an OpenAI key (even if using Mistral for transcription).

---

## Requirements

- macOS 12.0+
- API key from OpenAI or Mistral

---

## Permissions

On first launch, a wizard guides you through granting these in **System Settings → Privacy & Security**:

| Permission | Why |
|------------|-----|
| Microphone | Record your voice |
| Accessibility | Paste text via Cmd+V |
| Input Monitoring | Detect global hotkeys |

---

## Configuration

Settings are stored in `~/.whisper-voice-config.json` but you can change most things from **Preferences** (Cmd+,).

### API Keys for AI Modes

To use AI processing modes with Mistral transcription, add your OpenAI key:

```json
{
  "provider": "mistral",
  "apiKey": "your-mistral-key",
  "providerApiKeys": {
    "openai": "sk-your-openai-key"
  }
}
```

### Shortcut Options
- **Toggle**: Option+Space, Control+Space, or Cmd+Shift+Space
- **Push-to-Talk**: F1 through F12
- **Mode Switch**: Shift (during recording)

---

## Troubleshooting

### App doesn't respond to shortcuts
Add **Whisper Voice** to Input Monitoring and Accessibility in System Settings.

### Text not pasting
Add **Whisper Voice** to Accessibility in System Settings.

### AI modes are grayed out
You need an OpenAI API key configured. Add it to `providerApiKeys.openai` in your config.

### Check logs
Open Preferences (Cmd+,) → Logs tab to see what's happening.

---

## Development

```bash
cd WhisperVoice
./dev.sh  # Build and hot-reload (preserves permissions)
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
└── WhisperVoice/
    ├── Package.swift
    ├── dev.sh          # Development build script
    └── Sources/WhisperVoice/main.swift
```

---

## What's New in v3.0

- **Recording window** with live waveform visualization
- **AI processing modes** (Clean, Formal, Casual, Markdown)
- **Transcription history** with search (Cmd+H)
- **Mode switching** with Shift key during recording
- **Dev workflow** improvements (hot-reload with preserved permissions)

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
