> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 04 — Resolution

Transcript → `OrderIntent`. This is where the actual problem lives.

## The core insight

**Confidence scores do not capture ambiguity.**

`"hdfc"` fuzzy-matches `"hdfc bank"` at something like 95. It also matches `"hdfc life"` at
about the same. A naive "score ≥ 90 → accept" rule sails straight into the worst possible
outcome: high confidence, wrong instrument, no challenge.

So resolution uses **two independent signals**:

1. **Score** — how well the heard text matches an alias. Catches mis-hearing.
2. **Alias ambiguity** — a static property declared in the watchlist. Catches under-specification.

An alias marked `ambiguous: true` **always** routes to a challenge, no matter how high the
score. That's the whole trick. Ambiguity is a fact about the vocabulary, not a fact about
this particular recognition.

## The watchlist is the model

Keep it to ~30 names. Hand-maintained. See `config/watchlist.example.yaml` for the full
schema; the essential fields:

```yaml
- key: HDFCBANK
  tsym: HDFCBANK-EQ
  exch: NSE
  token: "1333"                 # cache from the symbol master; avoids a lookup per order
  aliases: [hdfc bank, hdfcbank, bank hdfc]
  ambiguous_aliases: [hdfc]     # match, but ALWAYS challenge
  check_word: bank              # the Vocollect check digit
  confusable_with: [HDFCLIFE, HDFCAMC]
  spoken: "H D F C Bank"        # what the readback says (and TTS speaks)
  default_qty: 40
  default_product: MIS
  max_qty: 200
  max_notional: 500000
  shortable: true
  derivative:
    lot_size: 550
    fut_root: HDFCBANK
```

**Maintenance discipline.** Adding a name to the watchlist means:

1. Checking whether any of its aliases collide with an existing name — a script must do
   this (`tools/check_aliases.py`), and CI must run it.
2. Assigning a `check_word` that is acoustically distinct from every other name's
   check word in the same `confusable_with` group.
3. Setting a `default_qty` that reflects what the trader actually trades in that name.

The collision checker is not optional. It is the thing that keeps the vocabulary safe as it
grows, and it's twenty lines of code.

## Matching pipeline

```
normalized text
      │
      ▼
 extract candidate symbol span   (everything between the verb and the first
      │                           qty/product/price token)
      ▼
 1. exact alias hit         ──► score 100
 2. exact ambiguous_alias   ──► score 100, ambiguous=True
 3. fuzzy over all aliases  ──► rapidfuzz token_set_ratio, top-k=3
      │
      ▼
 compute band
```

Use `rapidfuzz`. Build the alias index once at load into a flat
`list[tuple[alias_str, symbol_key, is_ambiguous]]` so the whole match is one pass over a few
hundred short strings — microseconds, no caching needed.

## Confidence bands

Two numbers matter: the top score `s1`, and the **margin** `s1 - s2` over the runner-up.
A high score with a thin margin is worse than a medium score with a wide one.

| Condition | Band | Behaviour |
|---|---|---|
| alias is in `ambiguous_aliases` | **CHALLENGE** | Always. Score is irrelevant. |
| `s1 ≥ 92` and `margin ≥ 8` | **RESOLVED** | Normal readback, normal commit |
| `s1 ≥ 92` and `margin < 8` | **CHALLENGE** | Two names heard nearly equally well |
| `75 ≤ s1 < 92` | **CHALLENGE** | Probably right, prove it |
| `s1 < 75` | **REJECT** | "Didn't catch that" — no guessing |

Thresholds live in `settings.yaml`. Tune them from the logs after a few weeks of real use;
do not tune them from intuition.

**REJECT is a first-class outcome, not a failure.** The user says it again. That costs two
seconds. Guessing costs a position.

## The challenge (check-word) mechanism

Borrowed wholesale from warehouse voice picking. Rather than asking "is this right?" —
which invites a reflex yes — the system asks for a **token that can only be produced if the
human knows which instrument is meant**.

```
Heard:  "short hdfc"
Widget: SHORT · H D F C ??? · 40 · MIS
        say  BANK  ·  LIFE  ·  AMC
```

The user says one word. That word:

- disambiguates the symbol,
- proves they were paying attention,
- cannot be produced by reflex, because the options differ per command.

Rules:

- Check words within a `confusable_with` group must be acoustically distinct. A script
  should assert this (minimum edit distance, no shared stressed vowel in the first syllable
  — a simple heuristic is fine; the point is to force a deliberate choice when adding
  names).
- The challenge has its **own** short timeout (default 4s), and expiry cancels.
- A challenge answer that matches none of the options **cancels the whole command**. It does
  not re-prompt. One retry is a slippery slope towards a loop the user talks their way
  through.
- After a successful challenge, the command still goes through the normal readback and
  commit. The challenge resolves the symbol; it does not authorize the order.

That last point matters and is easy to get wrong: **challenge ≠ commit.**

## Quantity and product

Resolved per `docs/03-command-grammar.md`. Each field carries provenance:

```python
class Provenance(StrEnum):
    SPOKEN   = "spoken"      # the user said it
    INFERRED = "inferred"    # came from config default
    CLAMPED  = "clamped"     # reduced to fit the live position or a risk limit
    COMPUTED = "computed"    # derived, e.g. half of position, lots × lot_size
```

Provenance drives the readback highlighting. An order where everything is `SPOKEN` needs
less visual weight than one where the quantity was `INFERRED` and the product was
`INFERRED` — the latter is where a surprise lives.

## Live-data dependencies

Resolution needs three live values, all of which must be **already in hand** when the
command arrives — never fetched inside the resolution path:

| Value | Used for | Source |
|---|---|---|
| LTP per watchlist symbol | notional estimate, protected-market price, limit sanity check | broker WebSocket, subscribed at startup to the whole watchlist |
| Current positions | `sell`/`cover` clamping, `half`/`all`, `exit` | polled every 2s and refreshed after every fill |
| Current expiry per derivative root | building futures `tsym` | resolved at startup, re-resolved daily |

If LTP is stale beyond `max_quote_age_ms` (default 5000), the notional in the readback is
shown as **stale** and protected-market orders are **rejected** — you cannot set a
protection band around a price you don't have. Explicit limits still work.

If positions are stale, `sell`/`cover`/`exit`/`half`/`all` are **rejected**. Never clamp
against a guess.

## Output

A fully-specified, immutable `OrderIntent` (see `schemas/order_intent.py`) or a
`Rejection(reason, detail)` or a `Challenge(options)`. Nothing else. `core/resolve.py`
returns a union of exactly those three and has no side effects, no I/O, and no clock
dependency beyond an injected `now`.

That property is what lets the whole hard part of this system be tested with a YAML file
and no microphone.
