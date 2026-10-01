"""
Bridge tests: the confirm step, the truth after send, and the HTTP guards.

    sayso/.venv/bin/python -m unittest discover tests

Runs the real bridge code over real HTTP on a spare port, with the scripted
engine (tests/fakes.py) underneath. No microphone, no broker, nothing is sent anywhere.
"""

from __future__ import annotations

import builtins
import http.client
import io
import json
import math
import os
import queue
import socket
import sys
import tempfile
import threading
import types
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bridge"))
sys.path.insert(0, str(ROOT / "sayso"))
# Sayso's own state (sessions, limits, settings) goes to a throwaway folder:
# these tests import the real engine and must never touch the live files.
os.environ["SAYSO_HOME"] = tempfile.mkdtemp(prefix="sayso-bridge-test-")
os.environ.pop("SAYSO_ACCOUNT", None)

import bridge  # noqa: E402
import fakes  # noqa: E402

DWELL = bridge.Engine.MIN_DWELL + 0.1
TOKEN = "test-token-not-secret"


def free_port() -> int:
    with socket.socket() as s:
        s.bind((bridge.HOST, 0))
        return s.getsockname()[1]


class Stream:
    """One face's event stream."""

    def __init__(self, port: int):
        self.conn = http.client.HTTPConnection(bridge.HOST, port, timeout=10)
        self.conn.request("GET", "/events", headers={"X-Sayso": TOKEN})
        self.sock = self.conn.sock
        self.resp = self.conn.getresponse()
        self.events: queue.Queue = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        try:
            for line in self.resp:
                line = line.decode().strip()
                if line.startswith("data: "):
                    self.events.put(json.loads(line[6:]))
        except Exception:
            pass

    def next(self, kind: str, timeout: float = 5.0, where=None) -> dict:
        deadline = time.time() + timeout
        while True:
            try:
                event = self.events.get(timeout=max(deadline - time.time(), 0.01))
            except queue.Empty:
                raise AssertionError(f"no '{kind}' event within {timeout}s") from None
            if event["type"] == kind and (where is None or where(event)):
                return event

    def drain(self, seconds: float) -> list:
        seen, end = [], time.time() + seconds
        while time.time() < end:
            try:
                seen.append(self.events.get(timeout=0.05))
            except queue.Empty:
                pass
        return seen

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


