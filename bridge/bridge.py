"""
Sayso bridge: runs the engine as a local background process for the face.

    sayso/.venv/bin/python bridge/bridge.py [--account NAME] [--port N]

The engine is the fork in ../sayso. This does what Sayso's own terminal
front-end (voice/main.py, voice/cli.py) does, and puts it on 127.0.0.1:

    GET  /events        server-sent events: state, status, card, question, result...
    GET  /status        account, session, network, limits
    POST /talk          record one utterance, then handle it
    POST /text          {"text": "..."}  handle typed words
    POST /confirm       {"decision": "send" | "cancel", "card_id": N}
                        {"decision": "price", "price": 72.5, "card_id": N}
    POST /ack           {"ack_id": "..."}  the face has shown an order's outcome
    POST /login         {"client_id", "user_id", "secret"}  opens the browser
    GET  /?code=...     the broker's login redirect
    POST /network /calibrate /refresh /shutdown
    GET  /positions  /funds  /orders

It runs on 8787, the redirect URL registered on the API key page. There is
no demo mode: every order is real (tests use their own scripted engine).

Rules it keeps (see ../CLAUDE.md):
  - nothing is sent without an explicit "send" for the exact card on screen,
    and every other path (timeout, cancel, disconnect, sleep, error) cancels;
  - once an order is sent, its outcome is held until the face has shown it,
    so a dropped connection can't lose the truth;
  - a typed price gets exactly Sayso's own front-end checks (cli._set_price);
  - credentials are held in memory for one login and never written or logged.

Exit codes: 0 normal, 3 port already in use, 4 engine failed to start.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import queue
import re
import secrets
import select
import signal
import socket
import sys
import threading
import time
import traceback
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ENGINE = ROOT / "sayso"
# A packaged app keeps per-user state (Sayso's and these logs) in SAYSO_HOME;
# a checkout keeps it beside the code.
LOGS = (Path(os.environ["SAYSO_HOME"]).expanduser() / "logs"
        if os.environ.get("SAYSO_HOME") else ROOT / "logs")
LOG_LIMIT = 5_000_000      # bytes; one older generation is kept

HOST = "127.0.0.1"
LIVE_PORT = 8787
KEEPALIVE = 2.0          # seconds; also how fast a dead face is noticed
FACE_LOG = "face.jsonl"


# ── events ────────────────────────────────────────────────────────────────

class Bus:
    """Fan-out of engine events to every connected face.

    What a face must never miss is held and replayed to every new
    connection: the order that is out (`inflight`), every outcome and fill
    carrying an `ack_id` until the face acknowledges it, and the resting
    orders Sayso is still following. A dropped stream, a relaunch or a
    busy overlay can then never lose what happened to a real order.
    """

    def __init__(self):
        self._subs: list[queue.Queue] = []
        self._lock = threading.Lock()
        self.last_status: dict = {}
        self.inflight: dict | None = None
        self.held: dict[str, dict] = {}          # ack_id -> event, in order
        self.working: dict[str, dict] = {}       # order_no -> "working open"
        self.run = secrets.token_hex(4)          # identifies this process

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue()
        with self._lock:
            self._subs.append(q)
            for event in ([self.last_status] if self.last_status else []) + \
                    list(self.working.values()) + \
                    ([self.inflight] if self.inflight else []) + list(self.held.values()):
                q.put(event)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self._lock:
            if q in self._subs:
                self._subs.remove(q)

    def connected(self) -> int:
        with self._lock:
            return len(self._subs)

    def holding(self) -> bool:
        """An order is out, news of one hasn't been shown yet, or Sayso is
        still following a resting order: stopping this engine would lose it."""
        with self._lock:
            return bool(self.inflight or self.held or self.working)

    def emit(self, kind: str, **payload) -> list[queue.Queue]:
        event = {"type": kind, "ts": time.time(), "run": self.run, **payload}
        with self._lock:
            if kind == "status":
                self.last_status = event
            elif kind == "inflight":
                self.inflight = event
            elif kind == "working" and payload.get("order_no"):
                if payload.get("state") == "open":
                    self.working[payload["order_no"]] = event
                else:
                    self.working.pop(payload["order_no"], None)
            if payload.get("ack_id"):
                if kind == "result":
                    self.inflight = None
                self.held[payload["ack_id"]] = event
            targets = list(self._subs)
            for q in targets:
                q.put(event)
        return targets

    def ack(self, ack_id: str) -> bool:
        with self._lock:
            return self.held.pop(ack_id, None) is not None


def rotate(path: Path, limit: int = LOG_LIMIT) -> None:
    """Keep a log from growing forever: past `limit` it becomes `.1`,
    replacing the older one."""
    try:
        if path.stat().st_size > limit:
            path.replace(path.with_name(path.name + ".1"))
    except OSError:
        pass


_writes = 0


def face_log(kind: str, **fields) -> None:
    """The face's own events (CLAUDE.md rule 20). Never credentials."""
    global _writes
    LOGS.mkdir(exist_ok=True)
    _writes += 1
    if _writes % 200 == 0:
        rotate(LOGS / FACE_LOG)                 # a long session rotates too
    line = json.dumps({"ts": time.time(), "event": kind, **fields}, default=str)
    with open(LOGS / FACE_LOG, "a") as fh:
        fh.write(line + "\n")


