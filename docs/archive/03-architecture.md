> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 03 — Architecture

## Process model

Two processes, one machine, loopback only.

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  zero-panel   (UI)          │         │  zero-engine  (headless)     │
│  PySide6 frameless window   │◄───────►│  asyncio, no UI imports      │
│  always-on-top, sizes in 06 │  ws://  │  owns: ASR, resolver,        │
│  renders state, sends       │127.0.0.1│  gate, broker, risk, logs    │
│  commit / cancel keystrokes │  :8787  │                              │
└─────────────────────────────┘         └──────────────────────────────┘
        ▲                                          │
        │ global hotkey (pynput)                   ▼
     trader                                   broker REST/WS
```

**Why two processes.** The UI is the part most likely to be thrown away and rebuilt (see
"UI swap path" below). Keeping the engine headless behind a local WebSocket means the UI is
replaceable in an afternoon and the engine stays testable without a display server. It also
means a UI crash cannot take the engine — or an in-flight order — down with it.

**Why PySide6 for v1.** The broker SDK is Python; a single language keeps the whole thing
debuggable by one person. A frameless, translucent, always-on-top `QWidget` gets you 80% of
the target look with no toolchain. If the visual polish matters later, see the swap path.

**UI swap path (optional, later).** Because the UI only speaks a documented JSON protocol
over the local socket, it can be replaced with Tauri v2 (web tech, much prettier) or a
native SwiftUI menu-bar app without touching the engine. Do **not** do this before M5. It is
a cosmetic upgrade to a system that must first be correct.

## Repository layout

**A target, not a description.** Two files exist: `core/intent.py` and the fixtures.
Everything else is unwritten. Marked below: **[exists]** / everything else is unwritten.

```
projectzero/
├── core/                 # pure logic — NO ui, audio or broker imports
│   ├── intent.py         # OrderIntent, Slot, Rejection, enums — THE CONTRACT  [exists]
│   ├── staged.py         # StagedOrder: the UI-configured parameters
│   ├── commands.py       # the voice vocabulary, built systematically
│   ├── normalize.py      # filler strip, asr_corrections
│   ├── resolve.py        # staged + phrase + world → OrderIntent | Rejection
│   ├── readback.py       # OrderIntent → visual card + speech string
│   ├── risk.py           # both notional caps, rate limits, limit sanity
│   ├── world.py          # injected quotes and positions
│   ├── config.py         # loading + loud validation
│   ├── jsonlog.py        # JSONL, secret-redacting
│   └── fsm.py            # command lifecycle state machine
├── broker/
│   ├── base.py           # Broker protocol
│   ├── paper.py          # in-memory simulator (DEFAULT)
│   └── shoonya.py        # live adapter — blocked on M5 prerequisites
├── engine/
│   ├── execute.py        # submit, find-by-tag recovery, reconcile
│   ├── server.py         # local WebSocket, 127.0.0.1 only
│   └── hotkey.py         # global hotkey listener
├── asr/                  # base, local_whisper, cloud, race
├── audio/                # capture (300ms pre-roll), vad
├── ui/                   # the order panel + readback card
├── cli/                  # drive the whole loop from a terminal
├── tools/                # config validation + invariant report
├── config/               # instruments.yaml, staged.yaml (examples exist)  [exists]
├── tests/                # fixtures/staged_commands.yaml [exists]; no test code
└── logs/                 # JSONL, gitignored
```

`core/` importing anything from `asr/`, `audio/`, `broker/`, `engine/`, `ui/` or `cli/` is
a build failure, to be enforced by a test that walks the import graph of every file in `core/`.

That test should also assert three other invariants directly:

- `PriceType` has no `MKT` member, so a bare market order is not constructible (rule 7).
- `mode: live` in a config file raises at load (rule 5).
- The JSONL logger redacts anything whose key looks like a secret (rule 19).

## The pipeline

```
 UI: instrument + strike + qty  ──────────────────►  StagedOrder
                                                          │
 hotkey down                                              │
      │                                                   │
      ▼                                                   │
 ┌──────────┐   PCM     ┌──────────┐  transcript  ┌───────▼────┐
 │ CAPTURE  │ ─────────►│   ASR    │ ────────────►│ NORMALIZE  │
 │ VAD/endpt│           │  (race)  │              │  + LOOKUP  │
 └──────────┘           └──────────┘              └─────┬──────┘
                                                        │ VoiceCommand
                                                        ▼
        ┌──────────────┐  OrderIntent  ┌─────────────────────────┐
        │  RISK CHECK  │◄──────────────│        RESOLVE          │
        └──────┬───────┘               │ staged + command + world│
               │ passed                └─────────────────────────┘
               ▼
 ┌──────────────┐  commit keypress  ┌──────────┐  ack + orderno  ┌──────────────┐
 │ CONFIRM GATE │ ─────────────────►│  SUBMIT  │ ───────────────►│ RECONCILE    │
 │ readback     │                   │ idem tag │                 │ poll → assert│
 └──────────────┘                   └──────────┘                 └──────────────┘
        │ timeout / cancel / reject / stage expired
        ▼
     CANCELLED  (the default outcome of anything going wrong)
