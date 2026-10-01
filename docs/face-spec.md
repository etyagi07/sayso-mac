# Face spec — the body kit on the Sayso engine

The engine (`sayso/`) decides everything about orders. The face decides how
that looks, sounds and feels. The engine may be changed where the product needs
it (in the fork, with tests; `CLAUDE.md` rule 11). Lean and fast over
feature-rich; Ekansh decides what gets added.

> Updated 2026-10-01 to match what is built. Exact sizes live in
> `app/Sources/SaysoFace/Model.swift` (`Shape.size`); every state renders with
> `Sayso --snapshot DIR`.

Salvaged from the archived `04-safety`, `06-voice-and-ui` and `10-design-brief`,
and corrected to how Sayso actually behaves.

---

## The one constraint

**The trader is looking at the chart, not at this.** Everything must read in
peripheral vision or in a glance short enough not to break attention. When
two design choices conflict, this one wins.

**Pitch:** *Speak the order. Glance. Press y.* Nothing trades without your
say-so, and no audio leaves your machine.

## How the face sits on the engine

- Sayso runs as a **local background process on 127.0.0.1**. The face is a
  separate app that talks to it.
- The face is a **dumb renderer**. It shows what the engine sends and returns
  only the user's words, the decision, and a typed price. It never computes,
  prices, sizes or validates an order.
- Every state renders from sample data with no engine, no mic and no broker
  (`Sayso --snapshot`), and the bridge tests run on a scripted engine. There
  is no demo mode in the app.
- macOS only: a non-activating floating panel.

## Shapes

A shape change the system triggers is its loudest signal. It is spent on
exactly one meaning: **your eyes are needed now.** Content changes freely
within a shape; the footprint does not.

| Shape | Size | Shows |
|---|---|---|
| **Pill** | 320×46 | Idle. LIVE, account ID, a health dot (click: Setup & health), moon when the market is closed, "Wrong IP", "N resting", list button. |
| **Strip** | 420×78 | Listening (level meter), transcribing, sending (with the order), the result (with the contract). **Never resizes between these.** Order news always outranks any overlay below. |
| **Question** | 420×124 | A clarifying question, answered by voice, typing, or `1`–`3` for fixed quick-picks, with a 30 s expiry bar. |
| **Card** | 440×218 | The confirm card. |
| **Card, unusual** | 440×246 | The same card, taller, with an amber banner naming why. |
| **Alert** | 440×196 | "ORDER MAY BE LIVE": names the order, can check today's order book, hold to clear. |
| **Setup & health** | 460×330 | Speech model, mic, registered IP, Shoonya login, account checks, market hours, orders left today, version. First-run wizard. |
| **Pane** | 460 × 110–318, sized to its rows | Positions / today's orders / funds. A spoken account question ("what do I own") opens it. |
| **Limits** | 460×372 | This account's limits: lowered at once, raised only after "Are you sure?". |
| **Notice** | 440×236 | Once per Mac: real money, not advice. Nothing works until it's accepted. |
| **Login, command, mic set-up, disconnected** | see `Shape.size` | Typing shapes take focus briefly; disconnected says why. |

- **Growth direction** is derived: the panel grows away from the nearest
  screen corner. The anchored corner stays put, so BUY/SELL lands in the same
  physical spot every time.
- Transitions take ~120 ms.
- Persisted: the window position, and the Shoonya client and user IDs (never
  the secret).

## The confirm card

```
 BUY   NIFTY · 29 Sep · 23150 CALL          weekly
       1 lot × 65 = 65                       NRML
       at market ≈ 72.70   (bid 72.50 / ask 72.60)
       total  ₹4,725.50
       NIFTY29SEP26C23150
 ─────────────────────────────────────────────────
 y send · p set price · esc cancel
```

- **Side first and largest, spelled out.** Buy and sell colours must stay
  distinct for red-green colour blindness; never rely on hue alone.
- **The contract as a trader says it** is the headline. The raw exchange code
  is small and secondary, but always present.
- **Lots × units spelled out.** Lots above 1 are highlighted.
- **"At market" says what it is:** a limit priced through the spread, with
  bid and ask beside it.
- **Rupees with Indian grouping** (₹17,55,000). Never "rupees" in one place
  and ₹ in another.
