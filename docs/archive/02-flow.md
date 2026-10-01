> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 02 — The flow

**This document is the current truth about the product model.** Where any other document
disagrees with it, this one wins and the other document is a bug — except `CLAUDE.md`,
whose invariants and settled decisions outrank everything here. Full precedence order is
in `README.md`.

## The model

An earlier design made voice carry the whole order: `short hdfc bank forty`. Almost all of
its effort went into one problem — "hdfc" is three different companies — and produced alias
tables, confidence bands, check words and a CI collision checker. That work is in
`docs/archive/`.

For options the problem was **self-inflicted**. The trader is already looking at a chain and
has already selected a strike. Making the microphone re-derive what the cursor knows adds a
failure mode for no gain.

So: **the UI configures, voice acts, a keypress commits.**

```
Instrument + Strike + Quantity   (UI, hands and eyes)
            │
            ▼
        "buy call"               (voice, the action)
            │
            ▼
        readback card            (resolved order, glanceable)
            │
            ▼
         Space                   (keypress, the commit)
            │
            ▼
        execute → audio + visual confirmation
```

## The vocabulary

Fixed and finite (`CLAUDE.md` rule 11). Built **systematically** in `core/commands.py` from
lemmas at import time, not hand-listed — the cross product and the collision check come for
free, and adding a verb is a one-line change.

```
VERBS      BUY   buy, long, go long
           SELL  sell, short, write, go short
           EXIT  exit, close, square off, flatten, get out of
OBJECTS    (none), this, it, that, the position, position
QUALIFIERS CALL  call, calls, the call
           PUT   put, puts, the put
```

12 verb forms × 6 objects × 7 qualifier forms (including the empty one) = **504 phrases**,
collision-checked at import. `zero-doctor` prints the count per meaning and the total, and
the total is asserted in a test — an earlier draft claimed 360, which the table beside it
could not produce.

`ce` / `pe` are deliberately **not** in the table. Two-phoneme tokens have poor acoustic
separation from each other and from whatever precedes them, and the distinctness rule below
applies to qualifiers as much as to verbs. Say `call` or `put`.

The kill switches (`cancel all`, `zero out`) are **not** in this vocabulary and never will
be — they are hotkey-only (`CLAUDE.md` rule 23). Spoken, they reject.

Matching is **exact lookup only**. No stemming, no fuzzy matching, no near-miss handling,
no LLM. `bui call` and `buy cal` both reject. An unrecognised phrase is a rejection, and
rejection is a normal outcome that costs two seconds.

**Where "exact" starts.** One step sits between the transcript and the lookup:
`core/normalize.py` lowercases, strips a fixed filler list, and applies
`normalize.asr_corrections` — a closed substitution table (`bye` → `buy`, `cell` → `sell`).
That is not fuzzy matching and must never become it. The distinction is that every entry
is a **specific pair a human observed in this trader's own logs and typed in**, reviewable
by reading a dict; nothing is computed, scored, or inferred at runtime. After
normalization the lookup is exact and total. Do not add an entry from imagination, and do
not add a rule that generates entries.

The acoustic rule from the archived grammar still applies to the verb set: **keywords that
mean opposite things must not rhyme or share a stressed vowel.** `buy` / `sell` / `exit` are
mutually distant. Never add a verb that collides — you own the vocabulary.

## The instrument table

`config/instruments.yaml` is the curated starting list, and the UI populates a picker
from it. Selection is **visual, not acoustic**, which is what makes an unmatched name
impossible rather than merely rejected — the safety property is that nothing *spoken*
ever chooses an instrument.

`CLAUDE.md` rule 12 was narrowed to say exactly that, and no more: no fuzzy matching in
the **voice path**. The picker itself may search or autocomplete over as large a symbol
master as is useful, which is what the brief asks for
(`docs/00-brief-as-given.md`). What the trader picks is on screen, confirmed at stage
time, and re-rendered in the readback, so a mis-click is visible in a way a mis-hearing
is not.

## What this keeps, unchanged

- **Rule 1/2:** voice composes, a keypress commits. Two channels.
- **Rule 4:** the readback renders the resolved order, never the user's words.
- **Rule 3:** every ambiguous path fails to CANCEL.
- **Rule 6:** `OrderIntent` is fully specified or it does not exist.
- **Rule 7:** no bare market orders.
- **Rules 8/9:** idempotency tags and mandatory reconciliation.
- Push-to-talk. See "Why not always-listening".

## What the qualifier is

The single best idea to come out of this change.

`buy call` parses as **action BUY + qualifier CALL**. The qualifier is **not a selector** —
it does not choose the call leg. It is an *assertion about what is staged*, verified against
the staged order:

