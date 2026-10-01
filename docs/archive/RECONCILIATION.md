# ProjectZero ↔ Sayso — reconciliation

`sayso/` in this folder started as a copy of `~/Desktop/sayso` at commit
`fe492a5` and is now **Ekansh's own fork**, the engine the face runs on (decided
2026-09-29). The original is the client's live copy and is never modified from
here. The fork has no `.git` (deleted, since the old history contained real IP
addresses); `.session.json` (a live broker token) and `.venv` were never copied.

**Superseded in part:** this doc was written before the decision that
ProjectZero is the UI/UX face only. For the current picture read `FINDINGS.md`
and `CLAUDE.md`.

## The short version

Sayso is ProjectZero's *original* idea, built, shaped by people who trade on
Shoonya, and proven with live fills. **Sayso is the base.** ProjectZero's
documents are a checklist to mine, not a spec to follow.

---

## 1. Where they already agree

Sayso reached these independently, most of them with a live incident behind
them:

| Idea | ProjectZero | Sayso |
|---|---|---|
| Nothing sends without a keypress | rule 1–2 | `y` sends; **anything else cancels** |
| Read back the resolved order | rule 4 | contract, lots × units, value, bid/ask |
| Unique tag per order, recover by tag | rule 8 | `remarks: sayso-<uuid>`; lost reply → search book by tag **only** |
| Uncertain ≠ rejected | rule 3 | `UNKNOWN` is its own outcome, never reported as a refusal |
| Follow the order to a final state | rule 9, layer 1 | `wait_for_outcome`, polls the order book |
| No market orders | rule 7 | only `LMT`; "at market" = limit through the touch |
| Hard limits in code, fail-closed | `risk.py` | `safety.py`; daily counters survive restarts |
| Ask, don't guess, on ambiguity | archived resolution doc | "hdfc" → bank or life?; two positions → which? |
| Only known mishearings are corrected | `asr_corrections` | `fuzzy.py` — explicit lists, no "close enough" |
| No reversal in one command | rule 22 | stronger: **selling options to open is refused outright** |
| Doesn't hear itself | silent pre-commit | speaks, but never listens while speaking |
| Read symbols from the master, never build them | known gap | done |

Sayso also has lessons ProjectZero never had: matching a lost order by
symbol+side+size claimed an *older* identical order; the SDK has no network
timeouts; "session expired" and "no data" look identical; the quote endpoint
sometimes answers for the wrong instrument. See `sayso/README.md`, "Notes on
the Shoonya API".

## 2. Where ProjectZero was wrong

Sayso's live evidence overrules these:

| ProjectZero believed | Reality |
|---|---|
| OAuth is a dead end; use QuickAuth with password + TOTP | OAuth works: `getAccessToken(authcode, secret_code, client_id, uid)` in a newer SDK |
| Option symbol like `NIFTY24SEP2625000CE` | `NIFTY29SEP26C23100`; SENSEX is on `BFO` in two different layouts |
| NIFTY lot = 75 | 65 |
| The UI should hold the contract; voice says only "buy call" | Unproven. Sayso's whole-order voice is proven live and guided by traders |

**Action for you (done 2026-09-29):** `ProjectZero/.env` holds your trading password and TOTP
seed because of that wrong conclusion. Sayso needs neither. Clear
`SHOONYA_PASSWORD` and `SHOONYA_TOTP_SECRET`. `ProjectZero/probe/` is also
obsolete.

## 3. What ProjectZero adds that Sayso lacks

In order of value. None of these have been changed in Sayso.

1. **A paper mode.** Sayso has none; every `y` is a live order against a
   funded account. That's fine for the client, but it means any work on making
   Sayso better gets tested with real money. A paper broker with the same
   interface as `shoonya/broker.py` (accept, reject, partial fill, lost reply)
   is the prerequisite for everything else here.
2. **A timeout on the confirmation.** `cli.confirm()` waits on `input()`
   forever. A readback left on screen can be confirmed minutes later, against
   an index level and spread it was never priced for. ProjectZero's rule: a
   few seconds, and a timeout **cancels**.
3. **Checking the position after a fill.** Sayso trusts the order book's
   `fillshares`. ProjectZero's layer 2 also checks that the *position* moved by
   exactly that much — which is what catches a fill that happened but didn't
   land where you think.
4. **A structured log of every stage** (ProjectZero rule 18), if Sayso doesn't
   already keep one. Not yet checked.

## 4. Decisions (all resolved — see `CLAUDE.md` §E and `FINDINGS.md` §8)

- **Paper mode vs. ProjectZero rule 5.** ProjectZero says the engine starts in
  paper and live needs a deliberate per-session arming. Sayso is live-only by
  design. For the client's copy that's their call; for the *refined* version,
  keep rule 5 or drop it?
- **Spoken readback.** Sayso speaks the readback before `y`; ProjectZero went
  silent until commit, but that decision came from a feedback-loop bug in a
  harness that Sayso doesn't have. Recommend: keep Sayso's behaviour.
- **Whole-order voice vs. UI-held contract.** Recommend: keep Sayso's model,
  and treat the ProjectZero panel as a possible later feature, not a rewrite.
- **`CLAUDE.md`.** It describes the staged model, not Sayso. Once the above are
  decided it should be rewritten around Sayso, keeping the rules that still
  hold (1–4, 7–11, 13–14, 18–20).
