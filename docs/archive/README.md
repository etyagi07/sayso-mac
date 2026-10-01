# Archive — nothing in here is current

Everything in this folder was written for ProjectZero's earlier plans: first
"voice composes the whole order", then the "staged order" model where the UI
held the contract. Both were superseded when the working **Sayso** engine
became the backbone (`sayso/`) and ProjectZero became the body kit (UI/UX) on
top of it.

Kept for reasoning and history only. Facts in here are often wrong: NIFTY lot
75 (it's 65), guessed symbol formats (real: `NIFTY29SEP26C23100`), the
QuickAuth/TOTP login (Sayso uses OAuth), and dozens of files that were never
built (`core/resolve.py`, `engine/*.py`, `asr/*.py`…).

**What's current:** `CLAUDE.md` (rules), `HANDOFF.md` (state), `docs/face-spec.md`
(what the face looks like), `docs/review-2026-09-30.md` (latest review and
decisions), `docs/user-guide.md`. Engine ideas once listed in
`ENGINE-ROADMAP.md` are in `engine-ideas.md` here.

## Index

| File | What it was | Salvaged into |
|---|---|---|
| `00-brief-as-given.md` | The trader's original UX brief (staged model) | the "attention, not speed" intent, in `face-spec.md` |
| `01-brief.md` | Problem, prior art, borrowed mechanics (aviation, open outcry, Bloomberg) | the thesis and positioning, in `face-spec.md` |
| `02-flow.md` | The staged-order model | nothing, since Sayso works differently |
| `03-architecture.md` | A ProjectZero engine, FSM, WebSocket protocol | the "dumb renderer over a state stream" idea |
| `03-command-grammar.md`, `04-resolution.md` | The first spoken grammar and resolver | Sayso solved this itself |
| `04-safety.md` | The confirm gate and failure modes | card rules and failure modes 1–3, in `face-spec.md` |
| `05-execution.md` | Broker notes (stale) | superseded by `sayso/README.md` "Notes on the Shoonya API" |
| `06-voice-and-ui.md` | ASR plan and widget spec | the widget rules, in `face-spec.md` |
| `07-roadmap.md` | Milestones for the unbuilt engine | superseded; see `engine-ideas.md` |
| `08-review.md`, `09-punchlist.md` | Audits of the staged model | — |
| `RECONCILIATION.md` | The 09-29 reconciliation of the old docs with the Sayso engine | superseded by `CLAUDE.md`, the reviews and `HANDOFF.md` |
| `10-design-brief.md` | Design brief and prototype prompt | the main source for `face-spec.md` |
| `broker-notes.md` | Unanswered questions for Finvasia | answered by `sayso/README.md` |
| `CLAUDE-staged-model.md` | The old rules file | replaced by the current `CLAUDE.md` |
| `order_intent-original.py`, `code/intent.py` | Contract types for both old models | Sayso's own preview/result dicts |
| `fixtures/*.yaml` | Golden test cases for the old models | Sayso's own 158 tests |
| `../../config/archive/*` | Config for the old models | — |
