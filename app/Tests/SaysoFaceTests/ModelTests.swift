import XCTest
@testable import SaysoFace

/// The panel's state machine, driven by the same events the bridge sends.
/// No bridge, no network: `client` is nil, so posts go nowhere.
@MainActor
final class ModelTests: XCTestCase {
    private var m: Model!

    override func setUp() async throws {
        UserDefaults.standard.set(true, forKey: Model.noticeKey)   // accepted, as on a Mac already in use
        m = Model()
        m.connectionChanged(true)
        m.apply(status())
    }

    private func status(run: String = "r1") -> [String: Any] {
        ["type": "status", "run": run, "account": "FA12345",
         "logged_in": true, "calibrated": true, "model_ready": true]
    }

    private func card(_ id: Int = 1, run: String = "r1") -> [String: Any] {
        ["type": "card", "run": run, "card_id": id, "display": "Nifty 29 Sep 23150 call",
         "timeout": 20.0,
         "preview": ["action": "BUY", "symbol": "NIFTY29SEP26C23150", "quantity": 65,
                     "lots": 1, "price": 72.7, "value": 4725.5, "tick": 0.05] as [String: Any]]
    }

    private func result(_ outcome: String?, ack: String? = nil, run: String = "r1",
                        extra: [String: Any] = [:]) -> [String: Any] {
        var e: [String: Any] = ["type": "result", "run": run, "speak": "Said back."]
        if let outcome { e["outcome"] = outcome }
        if let ack { e["ack_id"] = ack }
        return e.merging(extra) { $1 }
    }

    func testAModelDownloadSaysHowBigItIs() {
        var s = status(); s["model_ready"] = false; s["model_download_mb"] = 481
        m.apply(s)
        XCTAssertEqual(m.modelLoading, "Downloading the speech model (481 MB, once)…")
        m.apply(status())
        XCTAssertTrue(m.modelReady)
        XCTAssertNil(m.modelDownloadMB)
    }

    // MARK: the card and its keys

    func testCardTakesTheKeysOnlyWhileOpen() {
        XCTAssertEqual(m.shape, .pill)
        XCTAssertFalse(m.cardKeysWanted)
        m.apply(card())
        XCTAssertEqual(m.shape, .card)
        XCTAssertTrue(m.cardKeysWanted)
        m.openPriceEntry()
        XCTAssertFalse(m.cardKeysWanted, "typing a price must not also be y / esc")
        XCTAssertTrue(m.wantsKeyboard)
        m.apply(["type": "card_closed", "run": "r1", "reason": "cancel"])
        XCTAssertEqual(m.shape, .pill)
        XCTAssertFalse(m.cardKeysWanted)
        XCTAssertFalse(m.priceEntry)
    }

    func testNewCardClearsTheOldNotice() {
        m.apply(card(1))
        m.cardNotice = "Too quick. Read the card, then send."
        m.apply(card(2))
        XCTAssertNil(m.cardNotice)
        XCTAssertEqual(m.card?.id, 2)
    }

    func testDisconnectDropsTheCardQuietly() {
        m.apply(card())
        m.connectionChanged(false)
        XCTAssertNil(m.card)
        XCTAssertNil(m.alert, "no order was out, so there is nothing to alarm about")
        XCTAssertEqual(m.shape, .disconnected)
        XCTAssertFalse(m.cardKeysWanted)
    }

    // MARK: the truth after send

    func testLosingTheEngineWithAnOrderOutRaisesTheAlarm() {
        m.apply(card())
        m.apply(["type": "card_closed", "run": "r1", "reason": "send"])
        m.apply(["type": "inflight", "run": "r1", "card_id": 1])
        XCTAssertEqual(m.phase, "sending")
        XCTAssertEqual(m.inflight, 1)
        m.connectionChanged(false)
        XCTAssertEqual(m.alert?.kind, "unknown")
        XCTAssertEqual(m.shape, .alert, "the alarm shows even with the engine gone")
    }