def try_log(kind: str, **fields) -> None:
    """face_log where a failed write (a full disk) must not cost the news it
    records. Only the send itself fails closed on a log error."""
    try:
        face_log(kind, **fields)
    except Exception:
        traceback.print_exc()


def _plain(value, depth=0):
    """Make engine data JSON-safe, dropping the broker's raw replies."""
    if depth > 4:
        return str(value)
    if isinstance(value, dict):
        return {k: _plain(v, depth + 1) for k, v in value.items()
                if k not in ("raw_response",)}
    if isinstance(value, (list, tuple)):
        return [_plain(v, depth + 1) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)


# ── price entry: exactly Sayso's own front-end checks ─────────────────────

def apply_price(preview: dict, price, reprice=None) -> str | None:
    """Mirror of sayso/voice/cli.py _set_price. Returns an error, or None.

    Stricter than the terminal in two places, both for input a terminal user
    can't produce: non-numbers (NaN, inf, bools, absurd sizes), and a price
    that is only above zero before it is rounded to the tick.
    """
    shown = str(price)[:20]
    if isinstance(price, bool):
        return f"'{shown}' is not a price."
    try:
        price = float(price)
    except (TypeError, ValueError, OverflowError):
        return f"'{shown}' is not a price."
    if not math.isfinite(price) or price > 1e7:
        return f"'{shown}' is not a price."
    if price <= 0:
        return "A price has to be above zero."
    tick = preview.get("tick") or 0.05
    price = round(round(price / tick) * tick, 2)
    if price <= 0:
        return "A price has to be above zero."
    low, high = preview.get("lower_circuit"), preview.get("upper_circuit")
    if low and price < low:
        return f"{price:.2f} is below the lower circuit {low:.2f}."
    if high and price > high:
        return f"{price:.2f} is above the upper circuit {high:.2f}."
    if reprice is not None:
        reprice(preview, price)                 # Sayso's own: value, P&L, flags
        return None
    preview["price"] = price
    preview["value"] = round(preview["quantity"] * price, 2)
    preview["at_market"] = False
    reasons = preview.get("unusual")
    if isinstance(reasons, list) and "your price" not in reasons:
        reasons.append("your price")           # the card now looks different too
    return None


# ── the engine, driven the way voice/main.py drives it ────────────────────

