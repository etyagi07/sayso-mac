import AppKit
import SwiftUI

/// `Sayso --snapshot DIR` renders every panel state to PNG with sample data and
/// exits. No engine, no window, no screen recording needed (CLAUDE.md rule 10).
@MainActor
enum Snapshot {
    /// True while rendering to PNG: views that need a live window (the blur)
    /// step aside.
    static var active = false

    /// `Sayso --icon FILE.png` renders the 1024 px app icon (build.sh uses it).
    static func iconIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--icon"), i + 1 < args.count else { return false }
        let r = ImageRenderer(content: AppIconView())
        r.scale = 1
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        return true
    }

    /// Every panel state with sample data: rendered by --snapshot, and checked
    /// by the fit test (each state's content must fit its window).
    static func states() -> [(String, (Model) -> Void)] {
        let option: [String: Any] = [
            "action": "BUY", "symbol": "NIFTY29SEP26C23150", "quantity": 65, "lots": 1,
            "price": 72.70, "value": 4725.50, "ltp": 72.55, "at_market": true,
            "bid": 72.50, "ask": 72.60, "tick": 0.05, "lower_circuit": 0.05, "upper_circuit": 180.0,
            "when": "weekly", "underlying": "Nifty", "strike": 23150, "expiry": "2026-09-29",
            "option_type": "CE"]
        var sell = option
        sell["action"] = "SELL"
        var big = option
        big["lots"] = 3; big["quantity"] = 195; big["value"] = 14176.50; big["when"] = "expires today"
        big["price"] = 72.70
        let exit: [String: Any] = [
            "action": "EXIT SELL", "symbol": "NIFTY29SEP26C23150", "quantity": 65,
            "price": 72.40, "value": 4706.00, "ltp": 72.75, "at_market": true,
            "bid": 72.50, "ask": 72.65, "entry": 72.35, "pnl": 3.25, "lots": 1, "tick": 0.05,
            "underlying": "Nifty", "strike": 23150, "option_type": "CE", "expiry": "2026-09-29",
            "when": "weekly"]
        let stock: [String: Any] = [
            "action": "BUY (intraday)", "symbol": "RELIANCE-EQ", "company": "Reliance Industries",
            "quantity": 10, "price": 2951.10, "value": 29511.0, "ltp": 2950.40, "at_market": false,
            "bid": 2950.20, "ask": 2950.60, "tick": 0.05, "product": "intraday"]

        func card(_ p: [String: Any], _ display: String) -> Card {
            Card(preview: p, display: display, timeout: 20, opened: Date().addingTimeInterval(-6))
        }

        return [
            ("1-pill", { _ in }),
            ("2-pill-logged-out", { $0.loggedIn = false }),
            ("3-listening", { $0.phase = "listening"; $0.level = 2.0 }),
            ("26-refused-heard", { $0.heard = "buy nifty call on sensex"; $0.outcome = Outcome(text: "I heard both Nifty and Sensex, so nothing was done.", kind: "blocked", details: nil) }),
            ("4-card-option", { $0.card = card(option, "Nifty 29 Sep 23150 call"); $0.heard = "buy nifty call two three one five zero" }),
            ("5-card-unusual", { $0.card = card(big, "Nifty 29 Sep 23150 call") }),
            ("6-card-exit", { $0.card = card(exit, "Nifty 29 Sep 23150 call") }),
            ("37-card-strike-adjusted", { var p = option; p["strike"] = 23100; p["strike_adjusted_from"] = 23075; p["unusual"] = ["23075 isn't listed"]; $0.card = card(p, "Nifty 29 Sep 23100 call") }),
            ("42-first-run-notice", { $0.noticeAccepted = false }),
            ("39-card-sell", { $0.card = card(sell, "Nifty 29 Sep 23150 call") }),
            ("41-card-reading-back", { $0.card = card(option, "Nifty 29 Sep 23150 call"); $0.speaking = true }),
            ("38-card-atm", { var p = option; p["strike_chosen"] = "atm"; $0.card = card(p, "Nifty 29 Sep 23150 call") }),
            ("27-card-exit-worst", { $0.card = card(exit, "Nifty 29 Sep 23150 call"); $0.heard = "exit my nifty call"; $0.cardNotice = "Too quick. Read the card, then send." }),
            ("28-card-plain-worst", { $0.card = card(option, "Nifty 29 Sep 23150 call"); $0.heard = "buy nifty call two three one five zero"; $0.cardNotice = "Too quick. Read the card, then send." }),
            ("7-card-stock-priced", { $0.card = card(stock, "Reliance") }),
            ("8-card-price-entry", { $0.card = card(option, "Nifty 29 Sep 23150 call"); $0.priceEntry = true; $0.priceError = "999.00 is above the upper circuit 180.00." }),
            ("9-question", { $0.question = Question(text: "Which index for that call - Nifty, Bank Nifty or Sensex?",
                                                    choices: [("Nifty", "nifty"), ("Bank Nifty", "bank nifty"), ("Sensex", "sensex")],
                                                    expires: Date().addingTimeInterval(21), opened: Date().addingTimeInterval(-9)) }),
            ("10-sending", { $0.phase = "sending"; $0.heard = "buy nifty call"; $0.sending = "BUY 65 · Nifty 29 Sep 23150 call" }),
            ("11-filled", { $0.outcome = Outcome(text: "Bought 65 @ 72.35", kind: "filled", details: "Filled. Bought 65 of the Nifty 23150 call at 72.35.", subject: "Nifty 29 Sep 23150 call", order: true) }),
            ("12-rejected", { $0.outcome = Outcome(text: "Rejected by the broker. Margin shortfall.", kind: "rejected", details: "RMS:Margin Exceeds", subject: "BUY 65 · Nifty 29 Sep 23150 call", order: true) }),
            ("13-may-be-live", { $0.alert = Outcome(text: "I can't confirm that order went through. The connection dropped and I couldn't find it in your order book. Check your order book before you try again.", kind: "unknown", details: "sayso-3f9a1c2b7e"); $0.alarmSubject = "BUY 65 · Nifty 29 Sep 23150 call"; $0.alarmCheck = "Order book: complete, 65 of 65 @ 72.35 · 09:21" }),
            ("36-refused", { $0.heard = "buy nifty call two lots of"; $0.outcome = Outcome(text: "I didn't catch how many lots. Say the whole order again.", kind: "blocked", details: nil) }),
            ("14-login", { $0.loginOpen = true }),
            ("15-command", { $0.commandOpen = true }),
            ("16-disconnected", { $0.connected = false }),
            ("24-lost-while-sending", { $0.connected = false; $0.alert = Outcome(text: "Lost contact with the engine while your order was going out.", kind: "unknown", details: nil) }),
            ("25-port-taken", { $0.connected = false; $0.engineProblem = "Port 8787 is taken by another program." }),
            ("18-mic-intro", { $0.calibOpen = true }),
            ("19-mic-measuring", { $0.calibOpen = true; $0.calibStep = "speech"; $0.calibStarted = Date().addingTimeInterval(-2); $0.calibUntil = Date().addingTimeInterval(3) }),
            ("20-mic-noisy", { $0.calibOpen = true; $0.calibStep = "quietDone"; $0.calibNoisy = true }),
            ("22-mic-step2-ready", { $0.calibOpen = true; $0.calibStep = "quietDone" }),
            ("23-mic-step1-measuring", { $0.calibOpen = true; $0.calibStep = "quiet"; $0.calibStarted = Date().addingTimeInterval(-1); $0.calibUntil = Date().addingTimeInterval(2) }),
            ("21-pill-mic-not-set", { $0.calibrated = false }),
            ("29-pane-positions", { $0.pane = "positions"; $0.paneRows = [
                ["symbol": "NIFTY29SEP26C23150", "display": "Nifty 29 Sep 23150 call", "qty": 65, "avg_price": 72.35, "ltp": 74.10, "unrealised_pnl": 113.75],
                ["symbol": "YESBANK-EQ", "display": "YESBANK", "qty": -5, "avg_price": 22.40, "ltp": 22.55, "unrealised_pnl": -0.75]] }),
            ("30-pane-orders", { $0.pane = "orders"; $0.paneRows = [
                ["display": "Nifty 29 Sep 23150 call", "side": "BUY", "status": "COMPLETE", "quantity": 65, "filled": 65, "avg_fill_price": 72.35, "time": "09:21:04 29-09-2026", "tag": "sayso-1a2b"],
                ["display": "Nifty 29 Sep 23100 put", "side": "BUY", "status": "OPEN", "quantity": 65, "filled": 0, "price": 61.20, "time": "09:40:12 29-09-2026", "tag": "sayso-3c4d"],
                ["display": "YESBANK", "side": "SELL", "status": "REJECTED", "quantity": 5, "filled": 0, "price": 22.40, "time": "10:02:55 29-09-2026", "reason": "RMS: margin"]] }),
            ("31-pane-funds", { $0.pane = "funds"; $0.paneFunds = ["available": 184250.5, "cash_settled": 180000.0, "payin_today": 4250.5, "blocked": 0.0] }),
            ("32-setup-first-run", { $0.setupOpen = true; $0.loggedIn = false; $0.calibrated = false; $0.networkState = "mismatch"; $0.networkCurrent = "198.51.100.7"; $0.networkRegistered = ["203.0.113.10"] }),
            ("33-setup-ready", { $0.setupOpen = true; $0.networkCurrent = "203.0.113.10"; $0.networkRegistered = ["203.0.113.10"]; $0.marketHours = true; $0.optionOrdersLeft = 9
                $0.accountChecks = [["name": "market data", "ok": true], ["name": "NFO segment", "ok": true], ["name": "BFO segment", "ok": false, "fix": "Sensex options need the BFO segment activated with the broker."]] }),
            ("40-pill-market-closed", { $0.marketHours = false }),
            ("34-pill-ip-mismatch", { $0.networkState = "mismatch" }),
            ("35-pill-resting", { $0.working = ["24100000001": "Nifty 29 Sep 23100 put"] }),
        ]

    }

    /// What every state starts from: a logged-in, set-up Mac.
    static func base(_ m: Model) {
        m.connected = true; m.loggedIn = true; m.account = "FA12345"; m.modelReady = true
        m.calibrated = true; m.networkState = "ok"; m.noticeAccepted = true
        m.limits = ["max_order_value": 15000.0, "max_value_per_day": 50000.0, "max_orders_per_day": 20,
                    "max_quantity": 1000, "max_option_orders_per_day": 10,
                    "max_lots": ["NIFTY": 10, "BANKNIFTY": 3, "SENSEX": 10]]
        m.defaultLimits = m.limits
    }

    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        active = true
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let shots = states()
        for (name, setup) in shots {
            let m = Model()
            base(m)
            setup(m)
            m.recompute()
            let size = m.shape.size
            let view = RootView().environmentObject(m).frame(width: size.width, height: size.height)
                .clipped()                          // exactly what the window shows
                .padding(20).background(Color(red: 0.13, green: 0.14, blue: 0.16))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
        print("wrote \(shots.count) snapshots to \(dir.path)")
        return true
    }
}

/// The app icon: a voice waveform in the buy-to-sell colours, and the one key
/// that sends.
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.15, blue: 0.18),
                                              Color(red: 0.04, green: 0.045, blue: 0.055)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            Image(systemName: "waveform")
                .font(.system(size: 380, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Palette.buy, Palette.sell],
                                                startPoint: .leading, endPoint: .trailing))
                .offset(y: -40)
            Text("y")
                .font(.system(size: 118, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 168, height: 168)
                .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Color.white))
                .offset(x: 238, y: 238)
        }
        .frame(width: 1024, height: 1024)
    }
}
