> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 08 — Review of the staged-order revision

> **Read section G first.** Most of what follows has since been fixed, and G says exactly
> which items and how. Sections A–F are kept as the reasoning, not as a to-do list — acting
> on them without reading G means re-fixing things that are already fixed. The items still
> open are listed at the end of G and mirrored in `docs/07-roadmap.md` "Known gaps".

An audit of the document set against itself, and against what the model actually needs.

**Verdict on the direction: it's right.** Deleting symbol resolution rather than solving it
is the correct call, and `docs/02-flow.md`'s argument for *keeping* the gate — that
shrinking the command removes the ambiguity class but concentrates the remaining risk into
an utterance with no redundancy left — is the sharpest paragraph in the repository. The
revision is better than what it replaced.

What follows is what it left behind. Items are ordered by what blocks work, not by size.

---

## A. Blocking — M1 cannot start as written

### A1. There is no contract file

`README.md` lists `core/intent.py` as supporting material — "the contract between stages".
`docs/archive/README.md` says the original is "superseded by `core/intent.py`, which is now
the only file that may call itself the contract." **`core/intent.py` does not exist.**

The only typed contract in the repo is `docs/archive/order_intent-original.py`, which is
the equity model: it carries `Side.SHORT`, `Side.COVER`, `Band`, `Challenge`, a single
`notional` field and no strike, expiry or option type. `CLAUDE.md` rule 6 now enumerates
fields (`expiry`, `strike`, `option type`, provenance value `staged`) and a `StagedOrder`
type that exist in no file.

Three documents describe a contract that was deleted and not rewritten. Writing
`core/intent.py` — `OrderIntent`, `StagedOrder`, `VoiceCommand`, `Rejection`, the
provenance enum, `Side` with `SHORT`/`COVER` removed — is the first task, ahead of M0
scaffolding.

### A2. There are no fixtures for the current model

`tests/fixtures/transcripts.yaml` is explicitly archived by its own header and points at
`tests/fixtures/staged_commands.yaml`, which does not exist. M1's acceptance criterion is
"every fixture passes"; there are no fixtures to pass. The structural gate M1 describes —
*no spoken word can produce an order larger than staged, on a different strike, or on a
different option type* — needs its own corpus, and that corpus is small enough to write by
hand in an hour.

### A3. `config/staged.example.yaml` is missing about half of what the docs cite

Keys referenced in the docs that appear in no config file:

| Key | Cited in |
|---|---|
| `engine.host` / `engine.port` | `03-architecture.md` |
| `hotkeys.*` (talk, commit, cancel, kill switches) | `04-safety.md`, `05-execution.md` |
| `asr.*` — `cloud_enabled`, `prefer_cloud_window_ms`, `total_budget_ms`, `cloud_timeout_ms`, local model pin | `06-voice-and-ui.md` (whole ASR section) |
| `audio.*` — pre-roll, VAD, min/max utterance | `06-voice-and-ui.md` |
| `listen_mode: armed_window` | `02-flow.md` |
| `read_floor_ms` | `04-safety.md` fatigue mechanic |
| `reconcile_timeout_ms`, `reconcile_poll_ms`, `position_poll_ms` | `05-execution.md` |
| `reject_cooloff`, `session_hours` | `05-execution.md` risk table |
| `broker.*`, `paper.*`, `logging.*` | `03-architecture.md`, `05-execution.md` |

The archived `config/archive/settings.example.yaml` has most of these. They were dropped in
the rewrite rather than carried over.

---

## B. Contradictions inside the current model

### B1. The kill switch speaks words that are not in the vocabulary

`05-execution.md` lists **Voice `cancel all`** and **Voice `zero out`**. Neither phrase is
derivable from the lemma table in `02-flow.md`, and `CLAUDE.md` rule 11 says matching is
exact and an unrecognised phrase is a rejection. As written, saying "zero out" rejects.

**Recommendation: make both kill switches hotkey-only and delete the voice column.** A
destructive control that must work while `DEGRADED` should not run through the ASR path,
which may itself be the thing that is broken. This is a better design, not just a
consistency patch.

### B2. The vocabulary count doesn't match the lemma table

12 verb forms × 6 objects × 9 qualifier forms = **648**, not 360. 360 is exactly
12 × 6 × 5, which is what you get if `ce` / `c e` / `pe` / `p e` are dropped and only
`call`/`calls`/`put`/`puts`/none remain. Either the count or the table is wrong. Since
`zero-doctor` is specified to print this number, fix it before it becomes a test.