class Engine:
    MIN_DWELL = 0.7        # seconds a card must be on screen before send counts
    STATUS_EVERY = 120     # seconds between session / IP health checks
    SHUTDOWN_WAIT = 120    # seconds to let an order that's out report back
                           # (worst case after a send is about 90 s)
    LOGIN_TTL = 300        # seconds a started login waits for its redirect

    def __init__(self, bus: Bus, confirm_timeout: float, modules: dict | None = None):
        self.bus = bus
        self.confirm_timeout = confirm_timeout
        self._init_state()
        self.model_ready = False
        self.model_error: str | None = None
        self.model_download_mb: int | None = None      # downloading it now, this big
        if modules is None:
            from voice import agent, listen, safety, speak, watch
            import shoonya.broker as broker
            from shoonya import client, instruments, network, profile, underlyings
            modules = dict(agent=agent, listen=listen, safety=safety, speak=speak,
                           watch=watch, broker=broker, client=client,
                           network=network, underlyings=underlyings,
                           instruments=instruments, profile=profile)
        for name, module in modules.items():
            setattr(self, name, module)

        # Fills are announced by Sayso's own follower (voice/watch.py), which
        # speaks and prints. Wrap its one output so the face hears it too.
        # A fill is news about a real order: held until the face has shown
        # it, and logged (rule 20).
        original = self.watch._tell
        told = threading.local()

        def tell(text, outcome):
            told.done = True
            self.bus.emit("fill", text=text, outcome=outcome,
                          order_no=getattr(told, "order_no", None),
                          what=getattr(told, "what", None),
                          ack_id=secrets.token_hex(6))
            try_log("fill", outcome=outcome, said_back=text,
                    order_no=getattr(told, "order_no", None))
            try:
                original(text, outcome)         # Sayso's own: print and speak
            except Exception:
                traceback.print_exc()
        self.watch._tell = tell

        # And its watch itself, so the face can keep a resting order in
        # view for exactly as long as Sayso is following it. A watcher that
        # ends without telling (it crashed) says so: never a silent drop.
        watching = self.watch._watch

        def watch(order_no, what, *args):
            told.done, told.order_no, told.what = False, order_no, what
            self.bus.emit("working", order_no=order_no, what=what, state="open")
            failed = False
            try:
                watching(order_no, what, *args)
            except Exception:
                failed = True                   # even after a part-fill was told
            finally:
                if failed or not told.done:
                    self.watch._tell(f"I lost track of {what}. It may still be "
                                     f"working. Check your order book.", "unknown")
                self.bus.emit("working", order_no=order_no, what=what, state="done")
        self.watch._watch = watch

    def _init_state(self) -> None:
        self._busy = threading.Lock()        # one command at a time
        self._lock = threading.Lock()        # guards the open card
        self._decision: str | None = None
        self._decided = threading.Event()
        self._preview: dict | None = None
        # Card ids start somewhere random, so a face can never confuse a card
        # from an earlier engine run with this one's.
        self._card_id = secrets.randbelow(10**6) * 1000
        self._card_shown = 0.0
        self._card_opened = 0.0
        self._card_deadline = 0.0            # monotonic
        self._card_wall_deadline = 0.0       # wall clock: survives sleep
        self._card_viewers: set = set()
        self._sent = False                   # did this command send an order?
        self._sent_card: int | None = None
        self._sent_display: str | None = None
        self._warming = False
        self._blocks = 0                     # mic blocks heard, for the meter
        self._closing = False
        self._login: tuple | None = None
        self._login_state = ""
        self._login_started = 0.0

    # startup, off the request path
    def start(self) -> None:
        threading.Thread(target=self._warm, daemon=True).start()
        threading.Thread(target=self._health_loop, daemon=True).start()
        threading.Thread(target=self._speech_watch, daemon=True).start()

    def _speech_watch(self, every: float = 0.15) -> None:
        # The face shows when Sayso is talking (readback or result), so a
        # trader knows why pressing to talk will cut it short.
        was = False
        while not self._closing:
            try:
                now = bool(self.speak.speaking())
            except Exception:
                now = False
            if now != was:
                was = now
                self.bus.emit("speaking", on=now)
            time.sleep(every)

    def _warm(self) -> None:
        try:
            try:
                self.model_download_mb = self.listen.download_mb()
            except Exception:
                self.model_download_mb = None
            if self.model_download_mb:
                self.refresh_status()        # the panel says it's downloading
            self.listen.warm_up()
            self.model_ready, self.model_error = True, None
        except Exception as e:
            self.model_error = f"{type(e).__name__}: {e}"
            self.bus.emit("error", message="The speech model didn't load, so "
                          "only typed commands will work.", details=self.model_error)
        self.model_download_mb = None
        self.refresh_status()

    def rewarm(self) -> bool:
        """Try the speech model again (Setup & health's Retry)."""
        if self.model_ready or self._warming:
            return False
        self._warming = True

        def run():
            try:
                self._warm()
            finally:
                self._warming = False
        threading.Thread(target=run, daemon=True).start()
        return True

    def set_limits(self, changes: dict, confirmed: bool) -> dict:
        """This account's limits (safety.set_limits): lowering at once,
        raising only once the human has said yes."""
        limits = self.safety.set_limits(changes, confirmed=confirmed)
        threading.Thread(target=self.refresh_status, daemon=True).start()
        return limits

    def reset_limits(self) -> dict:
        limits = self.safety.reset_limits()
        threading.Thread(target=self.refresh_status, daemon=True).start()
        return limits

    def account_checks(self) -> list:
        return _plain(self.broker.account_checks())

    def _health_loop(self) -> None:
        # An expired session or a changed IP shows up on the panel before the
        # first order of the day finds out.
        while not self._closing:
            time.sleep(self.STATUS_EVERY)
            try:
                self.refresh_status()
            except Exception:
                pass

    def refresh_status(self) -> dict:
        status = {"live": True, "uid": os.getuid(),
                  "model_ready": self.model_ready,
                  "account": self.client.session_user(), "logged_in": False,
                  "calibrated": self.listen.config.get("silence_rms") is not None,
                  "model_error": self.model_error,
                  "model_download_mb": self.model_download_mb,
                  "profile": os.environ.get("SAYSO_ACCOUNT") or "default"}
        for key, read in (("market_hours", lambda: self.instruments.market_hours()),
                          ("accounts", lambda: self.profile.accounts())):
            try:
                status[key] = read()
            except Exception:
                status[key] = None
        try:
            api = self.client.Shoonya()
            status["logged_in"] = bool(api.resume() and self.client._session_alive(api))
        except Exception:
            status["logged_in"] = False
        try:
            # Facts, not Sayso's terminal wording: its messages end in
            # shell commands, which never appear on the panel.
            status["network"] = self.network.facts()
        except Exception:
            status["network"] = {"state": "unknown", "current": None, "registered": []}
        try:
            status["limits"] = _plain(self.safety.status())
        except Exception:
            status["limits"] = None
        self.bus.emit("status", **status)
        return status

    # commands
    def talk(self) -> bool:
        return self._start(self._talk_then_handle)

    def text(self, said: str) -> bool:
        return self._start(lambda: self._handle(said))

    def _start(self, work, idle: bool = True) -> bool:
        if self._closing or not self._busy.acquire(blocking=False):
            return False

        def run():
            try:
                work()
            finally:
                self._busy.release()
                if idle:
                    self.bus.emit("state", state="idle")
        threading.Thread(target=run, daemon=True).start()
        return True

    def _talk_then_handle(self) -> None:
        self.bus.emit("state", state="listening")
        try:
            audio = self.listen.record_until_silence(on_level=self._level)
            if audio is not None:
                self.bus.emit("state", state="transcribing")
                said = self.listen.transcribe(audio)
            else:
                said = None
        except self.listen.NotCalibrated:
            self.bus.emit("error", message="The microphone hasn't been set up "
                          "yet. Use Set up mic on the panel, then try again.")
            return
        except Exception as e:
            # No microphone, device unplugged, permission refused, model error.
            # Nothing was sent; say so, never go quiet.
            self.bus.emit("error", message="Couldn't hear you: the microphone "
                          "or speech model failed. Nothing was done.",
                          details=f"{type(e).__name__}: {e}")
            return
        if not said:
            self.bus.emit("result", speak="Nothing heard.", blocked=True, quiet=True)
            return
        self._handle(said)

    def _level(self, level: float) -> None:
        # The recorder hears 20 blocks a second; the meter needs 10.
        self._blocks += 1
        if self._blocks % 2 == 0:
            self.bus.emit("level", level=round(min(level, 9.99), 2))

    def _handle(self, said: str) -> None:
        self._sent = False
        self._sent_card = None
        self._sent_display = None
        face_log("heard", text=said)
        self.bus.emit("heard", text=said)
        self.bus.emit("state", state="working")
        try:
            result = self.agent.handle(said, confirm=self._confirm)
        except Exception as e:
            details = f"{type(e).__name__}: {e}"
            if self._sent:
                # It failed after the order went out: the truth is "unknown",
                # never "nothing was done".
                result = {"speak": "The order was sent, but something went wrong "
                          "afterwards. It may be live. Check your order book "
                          "before you try again.", "outcome": "unknown"}
            else:
                result = {"speak": "Something went wrong, so nothing was done.",
                          "blocked": True}
            self._after(result, details=details)
            return
        self._after(result)

    def _after(self, result: dict, details: str | None = None) -> None:
        out = {k: result.get(k) for k in (
            "speak", "outcome", "blocked", "cancelled", "confirmed", "final",
            "needs_answer", "needs_clarification", "broker_error", "show")}
        data = result.get("data")
        if data is not None:
            out["data"] = _plain(data)
        if details:
            out["details"] = details
        if result.get("needs_answer"):
            self.bus.emit("question", text=result.get("speak"),
                          field=result["needs_answer"],
                          choices=self._choices(result["needs_answer"]),
                          expires_in=getattr(self.agent, "PENDING_SECONDS", 30))
        if self._sent:
            # The outcome of a real order: held until the face confirms it
            # has shown it (POST /ack), and replayed to every reconnect.
            out.update(card_id=self._sent_card, ack_id=secrets.token_hex(6))
            self.bus.emit("result", **out)
        else:
            self.bus.emit("result", **out)
        d = data if isinstance(data, dict) else {}
        # A resting order is followed by Sayso's own watcher, as main.py does.
        # First: nothing below (speech, the log) may stop it being followed.
        if (result.get("outcome") in ("resting", "partial")
                and not result.get("final") and d.get("order_no")):
            what = (self.agent.friendly(d["symbol"]) if d.get("symbol")
                    else self._sent_display or "Your order")
            self.watch.follow(d["order_no"], what)
        try:
            self.speak.announce(result)
        except Exception:
            traceback.print_exc()
        try_log("outcome", card_id=self._sent_card,
                outcome=result.get("outcome"), blocked=bool(result.get("blocked")),
                said_back=result.get("speak"), tag=d.get("tag"),
                order_no=d.get("order_no"), status=d.get("status"),
                details=details)
        if result.get("outcome") or result.get("broker_error"):
            threading.Thread(target=self.refresh_status, daemon=True).start()

    def _choices(self, field: str) -> list:
        """Quick-picks only where the answers are fixed and public."""
        if field == "underlying":
            return [{"label": u.spoken, "say": u.aliases[0]}
                    for u in self.underlyings.UNDERLYINGS.values()]
        if field == "product":
            return [{"label": "Intraday", "say": "intraday"},
                    {"label": "Delivery", "say": "delivery"}]
        return []

    # the confirm step: what voice/cli.py confirm() does, over the wire.
    #
    # Every decision is taken under one lock and is tied to the exact card on
    # screen (`card_id`, bumped whenever the card changes). The moment send or
    # cancel is taken, the card is gone: a late price change or a stale send
    # can never touch the order that is about to go out.

    def _emit_card(self, preview: dict, display: str, bump: bool = True) -> None:
        if bump:
            self._card_id += 1
        # The dwell counts from when this exact card went out.
        self._card_shown = time.monotonic()
        viewers = self.bus.emit("card", preview=_plain(preview), display=display,
                                timeout=self.confirm_timeout, card_id=self._card_id)
        self._card_viewers.update(viewers)

    def _confirm(self, preview: dict) -> bool:
        if self._closing:
            # Shutting down: no new card, so nothing new can be sent.
            face_log("decision", decision="shutdown",
                     symbol=preview.get("symbol"), quantity=preview.get("quantity"))
            return False
        display = preview.get("symbol")
        try:
            display = self.agent.friendly(preview["symbol"])
        except Exception:
            pass
        with self._lock:
            self._preview = preview
            self._decision = None
            self._decided.clear()
            self._card_viewers = set()
            self._card_opened = time.monotonic()
            self._card_wall_deadline = time.time() + self.confirm_timeout
            self._card_deadline = self._card_opened + self.confirm_timeout
            self._emit_card(preview, display)
            nobody = not self._card_viewers
        if nobody:
            # A card nobody can see can't be read, so it can't be sent.
            with self._lock:
                self._preview = None
            self._close_card("no_face", preview)
            return False
        announced = False        # has card_closed gone out for this card?
        try:
            self.bus.emit("state", state="confirm")
            self.speak.say(preview.get("say") or preview.get("spoken"))
            while True:
                # Checked against both clocks: the monotonic one stops while
                # the Mac sleeps, the wall clock doesn't.
                left = min(self._card_deadline - time.monotonic(),
                           self._card_wall_deadline - time.time())
                woke = left > 0 and self._decided.wait(timeout=min(left, 0.5))
                if not woke and left > 0.5:
                    continue
                with self._lock:
                    self._decided.clear()
                    # A decision decide() accepted (it checks both deadlines)
                    # is honoured even if it landed as the wait gave up.
                    decision = self._decision or "timeout"
                    self._decision = None
                    if decision == "price":
                        # Applied, and the old card invalidated, by decide().
                        # Show the new card with a fresh window to read it.
                        self._card_deadline = time.monotonic() + self.confirm_timeout
                        self._card_wall_deadline = time.time() + self.confirm_timeout
                        self._emit_card(preview, display, bump=False)
                        continue
                    # send, cancel or timeout: the card closes now, under the lock.
                    self._preview = None
                    card_id = self._card_id
                self.speak.interrupt()
                if decision == "send":
                    # Logged before it counts as sent: if the log can't be
                    # written, this raises and nothing goes to the broker.
                    self._close_card("send", preview)
                    announced = True
                    self._sent = True
                    self._sent_card = card_id
                    self._sent_display = display
                    # Held by the bus until the result replaces it.
                    self.bus.emit("inflight", card_id=card_id, display=display,
                                  action=preview.get("action"),
                                  symbol=preview.get("symbol"),
                                  quantity=preview.get("quantity"),
                                  price=preview.get("price"))
                    self.bus.emit("state", state="sending")
                    return True
                self._close_card("timeout" if decision == "timeout" else "cancel", preview)
                announced = True
                return False
        except BaseException:
            # Never leave a zombie card behind: close it here and on screen.
            with self._lock:
                self._preview = None
            if not announced:
                try:
                    self.bus.emit("card_closed", reason="error", card_id=self._card_id)
                except Exception:
                    pass
            raise

    def _close_card(self, why: str, preview: dict) -> None:
        ms = int((time.monotonic() - self._card_opened) * 1000)
        face_log("decision", decision=why, card_id=self._card_id,
                 time_to_decide_ms=ms, symbol=preview.get("symbol"),
                 quantity=preview.get("quantity"), price=preview.get("price"),
                 value=preview.get("value"))
        self.bus.emit("card_closed", reason=why, card_id=self._card_id)

    def decide(self, decision: str, price=None, card_id=None) -> tuple[bool, str | None]:
        with self._lock:
            if self._preview is None or self._decision in ("send", "cancel"):
                return False, "No order is waiting for a decision."
            if decision != "cancel" and card_id != self._card_id:
                # Cancelling is always allowed; anything else must name the
                # card that is actually on screen.
                return False, "The card changed. Look at it again."
            if decision != "cancel" and (time.time() > self._card_wall_deadline or
                                         time.monotonic() > self._card_deadline):
                return False, "That card has expired."
            if decision == "send" and self._closing:
                return False, "Sayso is shutting down. Nothing was sent."
            if decision == "price":
                error = apply_price(self._preview, price, getattr(self.agent, "reprice", None))
                if error:
                    self.bus.emit("price_error", message=error)
                    return False, error
                # The card the user was looking at no longer matches the
                # order: its id dies now, before the new one is even shown.
                self._card_id += 1
                self._card_shown = time.monotonic()
            elif decision == "send":
                if time.monotonic() - self._card_shown < self.MIN_DWELL:
                    return False, "Too quick. Read the card, then send."
            else:
                decision = "cancel"
            self._decision = decision
            self._decided.set()
            return True, None

    def viewer_gone(self, q: queue.Queue) -> None:
        """A face's connection ended. If it was showing the open card, the
        card is cancelled at once: nobody may send what nobody can see."""
        with self._lock:
            showing = self._preview is not None and q in self._card_viewers
            self._card_viewers.discard(q)
        if showing:
            self.decide("cancel")

    def shutdown_gracefully(self) -> None:
        """Stop taking commands, cancel any open card, and let an order that
        is already out finish, so its outcome is spoken and logged."""
        self._closing = True
        if self._preview is not None:
            self.decide("cancel")
        # The command lock is held until the sent order's result has gone out.
        if self._busy.acquire(timeout=self.SHUTDOWN_WAIT):
            self._busy.release()
        elif self._sent:
            face_log("abandoned", card_id=self._sent_card)

    def busy_with_an_order(self) -> bool:
        return self._preview is not None or self.bus.inflight is not None

    # login: Sayso's own OAuth steps, with the redirect caught here
    def login_begin(self, creds: dict) -> str:
        api = self.client.Shoonya()
        # A one-time state the redirect must echo back, if the broker echoes
        # it: a page that sends this browser to our redirect with someone
        # else's code is refused, and so is a login for any other account.
        self._login_state = secrets.token_urlsafe(16)
        url = (api.getOAuthURL(self.client.AUTHORIZE_URL, creds["client_id"])
               + "&state=" + self._login_state)
        self._login = (api, dict(creds))
        self._login_started = time.monotonic()
        creds.clear()
        webbrowser.open(url)
        self.bus.emit("login", state="waiting")
        return url

    def login_complete(self, code: str, state: str | None = None) -> tuple[bool, str]:
        if not self._login:
            return False, "No login was started from the app."
        if state is not None and not secrets.compare_digest(state, self._login_state):
            # Not ours: refused without spending the login that is waiting.
            return False, "That login wasn't started from this Sayso. Start it again from the app."
        if self.busy_with_an_order():
            # Landing now would send the open order through the new session.
            return False, "An order is open in Sayso. Finish or cancel it, then log in again."
        api, creds = self._login
        self._login = None
        expected = str(creds.get("user_id") or "").strip().upper()
        if time.monotonic() - self._login_started > self.LOGIN_TTL:
            creds.clear()
            self.bus.emit("login", state="failed", message="That login took too long. Start it again.")
            return False, "That login took too long. Start it again from the app."
        try:
            result, detail = self.client._exchange(api, code, creds)
        except Exception as e:
            # Network error or a non-JSON reply inside the SDK: say so, never hang.
            result, detail = None, f"{type(e).__name__}: {e}"
        finally:
            creds.clear()
        if not result:
            hint = self.network.explain(detail) if detail else None
            message = hint or "The broker refused the login. Start it again for a fresh code."
            self.bus.emit("login", state="failed", message=message, details=detail)
            return False, message
        access_token, uid, _refresh, actid = result
        if str(uid or "").strip().upper() != expected:
            # Logged in, but not as the account asked for: never saved.
            message = f"That login was for a different account, not {expected}. Start it again."
            self.bus.emit("login", state="failed", message=message)
            return False, message
        session = {"access_token": access_token, "uid": uid, "actid": actid}
        self.client._write_private(self.client.SESSION_FILE, json.dumps(session, indent=2))
        self.broker._api = None          # next call picks up the new session
        self.bus.emit("login", state="ok", account=uid)
        threading.Thread(target=self.refresh_status, daemon=True).start()
        return True, f"Logged in as {uid}."

    def save_ips(self, ips: list) -> list:
        return self.network.save(ips)

    # mic calibration: sayso/voice/calibrate.py's steps and formula, with the
    # panel instead of "press Enter" prompts. Recording is Sayso's own _measure.
    NOISY = 0.02          # calibrate.py: a "quiet" reading above this isn't quiet
    NO_SOUND = ("The microphone is sending no sound at all. That's almost always "
                "permission: System Settings > Privacy & Security > Microphone, "
                "allow Sayso, then quit and reopen it.")

    def calibrate(self, step: str) -> bool:
        return self._start(lambda: self._calibrate(step), idle=False)

    def _calibrate(self, step: str) -> None:
        import numpy as np
        from voice import calibrate as cal
        seconds = 3 if step == "quiet" else 5
        self.bus.emit("calib", step=step, state="measuring", seconds=seconds)
        try:
            levels = cal._measure(seconds, "silence" if step == "quiet" else "speech ")
        except Exception as e:
            self.bus.emit("calib", step=step, state="error",
                          message="No microphone available.", details=f"{type(e).__name__}: {e}")
            return
        if step == "quiet":
            if max(levels) < cal.SILENT:
                self.bus.emit("calib", step=step, state="error", message=self.NO_SOUND)
                return
            self._floor = float(np.percentile(levels, 90))
            self.bus.emit("calib", step=step, state="done", floor=self._floor,
                          noisy=self._floor > self.NOISY)
            return
        floor = getattr(self, "_floor", None)
        if floor is None:
            self.bus.emit("calib", step=step, state="error", message="Measure the quiet room first.")
            return
        speech = float(np.percentile(levels, 90))
        if speech < cal.SILENT:
            self.bus.emit("calib", step=step, state="error", message=self.NO_SOUND)
            return
        if speech < floor * 2:
            self.bus.emit("calib", step=step, state="error",
                          message="Your voice was barely above the background. Move closer, "
                                  "or raise the input volume in System Settings, then try again.")
            return
        floor = max(floor, cal.SILENT)
        threshold = max(round(min(floor * 2.5, speech / 3), 4), cal.SILENT)
        self.listen.config.save(silence_rms=threshold)
        self.bus.emit("calib", step=step, state="saved", threshold=threshold,
                      floor=floor, speech=speech)
        threading.Thread(target=self.refresh_status, daemon=True).start()

    # read-only helpers
    def read(self, what: str):
        fn = {"positions": self.broker.positions, "funds": self.broker.funds,
              "orders": self.broker.orders_today}[what]
        data = _plain(fn())
        if isinstance(data, list):
            # Contracts as a trader says them, in Sayso's own words.
            for row in data:
                if isinstance(row, dict) and row.get("symbol"):
                    try:
                        row["display"] = self.agent.friendly(row["symbol"])
                    except Exception:
                        row["display"] = row["symbol"]
        return data


