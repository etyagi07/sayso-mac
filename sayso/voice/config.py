"""Per-machine settings.

Anything that depends on the computer rather than the code lives here -
microphone sensitivity above all. A threshold tuned on one laptop is
wrong on the next one, and the failure is silent: either it never hears
you, or it never stops listening.

Stored beside the project so a fresh clone starts unconfigured and says
so, rather than inheriting somebody else's microphone.
"""

import json
import os
import platform

from shoonya import profile

CONFIG_FILE = profile.home() / "config.json"

DEFAULTS = {
    # Set by `python -m voice.calibrate`. None means "not yet measured".
    "silence_rms": None,
    # The pause that ends a command. Cutting someone off mid-phrase only
    # ever rejects the phrase, so this errs short: every command waits it.
    "silence_seconds": 0.9,
    "max_seconds": 15,
    "min_speech_seconds": 0.4,
    # "auto" picks MLX on Apple Silicon and faster-whisper elsewhere.
    "asr_backend": "auto",
    "asr_model": "small.en",
    "input_device": None,      # None = the system default
    # Spoken readback of every preview and result, with outcome sounds.
    "speak": True,
    "voice": None,             # None = an Indian English voice if present
    "speech_rate": 190,        # words per minute
    # How long a resting order is followed, to announce its fill.
    "follow_seconds": 300,
}


def is_apple_silicon():
    return platform.system() == "Darwin" and platform.machine() == "arm64"


def load():
    settings = dict(DEFAULTS)
    try:
        settings.update(json.loads(CONFIG_FILE.read_text()))
    except (OSError, ValueError):
        pass
    return settings


def save(**changes):
    """Store only what was set on this machine. Writing every default here
    would pin today's defaults forever, and a better one would never
    reach a machine that had ever been calibrated."""
    try:
        stored = json.loads(CONFIG_FILE.read_text())
    except (OSError, ValueError):
        stored = {}
    stored.update(changes)
    # Written whole or not at all: a crash mid-write must not lose the
    # microphone calibration.
    tmp = CONFIG_FILE.with_name(CONFIG_FILE.name + ".tmp")
    tmp.write_text(json.dumps(stored, indent=2) + "\n")
    os.replace(tmp, CONFIG_FILE)
    return load()


def get(key):
    return load().get(key, DEFAULTS.get(key))


def is_calibrated():
    return load().get("silence_rms") is not None


def backend():
    """Which speech recogniser to use on this machine."""
    choice = get("asr_backend")
    if choice != "auto":
        return choice
    return "mlx" if is_apple_silicon() else "faster-whisper"
