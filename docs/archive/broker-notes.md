> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# Broker notes — Finvasia Shoonya

**This file is a stub. Fill it before M5.** `docs/07-roadmap.md` blocks the live
milestone until the questions below have written answers from the broker.

Everything in `docs/05-execution.md` about the Shoonya API was compiled from public
documentation and may be stale. When the two disagree, what's recorded here — sourced
directly from the broker — wins.

---

## Questions to send Finvasia (in writing, keep the reply)

1. **Static IP.** What is the exact process to register a static IP against my API account?
   How long does it take, and how do I change it later? Is a VPS IP acceptable?

2. **Registration.** Does my usage pattern — a human speaking individual orders, each
   authorized by a keypress, routed through the API at well under one order per second —
   require any algo or strategy registration with the exchange under the framework in force
   from 1 April 2026? If yes, what does that process involve?

3. **Market protection.** What is the exact parameter name and semantics for market
   protection on `place_order`? If I instead send a `LMT` order banded around LTP, does
   that satisfy the requirement?

4. **Rate limits.** What are the documented per-second and per-day limits on order
   placement, order book queries and position queries? What happens on breach — throttle
   or block?

5. **Idempotency.** Is the `remarks` field reliably returned in `get_orderbook()` and
   `single_order_history()`? What is its maximum length and character set? Is there a
   broker-native idempotency key I should use instead?

6. **Session.** How long is `susertoken` valid? Is there a documented error code for
   expiry, and is concurrent login from one IP permitted?

7. **Symbol master and `tsym`.** Where is the daily symbol master file, and at what time
   is it published? **What is the exact `tsym` format for weekly and monthly index
   options** — the deleted implementation guessed `NIFTY24SEP2625000CE` and that guess has
   never been validated against the venue. This is the single item most likely to fail
   silently at go-live. Futures and equity formats too, for completeness.

8. **Position identity.** What exactly keys a position in `get_positions()` — exchange,
   tradingsymbol, product, token? Reconciliation layer 2 asserts a delta against that key,
   and `EXIT` is scoped to one contract rather than the underlying, so the key shape has to
   be exact. An `EXIT` that matched on the underlying would close the wrong strikes.

---

## Answers

_(paste replies here, with dates)_

---

## Verified API facts

_(as you confirm each item in `docs/05-execution.md` against the live docs or against
observed behaviour, record it here with the date — this becomes the trusted reference)_

| Item | Status | Verified on | Note |
|---|---|---|---|
| `login()` signature | unverified | | |
| `place_order()` parameter names | unverified | | |
| Product codes `I`/`C`/`M` | unverified | | |
| `remarks` round-trips in order book | unverified | | |
| Position endpoint name and shape | unverified | | |
| Current lot sizes for NIFTY / BANKNIFTY | unverified | | in `instruments.yaml` |
| `tsym` format for weekly/monthly index options | unverified | | **guessed, never validated — M5 blocker** |
| Position key shape (`get_positions()`) | unverified | | see Q8; `core.intent.ContractKey` assumes exch+tsym+product |