| Spoken | Staged | Outcome |
|---|---|---|
| `buy call` | NIFTY 25000 **CE** | proceeds to readback |
| `buy call` | NIFTY 25000 **PE** | **REJECT** — `qualifier_mismatch` |
| `buy` | either | **REJECT** — `qualifier_required` (default; see below) |

The idea comes from the Vocollect check digit (`docs/archive/04-resolution.md`), but it is
not the same mechanism and the difference matters — see "Be precise about what the
qualifier protects" below. The check digit verified the thing that was at risk; here the
contract is chosen in the UI and is already on screen.

Consequence worth stating plainly: **a bare `buy` carries less proof than `buy call`.** The
config option `require_qualifier_for_options` (default `true`) makes the qualified form
mandatory on option orders, because that is where a single misheard monosyllable is most
expensive. This is a settled decision (`CLAUDE.md` section E), and it means the brief's
headline example — a bare "Buy" — is not the intended interaction. `buy call` is.

**Be precise about what the qualifier protects**, because it is easy to over-claim. It does
*not* protect against a side error: `buy call` and `sell call` share the qualifier, and the
contract it asserts came from the UI and is on screen already. What it does protect, and
both are real:

1. **A stray utterance.** A "buy" in conversation cannot place an order. This is the main
   defence and the reason the flag defaults on.
2. **A stale stage.** Muscle-memory `buy call` against a PE staged twenty minutes ago
   rejects — failure mode 4 caught by the vocabulary rather than by the clock.

Nothing in the voice path guards buy-versus-sell. The readback and the keypress are the
only defence there, which is a further argument for both.

## Side semantics against an existing position

The vocabulary folds `sell`, `short` and `write` into one `SELL` verb, which leaves a
question the archived grammar answered explicitly and this one must too.

The rule is symmetric: **a command that opposes the position reduces it and stops at
flat; a command that agrees with it adds.** Nothing flips in one utterance.

| Spoken | Position in the staged contract | Result | Intent |
|---|---|---|---|
| `buy call` | flat | open long, staged quantity | `OPEN_LONG` |
| `buy call` | long 75 | add 75 more (agrees) | `OPEN_LONG` |
| `buy call` | short 75 | close the short, clamped to 75 | `CLOSE_SHORT` |
| `buy call` | short 75, staged qty 150 | close 75, marked `clamped`; the extra 75 is **not** bought long | `CLOSE_SHORT` |
| `sell call` | flat | open short (write), staged quantity | `OPEN_SHORT` |
| `sell call` | short 75 | add 75 more (agrees) | `OPEN_SHORT` |
| `sell call` | long 75 | close the long, clamped to 75 | `CLOSE_LONG` |
| `sell call` | long 75, staged qty 150 | close 75, marked `clamped`; the extra 75 is **not** sold short | `CLOSE_LONG` |
| `exit` | long or short 150 | close all 150 in **that contract** | `CLOSE_*` |
| `exit` | flat | reject, `no_position` | — |

`CLAUDE.md` rule 22. The flip is the case that matters: turning a closed long into a fresh
naked short with one misheard syllable is an open-ended loss, and the trader asked for
neither leg of it. Reversing takes two commands, deliberately.

Both `OPEN_SHORT` rows are `friction: hold` — writing an option is not the same act as
closing a long and the card should not feel the same.

`EXIT` is scoped to the staged **contract**, not the underlying. Long two NIFTY strikes
with 25000 CE staged, `exit` closes 25000 CE only.

## Why the commit gate stays

Shrinking the command removes the ambiguity class but **concentrates the remaining risk**.

`short hdfc bank forty` has four tokens that must all parse, and the archived grammar's
rule — unknown token anywhere rejects the whole utterance — means a misrecognition almost
always produces a *rejection*. The redundancy is the safety mechanism.

A bare `buy` has no redundancy. **It cannot reject.** Anything that sounds like "buy" is a
complete, valid, fully-specified command against live pre-configured parameters. There is no
parse failure available to catch the error.

So per-utterance risk goes *up* even though the vocabulary got simpler, and the keypress is
what puts the redundancy back. `allow_voice_confirm` stays `false`: turning it on collapses
both channels into the one that has no redundancy left, which is why `CLAUDE.md` rule 2
calls it documented-unsafe.

## Why not always-listening

The brief this mode came from asks for a persistent listening state. The mic is instead
**armed only while an order is staged**, and push-to-talk remains the default
(`docs/06-voice-and-ui.md`: a hot mic that can place trades is not a thing to own).

`listen_mode: armed_window` is the middle ground: once parameters are staged, the engine
will accept a push-to-talk utterance within `stage_ttl_s`. It does not hold an open mic.

## Stage staleness

