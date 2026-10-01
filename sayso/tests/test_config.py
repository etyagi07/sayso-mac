"""Per-machine settings: only what was set here is stored."""

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import _isolated  # noqa: E402,F401  (state in a temp folder, never the live one)

from voice import config  # noqa: E402


def with_temp_config(fn):
    def run():
        saved = config.CONFIG_FILE
        with tempfile.TemporaryDirectory() as d:
            config.CONFIG_FILE = Path(d) / "config.json"
            try:
                fn()
            finally:
                config.CONFIG_FILE = saved
    run.__name__ = fn.__name__
    return run


@with_temp_config
def test_save_stores_only_what_was_set():
    # Writing every default pinned them: a better default never reached a
    # machine that had been calibrated once.
    config.save(silence_rms=0.0151)
    assert json.loads(config.CONFIG_FILE.read_text()) == {"silence_rms": 0.0151}
    assert config.get("silence_seconds") == config.DEFAULTS["silence_seconds"]


@with_temp_config
def test_saves_accumulate():
    config.save(silence_rms=0.02)
    config.save(voice="Rishi (Premium)")
    assert json.loads(config.CONFIG_FILE.read_text()) == {
        "silence_rms": 0.02, "voice": "Rishi (Premium)"}


@with_temp_config
def test_a_save_leaves_no_half_written_file():
    config.save(silence_rms=0.02)
    assert not config.CONFIG_FILE.with_name("config.json.tmp").exists()
    assert json.loads(config.CONFIG_FILE.read_text()) == {"silence_rms": 0.02}


def test_a_command_ends_on_a_short_pause():
    assert config.DEFAULTS["silence_seconds"] == 0.9


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_"):
            continue
        try:
            fn()
            passed += 1
            print(f"ok   {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {type(e).__name__}: {e}")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