class Rig:
    """The bridge's HTTP server and the scripted engine, as main() wires them."""

    def __init__(self, timeout: float = 5.0, delay: float = 0.05, engine=None):
        self.tmp = tempfile.TemporaryDirectory()
        bridge.LOGS = Path(self.tmp.name)
        self.port = free_port()
        self.bus = bridge.Bus()
        self.stops: list = []
        self.holder: dict = {"stop": lambda: self.stops.append(time.time())}
        handler = bridge.make_handler(self.holder, self.bus, self.port, TOKEN)
        self.server = bridge.Server((bridge.HOST, self.port), handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.engine = engine(self.bus) if engine else fakes.FakeEngine(self.bus, timeout, delay=delay)
        self.holder["engine"] = self.engine
        if engine:
            self.bus.emit("status", live=True, uid=os.getuid())
        else:
            self.engine.start()
        self.streams: list[Stream] = []

    def stream(self) -> Stream:
        s = Stream(self.port)
        self.streams.append(s)
        s.next("status")
        return s

    def request(self, method: str, path: str, body=None, headers=None):
        conn = http.client.HTTPConnection(bridge.HOST, self.port, timeout=5)
        raw = json.dumps(body) if body is not None else None
        conn.request(method, path, raw, {"Content-Type": "application/json",
                                         "X-Sayso": TOKEN, **(headers or {})})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, json.loads(data) if data else {}

    def post(self, path, body=None, **kw):
        return self.request("POST", path, body or {}, **kw)

    def say(self, text: str) -> None:
        code, _ = self.post("/text", {"text": text})
        assert code == 200, code

    def confirm(self, decision: str, card_id=None, price=None):
        body = {"decision": decision, "card_id": card_id}
        if price is not None:
            body["price"] = price
        return self.post("/confirm", body)

    def log(self) -> list:
        path = bridge.LOGS / bridge.FACE_LOG
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def wait_idle(self, timeout: float = 5.0) -> None:
        end = time.time() + timeout
        while time.time() < end:
            if self.engine._busy.acquire(blocking=False):
                self.engine._busy.release()
                return
            time.sleep(0.02)
        raise AssertionError("engine still busy")

    def close(self) -> None:
        for s in self.streams:
            s.close()
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()


class BridgeCase(unittest.TestCase):
    timeout = 5.0
    delay = 0.05

    def setUp(self):
        self.rig = Rig(self.timeout, self.delay)
        self.addCleanup(self.rig.close)


# ── the confirm step ──────────────────────────────────────────────────────

class ConfirmTests(BridgeCase):

    def test_send_needs_the_dwell(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        code, body = self.rig.confirm("send", card["card_id"])
        self.assertEqual(code, 409)
        self.assertIn("Too quick", body["error"])
        time.sleep(DWELL)
        code, _ = self.rig.confirm("send", card["card_id"])
        self.assertEqual(code, 200)
        self.assertEqual(face.next("card_closed")["reason"], "send")
        self.assertEqual(face.next("result")["outcome"], "filled")

    def test_send_must_name_the_card_on_screen(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        for stale in (card["card_id"] + 1, card["card_id"] - 1, None, "1"):
            code, body = self.rig.confirm("send", stale)
            self.assertEqual(code, 409, stale)
            self.assertIn("card changed", body["error"])
        self.rig.confirm("cancel")

    def test_cancel_needs_no_card_id(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        code, _ = self.rig.confirm("cancel")
        self.assertEqual(code, 200)
        self.assertEqual(face.next("card_closed")["reason"], "cancel")
        result = face.next("result")
        self.assertFalse(result.get("confirmed"))
        self.assertNotIn("ack_id", result)

    def test_unknown_decision_is_a_cancel(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        code, _ = self.rig.confirm("yes please", card["card_id"])
        self.assertEqual(code, 200)
        self.assertEqual(face.next("card_closed")["reason"], "cancel")

    def test_nothing_is_decided_twice(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 200)
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 409)
        self.assertEqual(self.rig.confirm("cancel")[0], 409)
        face.next("result")
        self.rig.wait_idle()
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 409)

    def test_price_change_kills_the_old_card(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        code, _ = self.rig.confirm("price", card["card_id"], price=80.03)
        self.assertEqual(code, 200)
        new = face.next("card", where=lambda e: e["card_id"] != card["card_id"])
        self.assertEqual(new["card_id"], card["card_id"] + 1)
        self.assertEqual(new["preview"]["price"], 80.05)        # to the tick
        self.assertEqual(new["preview"]["value"], round(65 * 80.05, 2))
        self.assertFalse(new["preview"]["at_market"])
        time.sleep(DWELL)
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 409)
        self.assertEqual(self.rig.confirm("send", new["card_id"])[0], 200)
        self.assertEqual(face.next("inflight")["price"], 80.05)

    def test_new_price_restarts_the_dwell(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        self.rig.confirm("price", card["card_id"], price=75)
        new = face.next("card", where=lambda e: e["card_id"] != card["card_id"])
        code, body = self.rig.confirm("send", new["card_id"])
        self.assertEqual(code, 409)
        self.assertIn("Too quick", body["error"])
        self.rig.confirm("cancel")

    def test_bad_price_leaves_the_card_alone(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        for bad in ("abc", None, True, float("nan"), "inf", 1e308, -5, 0.01, 0, 181):
            code, body = self.rig.confirm("price", card["card_id"], price=bad)
            self.assertEqual(code, 409, bad)
            self.assertTrue(body["error"], bad)
        time.sleep(DWELL)
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 200)
        self.assertEqual(face.next("inflight")["price"], 72.7)

    def test_timeout_cancels(self):
        self.rig.engine.confirm_timeout = 1.0
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        self.assertEqual(face.next("card_closed", timeout=3)["reason"], "timeout")
        self.assertEqual(self.rig.confirm("send", 1)[0], 409)

    def test_sleep_expires_the_card(self):
        # time.monotonic stops while a Mac sleeps; the wall clock doesn't.
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        self.rig.engine._card_wall_deadline = time.time() - 1
        code, body = self.rig.confirm("send", card["card_id"])
        self.assertEqual(code, 409)
        self.assertIn("expired", body["error"])
        self.assertEqual(face.next("card_closed", timeout=2)["reason"], "timeout")

    def test_face_that_goes_away_cancels_its_card(self):
        face, other = self.rig.stream(), self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        other.next("card")
        face.close()
        closed = other.next("card_closed", timeout=2)
        self.assertEqual(closed["reason"], "cancel")

    def test_card_nobody_can_see_is_not_sent(self):
        self.rig.say("buy nifty call")
        self.rig.wait_idle()
        decisions = [e for e in self.rig.log() if e["event"] == "decision"]
        self.assertEqual([d["decision"] for d in decisions], ["no_face"])

    def test_talking_shows_the_mic_level(self):
        self.rig.engine.listen = fakes.fake_modules(0.6)["listen"]
        face = self.rig.stream()
        self.assertEqual(self.rig.post("/talk")[0], 200)
        face.next("state", where=lambda e: e["state"] == "listening")
        levels = [e["level"] for e in face.drain(0.9) if e["type"] == "level"]
        self.assertTrue(levels and max(levels) >= 1.0, levels)
        self.rig.confirm("cancel")

    def test_the_face_hears_when_sayso_is_speaking(self):
        talking = [False]
        self.rig.engine.speak = types.SimpleNamespace(speaking=lambda: talking[0])
        threading.Thread(target=self.rig.engine._speech_watch, args=(0.02,), daemon=True).start()
        face = self.rig.stream()
        talking[0] = True
        self.assertTrue(face.next("speaking", timeout=2)["on"])
        talking[0] = False
        self.assertFalse(face.next("speaking", timeout=2)["on"])
        self.rig.engine._closing = True

    def test_one_command_at_a_time(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        code, _ = self.rig.post("/text", {"text": "funds"})
        self.assertEqual(code, 409)
        self.rig.confirm("cancel")


# ── the truth after send ──────────────────────────────────────────────────

class TruthTests(BridgeCase):
    delay = 0.6        # an order stays out long enough to lose the face

    def send(self, face: Stream, words: str = "buy nifty call") -> dict:
        self.rig.say(words)
        card = face.next("card")
        time.sleep(DWELL)
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 200)
        return card

    def test_outcome_is_replayed_until_acknowledged(self):
        face = self.rig.stream()
        self.send(face)
        result = face.next("result")
        self.assertEqual(result["outcome"], "filled")
        face.close()

        again = self.rig.stream()
        replay = again.next("result")
        self.assertEqual(replay["ack_id"], result["ack_id"])

        code, body = self.rig.post("/ack", {"ack_id": result["ack_id"]})
        self.assertTrue(body["ok"])
        again.close()
        later = self.rig.stream()
        self.assertFalse([e for e in later.drain(0.5) if e["type"] == "result"])

    def test_wrong_ack_keeps_the_outcome(self):
        face = self.rig.stream()
        self.send(face)
        result = face.next("result")
        self.assertFalse(self.rig.post("/ack", {"ack_id": "nope"})[1]["ok"])
        self.assertIn(result["ack_id"], self.rig.bus.held)

    def test_face_lost_while_sending_sees_it_in_flight(self):
        face = self.rig.stream()
        card = self.send(face)
        face.next("inflight")
        face.close()
        back = self.rig.stream()
        inflight = back.next("inflight", timeout=1)
        self.assertEqual(inflight["card_id"], card["card_id"])
        result = back.next("result", timeout=3)
        self.assertEqual(result["outcome"], "filled")

    def test_failure_after_send_says_it_may_be_live(self):
        face = self.rig.stream()
        self.send(face, "buy nifty call boom after")
        result = face.next("result", timeout=3)
        self.assertEqual(result["outcome"], "unknown")
        self.assertIn("may be live", result["speak"])
        self.assertIn("ack_id", result)

    def test_failure_before_card_says_nothing_was_done(self):
        face = self.rig.stream()
        self.rig.say("boom")
        result = face.next("result", timeout=3)
        self.assertTrue(result["blocked"])
        self.assertIn("nothing was done", result["speak"])
        self.assertNotIn("ack_id", result)
        self.assertFalse(self.rig.bus.holding())

    def test_a_resting_order_stays_in_view_until_it_resolves(self):
        face = self.rig.stream()
        self.send(face, "buy nifty call rest")
        self.assertEqual(face.next("result", timeout=3)["outcome"], "resting")
        opened = face.next("working", timeout=2)
        self.assertEqual(opened["state"], "open")
        fill = face.next("fill", timeout=5)
        self.assertEqual(fill["outcome"], "filled")
        done = face.next("working", timeout=2)
        self.assertEqual((done["state"], done["order_no"]), ("done", opened["order_no"]))

    def test_a_fill_is_held_and_logged_until_shown(self):
        face = self.rig.stream()
        self.send(face, "buy nifty call rest")
        result = face.next("result", timeout=3)
        self.rig.post("/ack", {"ack_id": result["ack_id"]})
        fill = face.next("fill", timeout=5)
        self.assertTrue(fill["ack_id"])
        face.close()
        back = self.rig.stream()
        self.assertEqual(back.next("fill", timeout=1)["ack_id"], fill["ack_id"])
        self.rig.post("/ack", {"ack_id": fill["ack_id"]})
        self.assertFalse(self.rig.bus.holding())
        self.rig.wait_idle()
        self.assertTrue(any(e["event"] == "fill" for e in self.rig.log()))

    def test_a_resting_order_is_replayed_to_a_new_connection(self):
        face = self.rig.stream()
        self.send(face, "buy nifty call rest")
        opened = face.next("working", timeout=3)
        face.close()
        back = self.rig.stream()
        again = back.next("working", timeout=1)
        self.assertEqual((again["order_no"], again["state"]), (opened["order_no"], "open"))

    def test_a_watcher_that_dies_says_so(self):
        def crash(order_no, what, every=2.0, limit=300):
            raise RuntimeError("watcher crashed")
        mods = fakes.fake_modules(0.05)
        mods["watch"]._watch = crash
        # The Engine wraps Sayso's follower when it is built.
        bridge.Engine(self.rig.bus, 5.0, modules=mods)
        face = self.rig.stream()
        mods["watch"].follow("X1", "Nifty 23100 put")
        fill = face.next("fill", timeout=3)
        self.assertEqual(fill["outcome"], "unknown")
        self.assertIn("lost track", fill["text"])
        self.assertEqual(face.next("working", timeout=2, where=lambda e: e["state"] == "done")["order_no"], "X1")

    def test_an_engine_following_a_resting_order_is_not_shut_down(self):
        face = self.rig.stream()
        self.send(face, "buy nifty call rest")
        result = face.next("result", timeout=3)
        self.rig.post("/ack", {"ack_id": result["ack_id"]})
        face.next("working", timeout=2)
        face.close()
        end = time.time() + 2
        while self.rig.bus.connected() and time.time() < end:
            time.sleep(0.05)
        code, body = self.rig.post("/shutdown")
        self.assertEqual(code, 409)
        self.assertTrue(body["working"])

    def test_a_fill_reaches_the_face_even_if_the_log_cant_be_written(self):
        face = self.rig.stream()
        saved = bridge.face_log

        def broken(*a, **k):
            raise OSError("disk full")
        bridge.face_log = broken
        try:
            self.rig.engine.watch._tell("Nifty put filled at 61.20.", "filled")
        finally:
            bridge.face_log = saved
        self.assertEqual(face.next("fill", timeout=2)["outcome"], "filled")

    def test_a_watcher_that_fails_after_a_part_fill_still_says_so(self):
        mods = fakes.fake_modules(0.05)

        def part_then_crash(order_no, what, every=2.0, limit=300):
            mods["watch"]._tell(f"{what}: 30 of 65 filled so far.", "partial")
            raise RuntimeError("watcher crashed")
        mods["watch"]._watch = part_then_crash
        bridge.Engine(self.rig.bus, 5.0, modules=mods)
        face = self.rig.stream()
        mods["watch"].follow("X2", "Nifty 23100 put")
        self.assertEqual(face.next("fill", timeout=3)["outcome"], "partial")
        self.assertEqual(face.next("fill", timeout=3)["outcome"], "unknown")

    def test_shutdown_opens_no_new_card(self):
        face = self.rig.stream()
        self.rig.engine._closing = True
        threading.Thread(target=lambda: self.rig.engine._handle("buy nifty call")).start()
        result = face.next("result", timeout=3)
        self.assertFalse(result.get("confirmed"))
        self.assertFalse([e for e in face.drain(0.3) if e["type"] == "card"])
        self.assertTrue(any(e.get("decision") == "shutdown" for e in self.rig.log()))

    def test_no_send_while_shutting_down(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        self.rig.engine._closing = True
        code, body = self.rig.confirm("send", card["card_id"])
        self.assertEqual(code, 409)
        self.assertIn("shutting down", body["error"])
        self.rig.confirm("cancel")

    def test_non_order_results_are_not_held(self):
        face = self.rig.stream()
        self.rig.say("funds")
        face.next("result")
        self.assertFalse(self.rig.bus.holding())

    def test_log_ties_the_decision_to_the_order(self):
        face = self.rig.stream()
        card = self.send(face)
        face.next("result", timeout=3)
        self.rig.wait_idle()
        log = self.rig.log()
        decision = next(e for e in log if e["event"] == "decision")
        outcome = next(e for e in log if e["event"] == "outcome")
        self.assertEqual(decision["decision"], "send")
        self.assertEqual(decision["card_id"], card["card_id"])
        self.assertEqual((decision["symbol"], decision["quantity"], decision["price"]),
                         ("NIFTY29SEP26C23150", 65, 72.7))
        self.assertEqual(outcome["card_id"], card["card_id"])
        self.assertTrue(outcome["tag"].startswith("sayso-"))
        self.assertTrue(outcome["order_no"])
        heard = next(e for e in log if e["event"] == "heard")
        self.assertEqual(heard["text"], "buy nifty call")

    def test_shutdown_lets_the_order_finish(self):
        face = self.rig.stream()
        self.send(face)
        face.next("inflight")
        started = time.time()
        self.rig.engine.shutdown_gracefully()
        self.assertGreater(time.time() - started, 0.2)
        self.assertEqual(face.next("result", timeout=1)["outcome"], "filled")
        self.assertEqual(self.rig.post("/text", {"text": "funds"})[0], 409)

    def test_shutdown_cancels_an_open_card(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        self.rig.engine.shutdown_gracefully()
        self.assertEqual(face.next("card_closed", timeout=1)["reason"], "cancel")


# ── HTTP guards ───────────────────────────────────────────────────────────

class HttpTests(BridgeCase):

    def test_browser_pages_are_refused(self):
        for headers in ({"Origin": "https://evil.example"},
                        {"Host": "evil.example:80"},
                        {"X-Sayso": ""},           # a web page's plain GET
                        {"X-Sayso": "1"}):         # the old fixed value: any local process
            for method, path in (("GET", "/status"), ("POST", "/talk"),
                                 ("POST", "/confirm"), ("GET", "/events")):
                code, _ = self.rig.request(method, path, {} if method == "POST" else None,
                                           headers=headers)
                self.assertEqual(code, 403, (headers, path))

    def test_shutdown_refused_while_a_face_is_connected(self):
        face = self.rig.stream()
        self.assertEqual(self.rig.post("/shutdown")[0], 409)
        self.assertFalse(self.rig.stops)
        face.close()
        end = time.time() + 2
        while self.rig.bus.connected() and time.time() < end:
            time.sleep(0.05)
        self.assertEqual(self.rig.post("/shutdown")[0], 200)
        self.assertTrue(self.rig.stops)

    def test_account_panes_read_in_plain_terms(self):
        code, body = self.rig.request("GET", "/orders")
        self.assertEqual(code, 200)
        row = body["data"][0]
        self.assertEqual(row["side"], "BUY")
        self.assertEqual(row["display"], "Nifty 29 Sep 23150 call")
        code, body = self.rig.request("GET", "/positions")
        self.assertEqual(body["data"][0]["display"], "Nifty 29 Sep 23150 call")
        code, body = self.rig.request("GET", "/funds")
        self.assertIn("available", body["data"])

    def test_account_checks_and_model_retry(self):
        code, body = self.rig.request("GET", "/checks")
        self.assertEqual({c["name"] for c in body["data"]}, {"market data", "NFO segment", "BFO segment"})
        self.assertFalse(self.rig.post("/warm")[1]["ok"])        # already loaded
        _, status = self.rig.request("GET", "/status")
        self.assertIn("market_hours", status)
        self.assertEqual(status["accounts"], ["default"])

    def test_status_carries_ip_facts_not_shell_commands(self):
        _, status = self.rig.request("GET", "/status")
        self.assertEqual(set(status["network"]), {"state", "current", "registered"})

    def test_an_engine_holding_news_is_not_shut_down(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        card = face.next("card")
        time.sleep(DWELL)
        self.rig.confirm("send", card["card_id"])
        face.next("result", timeout=3)
        face.close()
        end = time.time() + 2
        while self.rig.bus.connected() and time.time() < end:
            time.sleep(0.05)
        code, body = self.rig.post("/shutdown")
        self.assertEqual(code, 409)
        self.assertTrue(body["held"])
        self.assertFalse(self.rig.stops)
        self.assertTrue(self.rig.request("GET", "/status")[1]["held"])

    def test_no_login_while_an_order_is_open(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        code, body = self.rig.post("/login", {"client_id": "A_U", "user_id": "A", "secret": "s"})
        self.assertEqual(code, 409)
        self.rig.confirm("cancel")

    def test_a_login_cant_land_while_an_order_is_open(self):
        face = self.rig.stream()
        self.rig.say("buy nifty call")
        face.next("card")
        self.rig.engine._login = (object(), {"secret": "s"})
        self.rig.engine._login_started = time.monotonic()
        ok, message = bridge.Engine.login_complete(self.rig.engine, "code")
        self.assertFalse(ok)
        self.assertIn("order is open", message)
        self.rig.confirm("cancel")

    def test_raising_a_limit_needs_a_yes(self):
        code, body = self.rig.post("/limits", {"changes": {"max_order_value": 5000}})
        self.assertEqual(code, 200)
        self.assertEqual(body["limits"]["max_order_value"], 5000)
        code, body = self.rig.post("/limits", {"changes": {"max_order_value": 90000}})
        self.assertEqual(code, 409)
        self.assertTrue(body["needs_confirmation"])
        code, body = self.rig.post("/limits", {"changes": {"max_order_value": 90000},
                                               "confirmed": True})
        self.assertEqual((code, body["limits"]["max_order_value"]), (200, 90000))
        self.assertEqual(self.rig.post("/limits/reset")[1]["limits"]["max_order_value"], 15000.0)

    def test_a_stale_login_is_refused(self):
        self.rig.engine._login = (object(), {"secret": "s"})
        self.rig.engine._login_started = time.monotonic() - bridge.Engine.LOGIN_TTL - 1
        ok, message = bridge.Engine.login_complete(self.rig.engine, "code")
        self.assertFalse(ok)
        self.assertIn("too long", message)
        self.assertIsNone(self.rig.engine._login)

    def _waiting_login(self, uid):
        engine = self.rig.engine
        engine._login = (object(), {"user_id": "AB123", "secret": "s"})
        engine._login_state = "good"
        engine._login_started = time.monotonic()
        engine.client = types.SimpleNamespace(
            _exchange=lambda api, code, creds: (("tok", uid, "r", uid), None),
            _write_private=lambda *a: self.written.append(a), SESSION_FILE="x")
        self.written = []
        return engine

    def test_a_login_with_someone_elses_state_is_refused_and_keeps_waiting(self):
        engine = self._waiting_login("AB123")
        ok, message = bridge.Engine.login_complete(engine, "code", "evil")
        self.assertFalse(ok)
        self.assertIsNotNone(engine._login)
        self.assertEqual(self.written, [])

    def test_a_login_for_another_account_is_never_saved(self):
        engine = self._waiting_login("ZZ999")
        ok, message = bridge.Engine.login_complete(engine, "code", "good")
        self.assertFalse(ok)
        self.assertIn("different account", message)
        self.assertEqual(self.written, [])

    def test_the_right_account_logs_in_with_or_without_an_echoed_state(self):
        for state in ("good", None):
            engine = self._waiting_login("ab123")
            engine.broker = types.SimpleNamespace(_api=None)
            engine.refresh_status = lambda: None
            ok, _ = bridge.Engine.login_complete(engine, "code", state)
            self.assertTrue(ok)
            self.assertEqual(len(self.written), 1)

    def test_card_ids_differ_between_engine_runs(self):
        a = fakes.FakeEngine(bridge.Bus(), 5)._card_id
        b = fakes.FakeEngine(bridge.Bus(), 5)._card_id
        self.assertNotEqual(a, b)

    def test_status_says_which_engine_this_is(self):
        code, status = self.rig.request("GET", "/status")
        self.assertEqual(code, 200)
        self.assertEqual(status["port"], self.rig.port)

    def test_bad_bodies_are_rejected_not_crashed(self):
        conn = http.client.HTTPConnection(bridge.HOST, self.rig.port, timeout=5)
        conn.request("POST", "/text", "not json", {"Content-Type": "application/json",
                                                   "X-Sayso": TOKEN})
        self.assertEqual(conn.getresponse().status, 400)
        conn.close()
        self.assertEqual(self.rig.post("/text", {"text": ["a"]})[0], 200)
        self.rig.wait_idle()
        self.assertEqual(self.rig.post("/calibrate", {"step": "loud"})[0], 400)
        self.assertEqual(self.rig.post("/nowhere")[0], 404)


# ── the bridge as a process, as the app runs it ───────────────────────────

class ProcessTests(unittest.TestCase):

    def launch(self, port: int, *extra: str):
        import subprocess
        return subprocess.Popen([sys.executable, str(ROOT / "tests" / "scripted_bridge.py"),
                                 "--port", str(port), *extra],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def token_path(self, port: int) -> Path:
        return Path(os.environ["SAYSO_HOME"]) / "logs" / f".token-{port}"

    def status(self, port: int):
        try:
            token = self.token_path(port).read_text()
            conn = http.client.HTTPConnection(bridge.HOST, port, timeout=1)
            conn.request("GET", "/status", headers={"X-Sayso": token})
            return json.loads(conn.getresponse().read())
        except OSError:
            return None

    def test_starts_answers_and_stops_cleanly(self):
        port = free_port()
        proc = self.launch(port)
        self.addCleanup(proc.kill)
        self.addCleanup(proc.stdout.close)
        end = time.time() + 10
        while self.status(port) is None and time.time() < end:
            time.sleep(0.1)
        status = self.status(port)
        self.assertTrue(status and status["account"] == "DEMO01")

        clash = self.launch(port)
        self.assertEqual(clash.wait(timeout=10), 3)      # port taken: said, not looped
        self.assertIn(b"already in use", clash.stdout.read())
        clash.stdout.close()

        # The run's secret: readable by this user only, gone when it stops.
        self.assertEqual(self.token_path(port).stat().st_mode & 0o777, 0o600)
        proc.terminate()
        self.assertEqual(proc.wait(timeout=10), 0)
        self.assertIsNone(self.status(port))
        self.assertFalse(self.token_path(port).exists())

    def test_logs_rotate_instead_of_growing_forever(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "face.jsonl"
            log.write_text("x" * 20)
            bridge.rotate(log, limit=10)
            self.assertFalse(log.exists())
            self.assertEqual((Path(d) / "face.jsonl.1").read_text(), "x" * 20)
            log.write_text("small")
            bridge.rotate(log, limit=10)
            self.assertEqual(log.read_text(), "small")
            bridge.rotate(Path(d) / "missing.jsonl")          # no error

    def test_there_is_no_demo_mode(self):
        self.assertFalse(hasattr(bridge, "DEMO_PORT"))
        self.assertFalse(hasattr(bridge, "FakeEngine"))
        import inspect
        self.assertNotIn("--fake", inspect.getsource(bridge.main))


# ── the real Sayso agent and follower, with only the broker stubbed ───────

class RealAgentTests(unittest.TestCase):
    """Everything else here runs on the scripted agent. This drives
    Sayso's own voice.agent and voice.watch through the bridge over HTTP,
    so real result shapes pass through the confirm step, the held outcome
    and the resting-order follower. Nothing is sent anywhere: the broker's
    functions are replaced for the test."""

    QUOTE = {"stat": "Ok", "lp": "22.44", "bp1": "22.43", "sp1": "22.45", "ti": "0.01",
             "lc": "20.00", "uc": "25.00", "tsym": "YESBANK-EQ", "token": "11915"}

    def setUp(self):
        import shoonya.broker as b
        from shoonya import underlyings
        from voice import agent, safety, speak, watch
        self.b, self.agent, self.watch, self.speak = b, agent, watch, speak
        self.placed: list = []
        self.status_after_place = "COMPLETE"
        state = lambda status, n: {"order_no": n, "status": status, "final": status == "COMPLETE",
                                   "quantity": 1, "filled": 1 if status == "COMPLETE" else 0,
                                   "avg_fill_price": 22.45 if status == "COMPLETE" else None}
        stubs = {
            "quote_checked": lambda *a, **k: dict(self.QUOTE),
            "positions": lambda include_closed=False: [],
            "order_book": lambda: [],
            "place": lambda *a: self.placed.append(a) or {"status": "ACCEPTED", "order_no": "ORD1",
                                                          "tag": "sayso-test"},
            # Sayso's first look sees `status_after_place`; the follower's
            # later look (timeout=0) sees it filled.
            "wait_for_outcome": lambda n, timeout=10.0, **k: state(
                "COMPLETE" if timeout == 0 else self.status_after_place, n),
        }
        self.saved = {name: getattr(b, name) for name in stubs}
        self.saved_watch = (watch._tell, watch._watch)
        self.saved_speak = speak.enabled
        for name, fn in stubs.items():
            setattr(b, name, fn)
        speak.enabled = lambda: False                  # silent
        agent._pending = None
        quiet = types.SimpleNamespace(say=lambda *a, **k: None, interrupt=lambda: None,
                                      announce=lambda *a, **k: None)
        modules = dict(agent=agent, listen=fakes.fake_modules(0)["listen"], safety=safety,
                       speak=quiet, watch=watch, broker=b,
                       client=types.SimpleNamespace(session_user=lambda: "T1"),
                       network=types.SimpleNamespace(facts=lambda: {"state": "ok"}),
                       underlyings=underlyings,
                       instruments=types.SimpleNamespace(market_hours=lambda: True),
                       profile=types.SimpleNamespace(accounts=lambda: ["default"]))
        self.rig = Rig(engine=lambda bus: bridge.Engine(bus, 5.0, modules=modules))

    def tearDown(self):
        self.rig.close()
        for name, fn in self.saved.items():
            setattr(self.b, name, fn)
        self.watch._tell, self.watch._watch = self.saved_watch
        self.speak.enabled = self.saved_speak

    def order(self, face: Stream) -> dict:
        self.rig.say("buy one yesbank intraday")
        card = face.next("card", timeout=5)
        self.assertEqual(card["preview"]["say"], "Buy 1 Yes Bank, intraday.")
        return card

    def test_a_real_order_goes_out_once_at_the_price_on_the_card(self):
        face = self.rig.stream()
        card = self.order(face)
        time.sleep(DWELL)
        self.assertEqual(self.rig.confirm("send", card["card_id"])[0], 200)
        result = face.next("result", timeout=5)
        self.assertEqual(result["outcome"], "filled")
        self.assertTrue(result["ack_id"])
        self.assertEqual(len(self.placed), 1)
        side, tsym, qty, price = self.placed[0][:4]
        self.assertEqual((side, tsym, qty, price), ("B", "YESBANK-EQ", 1, card["preview"]["price"]))

    def test_a_typed_price_reprices_through_sayso(self):
        face = self.rig.stream()
        card = self.order(face)
        self.assertEqual(self.rig.confirm("price", card["card_id"], price=24.5)[0], 200)
        new = face.next("card", where=lambda e: e["card_id"] != card["card_id"])
        self.assertEqual(new["preview"]["value"], 24.5)
        self.assertIn("your price", new["preview"]["unusual"])
        self.rig.confirm("cancel")

    def test_an_account_question_names_its_pane(self):
        face = self.rig.stream()
        self.rig.say("what do I own")
        self.assertEqual(face.next("result", timeout=5).get("show"), "positions")

    def test_a_cancelled_real_order_never_reaches_the_broker(self):
        face = self.rig.stream()
        self.order(face)
        self.rig.confirm("cancel")
        result = face.next("result", timeout=5)
        self.assertFalse(result.get("confirmed"))
        self.assertEqual(self.placed, [])

    def test_a_real_resting_order_is_followed_to_its_fill(self):
        self.status_after_place = "OPEN"
        face = self.rig.stream()
        card = self.order(face)
        time.sleep(DWELL)
        self.rig.confirm("send", card["card_id"])
        self.assertEqual(face.next("result", timeout=5)["outcome"], "resting")
        self.assertEqual(face.next("working", timeout=3)["state"], "open")
        fill = face.next("fill", timeout=6)            # Sayso's follower looks every 2 s
        self.assertEqual(fill["outcome"], "filled")
        self.assertTrue(fill["ack_id"])
        self.assertEqual(face.next("working", timeout=2)["state"], "done")


# ── price checks ──────────────────────────────────────────────────────────

def preview(**kw) -> dict:
    return {"quantity": 65, "price": 72.7, "tick": 0.05, "at_market": True,
            "lower_circuit": 0.05, "upper_circuit": 180.0, **kw}


class PriceTests(unittest.TestCase):

    def test_rounds_to_the_tick(self):
        p = preview()
        self.assertIsNone(bridge.apply_price(p, "80.03"))
        self.assertEqual(p["price"], 80.05)
        self.assertEqual(p["value"], round(65 * 80.05, 2))
        self.assertFalse(p["at_market"])

    def test_refuses_what_is_not_a_price(self):
        for bad in (None, "", "abc", True, False, float("nan"), float("inf"),
                    "-inf", 1e308, -1e308, "1e400", 10**400, [], {}):
            p = preview()
            self.assertTrue(bridge.apply_price(p, bad), bad)
            self.assertEqual(p["price"], 72.7)

    def test_refusals_never_echo_a_huge_input(self):
        self.assertLess(len(bridge.apply_price(preview(), 10**400)), 60)

    def test_zero_after_rounding_is_refused(self):
        p = preview(lower_circuit=None)
        self.assertIn("above zero", bridge.apply_price(p, 0.02))
        self.assertEqual(p["price"], 72.7)

    def test_circuits(self):
        self.assertIn("lower circuit", bridge.apply_price(preview(lower_circuit=10), 9.9))
        self.assertIn("upper circuit", bridge.apply_price(preview(), 180.1))
        self.assertIsNone(bridge.apply_price(preview(), 180))

    def test_same_as_sayso_terminal(self):
        """Where Sayso's own front-end accepts a price, the bridge must
        produce the identical card; where it refuses, so must the bridge."""
        from voice import cli
        from voice.agent import reprice      # the bridge calls Sayso's own, as the terminal does
        cases = ["80.03", "72.7", "0.05", "179.99", "180", "181", "100.024",
                 "1.1", "0.04"]
        for raw in cases:
            for tick in (0.05, 0.1, None):
                terminal = preview(tick=tick)
                ours = preview(tick=tick)
                original = builtins.input
                builtins.input = lambda *_: raw
                try:
                    with redirect_stdout(io.StringIO()):
                        cli._set_price(terminal)
                finally:
                    builtins.input = original
                error = bridge.apply_price(ours, raw, reprice)
                if terminal["price"] == 72.7 and terminal["at_market"]:
                    self.assertTrue(error, (raw, tick))
                else:
                    self.assertIsNone(error, (raw, tick))
                    self.assertEqual(ours, terminal, (raw, tick))


# ── the engine names the bridge relies on ─────────────────────────────────

class ContractTests(unittest.TestCase):
    """The bridge drives Sayso through these names. If the engine renames
    one, this fails here instead of in front of a trader."""

    def test_engine_names(self):
        from voice import agent, calibrate, listen, safety, speak, watch
        import shoonya.broker as broker
        from shoonya import client, instruments, network, profile, underlyings
        need = {
            agent: ["handle", "friendly", "PENDING_SECONDS"],
            listen: ["warm_up", "download_mb", "record_until_silence", "transcribe",
                     "NotCalibrated", "config"],
            speak: ["say", "announce", "interrupt", "speaking"],
            watch: ["_tell", "_watch", "follow"],
            safety: ["status"],
            broker: ["positions", "funds", "order_book", "orders_today", "account_checks", "_api"],
            client: ["Shoonya", "session_user", "_session_alive", "_exchange",
                     "_write_private", "SESSION_FILE", "AUTHORIZE_URL"],
            network: ["check", "facts", "save", "explain"],
            underlyings: ["UNDERLYINGS"],
            calibrate: ["_measure", "SILENT"],
            instruments: ["market_hours"],
            profile: ["accounts", "in_app", "home"],
        }
        for module, names in need.items():
            for name in names:
                self.assertTrue(hasattr(module, name), f"{module.__name__}.{name}")
        self.assertTrue(hasattr(listen.config, "get") and hasattr(listen.config, "save"))
        import inspect
        self.assertIn("on_level", inspect.signature(listen.record_until_silence).parameters)
        self.assertTrue(hasattr(client.Shoonya, "getOAuthURL"))
        for u in underlyings.UNDERLYINGS.values():
            self.assertTrue(u.spoken and u.aliases)

    def test_scripted_engine_matches_the_real_names(self):
        fake = fakes.fake_modules(0)
        for name in ("agent", "listen", "speak", "watch", "safety", "broker",
                     "client", "network", "underlyings", "instruments", "profile"):
            self.assertIn(name, fake)
        self.assertTrue(math.isfinite(fake["agent"].PENDING_SECONDS))


if __name__ == "__main__":
    unittest.main()