```

Everything from `NORMALIZE` to `RISK CHECK` must be a pure function of its inputs, so that
the whole path can be exercised with typed strings standing in for the microphone. That is
what makes the hard part testable with no hardware (`CLAUDE.md` rule 10).

## Command lifecycle FSM

`core/fsm.py`. Every transition is logged. The machine owns legality only — the
orchestrator owns policy.

```
IDLE ──stage──► STAGED ──hotkey──► LISTENING ──endpoint──► RESOLVING
  ▲               ▲                    │                       │
  │               │                 (abort)            ┌───────┴───────┐
  │               │                    │            resolved        rejected
  │               │                    ▼               │               │
  │               │              CANCELLED ◄───────────┼───────────────┘
  │               │                ▲   │               ▼
  │               │   timeout/ESC ─┘   │        AWAITING_COMMIT
  │               ├──── after 1.5s ────┘               │
  │               │                              commit keypress
  │               │                                    │
  │               │                                    ▼
  │               │                               SUBMITTING
  │               │                                    │
  │               │                                    ▼
  │               │                               RECONCILING
  │               │                                │        │
  │               │                           matched   mismatch/timeout
  │               │                                ▼        ▼
  │               └──────────────────────────── DONE     DEGRADED
  │                                                         │
  └───────────────────── ack (hold, not tap) ───────────────┘
```

There must be **no edge from `LISTENING` or `RESOLVING` to `SUBMITTING`.** The only way to
reach the broker is through `AWAITING_COMMIT`, and a unit test should assert that the
transition raises — `CLAUDE.md` rule 1 expressed as a test rather than as a comment.

`CANCELLED` is transient: it shows for 1.5s and returns to `STAGED`, because the stage is
still there and is still what the next command will act on. It does **not** re-stamp the
stage — a cancelled or timed-out command must not buy the trader more TTL, or a distracted
session could keep a stale stage alive indefinitely by failing to confirm it.

`DEGRADED` is sticky. Its only legal exit is `IDLE`, via an explicit acknowledgement that
requires a hold rather than a tap — which forces the human to look at the reconciliation
failure. The kill switch still works while degraded, always.

## Module contracts

Define these as `typing.Protocol` so `core` never depends on an implementation.

```python
class Transcriber(Protocol):
    name: str
    async def transcribe(self, pcm: bytes, sample_rate: int) -> Transcript: ...

@dataclass(frozen=True)
class Transcript:
    text: str
    engine: str
    latency_ms: int
    avg_logprob: float | None = None   # None when the engine doesn't expose it
```

```python
class Broker(Protocol):
    async def place(self, order: BrokerOrder) -> Submission: ...
    async def order_status(self, order_no: str) -> OrderStatus: ...
    async def find_by_tag(self, tag: str) -> OrderStatus | None: ...   # idempotency
    async def positions(self) -> list[Position]: ...
    async def cancel_all(self) -> list[str]: ...
    async def square_off_all(self) -> list[str]: ...
