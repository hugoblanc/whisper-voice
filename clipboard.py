import subprocess
import time
from pynput.keyboard import Controller, Key


def paste_text(text: str):
    """
    Copie le texte dans le clipboard et simule Cmd+V pour le coller.

    Args:
        text: Le texte à coller
    """
    # Copie dans le clipboard via pbcopy (macOS)
    process = subprocess.Popen(
        ["pbcopy"],
        stdin=subprocess.PIPE,
        env={"LANG": "en_US.UTF-8"}
    )
    process.communicate(text.encode("utf-8"))

    # Petit délai pour s'assurer que le clipboard est prêt
    time.sleep(0.1)

    # Simule Cmd+V
    keyboard = Controller()
    keyboard.press(Key.cmd)
    keyboard.press("v")
    keyboard.release("v")
    keyboard.release(Key.cmd)
