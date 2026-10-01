# SUPERSEDED — archived 2026-09-29. Not current; written for ProjectZero's
# abandoned staged-order model. The engine is sayso/. Do not use.

"""
Canonical types for ProjectZero.

This file is the CONTRACT between stages. Copy it to `core/intent.py` at M0 and
treat changes to it as interface changes — every stage downstream depends on the
guarantee that an OrderIntent is complete and immutable.

Rule 6 of CLAUDE.md: an OrderIntent is either fully specified or it does not
exist. There is no partially-filled intent anywhere in the system.
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
    BUY = "BUY"
    SELL = "SELL"      # reduces a long; never flips to short
    SHORT = "SHORT"
    COVER = "COVER"    # reduces a short; never flips to long
    EXIT = "EXIT"      # closes the whole position; direction derived


class Product(StrEnum):
    MIS = "MIS"        # intraday        -> Shoonya 'I'
    CNC = "CNC"        # delivery        -> Shoonya 'C'
    NRML = "NRML"      # F&O carryforward-> Shoonya 'M'


class Instrument(StrEnum):
    EQ = "EQ"
    FUT = "FUT"
    OPT = "OPT"


class PriceType(StrEnum):
    LIMIT = "LIMIT"              # explicit price spoken
    PROTECTED_MARKET = "PROT"    # limit at LTP ± protection_pct — the DEFAULT
    # Bare MKT is deliberately absent. See CLAUDE.md rule 7.


class Provenance(StrEnum):
    """Where a field's value came from. Drives readback highlighting."""
    SPOKEN = "spoken"        # the human said it
    INFERRED = "inferred"    # a config default supplied it
    CLAMPED = "clamped"      # reduced to fit a position or a risk limit
    COMPUTED = "computed"    # derived (half of position, lots × lot_size)


class Band(StrEnum):
    RESOLVED = "resolved"
    CHALLENGE = "challenge"
    REJECT = "reject"


# ─────────────────────────────────────────────────────────────────────────────
# Field wrapper
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class Slot(Generic[T]):
    """A resolved value plus how it got there."""
    value: T
    provenance: Provenance
    note: str | None = None      # e.g. "clamped from 100 — position is 40"


# ─────────────────────────────────────────────────────────────────────────────
# The intent
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class OrderIntent:
    """A fully-specified, immutable order. Nothing partial ever gets this type."""

    command_id: str                 # ULID, minted at hotkey-down
    created_at: datetime

    side: Slot[Side]
    symbol_key: str                 # watchlist key, e.g. "HDFCBANK"
    tsym: str                       # broker trading symbol, e.g. "HDFCBANK-EQ"
    exch: str                       # "NSE" | "NFO" | ...
    instrument: Instrument

    quantity: Slot[int]             # SHARES for EQ; already lots × lot_size for FUT/OPT
    lots: Slot[int] | None          # set for derivatives, else None
    product: Slot[Product]
    price_type: Slot[PriceType]
    # the limit price actually sent; None never reaches the broker
    price: Slot[Decimal] | None

    # Context captured at resolution time, for the readback and for audit
    ltp: Decimal | None
    ltp_age_ms: int | None
    notional: Decimal               # quantity × (price or ltp)
    position_before: int            # signed, at the moment of resolution

    # Provenance of the transcript itself
    transcript_raw: str
    transcript_normalized: str
    asr_engine: str
    asr_agreement: bool | None      # None when only one engine returned

    @property
    def inferred_fields(self) -> list[str]:
        out: list[str] = []
        for name in ("side", "quantity", "product", "price_type"):
            slot: Slot[object] = getattr(self, name)
            if slot.provenance is not Provenance.SPOKEN:
                out.append(name)
        return out

    @property
    def is_derivative(self) -> bool:
        return self.instrument in (Instrument.FUT, Instrument.OPT)


# ─────────────────────────────────────────────────────────────────────────────
# The other two possible outcomes of resolution
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class Candidate:
    symbol_key: str
    alias_matched: str
    score: float


@dataclass(frozen=True, slots=True)
class Challenge:
    """An ambiguous symbol. The human must speak a check word."""
    command_id: str
    partial_side: Side
    candidates: list[Candidate]
    options: dict[str, str]         # check_word -> symbol_key
    reason: str                     # "ambiguous_alias" | "thin_margin" | "low_score"


@dataclass(frozen=True, slots=True)
class Rejection:
    command_id: str
    reason: str                     # machine-readable code
    detail: str                     # human-readable, shown in the widget
    candidates: list[Candidate] = field(default_factory=list)


Resolution = OrderIntent | Challenge | Rejection
"""core.resolve.resolve() returns exactly one of these three. Nothing else."""


# ─────────────────────────────────────────────────────────────────────────────
# Broker boundary
# ─────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True, slots=True)
class BrokerOrder:
    """What actually goes on the wire. Built from OrderIntent by the adapter."""
    tag: str                        # == command_id, goes in Shoonya `remarks`
    buy_or_sell: str                # 'B' | 'S'
    product_type: str               # 'I' | 'C' | 'M'
    exchange: str
    tradingsymbol: str
    quantity: int
    price_type: str                 # 'LMT' | 'MKT' | ...
    price: float
    retention: str = "DAY"
    discloseqty: int = 0
    amo: str = "NO"


class OrderState(StrEnum):
    PENDING = "PENDING"
    OPEN = "OPEN"
    COMPLETE = "COMPLETE"
    REJECTED = "REJECTED"
    CANCELED = "CANCELED"
    UNKNOWN = "UNKNOWN"     # triggers find-by-tag, then DEGRADED


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
    filled_qty: int
    avg_price: Decimal | None
    rejection_reason: str | None
    raw: dict[str, object]


@dataclass(frozen=True, slots=True)
class Position:
    tsym: str
    exch: str
    product: Product
    net_qty: int                    # signed
    avg_price: Decimal
