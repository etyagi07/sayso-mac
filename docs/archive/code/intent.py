# SUPERSEDED — archived 2026-09-29. Not current; written for ProjectZero's
# abandoned staged-order model. The engine is sayso/. Do not use.

"""
core/intent.py — THE CONTRACT.

The only file that may call itself the contract. Every other module in `core/`
consumes these types; nothing here imports from `asr/`, `audio/`, `broker/`,
`engine/`, `ui/` or `cli/` (CLAUDE.md rule 16).

Three documents referenced this file before it existed. It encodes, in types,
the decisions that were previously only prose:

  rule 6   an OrderIntent is fully specified or it does not exist
  rule 7   PriceType has no MKT member, so a bare market order is not constructible
  rule 22  SELL reduces before it opens; EXIT is scoped to the staged contract
  CLAUDE.md E   the qualifier is mandatory on options by default

Python 3.11+. Deliberately logic-free: validation that a value is *structurally*
impossible lives here; every decision about what a command *means* lives in
core/resolve.py, which is pure and testable.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from enum import StrEnum
from typing import Generic, TypeVar

T = TypeVar("T")


# ─────────────────────────────────────────────────────────────────────────────
# Enums
# ─────────────────────────────────────────────────────────────────────────────

class Side(StrEnum):
    """What the verb means. SHORT and COVER are deliberately absent. Direction against
    the live position is derived, not spoken: a command that opposes the position
    reduces it and stops at flat, one that agrees with it adds (rule 22)."""
    BUY = "BUY"
    SELL = "SELL"
    EXIT = "EXIT"      # close the whole position in the staged CONTRACT


class Intent(StrEnum):
    """What a resolved order actually does to the book. Derived, never spoken —
    it exists so the readback and the risk check can treat writing an option
    differently from closing a long. OPEN_* covers both opening from flat and
    adding to a position in the same direction; CLOSE_* always clamps at flat
    and never crosses it (rule 22)."""
    OPEN_LONG = "OPEN_LONG"
    CLOSE_LONG = "CLOSE_LONG"
    OPEN_SHORT = "OPEN_SHORT"     # writing or adding to a short — always hold-to-commit
    CLOSE_SHORT = "CLOSE_SHORT"


class OptionType(StrEnum):
    CE = "CE"
    PE = "PE"


class Instrument(StrEnum):
    OPT = "OPT"
    FUT = "FUT"
    EQ = "EQ"          # allowed by the model, never exercised — roadmap gap


class Product(StrEnum):
    MIS = "MIS"        # intraday         -> Shoonya 'I'
    CNC = "CNC"        # delivery         -> Shoonya 'C'
    NRML = "NRML"      # F&O carryforward -> Shoonya 'M'


class PriceType(StrEnum):
    """No MKT member. A bare market order must not be constructible (rule 7);
    PROTECTED is a limit banded around LTP and is disabled for options."""
    LIMIT = "LIMIT"
    PROTECTED = "PROTECTED"


class Provenance(StrEnum):
    """Where a field's value came from. Drives readback marking."""
    SPOKEN = "spoken"       # the human said it
    STAGED = "staged"       # the human set it in the UI
    INFERRED = "inferred"   # a config default supplied it
    CLAMPED = "clamped"     # reduced to fit the live position or a risk cap
    COMPUTED = "computed"   # derived (EXIT quantity, lots x lot_size)


class Friction(StrEnum):
    NORMAL = "normal"       # tap to commit
    HOLD = "hold"           # hold to commit: high premium, EXIT, or OPEN_SHORT


# ─────────────────────────────────────────────────────────────────────────────
# Field wrapper
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class Slot(Generic[T]):
    value: T
    provenance: Provenance
    note: str | None = None     # e.g. "clamped from 150 — long 75"


# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — what the UI configured
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class StagedOrder:
    """The parameters the trader set by hand, and the only thing a voice command
    can act on. Enforces rule 6 one stage early: an option stage without expiry,
    strike and option type raises rather than existing."""

    staged_at: datetime
    instrument_key: str          # e.g. "NIFTY" — a key in instruments.yaml
    exch: str
    instrument: Instrument
    lots: int
    lot_size: int
    product: Product
    tick_size: Decimal

    expiry: datetime | None = None
    strike: int | None = None
    opt: OptionType | None = None
    limit: Decimal | None = None
    tsym: str | None = None      # built by the adapter; UNVALIDATED format, M5 blocker

    def __post_init__(self) -> None:
        if self.lots < 1:
            raise ValueError("lots must be >= 1")
        if self.lot_size < 1:
            raise ValueError("lot_size must be >= 1")
        if self.instrument is Instrument.OPT:
            missing = [n for n in ("expiry", "strike", "opt") if getattr(self, n) is None]
            if missing:
                raise ValueError(f"option stage missing {missing} (CLAUDE.md rule 6)")
            if self.limit is None:
                # allow_protected_market_options is false; an option with no limit
                # cannot produce a price and must reject before the gate, not at it.
                raise ValueError("option stage requires an explicit limit (rule 7)")

    @property
    def quantity(self) -> int:
        return self.lots * self.lot_size

    def age_ms(self, now: datetime) -> int:
        return int((now - self.staged_at).total_seconds() * 1000)

    def is_expired(self, now: datetime, ttl_s: int) -> bool:
        return self.age_ms(now) > ttl_s * 1000


# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — what was said
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class VoiceCommand:
    """The result of an EXACT lookup in the generated phrase table. No scores,
    no bands, no near misses: a phrase is in the table or the utterance rejects."""
    phrase: str                       # the normalized phrase that matched, verbatim
    side: Side
    qualifier: OptionType | None      # an ASSERTION about the stage, not a selector


# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 — the resolved order
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class OrderIntent:
    """Fully specified or it does not exist (rule 6)."""

    command_id: str                  # ULID, minted at hotkey-down
    created_at: datetime

    side: Slot[Side]
    intent: Slot[Intent]
    instrument_key: str
    tsym: str
    exch: str
    instrument: Instrument
    expiry: Slot[datetime] | None
    strike: Slot[int] | None
    opt: Slot[OptionType] | None

    quantity: Slot[int]              # in units, lots already multiplied out
    lots: Slot[int] | None
    product: Slot[Product]
    price_type: Slot[PriceType]
    price: Slot[Decimal]             # never None — rule 7

    # Context captured at resolution, for the readback and the audit trail
    ltp: Decimal | None
    ltp_age_ms: int | None
    premium_notional: Decimal        # quantity x price — what leaves the account
    underlying_notional: Decimal     # quantity x strike — the delta-1 exposure
    position_before: int             # signed, in the CONTRACT, AT RESOLUTION.
                                     # Drives the rule 22 clamp only. Reconciliation
                                     # uses its own snapshot taken at commit — up to
                                     # gate_timeout_ms separates the two and a fill
                                     # can land in between. Do not reuse this one.
    stage_age_ms: int

    transcript_raw: str
    transcript_normalized: str
    matched_phrase: str
    asr_engine: str
    asr_agreement: bool | None       # None when only one engine returned

    @property
    def marked_fields(self) -> list[str]:
        """Anything the human did not say or set themselves."""
        out: list[str] = []
        for name in ("side", "intent", "quantity", "product", "price_type", "price"):
            slot = getattr(self, name)
            if slot is not None and slot.provenance not in (
                Provenance.SPOKEN, Provenance.STAGED
            ):
                out.append(name)
        return out

    @property
    def intrinsically_unusual(self) -> bool:
        """The part of "unusual" that the intent alone can decide.

        NOT the whole answer. `Readback.unusual` is authoritative and is

            intent.intrinsically_unusual or friction is Friction.HOLD

        because friction also depends on config (`max_premium_soft`), which core.intent
        does not see. An order over the soft cap must change the card's shape, or the
        most expensive order class is the one that looks ordinary
        (docs/04-safety.md, anti-pattern-matching).
        """
        return (
            bool(self.marked_fields)
            or self.side.value is Side.EXIT
            or self.intent.value is Intent.OPEN_SHORT
        )