Worth deciding deliberately: `ce` and `pe` are two-phoneme tokens with poor acoustic
separation from each other and from surrounding words. The acoustic-distinctness rule that
`02-flow.md` inherits argues for dropping them, which conveniently gives you 360.

### B3. `SELL` semantics against an existing position are undefined

This is the most expensive gap in the set.

The archived grammar had an explicit rule: `sell` reduces a long and **never flips to
short**; `cover` reduces a short and never flips to long; both clamp to the live position.
`docs/archive/README.md` lists `Side.SHORT` and `Side.COVER` as "deleted outright", and
`02-flow.md` folds `sell`, `short`, `write` and `go short` into a single `SELL` verb —
without saying what `SELL` does when the trader is already long the staged contract.

For an option the two readings are very different:

- **Reduce:** long 75 NIFTY 25000 CE, say "sell call" → flat.
- **Open:** long 75, say "sell call" → short 75 against the long, or flat plus a new naked
  short depending on how the broker nets it.

On a written call the second reading is an open-ended risk the trader did not ask for.
`EXIT` is specified carefully; `SELL` needs the same paragraph. Recommend keeping the old
clamp: `SELL` reduces first, and opening a new short requires the position to be flat.

### B4. Reconciliation layer 2 fires `DEGRADED` on every partial fill

`05-execution.md`:

```
expected_delta = signed_qty(intent)
actual_delta   = positions_after - positions_before
assert actual_delta == expected_delta
```

The chaos test in `07-roadmap.md` M2 injects 5% partial fills. A partial fill makes
`actual_delta` smaller than `expected_delta` by construction, so the assertion fails and
the engine goes `DEGRADED` on a perfectly normal event. The comparison must be against the
**filled quantity reported by layer 1**, not against the intent:

```
assert actual_delta == signed(filled_qty_from_layer_1)
assert abs(filled_qty) <= abs(intent.quantity)
```

This bug was inherited from the equity spec; it matters more now because partial fills are
explicitly in the acceptance criteria.

### B5. The default risk caps make deep-ITM NIFTY untradeable at one lot

`max_premium_per_order: 75000` ÷ lot size 75 = **₹1,000**. Any NIFTY option priced above
₹1,000 fails at a single lot — which is routine for in-the-money strikes. BANKNIFTY's
equivalent ceiling is ₹2,142.

This is precisely the failure `05-execution.md` warns about and that `zero-doctor` is
specified to catch, so the shipped example config would fail the project's own check. The
pair is otherwise well-chosen — both caps can bind first depending on moneyness (at
25000 CE @ ₹142.50 underlying binds at 5 lots, premium at 7), so the fix is just to raise
`max_premium_per_order` or state the ITM restriction deliberately.

### B6. `04-safety.md`'s title says four, its body says five

Title: "the gate, and the **four** things that kill this". Part 2: "**Five** now." README
says five. Stale staged parameters is the fifth and it is the one the new model introduced,
so it should be in the title.

### B7. Leftovers from the deleted model

- `04-safety.md`: "challenge-style prompts 4s" — there are no challenge prompts. The
  qualifier arrives inside the same utterance; there is no second timeout.
- `06-voice-and-ui.md` "What not to build": "never as the decision… band demotion" —
  confidence bands were deleted with the resolver.
- `05-execution.md`: `tradingsymbol` example is `'HDFCBANK-EQ'` and the fill readback
  example is `"filled 40 at 1961.20"`. Both should be option examples now that options are
  the only exercised path.
- `05-execution.md`: `DEGRADED` "blocks `IDLE → LISTENING`" — the FSM now routes
  `IDLE → STAGED → LISTENING`.

---

## C. Dangling references

| In | Points at | Should be |
|---|---|---|
| `README.md` supporting material | `core/intent.py` | does not exist — see A1 |
| `config/staged.example.yaml` header | "docs/11" | `docs/02-flow.md` |
| `tests/fixtures/transcripts.yaml` header | `staged_commands.yaml`, `docs/11-staged-order-mode.md`, `docs/03`, `docs/04` | does not exist / old numbering |
| `05-execution.md` risk table + protection_pct | `settings.yaml` | `staged.yaml` |
| `06-voice-and-ui.md` ASR policy | `settings.yaml` | `staged.yaml` |
| `instruments.example.yaml` `tsym_template` | `{expiry:%d%b%y}` → `NIFTY24Sep2625000CE` | docs show uppercase `NIFTY24SEP2625000CE`; the template cannot produce it |

