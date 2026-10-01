> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 10 — Design brief and prototype prompt

Two things, both self-contained so they can be handed to a designer or a design tool with
no other context:

- **Part 1** — the brief: what it is, what it must do, what it must not become.
- **Part 2** — the prompt: paste this to generate an interactive prototype.

`docs/06-voice-and-ui.md` is the spec both derive from. Where this file and 06 disagree,
06 wins and this file is a bug.

---

# Part 1 — The brief

## What it is

A small floating panel for macOS that sits over a trading chart. The trader configures an
options contract in it by hand, arms it, then speaks a short command — "buy call" — to
place the order, and confirms with a keypress. It is not a window and not an app you
switch to; it lives on top of whatever else is on screen, all day.

**In one line:** set the trade up, keep watching the chart, speak the action, get
confirmation.

## The one constraint everything follows from

**The trader is looking at the chart, not at this.** Every piece of information has to be
readable in peripheral vision, or in a glance short enough not to break attention on the
chart. That single fact drives the anchoring, the restraint about motion, the type choices
and the countdown bar. When a design decision is in tension, this wins.

## Platform behaviour

- Frameless, always-on-top, translucent dark surface. No dock icon, no menu-bar item.
- **Never takes focus.** Clicking it must not deactivate the chart window behind it.
- Draggable; it remembers where it was put.
- Assume a dark desktop and a dark chart behind it.

## Four shapes

A **system-initiated** shape change is the interface's loudest signal, so it is spent on
exactly one meaning: *something needs your eyes now.* Content changes freely within a
shape; the footprint does not. Setup is the exception — the trader opened it themselves,
so it costs no signal.

**1 — Pill** (~200×36). Nothing armed. A mode label (`PAPER` / `LIVE`) and little else.
Should be genuinely easy to forget about.

**2 — Setup** (~340×260). Building or changing the contract. **Used constantly, not once**
— price moves, so the trader re-picks a strike many times a session. This is the surface
they touch most, and it needs no typing where a tap will do:

    ACTIVE INSTRUMENT

    Underlying   [ NIFTY          ]     search / autocomplete
    Expiry       [ 25 Sep ] 2 Oct  9 Oct    3-4 chips, nearest first
    Strike       ‹  23,400  ›               steppers, ±50 NIFTY / ±100 BANKNIFTY
                    spot 23,412 · ATM       always show spot, mark ATM
    Type         [ CE ]  PE                 unmistakably distinct
    Quantity     ‹  1 lot  ›  = 75          step in lots, show the share count
    Limit        [ 142.50 ]  LTP 142.50 ⟳   live price beside it, one tap to match

                        [  ARM  ]

A strike picker with no reference to spot makes the trader do arithmetic to know how far
out-of-the-money they are. Options need an explicit limit on every order, so matching LTP
must be one tap, not something typed under pressure.

**3 — Panel** (~340×88). Armed and waiting. What the trader sees for most of a session:

    ‹ NIFTY 23,400 CE › · 1 lot (75) · limit 142.50 · armed 12s   🎙

The chevrons matter: **strike steps up and down from here**, without opening setup. It is
the most frequent edit there is and it should not cost a panel. Any edit re-stamps the
timer.

"armed 12s" counts up and turns amber near 90s, after which the context goes stale and
must be re-armed. The mic glyph means *armed for push-to-talk*, not an open microphone.

Within this same footprint the panel also shows a level meter and live partial text while
listening, a shimmer while thinking, a spinner while sending, "confirming with broker"
while reconciling, and the fill result. **None of those resize it.**

**4 — Card** (~380×150). The confirmation, and the error state.

## The confirmation card

The system does not submit on recognition. It shows what it understood, and the trader
commits with a keypress — voice composes, a key commits, two independent channels so one
mishearing cannot complete a trade alone. A keypress costs no eye movement, which is why
it does not break the core promise.

    BUY   NIFTY 23,400 CE
    75 qty  (1 lot) · NRML
    limit 142.50
    premium      ₹10,687.50
    underlying   ₹17,55,000
    NIFTY25SEP2523400CE
    ▓▓▓▓▓▓▓▓▓▓░░░░░░   space to send · esc

