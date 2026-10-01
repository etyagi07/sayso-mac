> **SUPERSEDED — archived 2026-09-29.** Not current. Written for ProjectZero's
> abandoned staged-order model. The engine is `sayso/`; the body kit's rules are
> `CLAUDE.md`; the current face spec is `docs/face-spec.md`. Facts in here (lot 75,
> symbol formats, QuickAuth/TOTP login, file paths) may be wrong.

# 00 — The brief, as given

Verbatim product brief handed to Claude Code, from which `docs/02-flow.md` and the
staged-order model were derived. `02-flow.md` cites it repeatedly ("the brief's
instruction 5", "the brief this mode came from asks for a persistent listening state")
and it was not in the repository, so those citations could not be checked. It is here now.

**This is a UX brief, not a safety brief.** It describes intended behaviour and says
nothing about reconciliation, idempotency, staleness, position semantics or the regulatory
framework. Everything in `docs/04-safety.md` and `docs/05-execution.md` is an addition
made on top of it, and some of those additions **depart from what this document asks for**.
Those departures are catalogued in `docs/08-review.md` section F. Do not treat them as
settled just because they are written down.

---

I'm building a voice-based options trading interface. Before making any code changes,
understand the product flow below and treat it as the intended UX/behavior.

## Core Idea

The goal is to let a trader place and manage options orders using voice commands without
having to look away from their trading charts.

The UI still provides the visual/manual controls needed to configure an order, but once the
order parameters are set, the system listens for a voice command such as:

- "Buy"
- "Sell"
- "Buy Call"
- "Sell Call"
- "Buy Put"
- "Sell Put"
- "Exit"
- Other relevant trading commands/variations

The voice command should trigger the corresponding action using the parameters already
configured in the interface.

## Order Setup Flow

The trader manually selects/configures:

1. **Instrument**
   - Example: an options underlying/instrument.
   - Instrument selection can be manual initially.
   - Autocomplete/search can be added to make selection faster.
2. **Strike Price**
   - The trader selects the required strike.
3. **Quantity**
   - The trader specifies the quantity.

These parameters remain visible in the UI so the trader always knows what the voice command
will act on.

Conceptually:

```
Instrument + Strike Price + Quantity → Voice Command → Order Action
```

For example:

```
NIFTY + 25,000 CE + 75 quantity → "Buy"  → Execute Buy Order
NIFTY + 25,000 PE + 75 quantity → "Sell" → Execute Sell Order
```

## Important UX Concept

This is NOT intended to be a traditional BBO-style workflow.

The system should instead be in a state where it is **waiting/listening** for the trader's
voice command after the relevant order parameters have been configured.

The trader should not need to constantly interact with buttons or move their attention away
from the chart.

The voice interaction is therefore the primary trigger for execution.

## Voice Command Handling

The command parser should understand natural variations rather than requiring one exact
phrase.

For example, commands could include:

- "Buy", "Buy this", "Buy call", "Buy the call"
- "Sell", "Sell this", "Sell put", "Sell the put"
- "Exit", "Close", "Close position"
- etc.

The exact command vocabulary should be designed **systematically** rather than hard-coded
randomly.

The system should distinguish between: BUY · SELL · EXIT/CLOSE · CALL · PUT · potential
future commands/actions.

The architecture should make it easy to add additional voice commands later.

## Confirmation / Feedback

After a command is recognized and the action is executed, the system should provide BOTH:

**Visual feedback** — order/action status, what was executed, instrument, strike, quantity,
buy/sell direction, success/failure state.

**Audio feedback** — e.g. "Bought 75 quantity NIFTY 25,000 Call." or "Sell order executed."

The audio feedback is important because the trader may still be looking at their chart
rather than the application UI.

## Safety / Ambiguity

Do not blindly execute an order if the voice command is ambiguous or incomplete.

For example, if the system cannot confidently determine the intended action, it should ask
for clarification or use a safe non-execution state.

The system should also make it clear which configured instrument/strike/quantity the
command will affect.

Potentially dangerous actions such as EXIT should be handled explicitly and audibly/visually
confirmed according to the application's execution model.

## Design Principle

The product should feel like:

```
Configure → Listen → Speak → Execute → Hear/See Confirmation
```

rather than:

```
Configure → Click multiple controls → Submit → Check result
```

The entire purpose is to reduce interaction friction for traders who need to maintain
visual attention on charts.

## Development Instructions

1. First understand the existing codebase and architecture.
2. Do not redesign the entire application unless necessary.
3. Preserve existing functionality.
4. Treat the voice-command layer as a modular component.
5. Keep the command interpretation separate from the actual order-execution layer.
6. Make the system extensible so additional commands and order types can be added later.
7. Do not assume that "Buy" or "Sell" alone necessarily defines every possible order type;
   use the currently configured UI state and command context to determine the intended
   action.
8. Provide clear visual and audio feedback for recognized actions.
9. Handle ambiguous/unrecognized commands safely.
10. Before implementing major architectural changes, explain what you found in the existing
    codebase and how you intend to integrate this flow.

The immediate goal is to understand and implement the voice-driven order interaction flow,
while keeping the architecture flexible for future trading functionality.