# ── HTTP ──────────────────────────────────────────────────────────────────

class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # A face that closed its connection is routine, not a traceback.
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


def token_file(port: int) -> Path:
    return LOGS / f".token-{port}"


def write_token(port: int) -> str:
    """A secret for this run, readable only by this macOS user (0600, in
    their own folder). The app sends it with every request, so no other
    process - another user's, a web page's - can drive or watch the engine."""
    token = secrets.token_urlsafe(24)
    LOGS.mkdir(parents=True, exist_ok=True)
    path = token_file(port)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(token)
    os.chmod(path, 0o600)
    return token


def make_handler(holder: dict, bus: Bus, port: int, token: str):
    """`holder["engine"]` is filled in once the engine has loaded; the port is
    bound first, so a clash is reported at once."""
    hosts = {f"{HOST}:{port}", f"localhost:{port}"}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):     # quiet: the event log is the record
            pass

        def _json(self, code: int, body) -> None:
            raw = json.dumps(body, default=str).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                body = json.loads(self.rfile.read(n))
                return body if isinstance(body, dict) else {}
            except ValueError:
                return {}

        def _local_only(self) -> bool:
            # Loopback only, and no browser page may drive or read it: a
            # cross-site request carries an Origin header (the app never
            # does), and a DNS-rebinding page arrives with a foreign Host.
            # The app also sends this run's secret (write_token), which no
            # web page and no other user's process can know.
            sent = self.headers.get("X-Sayso") or ""
            if (self.client_address[0] != HOST or self.headers.get("Origin")
                    or self.headers.get("Host") not in hosts
                    or not secrets.compare_digest(sent, token)):
                self._json(403, {"error": "forbidden"})
                return False
            return True

        def _status(self) -> dict:
            base = bus.last_status or {"type": "status", "starting": True, "uid": os.getuid()}
            return {**base, "subscribers": bus.connected(), "port": port,
                    "held": bus.holding()}

        def do_GET(self):
            try:
                self._get()
            except Exception:
                traceback.print_exc()
                self._safe_500()

        def do_POST(self):
            try:
                self._post()
            except Exception:
                traceback.print_exc()
                self._safe_500()

        def _safe_500(self):
            try:
                self._json(500, {"error": "Internal error. Nothing was done."})
            except Exception:
                pass

        def _get(self):
            url = urlparse(self.path)
            engine = holder.get("engine")
            if url.path == "/" and "code" in parse_qs(url.query):
                query = parse_qs(url.query)
                ok, message = (engine.login_complete(query["code"][0],
                                                     (query.get("state") or [None])[0])
                               if engine else (False, "The engine is still starting."))
                page = (f"<html><body style='font:15px -apple-system;padding:40px;"
                        f"background:#111;color:#eee'><h3>{'✓' if ok else '✗'} "
                        f"{message}</h3><p>You can close this tab.</p></body></html>")
                raw = page.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
                return
            if not self._local_only():
                return
            if url.path == "/status":
                return self._json(200, self._status())
            if engine is None:
                return self._json(503, {"error": "starting"})
            if url.path == "/events":
                return self._events(engine)
            if url.path == "/checks":
                try:
                    return self._json(200, {"data": engine.account_checks()})
                except Exception as e:
                    return self._json(200, {"error": str(e)})
            if url.path in ("/positions", "/funds", "/orders"):
                try:
                    return self._json(200, {"data": engine.read(url.path[1:])})
                except Exception as e:
                    return self._json(200, {"error": str(e)})
            self._json(404, {"error": "not found"})

        def _post(self):
            if not self._local_only():
                return
            path, body = urlparse(self.path).path, self._body()
            if path == "/shutdown":
                # Only an engine no face is using may be stopped this way: one
                # app can never stop another's engine.
                if bus.connected() > 0:
                    return self._json(409, {"error": "A Sayso window is using this engine."})
                if bus.holding():
                    # A real order is out, its news hasn't been shown, or a
                    # resting order is being followed: whoever connects next
                    # must see it, so this engine stays.
                    return self._json(409, {"error": "An order still needs this engine.",
                                            "held": True, "working": bool(bus.working)})
                self._json(200, {"ok": True})
                holder["stop"]()
                return
            engine = holder.get("engine")
            if engine is None:
                return self._json(503, {"error": "The engine is still starting."})
            if path == "/talk":
                ok = engine.talk()
                return self._json(200 if ok else 409, {"ok": ok})
            if path == "/text":
                said = str(body.get("text") or "").strip()
                if not said:
                    return self._json(400, {"error": "empty"})
                ok = engine.text(said)
                return self._json(200 if ok else 409, {"ok": ok})
            if path == "/confirm":
                ok, error = engine.decide(str(body.get("decision")), body.get("price"),
                                          body.get("card_id"))
                return self._json(200 if ok else 409, {"ok": ok, "error": error})
            if path == "/ack":
                return self._json(200, {"ok": bus.ack(str(body.get("ack_id") or ""))})
            if path == "/login":
                creds = {k: str(body.get(k) or "").strip()
                         for k in ("client_id", "user_id", "secret")}
                body.clear()
                if not all(creds.values()):
                    return self._json(400, {"error": "Client ID, User ID and secret "
                                                     "are all needed."})
                if engine.busy_with_an_order():
                    # A new login mid-order would send it through the new session.
                    creds.clear()
                    return self._json(409, {"error": "Finish or cancel the order first."})
                url = engine.login_begin(creds)
                return self._json(200, {"ok": True, "url": url})
            if path == "/network":
                # The registered IP(s) from the API key page, saved with Sayso's
                # own network.save, so its pre-flight check works.
                ips = [str(i).strip() for i in (body.get("ips") or []) if str(i).strip()]
                try:
                    saved = engine.save_ips(ips)
                except ValueError as e:
                    return self._json(400, {"error": str(e)})
                threading.Thread(target=engine.refresh_status, daemon=True).start()
                return self._json(200, {"ok": True, "saved": saved})
            if path == "/calibrate":
                step = str(body.get("step"))
                if step not in ("quiet", "speech"):
                    return self._json(400, {"error": "step must be quiet or speech"})
                ok = engine.calibrate(step)
                return self._json(200 if ok else 409, {"ok": ok})
            if path == "/warm":
                return self._json(200, {"ok": engine.rewarm()})
            if path == "/limits":
                # This account's limits. Raising any of them needs
                # "confirmed": true, sent only after the human said yes.
                changes = body.get("changes")
                if not isinstance(changes, dict):
                    return self._json(400, {"error": "Nothing to change."})
                try:
                    limits = engine.set_limits(changes, confirmed=body.get("confirmed") is True)
                except ValueError as e:
                    if type(e).__name__ == "NeedsConfirmation":
                        return self._json(409, {"needs_confirmation": True, "raised": str(e)})
                    return self._json(400, {"error": str(e)})
                return self._json(200, {"ok": True, "limits": limits})
            if path == "/limits/reset":
                return self._json(200, {"ok": True, "limits": engine.reset_limits()})
            if path == "/refresh":
                threading.Thread(target=engine.refresh_status, daemon=True).start()
                return self._json(200, {"ok": True})
            self._json(404, {"error": "not found"})

        def _gone(self) -> bool:
            # The face never writes on this connection, so readable means
            # closed. Noticed in a quarter second, not at the next write.
            try:
                ready, _, _ = select.select([self.connection], [], [], 0)
                return bool(ready) and self.connection.recv(1, socket.MSG_PEEK) == b""
            except OSError:
                return True

        def _events(self, engine):
            self.close_connection = True      # a stream is never reused
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            q = bus.subscribe()
            last = time.monotonic()
            try:
                while True:
                    try:
                        event = q.get(timeout=0.25)
                        chunk = f"data: {json.dumps(event, default=str)}\n\n"
                    except queue.Empty:
                        if self._gone():
                            break
                        if time.monotonic() - last < KEEPALIVE:
                            continue
                        chunk = ": keepalive\n\n"
                    self.wfile.write(chunk.encode())
                    self.wfile.flush()
                    last = time.monotonic()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                bus.unsubscribe(q)
                engine.viewer_gone(q)

    return Handler


