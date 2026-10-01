# HANDOFF — start the next session here

**Say to the new session:** "Read `HANDOFF.md` and `CLAUDE.md` in
Sayso-Basic, then continue."

> **This is the basic, parser-only Sayso for Mac**, published as
> `github.com/etyagi07/sayso-mac`. `README.md` is for visitors;
> `docs/development.md` holds the developer notes. There is no AI here: that work happens in a
> separate local folder.

## What this is

**Sayso** is a voice-trading engine for Shoonya: Indian index options (Nifty,
Bank Nifty, Sensex) and Nifty 50 stocks. You speak the order, it reads it back,
and it is sent only when you press `y`. The first client is happy with Sayso v1
(a terminal program).

**ProjectZero** makes it a product for many Mac traders:
- a native macOS floating panel (`app/`);
- a Python bridge (`bridge/`);
- a self-contained packaged app.

The engine is Ekansh's fork in `sayso/`. It may be changed where the product
needs it, with tests. Ekansh decides the features. Keep it lean and fast.

`CLAUDE.md` holds the binding rules. The short version:
- nothing is sent without a keypress;
- anything uncertain cancels;
- no trading logic in the face;
- never touch `~/Desktop/Sayso/sayso` (the client's live copy).

## State (2026-09-30): live, real money

- This Mac is logged in, with the mic calibrated and the IP check passing.
- **Every `y` is a real order.** It has been proven end to end with real fills.
- **Voice:** Zoe (Premium), set in `sayso/config.json`. Ekansh picked it from
  samples; no Indian English Enhanced voice is installed.
- **Reviews:**
  - `docs/review-2026-09-29.md`: the baseline and phases 1–6.
  - `docs/review-2026-09-30.md`: four independent reviews (about 6/10), the
    decisions, and the progress on waves A–C.
- **Waves A (truth and safety), B (design) and C (support and docs) are done.**
  Wave D, signing and notarisation, waits for a Developer ID.

## Layout

| Path | What |
|---|---|
| `test.sh` | **Runs every suite** (engine, bridge, panel) and says pass or fail: `./test.sh` (about 2 minutes). |
| `sayso/` | The engine fork, with Python 3.13 in `.venv`. It has 16 test files (210 tests): `cd sayso && for t in tests/test_*.py; do .venv/bin/python "$t"; done`. They all run in a temp `SAYSO_HOME` and never touch live state. |
| `bridge/bridge.py` | Runs the engine on 127.0.0.1: on 8787 (also the Shoonya OAuth redirect). No demo mode. It drives `agent.handle(text, confirm)` and streams events over SSE. Its tests run on a scripted engine (`tests/fakes.py`, `tests/scripted_bridge.py`) that is never shipped. |
| `tests/test_bridge.py` | 65 bridge tests over real HTTP, including Sayso's real `voice.agent` and `voice.watch` with a stubbed broker: `sayso/.venv/bin/python -m unittest discover -s tests` (about 60 s). |
| `app/` | The SwiftUI panel. `./build.sh` builds `app/build/Sayso.app`, the **dev** build, which runs this checkout's engine with this Mac's state. `app/Tests`: 49 tests, run with `cd app && swift test`. `--snapshot DIR` renders every state to PNG, and `--icon FILE` renders the icon. |
| `app/package.sh` | Builds the **packaged** app into `app/build/dist/Sayso.app`. It installs itself into `~/Library/Application Support/Sayso`. See "Packaging" in `docs/development.md`. |
| `app/sign.sh`, `app/entitlements/` | Sign and notarise the packaged app: hardened runtime, and the embedded Python's entitlements. `DEVELOPER_ID=-` tests it ad hoc. |
| `logs/` | Dev-build logs. `bridge.log` holds the engine's output. `face.jsonl` holds, per command, the words heard, the decision (with card_id, symbol, quantity, price, ms), the outcome (tag, order_no) and fills. Logs rotate at 5 MB. |
| `docs/user-guide.md` | For traders: install, set-up, first order, screens, troubleshooting, uninstall. |
| `docs/face-spec.md` | The face design spec. `docs/archive/` is history only. |
| `FINDINGS.md` | The original scan and decisions log. Newer decisions are in `CLAUDE.md` §E and the review docs. |

## Keys

- **⌃⌥Space** starts talking. Sayso stops listening when you pause (0.9 s).
- **While a card is open:**
  - `y` sends. It lights in the side's colour once the card has been up for
    0.7 s.
  - `p` types a price.
  - `esc` cancels. The bar running out also cancels.
- **While a question has quick-picks:** `1`–`3` answer it.
- **At all other times** every key goes to your other apps.
- **Double-click the pill** to type a command.
- **Click the status dot** for Setup & health.
- **List button:** positions, orders, funds.
- **Right-click:**
  - Positions, Today's orders, Funds;
  - Setup & health;
  - Account (switch, or New account…);
  - Talk key (pick the push-to-talk chord);
  - Your limits…;
  - Copy diagnostics, Open logs folder;
  - Quit Sayso.

## Next up

0. **Demo mode is gone** (Ekansh, 2026-10-01; rule 10 amended).
   **Parser fixed from the real log** (`logs/face.jsonl`: 12 of 22 commands
   had failed, almost all parser strictness, not the mic): intraday
   misspellings, "buy a X", "Buy one." as an answer, index levels ("what is
   Nifty at?"), "is F&O enabled?", and "…no, buy two…" corrections. Engine
   tests added.
   **This folder is the basic, parser-only Sayso** (split off on 2026-10-01
   with a fresh git history). The AI-enabled version is developed separately
   in `~/Desktop/ProjectZero`.

1. **Signing and notarisation: prepared and tested ad hoc.** It needs only
   Ekansh's Developer ID.
   - To sign: `PYTHON_RUNTIME=app/build/runtime/python app/package.sh`, then
     `DEVELOPER_ID="Developer ID Application: … (TEAMID)"
     NOTARY_PROFILE=sayso app/sign.sh`. The script's header has the one-time
     notarytool set-up.
   - Then test on a clean Mac and user account, including the first-run
     model download.
   - Still open:
     - bundle the pinned speech model, or show its download;
     - an in-app uninstall (the user guide has the manual steps).
2. **Not verified on screen yet:**
   - whether hover tooltips show on the non-activating panel. "copy details"
     works regardless.

   The translucent panel was checked on screen on 2026-10-01 (in the since-removed demo), along
   with the card, banner and `y` key.
3. **Open questions for Ekansh** (review 09-30 §E):
   - SEBI and Shoonya vendor status;
   - the NorenRestApiOAuth licence;
   - a EULA, which should come from a lawyer;
   - an opt-in to keep the secret in the Keychain.

   Done: a first-run "real money, not advice" notice (once per
   Mac), and a factual privacy note in the user guide.
4. **Smaller items left from the reviews:**
   - CI: `.github/workflows/tests.yml` runs `./test.sh` on GitHub's macOS
     (Apple Silicon) runner on every push.

   Done on 2026-10-01 (later):
   - **Login:** a login that comes back for a different account than the
     User ID typed is refused and never saved. The login link now carries a
     one-time `state`; if Shoonya echoes it, a wrong one is refused. **Not yet
     checked against the real broker:** the next live login confirms that
     Shoonya accepts the extra `state` in the link.
   - **A frozen engine** (running, but silent for 30 s) is stopped and
     restarted. Tested by freezing the demo engine: replaced in 49 s.
   - **No rollback:** an older copy of the app refuses to install its older
     engine over a newer one, and says to open the newer Sayso.
   - **Speech model:** while it downloads (481 MB, once), the panel says so
     instead of "Loading…". The packaged app keeps it in its own folder
     (`HF_HOME` = `SAYSO_HOME/models`); the dev build keeps `~/.cache`.
   - **Focus:** after a typed price, a command or a Sayso alert, the
     keyboard goes back to the app that had it (unless the trader has moved
     to another app since). **Not checked on screen yet.**
   - **Five type sizes** (`Size` in `Views.swift`): 11, 13, 16, 20, 28.

   Done on 2026-10-01:
   - the speaking indicator ("reading back" on the card, a speaker on the
     strip);
   - panes sized to their content;
   - "New account…" in the Account menu;
   - `./test.sh`.

## Working notes

- **Git:** fresh history from 2026-10-01 (the old history, with a real
  account ID and IP in it, stays only in `~/Desktop/ProjectZero`). Never add
  the client's repo (`github.com/etyagi07/sayso`) as a remote. Commit after
  each working change. `07ee3cb` is the first live-proven state.
- Ekansh wants short answers, and multiple-choice questions for decisions.
  Don't over-engineer. Verify before claiming.
- **Testing UI safely:**
  - `app/build/Sayso.app/Contents/MacOS/Sayso --snapshot DIR`;
  - `sayso/.venv/bin/python tests/scripted_bridge.py --port <spare>` (the
    tests' scripted engine; nothing is sent). There is no demo mode in the
    app any more (Ekansh, 2026-10-01).
- **Never** send requests to 127.0.0.1:8787, or run the live app, without
  Ekansh asking.
- The dev build keeps the login in `sayso/.session.json`, a live broker token:
  never print it. The packaged build keeps it in
  `~/Library/Application Support/Sayso`.
- Reviewers and agents: read-only, a temp `SAYSO_HOME` for anything that
  imports the engine, and no network.

## Wave E done (2026-10-01): from the 10-01 re-review

Ekansh's decisions (also in `docs/review-2026-09-30.md`):
- Shoonya's connector is downloaded per Mac, never bundled.
- Limits: today's are the defaults; traders change their own, and raising
  asks "Are you sure?".
- Shorter spoken results with one alarm sound.
- No support contact yet.
- He tests Practice ↔ Live himself.

Built and tested:
- **Every shape fits its window,** enforced by `FitTests`. The card now has
  five rows, and snapshots are clipped like the real window.
- **Per-run secret token** between the panel and the engine
  (`logs/.token-<port>`, 0600). This shut out other processes and other
  users.
- **Never lost:**
  - `/shutdown` refuses while an order rests;
  - news under an alarm waits, unacknowledged;
  - raising an alarm cancels an open card;
  - "Check orders" looks up by order number;
  - fills are emitted before logging;
  - a failing watcher always says so;
  - no login lands mid-order.
- **Engine `reprice`:** a typed price updates the value, an exit's P&L and
  the flags, in the terminal too.
- **Per-account limits:** a screen (right-click → Your limits), a row in
  Setup, and the engine requires confirmation to raise any limit.
- **The connector:** pinned by sha256 and fetched by the installer on first
  launch. An offline install keeps the old engine. Tested for real from the
  package.
- **Talk key:** ⌃⌥Space / ⌃⇧Space / ⌃⌥⌘Space (right-click → Talk key). A
  Setup row explains the input-source clash.
- **Design:**
  - the exit arrow points at the sending price;
  - the timer is never red;
  - faint text at 0.45;
  - structured "Resting @" and "Part filled x/y";
  - a PRACTICE badge, and practice keeps the warning borders;
  - the disconnected state shows a spinner only while starting, and a Copy
    diagnostics button otherwise;
  - the login URL on its own line with a copy button;
  - the stock headline "10 RELIANCE";
  - the question hint in the header.
- **`sign.sh`:** stops on any codesign error, verifies every Mach-O, and
  prints the notary log on failure. The dist app was re-packaged, signed ad
  hoc, and installed in demo mode on 2026-10-01.
- **Docs:** the user guide (install, first 1-share order, sounds, limits,
  practice, accounts, privacy, no support contact), the spec, the READMEs,
  `.gitignore`.
- **Tests:** engine 203 in 16 files, bridge 62, panel 47; `./test.sh` passes.

**Next:**
- Done on screen by Ekansh (2026-10-01): limits (lower, raise with "Are
  you sure?", an order above the limit refused).
- Developer ID signing, then a clean-Mac test.
- The legal questions.
- This repo's history is fresh (2026-10-01): no real account ID or IP.
