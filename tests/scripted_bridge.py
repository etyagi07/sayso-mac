"""The bridge as a process, on the scripted engine (tests/fakes.py): what
the process tests launch. Takes bridge.py's own arguments."""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "bridge"))
sys.path.insert(0, str(HERE))

import bridge  # noqa: E402
import fakes  # noqa: E402

if __name__ == "__main__":
    sys.exit(bridge.main(make_engine=lambda bus, timeout: fakes.FakeEngine(bus, timeout)))
