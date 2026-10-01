"""Which trading account is in use.

The login session and the daily limit counters both belong to one
account. Keeping them per account means switching is a flag, not copying
files around - and a session can never leak from one account to another.
Credentials are not stored at all; they are typed at each login.

    python -m voice.main --account client     -> .session.client.json
    python -m voice.main                      -> .session.json (the default)

Must be read before anything else from this project is imported, since
file paths are fixed at import time. Entry points call from_argv() first.
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VAR = "SAYSO_ACCOUNT"
HOME_VAR = "SAYSO_HOME"


def in_app():
    """True when a front-end app drives the engine (it sets SAYSO_APP=1).
    Messages then point at the app's controls instead of terminal
    commands, which an app user never types."""
    return os.environ.get("SAYSO_APP") == "1"


def home():
    """Where this machine's state lives: sessions, settings, symbol masters.

    Beside the code by default, as a terminal checkout expects. An app that
    installs the code somewhere shared (or read-only) sets SAYSO_HOME to a
    per-user folder instead.
    """
    chosen = os.environ.get(HOME_VAR, "").strip()
    if not chosen:
        return ROOT
    path = Path(chosen).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def name():
    n = os.environ.get(VAR, "").strip()
    return n or None


def _tag():
    n = name()
    return f".{n}" if n else ""


def session_file():
    return home() / f".session{_tag()}.json"


def account_file():
    """Per-account settings that are not credentials - registered IPs."""
    return home() / f".account{_tag()}.json"


def limits_file():
    return home() / f".daily_limits{_tag()}.json"


def accounts():
    """The account profiles this machine has used, by name ("default" for
    the unnamed one), from which files exist. Nothing is read from them."""
    found = set()
    for f in home().glob(".session*.json"):
        middle = f.name[len(".session"):-len(".json")]
        found.add(middle[1:] if middle.startswith(".") else "default")
    return sorted(found, key=lambda n: (n != "default", n))


def cmd(module, *args, account=True):
    r"""The command to run one of this project's modules, exactly as it must
    be typed here: this project's Python (`.venv/bin/python` on a Mac,
    `.\.venv\Scripts\python.exe` on Windows - bare `python` is missing or
    the wrong one), plus `--account NAME` when an account is in use, so a
    hint never quietly acts on the default account instead."""
    exe = sys.executable
    try:
        rel = os.path.relpath(exe)
        if not rel.startswith(".."):
            exe = rel
    except ValueError:
        pass                                  # another drive, on Windows
    if os.name == "nt" and not os.path.isabs(exe):
        exe = ".\\" + exe
    if " " in exe:
        exe = f'& "{exe}"' if os.name == "nt" else f'"{exe}"'
    parts = [exe, "-m", module, *args]
    if account and name():
        parts += ["--account", name()]
    return " ".join(parts)


def label():
    return name() or "default"


def from_argv(argv=None):
    """Take --account NAME off the command line and make it current."""
    argv = sys.argv if argv is None else argv
    for i, arg in enumerate(list(argv)):
        value = None
        if arg == "--account" and i + 1 < len(argv):
            value = argv[i + 1]
            del argv[i:i + 2]
        elif arg.startswith("--account="):
            value = arg.split("=", 1)[1]
            del argv[i]
        if value is not None:
            # It becomes part of a filename, so keep it to a safe shape.
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", value):
                raise SystemExit(f"Account name {value!r} should be letters, "
                                 f"digits, - or _.")
            os.environ[VAR] = value
            break
    return name()
