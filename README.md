# ProjectZero

**Sayso, for the Mac.** Sayso is a voice-trading engine for Indian markets. You
say the order, it works out the exact contract and reads it back, and it sends
the order only when you press `y`. ProjectZero is the product around it: a
floating panel that sits beside the chart all day.

> *Speak the order. Glance. Press y.* Nothing trades without your say-so.

## The split

| | Where | Owns |
|---|---|---|
| **Engine** | `sayso/` (Ekansh's fork) | speech → order, contracts, prices, limits, sending, following fills, login |
| **Body kit** | everything else here | how it looks, sounds, onboards and is supported; no trading logic |

The engine may be changed where the product needs it, in the fork only and
with tests. The client's live copy (`~/Desktop/Sayso/sayso`) is never modified from
here.

## Read in this order

1. **`CLAUDE.md`**: the rules.
2. **`HANDOFF.md`**: the current state and what's next.
3. **`docs/user-guide.md`**: what a trader sees and does.
4. **`docs/face-spec.md`**: the design of the panel.
5. **`docs/review-2026-09-30.md`**: the latest review, scores and decisions.
6. **`sayso/README.md`**: the engine, including its "Notes on the Shoonya
   API".

`docs/archive/` and `config/archive/` hold earlier designs; nothing in them is
current.

## Run it (macOS 14+, Apple Silicon)

```bash
cd sayso && ./setup.sh && cd ..      # once: the engine's Python environment
app/build.sh                         # builds app/build/Sayso.app, the dev build
open app/build/Sayso.app             # LIVE: real orders
```

- The app starts the engine (`bridge/bridge.py`) itself.
  - Live runs on 127.0.0.1:8787, which must be the redirect URL on the
    Shoonya API key page.
  - There is no demo mode: every order is real. The tests run on a
    scripted engine in `tests/fakes.py` that no build ships.
- Only one Sayso panel can be open at a time.
- **First run:** Setup & health opens by itself. Connect Shoonya, register
  the IP, and set up the mic, all in the panel.

**Keys:** see `HANDOFF.md` or the user guide.

## Tests

```bash
cd sayso && for t in tests/test_*.py; do .venv/bin/python "$t"; done && cd ..
sayso/.venv/bin/python -m unittest discover -s tests
cd app && swift test
```

| Suite | What |
|---|---|
| Engine | 16 files, 210 tests |
| Bridge | 65 tests over real HTTP, including the real agent with a stubbed broker |
| Panel | 49 tests: the state machine, the installer, and every shape's fit |

Nothing is sent anywhere, and no test touches live state.

## Packaging (the self-contained app)

```bash
PYTHON_RUNTIME=app/build/runtime/python app/package.sh   # -> app/build/dist/Sayso.app
```

- **`PYTHON_RUNTIME`** is an unpacked python-build-standalone "install_only"
  CPython 3.13 for aarch64-apple-darwin. The one used on 2026-09-30:
  - release `20260929`, file
    `cpython-3.13.15+20260929-aarch64-apple-darwin-install_only.tar.gz`;
  - from github.com/astral-sh/python-build-standalone;
  - sha256 `003d459a75ff6949a6590812b1e02a65e849b5b2a9f47c421010138ec643a11c`.
- **Dependencies:** `app/requirements-dist.txt`, which leaves out torch.
- **Shoonya's connector** (NorenRestApiOAuth) is **not** shipped: its licence
  forbids copying. On first launch each Mac downloads that one file from
  PyPI, pinned by checksum in `app/sdk-requirements.txt`.
- **First launch:** the app installs its engine into
  `~/Library/Application Support/Sayso`, and keeps each user's login,
  settings and logs there.
- **Size:** about 705 MB for the app and 698 MB installed, plus about 0.5 GB
  for the speech model on first use.
- **Signing and notarising:** `app/sign.sh` signs every library and
  executable, then the app, with the hardened runtime and the entitlements in
  `app/entitlements/`, then notarises and staples it.
  - It needs a Developer ID and a notarytool profile; see the script's
    header.
  - `DEVELOPER_ID=- app/sign.sh` runs the signing half ad hoc. It was tested
    on 2026-10-01: all 207 libraries plus the interpreter signed, and under
    the hardened runtime numba's JIT, PortAudio and the MLX speech model all
    ran.
  - The installer clears macOS's download quarantine flag on its own copy of
    the engine (tested). Gatekeeper then judges the app once, not every
    binary inside the engine.
  - Until it is signed with a real Developer ID, it runs only on this Mac.
