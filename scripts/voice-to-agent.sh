#!/bin/bash
#
# Launched by Whisper Voice "command" action.
# Opens a new Terminal tab and runs Claude Code with the dictated instruction.
#
# Environment variables set by Whisper Voice:
#   WV_TRANSCRIPTION      — processed text (the instruction)
#   WV_RAW_TRANSCRIPTION  — raw text before mode processing
#   WV_APP_BUNDLE_ID      — source app bundle ID
#   WV_APP_NAME           — source app name
#   WV_MODE               — current mode
#   WV_PROJECT            — tagged project name
#
# Clipboard content (if any) is available via pbpaste inside the prompt.

set -euo pipefail

INSTRUCTION="${WV_TRANSCRIPTION:?WV_TRANSCRIPTION not set}"
CLIPBOARD="$(pbpaste 2>/dev/null || true)"

# Build the prompt — include clipboard context only if non-empty
PROMPT="$INSTRUCTION"
if [ -n "$CLIPBOARD" ]; then
    PROMPT="Contexte (copié depuis $WV_APP_NAME):
---
$CLIPBOARD
---

Instruction: $INSTRUCTION"
fi

# Default working directory: superproper repo. Override with WV_AGENT_CWD env var.
CWD="${WV_AGENT_CWD:-$HOME/Documents/dev/superproper/super_proper}"

# Escape single quotes for osascript
ESCAPED_CWD="${CWD//\'/\'\\\'\'}"
ESCAPED_PROMPT="${PROMPT//\'/\'\\\'\'}"

# Open a new Terminal tab and run Claude with the prompt
osascript -e "
tell application \"Terminal\"
    activate
    do script \"cd '${ESCAPED_CWD}' && claude --dangerously-skip-permissions '${ESCAPED_PROMPT}'\"
end tell
"