- **`BUY` / `SELL` is the largest element and comes first.** Its error is the most
  expensive; the eye should land on it without being aimed.
- **Both money figures, always, never merged.** Premium is what leaves the account,
  underlying is the exposure; they differ by about 100×. Indian digit grouping —
  `₹17,55,000`, not `₹1,755,000`.
- Line six is the raw instrument code actually being sent. Small, secondary, present.
- Extra marked lines where needed: `quantity clamped from 150 · you are long 75`, a stale
  price warning, and so on. Marked, not merely appended.
- **Unusual orders must look different, not just say different things.** Bigger than usual
  size, closing a position, or writing an option: border and proportion shift enough to
  notice without reading a word.
- The bar is the timer: ~6s, depleting, colour shift in the last 1.5s. **No numeric
  countdown** — a shrinking bar reads peripherally, digits do not. Expiry cancels.

## Position and growth

Draggable, so **growth direction is derived, not fixed**: setup and the card expand *away*
from whichever screen corner the panel is nearest. Anchored bottom-right, they grow up and
left. The anchored corner stays put across all four shapes, so the `BUY`/`SELL` line lands
in the same physical spot every time. Transitions ~120ms.

## Motion

Almost none. No pulsing, breathing, idle animation or attention-seeking. It must be able
to sit still for an hour. The listening level meter is the only continuous movement, and
it is small.

## Colour and type

- Two colours for buy and sell that stay distinguishable to a red-green colour-blind
  viewer. Never hue alone — the word is spelled out and the position is fixed.
- `CE` and `PE` must also be visually distinct, in setup and on the panel.
- Tabular-figure numerals so prices do not jitter as they tick.
- Minimum ~13px for side and instrument, ~11px for detail. Readable at 70cm, off-axis.

## Paper vs live

Two modes, and **no state in which the trader could be unsure which one they are in**. Not
a small label — a different border treatment and accent across the whole surface, visible
even on the idle pill. Live should feel slightly uncomfortable. Arming live is a
deliberately awkward control: held 1.5s, placed away from everything else.

## The error state

When the system cannot confirm what actually happened to an order, the card shows the
discrepancy and **does not auto-dismiss**. It must look wrong from across the room, and
clearing it requires a hold, not a click.

## Explicitly not wanted

No chat transcript or history. No avatar, face or character. No suggestions, tips or
onboarding. No settings screen — configuration is a text file. Nothing that follows the
cursor. Nothing in the centre of the screen. No sound before the order is committed.

## The two tests

**The glance.** Look at the chart, trigger a card in peripheral vision, and tell without
moving your eyes: that it appeared, buy or sell, whether it is unusual, and which contract
is armed. Four for four.

**The re-arm.** Change strike by one step and re-arm in under two seconds without leaving
the panel. This one is about adoption rather than safety — if moving a strike is tedious
the trader stops doing it, and a perfect readback on an order they did not want helps
nobody.

---

# Part 2 — The prototype prompt

Paste as-is. The point is not a pretty picture of one state — it is something that can be
*stepped through*, over a dark chart, so both tests can actually be run.

