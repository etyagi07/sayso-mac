> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 06 — Voice in, and the interface

**Neither half of this document is built.** Both are design-only, kept because the
decisions in them were made deliberately and should not be re-litigated from scratch when
someone finally writes the code. Everything here is subject to measurement on the target
machine; do not trust a number in this file, including the ones stated as defaults.

---

# Part 1 — Capture and transcription

Both solved off-the-shelf; the only real decisions are *which* engine and *how to absorb
its errors downstream*.

## Capture

- **Trigger:** global hotkey, **push-to-talk** (hold) by default, with tap-to-toggle as a
  setting. Always-listening on an order channel is a liability — a hot mic that can place
  trades is not a thing to own.
- **Library:** `pynput` for the global hotkey, `sounddevice` for capture.
- **Format:** 16kHz mono int16. Both engines take it; resampling later costs nothing.
- **Ring buffer:** keep a rolling **300ms pre-roll** so the first phoneme isn't clipped when
  the user starts speaking as they press. This single detail removes a large class of
  "it heard 'ort hdfc'" failures.
- **Endpointing:** `webrtcvad` (cheap, fine) or `silero-vad` (better, heavier). On
  push-to-talk, key release is the primary endpoint and VAD is only a backstop for
  tap-to-toggle mode.
- **Guards:** minimum utterance 400ms (below that → discard silently); maximum utterance
  **4s** (`audio.max_utterance_ms`; above that → reject — the longest phrase in the
  vocabulary is "square off the position the put" and nobody says that slowly).

## Transcription: dual path

Two engines run **concurrently** on every utterance. Cost is negligible at one user's
volume, and it buys both latency insurance and a free disagreement signal.

```python
# asr/race.py
async def transcribe(pcm) -> RaceResult:
    local = asyncio.create_task(local_engine.transcribe(pcm))
    cloud = asyncio.create_task(cloud_engine.transcribe(pcm))
    ...
```

**Policy** (under `asr:` in `staged.yaml`, so it can be tuned from measurements):

1. Start both. Wait up to `prefer_cloud_window_ms` (default **400ms**) past the first
   result for the other to arrive.
2. If **both** arrive and the normalized texts **agree** → use it, log `agreement: true`.
   This is the common case and it's a genuine confidence signal — two independent engines
   hearing the same thing is stronger evidence than either one's internal score.
3. If both arrive and they **disagree** → set `agreement: false` and pass the preferred
   transcript on anyway. **`core/resolve.py` is what rejects it**, with
   `RejectReason.ASR_DISAGREEMENT`. The ASR layer flags; core decides. That split is not
   cosmetic: rule 10 requires the decision to be pure-function-testable, and a rejection
   buried in `asr/race.py` could only be tested with audio.
   The decision itself is strict — with symbols out of the voice path the utterance is one
   short phrase, and two engines disagreeing about a three-word command means neither
   should be trusted. The trader says it again, which costs two seconds.
4. If only one arrives within `total_budget_ms` (default **1800ms**) → use it, and push
   the single-engine state into `Readback.warnings` so the card shows it.
5. If neither arrives → `RejectReason.ASR_UNAVAILABLE`, shown as "transcription
   unavailable". Never proceed.

Always log both transcripts, both latencies, and the agreement flag. After a few weeks this
tells you whether the cloud path is earning its network dependency at all — it may not be,
and dropping it would be a real simplification.

## Local engine

`faster-whisper` (CTranslate2). On Apple Silicon, run `small.en` or `distil-small.en` with
`compute_type="int8"`; `base.en` if latency still isn't good enough. Whisper's own
`large-v3-turbo` weights are also available locally if the machine can take them.

- Pin the model in settings; never auto-select.
- **Prime it at startup** with a dummy 500ms transcription. A cold first call is several
  times slower and that will be the first order of the day.
- Pass an `initial_prompt` containing the command vocabulary. Whisper conditions on it and
  it measurably improves recognition of domain terms. Generate it from `core.commands`
  at load, not by hand — the phrase table already exists.

Measure actual latency on the target machine and record it in the repo. Don't
trust any number in this document, including the ones above.

## Cloud engine

Any OpenAI-compatible transcription endpoint. Groq's Whisper deployment
(`whisper-large-v3-turbo`) is the reference choice — same Whisper API shape, hosted, fast.
Deepgram is the alternative if streaming partials are wanted later.

- Supply the same `prompt` (the command vocabulary).
- **Hard timeout** at `asr.cloud.timeout_ms`; a hung cloud call must never stall the pipeline,
  which is exactly what the local path is insurance against.
- Key from `.env`. Never logged.
- Note that audio of order intent leaves the machine on this path. Single user, their call,
  but it should be a conscious setting: `cloud_enabled: true/false`.

## Streaming partials

Show interim text in the panel purely as **liveness feedback** — proof the mic is hearing
something. Partials must never drive resolution. Only the final transcript enters the
pipeline.

## What not to build