`docs/archive/` deliberately keeps old links and says so — that is fine and should stay.

---

## D. Design questions the revision opened and hasn't answered

### D1. What the qualifier actually protects

`02-flow.md` presents `buy call` as the Vocollect check digit carried forward. It isn't
quite, and the difference matters.

The warehouse check digit verified **the thing that was at risk** — the worker's location,
which nothing else confirmed. Here, the contract is chosen in the UI, validated at stage
time, and rendered on screen continuously. It is the one parameter that cannot be wrong.
Voice now decides exactly one thing — **the side** — and the qualifier gives zero
protection against a side error, because `buy call` and `sell call` share the qualifier.

That does not make it useless. It genuinely protects two real things:

1. **Stray utterance.** With `require_qualifier_for_options: true`, a random "buy" in
   conversation cannot place an order. This is the main defence and it is a good one.
2. **Stale stage.** Muscle-memory "buy call" against a PE staged twenty minutes ago
   rejects. That is failure mode 4 caught by the vocabulary.

Worth rewriting that section to claim those two jobs rather than the check-digit lineage —
and then noting plainly that **nothing in the voice path guards buy-vs-sell**; the readback
and the keypress are the only defence there, which is a further argument for both.

### D2. `EXIT` — instrument or contract?

`02-flow.md` says `exit` acts on "the live position in the staged instrument". If the
trader is long two NIFTY strikes, "exit" against a staged 25000 CE must close **that
contract**, not the NIFTY book. The wording should say contract.

### D3. The EQ row in `instruments.example.yaml`

`07-roadmap.md` lists "equity and futures paths — the model allows them; never exercised"
as a known gap, yet the example instrument table ships a RELIANCE EQ row that the picker
will happily offer. `require_qualifier_for_options`, both-notional risk and
`allow_protected_market_options` all assume options. Either comment the row as untested or
remove it until the path is exercised.

### D4. `max_orders_per_minute: 6`

Justified as regulatory headroom, but 10/s is 600/min — 6/min is 100× conservative and may
bind during a fast move, which is exactly when an options trader is speaking. 20/min is
still 30× under the threshold. Tune from logs; it is an ergonomics number wearing a safety
number's clothes.

---

## E. What this revision got right, and should not be re-litigated

- **Deleting the problem instead of solving it.** The README is honest that this cost the
  best thinking in the project, and keeping `docs/archive/` with a survival map is the
  right way to spend that loss.
- **"Shrinking the command concentrates the risk."** The reason the gate survives a change
  that appears to make the gate less necessary. Keep this argument verbatim.
- **Silent pre-commit audio**, with the TTS-feedback-loop reason. That is an observed
  failure, not a theorised one, and the reasoning that killed the timeout sound does apply
  to the readback tick.
- **Two notionals, and the observation that the caps are not independent.** `underlying ÷
  premium = strike ÷ price` is the kind of thing found by running code, and the
  `zero-doctor` tradability check is the right response — see B5 for making the defaults
  pass it.
- **The structural M1 gate** (nothing spoken can change strike, option type or exceed
  staged quantity) is stronger than the statistical gate it replaced.
- **"Nothing is built"** stated plainly in three places, and `02-flow.md` flagged as a
  proposal not yet re-examined. That honesty is worth more than the documents.

---

## Suggested order of work

1. Write `core/intent.py` — the contract (A1). Nothing else is startable without it.
2. Fix B3 (`SELL` clamp) and B4 (partial fills) — both are correctness, both are cheap now
   and expensive later.
3. Hand-write `tests/fixtures/staged_commands.yaml` (A2) including a case for every item in
   B3.
4. Rebuild `config/staged.yaml` from `config/archive/settings.example.yaml` plus the new
   keys (A3), and fix the caps (B5).
5. Sweep C, B1, B2, B6, B7 — an afternoon of text edits.
6. Then M0.

---

## F. Where the current docs depart from the brief

Added after `docs/00-brief-as-given.md` was put into the repository. Three documents cite
"the brief"; it was not checkable until now. These are **decisions, not bugs** — but they
were made silently, and four of them contradict the brief's plain words. Each needs an
explicit yes or no before M1.

### F1. The brief has no confirmation step. The docs insert one. ⚠ the big one

Brief, Design Principle: `Configure → Listen → Speak → Execute → Hear/See Confirmation`.
Nothing between Speak and Execute.

Docs: `… → Speak → readback → Space → Execute`.

