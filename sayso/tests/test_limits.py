"""Each account's own limits: today's defaults, lowered freely, raised only
after a yes. Offline; state goes to a temp folder."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import _isolated  # noqa: E402,F401  (state in a temp folder, never the live one)

from voice import safety  # noqa: E402


def fresh(fn):
    def run():
        safety.reset_limits()
        try:
            fn()
        finally:
            safety.reset_limits()
    run.__name__ = fn.__name__
    return run


@fresh
def test_the_defaults_are_todays_limits():
    assert safety.effective() == safety.effective(safety.DEFAULTS)
    assert safety.LIMITS.max_order_value == 15000.0
    assert safety.LIMITS.max_lots == {"NIFTY": 10, "BANKNIFTY": 3, "SENSEX": 10}


@fresh
def test_lowering_needs_no_confirmation():
    now = safety.set_limits({"max_order_value": 5000, "max_lots": {"BANKNIFTY": 1}})
    assert now["max_order_value"] == 5000.0 and now["max_lots"]["BANKNIFTY"] == 1
    assert safety.LIMITS.max_order_value == 5000.0       # in force at once


@fresh
def test_raising_needs_a_yes():
    try:
        safety.set_limits({"max_order_value": 50000})
        raise AssertionError("raised without confirmation")
    except safety.NeedsConfirmation as e:
        assert "max_order_value" in str(e)
    assert safety.LIMITS.max_order_value == 15000.0       # unchanged
    safety.set_limits({"max_order_value": 50000}, confirmed=True)
    assert safety.LIMITS.max_order_value == 50000.0


@fresh
def test_a_raised_lot_cap_needs_a_yes_too():
    try:
        safety.set_limits({"max_lots": {"NIFTY": 20}})
        raise AssertionError("raised without confirmation")
    except safety.NeedsConfirmation:
        pass


@fresh
def test_limits_are_kept_per_account_and_survive_a_restart():
    safety.set_limits({"max_orders_per_day": 5})
    safety.LIMITS.max_orders_per_day = 999                # as if freshly imported...
    safety.load_saved()                                   # ...and loaded again
    assert safety.LIMITS.max_orders_per_day == 5


@fresh
def test_nonsense_is_refused_and_changes_nothing():
    for bad in ({"max_order_value": 0}, {"max_order_value": -5},
                {"max_order_value": "lots"}, {"max_order_value": True},
                {"max_order_value": float("nan")}, {"max_order_value": float("inf")},
                {"max_quantity": 1.5}, {"max_lots": {"NIFTY": 0}},
                {"max_lots": {"FINNIFTY": 2}}, {"max_lots": 5},
                {"allow_marketable_limits": False}, {"unknown": 1}):
        try:
            safety.set_limits(bad, confirmed=True)
            raise AssertionError(f"accepted {bad}")
        except ValueError:
            pass
    assert safety.effective() == safety.effective(safety.DEFAULTS)


@fresh
def test_a_reset_goes_back_to_the_defaults():
    safety.set_limits({"max_value_per_day": 10000})
    safety.reset_limits()
    assert safety.effective() == safety.effective(safety.DEFAULTS)


@fresh
def test_status_shows_every_limit_and_the_defaults():
    safety.set_limits({"max_orders_per_day": 7})
    s = safety.status()
    assert s["limits"]["max_orders_per_day"] == 7
    assert s["default_limits"]["max_orders_per_day"] == 20
    assert "value_remaining" in s


@fresh
def test_index_names_are_said_the_way_traders_say_them():
    try:
        safety.check_option("X", "BANKNIFTY", 5, 30, 100.0)
        raise AssertionError("not refused")
    except safety.Rejected as e:
        assert "Bank Nifty" in str(e) and "BANKNIFTY" not in str(e), str(e)


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_"):
            continue
        try:
            fn()
            passed += 1
            print(f"ok   {name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {name}: {type(e).__name__}: {e}")
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
