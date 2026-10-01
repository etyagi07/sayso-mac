"""Hard limits enforced in code, regardless of what was said or parsed.

This layer exists because every other layer can be wrong: ASR mishears,
the parser misreads, a number is misheard. These checks are the last thing
between a misunderstanding and a trade, so they are deliberately dumb,
explicit, and fail-closed.
"""

import json
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

# Daily counters must survive a restart, or the caps mean nothing: quitting
# and relaunching would hand you a fresh allowance.
from shoonya import profile

# Per account: each has its own allowance.
STATE_FILE = profile.limits_file()


@dataclass
class Limits:
    # Equity: any stock in voice.stocks (the Nifty 50, plus Yes Bank).
    # Small caps - the client trades index options, not stocks. Big enough
    # for one share of any Nifty 50 name; some trade above Rs 10,000.
    max_order_value: float = 15000.0
    max_quantity: int = 1000
    # Shoonya has no MKT order type; "at market" is a limit priced through
    # the touch. This flag is kept only to name that explicitly.
    allow_marketable_limits: bool = True
    max_orders_per_day: int = 20
    max_value_per_day: float = 50000.0

    @property
    def allowlist(self):
        from voice import stocks
        return stocks.symbols()

    # --- options -------------------------------------------------------
    # Lot caps per index. With no premium or order-value cap, these are the
    # only automatic limit on size - what stops a misheard "twenty" for
    # "two" becoming a real position. BANKNIFTY is tighter because it has
    # no weekly contract, so its monthly lots are the most expensive.
    # They cap the damage from a misheard command; they are NOT a view on
    # what is a sensible trade.
    max_lots: dict = field(default_factory=lambda: {
        "NIFTY": 10, "BANKNIFTY": 3, "SENSEX": 10})
    # No premium-per-unit cap: it blocked every BANKNIFTY at-the-money
    # trade. No per-order value cap either - the client sizes his own
    # trades, and the confirmation screen spells out lots, units and total.
    max_premium_per_unit: float = None
    max_option_order_value: float = None
    max_option_orders_per_day: int = 10

    @property
    def option_allowlist(self):
        return set(self.max_lots)


LIMITS = Limits()
DEFAULTS = Limits()          # what every account starts with

# What a trader may set for their own account, and the type of each. The
# per-index lot caps are set as one dict. Anything else stays fixed.
EDITABLE = {"max_order_value": float, "max_quantity": int,
            "max_orders_per_day": int, "max_value_per_day": float,
            "max_option_orders_per_day": int, "max_lots": dict}


class NeedsConfirmation(ValueError):
    """Raising a limit lets bigger orders through: the human must say yes."""


def effective(limits=None):
    """The editable limits in force, as plain data."""
    limits = limits or LIMITS
    return {k: (dict(getattr(limits, k)) if k == "max_lots" else getattr(limits, k))
            for k in EDITABLE}


def _stored():
    try:
        data = json.loads(profile.account_file().read_text())
        return data.get("limits") or {}
    except (OSError, ValueError, AttributeError):
        return {}


def _apply(values, onto):
    for key, kind in EDITABLE.items():
        if key not in values:
            continue
        if kind is dict:
            merged = dict(DEFAULTS.max_lots)
            merged.update({k: int(v) for k, v in values[key].items()
                           if k in DEFAULTS.max_lots})
            setattr(onto, key, merged)
        else:
            setattr(onto, key, kind(values[key]))


def load_saved():
    """This account's own limits, over the defaults. A stored value that
    isn't valid is ignored, never trusted."""
    fresh = Limits()
    try:
        _apply(_validated(_stored()), fresh)
    except ValueError:
        pass
    _apply(effective(fresh), LIMITS)


