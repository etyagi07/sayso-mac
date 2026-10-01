> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 07 — Roadmap

Replaces the original build plan, whose milestones were organised around a problem that no
longer exists. M1 there was "resolution, offline" — symbol matching, alias collision
checking, confidence bands — and that milestone was not completed so much as **deleted**
when parameters moved into the UI.

The ordering principle survives and is still the point: **build the hard, dangerous stages
first, with no microphone and no broker.** The fun parts are the ones that can wait.

---

## What exists

An implementation of M0–M2 existed briefly and was deleted. Two files were then written
deliberately, to unblock M1, and they are the only code in the repository:

| File | What it is |
|---|---|
| `core/intent.py` | **The contract.** `StagedOrder`, `VoiceCommand`, `OrderIntent`, `Rejection`, `Readback`, the broker types. Verified on 3.11: the rule 6 and rule 7 guards raise, `Side` has no `SHORT`/`COVER`, `PriceType` has no `MKT`. |
| `tests/fixtures/staged_commands.yaml` | 30 golden cases, 15 of them rejections. Cases marked `[GATE]` are the structural M1 assertions. |

Everything else below is the plan, not a record, and each milestone's acceptance criteria
stand as **targets**.

One finding from that implementation is worth keeping, because it was discovered
by running code rather than by reasoning, and it will recur: the two notional
caps are not independent. `underlying ÷ premium` is `strike ÷ price`, so a
carelessly chosen pair makes one of them unreachable dead code, and a cap that
looks generous can block even a single lot. See `docs/05-execution.md`.

### M0 — Scaffolding

- `pyproject.toml` (uv-ready), Python 3.11+, the layout in `docs/03-architecture.md`.
- `ruff` + `mypy --strict` clean on `core/`.
- Config loading with schema validation that fails loudly at startup.
- JSONL logger with `command_id` threading and secret redaction.
- The import-graph test: `core/` importing downstream is a build failure.

**Acceptance:** `zero-doctor` validates config, prints the vocabulary and instrument
tables with a per-cap tradability report, and exits 0.

### M1 — The staged-order core

- `core/staged.py`, `commands.py`, `normalize.py`, `resolve.py`, `readback.py`, `risk.py`,
  `world.py`, `fsm.py` — all pure, all `mypy --strict`. `core/intent.py` already exists;
  build against it rather than redefining its types.
- The vocabulary generated systematically and collision-checked at import; the total (504)
  asserted in a test.
- A CLI driving the whole loop from a typed string to a reconciled order.

**Acceptance:**
- Every case in `tests/fixtures/staged_commands.yaml` passes, and every case marked
  `[GATE]` is additionally asserted as a property, not just as a fixture.
- A test asserting the hard gate: no spoken word can produce an order larger than what is
  staged, on a different strike, or on a different option type. This replaces the old
  "zero wrong-instrument resolutions" gate and is stronger — structural, not statistical.
- Runs with no network, no audio device, no clock beyond an injected `now`.

### M2 — Paper broker and reconciliation

- `broker/paper.py`: configurable latency, rejections, partial fills, lost responses.
- `engine/execute.py`: idempotency tagging, find-by-tag recovery, both reconciliation
  layers, `DEGRADED`.

**Acceptance:** a chaos test runs 200 commands with 10% lost responses, 5%
rejections and 5% partial fills — zero duplicate orders, every lost response recovered by
tag or landed in `DEGRADED`, never silently. An induced position mismatch forces
`DEGRADED`.

---

## Next

### M3 — The UI

The entire model depends on the staged parameters being continuously visible, so this
cannot be deferred behind the voice path the way the original plan deferred the panel.

- `engine/server.py` (127.0.0.1 WebSocket, `Origin` rejected, refuses to bind `0.0.0.0`).
- The order panel: instrument picker from `instruments.yaml`, strike, lots, limit.
- The readback card, countdown bar, hold-to-commit ring, `DEGRADED` state.
- `engine/hotkey.py`.

**Acceptance:**
- The glance test in `docs/06-voice-and-ui.md`, all four questions, on two monitors.
- `Space` and `Esc` pass through to other applications when the gate is closed. Verify in
  a text editor. This is the most likely regression in the whole project.
- The panel never steals focus — verified by typing continuously in another app while
  running twenty commands.