`02-flow.md` argues this well — a bare `buy` has no redundancy and therefore cannot
reject, so per-utterance risk rises even as the vocabulary shrinks, and the keypress puts
the redundancy back. That argument is sound. It is also **a change to the product**, and
the brief's own words are on the other side of it: "The trader should not need to
constantly interact with buttons."

Note the two are not straightforwardly opposed. The brief's stated purpose is *visual*
attention — "without having to look away from their trading charts". A keypress costs no
eye movement. If the requirement is eyes-on-chart, the gate is compatible with the brief.
If the requirement is hands-off-keyboard, it is not.

**Decide which of those two the requirement actually is.** Everything else in this section
follows from the answer.

### F2. The brief asks for a persistent listening state. The docs use push-to-talk.

Brief: "The system should instead be in a state where it is waiting/listening for the
trader's voice command after the relevant order parameters have been configured."

Docs (`02-flow.md` "Why not always-listening", `06-voice-and-ui.md`): push-to-talk by
default; `listen_mode: armed_window` offered as a middle ground; "a hot mic that can place
trades is not a thing to own."

The override is stated openly, which is right. But note push-to-talk is a button — so it
carries the same tension as F1, and if F1 resolves to "hands-off", `armed_window` plus a
wake word is the only configuration that satisfies the brief.

### F3. The brief's primary example is a bare "Buy". The default config rejects it.

Brief: `NIFTY + 25,000 CE + 75 quantity → "Buy" → Execute Buy Order`.

Config: `require_qualifier_for_options: true`, which makes a bare `buy` on an option a
rejection. The brief's headline example does not work under the shipped defaults.

The flag exists for a real reason (see D1 — it is what stops a stray "buy" in conversation
from trading) but it changes the primary interaction the brief describes. Either flip the
default and accept the stray-utterance risk, or keep it and tell the trader plainly that
the qualified form is the interaction.

### F4. The brief allows a clarification prompt. The docs never re-prompt.

Brief: "if the system cannot confidently determine the intended action, it should ask for
clarification **or** use a safe non-execution state."

Docs: reject only; one failed qualifier cancels the command with no retry, because a
re-prompt is a loop a human can talk their way through.

This is within the brief's "or", so it is compliant — but it is the stricter half, chosen
without comment. Worth confirming the trader wants the stricter half.

### F5. Rule 12 is over-broad and blocks something the brief explicitly invites.

Brief: "Instrument selection can be manual initially. **Autocomplete/search can be added to
make selection faster.**"

`CLAUDE.md` rule 12: "The instrument table is hand-maintained and small. Do not add a fuzzy
search over the full exchange symbol master."

The rule's justification — that an unmatched name becomes *impossible* rather than merely
rejected — is an argument about **acoustic** matching. It was written when voice picked the
symbol. Once selection is visual, on screen, and confirmed in the readback, autocomplete
over the full symbol master is not dangerous: the trader can see what they picked.

Rule 12 should be narrowed to "no fuzzy matching in the voice path", leaving the UI picker
free to search whatever it likes. As written it prevents a feature the brief asks for, for
a reason that no longer applies.

### F6. Development instructions 1–3 are inert

"First understand the existing codebase", "Do not redesign the entire application unless
necessary", "Preserve existing functionality" — there is no existing codebase. Nothing is
built. Instructions 1–3 will either be silently ignored or will make an agent cautious
about protecting code that does not exist. Replace them for the next handoff.

### What the docs got right against the brief

- **Systematic vocabulary, exact matching.** The brief asks for natural variations designed
  systematically rather than hard-coded; the docs enumerate the variations systematically
  and then match exactly against the enumeration. Both halves satisfied, no fuzzy layer.
- **Instruction 7** — "use the currently configured UI state and command context" — is
  implemented exactly: the verb carries the side, the UI carries the contract.
- **Instruction 5** — interpretation separate from execution — is `core/` vs `engine/`.
- **EXIT handled explicitly** with mandatory hold-to-commit, per the brief's last safety line.
- **Audio confirmation after execution** is preserved, and the pre-commit silence is a
  well-argued addition rather than a quiet removal (`04-safety.md`).

---

## G. What has been applied

Dated 2026-09-21. Items not listed here are still open.

**Resolved by decision** (recorded in `CLAUDE.md` section E):

- **F1** — the requirement is *eyes*, not hands. Setup is manual; voice is the buy/sell
  trigger; the keypress commit stays. `CLAUDE.md` section E also names the trap: never
  turn the gate into an auto-send with `Esc` as a veto, because that inverts the fail-safe.