    func testTheEngineComingBackReplacesTheAlarmWithTheTruth() {
        m.apply(["type": "inflight", "run": "r1", "card_id": 1])
        m.connectionChanged(false)
        XCTAssertNotNil(m.alert)
        m.connectionChanged(true)
        m.apply(status())
        m.apply(result("filled", ack: "a1"))
        XCTAssertNil(m.alert)
        XCTAssertEqual(m.outcome?.kind, "filled")
        XCTAssertNil(m.inflight)
    }

    func testARestartedEngineCantClearTheAlarm() {
        m.apply(["type": "inflight", "run": "r1", "card_id": 1])
        m.connectionChanged(false)
        m.connectionChanged(true)
        m.apply(status(run: "r2"))
        XCTAssertNil(m.inflight, "the new engine can't report the old one's order")
        XCTAssertNotNil(m.alert, "so the alarm stays until a human clears it")
        m.clearAlert()
        XCTAssertNil(m.alert)
    }

    func testAnUnknownOutcomeIsAnAlarm() {
        m.apply(["type": "inflight", "run": "r1", "card_id": 1])
        m.apply(result("unknown", ack: "a1"))
        XCTAssertEqual(m.alert?.kind, "unknown")
        XCTAssertEqual(m.shape, .alert)
        XCTAssertNil(m.inflight)
    }

    func testALaterOrdinaryResultDoesntClearARealAlarm() {
        m.apply(result("unknown", ack: "a1"))
        m.apply(result(nil, extra: ["blocked": true]))
        XCTAssertNotNil(m.alert)
    }

    func testAReplayedOutcomeIsShownOnce() {
        m.apply(result("filled", ack: "a1"))
        XCTAssertEqual(m.outcome?.kind, "filled")
        m.outcome = nil
        m.apply(result("filled", ack: "a1"))
        XCTAssertNil(m.outcome)
        m.apply(result("rejected", ack: "a2"))
        XCTAssertEqual(m.outcome?.kind, "rejected")
    }

    // MARK: the right engine

    func testWhyTheEngineIsDownIsShown() {
        m.connectionChanged(false)
        m.engineExited(3)
        XCTAssertTrue(m.engineProblem?.contains(AppMode.port) ?? false)
        m.engineExited(4)
        XCTAssertTrue(m.engineProblem?.contains("couldn't start") ?? false)
        m.connectionChanged(true)
        m.apply(status())
        XCTAssertNil(m.engineProblem)
    }

    // MARK: questions and results

    func testAQuestionIsShownNotItsResultLine() {
        m.apply(["type": "question", "run": "r1", "text": "Which index?", "expires_in": 30.0,
                 "choices": [["label": "Nifty", "say": "nifty"]]])
        m.apply(result(nil, extra: ["needs_answer": "underlying", "blocked": true]))
        XCTAssertEqual(m.shape, .question)
        XCTAssertNil(m.outcome)
        XCTAssertEqual(m.question?.choices.first?.label, "Nifty")
    }

    func testACardReplacesTheQuestion() {
        m.apply(["type": "question", "run": "r1", "text": "Which index?", "expires_in": 30.0])
        m.apply(card())
        XCTAssertNil(m.question)
        XCTAssertEqual(m.shape, .card)
    }

    func testQuietResultIsAToast() {
        m.apply(result(nil, extra: ["quiet": true, "speak": "Nothing heard."]))
        XCTAssertEqual(m.toast, "Nothing heard.")
        XCTAssertNil(m.outcome)
        XCTAssertEqual(m.shape, .strip)
    }

    func testTheMeterOnlyMovesWhileListening() {
        m.apply(["type": "state", "run": "r1", "state": "listening"])
        m.apply(["type": "level", "run": "r1", "level": 2.5])
        XCTAssertEqual(m.level, 2.5)
        m.apply(["type": "state", "run": "r1", "state": "transcribing"])
        XCTAssertEqual(m.level, 0)
    }

    func testAnUnusualOrderHasItsOwnShape() {
        var e = card()
        var p = e["preview"] as! [String: Any]
        p["lots"] = 3; p["quantity"] = 195
        e["preview"] = p
        m.apply(e)
        XCTAssertEqual(m.shape, .cardUnusual)
        XCTAssertTrue(m.cardKeysWanted)
        XCTAssertNotEqual(Shape.card.size, Shape.cardUnusual.size)
    }