```

`paper.py` implements `Broker` fully, including realistic rejections, partial fills and a
configurable latency distribution. **It is the default broker.** Live is opt-in per session
(`CLAUDE.md` rule 5).

## Local WebSocket protocol

Engine → panel (server push), one JSON object per message:

```json
{"t": "state",    "state": "AWAITING_COMMIT", "mode": "paper"}
{"t": "staged",   "contract": "NIFTY 25000 CE", "lots": 1, "qty": 75,
                  "limit": "142.50", "age_ms": 4200, "ttl_ms": 90000}
{"t": "partial",  "text": "buy c…"}
{"t": "readback", "headline": "BUY  NIFTY 25000 CE",
                  "lines": ["75 qty  (1 lot) · NRML", "limit 142.50",
                            "premium  ₹10,687.50", "underlying  ₹18,75,000"],
                  "marks": [], "warnings": [], "unusual": false,
                  "speech": "Buy 75 Nifty 25000 Call. Confirm.",
                  "friction": "normal", "expires_ms": 6000}
{"t": "reject",   "reason": "qualifier_mismatch",
                  "detail": "Heard “PUT” but NIFTY 25000 CE is staged"}
{"t": "result",   "status": "COMPLETE", "order_no": "P000000000001",
                  "filled": 75, "avg_price": "142.50",
                  "speech": "Bought 75 Nifty 25000 Call at 142.50."}
{"t": "alert",    "level": "error", "msg": "Position mismatch — engine DEGRADED"}
```

UI → engine:

```json
{"t": "stage",   "instrument": "NIFTY", "expiry": "2026-09-24", "strike": "25000",
                 "opt": "CE", "lots": 1, "limit": "142.50"}
{"t": "commit"}
{"t": "cancel"}
{"t": "ack_degraded"}
{"t": "arm_live", "hold_ms": 1500}
{"t": "kill",     "level": "cancel_all"}      // or "zero_out", which needs hold_ms
```

`arm_live` is the session-level arming rule 5 requires: live mode cannot be reached from
a config file, so it is reached by a held control in the panel and this message. The
engine refuses it unless the panel is connected and `mode: paper` was loaded cleanly, and
it is never sticky across a restart.

The `readback` payload is exactly what `core.readback.render()` returns. The UI holds **no
business logic** — it does not decide whether an order is unusual or high-exposure, it
renders `unusual` and `friction` because the engine said so. Keeping it dumb is what makes
it replaceable.

Bind to `127.0.0.1` only. No auth — single user, loopback (`CLAUDE.md` rule 13) — but the
engine must reject a connection whose `Origin` header is present, and refuse to bind to
`0.0.0.0` even if configured to.

## Configuration

Three files, all in `config/`, none containing secrets except the gitignored `.env`:

- `instruments.yaml` — the hand-maintained instrument table the UI picker reads.
- `staged.yaml` — risk caps, timeouts, stage TTL, ASR policy, hotkeys.
- `.env` — broker credentials, ASR API key. Loaded via environment only.

Loading is strict: a missing key, a non-numeric limit, a duplicate instrument or
`mode: live` all raise `ConfigError` at startup. A malformed config must fail loudly at
09:00, never quietly at 09:20.

All three are hot-reloadable **only when the FSM is in `IDLE`**. Never mutate config while a
command is in flight.

## Logging

One JSONL file per trading day in `logs/`. One line per FSM transition, carrying a
`command_id` (ULID) that threads the whole lifecycle. Log the audio duration, both ASR
results and their latencies, the agreement flag, the raw and normalized transcripts, the
matched phrase, the staged parameters and their age, the resolved intent or the rejection
reason, the readback string, the time-to-commit, the broker payload, the broker response,
and both reconciliation layers.

Never log credentials. Optionally persist the raw WAV per command behind a config flag —
enormously useful for tuning the vocabulary and `asr_corrections` against real speech, and
it is a single-user machine, so the privacy trade-off is the user's own to make.
