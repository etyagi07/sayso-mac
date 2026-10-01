> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 01 — Brief

## What this actually is

Strip the trading context away and you have a **constrained voice command interface over a
transactional API**. Not a voice assistant, not a chatbot — a fixed-grammar command channel
with an irreversible side effect at the end. That last part is the whole reason it's hard.
Asking a smart speaker for the weather and having it mishear costs nothing. Here, the output
is a position.

## What problem it solves — and what it doesn't

It does **not** solve speed. Typing `RELIANCE` into the broker terminal takes about three
seconds, and you will never beat that by much once you add recognition, matching and
confirmation.

The real value is **attention**: not breaking eye contact with a chart. Specifically
*visual* attention — that distinction was settled deliberately (`CLAUDE.md` section E) and
it is why a keypress commit is compatible with this goal while a click on a submit button
in another window is not. A key costs no eye movement; finding a button costs everything
the project is trying to save.

This reframing is load-bearing. If you optimize for latency you will eventually cut the
confirmation step, which is the one thing making the system safe. Optimize for attention
instead and the confirmation is nearly free — it happens while you're still looking at the
chart.

**Design consequence:** whenever a latency/safety trade-off appears, safety wins, and the
answer to "this feels slow" is to make the readback easier to absorb, never to remove it.

## The five stages, and where the difficulty actually is

| # | Stage | Difficulty | Notes |
|---|---|---|---|
| 1 | **Capture** — mic, VAD, endpointing | Solved, off-the-shelf | |
| 2 | **Transcription** — audio → text | Solved, off-the-shelf | Imperfect in ways you must absorb downstream |
| 3 | **Resolution** — text → order intent | Was the problem; largely dissolved | See below |
| 4 | **Confirmation** — the safety gate | Cheap to build, high design leverage | It's what lets you get away with an imperfect stage 2 |
| 5 | **Execution + reconciliation** | Easy call, neglected half | Reconciliation is the bit people skip and regret |

Stage 3 originally carried three sub-problems: the symbol is ambiguous ("hdfc" is three
companies), the quantity is usually unspoken, and the product type is implied by what you
mean. Enormous effort went into solving them acoustically.

**Then the problem was reframed rather than solved.** For options the trader is already
looking at a chain with a strike selected, so instrument, strike and quantity come from the
UI and voice carries only the action. All three sub-problems disappear at once — not
because the matching got better, but because the matching stopped being necessary.
`docs/02-flow.md` has the current model; `docs/archive/` has the work that was displaced.

The effort therefore moves to **stage 4**, which is where it should have been. Shrinking the
utterance concentrates risk: `short hdfc bank forty` has four tokens that must all parse and
usually fails safe, while a bare `buy` cannot fail to parse at all. The gate is what puts
that redundancy back. **The broker API remains the least interesting part of this project.**

## Single-client context

This is built for one trader, on one machine, against one short instrument table. That is
a *design advantage*, not a limitation, and should be exploited aggressively:

- The command vocabulary can be tuned to one person's speech habits and accent.
- The instrument table holds only names that person actually trades.
- Risk caps can be set to one person's real size rather than to a defensible average.
- There is no onboarding, no settings UI, no generality tax. Configuration is a YAML file
  the user edits in their editor.
- Failure telemetry has an n of 1, so it is actually readable end to end.

Anything that only makes sense for a second user is out of scope (`CLAUDE.md` rule 13).

## Prior art

### Commercially shipped (India)

- **Tradebulls Touch 2.0** markets voice-based order placement as a headline feature —
  search a stock and place orders by voice. So the concept is not exotic.
- **Angel One** told investors in 2023 it was building a conditional-order platform that
  translates a statement into an order via an LLM, and later rolled out an AI assistant that
  has absorbed a large volume of user interactions.

The direction of travel is clear. **Nobody has made voice the primary order-entry path.**

### Open source (thin)

- `marketcalls/openalgo-voice-based-orders` — the closest match. Flask, browser mic capture,
  Groq-hosted Whisper, activation words "MILO"/"MYLO", commands like `MILO buy 100 TCS`,
  silence detection to trigger the send. OpenAlgo has official docs for it. It goes from
  transcription **straight to order with no confirmation**.
- A Binance/Whisper equivalent exists for crypto.
- `rushabhhh/TradeGPT` — a different route entirely: MCP plus a desktop LLM client driving
  Zerodha's Kite API in natural language. The "LLM as the whole interface" approach, which
  this project explicitly rejects (`CLAUDE.md` rule 11).

**Honest summary:** several proofs of concept, no serious open implementation. Every one
found goes from transcript straight to order with **no confirmation step at all**, and
every one tries to resolve the symbol acoustically. This project does neither: the
confirmation is the centre of the design, and the symbol never enters the voice path. That
is the opening, and it is the whole of it.

> Verify the current state of these repos before borrowing from them; they were surveyed
> before this spec was written and are small and fast-moving.

## Where the real inspiration comes from — mostly not from trading

The useful prior art is in other industries that solved high-stakes voice command decades ago.

### Aviation readback / hearback

The closest analogue, with a century of accident data behind it. The controller issues a
clearance, the pilot reads it back, the controller confirms or corrects. Three things
transfer directly:

1. **Readback is mandatory and structured**, not optional and not free-form.
2. **The phonetic alphabet exists purely to make confusable items acoustically distinct** —
   exactly the "design your own vocabulary" move. Applied here to the verb set.
3. **The documented failure mode is expectation bias** — pilots read back what they expected
   to hear rather than what was said. This is the argument for reading back the *resolved
   order* rather than echoing the user's words. If you hear your own phrasing repeated,
   you'll confirm it whether or not the system understood you.

→ `docs/04-safety.md`

### Warehouse voice picking (Vocollect and similar)

The sleeper. Workers wear headsets, the system directs them to a bin, and the worker speaks
back a **check digit** printed on the shelf — a short arbitrary token that proves they are
physically at the right location. It's cheap and it's clever: you don't verify the whole
task, you verify one thing that can only be right if everything upstream was right.

→ Make the confirmation token itself disambiguating. Not "is this right?" but a word that
can only be produced by someone who knows what is about to happen. This became the
**qualifier**: `buy call` against a staged put is a rejection, never a silent put purchase.
See `docs/02-flow.md`.

### Medical dictation (Dragon Medical and descendants)

Where domain-specific ASR was actually solved at scale. The lesson is structural, not
acoustic: **dictation fills a template with required fields, and nothing enters the record
without explicit clinician sign-off.** Same shape as an order form with a commit step.

→ `OrderIntent` is a template with required fields (`CLAUDE.md` rule 6), and it is
fully specified or it does not exist.

### Open outcry pits

Interesting for the opposite reason. Traders used hand signals *alongside* voice, because a
single channel wasn't trustworthy in a noisy room. Palm-in for buy, palm-out for sell.

→ **Voice to compose, keypress to commit.** Two independent channels; an error in one cannot
complete a transaction alone.

### The Bloomberg terminal

The counterweight to the LLM instinct. Professionals overwhelmingly prefer a terse memorized
grammar to natural language, because it's fast, deterministic, and you develop muscle memory.

→ The command language should be closer to `AAPL US <Equity> GO` than to "hey, could you
sell some Reliance for me". `docs/02-flow.md` is written accordingly — 504 phrases, exact
lookup, no interpretation.
