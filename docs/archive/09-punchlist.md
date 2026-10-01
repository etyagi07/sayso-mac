> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 09 — Proofreading punch list

**Status: closed.** All 21 findings verified against the files; 19 fixed, 2 rejected as
misreadings. The two audits that had not run — the numeric/cross-reference pass and the
line-level pass — have now run, and their findings are in section C below. A third pass,
a straight end-to-end **read** of the edited prose, is in section D; it exists because the
fixes themselves introduced errors, which is the normal way of these things.

Kept as a record of what was wrong and how it was resolved. Nothing here is outstanding;
the open work is in `docs/07-roadmap.md` "Known gaps".

---

## A. Contradictions — verified and fixed

| # | Finding | Resolution |
|---|---|---|
| 1 | `BUY` against a short could flip; rule 22 covered only `SELL`. | **Rule 22 rewritten symmetric**: no command flips through flat in either direction. A command that *opposes* the position reduces and clamps at flat; one that *agrees* adds. Side table in `02-flow` completed to 10 rows with the `Intent` each produces. Two `[GATE]` fixtures added (`buy_against_smaller_short_clamps`, plus `buy_when_long_adds`). |
| 2 | `EXIT` said "staged instrument" in one place, "staged contract" in another. | Contract everywhere. |
| 3 | `EXIT`'s readback was said to replace the staged parameters, contradicting rule 21. | The stage still renders; only the **quantity** comes from the book, shown as a marked computed line. `EXIT` is exactly the command where hiding the stage would be worst. |
| 4 | `SELL` when already short was unspecified. | Covered by the symmetric rule: it **adds** (scaling a written position is legitimate; only flipping is not), with `friction: hold` because the `Intent` is `OPEN_SHORT`. Fixture `sell_when_short_adds`. |
| 5 | Two definitions of `Readback.unusual`; the code ignored friction, so the most expensive orders got an ordinary-looking card. | `OrderIntent.unusual` renamed `intrinsically_unusual`; `Readback.unusual` is authoritative and is `intrinsically_unusual or friction is HOLD`. Documented in both places and in the docstring. |
| 6 | `position_before` snapshotted "at resolution" in the contract and "at commit" in `05-execution`. | Two named snapshots, with a table saying which is for the rule 22 clamp and which is for reconciliation, and why reusing one for the other sends a correct order to `DEGRADED`. |
| 7 | Partial fills had no representable state, so the M2 chaos test could not pass. | `OrderState.PARTIAL` added (explicitly non-terminal) plus `is_terminal`. Remainder policy written: on reconcile timeout with a partial, cancel the remainder, wait for the cancel, reconcile against what filled. Layer 2 now runs on any terminal state with a non-zero fill. |
| 8 | A fixture silently asserted an undocumented cap precedence. | Evaluation order written into `05-execution` (session → cooloff → rate → limit sanity → premium → underlying; soft cap last, for friction only). Fixture rebuilt to breach **one** cap: 3 lots of a 24000 CE at ₹1,000 — premium ₹2,25,000 over the cap, underlying ₹54,00,000 well under. |
| 9 | `no_price` was unreachable: `StagedOrder` raises without a limit. | `02-flow` now describes it as a **stage-time UI rejection**; `NO_PRICE` retained for the unexercised equity/futures paths, and said so. |
| 10 | ASR disagreement was rejected in two layers. | The race **flags** (`agreement: false`), `core/resolve.py` **rejects**. Rule 10 requires the decision to be pure-function-testable, and a rejection inside `asr/race.py` could only be tested with audio. |
| 11 | FSM and panel state tables named different states. | `RECONCILING` added to the panel table and marked never-skipped — it is the window in which silent failure happens. `RESULT` documented as rendering both `DONE` and `CANCELLED`. |
| 12 | `CANCELLED → STAGED` was in prose but missing from the diagram. | Edge drawn, and the open question answered: the return does **not** re-stamp the stage, or a distracted session could keep a stale stage alive by never confirming it. |
| 13 | The readback card mock-up showed speech at the gate. | Replaced with the silence note. |
| 14 | Whether the qualifier applies to `EXIT` was never stated. | It does not — there is no leg to assert against when closing what you hold. Written into `02-flow`, fixture `exit_needs_no_qualifier`. |
| 15 | `asr_corrections` is near-miss handling, which `02-flow` says does not exist. | Boundary written: normalization is a **closed table of pairs a human observed in this trader's own logs**; nothing is computed, scored or inferred at runtime, and after it the lookup is exact and total. |
| 16 | Live arming was required by rule 5 with no protocol message and no control. | `{"t": "arm_live", "hold_ms": 1500}` added to the protocol; the held control specified in `06`; never sticky across a restart. |
| 17 | Rate caps were enforced pre-gate, counting cancelled commands and missing a loop after the gate. | Counters increment **at submission**; the pre-gate check is advisory. The regulatory purpose is to bound orders actually routed. |
| 18 | Stage expiry enforced two ways. | Both kept, and the resolve-time check named authoritative — it is the only half a fixture can exercise. |
| 19 | Precedence claimed by both `README` and `02-flow`. | `02-flow` qualified: current truth about the product model, below `CLAUDE.md`. |
| 20 | A fixture staged a strike with no quote in its world. | LTP added; `RejectReason.NO_QUOTE` added for genuinely absent quotes and a fixture with it. |
| 21 | Stale-quote handling flagged the notionals, which do not use LTP. | Corrected: neither notional uses LTP. What a stale quote corrupts is `limit_sanity_pct`, which is now **skipped, not relaxed**, with a warning on the card — a check against a ten-minute-old price is worse than none, because it looks like one. Fixture `stale_quote_skips_limit_sanity`. |

