"""Recording until a pause, against a fake microphone. Offline, silent."""

import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import _isolated  # noqa: E402,F401  (state in a temp folder, never the live one)

from voice import config, listen  # noqa: E402


def recording(levels, on_level=None):
    """Run record_until_silence over blocks at these loudness levels."""
    feed = list(levels)

    class Stream:
        def __enter__(self):
            return self

        def __exit__(self, *e):
            pass

        def read(self, n):
            level = feed.pop(0) if feed else 0.0
            return np.full((n, 1), level, dtype="float32"), False

    saved = (listen.sd, listen._threshold, config.CONFIG_FILE)
    with tempfile.TemporaryDirectory() as d:
        listen.sd = SimpleNamespace(InputStream=lambda **k: Stream())
        listen._threshold = lambda: 0.02
        config.CONFIG_FILE = Path(d) / "config.json"      # the defaults
        try:
            return listen.record_until_silence(on_level=on_level)
        finally:
            listen.sd, listen._threshold, config.CONFIG_FILE = saved


def test_a_pause_ends_the_command():
    blocks = int(config.DEFAULTS["silence_seconds"] / 0.05)
    audio = recording([0.1] * 20 + [0.0] * 200)
    seconds = len(audio) / listen.SAMPLE_RATE
    assert audio is not None
    assert abs(seconds - (20 + blocks) * 0.05) < 0.11, seconds


def test_the_level_meter_hears_every_block():
    heard = []
    recording([0.1] * 20 + [0.0] * 200, heard.append)
    assert abs(heard[0] - 5.0) < 1e-3, heard[:3]        # 0.1 over a 0.02 threshold
    assert heard[-1] == 0.0


def test_a_broken_meter_cannot_break_recording():
    def boom(level):
        raise RuntimeError("meter")
    assert recording([0.1] * 20 + [0.0] * 200, boom) is not None


def test_the_speech_model_is_pinned():
    import huggingface_hub
    calls = []

    def fake(**k):
        calls.append(k)
        if k.get("local_files_only"):
            raise OSError("not cached")
        return "/models/small.en"
    saved = huggingface_hub.snapshot_download
    huggingface_hub.snapshot_download = fake
    try:
        assert listen._mlx_path("small.en") == "/models/small.en"
    finally:
        huggingface_hub.snapshot_download = saved
    revision = listen.MLX_REVISIONS["small.en"]
    assert [c["revision"] for c in calls] == [revision, revision], calls
    assert calls[0]["local_files_only"] and "local_files_only" not in calls[1]
    assert listen._mlx_path("tiny.en") == listen._mlx_repo("tiny.en")   # unpinned


def test_a_missing_model_says_how_big_its_download_is():
    import huggingface_hub
    cached = [True]

    def fake(**k):
        assert k["local_files_only"] and k["revision"] == listen.MLX_REVISIONS["small.en"]
        if not cached[0]:
            raise OSError("not cached")
        return "/models/small.en"
    saved = (huggingface_hub.snapshot_download, listen.config.backend, listen.config.get)
    huggingface_hub.snapshot_download = fake
    listen.config.backend = lambda: "mlx"
    listen.config.get = lambda key: "small.en" if key == "asr_model" else saved[2](key)
    try:
        assert listen.download_mb() is None
        cached[0] = False
        assert listen.download_mb() == 481
    finally:
        huggingface_hub.snapshot_download, listen.config.backend, listen.config.get = saved


def test_silence_alone_is_not_a_command():
    assert recording([0.0] * 400) is None


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
