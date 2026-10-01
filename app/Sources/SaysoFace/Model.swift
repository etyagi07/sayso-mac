import AppKit
import Foundation

/// The panel's shapes. A shape change the system triggers means "eyes needed now".
enum Shape: Equatable {
    case pill, strip, question, card, cardUnusual, alert, login, command, calibrate, setup, limits, notice, disconnected
    case pane(lines: Int)          // sized to what it shows: no dead band under two rows

    /// An unusual order (large, several lots, an exit, a typed price, expiring
    /// today) gets a different proportion, not just different words: it can
    /// be told apart with the text unreadable.
    var isCard: Bool { self == .card || self == .cardUnusual }

    var size: CGSize {
        switch self {
        case .pill:                return CGSize(width: 320, height: 46)
        case .disconnected:        return CGSize(width: 420, height: 52)
        case .strip:               return CGSize(width: 420, height: 78)
        case .question:            return CGSize(width: 440, height: 140)
        case .card:                return CGSize(width: 440, height: 218)
        case .cardUnusual:         return CGSize(width: 440, height: 246)
        case .alert:               return CGSize(width: 440, height: 216)
        case .login:               return CGSize(width: 420, height: 312)
        case .command:             return CGSize(width: 400, height: 78)
        case .calibrate:           return CGSize(width: 420, height: 200)
        case .setup:               return CGSize(width: 460, height: 436)
        case .notice:              return CGSize(width: 440, height: 236)
        case .limits:              return CGSize(width: 460, height: 372)
        case .pane(let lines):     return CGSize(width: 460, height: 84 + 26 * CGFloat(min(max(lines, 1), 9)))
        }
    }
}

struct Card {
    var preview: [String: Any]
    var display: String
    var timeout: Double
    var opened: Date
    var id: Int = 0

    func string(_ k: String) -> String? { preview[k] as? String }
    func number(_ k: String) -> Double? {
        if let d = preview[k] as? Double { return d }
        if let i = preview[k] as? Int { return Double(i) }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let i = preview[k] as? Int { return i }
        if let d = preview[k] as? Double { return Int(d) }
        return nil
    }
}

struct Question {
    var text: String
    var choices: [(label: String, say: String)]
    var expires: Date
    var opened: Date
}

struct Outcome {
    var text: String
    var kind: String          // filled, resting, partial, rejected, unknown, blocked, info, cancelled
    var details: String?
    var subject: String? = nil    // the contract it was about, for a structured result
    var order = false             // news about a real order: nothing may cover it
}

@MainActor
final class Model: ObservableObject {
    weak var client: BridgeClient?

    // connection and account
    @Published var connected = false
    @Published var account: String?
    @Published var loggedIn = false
    @Published var calibrated = true
    @Published var modelReady = false
    @Published var networkState = "unknown"     // ok, mismatch, unset, unknown (Sayso's check)
    @Published var networkCurrent: String?      // this Mac's internet address
    @Published var networkRegistered: [String] = []
    @Published var working: [String: String] = [:]   // order_no -> contract, while Sayso follows it
    @Published var optionOrdersLeft: Int?
    @Published var marketHours: Bool?            // the clock says NSE is open (holidays aren't known)
    @Published var modelError: String?           // the speech model failed to load
    @Published var modelDownloadMB: Int?         // being downloaded now, this big
    /// What the speech model is doing while it isn't ready.
    var modelLoading: String {
        modelDownloadMB.map { "Downloading the speech model (\($0) MB, once)…" } ?? "Loading speech model…"
    }
    @Published var profileName = "default"       // the Sayso account profile in use
    @Published var accounts: [String] = []       // profiles this Mac has used
    @Published var accountChecks: [[String: Any]] = []   // market data, NFO, BFO

    // this account's own limits
    @Published var limits: [String: Any] = [:]          // in force
    @Published var defaultLimits: [String: Any] = [:]
    @Published var limitsLeft: [String: Any] = [:]      // what's left of today's allowances
    @Published var limitsOpen = false
    @Published var limitsMessage: String?
    /// Set by the app: "are you sure?" before any limit goes up.
    var confirmRaise: ((String) -> Bool)?

    // the push-to-talk chord
    @Published var talkKeyLabel = TalkKey.current.label
    @Published var talkKeyWorks = true
    var chooseTalkKey: ((TalkKey) -> Void)?
    @Published var foreignEngine = false      // or belongs to another user on this Mac
    @Published var engineProblem: String?     // why the engine isn't running, if known

