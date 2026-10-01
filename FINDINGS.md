# Full scan — Sayso as backbone, ProjectZero as face

> **Read this first.** Sections 1–7 are the scan as it stood on 2026-09-28,
> *before* the decisions in §8 and the reconciliation cleanup on 2026-09-29.
> Where they say work around an engine gap "in the face" (§2 adapters,
> §3.1, §7-P2), that is **superseded**: the rule now is that engine gaps are
> fixed in the engine (`CLAUDE.md` rule 11; the old roadmap is now
> `docs/archive/engine-ideas.md`). The §7 cleanup items are done; see §9.
>
> **Also superseded (2026-09-29/30):** "client-only", "engine used as it is"
> and "Windows next". It is now a product for many Mac traders, the engine may
> change in the fork with tests, and it is macOS only. The current decisions
> are in `CLAUDE.md` §E and `docs/review-2026-09-30.md`.


Four read-only agents scanned everything under `ProjectZero/` on 2026-09-28:
the engine interface, the current UX, the design docs, and folder hygiene plus
ship-readiness. Nothing was changed, and the original `~/Desktop/sayso` was not touched.

---

## 1. Bottom line

- **The backbone is ready to have a face put on it without changing its logic.**
  There is one clean entry point, `voice.agent.handle(transcript, confirm=callback)`,
  and it returns plain dicts. `agent.py` and `broker.py` contain no `print`.
- **What stops it being a product is almost all surface**: terminal onboarding,
  raw broker codes, dead air after `y`, errors spoken verbatim, and no persistent
  context such as positions, session, LIVE badge or limits.
- **About 70% of ProjectZero's UI thinking carries over.** The staged-model parts
  do not.
- **ProjectZero's `CLAUDE.md` currently contradicts the new direction** and will
  push back on Sayso-faithful work in every future session until it is rewritten.

---

## 2. The seam between face and backbone

**Use as-is:**
- `agent.handle(transcript, confirm)`
- `broker.positions()`, `funds()`, `order_book()`, `wait_for_outcome(order_no, timeout=0)`
- `safety.status()`
- `network.check()` / `registered()` / `save()`
- `client.session_user()`
- `speak.say` / `sound` / `announce` / `interrupt` / `listening`
- `listen.warm_up()` / `transcribe()`

**Thin adapters, written in the face, never in Sayso:**

1. **Confirm bridge.** Calls `handle()` on one worker thread, serialised because
   `_pending` is a module global. `confirm(preview)` posts the card to the UI,
   speaks `preview["say"]`, blocks until the user decides, calls
   `speak.interrupt()`, and returns a bool. **On window close, disconnect or
   timeout it returns False.**
2. **Result dispatcher.** Branches on `outcome` first, then `preview`, then
   `needs_answer`, `needs_clarification` and `blocked`. Do not trust
   `confirmed`, which is missing on several post-`y` outcomes.
3. **Question mirror.** Starts a 30 s countdown on `needs_answer`. Buttons send
   the answer word as a transcript. The choices only exist inside the spoken
   text, so derive them from `underlyings` and `positions()`.
4. **Fill poller.** Replaces `watch.follow`, which only prints, by polling
   `wait_for_outcome(…, timeout=0)` and emitting events.
5. **Recorder.** Reimplements `record_until_silence` to emit mic-level events,
   using the same `speak.listening()` guard.
6. **Login flow.** Rebuilt as a GUI over `getOAuthURL`, a local 127.0.0.1:8787
   listener that catches the redirect, `_exchange` and `_write_private`.
   `credentials.py` and `client.login_interactive` are `input()`-based and
   raise `SystemExit`.
7. **Health checks.** Re-run each check individually, because `doctor.main()`
   only prints and never clears its global results list.
8. **Logout and account switch.** Both need a process restart, because paths
   are frozen at import. There is no logout function.

**Events the face can't get today:** stages inside `handle()`, mic level,
speaking started and finished, session expiry pushed to the UI, question
expiry, live quotes and P&L (everything must be polled).

