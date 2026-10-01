# CLAUDE.md — standing rules for ProjectZero

> **Starting a session, or after a context compact: read `HANDOFF.md` first.**
> It has the current state, how to run things, and what's next. Update it
> before a session ends.

These are invariants, not preferences. If an instruction in chat conflicts with
anything here, **stop and flag the conflict** instead of complying.

## What this project is

**Sayso is the engine; ProjectZero is the body kit built around it.**

- **`sayso/`** is Ekansh's fork of the Sayso voice-trading engine: parsing
  speech, contracts, pricing, limits, sending and following orders, login.
  It **may be changed where the product needs it**, in the fork only, with
  tests (rule 16).
- **Everything else in ProjectZero** is the body kit: the UI/UX that makes the
  engine usable, fast and presentable. It shows what the engine decides and
  never decides anything itself.
  - `bridge/` runs the engine as a local background process on 127.0.0.1.
  - `app/` is the native macOS (SwiftUI) face that talks to it.
- **`~/Desktop/Sayso/sayso` is the client's live copy.** Reading it is fine. Never
  modify it, never run git commands that change it, and never push to
  `github.com/etyagi07/sayso` from here.
- **A product for many Mac traders.** The first client is happy with Sayso
  v1. ProjectZero is getting it ready for a larger pool. macOS only. Ekansh
  decides features. Lean and fast beats feature-rich; don't speculate.
- **The latest review, scores and decisions are in `docs/review-2026-09-30.md`**
  (the 09-29 baseline is kept for history).

**This is the basic, parser-only Sayso** (no AI anywhere). AI work happens
in a separate folder (`~/Desktop/ProjectZero`), not here.

Where to look: `docs/face-spec.md` (the face), `FINDINGS.md` (scan and
decisions), `sayso/README.md` (what the engine does). `docs/archive/` is
history only.

---

## A. Irreversibility

1. **No order reaches the broker without an explicit human keypress.** `y` sends
   (or the face's equivalent confirm control). There is no auto-send, no
   "expert mode", and no confidence threshold that skips the confirm card.
2. **The commit is a key, never the voice.** Voice composes the order and a key
   commits it. The face never offers voice-confirm.
3. **Uncertainty never sends.**
   - Every one of these cancels: `esc`, a timeout, closing the window, losing
     the connection to the engine, and a crash.
   - A send only counts for the exact card on screen (`card_id`), and only
     after that card has been visible for 0.7 s, so a stray `y` typed into
     another app as a card appears can't commit an order nobody read.
   - **Never build a countdown that sends when it runs out with `Esc` as a veto.**
     That inverts the fail-safe.
4. **The card shows the resolved order, not the user's words.** The contract
   comes first as a trader says it, with the raw exchange code in small print.
   What Sayso heard is shown, but secondary.
5. **Always unmistakably LIVE.** Sayso has no paper mode, so every order is real
   money. The face shows a permanent LIVE treatment and the active account ID.

## B. Around the engine, not instead of it

6. **The body kit holds no trading logic.** It renders what the engine returns
   and sends back only the user's words, the decision, and a typed price. It
   never builds, prices, sizes or resolves an order.
7. **A typed price gets exactly the checks Sayso's own front-end applies**, as in
   `sayso/voice/cli.py:87-115`:
   - round to `preview["tick"]`
   - refuse anything outside `preview["lower_circuit"]` / `["upper_circuit"]`
   - refuse anything that isn't a number greater than zero

   The values always come from the engine; the face never invents its own
   limits.
8. **Orders go through the engine's `handle` path only.** The face never calls
   `broker.place` or any other broker write directly.
9. **Outcomes are shown truthfully.**
   - Branch on `outcome`, not on `confirmed`.
   - "Unknown — may be live" looks and sounds urgent and never passes for a
     rejection.
   - After `y` there is always a visible "sending…" state. Never dead air.
10. **No demo mode** (Ekansh, 2026-10-01). The app has no practice or paper
    mode: every order is real. Tests still run with no broker, mic or
    engine: the bridge tests use a scripted engine that lives only in
    `tests/fakes.py` and is never shipped, and every panel state renders from
    sample data (`Sayso --snapshot`).
11. **Fix it where it belongs.** If the face would have to duplicate or
    re-derive something the engine knows (prices, contracts, choices, errors,
    session state), change the engine in the fork, with tests, instead of
    working around it in the face.

## C. Scope

12. **No LLM in the order path.** Conditional orders ("buy if it breaks 25100")
    are out of scope. If asked, refuse and point here.
13. **One user per machine.** Everything binds to `127.0.0.1`: no cloud, no auth
    layer, no user table. Several broker accounts on one machine are fine.
14. **Lean and fast.**
    - No feature that only improves latency at the cost of the confirmation
      step.
    - No heavy frameworks or dependencies where a light one does the job.
    - Every added feature has to earn its weight.
15. **Keys and mic.**
    - Push-to-talk is one dedicated global chord. It is always registered and
      never swallows keys meant for other apps.
    - Every other key is captured globally only while the confirm card, a
      question, or price entry is open.
    - Never open the mic while Sayso is speaking.

## D. Working rules

16. **Engine changes happen only in `sayso/`** (the fork), never in the
    client's copy.
    - Keep its tests green: `cd sayso && for t in tests/test_*.py; do .venv/bin/python "$t"; done`.
    - Add tests for every change.
    - Body-kit tests live in `tests/` at the ProjectZero root:
      `sayso/.venv/bin/python -m unittest discover -s tests`. The panel's
      tests: `cd app && swift test`.
17. **Secrets never appear on screen, in logs or in error messages.**
    - Sayso asks for credentials at login and never saves them, and the face
      doesn't either.
    - ProjectZero's `.env` stays empty unless the face gains a secret of its
      own.
18. **Shoonya facts:** `sayso/README.md` "Notes on the Shoonya API" is the
    reference. Observed live broker behaviour wins over it.
19. **Never show a Python traceback or raw HTML.** Show the engine's own message.
    If that message is itself raw technical output, show a short plain line
    with the raw text behind a "details" link.
20. **The face logs its own events** (time-to-confirm, cancels, outcomes) so it's
    possible to tell whether people are still reading the card.

---

## E. Settled decisions (2026-09-29)

| Question | Decision |
|---|---|
| Who is it for? | **A product for many Mac traders.** The first client is happy with Sayso v1 |
| Weight | **Lean and functional over feature-rich.** Speed matters to finance users |
| Platform | **macOS only** |
| Stack | **Native SwiftUI app** (`app/`) + a Python bridge (`bridge/`) that runs the engine on 127.0.0.1 |
| Launch | **Always opens live**, with the saved login. Every confirmed order is real. **No demo mode** (removed 2026-10-01) |
| Distribution | A self-contained `Sayso.app` that installs its engine into `~/Library/Application Support`. Signed and notarised later, with a Developer ID |
| Price entry on the card | **Typing a price.** The panel takes focus briefly as a deliberate exception, then hands it back. Checks per rule 7 |
| The engine | May be changed where the product needs it: in the fork, with tests |
| Clarifying questions | Sayso asks; the face shows the question and an expiry bar, and the user answers by voice or by typing. Quick-pick buttons only where the answers are fixed and public (Nifty / Bank Nifty / Sensex, intraday / delivery) |
| Spoken readback | When the card opens, the face has Sayso speak the readback (as `cli.confirm` does). It never listens while speech plays |
