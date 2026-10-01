> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 05 — Execution, reconciliation and regulatory

The easy stage, plus the neglected half of it.

## Broker adapter

Target broker: **Finvasia Shoonya** (NorenRestApi), via `ShoonyaApi-py`.

> **Verify every detail below against the live vendor documentation before coding**
> (`CLAUDE.md` rule 20). These notes were compiled from public docs and the vendor's Python
> SDK README and may be stale. The adapter must be written so that a change in the vendor's
> parameter names touches exactly one file.

### Login

```python
api.login(userid, password, twoFA, vendor_code, api_secret, imei)
```

- `twoFA` is the TOTP — generate with `pyotp` from the seed in `.env`. Do not prompt.
- Response carries `susertoken`, used for all subsequent calls.
- **Session handling:** log in once at engine start, keep the token, detect expiry (the
  vendor returns a session error) and re-login **once** automatically. If re-login fails,
  enter `DEGRADED` — never retry a login in a loop against a broker.

### Place order

```python
api.place_order(
    buy_or_sell,      # 'B' | 'S'
    product_type,     # 'C' CNC | 'M' NRML | 'I' MIS | 'B' bracket | 'H' cover
    exchange,         # 'NSE' | 'NFO' | 'BSE' | 'CDS' | 'MCX'
    tradingsymbol,    # e.g. 'NIFTY24SEP2625000CE'  (format UNVALIDATED — M5 blocker)
    quantity,
    discloseqty,
    price_type,       # 'LMT' | 'MKT' | 'SL-LMT' | 'SL-MKT' | ...
    price=0.0,
    trigger_price=None,
    retention='DAY',  # 'DAY' | 'EOS' | 'IOC'
    amo='NO',
    remarks=None,     # ← idempotency tag goes here
)
```

Mapping from `OrderIntent`:

| Intent | Shoonya |
|---|---|
| `side=BUY` | `buy_or_sell='B'` |
| `side=SELL` | `buy_or_sell='S'` |
| `product=MIS` | `product_type='I'` |
| `product=CNC` | `product_type='C'` |
| `product=NRML` | `product_type='M'` |
| protected market | `price_type='LMT'`, `price=<band price>` |
| explicit limit | `price_type='LMT'`, `price=<limit>` |
| `command_id` (ULID) | `remarks=<command_id>` |

`EXIT` resolves to the opposite side of the held position — `core/resolve.py`
derives it from the signed position and never assumes.

### Other calls used

`get_orderbook()`, `single_order_history(orderno)`, `get_trade_book()`, `cancel_order()`,
`get_positions()`, `searchscrip()`, `get_security_info()`, `start_websocket()` /
`subscribe()`.

The WebSocket feed is subscribed to the staged contract (and the instrument table's
underlyings) for LTP. Resolution never fetches — quotes and positions are already in hand
when the command arrives, which is what keeps `core/resolve.py` pure.

## Never send a bare market order

`CLAUDE.md` rule 7. Two reasons, and they point the same way:

1. **Regulatory.** Under the framework in force from 1 April 2026, market orders routed via
   API require a non-zero market-protection value, which converts them to a limit bounded
   around the last traded price.
2. **Practical.** A market order into a thin option strike is how you discover what an
   ₹8 spread feels like.

Implementation: a "protected market" order is a **limit order at `LTP × (1 ± protection_pct)`**,
rounded to tick size, side-appropriate (buy: above LTP; sell: below LTP). `protection_pct`
is per-instrument-class in `staged.yaml`: 0.5% for liquid cash, 1% for index futures, and
disallowed entirely for options (`allow_protected_market_options: false`) — option spreads
are too wide, so an option order without an explicit limit is a rejection, not a band.

If LTP is stale, protected-market is **rejected**. You cannot band around a price you don't
have.

## Idempotency

Every command gets a **ULID** at the moment the hotkey is pressed. It is the `command_id` in
every log line and it goes into the broker's `remarks` field.

**The rule: never blind-retry a submission** (`CLAUDE.md` rule 8).

On any ambiguous outcome — timeout, connection reset, 5xx, unparseable response:

```
1. Do NOT resubmit.
2. Query the order book and search for remarks == command_id.
3. Found    → adopt that order number, continue to reconciliation.
   Not found → surface "submission status unknown" to the panel,
               enter DEGRADED, require human acknowledgement.
4. Only after the human explicitly re-issues does a new command_id get created.
```

A duplicated order is worse than a missed one, because a missed one is visible immediately
and a duplicate is not.

## Reconciliation

The half everyone skips. Two layers.

