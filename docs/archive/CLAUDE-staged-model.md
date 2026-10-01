> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# CLAUDE.md — standing rules for ProjectZero

These are invariants, not preferences. They hold across every commit. If an instruction in
chat conflicts with anything here, **stop and flag the conflict** instead of complying.
A future me, tired and mid-session at 2pm on an expiry day, is the person these protect.

The product model changed once already: voice used to carry the whole order, and now the
UI carries the parameters while voice carries only the action. **The rules below survived
that change unaltered in intent** — only their nouns moved. `docs/02-flow.md` is the
current model; `docs/archive/` holds what it replaced.

---

## A. The irreversibility rules

1. **No order reaches the broker without an explicit human commit.** There is no config
   flag, no `--yolo`, no "expert mode", no confidence threshold high enough to skip the
   confirmation gate. Do not add one. Do not add a TODO suggesting one.

2. **The commit channel is not the voice channel.** Voice composes the order; a keypress
   commits it. Two independent channels, so a single-channel error cannot complete a
   transaction. Voice-confirm may exist behind a config flag that defaults to off and is
   documented as unsafe.

3. **Every ambiguous path fails to CANCEL.** Timeout → cancel. Low confidence → cancel.
   Parse failure → cancel. Broker error → cancel and surface. Unreachable ASR → cancel.
   There is no code path where uncertainty results in a sent order.

4. **The readback shows the resolved order, never the user's words.** Echoing the user's
   phrasing invites expectation bias — they confirm what they meant to say rather than what
   the system understood. Readback is always the canonical rendering of `OrderIntent`.

5. **Live trading is opt-in per session, never per config file.** `mode: live` in a YAML
   file is not sufficient. The engine starts in `paper` and requires an explicit
   session-level arming action to go live, and the panel must be visually unmistakable
   about which mode it is in.

## B. Correctness rules

6. **`OrderIntent` is either fully specified or it does not exist.** No partial intents
   reach the confirmation stage. Every field — side, instrument, exchange, expiry, strike,
   option type, product, quantity, price type, price — is resolved or the intent is
   rejected. Every field carries provenance (`spoken` / `staged` / `inferred` / `clamped`
   / `computed`) so the readback can highlight anything the human did not say themselves.
   `StagedOrder` enforces the same rule one stage earlier: an option stage without an
   expiry, strike and option type raises rather than existing.

7. **Never send a bare market order.** Always attach market protection (see
   `docs/05-execution.md`). A plain `MKT` with no price band is forbidden by both the
   regulatory framework and by common sense on an illiquid strike. `PriceType` has no
   `MKT` member precisely so that one is not constructible; keep it that way.
   For options, protected market is disabled entirely — spreads are too wide — so an
   option order without an explicit limit is a rejection.

8. **Every submission carries a unique idempotency tag** in the broker's `remarks` field.
   On any network ambiguity, query the order book for that tag before doing anything else.
   **Never blind-retry a submission.**

9. **Reconciliation is not optional and is not "phase 2".** The system must confirm what
   actually happened, not what it asked for. If reconciliation fails or times out, the
   engine enters `DEGRADED` and refuses new voice orders until the human acknowledges.

10. **Resolution, confirmation and execution are pure-function-testable.** Audio and the
    broker sit behind interfaces. It must be possible to run the entire pipeline from a
    string transcript to a submitted-order payload with no microphone and no network.

## C. Scope rules