- Killing the UI mid-gate cancels the command; restarting it reconnects cleanly and
  re-renders the staged parameters.
- Stage age is visible and the panel is unmistakable about `PAPER` vs `LIVE`.

### M4 — Voice

- `audio/capture.py` with 300ms pre-roll, `audio/vad.py`.
- `asr/local_whisper.py`, `asr/cloud.py`, `asr/race.py`.
- `initial_prompt` generated from `core.commands`.

**Acceptance:**
- p50/p95 latency for local and cloud, measured on the target machine and **written into
  the repo**. Agreement rate over 100 real utterances.
- Cold-start priming verified: the first transcription of the session is within 2× p50.
- 100 spoken utterances captured to a file, every one added to the golden fixtures with
  its expected outcome. **This is the real deliverable of M4** — the fixture file then
  contains this trader's actual speech, not imagined speech.
- Specifically: how often does "buy" come back as "by" or "bye"? That single number
  decides whether `require_qualifier_for_options` can ever be turned off.

### M5 — Live, carefully

**Prerequisites, all before a line of `broker/shoonya.py` is written:**

- [ ] Static IP obtained and registered with the broker.
- [ ] Written confirmation from Finvasia on API access, any registration requirement for
      this usage pattern, market-protection semantics, and rate limits — recorded in
      `docs/broker-notes.md`.
- [ ] The correct `tsym` format for weekly and monthly index options confirmed. The CLI
      currently generates a **guess** (`NIFTY24SEP2625000CE`) that has never been
      validated against the venue.
- [ ] Current lot sizes confirmed against the live contract spec.
- [ ] API credentials in `.env`, TOTP automation working.

Then: the adapter, WebSocket LTP subscription, position polling, and session-level arming
to enter live mode (`CLAUDE.md` rule 5).

**Rollout, in this order, no skipping:**

1. Live login + live market data, **paper execution**. A full session. Check every
   notional against the broker terminal.
2. Live execution, **one lot, one liquid strike, `max_premium_per_order` set to ₹5,000**.
   Ten orders across a session, each reconciled by hand against the broker terminal.
3. Real size, limits raised one step at a time over a week.

**Acceptance:** thirty consecutive live orders with correct reconciliation and zero manual
interventions, before limits go anywhere near normal size.

### M6 — Hardening

- Fatigue telemetry and friction escalation (`docs/04-safety.md`). Log
  `time_to_commit_ms` from M3 so there is data when you get here.
- A weekly log review script: rejection reasons by frequency, ASR agreement rate,
  qualifier-mismatch rate, cancel-after-readback rate, median time-to-commit.
- Crash recovery: on startup, always reconcile the day's order book against the local log
  before accepting a command.
- `reject_cooloff` and `session_hours`, both specified in `docs/05-execution.md` and
  neither implemented.

**Acceptance:** the weekly report runs on one command and answers, without interpretation:
is the gate still catching anything, and is the trader still reading it.

---

## Explicitly out of scope

Not "later" — **out of scope**, unless the invariants in `CLAUDE.md` are deliberately
revisited first:

- Conditional / triggered orders ("if it breaks 25100")
- Any LLM in the order path
- Baskets, spreads, multi-leg strategies
- Fuzzy search over the full exchange symbol master
- Multi-user anything
- Mobile
- Auto-execution without a keypress
- A public web UI

## Known gaps to design around

Carried over from the deleted implementation, so nobody rediscovers them the hard way:

| Gap | Where |
|---|---|
| `tsym` construction for index options is unspecified | blocks M5; `docs/broker-notes.md` Q7 |
| Session-hours check | specified in `docs/05-execution.md`, never implemented |
| `reject_cooloff` lockout | same |
| Equity and futures paths | the model allows them; never exercised |
| Position identity | the broker's own key shape is unconfirmed |
| The old equity fixtures still contain six known inconsistencies | `tests/fixtures/transcripts.yaml` header |
| `max_orders_per_minute: 6` may bind during a fast move | `docs/05-execution.md`; it is an ergonomics number, not a safety one — 10/s is 600/min |
| The brief's development instructions 1–3 assume a codebase that does not exist | `docs/00-brief-as-given.md`; rewrite them for the next handoff, do not edit the brief |
| No test runner, no `pyproject.toml`, no `zero-doctor` | M0 |