    func testAFillIsShownAsQuantityAtPrice() {
        m.apply(card())
        m.apply(["type": "card_closed", "run": "r1", "reason": "send"])
        m.apply(result("filled", ack: "a1", extra: [
            "speak": "Filled. Bought 65 of the Nifty 23150 call at 72.70.",
            "data": ["symbol": "NIFTY29SEP26C23150",
                     "state": ["filled": 65, "avg_fill_price": 72.7]] as [String: Any]]))
        XCTAssertEqual(m.outcome?.text, "Bought 65 @ 72.70")
        XCTAssertEqual(m.outcome?.subject, "Nifty 29 Sep 23150 call")
        XCTAssertEqual(m.outcome?.details, "Filled. Bought 65 of the Nifty 23150 call at 72.70.")
    }

    func testAFillWithoutFiguresKeepsTheEnginesWords() {
        m.apply(result("filled", ack: "a1"))
        XCTAssertEqual(m.outcome?.text, "Said back.")
    }

    func testARestingOrderStaysInViewUntilSaysoStopsFollowingIt() {
        m.apply(["type": "working", "run": "r1", "order_no": "7", "what": "Nifty 23100 put", "state": "open"])
        XCTAssertEqual(m.working["7"], "Nifty 23100 put")
        m.apply(["type": "fill", "run": "r1", "text": "Nifty 23100 put filled at 61.20.", "outcome": "filled"])
        m.apply(["type": "working", "run": "r1", "order_no": "7", "state": "done"])
        XCTAssertTrue(m.working.isEmpty)
    }

    func testNumberKeysOnlyWhileAQuestionHasQuickPicks() {
        XCTAssertEqual(m.pickKeys, 0)
        m.apply(["type": "question", "run": "r1", "text": "Which index?", "expires_in": 30.0,
                 "choices": [["label": "Nifty", "say": "nifty"], ["label": "Bank Nifty", "say": "bank nifty"],
                             ["label": "Sensex", "say": "sensex"]]])
        XCTAssertEqual(m.pickKeys, 3)
        m.apply(card())
        XCTAssertEqual(m.pickKeys, 0, "a card replaces the question and its keys")
        m.apply(["type": "question", "run": "r1", "text": "Which strike?", "expires_in": 30.0])
        XCTAssertEqual(m.pickKeys, 0, "no fixed answers, no keys")
    }

    func testTheChecklistOffersItselfOnceWhenSomethingNeedsFixing() {
        let fresh = Model()
        fresh.connectionChanged(true)
        var s = status()
        s["logged_in"] = false
        fresh.apply(s)
        XCTAssertTrue(fresh.setupOpen)
        XCTAssertEqual(fresh.shape, .setup)
        fresh.closeSetup()
        fresh.apply(s)
        XCTAssertFalse(fresh.setupOpen, "once per launch; after that it's on the dot")
    }

    func testALoadingSpeechModelIsNotSomethingToFix() {
        let fresh = Model()
        fresh.connectionChanged(true)
        var s = status()
        s["model_ready"] = false
        s["network"] = ["state": "ok", "current": "203.0.113.10", "registered": ["203.0.113.10"]]
        fresh.apply(s)
        XCTAssertFalse(fresh.setupOpen)
        XCTAssertFalse(fresh.setupReady)
    }

    func testIPFactsAreRead() {
        var s = status()
        s["network"] = ["state": "mismatch", "current": "192.0.2.30", "registered": ["203.0.113.10"]]
        m.apply(s)
        XCTAssertEqual(m.networkState, "mismatch")
        XCTAssertEqual(m.networkCurrent, "192.0.2.30")
        XCTAssertEqual(m.networkRegistered, ["203.0.113.10"])
        XCTAssertTrue(m.setupNeeded)
    }

    // MARK: order news is never covered

