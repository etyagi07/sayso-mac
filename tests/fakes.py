"""
The scripted engine the bridge tests run on: the real bridge Engine code,
with Sayso's agent, broker, mic and speech replaced by a script. Test-only:
no build ships it, and the app has no demo mode. Nothing is sent anywhere.
"""

from __future__ import annotations

import json
import os
import secrets
import threading
import time
from types import SimpleNamespace

from bridge import Bus, Engine


class FakeAgent:
    """Stands in for voice/agent.py: same handle(transcript, confirm)
    contract, scripted answers. Words in the transcript pick the script:
    'which'/'buy call' asks a question, 'funds' answers a query, 'exit'
    closes, 'reject'/'unknown'/'rest' pick the outcome, 'boom' fails before
    the card and 'boom after' fails after the order is sent."""

    PENDING_SECONDS = 30

    def __init__(self, delay: float = 0.9):
        self.delay = delay

    @staticmethod
    def friendly(symbol):
        return "Nifty 29 Sep 23150 call" if symbol.startswith("NIFTY") else symbol

    def handle(self, said, confirm=None):
        time.sleep(self.delay / 3)
        s = said.lower().strip()
        if s in ("buy call", "buy put") or "which" in s:
            return {"speak": "Which index for that call - Nifty, Bank Nifty or Sensex?",
                    "blocked": True, "needs_answer": "underlying"}
        if "funds" in s:
            return {"speak": "You have 12345.67 rupees available.",
                    "data": {"available": 12345.67}}
        if s.startswith("boom") and "after" not in s:
            raise RuntimeError("simulated failure before any card")
        exit_ = s.startswith("exit")
        lots = 2 if "two lots" in s else 1
        preview = {
            "action": "EXIT SELL" if exit_ else ("SELL" if s.startswith("sell") else "BUY"),
            "symbol": "NIFTY29SEP26C23150", "quantity": 65 * lots,
            "lots": None if exit_ else lots,
            "price": 72.7, "ltp": 72.55, "at_market": True,
            "bid": 72.5, "ask": 72.6, "tick": 0.05,
            "lower_circuit": 0.05, "upper_circuit": 180.0,
            "expiry": "2026-09-29", "strike": 23150, "underlying": "Nifty",
            "when": "expires today" if "today" in s else "weekly",
            "say": "Buy 1 lot, Nifty 23 1 50 call, weekly.",
        }
        if exit_:
            preview.update(entry=72.35, pnl=3.25, option_type="CE", lots=lots)
        preview["value"] = round(preview["quantity"] * preview["price"], 2)
        preview["option_type"] = "CE"
        preview["unusual"] = ([f"{lots} lots"] if lots > 1 else []) + \
            (["closing a position"] if exit_ else []) + \
            (["expires today"] if "today" in s else [])
        if confirm is None or not confirm(preview):
            return {"speak": "Cancelled.", "preview": preview, "confirmed": False}
        time.sleep(self.delay)
        if "boom" in s:
            raise RuntimeError("simulated failure after the order was sent")
        sent = {"symbol": preview["symbol"], "tag": "sayso-demo" + secrets.token_hex(3),
                "order_no": "DEMO" + secrets.token_hex(3).upper(),
                "quantity": preview["quantity"], "price": preview["price"]}
        if "unknown" in s:
            return {"speak": "I can't confirm that order went through. Check your "
                    "order book before you try again.", "outcome": "unknown",
                    "confirmed": True, "data": sent}
        if "reject" in s:
            return {"speak": "Rejected by the broker. Margin shortfall.",
                    "outcome": "rejected", "data": {**sent, "status": "REJECTED"}}
        if "rest" in s:
            return {"speak": "Placed but not filled yet.", "outcome": "resting",
                    "confirmed": True, "data": {**sent, "status": "OPEN"}}
        return {"speak": f"Filled. Bought {preview['quantity']} of the Nifty 23150 "
                f"call at {preview['price']:.2f}.", "say": f"Filled at {preview['price']:.2f}.",
                "outcome": "filled",
                "confirmed": True,
                "data": {**sent, "status": "COMPLETE", "filled": preview["quantity"],
                         "avg_fill_price": preview["price"]}}


def fake_safety():
    """Sayso's limits as the tests need them: lowered at once, raised only
    when confirmed, same as voice/safety.py."""
    defaults = {"max_order_value": 15000.0, "max_quantity": 1000, "max_orders_per_day": 20,
                "max_value_per_day": 50000.0, "max_option_orders_per_day": 10,
                "max_lots": {"NIFTY": 10, "BANKNIFTY": 3, "SENSEX": 10}}
    now = json.loads(json.dumps(defaults))

    class NeedsConfirmation(ValueError):
        pass

    def set_limits(changes, confirmed=False):
        raised = [k for k, v in changes.items() if k != "max_lots" and v > now[k]]
        raised += [f"{i} lots" for i, n in (changes.get("max_lots") or {}).items()
                   if n > now["max_lots"][i]]
        if raised and not confirmed:
            raise NeedsConfirmation(", ".join(raised))
        for k, v in changes.items():
            if k == "max_lots":
                now["max_lots"].update(v)
            else:
                now[k] = v
        return json.loads(json.dumps(now))

    def reset_limits():
        now.clear()
        now.update(json.loads(json.dumps(defaults)))
        return json.loads(json.dumps(now))

    return SimpleNamespace(
        status=lambda: {"option_orders_remaining": 9, "orders_remaining": 20,
                        "value_remaining": 50000.0, "limits": json.loads(json.dumps(now)),
                        "default_limits": defaults},
        set_limits=set_limits, reset_limits=reset_limits,
        NeedsConfirmation=NeedsConfirmation)