- **No custom acoustic model, no fine-tuning.** The input space is 504 phrases over three
  verbs. Shrinking the problem beats growing the model, costs nothing, and can be debugged
  by reading a dict. This got dramatically easier when symbols left the voice path.
- **No confidence-score-driven auto-accept** based on the ASR engine's internal logprobs
  alone. There are no confidence bands left to feed — they were deleted with the resolver.
  A logprob may be logged; it may not decide anything.
- **No LLM post-processing of the transcript.** It would fix some errors and silently invent
  others, and "silently invent" is disqualifying here (`CLAUDE.md` rule 11).

---

# Part 2 — The interface

Two parts now: the **order panel** where parameters are configured, and the
**readback card** that opens over it at the gate. An earlier design had only the card,
because voice carried the parameters; the panel is what changed.

The panel is a small, always-on-top floating surface. Reference feel: the class of Mac
assistant widgets that sit over your work as a compact pill and expand only when they have
something to say.
The design constraint here is stricter than those, though, because this panel exists to be
read in a **glance taken without leaving the chart**.

## Non-negotiables

1. **Frameless, always-on-top, draggable, no dock icon, no menu bar clutter.**
2. **Small when idle.** A pill you forget about. It must not compete with the chart.
3. **Legible at a glance from peripheral vision.** Shape and colour carry as much
   information as text.
4. **Never steals focus.** Ever. Clicking it must not deactivate the chart window, and
   showing the readback must not either. On macOS: `NSPanel` with
   `nonactivatingPanel` behaviour — in Qt terms `Qt.Tool | Qt.FramelessWindowHint |
   Qt.WindowStaysOnTopHint` plus `Qt.WA_ShowWithoutActivating`, and verify the panel really
   is non-activating rather than assuming the flags did it.
5. **The commit key is captured globally**, not by the panel having focus — because the
   panel never has focus. The hotkey listener in the engine owns `Space`/`Esc`, and **only
   while the gate is open**. Outside that window those keys must pass straight through to
   whatever app the user is actually in. Getting this wrong eats spacebars in every other
   app, which is the fastest way to make the tool unusable.

## Four shapes

Every resize is motion in peripheral vision, and motion is the most expensive signal this
interface can spend. Eight sizes — one per FSM state — would make the panel twitch through
listening, resolving, submitting and reconciling, and the trader would learn to ignore it
moving. That trains away the one signal that has to work.

So there are four shapes, and a **system-initiated** shape change means exactly one thing:
*something needs your eyes now.* Setup is the exception that proves it — the trader opened
that one deliberately, so its expansion spends no signal.

| Shape | Size | FSM states | Content |
|---|---|---|---|
| **Pill** | ~200×36 | `IDLE` | Mode (`PAPER` / `LIVE`). Nothing staged. Ignorable by design. |
| **Setup** | ~340×260 | `IDLE`, or invoked from `STAGED` | Building or changing the contract. Trader-invoked, dismissed on staging. See below. |
| **Panel** | ~340×88 | `STAGED`, `LISTENING`, `RESOLVING`, `SUBMITTING`, `RECONCILING`, `RESULT` | Contract · strike · qty · limit, plus the stage-age indicator. Content changes between these states — level meter, partial text, shimmer, spinner, fill detail — but **the footprint does not**. |
| **Card** | ~380×150 | `AWAITING_COMMIT`, `DEGRADED` | The readback over the panel, with the countdown bar. Or the reconciliation mismatch, which does not auto-dismiss. |

The `RECONCILING` content is never skipped even though it shares the panel footprint: it is
the window in which silent failure happens, and a panel that jumps from `SUBMITTING`
straight to a fill hides it.

### Setup is used constantly, not once

An earlier draft treated setup as something passed through on the way to the real
interface. That was wrong, and it is the kind of wrong that produces a bad tool: price
moves, so the trader re-picks a strike **many times a session**. It is the surface they
touch most often, and it deserves as much care as the card.

It must be fast, and it must need no typing where a tap will do:

```
ACTIVE INSTRUMENT

Underlying   [ NIFTY          ]     search / autocomplete — "NIF" -> NIFTY
Expiry       [ 25 Sep ] 2 Oct  9 Oct    3-4 chips, one tap, nearest first
Strike       ‹  23,400  ›               steppers: ±50 NIFTY, ±100 BANKNIFTY
                spot 23,412 · ATM       ALWAYS show spot, mark the ATM strike
Type         [ CE ]  PE                 unmistakably distinct, not a subtle toggle
Quantity     ‹  1 lot  ›  = 75          step in lots, always show the share count
Limit        [ 142.50 ]  LTP 142.50 ⟳   live price beside it, one tap to match

                    [  ARM  ]
```

Two details that are not decoration:

- **Spot and the ATM marker.** A strike picker with no reference to spot makes the trader
  do arithmetic to know how far out-of-the-money they are. Show both.