> Build an interactive design prototype for a VOICE-FIRST TRADING INTERFACE. Single
> self-contained page. This is a DESIGN PROTOTYPE, not the real app — no microphone, no
> network, no broker. All data is fake and hardcoded, and every state is reachable from a
> control strip.
>
> **THE PRODUCT, IN ONE LINE.** Set the trade up. Keep watching the chart. Speak the
> action. Get confirmation.
>
> A trader configures an instrument visually, arms it, and then keeps their eyes on the
> chart. Short spoken commands — "buy call", "sell", "exit" — execute against that active
> context, so they never say "buy NIFTY 23,400 call 25 September quantity 75". They
> already set that up.
>
> **THE ONE CONSTRAINT EVERYTHING FOLLOWS FROM.** The trader is looking at the chart, not
> at this interface. Everything must be readable in peripheral vision, or in a glance too
> short to break attention. Where a design decision is in tension, this wins.
>
> **THE SCENE.** Fill the page with a convincing dark trading chart — candlesticks, price
> axis right, time axis bottom, a couple of indicator lines. It is a backdrop; it just
> needs to look plausible. The interface floats above it, draggable, and remembers where
> it is dropped.
>
> **FOUR SHAPES.**
> - PILL (~200×36) — nothing armed. Mode label only. Easy to forget about.
> - SETUP (~340×260) — building or changing the instrument. Opened by the trader,
>   dismissed on arming.
> - STRIP (~340×88) — armed. Also covers listening, thinking, sending, confirming with
>   broker, and the result. Content changes freely; THE FOOTPRINT DOES NOT.
> - CARD (~380×150) — the confirmation, and the error state.
>
> A SYSTEM-initiated shape change means exactly one thing: something needs your eyes now.
> That is why the strip never resizes through its five different contents. Setup is
> different — the trader opened it deliberately, so its expansion costs nothing.
>
> **SHAPE 1 — SETUP.** Design this properly; it is used constantly, not once. Price moves,
> so the trader re-picks a strike many times a session. This is the surface they touch
> most and it has to be fast, with no typing where a tap will do.
>
>     ACTIVE INSTRUMENT
>
>     Underlying   [ NIFTY          ]     ← search/autocomplete, "NIF" → NIFTY
>     Expiry       [ 25 Sep ] 2 Oct  9 Oct   ← 3–4 chips, one tap, nearest first
>     Strike       ‹  23,400  ›              ← steppers, ±50 NIFTY, ±100 BANKNIFTY
>                     spot 23,412 · ATM      ← ALWAYS show spot and mark the ATM strike
>     Type         [ CE ]  PE                ← unmistakably distinct, not a subtle toggle
>     Quantity     ‹  1 lot  ›  = 75         ← step in lots, always show the share count
>     Limit        [ 142.50 ]  LTP 142.50 ⟳  ← current price beside it, one tap to match
>
>                         [  ARM  ]
>
> A strike picker with no reference to spot is useless — the trader needs to see how far
> out-of-the-money they are without doing arithmetic. Show spot, mark ATM. A limit price
> is required on every order (these are options; there is no market order), so make
> matching LTP a single tap rather than something to type under pressure. ARM is
> deliberate: it is the moment the context goes live and voice starts meaning something.
>
> **SHAPE 2 — ARMED STRIP.** Collapses to a compact bar that stays visible the entire time:
>
>     ‹ NIFTY 23,400 CE › · 1 lot (75) · limit 142.50 · armed 12s   🎙
>
> THE ACTIVE CONTEXT IS NEVER HIDDEN WHILE ARMED. The trader must never have to remember
> what the next spoken word will act on.
>
> Note the chevrons: strike steps up and down FROM THE STRIP, without opening setup. It is
> the most frequent edit there is and it should not cost a panel. Any edit resets the
> "armed" timer.
>
> "armed 12s" counts up and turns amber approaching 90 seconds, after which the context
> goes stale and must be re-armed. The mic glyph means ARMED — ready to accept a held
> hotkey — not an open microphone. Show that distinction; a hot mic that can place trades
> is not this.
>
> Within this same footprint, also show: a level meter with live partial text while
> listening, a shimmer while thinking, a spinner while sending, "confirming with broker"
> while reconciling, and the fill result. None of these resize it.
>
> **SHAPE 3 — THE CONFIRMATION.** The heart of it. The system does NOT submit on
> recognition. It shows what it understood, and the trader confirms with a keypress. Voice
> composes; a key commits — two independent channels, so one mishearing cannot complete a
> trade alone. A keypress costs no eye movement, which is why it does not break the core
> promise.
>
>     BUY   NIFTY 23,400 CE
>     75 qty  (1 lot) · NRML
>     limit 142.50
>     premium      ₹10,687.50
>     underlying   ₹17,55,000
>     NIFTY25SEP2523400CE
>     ▓▓▓▓▓▓▓▓▓▓░░░░░░   space to send · esc
>
> BUY/SELL is the largest element and comes first — the field whose error is most
> expensive. Both money figures always appear and are never merged: premium is what leaves
> the account, underlying is the exposure, and they differ by ~100×. Indian digit grouping
> (₹17,55,000, not ₹1,755,000). Line six is the raw instrument code actually being sent —
> small, secondary, present. The bar runs ~6s and shifts colour in the last 1.5s. NO
> numeric countdown — a shrinking bar reads peripherally, digits do not. If it runs out the
> order is CANCELLED, never sent.
>
> **SHAPE 4 — EXECUTION FEEDBACK** (back inside the strip footprint). Only after the broker
> confirms — never on recognition, never on submission:
>
>     BUY EXECUTED · NIFTY 23,400 CE · 75 @ ₹142.50
>
> Plus a spoken line: "Bought 75 Nifty 23,400 call at 142.50." Audio is reserved for things
> that have actually happened; nothing makes a sound before the commit.
>
> **COMMANDS TO REPRESENT.**
> - BUY CALL / BUY PUT — open or add. The "call"/"put" is checked against what is armed —
>   say "call" against an armed PE and it rejects rather than trading the other leg.
> - SELL CALL / SELL PUT — sell or reduce; never flips a long straight into a short.
> - EXIT — close the position in the armed instrument, quantity from the book.
> - EXIT ALL — a KEY, not a phrase. Closing everything on one mishearable syllable is
>   unrecoverable, and it must work when the speech layer is what is broken. A deliberately
>   awkward held control, away from everything else.
>
> **BUILD THESE CARD VARIANTS** — they are where designs fall over:
> - plain buy (above)
> - CLAMPED SELL — extra marked line: "quantity clamped from 150 · you are long 75"
> - EXIT — quantity came from the position, not setup: "quantity full position (+150)"
> - HIGH-EXPOSURE — requires hold-to-commit; show a fill ring on the key hint
> - STALE PRICE warning line
> - REJECTED — "heard PUT, NIFTY 23,400 CE is armed"
> - ERROR STATE — the system cannot confirm what happened to an order. Shows the
>   discrepancy, does NOT auto-dismiss, needs a hold to clear. Should look wrong from
>   across the room.
>
> Unusual orders must LOOK different, not merely say different things. Clamped, exit and
> high-exposure cards should be distinguishable from the plain one by border and proportion
> alone, with the text unreadable.
>
> **POSITION AND GROWTH.** Draggable, so growth direction is DERIVED, not fixed: it expands
> away from whichever screen corner it is nearest. Pinned bottom-right, setup and the card
> grow up and left. The anchored corner stays put across all shapes, so the BUY/SELL line
> lands in the same physical spot every time. Transitions ~120ms.
>
> **MOTION: ALMOST NONE.** No pulsing, breathing, idle animation or attention-seeking. It
> must be able to sit still for an hour. The listening level meter is the only continuous
> movement, and it is small.
>
> **COLOUR AND TYPE.** Two colours for buy and sell that stay distinguishable to a
> red-green colour-blind viewer — never hue alone; the word is always spelled out and the
> position is fixed. CE and PE must also be visually distinct, in setup and on the strip.
> Tabular-figure numerals so prices do not jitter as they tick. Minimum ~13px for side and
> instrument, ~11px for detail; assume the viewer is 70cm away and not looking directly at
> it.
>
> **PAPER VS LIVE.** Two modes, with no state in which the trader could be unsure which
> they are in — not a small label, but a different border treatment and accent across the
> whole surface, visible even on the idle pill. Live should feel slightly uncomfortable.
>
> **DO NOT ADD.** A chat transcript or history, an avatar or character, suggestions, tips,
> onboarding, a settings screen, anything that follows the cursor, anything in the centre
> of the screen, or any sound before the commit.
>
> **CONTROLS.** A small strip, clearly outside the design, stepping through every shape,
> state and variant and toggling paper/live. It is scaffolding — style it as such; it must
> never read as part of the interface.
>
> **THE TEST THIS HAS TO PASS.** Two tests, both required.
> 1. THE GLANCE — look at the chart, trigger a confirmation in peripheral vision, and tell
>    without moving your eyes: that it appeared, buy or sell, whether it is unusual, and
>    which contract is armed. Four for four.
> 2. THE RE-ARM — change strike by one step and re-arm in under two seconds, without
>    leaving the strip. If that is slow the trader stops moving strikes, and the whole
>    thing gets used less.