The failure mode this flow introduces that the old one could not: **parameters set twenty
minutes ago, acted on now.**

- A staged order has `staged_at` and expires after `stage_ttl_s` (default 90s).
- Any change to instrument, strike, quantity or limit **re-stamps** it.
- An expired stage rejects with `stage_expired`; the trader re-confirms in the UI.
- Expiry is enforced **twice, deliberately**: `listen_mode: armed_window` declines to arm
  the mic on an expired stage, and `core/resolve.py` checks again against an injected
  `now`. The input gating is best-effort convenience; the resolve-time check is the
  authoritative one, because it is the only half that is pure-function-testable and the
  only half a fixture can exercise.
- The panel shows stage age, and the readback always renders the staged parameters so what
  is about to happen is on screen at commit time.

## Options and notional

For an option these are different numbers by two orders of magnitude:

- **premium notional** = `quantity × premium` — what leaves the account
- **underlying notional** = `quantity × strike` — the delta-1 exposure

NIFTY 25000 CE × 75 at ₹142.50 is ₹10,687 of premium and ₹18,75,000 of underlying. A single
`max_notional_per_order` cannot mean both, which is why the risk config now carries
`max_premium_per_order` and `max_underlying_notional_per_order` and checks both. The
readback shows both. This replaces the unresolved cap question from the equity spec.

`allow_protected_market_options: false` still holds (`docs/05-execution.md`): option
orders require an explicit limit, so the UI supplies the limit price. An option stage with
no limit cannot be constructed at all — `StagedOrder.__post_init__` raises — so this is a
**stage-time UI rejection**, caught when the trader tries to stage, not a voice-time one.
The
`RejectReason.NO_PRICE` member exists for the equity and futures paths, which are allowed
by the model and never exercised.

## EXIT

`exit` / `close` / `close position` acts on the **live position** in the staged contract,
not on the staged quantity. It is rejected when flat. Per the brief and
`docs/05-execution.md` it is treated as destructive: it always requires hold-to-commit,
regardless of exposure.

Its readback still renders the staged contract — rule 21 requires the stage to be on
screen whenever it is actionable, and `EXIT` is precisely the command where stage and
action differ, so hiding it would be worst there. The difference is that the **quantity**
comes from the book rather than the stage, so it is shown as a marked, computed line:
`quantity full position (+150)` (`docs/04-safety.md`).

The qualifier is **not required for `EXIT`**, even with
`require_qualifier_for_options: true`. There is no leg to assert against when you are
closing what you already hold, and the staged contract identifies it. `exit`, `close` and
`close position` are all accepted bare.

## Module boundary

`CLAUDE.md` rule 16 — `core/` has no UI, audio or broker imports. The new split:

```
core/intent.py      THE CONTRACT — every type below. Already written; build against it.
core/normalize.py   transcript -> normalized text     (filler, asr_corrections)
core/commands.py    phrase  -> VoiceCommand           (vocabulary, no state)
core/staged.py      the UI-configured parameters
core/resolve.py     StagedOrder + VoiceCommand + world -> OrderIntent | Rejection
core/readback.py    OrderIntent -> visual dict + speech string
core/risk.py        limits, both notionals
core/fsm.py         lifecycle
```

Command interpretation never touches execution; `resolve()` is pure and returns a value.
This is the brief's instruction 5, and it was already `CLAUDE.md` rule 10.

## Audio

Nothing makes a sound until an order is confirmed. See `docs/04-safety.md`.

## Where the numbers live

Nothing in this document is a constant. Every threshold is in `config/staged.yaml` and
every one of them is a **starting point to be tuned from logs, not from intuition**:

| Setting | Default | What it controls |
|---|---|---|
| `listen_mode` | `armed_window` | PTT accepted only while something is staged and unexpired |
| `stage_ttl_s` | 90 | How long staged parameters stay actionable |
| `require_qualifier_for_options` | true | Whether a bare `buy` can place an option order |
| `allow_voice_confirm` | false | **Unsafe.** Lets voice both compose and commit |
| `gate_timeout_ms` | 6000 | Readback auto-cancel |
| `hold_to_commit_ms` | 800 | Hold duration for high-exposure and EXIT |
| `max_premium_soft` | 30,000 | Above this, hold-to-commit |
| `max_premium_per_order` | 2,00,000 | Binds on expensive (deep ITM) options. Divided by lot size it is the highest per-unit price tradable at one lot — see `docs/05-execution.md` |
| `max_underlying_notional_per_order` | 1,00,00,000 | Binds on cheap options in size |

`zero-doctor` reports how many lots each instrument can actually trade before a cap bites,
and fails if a cap makes an instrument untradeable at one lot. That check exists because
the first pair of caps chosen for this project silently did exactly that.