### Layer 1 — order terminal state

After submission, poll `single_order_history(orderno)` on a short interval (250ms, backing
off to 1s) until a terminal state (`COMPLETE`, `REJECTED`, `CANCELED`) or
`reconcile_timeout_ms` (default 5000).

**A partial fill is not terminal.** `OrderState.PARTIAL` means some quantity filled and
the remainder is still resting, which for a voice order is not a state to leave lying
around: on `reconcile_timeout_ms` with a partial, **cancel the remainder**, wait for the
cancel to confirm, and then reconcile against what actually filled. The order ends
`CANCELED` with a non-zero `filled_qty`, the result card says so explicitly
("filled 75 of 150, remainder cancelled"), and layer 2 runs normally. Timing out into
`DEGRADED` on an ordinary partial would make the M2 chaos test unpassable and would train
the trader to dismiss the alarm.

Read back the terminal state to the panel and as audio:

- `COMPLETE` → "Bought 75 Nifty 25000 Call at 142.50" + fill chime.
- `REJECTED` → show the broker's rejection reason verbatim. Broker rejection messages are
  cryptic but they are the ground truth; do not paraphrase them.
- Timeout with **nothing filled** → **`DEGRADED`**. A timeout with a partial fill is
  handled above and is not a `DEGRADED` condition.

### Layer 2 — position assertion

The one that actually catches silent failure. After any terminal state with a non-zero
`filled_qty` — `COMPLETE`, or `CANCELED` after a partial:

```
filled       = signed(layer_1.filled_qty)      # what the broker says actually traded
actual_delta = positions_after[contract] - positions_before[contract]

assert actual_delta == filled                  # the book agrees with the fill report
assert abs(filled) <= abs(intent.quantity)     # and the fill never exceeded the intent
```

**Compare against the filled quantity, not against the intent.** A partial fill makes the
position delta smaller than the intent by construction, so asserting against the intent
sends the engine `DEGRADED` on an ordinary event — and the M2 chaos test injects partial
fills deliberately. The intent is checked by the second assertion, which is the one that
catches an over-fill or a duplicate.

**Two different snapshots exist and must not be confused.**

| Snapshot | Taken at | Used for |
|---|---|---|
| `OrderIntent.position_before` | resolution / readback | the rule 22 clamp, and the readback |
| `positions_before` | the **commit keypress** | reconciliation layer 2, here |

Up to `gate_timeout_ms` (6s) separates them, and a fill on a resting order can land in
between. Reusing the resolution-time figure here would send a perfectly correct order to
`DEGRADED`. Key the position by the **contract** (exchange + tsym + product), never by the
underlying.

On mismatch: **`DEGRADED`**, loud repeating alarm, panel shows both numbers, engine refuses
new voice commands until acknowledged.

This is what stands between "you believe you're short and you're flat" and knowing. It costs
one extra API call per order.

### DEGRADED state

Sticky. Blocks any entry to `LISTENING` (the path is `IDLE → STAGED → LISTENING`; both
edges are refused). Cleared only by an explicit `ack_degraded` from the
panel, which requires a hold, not a tap. While degraded, the kill switch still works —
**always**.

## Kill switch

Two levels, both available at all times including from `DEGRADED`:

**Hotkey-only. Neither is a voice command** (`CLAUDE.md` rule 23): a destructive control
that must work while `DEGRADED` cannot run through the ASR path, because the ASR path may
be the thing that is broken.

| Level | Trigger | Action |
|---|---|---|
| **Cancel all** | `Cmd+Shift+.` | Cancel every open order. No confirmation — cancelling is safe. |
| **Zero out** | `Cmd+Shift+/` | Cancel all **and** square off every position. **Requires hold-to-confirm (1.5s).** |

`zero out` is destructive, so it gets a gate — but a short, loud, unmissable one, not the
normal readback flow. The distinction: cancelling open orders moves you toward flat and
needs no gate; squaring off positions is itself a set of trades and needs one.

Both log every order number they touch, and both run their own reconciliation pass
afterwards.

## Risk limits (`core/risk.py`)

Checked **before** the readback renders, so a blocked order never reaches the gate. All from
`staged.yaml`.

One exception to "before the gate": **the rate counters increment at submission, not at
resolution.** Their purpose is regulatory — bounding orders actually routed to the broker
— and a command that is cancelled or times out at the gate never reaches it. Counting
resolutions would let the trader burn the day's budget on cancelled commands while a loop
downstream of the gate went uncounted. The pre-gate check is advisory (it rejects early
when the budget is already spent); the authoritative increment is in `engine/execute.py`.