---

## 3. Safety items the face must carry

These don't go away when the terminal does.

1. **Price-edit checks live only in the terminal UI** (`cli.py:87-115`: tick
   rounding and circuit limits). The engine sends whatever `preview["price"]`
   the UI writes, and an option exit is never rechecked. **Any face that
   allows price editing must copy these checks.** This is the single most
   important finding.
2. **`y` commits; everything else cancels; a timeout cancels.** Never build an
   auto-send countdown with Esc to veto it.
3. **The "unknown, may be live" outcome must look and sound urgent.** Today it
   shares the harmless Pop sound with an ordinary refusal.
4. **Global key capture only while the card is open.** The keys are `y` and `p`,
   and Enter for push-to-talk. Capturing Enter globally at all times would eat
   it in every other app.
5. **Never open the mic while Sayso is speaking.** Reuse `speak.listening()`.
6. **Show a permanent LIVE badge and the account ID.** Every order is real money.

---

## 4. UX fixes, ranked by harm to a first-time paying user

1. **Onboarding is four shell commands.** Replace with one app and a first-run
   wizard: mic → IP → login → checks → ready.
2. **Daily login is a raw-secret paste plus a URL copied from a browser error
   page.** Replace with a local redirect listener and an optional OS keychain.
3. **The card headline is `NIFTY29SEP26C23150`.** Use the human name, e.g.
   "NIFTY · 29 Sep · 23150 CALL". `friendly()` already exists; keep the raw
   code in small print.
4. **Up to 10 s of dead air after `y`.** Show a "Sending… / waiting for
   exchange" state.
5. **Raw errors are shown and spoken**, e.g. `HTTP 502 '<html>…'`, urllib3
   reprs, `Session Expired`. Map them to plain sentences and put the raw text
   behind a "details" link.
6. **Python exceptions reach the user**, e.g. `error: KeyError: 'lp'`. Show a
   friendly error panel with a "copy diagnostics" button.
7. **A session expiring mid-day is misreported** as "couldn't reach the
   broker". Show a session banner with in-app re-login.
8. **No LIVE badge and no account badge.**
9. **Fill announcements print over the prompt, and quitting silently abandons
   resting orders.** Add an activity panel and warn on quit.
10. **Positions, orders and funds exist only as one spoken sentence.** Give
    them persistent panes.