## B. Rejected

- **"The archive files are cited but absent."** False positive: `docs/archive/` and
  `config/archive/` exist and were simply not in the set the reviewer was given.
- **Dozens of "unbalanced `**`/backtick" hits** from the automated pass. All were emphasis
  spanning two source lines, which is valid Markdown and renders correctly.

## C. The two audits that had not run

**Numeric and cross-reference audit** — scripted over every doc: config keys, type and
enum names against `core/intent.py`, rejection-reason strings, `CLAUDE.md` rule citations,
milestone references, FSM state coverage, and every worked arithmetic example recomputed.
One real finding: `cloud_timeout_ms` in `06` did not exist under that name in the config,
which nests it at `asr.cloud.timeout_ms`. Fixed. Everything else reconciled.

**Line-level proofread** — scripted plus read: doubled words, unclosed fences, table
column counts, stray terminology, box-drawing alignment. Findings:

- `02-flow.md` heading "The qualifier is a check word" → "What the qualifier is". The
  section's own argument is that it is *not* the Vocollect check digit; the heading said
  otherwise. ("Check digit" survives in `01-brief.md`, where it correctly describes the
  warehouse practice.)
- The process-model box in `03-architecture.md` had a gutter one character narrower on
  three rows, so its right edge stepped. All seven rows now 72 columns.
- The FSM diagram had been damaged by an earlier edit that inserted four lines of prose
  into the middle of it, breaking the two left-hand edge columns. Redrawn; the prose moved
  below the fence where it belongs.
- No doubled words, no unclosed fences, no malformed tables.


## D. Third pass — reading the edited prose

The scripted audits in C check things a script can see. They cannot see a paragraph that
now contradicts the paragraph above it because both were edited separately. So the set was
read end to end afterwards. Found and fixed:

**Contradictions introduced by the fixes themselves**

- `02-flow.md` still said "`CLAUDE.md` rule 12 holds unchanged: no fuzzy search over the
  exchange symbol master". Rule 12 had been *narrowed* to the voice path precisely so the
  UI could autocomplete, which is what the brief asks for. The one document a reader goes
  to for the product model was asserting the opposite of the rule it cited.
- `02-flow.md` said the qualifier "is exactly the Vocollect check-digit mechanism",
  three paragraphs above the section added to explain that it is **not** — the check digit
  verified the thing at risk, and here the contract is already on screen.
- `04-safety.md` opened with "three of the **four** failure modes" after the title and
  body had both been corrected to five.
- `05-execution.md` said "timeout without terminal state → `DEGRADED`" immediately below
  the new paragraph saying a timeout with a partial fill cancels the remainder instead.
  Qualified to "timeout with **nothing filled**".
- `04-safety.md` said "an option order passes through both" the qualifier and the commit,
  after `EXIT` had been exempted from the qualifier.
- The no-speech test was specified to assert "no speech at all" while also being told the
  spoken string is "what a voice-confirm mode would speak" — an impossible pair. Now
  conditioned on `allow_voice_confirm` being false, with the exemption named.

**Damage and drift**

- The readback card in `04-safety.md` was an unclosed box: top and bottom rules with
  corners, but no right edge on any body line. Closed, 56 columns.
- `02-flow.md` referenced a leftover "now also honoured by this flow" clause from an
  earlier edit that no longer parsed as an argument. Rewritten.
- `core/normalize.py` was missing from `02-flow.md`'s module list despite the same
  document having a section about what it does.
- Mixed `x` and `×` for multiplication; four over-long lines; three runs of blank lines;
  a stray space inside a JSON example; `RejectReason.ASR_UNAVAILABLE` described in prose
  but not named.

**Method note for next time.** Every one of the contradictions above was created by fixing
something else, and none of them was visible to the scripts. A scripted pass and a read
pass catch disjoint sets of problems; running only the first is how a document set drifts
while appearing to be verified.
