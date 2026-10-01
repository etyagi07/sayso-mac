> **Not a plan — ideas only (archived 2026-09-29).** The engine is used as it is.
> Raise these only if the client asks for them. See `CLAUDE.md` rule 11.

# Engine roadmap — changes to the Sayso fork so the body kit never re-derives engine logic

**Status: plan only. Nothing here is built.** `sayso/` is still byte-identical
to the client's copy at `fe492a5`.

**Rules for every item:**
- Work in `ProjectZero/sayso/` (the fork) only. Never touch `~/Desktop/sayso`.
- Keep all 158 existing tests green, and add tests for each change.
  (Run them with `for t in tests/test_*.py; do python "$t"; done`, as CI does.)
- The engine returns **data**, never wording the face has to parse. `speak`
  strings stay for Sayso's own terminal front-end.

---

## Phase 1 — safety. Before any face exists

**E1. Price checks inside the engine.**
- Today tick rounding, circuit limits and `> 0` live only in
  `voice/cli.py:87-115`, and `agent.py` sends whatever `preview["price"]` the
  UI leaves behind. The option-exit path re-checks nothing.
- Change: after `confirm` returns, validate the price on all three paths
  (equity, option buy, option exit) and reject with a clear reason if it fails.
- *Face needs:* to send a typed number and trust the answer.

**E2. A confirm timeout that cancels.**
- Today `input()` waits forever.
- Change: the engine owns the deadline. Expiry means cancel, never send.
- *Face needs:* a countdown that mirrors a real deadline.

## Phase 2 — let a face connect

**E3. A local host on 127.0.0.1.**
- Run Sayso as a background process that exposes `handle` plus the read-only
  helpers (positions, funds, order book, limits, network, session).
- Confirm crosses the wire as `preview → {decision, price}` rather than a dict
  edited in place.
- A disconnect or timeout means False.
- One `handle` at a time, because `_pending` is module-global.
- *Face needs:* the whole architecture.

**E4. Stage events from inside `handle`.** Emit resolving → awaiting confirm →
sending → waiting for exchange → outcome. *Face needs:* no dead air after `y`.

**E5. Order lifecycle as events.** `watch.follow` only prints today; emit
fill, partial, rejected and still-resting as data. *Face needs:* an activity
panel and correct sounds.

**E6. Questions as data.** Return `choices` and `expires_at` with
`needs_answer`. Today the choices exist only inside the spoken sentence, and
the 30 s window is a private constant. *Face needs:* tappable choices and an
expiry bar.

**E7. Structured errors.** Return `error_code`, `plain` and `raw` separately.
Today raw broker, HTTP and HTML text is written into `speak`. *Face needs:*
plain copy with a "details" link.

**E8. A display block on every preview**, including exits:
- display name
- call or put
- weekly, monthly, or expires today
- strike-adjusted note
- product

Today an exit carries only the raw exchange code, and the strike-adjusted note
is never shown. *Face needs:* the human headline and the chips.

**E9. A structured order log.** One JSONL line per stage of every command:
heard, resolved, previewed, decision, sent, outcome. It's the only way to
answer "why did it do that".

## Phase 3 — ship it

**E10. Login and session API, with no `input()` or `SystemExit`:**
- `login.begin() → url`
- a 127.0.0.1 redirect listener
- `login.complete(code)`
- `logout()`
- `session_status()`

*Face needs:* a "Connect Shoonya" button and in-app re-login when the session
expires.

**E11. Health checks as data.** `doctor.run() → [ {name, ok, detail, fix} ]`.
Today it only prints, and its results list is never cleared. *Face needs:* the
onboarding checklist.

**E12. Mic events and calibration without `input()`.** A level callback,
recording start/stop events, and calibration as a function. *Face needs:* a
level meter and a mic step in the wizard.

**E13. Per-user app-data paths.** Config, session, limits and symbol masters
are written next to the source today, which breaks inside a signed `.app`.
Change: move them to `~/Library/Application Support/Sayso` on macOS and
`%APPDATA%` on Windows. *Face needs:* a signed installer.

**E14. Pinned dependencies and model.** Pin `faster-whisper`, pin the Whisper
model revision, and decide whether to bundle or download the 481 MB model.
*Face needs:* reproducible builds.

## Phase 4 — product

**E15. Paper mode.** A paper broker behind the same interface as
`shoonya/broker.py`: accept, reject, partial fill, lost reply. *Face needs:* a
safe demo mode and a way to test without real money. The face must make it
look completely different from LIVE.
