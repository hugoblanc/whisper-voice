# Whisper Voice

macOS voice transcription app using the OpenAI Whisper API.

**Option+Space** to record your voice, and the transcribed text is automatically pasted at the cursor location.

## Features

- Global keyboard shortcut (Option+Space)
- Menu bar icon (🎤 → 🔴 → ⏳)
- macOS notifications
- Automatic text pasting
- Auto-start at login (optional)

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
3. Create a macOS application bundle (`~/Applications/Whisper Voice.app`)
4. Configure auto-start (optional)

## macOS Permissions

After installation, add **Whisper Voice** to these privacy settings:

**System Preferences → Privacy & Security →**

| Permission | Why |
|------------|-----|
| **Accessibility** | To paste text with Cmd+V |
| **Input Monitoring** | To detect the Option+Space shortcut |
| **Automation → System Events** | To simulate keystrokes |
| **Microphone** | To record audio (prompted automatically) |

## Usage

### Launch

```bash
open -a "Whisper Voice"
```

Or find it in `~/Applications/` and double-click.

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

## Uninstallation

```bash
./uninstall.sh
```

This removes:
- The application bundle (`~/Applications/Whisper Voice.app`)
- The auto-start service
- Log files

## Configuration

The `.env` file contains your API key:

```
OPENAI_API_KEY=sk-your-key-here
```

## Logs

```bash
tail -f ~/.whisper-voice.log
```

## Troubleshooting

### Shortcut not working

Make sure **Whisper Voice** is added in:
- System Preferences → Privacy & Security → Accessibility
- System Preferences → Privacy & Security → Input Monitoring

Then restart the app.

### Text not pasting

Add **Whisper Voice** to:
- System Preferences → Privacy & Security → Automation → System Events

### "This process is not trusted" error

Add **Whisper Voice** to Accessibility preferences, then restart the application.

## Cost

Uses the `gpt-4o-mini-transcribe` model at $0.003/minute (50% cheaper than whisper-1).

## License

MIT