- **F3** — `require_qualifier_for_options` stays `true`. `buy call`, not `buy`.
- **F4** — reject with no retry; no clarification loop.
- **F5** — rule 12 narrowed to the voice path; the UI picker may autocomplete freely.

**Fixed:**

| Item | What changed |
|---|---|
| A1 | `core/intent.py` written — `StagedOrder`, `VoiceCommand`, `OrderIntent`, `Rejection`, `Readback`, broker types. Verified on 3.11: the rule 6 and rule 7 guards raise, `Side` has no `SHORT`/`COVER`, `PriceType` has no `MKT`. |
| A2 | `tests/fixtures/staged_commands.yaml` — 30 cases, 15 rejections, every `RejectReason` used is in the enum. `[GATE]` marks the structural M1 assertions. |
| A3 | `config/staged.example.yaml` rebuilt: `engine`, `hotkeys`, `audio`, `asr`, `broker`, `paper`, `logging`, `listen_mode`, `read_floor_ms`, `reconcile_*`, `reject_cooloff`, `session_hours` all restored. |
| B1 | Kill switches are hotkey-only (`CLAUDE.md` rule 23); the voice column is gone. |
| B2 | Vocabulary corrected to **504** and the arithmetic shown; `ce`/`pe` dropped on acoustic grounds. |
| B3 | Rule 22 added, plus a side-semantics table in `docs/02-flow.md`. `SELL` reduces before it opens; `EXIT` is scoped to the contract. |
| B4 | Reconciliation layer 2 now asserts against the **filled** quantity, with a second assertion that the fill never exceeded the intent. |
| B5 | `max_premium_per_order` 75,000 -> 2,00,000, with the worked table showing why 75,000 made every NIFTY ITM strike untradeable at one lot. |
| B6 | `04-safety.md` title says five. |
| B7 | Removed the 4s challenge timeout, the band-demotion leftover, `HDFCBANK-EQ` and the equity fill example. |
| C | `settings.yaml` -> `staged.yaml`, `docs/11` -> `docs/02-flow.md`, the fixture header's dead pointers, the mixed-case `tsym` template flagged. |
| D3 | The untested `RELIANCE` EQ row is commented out with the reason. |

**Still open:**

- **D2** was folded into B3 — EXIT is now explicitly contract-scoped. Nothing outstanding.
- **D4** — `max_orders_per_minute: 6` left as is, with a note to raise it if it binds.
- **F6** — development instructions 1-3 in the brief are inert; rewrite them for the next
  handoff rather than editing the brief, which is kept verbatim.
- The six known inconsistencies in the archived equity fixtures, which stay archived.
- Everything in `docs/07-roadmap.md` "Known gaps" — `tsym` construction above all.

---

## H. Second pass — proofread and reconciliation

Dated 2026-09-21, after G. Full detail in `docs/09-punchlist.md`, which is now closed.

Twenty-one contradictions were raised by an independent read; 19 held and were fixed, 2
were misreadings. The behavioural ones, which changed the spec rather than its wording:

- **Rule 22 is now symmetric.** It forbade `SELL` flipping a long into a short but said
  nothing about `BUY` against a short, and it accidentally forbade *adding* to a written
  position, which is ordinary scaling. It now reads: a command that opposes the position
  reduces it and stops at flat; one that agrees adds; nothing flips in one utterance.
- **Partial fills are representable.** `OrderState.PARTIAL`, non-terminal, plus a
  remainder policy — cancel the rest, then reconcile against what filled. Without this the
  M2 chaos test could not have passed.
- **Two position snapshots, named separately.** The clamp uses the resolution-time one,
  reconciliation uses a commit-time one, and up to 6s of gate sits between them.
- **Risk-cap evaluation order is fixed and written down**, and the rate counters moved to
  submission, where the regulatory purpose actually points.
- **`Readback.unusual` includes friction**, so an order over the soft cap no longer gets an
  ordinary-looking card.
- **Stale quotes skip the limit-sanity check rather than running it**, and `NO_QUOTE` now
  exists as distinct from stale.
- **`arm_live` exists** as a protocol message and a held control, which rule 5 required and
  nothing provided.

The two audits that had never run — numeric/cross-reference and line-level — have now run.
They found one real reference error (`cloud_timeout_ms` vs `asr.cloud.timeout_ms`), one
misleading heading, and two damaged ASCII diagrams, all fixed.