def _validated(changes):
    clean = {}
    for key, value in (changes or {}).items():
        if key not in EDITABLE:
            raise ValueError(f"{key} can't be changed")
        if EDITABLE[key] is dict:
            if not isinstance(value, dict):
                raise ValueError("lots must be given per index")
            lots = {}
            for index, n in value.items():
                if index not in DEFAULTS.max_lots:
                    raise ValueError(f"{index} isn't an option index here")
                if isinstance(n, bool) or int(n) != n or int(n) < 1:
                    raise ValueError("a lot cap must be a whole number, at least 1")
                lots[index] = int(n)
            clean[key] = lots
            continue
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or value != value or value in (float("inf"), float("-inf"))):
            raise ValueError(f"{key} must be a number")
        if EDITABLE[key] is int and int(value) != value:
            raise ValueError(f"{key} must be a whole number")
        if value <= 0:
            raise ValueError(f"{key} must be above zero")
        clean[key] = EDITABLE[key](value)
    return clean


def set_limits(changes, confirmed=False):
    """Change this account's limits. Lowering is immediate; raising any
    limit needs confirmed=True (the app asks "are you sure?"). Returns the
    limits now in force."""
    clean = _validated(changes)
    now = effective()
    raised = []
    for key, value in clean.items():
        if key == "max_lots":
            raised += [f"{i} lots" for i, n in value.items() if n > now["max_lots"].get(i, 0)]
        elif value > now[key]:
            raised.append(key)
    if raised and not confirmed:
        raise NeedsConfirmation(", ".join(raised))
    try:
        data = json.loads(profile.account_file().read_text())
    except (OSError, ValueError):
        data = {}
    stored = dict(data.get("limits") or {})
    stored.update(clean)
    data["limits"] = stored
    from shoonya.client import _write_private
    _write_private(profile.account_file(), json.dumps(data, indent=2))
    _apply(clean, LIMITS)
    return effective()


def reset_limits():
    """Back to the defaults (lowering or raising, as it happens)."""
    try:
        data = json.loads(profile.account_file().read_text())
    except (OSError, ValueError):
        data = {}
    data.pop("limits", None)
    from shoonya.client import _write_private
    _write_private(profile.account_file(), json.dumps(data, indent=2))
    _apply(effective(DEFAULTS), LIMITS)
    return effective()

load_saved()


def _blank(date_=None):
    return {"date": date_,
            "equity": {"orders": 0, "value": 0.0},
            "options": {"orders": 0, "value": 0.0}}


def _load():
    """Counters are per-segment: equity and options have very different
    caps, so one pot means a single option order exhausts a whole day of
    equity allowance."""
    try:
        data = json.loads(STATE_FILE.read_text())
        state = _blank(data.get("date"))
        for seg in ("equity", "options"):
            row = data.get(seg) or {}
            state[seg] = {"orders": int(row.get("orders", 0)),
                          "value": float(row.get("value", 0.0))}
        return state
    except (OSError, ValueError, TypeError):
        return _blank()


def _save(state):
    try:
        STATE_FILE.write_text(json.dumps({**state, "date": str(state["date"])}))
    except OSError:
        pass  # Never let bookkeeping block a legitimate trade.


_spent_today = _load()


class Rejected(Exception):
    """A limit said no. The message is meant to be read aloud."""


def _today_counters(segment="equity"):
    today = str(date.today())
    if _spent_today["date"] != today:
        _spent_today.update(_blank(today))
        _save(_spent_today)
    return _spent_today[segment]


def _spoken(index):
    """'Bank Nifty', never 'BANKNIFTY', in anything shown or said."""
    try:
        from shoonya import underlyings
        return underlyings.get(index).spoken
    except Exception:
        return index


