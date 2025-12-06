# Whisper Voice

macOS voice transcription app using the OpenAI Whisper API.

**Option+Space** to record your voice, and the transcribed text is automatically pasted at the cursor location.

## Features

- Global keyboard shortcut (Option+Space)
- Menu bar icon (🎤 → 🔴 → ⏳)
- macOS notifications
- Automatic text pasting

## Requirements

- macOS
- Python 3.10+
- An OpenAI API key ([get a key](https://platform.openai.com/api-keys))

## Installation

```bash
# Clone the repo
git clone https://github.com/hugoblanc/whisper-voice.git
cd whisper-voice

# Run the installation
./install.sh
```

The installation script will:
1. Install Python dependencies
2. Ask for your OpenAI API key
3. Configure auto-start (optional)

## Usage

### Manual launch

```bash
python main.py
```

### Shortcut

| Action | Shortcut |
|--------|----------|
| Start/Stop recording | **Option+Space** |

### Visual indicators (menu bar)

| Icon | State |
|------|-------|
| 🎤 | Idle |
| 🔴 | Recording |
| ⏳ | Transcribing |

## macOS Permissions

On first launch, macOS will ask you to authorize:

1. **Microphone**: to record your voice
2. **Accessibility**: System Preferences → Privacy & Security → Accessibility → Add Terminal
3. **Input Monitoring**: System Preferences → Privacy & Security → Input Monitoring → Add Terminal

## Uninstallation

```bash
./uninstall.sh
```

## Configuration

The `.env` file contains your API key:

```
OPENAI_API_KEY=sk-your-key-here
```

## Troubleshooting

### Shortcut not working

Make sure Terminal is added in:
- System Preferences → Privacy & Security → Accessibility
- System Preferences → Privacy & Security → Input Monitoring

### "This process is not trusted" error

Add Terminal in Accessibility preferences, then restart the application.

## License

MIT