11. **The card is missing key facts:** weekly/monthly/**expires today**, spot
    and distance from it, product, the strike-adjusted notice (which is never
    shown or heard today), and that "at market" means a limit two ticks
    through the spread.
12. **Price edit is fragile.** Pressing Enter on an empty field cancels the
    order. Use an inline field with ± tick buttons and show the circuit range.
13. **Copy is inconsistent:** ₹ vs "rupees", missing digit grouping, BANKNIFTY
    vs Bank Nifty, "Cancelled." vs "OK, nothing done.", and roadmap words like
    "yet" and "for now".
14. **Startup noise:** HuggingFace progress bars, `mlx:small.en`,
    `threshold 0.0269`, and "LISTENING" shown in text mode.
15. **Recording state is text-only.** Add a level meter and a start/stop
    sound.

**Preserve exactly:**
- `y` / any-key-cancels
- prices are changed on screen, not by voice
- the arithmetic is spelled out, e.g. `2 lots × 65 = 130`
- entry, now and P&L shown on exit
- the short spoken readback
- only four sounds
- truthful outcomes: filled / partial / resting / rejected / unknown
- asking instead of guessing
- "I haven't done anything" on every refusal
- limits never block exits
- the IP pre-flight check

---

## 5. What to take from ProjectZero's design docs

**Keep:**
- the one constraint (the trader is looking at the chart)
- the glance test
- a shape change reserved for "eyes needed now"
- the card layout (side first and largest)
- unusual orders look different
- the error card that doesn't auto-dismiss
- growth direction derived from the anchored corner
- near-zero motion
- colour-blind-safe colours and tabular figures
- a non-activating panel
- a dumb renderer fed a state stream
- the "disconnected" pill
- time-to-`y` fatigue telemetry

**Adapt:**
- **Shapes** become: Pill (idle, LIVE, account) · Strip (listening, speaking,
  sending, watching, result) · **Question** (new) · Card (confirm or error).
- **Paper/live** becomes always LIVE.
- **The countdown bar** appears only once a confirm timeout actually exists.
- **The prototype prompt** in `docs/10` Part 2 is a strong structure. It needs:
  - Setup and the armed strip deleted
  - Question and speaking states added
  - `y`/`p` keys
  - Sayso's real facts: lot 65, `NIFTY29SEP26C23100`, Bank Nifty monthly
    only, Sensex on BFO
  - card variants for stock, large order, multi-lot, exit with P&L,
    price-set-with-`p`, "refused: selling to open", resting, and unknown

**Discard:** the setup panel, arming, qualifiers, the 504-phrase vocabulary,
silence before commit, "reject, never ask", paper mode, and explicit limits on
options.

**One real design tension:** `p` needs typed input, but the panel is meant to
never take focus. Pick one: take focus briefly for price entry, or use ± tick
buttons and global keys.

---

## 6. Blockers to shipping a signed Windows/macOS app

1. **Sayso writes its state next to its own source files:** config, session,
   limits and symbol masters. That breaks inside a signed `.app` or under
   Program Files. The face would have to run Sayso from a writable copy; true
   app-data paths need a change in Sayso itself.
2. **Terminal-only input throughout.** This is covered by the adapters in §2.
3. **It needs a system Python 3.12 plus a venv.** A shipped app needs a frozen
   runtime (PyInstaller, Briefcase or an embedded Python).
4. **Native libraries must be bundled and signed**: PortAudio, mlx or
   ctranslate2. macOS also needs notarisation and a microphone entitlement.
5. **A 481 MB Whisper model downloads on first run, unpinned.** Bundle it, or
   pin the revision.
6. **Two speech stacks:** Apple Silicon uses mlx, everything else uses
   faster-whisper, which is itself unpinned. That means two build matrices.
7. **Shelling out to PowerShell for speech** tends to trip Windows antivirus.
8. **The redistribution licence of `NorenRestApiOAuth` is unverified.**

Tests: 158 offline tests, no broker needed, CI on Ubuntu. `cli`, `listen`,
`doctor`, `fuzzy` and `numbers` only have smoke-test coverage.

---

## 7. Risks and cleanup (proposed, not done)

**P0: secrets and the client**
- `ProjectZero/.env` still holds your trading password and TOTP seed. Sayso
  needs neither, and ProjectZero isn't a git repo, so `.gitignore` protects
  nothing. Clear both values.
- `probe/` can place live orders and prints TOTP codes. Delete it.
- **`sayso/.git` (the copy) still contains the branch
  `backup/before-ip-scrub` and `refs/original/*`**, which hold real ISP IP
  addresses, plus a `FETCH_HEAD` naming the client repo. There is no remote, so
  it can't push, but zipping or mirroring it would expose them. Either delete
  the copy's `.git` entirely (it's a reference snapshot) or prune those refs.
- `sayso/.daily_limits.json` is the client's counters for the day. Delete it
  from the copy.
- Screenshots in `sayso/docs/` show a real account's positions and MTM.
  Review them before using any in marketing.

**P1: stop the docs misleading future sessions**
- **Rewrite `CLAUDE.md`.**
  - Rules 5, 12, 21 and 22, and section E rows 2–3, directly contradict Sayso
    (paper-first, voice never selects instruments, staged parameters, "reject,
    never ask").
  - Keep rules 1–4, 7–11, 13–14 and 18–20 as UI rules.
  - Add a rule that the face mirrors the price-edit checks.
- Rewrite `README.md`, with `RECONCILIATION.md` and `FINDINGS.md` as the entry
  points.
- **Archive:** `docs/00`, `02`, `03`, `05`, `07`, `08`, `09`,
  `broker-notes.md`, `core/`, `config/*`, `tests/fixtures/*`, and the old
  `.gitignore`.
- **Salvage `docs/04`, `06` and `10` into a new face spec first.**
- Delete `__pycache__/` and `.DS_Store` files.

**P2: things the face works around, not changes, in Sayso**
- import-time state paths
- `input()` flows
- module-global state (one engine per process)
- no confirm timeout (the face times out its own confirm, and a timeout
  cancels)
- no paper mode (a paper broker would be a new module beside `broker.py`)
- hard limits live in code (the face can only display them)

---

## 8. Decisions (answered 2026-09-29)

1. **Rewrite `CLAUDE.md` around Sayso?** Needed before building anything, or it
   will keep blocking the work.
2. **Who is the product for?** This client only, or other traders too? That
   decides how much installer, onboarding and branding is worth doing.
3. **Windows first?** The client runs Windows 11.
4. **How the face runs Sayso:** as a local backend process the UI talks to, or
   bundled in one app?
5. **Price entry:** take focus briefly, or tick buttons only?
6. **Engine gaps the face can't fix alone:** a confirm timeout, app-data paths
   and a paper mode each need a Sayso change. Would that be in *your* version
   of Sayso, never the client's?
7. **Delete `sayso/.git` from the copy?**

**Answers:**

1. `CLAUDE.md` rewritten around Sayso. The old version is at
   `docs/archive/CLAUDE-staged-model.md`.
2. This client first, built so it can become a product later.
3. **macOS first**, then Windows.
4. Sayso runs as a local background process; the face is a separate UI.
5. **Typed price entry.** The panel takes focus briefly, as a deliberate
   exception.
6. Engine gaps get fixed in the fork (`sayso/`), never in the client's copy.
7. The copy's `.git` is deleted. Also done: `SHOONYA_PASSWORD` and
   `SHOONYA_TOTP_SECRET` are cleared from `.env` and removed from the template.

**Still open from §7:**
- ~~delete `probe/`~~: done. (An earlier version of this line said it could
  no longer log in. That was wrong: it still could, and could place live orders.)
- delete `sayso/.daily_limits.json` (the client's counters)
- archive the staged-model docs and code
- rewrite `README.md`

## 9. Reconciliation cleanup (2026-09-29)

A verification agent found the project **not reconciled**. The fixes:

**Deleted:**
- `probe/`, which could still log in and place live orders
- `config/secrets.example.env`, which held the real IP and account ID
- the client's runtime state in the fork (`.daily_limits.json`, `config.json`)
- all `.DS_Store` and `__pycache__`

**Cleared:** every value in `.env`. It is now a comment-only stub, because the
body kit needs no credentials.

**Archived, each with a SUPERSEDED banner:**
- all 11 numbered docs and `broker-notes.md`
- `core/intent.py`
- `config/*.yaml`
- `tests/fixtures/*`

The archive index was rewritten.

**Rewritten:**
- `CLAUDE.md`: engine logic can never live in the face; the tie-break in
  rule 11; price checks belong to the engine only (rule 7); a push-to-talk
  chord; the engine JSONL log
- `README.md`
- `.gitignore`

**New:**
- `docs/face-spec.md`, salvaged from the old `04`/`06`/`10` and corrected to
  how Sayso behaves
- `ENGINE-ROADMAP.md`, items E1–E15, plan only

**Still for Ekansh:** regenerate the API secret code on the Shoonya API key
page, since it sat in plain text in `.env`.

## 10. Direction change (2026-09-29, later)

**Build the body kit around the engine as it is.** No engine wishlist; the
client decides features; lean and fast over bulky.

- `ENGINE-ROADMAP.md` moved to `docs/archive/engine-ideas.md` as an ideas list
  only.
- `CLAUDE.md` rewritten to match.
- Stack: a native SwiftUI app plus a Python bridge, wired to the fork.