def check(symbol, quantity, price, price_type, limits=LIMITS):
    """Raise Rejected if this order breaches any limit. Returns the value."""
    # Strip the series suffix, not everything after the first hyphen - that
    # turned BAJAJ-AUTO-EQ into BAJAJ.
    base = symbol.upper().removesuffix("-EQ")

    if base not in limits.allowlist:
        raise Rejected(f"{base} isn't in the stock list - only Nifty 50 "
                       f"stocks can be traded.")

    if price_type == "MKT":
        raise Rejected("Shoonya does not accept market orders; "
                       "this should have been priced as a limit.")

    if quantity <= 0:
        raise Rejected(f"Quantity {quantity} is not a valid order size.")
    if quantity > limits.max_quantity:
        raise Rejected(
            f"Quantity {quantity} exceeds the per-order cap of "
            f"{limits.max_quantity} shares."
        )

    if price is None:
        raise Rejected("No price available to value this order against.")

    value = round(quantity * price, 2)
    if value > limits.max_order_value:
        raise Rejected(
            f"That order is worth {value:.2f} rupees, over the "
            f"{limits.max_order_value:.0f} rupee per-order limit."
        )

    counters = _today_counters("equity")
    if counters["orders"] >= limits.max_orders_per_day:
        raise Rejected(
            f"Daily order limit reached ({limits.max_orders_per_day} orders)."
        )
    if counters["value"] + value > limits.max_value_per_day:
        raise Rejected(
            f"That would take today's traded value to "
            f"{counters['value'] + value:.2f}, over the "
            f"{limits.max_value_per_day:.0f} rupee daily cap."
        )

    return value


def check_option(tsym, underlying, lots, lot_size, price, limits=LIMITS):
    """Limits for an option order. Returns (total_value, units)."""
    underlying = underlying.upper()
    if underlying not in limits.option_allowlist:
        raise Rejected(
            f"{_spoken(underlying)} options are not enabled. Only "
            f"{', '.join(_spoken(u) for u in sorted(limits.option_allowlist))} "
            f"can be traded."
        )
    if lots <= 0:
        raise Rejected(f"{lots} lots is not a valid order size.")
    cap = limits.max_lots.get(underlying)
    if cap is not None and lots > cap:
        raise Rejected(
            f"{lots} lots exceeds the {_spoken(underlying)} cap of {cap} lot"
            f"{'s' if cap != 1 else ''} per order."
        )
    if price is None:
        raise Rejected("No price available to value this option against.")
    if (limits.max_premium_per_unit is not None
            and price > limits.max_premium_per_unit):
        raise Rejected(
            f"Premium {price:.2f} is above the {limits.max_premium_per_unit:.0f} "
            f"per-unit limit - that contract is too expensive to trade here."
        )

    units = lots * lot_size
    value = round(units * price, 2)
    if (limits.max_option_order_value is not None
            and value > limits.max_option_order_value):
        raise Rejected(
            f"That order is worth {value:,.2f} rupees, over the "
            f"{limits.max_option_order_value:,.0f} rupee option limit."
        )

    counters = _today_counters("options")
    if counters["orders"] >= limits.max_option_orders_per_day:
        raise Rejected(
            f"Daily option order limit reached "
            f"({limits.max_option_orders_per_day} orders)."
        )
    return value, units


def record(value, segment="equity"):
    """Count an order that actually reached the market.

    Rejected orders must not count - they consumed no capital, and an
    allowance spent on trades that never happened is just lost capacity.
    """
    counters = _today_counters(segment)
    counters["orders"] += 1
    counters["value"] = round(counters["value"] + value, 2)
    _save(_spent_today)


def status():
    eq, op = _today_counters("equity"), _today_counters("options")
    return {
        "stocks": len(LIMITS.allowlist),
        "max_order_value": LIMITS.max_order_value,
        "marketable_limits": LIMITS.allow_marketable_limits,
        "orders_today": eq["orders"],
        "value_today": eq["value"],
        "orders_remaining": LIMITS.max_orders_per_day - eq["orders"],
        "option_orders_today": op["orders"],
        "option_value_today": op["value"],
        "option_orders_remaining": (LIMITS.max_option_orders_per_day
                                    - op["orders"]),
        "option_allowlist": sorted(LIMITS.option_allowlist),
        "max_lots": dict(LIMITS.max_lots),
        "max_premium_per_unit": LIMITS.max_premium_per_unit,
        "max_option_order_value": LIMITS.max_option_order_value,
        # Everything a trader can change, what it was by default, and what
        # is left of the daily allowances.
        "limits": effective(),
        "default_limits": effective(DEFAULTS),
        "value_remaining": round(LIMITS.max_value_per_day - eq["value"], 2),
    }
