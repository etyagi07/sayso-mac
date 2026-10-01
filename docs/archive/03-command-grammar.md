> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 03 — Command grammar

Fixed, finite, memorized. Closer to `AAPL US <Equity> GO` than to natural language.
No LLM in this path (`CLAUDE.md` rule 11).

## Design rules for the grammar itself

1. **Every word is load-bearing or dropped.** Filler is stripped before parsing, so "uh,
   short me some hdfc please" and "short hdfc" produce identical parses.
2. **Word order is fixed.** `<verb> <symbol> [qty] [product] [price]`. No reordering,
   no optional slots in the middle. A fixed skeleton is what makes a 40-line parser
   sufficient and a 400-line one unnecessary.
3. **Acoustically distinct keywords.** Where two keywords would mean opposite things, they
   must not rhyme or share a stressed vowel. This is the phonetic-alphabet lesson from
   aviation applied to the verb set. See "acoustic audit" below.
4. **Unknown token anywhere in the utterance ⇒ reject the whole utterance.** No partial
   parses, no "did you mean". Rejection is cheap; a wrong parse is not.

## Grammar (EBNF)

```ebnf
command       = order_cmd | control_cmd ;

order_cmd     = verb , symbol , [ qty_spec ] , [ product ] , [ price_spec ] ;

verb          = "buy" | "sell" | "short" | "cover" | "exit" ;
symbol        = alias ;                        (* from watchlist.yaml *)
qty_spec      = number
              | number , "lots"
              | "half"                         (* half of current position *)
              | "all"                          (* whole current position  *)
              | "default" ;                    (* explicit use of the default *)
product       = "intraday" | "delivery" | "futures" | "options" ;
price_spec    = "market"
              | "at" , number
              | "limit" , number ;

control_cmd   = "status"                       (* speak current positions & P&L *)
              | "positions"
              | "cancel"                       (* cancel the pending gate        *)
              | "cancel all"                   (* cancel all open broker orders  *)
              | "zero out" ;                   (* kill switch: cancel all + square
                                                   off everything — guarded, see 07 *)
```

## Verb semantics

| Verb | Meaning | Default product | Notes |
|---|---|---|---|
| `buy` | open/increase long | `intraday` (configurable) | |
| `sell` | reduce or close a long | same as the position being reduced | **Never flips to short.** Caps at current long qty. |
| `short` | open/increase short | `intraday` | Rejected if instrument not shortable in that product |
| `cover` | reduce or close a short | same as the position being covered | **Never flips to long.** Caps at current short qty. |
| `exit` | close the whole position in that symbol | matches the position | Qty slot forbidden; `exit` is always `all` |

**The `sell`/`cover` clamp is important.** "sell hdfc" when flat is a rejection, not a
short. "sell hdfc" when long 40 with a default qty of 100 is a sell of 40, not 100, and the
readback must mark the quantity as clamped. Ambiguity between "reduce" and "reverse" is
exactly the kind of thing that turns a good day into an incident.

## Quantity resolution order

1. Explicit number in the utterance → use it.
2. `half` / `all` → computed from the live position; **rejected if flat**.
3. No qty spoken → `default_qty` for that symbol from `watchlist.yaml`, marked `inferred`.
4. No qty spoken and no `default_qty` configured → **reject**. Never fall back to 1.

For `futures`/`options`, quantity is in **lots** and is multiplied by `lot_size` from the
watchlist. Speaking a bare number with a derivative product means lots, and the readback
must say both: `2 lots (1100)`.

## Product resolution order

1. Explicit product word → use it.
2. Symbol-level `default_product` in `watchlist.yaml` → use it, marked `inferred`.
3. Global `default_product` in `settings.yaml` → use it, marked `inferred`.

Product is the field most likely to be silently wrong, because "short hdfc" means something
different depending on it. It is therefore **always shown in the readback**, and when it was
inferred it is visually marked (`docs/05-confirmation.md`).

## Price resolution

Default is *not* a bare market order (`CLAUDE.md` rule 7). Default is a **protected market
order**: a limit at `LTP ± protection_pct`, side-appropriate, with `protection_pct` from
`settings.yaml` (start at 0.5% for liquid cash, wider for options).

