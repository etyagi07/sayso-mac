> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 04 — Safety: the gate, and the five things that kill this

Merges what were separate confirmation and failure-mode documents. They belonged
together: three of the five failure modes are failures *of the gate*, and the fatigue
mechanic was described twice, slightly differently, in both.

---

# Part 1 — The gate

Cheap to build, and the thing that lets you get away with an imperfect ASR stage. Also the
thing most likely to rot. Part 2 is about the rot.

## Four rules

1. **Read back the resolved order, never the user's words.** (Aviation: expectation bias.)
2. **Commit on a different channel from the one that composed the order.** (Open outcry:
   palm-in/palm-out alongside voice.)
3. **Show rupee exposure, not just quantity.** ₹10,687 is a number the trader has intuition
   about. "75" is not.
4. **Timeout cancels.** Always. Never "timeout confirms because you were probably fine".

## The readback

A canonical rendering of `OrderIntent`, produced by `core/readback.py`. Pure function,
unit-tested, returning both a visual structure and a speech string.

```
┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ BUY  NIFTY 25000 CE                                  ┃
┃ 75 qty  (1 lot) · NRML                               ┃
┃ limit 142.50                                         ┃
┃ premium  ₹10,687.50                                  ┃
┃ underlying  ₹18,75,000                               ┃
┃ NIFTY24SEP2625000CE                                  ┃
┃ `commit` to send  ·  `cancel`  ·  auto-cancel 6000ms ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
  (silent — nothing is spoken before the commit; see "Audio feedback" below)
```

Field order is fixed: **side, contract, quantity, product, price, exposure.** Side first,
because it is the field whose error is most expensive and the eye lands there first.

### Rendering rules

- **Side** in the largest weight, colour-coded, spelled out — `BUY`, not an arrow.
- **Contract** rendered as the trader thinks of it (`NIFTY 25000 CE`), with the raw `tsym`
  in smaller text underneath, because that is what actually gets sent.
- **Both notionals on an option.** Premium is what leaves the account; underlying is the
  delta-1 exposure. They differ by ~100×. See `docs/02-flow.md`.
- **Computed and clamped fields are marked** and named on their own line. An `EXIT` shows
  `quantity full position (+150)`, because that quantity came from the book, not the stage.
- **Rupees always**, with Indian digit grouping — `₹18,75,000`, not `₹1,875,000`.
- **Stale quote** turns the exposure amber and appends the age. Note what a stale LTP
  actually corrupts: neither notional uses it (premium is qty × price, underlying is
  qty × strike), so the exposure figures stay correct. What goes stale is the
  `limit_sanity_pct` check, which measures the limit against LTP. Past
  `max_quote_age_ms` that check is **skipped, not relaxed**, and the readback carries a
  warning saying so — a sanity check against a price from ten minutes ago is worse than
  no check, because it looks like one. No quote at all is `RejectReason.NO_QUOTE`.

### Anti-pattern-matching

A readback the eye can skip is a readback that isn't read. Two cheap mitigations, both
implemented:

- **The card's shape changes when the order is unusual.** `Readback.unusual` is
  `intent.intrinsically_unusual or friction is Friction.HOLD` — true for a clamped or
  computed quantity, for any `EXIT`, for any order that opens or adds to a short, and
  whenever hold-to-commit is required. The friction half matters: an order over
  `max_premium_soft` must not keep an ordinary-looking card, or the most expensive order
  class is the one that looks routine. `core.intent` cannot decide this alone because
  friction depends on config, so `core/readback.py` combines the two.
  The border colour and the extra marked lines make that detectable in peripheral vision
  without reading a word.
- **Never render a fixed-width fully-constant string.** No "Confirm order? [Y/N]" that
  looks identical for every command in the day.

## The commit channel

**Voice composes. A key commits.** Two independent channels; an error in one cannot
complete a transaction alone.

| Action | Binding | Notes |
|---|---|---|
| Commit (normal) | `Space` tap | Only while the gate is open |
| Commit (high exposure or EXIT) | `Space` **held 800ms** | Progress ring in the UI |
| Cancel | `Esc`, or the hotkey tapped again | |
| Auto-cancel | 6s timeout | Countdown bar visible throughout |

**Friction scales with exposure.** Hold-to-commit engages when premium exceeds
`max_premium_soft`, and unconditionally for `EXIT`, which is destructive by nature, and for
any order whose `Intent` is `OPEN_SHORT` — writing an option, or adding to a written one,
is not the same act as closing a long, and the card should not feel the same.