    func testAnOpenPaneNeverHidesAnOrderThatIsOut() {
        for open in ["pane", "setup"] {
            let m = Model()
            m.connectionChanged(true)
            m.apply(status())
            if open == "pane" { m.pane = "positions" } else { m.setupOpen = true }
            m.recompute()
            m.apply(["type": "inflight", "run": "r1", "card_id": 1])
            XCTAssertEqual(m.shape, .strip, "sending shows over the \(open)")
            m.apply(result("rejected", ack: "a1"))
            XCTAssertEqual(m.shape, .strip, "and so does its result")
            XCTAssertEqual(m.outcome?.kind, "rejected")
        }
    }

    func testTalkingPutsTheBookAway() {
        m.pane = "orders"
        m.setupOpen = true
        m.calibrated = false               // opens mic set-up: no microphone prompt
        m.talk()
        XCTAssertNil(m.pane)
        XCTAssertFalse(m.setupOpen)
    }

    func testARefusalAfterAQuestionIsShownAndReleasesTheKeys() {
        m.apply(["type": "question", "run": "r1", "text": "Which index?", "expires_in": 30.0,
                 "choices": [["label": "Nifty", "say": "nifty"], ["label": "Sensex", "say": "sensex"]]])
        XCTAssertEqual(m.pickKeys, 2)
        m.apply(result(nil, extra: ["blocked": true, "speak": "Daily loss limit reached. Nothing was done."]))
        XCTAssertNil(m.question)
        XCTAssertEqual(m.shape, .strip)
        XCTAssertEqual(m.pickKeys, 0)
    }

    func testAFillWaitsBehindANewerOrder() {
        m.apply(["type": "inflight", "run": "r1", "card_id": 2])
        m.apply(["type": "fill", "run": "r1", "text": "Nifty put filled at 61.20.", "outcome": "filled", "ack_id": "f1"])
        XCTAssertNil(m.outcome, "the new order's sending isn't covered")
        m.apply(result("rejected", ack: "a2"))
        XCTAssertEqual(m.outcome?.kind, "rejected", "nor is its result")
        m.outcome = nil
        m.apply(["type": "state", "run": "r1", "state": "idle"])
        XCTAssertEqual(m.outcome?.text, "Nifty put filled at 61.20.", "then the fill")
    }

    func testAFillShownOnceEvenIfReplayed() {
        m.apply(["type": "fill", "run": "r1", "text": "Put filled.", "outcome": "filled", "ack_id": "f1"])
        XCTAssertEqual(m.outcome?.text, "Put filled.")
        m.outcome = nil
        m.apply(["type": "fill", "run": "r1", "text": "Put filled.", "outcome": "filled", "ack_id": "f1"])
        XCTAssertNil(m.outcome)
    }

    func testAWatcherThatLostTrackRaisesTheAlarm() {
        m.apply(["type": "fill", "run": "r1", "text": "I lost track of it.", "outcome": "unknown", "ack_id": "f1"])
        XCTAssertEqual(m.shape, .alert)
    }

    func testRestingOrdersResetWhenTheEngineChanges() {
        m.apply(["type": "working", "run": "r1", "order_no": "7", "what": "Put", "state": "open"])
        m.apply(status(run: "r2"))
        XCTAssertTrue(m.working.isEmpty)
        m.apply(["type": "working", "run": "r2", "order_no": "7", "what": "Put", "state": "open"])
        m.connectionChanged(false)
        XCTAssertTrue(m.working.isEmpty, "replayed on reconnect, not kept stale")
    }

    func testQuittingNeverAbandonsAnOrderSilently() {
        m.apply(["type": "inflight", "run": "r1", "card_id": 1])
        m.quitTimedOut()
        XCTAssertEqual(m.shape, .alert)
        XCTAssertNil(m.inflight, "a second Quit goes through")
        m.apply(result("filled", ack: "a1"))
        XCTAssertNil(m.alert, "the real result replaces the alarm")
    }

    func testAnotherUsersEngineIsUnusable() {
        var s = status()
        s["uid"] = Int(getuid()) + 1
        m.apply(s)
        m.apply(card())
        XCTAssertEqual(m.shape, .disconnected)
        XCTAssertFalse(m.cardKeysWanted)
    }