    // the flow
    @Published var phase = "idle"             // idle listening transcribing working confirm sending
    @Published var inflight: Int?             // card_id of an order sent, outcome not yet seen
    @Published var sending: String?           // that order, as "BUY 65 · Nifty 29 Sep 23150 call"
    @Published var alarmSubject: String?      // the order the alarm is about
    @Published var alarmCheck: String?        // what today's order book says about it
    private var alarmTag: String?
    private var alarmOrderNo: String?
    private var alarmSymbol: String?
    private var inflightSymbol: String?
    private var lastAction: String?
    @Published var heard: String?
    @Published var level = 0.0                // mic loudness while listening; 1 = speech
    @Published var speaking = false           // Sayso is reading something out

    /// The one-time "this is real money, and not advice" notice, accepted
    /// once per Mac before the first order.
    static let noticeKey = "sayso.notice.accepted.v1"
    @Published var noticeAccepted = UserDefaults.standard.bool(forKey: Model.noticeKey)

    func acceptNotice() {
        noticeAccepted = true
        UserDefaults.standard.set(true, forKey: Model.noticeKey)
        recompute()
    }
    @Published var card: Card?
    @Published var question: Question?
    @Published var outcome: Outcome?
    @Published var alert: Outcome?            // "unknown - may be live": sticky
    @Published var priceEntry = false
    @Published var priceError: String?
    @Published var cardNotice: String?      // e.g. "Too quick. Read the card, then send."
    @Published var loginOpen = false
    @Published var loginMessage: String?
    @Published var loginWaiting = false
    private var loginAttempt = 0
    @Published var commandOpen = false

    // account panes and setup
    @Published var pane: String?                  // positions, orders, funds
    @Published var paneRows: [[String: Any]] = []
    @Published var paneFunds: [String: Any]?
    @Published var paneError: String?
    @Published var paneDetails: String?
    @Published var paneLoading = false
    @Published var setupOpen = false
    @Published var setupMessage: String?
    private(set) var setupByUser = false      // opened by a click, not on its own
    private var setupOffered = false

    // mic set-up
    @Published var calibOpen = false
    @Published var calibStep = "intro"      // intro quiet quietDone speech saved error
    @Published var calibMessage: String?
    @Published var calibNoisy = false
    @Published var calibUntil: Date?
    @Published var calibStarted: Date?
    @Published var micDenied = false
    @Published var toast: String?

    // derived, for the panel
    @Published private(set) var shape: Shape = .disconnected
    @Published private(set) var wantsKeyboard = false
    @Published private(set) var cardKeysWanted = false
    @Published private(set) var pickKeys = 0         // how many quick-pick number keys to capture

    private var outcomeClear: Task<Void, Never>?
    private var shownAcks = Set<String>()     // news already on screen, acknowledged
    private var waitingNews: [(Outcome, String?)] = []   // fills waiting for the strip
    private var lostLink = false              // the alert is ours, raised on a lost connection
    private var engineRun: String?            // which bridge process the events come from
    private var lastCardDisplay: String?      // the contract of the last card, for its result

    func recompute() {
        let s: Shape
        let usable = connected && !foreignEngine
        // An order that is out, or news of one, is never covered by anything.
        let orderNews = inflight != nil || phase == "sending" || outcome?.order == true
        if alert != nil { s = .alert }               // shown even with the engine gone
        else if !noticeAccepted { s = .notice }      // before anything else, once
        else if usable, let c = card { s = CardFacts(c).unusual ? .cardUnusual : .card }
        else if !usable { s = .disconnected }
        else if orderNews { s = .strip }
        else if question != nil { s = .question }
        else if loginOpen { s = .login }
        else if commandOpen { s = .command }
        else if calibOpen { s = .calibrate }
        else if limitsOpen { s = .limits }
        else if phase != "idle" || outcome != nil || toast != nil { s = .strip }
        else if setupOpen { s = .setup }
        else if pane != nil {
            s = .pane(lines: paneLoading || paneError != nil ? 2 : (pane == "funds" ? 4 : paneRows.count))
        }
        else { s = .pill }
        if s != shape { shape = s }
        let kb = (s.isCard && priceEntry) || s == .login || s == .command || s == .limits
            || (s == .setup && setupByUser && (networkState == "mismatch" || networkState == "unset"))
        if kb != wantsKeyboard { wantsKeyboard = kb }
        let ck = s.isCard && !priceEntry
        if ck != cardKeysWanted { cardKeysWanted = ck }
        // 1, 2, 3 pick a quick answer, only while the question is on screen.
        let pk = s == .question ? min(question?.choices.count ?? 0, 3) : 0
        if pk != pickKeys { pickKeys = pk }
    }