**Voice-confirm is off by default**, behind `allow_voice_confirm: false`, documented as
unsafe. It defeats rule 2. `zero-doctor` reports it as a failed invariant when enabled.

## Never accept "yes"

If voice confirmation is ever used, the accepted token is **never** "yes", "confirm" or
"ok". Those are reflexes and they are also the words most likely to appear in background
speech. The accepted token is the qualifier — a word that only makes sense if the human
parsed the readback.

## Qualifier vs commit

Two distinct gates that do not substitute for each other:

- **The qualifier** (`buy call`) proves the human knows *what* is staged. Voice.
- **The commit** authorizes the order. Keypress.

An option `BUY` or `SELL` passes through both. `EXIT` passes through the commit only —
there is no leg to assert against when closing what you already hold
(`docs/02-flow.md`). **Qualifier ≠ commit** — this is easy to get wrong.

## Timeout behaviour

- Gate timeout **6s** from the moment the readback renders. There is no second prompt of
  any kind: the qualifier arrives inside the same utterance, and a mismatch cancels rather
  than re-asking (`CLAUDE.md` section E).
- The countdown is a depleting bar, never a number. A bar is readable peripherally without
  refocusing, which is the entire thesis of the project.
- On expiry: cancel, log, show "cancelled — timeout" for 1.5s, return to `STAGED`.
- **No sound on timeout.** A sound trains you to wait for the sound.

## Audio feedback

**Nothing makes a sound until an order is confirmed.** The whole pre-commit path
— listening, resolving, readback, rejection, cancel, timeout — is silent.

| Event | Sound |
|---|---|
| Listening started | *(silent)* |
| Readback ready | *(silent)* |
| Rejected | *(silent)* |
| Cancelled / timed out | *(silent)* |
| **Fill confirmed** | Distinct chime + spoken confirmation |
| **Broker rejection after commit** | Spoken, verbatim from the broker |
| **Reconciliation mismatch / DEGRADED** | **Loud, ugly, unmistakable, repeating until acknowledged** |

Three reasons the pre-commit half is silent, and they compound:

1. **A spoken readback is an input.** The microphone hears the text-to-speech,
   it becomes the next transcript, which is rejected, which is spoken again.
   Observed in the browser harness as an endless loop of the application
   talking to itself.
2. **It invites confirming what you heard rather than what was rendered.** That
   is the expectation-bias failure in `docs/01-brief.md`, arriving through the
   back door. Rule 1 of this document says read back the *resolved order*; a
   readback that reaches the ear before the eye defeats it.
3. **A sound that fires on every command becomes wallpaper**, which is
   failure mode 1 above. Reserving audio for outcomes keeps it meaningful —
   when this system makes a noise, something irreversible has happened.

The original design had a tick on readback-ready and a low tone on rejection.
Both are gone. The reasoning that killed the timeout sound — *a sound trains you
to wait for the sound* — applies at least as strongly to the gate.

To be enforced by a test that walks every pre-commit path and asserts the engine emits no
speech at all **while `allow_voice_confirm` is false**, which is the only configuration
this project ships. The renderer still *produces* the spoken string — it is worth logging,
it is testable, and it is the one thing a voice-confirm mode would have to speak — it is
simply never emitted. If anyone ever enables that flag, this test is the thing they have
to consciously exempt, which is the point.

---

# Part 2 — What would make this fail

Five now. Each gets a **mechanic**, not a warning. A warning in a README has never
prevented anything.

## 1. Confirmation fatigue

**The failure:** you stop reading readbacks and reflexively commit. The gate is still
there, still logging, still rendering — and completely decorative. This is the most likely
way the project dies, and it dies quietly, weeks after it starts working.

**Why it's likely:** the gate is correct 99% of the time, and humans stop attending to
signals that are almost always the same.

**Mechanics:**

- **Measure it.** `time_to_commit_ms` on every commit, rolling median over 50. The physical
  floor for reading a six-line card is roughly 600–800ms; calibrate once, deliberately,
  and store it as `read_floor_ms`.
- **Escalate automatically.** When the median drops below the floor, hold-to-commit becomes
  mandatory for everything and a fatigue banner appears until it recovers.
- **Make the card's shape informative** so "unusual" is detectable without reading.
- **Qualifiers can't be reflexed.** `buy call` differs per staged contract; muscle memory
  produces the wrong word, which rejects. Note what this does *not* cover: the qualifier is
  identical for `buy call` and `sell call`, so it is no defence against a side error. Only
  the readback and the keypress are.
- **Watch the cancel rate.** Exactly zero cancels over hundreds of orders means the gate is
  catching nothing — either a miracle or a symptom.