    func testTheOrderStaysInViewFromSendToResult() {
        m.apply(card())
        m.apply(["type": "card_closed", "run": "r1", "reason": "send"])
        m.apply(["type": "inflight", "run": "r1", "card_id": 1, "action": "BUY", "quantity": 65,
                 "display": "Nifty 29 Sep 23150 call", "symbol": "NIFTY29SEP26C23150"])
        XCTAssertEqual(m.sending, "BUY 65 · Nifty 29 Sep 23150 call")
        m.apply(result("rejected", ack: "a1"))
        XCTAssertEqual(m.outcome?.subject, "BUY 65 · Nifty 29 Sep 23150 call")
        XCTAssertNil(m.sending)
    }

    func testTheAlarmNamesItsOrder() {
        m.apply(["type": "inflight", "run": "r1", "card_id": 1, "action": "EXIT SELL", "quantity": 65,
                 "display": "Nifty 29 Sep 23150 call"])
        m.connectionChanged(false)
        XCTAssertEqual(m.alarmSubject, "SELL 65 · Nifty 29 Sep 23150 call")
    }

    func testASellFillSaysSold() {
        var e = card()
        var p = e["preview"] as! [String: Any]
        p["action"] = "SELL (intraday)"
        e["preview"] = p
        m.apply(e)
        m.apply(result("filled", ack: "a1", extra: ["data": ["state": ["filled": 1, "avg_fill_price": 22.4]] as [String: Any]]))
        XCTAssertEqual(m.outcome?.text, "Sold 1 @ 22.40")
    }

    func testHealthFieldsAreRead() {
        var s = status()
        s["market_hours"] = false
        s["model_error"] = "OSError: no model"
        s["profile"] = "client"
        s["accounts"] = ["default", "client"]
        s["limits"] = ["option_orders_remaining": 7]
        m.apply(s)
        XCTAssertEqual(m.marketHours, false)
        XCTAssertEqual(m.modelError, "OSError: no model")
        XCTAssertEqual(m.profileName, "client")
        XCTAssertEqual(m.accounts, ["default", "client"])
        XCTAssertEqual(m.optionOrdersLeft, 7)
        m.retryModel()
        XCTAssertNil(m.modelError)
    }

    func testDiagnosticsSayWhatSupportNeedsAndNoSecrets() {
        let d = m.diagnostics
        XCTAssertTrue(d.contains("account FA12345"))
        XCTAssertTrue(d.contains("port 8787"))
        XCTAssertFalse(d.lowercased().contains("secret"))
    }

    func testPanesAreSizedToWhatTheyShow() {
        m.pane = "positions"
        m.paneRows = [["symbol": "A"], ["symbol": "B"]]
        m.recompute()
        let two = m.shape.size.height
        m.paneRows = (0..<8).map { ["symbol": "\($0)"] }
        m.recompute()
        XCTAssertGreaterThan(m.shape.size.height, two)
        m.paneRows = (0..<40).map { ["symbol": "\($0)"] }
        m.recompute()
        XCTAssertLessThanOrEqual(m.shape.size.height, 320, "long books scroll")
    }

    func testTheSpeakingMarkFollowsTheEngine() {
        m.apply(["type": "speaking", "run": "r1", "on": true])
        XCTAssertTrue(m.speaking)
        m.connectionChanged(false)
        XCTAssertFalse(m.speaking)
    }

    func testTheFirstRunNoticeComesFirstAndOnlyOnce() {
        UserDefaults.standard.removeObject(forKey: Model.noticeKey)
        defer { UserDefaults.standard.set(true, forKey: Model.noticeKey) }
        let fresh = Model()
        fresh.connectionChanged(true)
        fresh.apply(status())
        XCTAssertEqual(fresh.shape, .notice)
        fresh.talk()
        XCTAssertEqual(fresh.phase, "idle", "nothing is spoken until it's accepted")
        fresh.acceptNotice()
        XCTAssertEqual(fresh.shape, .pill)
        XCTAssertTrue(Model().noticeAccepted, "remembered on this Mac")
    }

    func testCancelledIsNotAFailure() {
        m.apply(result(nil, extra: ["confirmed": false]))
        XCTAssertEqual(m.outcome?.kind, "cancelled")
    }
}