def fake_modules(delay: float) -> dict:
    class NotCalibrated(RuntimeError):
        pass

    def record_until_silence(on_level=None):
        blocks = max(int(delay * 1.3 / 0.05), 1)
        for i in range(blocks):
            time.sleep(0.05)
            if on_level:
                on_level(3.0 if i < blocks * 0.7 else 0.3)
        return b"audio"

    def transcribe(_audio):
        time.sleep(delay / 2)
        return "buy nifty call two three one five zero"

    quiet = SimpleNamespace(say=lambda *a, **k: None, interrupt=lambda: None,
                            announce=lambda *a, **k: None, speaking=lambda: False)

    # A resting order that fills a little later, through the same names
    # Sayso's follower uses, so the bridge's wrappers see it.
    watch = SimpleNamespace(_tell=lambda text, outcome: None)

    def _watch(order_no, what, every=2.0, limit=300):
        time.sleep(delay * 4)
        watch._tell(f"{what} filled at 72.70.", "filled")

    def follow(order_no, what):
        threading.Thread(target=lambda: watch._watch(order_no, what), daemon=True).start()
    watch._watch, watch.follow = _watch, follow
    orders = [{"order_no": "DEMO1", "status": "COMPLETE", "final": True, "side": "BUY",
               "symbol": "NIFTY29SEP26C23150", "quantity": 65, "filled": 65,
               "avg_fill_price": 72.35, "price": 72.4, "reason": None,
               "time": "09:21:04 29-09-2026", "tag": "sayso-demo1"}]
    underlying = lambda spoken, alias: SimpleNamespace(spoken=spoken, aliases=(alias,))
    return dict(
        agent=FakeAgent(delay),
        listen=SimpleNamespace(NotCalibrated=NotCalibrated, warm_up=lambda: None, download_mb=lambda: None,
                               record_until_silence=record_until_silence,
                               transcribe=transcribe,
                               config=SimpleNamespace(get=lambda k: 0.02)),
        speak=quiet,
        watch=watch,
        safety=fake_safety(),
        broker=SimpleNamespace(
            positions=lambda: [{"symbol": "NIFTY29SEP26C23150", "qty": 65,
                                "avg_price": 72.35, "ltp": 72.75, "unrealised_pnl": 26.0}],
            funds=lambda: {"available": 12345.67, "cash_settled": 12000.0,
                           "payin_today": 345.67, "blocked": 0.0},
            order_book=lambda: [], orders_today=lambda: list(orders), _api=None,
            account_checks=lambda: [
                {"name": "market data", "ok": True, "detail": "nifty 25010.50", "fix": "", "blocking": True},
                {"name": "NFO segment", "ok": True, "detail": "enabled", "fix": "", "blocking": False},
                {"name": "BFO segment", "ok": True, "detail": "enabled", "fix": "", "blocking": False}]),
        client=SimpleNamespace(session_user=lambda: "DEMO01"),
        network=SimpleNamespace(facts=lambda: {"state": "ok", "current": "203.0.113.10",
                                               "registered": ["203.0.113.10"]}),
        instruments=SimpleNamespace(market_hours=lambda: True),
        profile=SimpleNamespace(accounts=lambda: ["default"]),
        underlyings=SimpleNamespace(UNDERLYINGS={
            "NIFTY": underlying("Nifty", "nifty"),
            "BANKNIFTY": underlying("Bank Nifty", "bank nifty"),
            "SENSEX": underlying("Sensex", "sensex")}),
    )


class FakeEngine(Engine):
    """Runs the real Engine code; only the layer underneath is scripted."""

    def __init__(self, bus: Bus, confirm_timeout: float, delay: float = 0.9):
        super().__init__(bus, confirm_timeout, modules=fake_modules(delay))
        self.model_ready = True

    def start(self) -> None:
        self.refresh_status()

    def refresh_status(self) -> dict:
        status = {"live": True, "uid": os.getuid(), "model_ready": True,
                  "account": "DEMO01", "logged_in": True, "calibrated": True,
                  "network": {"state": "ok", "current": "203.0.113.10",
                              "registered": ["203.0.113.10"]},
                  "market_hours": True, "profile": "default", "accounts": ["default"],
                  "model_error": None, "model_download_mb": None,
                  "limits": self.safety.status()}
        self.bus.emit("status", **status)
        return status

    def login_begin(self, creds):
        creds.clear()
        self.bus.emit("login", state="ok", account="DEMO01")
        return "about:blank"

    def login_complete(self, code):
        return False, "The scripted engine has no login."

    def save_ips(self, ips):
        return ips

    def _calibrate(self, step):
        seconds = 3 if step == "quiet" else 5
        self.bus.emit("calib", step=step, state="measuring", seconds=seconds)
        time.sleep(seconds)
        if step == "quiet":
            self.bus.emit("calib", step=step, state="done", floor=0.0108, noisy=False)
        else:
            self.bus.emit("calib", step=step, state="saved", threshold=0.0269,
                          floor=0.0108, speech=0.0852)