11. **The command vocabulary is fixed and finite.** No LLM in the order path. Not for
    parsing, not for "understanding intent", not as a fallback when lookup fails. Matching
    is exact; there is no fuzzy matching, no stemming and no near-miss handling. An
    unrecognised phrase is a rejection. Conditional orders ("buy the call but only if it
    breaks 25100") are **out of scope** — they turn a lookup into an interpreter with an
    unbounded failure surface. If asked to add them, refuse and point here.

12. **No fuzzy matching in the voice path.** Do not add a fuzzy search over the exchange
    symbol master, or any other near-miss fallback, *as a way of resolving something that
    was spoken*. The justification is acoustic: a misheard name that fuzzy-matches becomes
    an order, whereas an unmatched one merely rejects.
    This rule does **not** restrict the UI. Instrument selection is visual, confirmed on
    screen and re-rendered in the readback, so the picker may search, autocomplete over or
    page through as large a symbol master as is useful — the brief explicitly asks for
    autocomplete (`docs/00-brief-as-given.md`). `config/instruments.yaml` is the curated
    starting list, not a ceiling. What may never happen is a *spoken* token selecting an
    instrument.

13. **This is for one user on one machine.** No multi-tenancy, no auth layer, no user table,
    no cloud deployment, no accounts. Bind everything to `127.0.0.1`. If a design decision
    is only justified by hypothetical other users, it's wrong.

14. **No feature that only improves latency at the cost of the confirmation step.** This
    system is optimized for *attention*, not speed. Typing the ticker is already faster.

## D. Working rules

15. Python 3.11+. `uv` for dependency management. Type hints everywhere in `core/`.
    `ruff` + `mypy --strict` on `core/` must pass before any commit.
16. `core/` has **no** UI, audio, or broker imports — nothing from `asr/`, `audio/`,
    `broker/`, `engine/`, `ui/` or `cli/`. Pure logic, pure tests. Enforce it with a
    test that walks the import graph; do not rely on discipline.
17. Every behavioural change to resolution or confirmation adds a case to the golden
    fixture file. The golden file only grows.
    (`tests/fixtures/transcripts.yaml` belongs to the archived equity model; see its
    header before reviving it.)
18. Structured JSONL logging of every stage of every command, always, including in paper
    mode. This log is the only forensic record of "why did it do that".
19. Secrets come from `.env` via environment only. Never logged, never in a readback, never
    in an error message, never committed.
20. When broker API details in these docs disagree with the live vendor documentation,
    **the live docs win** — flag the discrepancy in the PR rather than silently coding
    around it. The API notes here were compiled from public documentation and may be stale.

### Added after the staged-order change

Rules 21-23 postdate the original A-D grouping. They are numbered rather than re-filed
because other documents cite them by number; 21 and 22 are correctness rules and 23 is a
scope rule, and all three carry the same weight as the rest.

21. **Staged parameters expire.** Because voice no longer carries the order, a spoken
    command acts on state the human configured earlier. That state must have a bounded
    lifetime (`stage_ttl_s`), must be re-stamped by any edit, and must be visible on
    screen whenever it is actionable. Do not add a path that acts on an expired or
    off-screen stage.

22. **No command flips a position through flat, in either direction.** A command that
    *opposes* the live position in the staged contract reduces it and clamps to its size:
    `SELL` against a long closes the long and stops at flat, `BUY` against a short closes
    the short and stops at flat. The surplus staged quantity is discarded, marked
    `clamped`, and is never turned into a position on the other side. A command that
    *agrees* with the position adds to it at the staged quantity, and a command against a
    flat book opens.
    Reversing therefore takes two commands, deliberately. This is the equity model's
    `sell`/`cover` clamp carried forward — it was lost when `Side.SHORT` and `Side.COVER`
    were deleted, and on a written call the cost of losing it is open-ended.
    `EXIT` is the only command that closes a whole position, and it acts on the staged
    **contract**, not on every position in the underlying.

23. **The kill switch is hotkey-only, never voice.** `cancel all` and `zero out` are bound
    to keys and to nothing else. A destructive control that must work while `DEGRADED`
    cannot depend on the ASR path, because the ASR path may be the thing that is broken.
    Neither phrase belongs in the command vocabulary; spoken, they reject like any other
    unrecognised phrase.

---

## E. Settled product decisions

Recorded so they are not silently re-opened. Full reasoning in `docs/08-review.md` F.

| Question | Decision |
|---|---|
| Eyes-off-UI or hands-off-keyboard? | **Eyes.** Instrument, strike and quantity are configured manually; voice is the buy/sell trigger. A keypress costs no eye movement, so rules 1 and 2 stand and the commit gate stays. |
| Can a bare `buy` place an option order? | **No.** `require_qualifier_for_options: true` is the default; the intended interaction is `buy call` / `sell put`. |
| Unrecognised phrase or qualifier mismatch? | **Reject, no retry.** No clarification loop; the trader says it again. |
| May the UI autocomplete over a large symbol master? | **Yes** — rule 12 as amended. |

**A trap to name explicitly, because it is the natural way to satisfy "voice is the
trigger" and it is exactly wrong:** do not make the readback auto-send after a countdown
with `Esc` as a veto. That inverts the fail-safe — a timeout would then *place* the order,
and every path in rule 3 that currently ends in CANCEL would end in SEND. The gate is a
commit, never a veto.