    // MARK: events from the bridge

    func apply(_ e: [String: Any]) {
        // Only an engine this window may use is listened to: another user's,
        // or the other mode's, gets no acknowledgements and moves nothing.
        if e["type"] as? String != "status" && foreignEngine { return }
        if let run = e["run"] as? String, run != engineRun {
            // A different engine process: whatever the old one had in flight
            // can no longer be reported. The alert, if any, stays up.
            if engineRun != nil { inflight = nil; working = [:] }   // the new one replays its own
            engineRun = run
        }
        switch e["type"] as? String {
        case "status":
            if e["starting"] as? Bool == true { break }
            foreignEngine = (e["uid"] as? Int).map { $0 != Int(getuid()) } ?? false
            engineProblem = nil
            account = e["account"] as? String
            loggedIn = e["logged_in"] as? Bool ?? false
            calibrated = e["calibrated"] as? Bool ?? true
            modelReady = e["model_ready"] as? Bool ?? false
            if let n = e["network"] as? [String: Any] {
                networkState = n["state"] as? String ?? "unknown"
                networkCurrent = n["current"] as? String
                networkRegistered = n["registered"] as? [String] ?? []
            }
            if let l = e["limits"] as? [String: Any] {
                optionOrdersLeft = l["option_orders_remaining"] as? Int
                limits = l["limits"] as? [String: Any] ?? limits
                defaultLimits = l["default_limits"] as? [String: Any] ?? defaultLimits
                limitsLeft = l.filter { ["orders_remaining", "value_remaining",
                                         "option_orders_remaining"].contains($0.key) }
            }
            marketHours = e["market_hours"] as? Bool
            modelError = e["model_error"] as? String
            modelDownloadMB = e["model_download_mb"] as? Int
            profileName = e["profile"] as? String ?? "default"
            accounts = e["accounts"] as? [String] ?? []
            // First launch, or something broke overnight: show the checklist
            // once, unasked. After that it's on the status dot.
            if !setupOffered && setupNeeded {
                setupOffered = true
                setupOpen = true
            }
        case "state":
            phase = e["state"] as? String ?? "idle"
            if phase != "listening" { level = 0 }
            if phase == "idle" && outcome == nil { showWaitingNews() }
            if phase == "listening" || phase == "working" { outcome = nil; toast = nil }
        case "level":
            level = e["level"] as? Double ?? 0
            return                                // nothing else changes; skip recompute
        case "speaking":
            speaking = e["on"] as? Bool ?? false
            return
        case "heard":
            heard = e["text"] as? String
        case "card":
            lastCardDisplay = e["display"] as? String
            lastAction = (e["preview"] as? [String: Any])?["action"] as? String
            card = Card(preview: e["preview"] as? [String: Any] ?? [:],
                        display: e["display"] as? String ?? "",
                        timeout: e["timeout"] as? Double ?? 20,
                        opened: Date(),
                        id: e["card_id"] as? Int ?? 0)
            priceEntry = false
            priceError = nil
            cardNotice = nil
            question = nil
        case "card_closed":
            card = nil
            priceEntry = false
        case "inflight":
            // Sent. Replayed on every reconnect until the outcome is shown.
            inflight = e["card_id"] as? Int ?? -1
            phase = "sending"
            card = nil
            let action = (e["action"] as? String ?? "").replacingOccurrences(of: "EXIT ", with: "")
            lastAction = action
            inflightSymbol = e["symbol"] as? String
            alarmSymbol = inflightSymbol
            let qty = (e["quantity"] as? NSNumber).map { " \($0.intValue)" } ?? ""
            sending = "\(action.split(separator: " ").first.map(String.init) ?? "")\(qty) · \(e["display"] as? String ?? lastCardDisplay ?? "")"
        case "price_error":
            priceError = e["message"] as? String
        case "question":
            let secs = e["expires_in"] as? Double ?? 30
            let choices = (e["choices"] as? [[String: Any]] ?? []).compactMap { c -> (String, String)? in
                guard let l = c["label"] as? String, let s = c["say"] as? String else { return nil }
                return (l, s)
            }
            question = Question(text: e["text"] as? String ?? "", choices: choices,
                                expires: Date().addingTimeInterval(secs), opened: Date())
        case "result":
            showResult(e)
        case "working":
            guard let no = e["order_no"] as? String else { break }
            if e["state"] as? String == "open" { working[no] = e["what"] as? String ?? "An order" }
            else { working[no] = nil }
        case "fill":
            // What became of a resting order: held by the engine until shown.
            let ack = e["ack_id"] as? String
            if let ack, shownAcks.contains(ack) { client?.post("/ack", ["ack_id": ack]); break }
            if let ack, waitingNews.contains(where: { $0.1 == ack }) { break }   // a replay, already queued
            let kind = e["outcome"] as? String ?? "filled"
            let o = Outcome(text: e["text"] as? String ?? "", kind: kind, details: nil,
                            subject: e["what"] as? String, order: true)
            if kind == "unknown" {
                // Sayso itself plays the alarm sound for this; the panel doesn't add one.
                raiseAlarm(o, orderNo: e["order_no"] as? String)
                alarmSubject = nil                    // the watcher's words already name it
                lostLink = false
                acknowledge(ack)
            } else if alert != nil || phase != "idle" || inflight != nil || outcome != nil {
                // Never over a newer order's "sending" or result: next in line.
                waitingNews.append((o, ack))
            } else {
                show(o)
                acknowledge(ack)
            }
        case "login":
            switch e["state"] as? String {
            case "waiting": loginWaiting = true; loginMessage = "Finish logging in, in your browser."
                // The browser may never come back (a wrong redirect URL on
                // the API key page): don't wait forever. Only for this attempt.
                loginAttempt += 1
                let attempt = loginAttempt
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                    guard let self, self.loginWaiting, self.loginAttempt == attempt else { return }
                    self.loginWaiting = false
                    self.loginMessage = "No reply from the browser. Check the redirect URL on the API key page, then start again."
                }
            case "ok": loginWaiting = false; loginOpen = false; loginMessage = nil
                       toast = "Connected\(account.map { " as \($0)" } ?? "")."
                       clearOutcomeSoon()
            default: loginWaiting = false; loginMessage = e["message"] as? String ?? "Login failed."
            }
        case "calib":
            applyCalib(e)
        case "error":
            show(Outcome(text: e["message"] as? String ?? "Something went wrong.",
                         kind: "blocked", details: e["details"] as? String))
        default:
            break
        }
        recompute()
    }

    private func showResult(_ e: [String: Any]) {
        // The outcome of a sent order carries an ack_id. The engine keeps
        // replaying it until told it has been shown.
        let ack = e["ack_id"] as? String
        if let ack, shownAcks.contains(ack) {            // a replay of one already shown
            client?.post("/ack", ["ack_id": ack])
            return
        }
        if let ack, waitingNews.contains(where: { $0.1 == ack }) { return }
        defer {
            if ack != nil, let p = pane { openPane(p) }  // an open book shows the new order
        }
        let text = e["speak"] as? String ?? ""
        if e["quiet"] as? Bool == true { toast = text; clearOutcomeSoon(); return }
        let kind: String
        if let o = e["outcome"] as? String { kind = o }
        else if e["needs_answer"] != nil { return }          // the question card shows it
        else if e["blocked"] as? Bool == true { kind = "blocked" }
        else if e["confirmed"] as? Bool == false { kind = "cancelled" }
        else { kind = "info" }
        // Every outcome of a sent order keeps its contract in view.
        var o = Outcome(text: text, kind: kind, details: e["details"] as? String,
                        subject: ack != nil ? (sending ?? lastCardDisplay) : nil, order: ack != nil)
        if kind == "filled", let fill = Self.fill(e["data"]) {
            // Structured: what traded and at what, over the contract. The
            // engine's full sentence stays one hover away.
            let verb = (lastAction ?? "").contains("SELL") ? "Sold" : "Bought"
            o = Outcome(text: "\(verb) \(fill.qty) @ \(Fmt.price(fill.avg))", kind: kind,
                        details: text, subject: lastCardDisplay, order: true)
        }
        // Resting and part-filled results are structured like fills: the
        // engine's sentence (with its order number) stays one click away.
        if let d = e["data"] as? [String: Any], ack != nil {
            let st = d["state"] as? [String: Any] ?? d
            func num(_ k: String) -> Double? { (st[k] as? NSNumber)?.doubleValue }
            if kind == "resting", let price = num("price") {
                o = Outcome(text: "Resting @ \(Fmt.price(price))", kind: kind, details: text,
                            subject: o.subject, order: true)
            } else if kind == "partial", let filled = num("filled"), let qty = num("quantity") {
                let at = num("avg_fill_price").map { " @ \(Fmt.price($0))" } ?? ""
                o = Outcome(text: "Part filled \(Int(filled))/\(Int(qty))\(at)", kind: kind, details: text,
                            subject: o.subject, order: true)
            }
        }
        let symbol = alarmSymbol
        if ack != nil { sending = nil; inflight = nil }  // its fate is known now
        let data = e["data"] as? [String: Any]
        if kind == "unknown" {
            // Sayso itself plays the alarm sound with this result.
            raiseAlarm(o, tag: data?["tag"] as? String, orderNo: data?["order_no"] as? String, symbol: symbol)
            lostLink = false
            acknowledge(ack)
        } else if lostLink && ack != nil {
            // The engine came back and said what really happened.
            alert = nil
            lostLink = false
            show(o)
            acknowledge(ack)
        } else if alert != nil && ack != nil {
            // An alarm is on screen: this news waits behind it, and is only
            // acknowledged once it has actually been shown.
            waitingNews.append((o, ack))
        } else if let pane = e["show"] as? String, ack == nil {
            openPane(pane)                       // "what do I own?" answered as a table
        } else {
            show(o)
            acknowledge(ack)
        }
        question = nil          // a question's own result returned above
    }

    /// The loud state, naming the order it is about.
    private func raiseAlarm(_ o: Outcome, tag: String? = nil, orderNo: String? = nil, symbol: String? = nil) {
        alert = o
        alarmSubject = o.subject ?? sending ?? lastCardDisplay
        alarmTag = tag
        alarmOrderNo = orderNo
        alarmSymbol = symbol
        alarmCheck = nil
        if card != nil {
            // A card can't wait under an alarm and be sent the moment it
            // clears: nobody was looking at it.
            cancel()
            card = nil
            priceEntry = false
        }
    }

    /// Look the alarm's order up in today's order book, from the panel.
    func checkAlarmOrder() {
        alarmCheck = "Checking today's orders…"
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            let (code, body) = await client.get("/orders")
            guard code == 200, let rows = body["data"] as? [[String: Any]] else {
                self.alarmCheck = code == 0 ? "Can't reach the engine to check. Use the broker's app."
                                            : "Couldn't read the order book. Use the broker's app."
                return
            }
            // By order number, then tag, then contract: rows come newest first.
            let row = rows.first { self.alarmOrderNo != nil && $0["order_no"] as? String == self.alarmOrderNo }
                ?? rows.first { self.alarmTag != nil && $0["tag"] as? String == self.alarmTag }
                ?? rows.first { self.alarmSymbol != nil && $0["symbol"] as? String == self.alarmSymbol }
            guard let row else {
                self.alarmCheck = "Not in today's order book yet. Check again in a moment."
                return
            }
            let status = OrderWords.status(row["status"] as? String ?? "?")
            let qty = (row["filled"] as? NSNumber)?.intValue ?? 0
            let of = (row["quantity"] as? NSNumber)?.intValue ?? 0
            let at = ((row["avg_fill_price"] ?? row["price"]) as? NSNumber).map { " @ \(Fmt.price($0.doubleValue))" } ?? ""
            let time = String((row["time"] as? String ?? "").prefix(5))
            self.alarmCheck = "Order book: \(status), \(qty) of \(of)\(at)\(time.isEmpty ? "" : " · \(time)")"
        }
    }

    /// Tell the engine this news is on screen, so it stops replaying it.
    private func acknowledge(_ ack: String?) {
        guard let ack else { return }
        shownAcks.insert(ack)
        client?.post("/ack", ["ack_id": ack])
    }

    private func showWaitingNews() {
        guard alert == nil, phase == "idle", inflight == nil, outcome == nil, !waitingNews.isEmpty else { return }
        let (o, ack) = waitingNews.removeFirst()
        show(o)
        acknowledge(ack)
    }

    /// Quantity and average price of a fill, from the engine's order data.
    static func fill(_ data: Any?) -> (qty: Int, avg: Double)? {
        guard let d = data as? [String: Any] else { return nil }
        let st = d["state"] as? [String: Any] ?? d
        let qty = ((st["filled"] ?? d["filled"]) as? NSNumber)?.intValue
        let avg = ((st["avg_fill_price"] ?? d["avg_fill_price"]) as? NSNumber)?.doubleValue
        guard let qty, let avg, qty > 0, avg > 0 else { return nil }
        return (qty, avg)
    }

    private func show(_ o: Outcome) {
        outcome = o
        clearOutcomeSoon(o.kind == "info" ? 8 : 5)
    }

    private func clearOutcomeSoon(_ seconds: Double = 4) {
        outcomeClear?.cancel()
        outcomeClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.outcome = nil
            self?.toast = nil
            self?.heard = nil
            self?.showWaitingNews()
            self?.recompute()
        }
    }

    func connectionChanged(_ up: Bool) {
        if !up && connected && inflight != nil && alert == nil {
            // An order was out and its result can't reach us now.
            raiseAlarm(Outcome(text: "Lost contact with the engine while your order was going out.",
                               kind: "unknown", details: nil), symbol: inflightSymbol)
            lostLink = true
            NSSound(named: "Sosumi")?.play()
        }
        connected = up
        if !up {
            // The bridge cancels an open card the moment the face goes away,
            // and replays resting orders when it comes back.
            card = nil; question = nil; phase = "idle"; priceEntry = false; working = [:]; speaking = false
        }
        recompute()
    }

    /// Quitting waited and the order still hasn't reported back: don't quit,
    /// say so the loud way. A second Quit goes through.
    func quitTimedOut() {
        raiseAlarm(Outcome(text: "No word yet on the order you sent, so Sayso didn't quit.",
                           kind: "unknown", details: nil, order: true))
        lostLink = true
        inflight = nil
        toast = nil
        NSSound(named: "Sosumi")?.play()
        recompute()
    }

    func engineExited(_ code: Int32) {
        switch code {
        case 3: engineProblem = "Another app is using port \(AppMode.port), which Sayso needs."
        case 4: engineProblem = "Sayso's engine couldn't start. Its log has the reason."
        case 0: engineProblem = nil
        default: engineProblem = "Sayso's engine stopped. Restarting…"
        }
        recompute()
    }

    /// A refused or unanswered command says so, instead of doing nothing.
    private func refused(_ code: Int, _ body: [String: Any]) {
        guard code != 200 else { return }
        switch code {
        case 409: toast = "Busy. Finish what's on screen first."
        case 0: toast = "No answer from the engine."
        default: toast = body["error"] as? String ?? "That didn't go through."
        }
        clearOutcomeSoon()
        recompute()
    }

    // MARK: user actions

    func talk() {
        guard noticeAccepted, connected, !foreignEngine, card == nil, alert == nil else { return }
        // Speaking is a new command: the book and the checklist step aside.
        pane = nil; setupOpen = false
        if !calibrated { openCalibration(); return }
        Task { [weak self] in
            guard let self else { return }
            // Permission is settled before recording starts, never during it.
            guard await MicAccess.ensure() == .granted else {
                self.micDenied = true
                self.show(Outcome(text: MicAccess.deniedMessage, kind: "blocked", details: nil))
                self.recompute()
                return
            }
            self.question = nil
            self.client?.post("/talk") { [weak self] in self?.refused($0, $1) }
        }
    }

    func send() {
        guard let c = card, !priceEntry, !foreignEngine else { return }
        client?.post("/confirm", ["decision": "send", "card_id": c.id]) { [weak self] code, body in
            if code != 200 { self?.cardNotice = body["error"] as? String ?? "No answer from the engine." }
        }
    }
    func cancel() {
        client?.post("/confirm", ["decision": "cancel"]) { [weak self] code, _ in
            // 409 means it was already closed. No answer: the engine cancels
            // the card itself when it loses this window, or on its timeout.
            if code == 0 { self?.cardNotice = "No answer from the engine." }
        }
    }

    /// The Mac is going to sleep: nothing stays open across it.
    func sleeping() {
        if card != nil { cancel() }
    }

    func openPriceEntry() {
        guard card != nil else { return }
        priceEntry = true
        priceError = nil
        recompute()
    }

    func closePriceEntry() {
        priceEntry = false
        priceError = nil
        recompute()
    }

    func submitPrice(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let price = Double(cleaned), price.isFinite, let c = card else {
            priceError = "'\(raw)' is not a price."; return
        }
        client?.post("/confirm", ["decision": "price", "price": price, "card_id": c.id]) { [weak self] code, body in
            guard let self else { return }
            if code == 200 { self.closePriceEntry() }
            else { self.priceError = body["error"] as? String ?? "That price wasn't accepted." }
        }
    }

    func answer(_ say: String) {
        guard noticeAccepted, alert == nil else { return }
        client?.post("/text", ["text": say]) { [weak self] in self?.refused($0, $1) }
    }

    func runCommand(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        commandOpen = false
        recompute()
        guard !t.isEmpty else { return }
        client?.post("/text", ["text": t]) { [weak self] in self?.refused($0, $1) }
    }

    func openCommand() { guard noticeAccepted, connected, !foreignEngine, card == nil, alert == nil else { return }; commandOpen = true; recompute() }
    func closeCommand() { commandOpen = false; recompute() }
    func openLogin() { loginOpen = true; loginMessage = nil; recompute() }
    func closeLogin() { loginOpen = false; loginWaiting = false; recompute() }

    func login(clientID: String, userID: String, secret: String, ip: String) {
        loginMessage = nil
        let ips = ip.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        if !ips.isEmpty { client?.post("/network", ["ips": ips]) }
        client?.post("/login", ["client_id": clientID, "user_id": userID, "secret": secret]) { [weak self] code, body in
            if code != 200 { self?.loginMessage = body["error"] as? String ?? "Couldn't start the login." }
        }
    }

    // MARK: setup and health

    /// Everything a first order needs, as Sayso reports it.
    var setupReady: Bool { !setupNeeded && modelReady }

    /// Something only the user can fix (the speech model just loads).
    var setupNeeded: Bool {
        !loggedIn || !calibrated || networkState == "mismatch" || networkState == "unset"
    }

    func openSetup() {
        setupOpen = true; setupByUser = true; setupMessage = nil; recompute()
        guard loggedIn else { accountChecks = []; return }
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            let (code, body) = await client.get("/checks")
            if code == 200, let rows = body["data"] as? [[String: Any]] { self.accountChecks = rows }
        }
    }

    // MARK: limits

    func openLimits() { limitsOpen = true; limitsMessage = nil; recompute() }
    func closeLimits() { limitsOpen = false; limitsMessage = nil; recompute() }

    static let limitNames = [
        "max_order_value": "per stock order", "max_value_per_day": "stocks a day",
        "max_orders_per_day": "stock orders a day", "max_quantity": "shares per order",
        "max_option_orders_per_day": "option orders a day", "max_lots": "lots per order"]

    /// Lowering applies at once. Raising asks "are you sure?" first, and the
    /// engine refuses a raise that wasn't confirmed.
    func saveLimits(_ changes: [String: Any], confirmed: Bool = false) {
        guard !changes.isEmpty else { closeLimits(); return }
        var body: [String: Any] = ["changes": changes]
        if confirmed { body["confirmed"] = true }
        client?.post("/limits", body) { [weak self] code, reply in
            guard let self else { return }
            switch code {
            case 200:
                self.closeLimits()
                self.toast = "Limits saved."
                self.recompute()
            case 409 where reply["needs_confirmation"] as? Bool == true:
                let raised = (reply["raised"] as? String ?? "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { Model.limitNames[$0] ?? $0 }.joined(separator: ", ")
                if self.confirmRaise?(raised) == true {
                    self.saveLimits(changes, confirmed: true)
                } else {
                    self.limitsMessage = "Not raised. Nothing changed."
                }
            case 0:
                self.limitsMessage = "No answer from the engine."
            default:
                self.limitsMessage = reply["error"] as? String ?? "Those limits weren't accepted."
            }
        }
    }

    func resetLimits() {
        client?.post("/limits/reset") { [weak self] code, _ in
            guard let self else { return }
            if code == 200 { self.closeLimits(); self.toast = "Limits back to the defaults."; self.recompute() }
            else { self.limitsMessage = "No answer from the engine." }
        }
    }

    func retryModel() {
        modelError = nil
        client?.post("/warm")
        recompute()
    }

    /// Set by the app: switch account profile, copy diagnostics, open logs.
    var switchAccount: ((String) -> Void)?
    var newAccount: (() -> Void)?
    var copyDiagnostics: (() -> Void)?
    var openLogs: (() -> Void)?

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// What it takes to trace a problem, and nothing secret.
    var diagnostics: String {
        [
            "Sayso \(Model.version) · port \(AppMode.port)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "connected \(connected) · engine problem: \(engineProblem ?? "none")",
            "account \(account ?? "—") · profile \(profileName) · logged in \(loggedIn)",
            "IP \(networkState) · current \(networkCurrent ?? "?") · registered \(networkRegistered.joined(separator: ", "))",
            "speech model \(modelReady ? "ready" : (modelError ?? "loading")) · mic calibrated \(calibrated)",
            "market hours \(marketHours.map(String.init) ?? "?") · option orders left \(optionOrdersLeft.map(String.init) ?? "?")",
            "phase \(phase) · in flight \(inflight.map(String.init) ?? "none") · resting \(working.count)",
        ].joined(separator: "\n")
    }
    func closeSetup() { setupOpen = false; setupByUser = false; recompute() }

    func saveIPs(_ raw: String) {
        let ips = raw.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        guard !ips.isEmpty else { setupMessage = "Type the IP address from the API key page."; return }
        client?.post("/network", ["ips": ips]) { [weak self] code, _ in
            switch code {
            case 200: self?.setupMessage = nil
            case 0: self?.setupMessage = "No answer from the engine."
            default: self?.setupMessage = "That isn't an IP address."
            }
        }
    }

    // MARK: account panes

    func openPane(_ which: String) {
        guard connected, !foreignEngine else { return }
        pane = which
        paneRows = []; paneFunds = nil; paneError = nil; paneDetails = nil; paneLoading = true
        recompute()
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            let (code, body) = await client.get("/\(which)")
            guard self.pane == which else { return }        // closed or switched meanwhile
            self.paneLoading = false
            if code != 200 {
                self.paneError = "No answer from the engine."
            } else if let raw = body["error"] as? String {
                // The broker's own words go behind "details" (CLAUDE.md rule 19).
                self.paneError = self.loggedIn ? "Couldn't read your \(which) from Shoonya."
                                               : "Log in to see your \(which)."
                self.paneDetails = raw
            } else if let rows = body["data"] as? [[String: Any]] {
                self.paneRows = rows
            } else if let funds = body["data"] as? [String: Any] {
                self.paneFunds = funds
            }
            self.recompute()
        }
    }

    func closePane() { pane = nil; recompute() }

    func pick(_ i: Int) {
        guard let q = question, q.choices.indices.contains(i) else { return }
        answer(q.choices[i].say)
    }

    func clearAlert() {
        alert = nil
        alarmCheck = nil
        if lostLink { inflight = nil; lostLink = false }
        showWaitingNews()
        recompute()
    }

    // MARK: mic set-up

    func openCalibration() {
        calibOpen = true; calibStep = "intro"; calibMessage = nil; calibNoisy = false
        recompute()
    }
    func closeCalibration() { calibOpen = false; recompute() }

    func measure(_ step: String) {
        calibMessage = nil
        Task { [weak self] in
            guard let self else { return }
            // Ask for the microphone first. The countdown starts only
            // once it's granted, so the prompt never lands mid-measurement.
            guard await MicAccess.ensure() == .granted else {
                self.micDenied = true
                self.calibStep = "error"
                self.calibMessage = MicAccess.deniedMessage
                self.recompute()
                return
            }
            self.micDenied = false
            self.client?.post("/calibrate", ["step": step]) { [weak self] code, _ in
                if code == 409 { self?.calibMessage = "Busy — finish what's on screen first." }
            }
        }
    }

    private func applyCalib(_ e: [String: Any]) {
        let step = e["step"] as? String ?? ""
        switch e["state"] as? String {
        case "measuring":
            calibStep = step == "quiet" ? "quiet" : "speech"
            calibStarted = Date()
            calibUntil = Date().addingTimeInterval(e["seconds"] as? Double ?? 3)
        case "done":
            calibStep = "quietDone"
            calibNoisy = e["noisy"] as? Bool ?? false
        case "saved":
            calibStep = "saved"
            calibrated = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.closeCalibration()
            }
        default:
            calibStep = "error"
            calibMessage = e["message"] as? String ?? "Couldn't measure the microphone."
        }
    }
}

/// How an order's broker status is put to a trader, everywhere it shows.
enum OrderWords {
    static func status(_ s: String) -> String {
        switch s {
        case "COMPLETE": return "filled"
        case "OPEN", "PENDING", "TRIGGER_PENDING": return "working"
        case "CANCELED": return "cancelled"
        default: return s.lowercased()
        }
    }
}