| Limit | Default | Behaviour on breach |
|---|---|---|
| `max_premium_per_order` | ₹2,00,000 | Reject |
| `max_premium_soft` | ₹30,000 | Allow, but force hold-to-commit |
| `max_underlying_notional_per_order` | ₹1,00,00,000 | Reject |
| `max_orders_per_day` | 40 | Reject |
| `max_orders_per_minute` | 6 | Reject (also keeps you far from any rate threshold) |
| `reject_cooloff` | 3 rejects in 60s → 120s lockout | Reject with countdown *(not built)* |
| `session_hours` | 09:15–15:30 IST, weekdays | Reject outside *(not built)* |
| `limit_sanity_pct` | 8% from LTP | Reject the limit price. **Skipped** when the quote is older than `max_quote_age_ms`; no quote at all is `NO_QUOTE` |

**Evaluation order is fixed** and must be, because a stage can breach more than one cap at
once and the trader needs the same answer every time: `session_hours` → `reject_cooloff` →
`max_orders_per_minute` → `max_orders_per_day` → `limit_sanity_pct` → `max_premium_per_order`
→ `max_underlying_notional_per_order`. The first breach wins and the rest are not
evaluated. `max_premium_soft` is not a rejection and is evaluated last, after everything
has passed, to set `friction`.

**The two notional caps are not independent, and choosing them carelessly makes one of
them dead code.** `underlying ÷ premium` is `strike ÷ price` — roughly 175× for a cheap OTM
option and 25× for a deep ITM one. Pick a pair where each can bind first. `zero-doctor`
prints how many lots each instrument can trade before a cap bites and fails outright if a
cap blocks even one lot. This check exists because the first pair chosen for this project
silently did exactly that.

Worked example of the trap, with the numbers:

| Cap pair | NIFTY 25000 CE @142.50 | NIFTY deep ITM @₹1,000 | Max premium per unit at 1 lot |
|---|---|---|---|
| premium ₹75,000 (the original) | underlying binds at 5 lots | **premium binds at 1 lot** | **₹1,000** — any ITM strike above that is untradeable |
| premium ₹2,00,000 (current) | underlying binds at 5 lots | premium binds at 2 lots | ₹2,666 |

₹1,000 is an ordinary price for a NIFTY ITM call, so the original pair would have failed
`zero-doctor` against the project's own example config. Both caps must stay reachable:
`underlying ÷ premium` is `strike ÷ price`, ~175x for a cheap OTM option and ~25x deep ITM,
so the pair has to straddle that range.

`max_orders_per_minute` at 6 is deliberately conservative. A human speaking commands cannot
legitimately exceed it, and anything that does is a bug in the software, not a trade.

## Regulatory — the SEBI framework in force from 1 April 2026

Facts to design around (**confirm the current position with Finvasia before building on
top of it** — the details below come from public commentary, not from the circular text):

- **A static IP registered with the broker is mandatory for API access.** Obtainable from an
  ISP or a VPS/cloud provider; commonly cited cost is around ₹1,500/year. This is a
  **prerequisite**, not a step — resolve it before writing the live adapter.
- **10 orders/second is the dividing line.** Below it, retail API users generally need no
  prior strategy approval or exchange registration. Above it, the strategy must be
  registered through the broker with the exchange and goes through an audit.
- **Market orders need a non-zero market-protection value.** Already handled above.
- **The rules apply to API-routed orders**, not to manual orders placed through the broker's
  own front end.

### How this project sits inside that

This system is a **human-in-the-loop order entry channel**, not a strategy: every order is
composed by a human utterance and authorized by a human keypress. But it is **routed through
the API**, so the API rules apply regardless of how manual it feels.

Practical consequences:

1. Get the static IP and register it. Running the engine on a home connection with a dynamic
   IP will simply not work.
2. Order rate is bounded by human speech (~6/minute in the config above), which is three
   orders of magnitude below the 10/s threshold. Keep the `max_orders_per_minute` limit
   enforced in code so that remains true even if something loops.
3. Do not add any feature that emits orders without a human keypress. Beyond being rule 1 of
   `CLAUDE.md`, it is the thing that would change this system's regulatory character.
4. **Ask Finvasia directly, in writing, before going live**, covering: static IP
   registration process, whether they require any algo/strategy registration for this usage
   pattern, their market-protection parameter semantics, and their API rate limits. Record
   the answers in `docs/broker-notes.md` in this repo.

None of this is legal advice — it's a compilation of public reporting, and the regulatory
detail may have moved. Confirm with the broker and, if the size warrants it, with someone
qualified.