- **One-tap LTP match.** Options need an explicit limit (`allow_protected_market_options`
  is false), so a limit price has to be entered on *every* setup. Typing one under
  pressure is where a decimal slip comes from.

### Strike stepping from the panel

The single most frequent edit is nudging the strike one step. Opening the full setup shape
for that is friction the trader pays fifty times a day, so the staged panel carries its own
steppers:

```
‹ NIFTY 23,400 CE › · 1 lot (75) · limit 142.50 · staged 12s   🎙
```

A step re-stamps the stage (rule 21 — any edit does) and re-prices the limit against the
new strike's LTP. This is the one interaction that has a speed target rather than a safety
target; see the re-arm test below.

**The staged panel is always visible when something is staged.** The trader must never have
to remember what the next spoken word will act on — that is the whole safety argument for
moving parameters into the UI, and it is void if the parameters are off screen. Stage age
is shown continuously and turns amber as it approaches `stage_ttl_s`.

## Position and growth direction

The panel is **draggable and remembers where it was put**. That single fact determines the
rest:

- **Growth direction is derived, never hardcoded.** On expanding to the card, the panel
  works out which screen corner it is nearest and grows *away* from it. Pinned
  bottom-right, the card grows up and left. Get this wrong and dragging it to a different
  corner one day pushes the card off screen — silently, at the exact moment it matters.
- **The anchored corner stays fixed across all four shapes**, so the text the eye is
  looking for does not move between them. The side (`BUY` / `SELL`) renders closest to the
  anchor, because it is the field whose error is most expensive and the eye lands there
  first.
- Transitions animate over ~120ms. Enough to read as a change, short enough not to be a
  distraction in its own right.
- Only the window position is persisted, in a small local file.

On which corner: worth checking against the actual chart layout before settling. Top-right
collides with macOS notification banners, and most charts put the price axis on the right
and the time axis along the bottom, so the left edge is often the deadest screen space.
That is the trader's call — the software's job is to remember the answer.

## Mode must be unmistakable

`PAPER` and `LIVE` are visually different at a distance — not a small text label, a
different **border treatment and accent colour** for the entire panel. Live mode should
feel slightly uncomfortable. Add a persistent thin accent line along the panel edge in live
mode so that even the idle pill is distinguishable.

There must be no state in which the trader can be unsure which mode they are in.

**Going live is a control on the panel, not a setting.** Rule 5 forbids reaching live mode
from a config file, so the panel carries a deliberately awkward one: held for 1500ms,
placed away from every other control, sending `{"t": "arm_live"}`
(`docs/03-architecture.md`). It is never sticky — a restart comes back in `paper`.

## Colour and type

- Dark, translucent background (`NSVisualEffectView`-style blur if available; a flat dark
  panel at ~92% opacity is fine and simpler).
- **BUY** and **SELL** get two colours that remain distinguishable under red-green colour
  blindness — do not rely on red/green alone. Pair colour with the spelled word and with
  position (side is always the first element). **CE and PE must also be visually distinct**
  in the staged panel, for the same reason the qualifier exists.
- Numerals in a **tabular-figures** font so quantities and prices do not jitter between
  renders. `SF Mono`, `JetBrains Mono` or any monospace with tabular figures.
- Minimum 13pt for the side and symbol, 11pt for detail lines. Target legibility at ~70cm
  in peripheral vision.

## The countdown bar

A depleting horizontal bar along the bottom of the readback card. **No numeric countdown** —
a bar is readable peripherally without refocusing, which is the whole thesis of the project.
It changes colour in the last 1.5s.

## The two tests

Both are required, and a design can pass one while failing the other.

**1 — The glance.** Put the panel on a second monitor, look at a chart on the first, and
check whether you can tell, *without moving your eyes*: (a) that a readback appeared,
(b) whether it is a buy or a sell, (c) whether the order is unusual for you, and (d) which
contract is staged. Four for four, or the UI is wrong regardless of how good it looks.

**2 — The re-arm.** Change the strike by one step and re-stage in under two seconds without
leaving the panel. This one is about adoption rather than safety: if moving a strike is
tedious the trader stops doing it, trades the wrong strike or abandons the tool, and a
perfect readback on an order they did not want is no use to anyone.

## Implementation notes

- **PySide6** for v1 (`docs/03-architecture.md` explains why). `QWidget` with
  `Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool`, translucent background,
  custom paint.
- Consume the engine's local WebSocket; render purely from pushed state. **The UI holds no
  business logic** — it does not decide whether an order is unusual or high-exposure, it
  renders `unusual` and `friction` because the engine said so. The one thing it owns is
  collecting the staged parameters and sending them as a `stage` message; validation of
  those still happens engine-side in `StagedOrder.__post_init__`.
- Persist only window position, in a tiny local file; derive growth direction from it
  at render time rather than storing a direction.
- The panel must reconnect automatically if the engine restarts, and show a clearly
  "disconnected" pill in the meantime — never a normal-looking idle pill when it isn't
  actually connected to anything.
