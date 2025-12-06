import subprocess
import time
from pynput.keyboard import Controller, Key


def paste_text(text: str):
    """
    Copy text to clipboard and simulate Cmd+V to paste.

    Args:
        text: The text to paste
    """
    # Copy to clipboard via pbcopy (macOS)
    process = subprocess.Popen(
        ["pbcopy"],
        stdin=subprocess.PIPE,
        env={"LANG": "en_US.UTF-8"}
    )
    process.communicate(text.encode("utf-8"))

    # Small delay to ensure clipboard is ready
    time.sleep(0.1)

    # Simulate Cmd+V
    keyboard = Controller()
    keyboard.press(Key.cmd)
    keyboard.press("v")
    keyboard.release("v")
    keyboard.release(Key.cmd)