# ─────────────────────────────────────────────────────────────────────────────
# The other outcomes. resolve() returns exactly one of these three.
# ─────────────────────────────────────────────────────────────────────────────

class RejectReason(StrEnum):
    NO_STAGE = "no_stage"
    NO_QUOTE = "no_quote"            # no LTP at all, as distinct from a stale one
    STAGE_EXPIRED = "stage_expired"
    UNKNOWN_PHRASE = "unknown_phrase"
    QUALIFIER_REQUIRED = "qualifier_required"
    QUALIFIER_MISMATCH = "qualifier_mismatch"
    ASR_DISAGREEMENT = "asr_disagreement"
    ASR_UNAVAILABLE = "asr_unavailable"
    NO_POSITION = "no_position"
    NO_PRICE = "no_price"
    STALE_QUOTE = "stale_quote"
    LIMIT_SANITY = "limit_sanity"
    MAX_PREMIUM = "max_premium"
    MAX_UNDERLYING = "max_underlying"
    RATE_LIMIT = "rate_limit"
    COOLOFF = "cooloff"
    OUTSIDE_SESSION = "outside_session"
    DEGRADED = "degraded"


@dataclass(frozen=True, slots=True)
class Rejection:
    command_id: str
    reason: RejectReason
    detail: str                      # human-readable, rendered in the UI
    context: dict[str, str] = field(default_factory=dict)


Resolution = OrderIntent | Rejection
"""core.resolve.resolve() returns one of these. There is no third state: the
qualifier is checked inside the same utterance, so nothing is ever pending."""


# ─────────────────────────────────────────────────────────────────────────────
# Readback — what core/readback.py returns, and what goes on the wire verbatim
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class Readback:
    headline: str                    # "BUY  NIFTY 25000 CE"
    lines: list[str]
    marks: list[str]                 # names of marked_fields, for emphasis
    warnings: list[str]              # "single ASR engine", "quote 7s old"
    unusual: bool
    friction: Friction
    speech: str                      # produced always, EMITTED only after commit
    expires_ms: int


# ─────────────────────────────────────────────────────────────────────────────
# Broker boundary
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class BrokerOrder:
    tag: str                         # == command_id, goes in Shoonya `remarks`
    buy_or_sell: str                 # 'B' | 'S'
    product_type: str                # 'I' | 'C' | 'M'
    exchange: str
    tradingsymbol: str
    quantity: int
    price_type: str                  # 'LMT' only — see PriceType
    price: float
    retention: str = "DAY"
    discloseqty: int = 0
    amo: str = "NO"


class OrderState(StrEnum):
    PENDING = "PENDING"
    OPEN = "OPEN"
    PARTIAL = "PARTIAL"              # some filled, remainder still resting — NOT terminal
    COMPLETE = "COMPLETE"
    REJECTED = "REJECTED"
    CANCELED = "CANCELED"            # includes a partial whose remainder was cancelled
    UNKNOWN = "UNKNOWN"              # triggers find-by-tag, then DEGRADED

    @property
    def is_terminal(self) -> bool:
        return self in (OrderState.COMPLETE, OrderState.REJECTED, OrderState.CANCELED)


@dataclass(frozen=True, slots=True)
class Submission:
    order_no: str | None
    tag: str
    accepted: bool
    raw: dict[str, object]


@dataclass(frozen=True, slots=True)
class OrderStatus:
    order_no: str
    tag: str | None
    state: OrderState
    filled_qty: int                  # reconciliation layer 2 asserts against THIS
    avg_price: Decimal | None
    rejection_reason: str | None
    raw: dict[str, object]


@dataclass(frozen=True, slots=True)
class ContractKey:
    """Positions are keyed by contract, never by underlying — EXIT on a staged
    25000 CE must not touch a 25100 CE (rule 22)."""
    exch: str
    tsym: str
    product: Product


@dataclass(frozen=True, slots=True)
class Position:
    key: ContractKey
    net_qty: int                     # signed
    avg_price: Decimal