**Explicitly rejected:** injecting deliberately wrong readbacks to test attention.
Production is not a simulator; a confirmed fake is a real order.

## 2. Scope creep into natural language

**The failure:** "buy the call but only if it breaks 25100" seems like a small addition. It
turns a lookup into an interpreter with an unbounded failure surface, and once an LLM is in
the order path you can no longer enumerate what the system might do.

**Why it's likely:** it is the single most natural feature request, it will occur to you
during a live session when you actually want it, and the first version will appear to work.

**Mechanics:**

- `CLAUDE.md` rules 11 and 12 forbid it and instruct the coding agent to refuse and point
  at the rule rather than implement it.
- The vocabulary is a generated, collision-checked table of exact phrases. There is no
  partial-match path for a heuristic to creep into one commit at a time.
- Unknown phrase ⇒ reject. A test must assert that near-misses like `bui call` and
  `buy cal` resolve to nothing at all.
- If conditional orders are genuinely wanted, build them as a **separate system with a
  separate entry path** — a visible resting-order manager with its own state and alarms. A
  conditional order is a stored program; a voice command is an instruction. Different
  safety requirements, different gate.

## 3. Silent execution failure

**The failure:** you believe you are long and you are flat. Or long twice. The readback was
right, the submission looked fine, and reality diverged after that.

**Why it's likely:** the failure is invisible at exactly the moment you would catch it. You
saw a correct readback, you heard a confirmation, and you looked back at the chart.

**Mechanics:**

- **Position assertion after every fill** (`docs/05-execution.md`, layer 2). Not "did the
  order succeed" but "did my position change by exactly what I intended".
- **`DEGRADED` is sticky and loud**, blocks new commands, and needs a deliberate hold.
- **Never blind-retry.** Find-by-tag before anything else.
- **Reconcile at startup**, so a crash mid-command cannot leave an unexamined order.
- **The chaos test** is the standing gate: 200 commands with 10% lost responses, 5%
  rejections, 5% partial fills — zero duplicates, nothing silent.

## 4. Stale staged parameters — *new with this design*

**The failure:** you configure NIFTY 25000 CE × 75 to watch it, get distracted, and twenty
minutes later say something that sounds like a command. The order is placed against
parameters you no longer mean.

**Why it's likely:** it is created by the very change that removed the ambiguity problem.
Voice-composes-everything could not have this failure, because the utterance carried its
own context. A bare `buy` carries none.

**Mechanics:**

- `stage_ttl_s` (default 90s). Past it, commands reject with `stage_expired`.
- Any UI edit re-stamps the stage.
- The UI shows stage age continuously, and the readback always renders the staged
  parameters, so what is about to happen is on screen at commit time.
- Push-to-talk, not always-listening. The mic is armed only while an order is staged.
- The keypress commit, which is the backstop for every version of this failure.

## 5. Regulatory / access

**The failure:** you build the whole thing and then find you cannot get API access on your
setup, or you are operating under a rule you did not know applied.

**Mechanics:**

- **Resolve access before writing the live adapter.** The M5 prerequisite checklist in
  `docs/07-roadmap.md` blocks the milestone, deliberately.
- Static IP obtained and registered first, not last.
- Written answers from Finvasia recorded in `docs/broker-notes.md`.
- `max_orders_per_minute` enforced in code at 6, three orders of magnitude below the 10/s
  threshold even if something loops.
- No feature that emits an order without a human keypress, which is what keeps this a
  human-in-the-loop entry channel rather than a strategy.

## Minor ones worth a line each

| Risk | Mitigation |
|---|---|
| Hot mic places a trade from background speech | Push-to-talk by default; always-listening is a setting the user must turn on |
| `Space` swallowed globally, breaking every other app | Hotkey capture only while the gate is open; explicit acceptance test |
| Cold-start ASR latency on the first order of the day | Prime the model at startup |
| Stale LTP producing a wrong notional or bad protection band | Quote age check; stale ⇒ reject protected-market, flag the exposure |
| A risk cap that silently makes an instrument untradeable | `zero-doctor` computes max lots per cap and fails if it is zero |
| Token/session expiry mid-session | Single automatic re-login, then `DEGRADED`; never loop |
| Config edited mid-session | Hot reload only from `IDLE` |
| The trader in a noisy room | Push-to-talk plus the qualifier; a falling ASR agreement rate is the early warning |
| It turns out to be slower than typing and gets abandoned | Expected — the value is attention, not speed. Judge it on whether you kept your eyes on the chart, not on a stopwatch. |