- `market` → protected market as above.
- `at 1450` / `limit 1450` → plain limit.
- A limit more than `sanity_pct` away from LTP is **rejected**, not confirmed. Saying "at
  145" when you meant "at 1450" should never reach a readback.

## Normalization (before parsing)

`core/normalize.py`, applied in order. Each step is individually unit-tested.

1. Lowercase, strip punctuation, collapse whitespace.
2. **Filler strip** — `uh, um, er, like, please, okay, ok, hey, now, just, some, me, a, the,
   of, for, do, can, you, i, want, to, gonna` — from a config list, so it can be tuned to
   the user's actual speech.
3. **Letter-run collapsing** — ASR renders spelled letters inconsistently:
   `"h d f c"`, `"h.d.f.c."`, `"hdfc"`, `"H D F C"`, `"aitch dee eff see"`.
   Collapse runs of ≥2 single letters (and the spelled-out letter words) into one token.
4. **Number words → digits** — `forty` → `40`, `two hundred` → `200`, `fifteen hundred` →
   `1500`. Indian conventions: `one lakh` → `100000`. Handle `"for tea"` → `40`? **No** —
   see the homophone note below.
5. **Verb synonym folding** — a small explicit map: `go long` → `buy`, `sell short` →
   `short`, `buy to cover` → `cover`, `square off` → `exit`, `get out of` → `exit`.
   Explicit map only; no stemming, no fuzzy verb matching.
6. **Digit-glue repair** — `"4 0"` → `40` when adjacent bare digits appear with no
   intervening token.

**Homophone note.** Do not build a general homophone corrector. It is unbounded and it
introduces failures you cannot enumerate. Instead: rely on (a) the grammar rejecting
anything that doesn't parse, and (b) the readback catching what slips through. The one
exception is a small hand-maintained `asr_corrections` map in `settings.yaml` for mistakes
the user actually observes in their own logs, e.g. `"shot" → "short"`,
`"sale" → "sell"`, `"riliance" → "reliance"`. That list grows from evidence, not
imagination.

## Acoustic audit of the verb set

Run this check and record the result in the repo:

- `buy` / `by` / `bye` — homophones, but only `buy` is a verb in position 1, so harmless.
- `sell` / `cell` — resolve via the `asr_corrections` map if it ever appears.
- **`short` / `sort`** — real risk; `sort` is not in the grammar so it rejects rather than
  misfires. Add `"sort" → "short"` to corrections **only** if the user confirms it in logs;
  the default is rejection.
- `cover` / `covered` — fold in normalization.
- **`buy` vs `bid`** — both plausible in a trading context; `bid` is deliberately **not** in
  the grammar.

**The dangerous pair is `buy` vs `sell`-family, and they are acoustically distant.** Good.
Never add a verb that rhymes with an existing one. If a new verb is needed and it collides,
pick a different word — you own the vocabulary.

## Examples

| Utterance | Parse | Notes |
|---|---|---|
| `short hdfc` | `SHORT · <ambiguous> · default · intraday · protected-mkt` | Triggers check-word challenge |
| `short hdfc bank forty` | `SHORT · HDFCBANK-EQ · 40 · MIS · protected-mkt` | Clean |
| `buy two lots nifty futures` | rejected | Qty precedes symbol — word order is fixed |
| `buy nifty two lots futures` | `BUY · NIFTY<exp>FUT · 2 lots (150) · NRML · protected-mkt` | |
| `sell reliance all` | `SELL · RELIANCE-EQ · <position qty> · MIS` | Rejected if flat |
| `exit tcs` | `EXIT · TCS-EQ · <position qty>` | Qty slot forbidden |
| `exit tcs fifty` | rejected | `exit` takes no qty |
| `buy tcs at 3900` | `BUY · TCS-EQ · default · MIS · LMT 3900` | Sanity-checked vs LTP |
| `short reliance if it breaks 1400` | rejected | Conditional — out of scope (rule 11) |
| `zero out` | kill switch | Guarded, see `docs/07-execution.md` |

## Testing

`tests/fixtures/transcripts.yaml` is the golden file. Every case there must include the raw
transcript and the expected outcome (`intent` / `reject` / `challenge`), and the file only
grows (`CLAUDE.md` rule 17). Seed it with the table above plus the deliberately-mangled
cases already in the fixture file.