- **Chips:** weekly / monthly / **EXPIRES TODAY** (loud), and the product.
- **Marked lines where they apply:**
  - strike adjusted ("23075 isn't listed, using 23100")
  - Bank Nifty is monthly only
  - at-the-money was chosen
  - on exit: entry / now / P&L
- **What Sayso heard** is shown small and secondary. The card shows the
  resolved order, not the user's words.
- **Unusual orders look different, not just say different things.** Border and
  proportion change for a large order (≥ ₹25,000 today), more than one lot, an
  exit, or a price the user typed. The card should be distinguishable from a
  plain one with the text unreadable.

**Variants to design:**
- plain option buy
- stock buy (company line, intraday/delivery)
- large order
- multi-lot
- exit with P&L
- user-typed price
- refused (selling options to open)
- resting / watching (up to 5 min)
- rejected by broker
- **unknown, may be live**

**The error card** ("ORDER MAY BE LIVE") covers unknown outcomes and a lost
connection with an order out. An expired session and an unregistered IP are
states of the pill ("Not logged in · Connect", "Wrong IP · Fix") instead. It does not auto-dismiss,
it looks wrong from across the room, and it needs a hold to clear.

## Keys, voice and focus

- **Push-to-talk** is one dedicated global chord. It is always registered and
  never swallows keys meant for other apps.
- **`y` sends, `p` types a price, `esc` cancels.** These keys are captured
  globally only while the card is open; every other key reaches your other
  apps. `y` counts only after the card has been on screen for 0.7 s, and
  lights up in the side's colour when it does.
- **Typing a price (`p`)**: the panel takes keyboard focus briefly, as a
  deliberate exception, and hands it straight back. The price is rounded to the
  engine's tick and checked against the engine's circuit limits, exactly as
  Sayso's own front-end does (`CLAUDE.md` rule 7).
- **Timeout, closing the window, or losing the engine all cancel.** Never build
  a countdown that sends when it runs out.
- **Sayso speaks the readback** when the card opens (the face's confirm handler
  triggers it) and speaks the outcome after. The face shows a speaking
  indicator and never opens the mic while speech is playing.

## Sound

Sayso's four sounds: filled, resting, rejected, other.

**"Unknown, may be live" needs its own urgent sound**, which the face plays
itself, since today Sayso uses the harmless one for it.

Silence while typing a price. No sound on a timeout, because a sound trains
you to wait for the sound.

## Always visible, never a chat log

- **LIVE**: a permanent white badge and border on every shape, including the
  idle pill. Red is kept for danger only.
- The account ID, the session state, and market open/closed.
- On demand, as panes rather than spoken sentences: positions with P&L, open
  orders, funds, and limits left today.
- Answers to account questions ("what do I own?") appear one at a time and
  never scroll into a history.

## Onboarding

One app and a first-run wizard: **mic check → registered IP → Connect Shoonya
→ health checks → ready.**

The login catches the broker's redirect itself, so there is no copying a code
out of a browser error page. There are no shell commands anywhere.

## Copy

- Show the engine's own messages. Never a Python traceback or raw HTML; if
  the message is raw technical output, show a short plain line with the raw
  text behind a "details" link.
- Always "Bank Nifty", never "BANKNIFTY".
- No roadmap words ("yet", "for now").
- Every refusal ends with **"Nothing was sent."** (or Sayso's own "nothing was done"). That's Sayso's best
  habit; keep it.

## Motion, colour, type

- Almost no motion: nothing idles, pulses or breathes. The level meter is the
  only continuous movement.
- Dark translucent surface.
- Tabular figures, so prices don't jitter as they change.
- Minimum ~13 px for side and contract, ~11 px for detail, readable at 70 cm
  off-axis.

## Acceptance tests

1. **The glance.** Eyes on the chart, a card appears in peripheral vision. You
   can tell that it appeared, whether it's a buy or a sell, whether it's
   unusual, and which contract it is. Four for four.
2. **The question.** Answer "Which index?" without looking away from the chart.
3. **Pass-through.** With no card open, every key (including Enter and `y`)
   still reaches the app you're typing in. Verify in a text editor.
4. **Never dead air.** After `y`, something visible changes within 100 ms.

## Fit

The window never grows to fit its content, so every shape's content must fit
its window. `FitTests` checks every snapshot state: content taller than its
shape fails the build's tests, rather than showing a cut-off card.