def main(argv: list | None = None, make_engine=None) -> int:
    """make_engine(bus, confirm_timeout) is for the tests' scripted engine."""
    ap = argparse.ArgumentParser(description="Run Sayso for the face.")
    ap.add_argument("--account", help="Sayso account profile (as --account in Sayso)")
    ap.add_argument("--port", type=int,
                    help=f"default {LIVE_PORT} (the API key's redirect URL)")
    ap.add_argument("--confirm-timeout", type=float, default=20.0,
                    help="seconds a card stays open before it cancels")
    args = ap.parse_args(argv)
    port = args.port or LIVE_PORT
    rotate(LOGS / FACE_LOG)

    bus = Bus()
    holder: dict = {}
    try:
        server = Server((HOST, port), make_handler(holder, bus, port, "pending"))
    except OSError as e:
        print(f"ERROR: port {port} is already in use ({e.strerror}).", flush=True)
        return 3
    # The secret is written only once the port is ours, so a clash never
    # overwrites the token of the engine that holds it.
    server.RequestHandlerClass = make_handler(holder, bus, port, write_token(port))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    stopped = threading.Event()

    def stop(*_):
        def run():
            engine = holder.get("engine")
            if engine is not None:
                engine.shutdown_gracefully()
            stopped.set()
        threading.Thread(target=run, daemon=True).start()

    holder["stop"] = stop
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    try:
        if make_engine:
            engine: Engine = make_engine(bus, args.confirm_timeout)
        else:
            # Sayso fixes its per-account file paths at import time, so the
            # account is chosen before any of it is imported.
            sys.path.insert(0, str(ENGINE))
            if args.account:
                # Same shape check Sayso's profile.from_argv applies: it becomes
                # part of the session and limits file names.
                if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", args.account):
                    print(f"ERROR: account name {args.account!r} should be letters, "
                          f"digits, - or _.", flush=True)
                    return 4
                os.environ["SAYSO_ACCOUNT"] = args.account
            os.environ["SAYSO_APP"] = "1"     # Sayso's hints point at the panel
            engine = Engine(bus, args.confirm_timeout)
    except Exception as e:
        traceback.print_exc()
        print(f"ERROR: the engine failed to start: {type(e).__name__}: {e}", flush=True)
        return 4

    if stopped.is_set():            # asked to stop while it was loading
        server.shutdown()
        token_file(port).unlink(missing_ok=True)
        return 0
    holder["engine"] = engine
    engine.start()

    print(f"sayso bridge on http://{HOST}:{port}  ·  LIVE (real orders)", flush=True)
    while not stopped.wait(0.5):
        pass
    server.shutdown()
    try:
        token_file(port).unlink()
    except OSError:
        pass
    print("sayso bridge stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
