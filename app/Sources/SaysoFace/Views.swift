import AppKit
import SwiftUI

// MARK: - palette (buy/sell stay distinct under red-green colour blindness)

/// The panel's five type sizes. Nothing uses any other.
enum Size {
    static let small: CGFloat = 11      // small print: exchange codes, hints
    static let body: CGFloat = 13       // most text
    static let title: CGFloat = 16      // a screen's title, the contract
    static let large: CGFloat = 20      // a figure to read at a glance
    static let hero: CGFloat = 28       // the card's BUY/SELL and price
}

enum Palette {
    static let buy = Color(red: 0.24, green: 0.61, blue: 1.0)       // blue
    static let sell = Color(red: 1.0, green: 0.54, blue: 0.0)       // orange, #FF8A00
    static let live = Color.white.opacity(0.92)                    // real money: plain, never a warning colour
    static let good = Color(red: 0.30, green: 0.82, blue: 0.47)
    static let warn = Color(red: 1.0, green: 0.894, blue: 0.361)    // amber #FFE45C: "look twice"

    static let bad = Color(red: 1.0, green: 0.33, blue: 0.33)
    static let text = Color.white.opacity(0.94)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.45)          // 4.5:1 on the panel
    static let surface = Color(red: 0.07, green: 0.075, blue: 0.09).opacity(0.84)   // over a blur
}

enum Fmt {
    private static let inr: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()
    static func rupees(_ v: Double?) -> String { v.flatMap { inr.string(from: NSNumber(value: $0)) } ?? "—" }
    static func price(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    static func signed(_ v: Double) -> String { (v >= 0 ? "+" : "−") + rupees(abs(v)) }
}

// MARK: - root

/// What a shape shows, without the window chrome: measured by the fit test.
struct ShapeContent: View {
    @EnvironmentObject var m: Model

    var body: some View {
        switch m.shape {
            case .disconnected: DisconnectedView()
            case .pill:         PillView()
            case .strip:        StripView()
            case .question:     QuestionView()
            case .card, .cardUnusual: CardView()
            case .alert:        AlertView()
            case .login:        LoginView()
            case .command:      CommandView()
            case .calibrate:    CalibrateView()
            case .setup:        SetupView()
            case .notice:       NoticeView()
            case .limits:       LimitsView()
            case .pane:         PaneView()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ShapeContent()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Chrome(emphasis: emphasis))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Button("Positions") { m.openPane("positions") }
            Button("Today's orders") { m.openPane("orders") }
            Button("Funds") { m.openPane("funds") }
            Button("Setup & health…") { m.openSetup() }
            Menu("Account: \(m.profileName)") {
                ForEach(m.accounts, id: \.self) { name in
                    Button(name == m.profileName ? "✓ \(name)" : name) { m.switchAccount?(name) }
                }
                Divider()
                Button("New account…") { m.newAccount?() }
            }
            Menu("Talk key: \(m.talkKeyLabel)") {
                ForEach(TalkKey.allCases, id: \.rawValue) { key in
                    Button(key.label == m.talkKeyLabel ? "✓ \(key.label)" : key.label) { m.chooseTalkKey?(key) }
                }
            }
            Button("Your limits…") { m.openLimits() }
            Button("Copy diagnostics") { m.copyDiagnostics?() }
            Button("Open logs folder") { m.openLogs?() }
            Divider()
            Button("Quit Sayso") { NSApp.terminate(nil) }
        }
    }

    private var emphasis: Chrome.Emphasis {
        if m.shape == .alert { return .alarm }
        if m.shape == .cardUnusual { return .unusual }
        return .normal
    }
}

/// LIVE is a permanent border on every shape, including the idle pill.
struct Chrome: View {
    enum Emphasis { case normal, unusual, alarm }
    @EnvironmentObject var m: Model
    let emphasis: Emphasis

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            if !Snapshot.active { Blur().clipShape(shape) }
            shape.fill(Palette.surface)
            if emphasis == .alarm { shape.fill(Palette.bad.opacity(0.16)) }
            shape.strokeBorder(borderColor, lineWidth: borderWidth)
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .alarm: return Palette.bad
        case .unusual: return Palette.warn
        case .normal: return Palette.live.opacity(0.6)
        }
    }
    private var borderWidth: CGFloat { emphasis == .normal ? 1.5 : 3 }
}

struct ModeBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: Size.small, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Palette.live))
            .help("Live — every confirmed order is real money.")
    }
}

// MARK: - pill (idle)

struct PillView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 10) {
            ModeBadge()
            Button { m.openSetup() } label: { Circle().fill(dotColor).frame(width: 9, height: 9) }
                .buttonStyle(.plain).help("\(dotHelp). Click for setup & health.")
            if m.loggedIn && (m.networkState == "mismatch" || m.networkState == "unset") {
                // The broker will refuse every order from here: say so, don't hint.
                Text(m.account ?? "—")
                    .font(.system(size: Size.body, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.text)
                Text(m.networkState == "mismatch" ? "Wrong IP" : "IP not set")
                    .font(.system(size: Size.small, weight: .bold)).foregroundStyle(Palette.bad)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                Button("Fix") { m.openSetup() }.buttonStyle(PillButton(color: Palette.text))
            } else if m.loggedIn {
                Text(m.account ?? "—")
                    .font(.system(size: Size.body, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.text)
                    .lineLimit(1).fixedSize()
                if m.marketHours == false {
                    Image(systemName: "moon.zzz.fill").font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                        .help("Market closed (NSE hours are 09:15–15:30 IST, Monday to Friday)")
                }
                Spacer(minLength: 4)
                if !m.working.isEmpty {
                    // A resting order stays in view while Sayso follows it.
                    Label("\(m.working.count) resting", systemImage: "hourglass")
                        .font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Palette.warn)
                        .help(m.working.values.sorted().joined(separator: "\n"))
                }
                if !m.calibrated {
                    Button { m.openCalibration() } label: { Label("Set up mic", systemImage: "mic") }
                        .buttonStyle(PillButton(color: Palette.text))
                } else {
                    Button { m.openPane("positions") } label: { Image(systemName: "list.bullet.rectangle") }
                        .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Positions, orders and funds")
                    if m.working.isEmpty {
                        Text(m.talkKeyLabel)
                            .font(.system(size: Size.small, weight: .medium))
                            .foregroundStyle(Palette.faint)
                            .help("Press once, speak, then pause.")
                    }
                }
            } else {
                Text("Not logged in").font(.system(size: Size.body)).foregroundStyle(Palette.dim)
                Spacer(minLength: 4)
                Button("Connect") { m.openLogin() }
                    .buttonStyle(PillButton(color: Palette.live))
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { m.openCommand() }
        .help("Double-click to type a command.")
    }

    private var dotColor: Color {
        if !m.loggedIn { return Palette.faint }
        if m.networkState == "mismatch" || m.networkState == "unset" { return Palette.bad }
        return m.setupReady ? Palette.good : Palette.warn
    }
    private var dotHelp: String {
        if !m.loggedIn { return "Not logged in" }
        if m.networkState == "mismatch" { return "This Mac's IP isn't registered with your API key" }
        if !m.modelReady { return m.modelLoading }
        return m.setupReady ? "Ready" : "Something needs setting up"
    }
}

struct DisconnectedView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Palette.dim)
            Text(message).font(.system(size: Size.body)).foregroundStyle(Palette.dim)
                .lineLimit(2).minimumScaleFactor(0.85)
            Spacer()
            if starting {
                ProgressView().controlSize(.small)
            } else {
                Button("Copy diagnostics") { m.copyDiagnostics?() }.buttonStyle(PillButton(color: Palette.text))
            }
            ModeBadge()
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }

    /// Still coming up (worth waiting for), rather than failed.
    private var starting: Bool {
        guard let problem = m.engineProblem else { return !(m.connected && m.foreignEngine) }
        return problem.hasPrefix("Installing") || problem.hasSuffix("Restarting…")
    }

    private var message: String {
        if m.connected && m.foreignEngine {
            return "Another user on this Mac is running Sayso."
        }
        return m.engineProblem ?? "Starting Sayso…"
    }
}

// MARK: - strip (listening, working, sending, results)

struct StripView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: Size.body, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(2)
                // What was heard stays under a refusal, so it can be said
                // again differently.
                if m.phase == "sending", m.outcome == nil, let s = m.sending {
                    Text(s).font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.dim).lineLimit(1)
                } else if let h = m.heard, m.outcome == nil || m.phase != "idle" || m.outcome?.kind == "blocked" {
                    Text("heard  “\(h)”").font(.system(size: Size.small)).foregroundStyle(Palette.faint).lineLimit(1)
                } else if let s = m.outcome?.subject {
                    Text(s).font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.dim).lineLimit(1)
                        .help(m.outcome?.details ?? "")
                } else if let d = m.outcome?.details {
                    DetailsLink(text: d)
                }
            }
            Spacer(minLength: 0)
            if m.speaking {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: Size.body))
                    .foregroundStyle(Palette.dim).help("Sayso is speaking. \(m.talkKeyLabel) cuts it short.")
            }
            ModeBadge()
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    private var headline: String {
        if let o = m.outcome {
            if o.kind == "blocked" && !o.text.localizedCaseInsensitiveContains("nothing") {
                return o.text + " Nothing was sent."
            }
            return o.text
        }
        if let t = m.toast { return t }
        switch m.phase {
        case "listening": return "Listening…"
        case "transcribing": return "Working out what you said…"
        case "working": return "Resolving…"
        case "sending": return "Sending — waiting for the exchange…"
        default: return ""
        }
    }

    private var color: Color {
        switch m.outcome?.kind {
        case "filled": return Palette.good
        case "partial", "resting": return Palette.warn
        case "rejected": return Palette.text          // red is kept for danger
        case "blocked": return Palette.text
        case "cancelled": return Palette.dim
        default: return Palette.text
        }
    }

    private func iconColor(_ kind: String) -> Color {
        switch kind {
        case "rejected": return Palette.bad
        case "blocked": return Palette.warn
        default: return color
        }
    }

    @ViewBuilder private var icon: some View {
        if let kind = m.outcome?.kind {
            Image(systemName: {
                switch kind {
                case "filled": return "checkmark.circle.fill"
                case "rejected": return "xmark.octagon.fill"
                case "resting", "partial": return "hourglass"
                case "cancelled": return "minus.circle"
                case "blocked": return "exclamationmark.circle"
                default: return "info.circle"
                }
            }()).foregroundStyle(iconColor(kind)).font(.system(size: Size.title))
        } else if m.phase == "listening" {
            LevelMeter(level: m.level)
        } else if m.phase == "idle" {
            Image(systemName: "info.circle").foregroundStyle(Palette.dim)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Five bars. The third lights at the level that counts as speech, so a
/// meter stuck below it means the mic isn't hearing you.
struct LevelMeter: View {
    let level: Double
    private let steps: [Double] = [0.3, 0.6, 1.0, 1.8, 3.0]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(steps.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level >= steps[i] ? (i >= 2 ? Palette.good : Palette.text) : Palette.faint.opacity(0.5))
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

// MARK: - question

struct QuestionView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        if let q = m.question {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("QUESTION").font(.system(size: Size.small, weight: .heavy)).tracking(1.2).foregroundStyle(Palette.text)
                    Text(q.choices.isEmpty ? "· \(m.talkKeyLabel) and say it, or double-click to type"
                                           : "· press 1–\(min(q.choices.count, 3)) or say it")
                        .font(.system(size: Size.small)).foregroundStyle(Palette.faint).lineLimit(1)
                    Spacer()
                    ModeBadge()
                }
                Text(q.text).font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(Array(q.choices.enumerated()), id: \.element.say) { i, c in
                        Button { m.answer(c.say) } label: {
                            HStack(spacing: 5) {
                                if i < 3 { Text("\(i + 1)").font(.system(size: Size.small, weight: .bold).monospaced()).foregroundStyle(Palette.dim) }
                                Text(c.label)
                            }
                        }
                        .buttonStyle(PillButton(color: Palette.text))
                    }
                    Spacer()
                }
                ExpiryBar(start: q.opened, end: q.expires) { m.question = nil; m.recompute() }
            }
            .padding(16)
            .onTapGesture(count: 2) { m.question = nil; m.openCommand() }
        }
    }
}

// MARK: - the confirm card

/// Everything the card shows, read from Sayso's preview. Nothing is computed
/// here that the engine didn't supply.
struct CardFacts {
    let c: Card
    init(_ c: Card) { self.c = c }

    var action: String { c.string("action") ?? "" }
    var isExit: Bool { action.hasPrefix("EXIT") }
    var side: String {
        let words = action.split(separator: " ")
        if isExit, words.count > 1 { return String(words[1]) }
        return words.first.map(String.init) ?? "?"
    }
    var product: String? {
        guard let open = action.firstIndex(of: "("), let close = action.firstIndex(of: ")") else {
            return c.string("product")
        }
        return String(action[action.index(after: open)..<close])
    }
    var lots: Int? { c.int("lots") }
    var quantity: Int { c.int("quantity") ?? 0 }
    var value: Double? { c.number("value") }
    var atMarket: Bool { (c.preview["at_market"] as? Bool) ?? true }
    var when: String? { c.string("when") }
    var underlying: String? { c.string("underlying") }
    var strike: String? {
        guard let k = c.number("strike") else { return nil }
        return k.rounded() == k ? String(Int(k)) : String(k)
    }
    var adjustedFrom: Int? { c.int("strike_adjusted_from") }
    var atTheMoney: Bool { c.string("strike_chosen") == "atm" }
    var optionType: String? {
        switch c.string("option_type") {
        case "CE": return "CALL"
        case "PE": return "PUT"
        default: return nil
        }
    }
    /// "2026-09-29" -> "29 Sep"
    var expiryShort: String? {
        guard let iso = c.string("expiry") else { return nil }
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return iso }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(parts[2]) \(months[parts[1] - 1])"
    }

    /// Why this order deserves a second look: the engine's own list
    /// (agent.unusual). The fallback is for an engine that doesn't send it.
    var reasons: [String] {
        if let r = c.preview["unusual"] as? [String] { return r }
        var r: [String] = []
        if (value ?? 0) >= 25_000 { r.append("large order") }
        if let l = lots, l > 1 { r.append("\(l) lots") }
        if isExit { r.append("closing a position") }
        if !atMarket { r.append("your price") }
        if when == "expires today" { r.append("expires today") }
        return r
    }
    var unusual: Bool { !reasons.isEmpty }
}

struct CardView: View {
    @EnvironmentObject var m: Model
    @State private var priceText = ""
    @FocusState private var priceFocused: Bool

    var body: some View {
        if let card = m.card {
            let f = CardFacts(card)
            let sideColor = f.side == "SELL" ? Palette.sell : Palette.buy
            VStack(alignment: .leading, spacing: 0) {
            if f.unusual {
                Banner(text: f.reasons.joined(separator: " · "), color: Palette.warn)
            }
            VStack(alignment: .leading, spacing: 7) {
                // The glance: side, strike, call or put. Everything else is
                // smaller, because it is read second.
                HStack(alignment: .center, spacing: 10) {
                    // A solid block of the side's colour: peripheral vision
                    // picks up blocks, not coloured letters.
                    Text(f.isExit ? "EXIT" : f.side)
                        .font(.system(size: Size.hero, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(sideColor))
                    if let k = f.strike, let t = f.optionType {
                        Text(k)
                            .font(.system(size: Size.hero, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Palette.text)
                        Text(t)
                            .font(.system(size: Size.large, weight: .heavy)).tracking(1)
                            .foregroundStyle(Palette.text)
                    } else {
                        Text("\(f.quantity) \(card.display.uppercased())")
                            .font(.system(size: Size.hero, weight: .heavy).monospacedDigit())
                            .foregroundStyle(Palette.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 3) {
                        ModeBadge()
                        Text(m.account ?? "").font(.system(size: Size.small, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.dim)
                    }
                }

                HStack(spacing: 6) {
                    if f.strike != nil, let u = f.underlying {
                        Text([u, f.expiryShort].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                    }
                    if f.atTheMoney { Chip(text: "at the money", color: Palette.dim) }
                    if f.isExit { Chip(text: f.side == "SELL" ? "sell to close" : "buy to close", color: sideColor) }
                    if let w = f.when { Chip(text: w, color: w == "expires today" ? Palette.warn : Palette.dim, filled: w == "expires today") }
                    if let p = f.product { Chip(text: p, color: Palette.dim) }
                    if let co = card.string("company") { Text(co).font(.system(size: Size.body)).foregroundStyle(Palette.dim) }
                }

                Group {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let l = f.lots, l > 0 {
                            Text("\(l) lot\(l == 1 ? "" : "s") × \(f.quantity / l) = \(f.quantity)")
                                .foregroundStyle(l > 1 ? Palette.warn : Palette.text)
                        } else {
                            Text("\(f.quantity) \(card.string("company") != nil ? "shares" : "units")")
                                .foregroundStyle(Palette.text)
                        }
                        // An exit's result at the price it is sent at (the
                        // engine's P&L), on the same line as its size.
                        if f.isExit, let entry = card.number("entry") {
                            Text("entry \(Fmt.price(entry)) → \(Fmt.price(card.number("price")))").foregroundStyle(Palette.dim)
                                .lineLimit(1).minimumScaleFactor(0.85)
                            if let pnl = card.number("pnl") {
                                Text(Fmt.signed(pnl)).foregroundStyle(pnl >= 0 ? Palette.good : Palette.bad)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(Fmt.rupees(f.value))
                            .font(.system(size: Size.title, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.dim)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(f.atMarket ? "at market ≈ \(Fmt.price(card.number("price")))"
                                        : "limit \(Fmt.price(card.number("price")))")
                            .foregroundStyle(f.atMarket ? Palette.text : Palette.warn)
                        if let b = card.number("bid"), let a = card.number("ask") {
                            Text("bid \(Fmt.price(b)) / ask \(Fmt.price(a))").foregroundStyle(Palette.faint)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 6)
                        Text(card.string("symbol") ?? "").font(.system(size: Size.small).monospaced()).foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: Size.body).monospacedDigit())

                if m.priceEntry {
                    HStack(spacing: 8) {
                        Text("limit").font(.system(size: Size.body)).foregroundStyle(Palette.dim)
                        TextField("price", text: $priceText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: Size.body).monospacedDigit())
                            .frame(width: 110)
                            .focused($priceFocused)
                            .onSubmit { m.submitPrice(priceText) }
                            .onExitCommand { m.closePriceEntry() }
                        if let lo = card.number("lower_circuit"), let hi = card.number("upper_circuit") {
                            Text("\(Fmt.price(lo)) – \(Fmt.price(hi))").font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                        }
                        Spacer()
                    }
                    .onAppear {
                        priceText = Fmt.price(card.number("spoken_price") ?? card.number("price"))
                        DispatchQueue.main.async { priceFocused = true }
                    }
                } else if let n = m.cardNotice {
                    // One secondary line, most important first: the footprint
                    // never has to grow for it.
                    Text(n).font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Palette.warn)
                } else if let sp = card.number("spoken_price") {
                    Text("heard price \(Fmt.price(sp)) — press p to use it")
                        .font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Palette.warn)
                } else if let h = m.heard {
                    Text("heard  “\(h)”").font(.system(size: Size.small)).foregroundStyle(Palette.faint).lineLimit(1)
                }

                Spacer(minLength: 0)
                ExpiryBar(start: card.opened, end: card.opened.addingTimeInterval(card.timeout)) {}
                if m.priceEntry {
                    // While typing, the keys are the field's own.
                    HStack(spacing: 8) {
                        if let e = m.priceError {
                            Text(e).font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Palette.bad).lineLimit(1)
                        }
                        Spacer()
                        KeyHint(key: "↩", text: "set")
                        KeyHint(key: "esc", text: "back")
                    }
                } else {
                    HStack(spacing: 8) {
                        Button { m.send() } label: { SendKey(opened: card.opened, color: sideColor) }.buttonStyle(.plain)
                        Button { m.openPriceEntry() } label: { KeyHint(key: "p", text: "price") }.buttonStyle(.plain)
                        Button { m.cancel() } label: { KeyHint(key: "esc", text: "cancel") }.buttonStyle(.plain)
                        Spacer()
                        if m.speaking {
                            Label("reading back", systemImage: "speaker.wave.2.fill")
                                .font(.system(size: Size.small)).foregroundStyle(Palette.dim)
                        } else {
                            Text("timeout cancels").font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                        }
                    }
                }
            }
            .padding(16)
            }
            .overlay(alignment: .leading) { Rectangle().fill(sideColor).frame(width: 4) }
        }
    }
}

/// `y`, larger than the other keys, lit in the side's colour once the card
/// has been on screen long enough for a send to count (the engine enforces
/// the same 0.7 s).
struct SendKey: View {
    let opened: Date
    let color: Color
    var body: some View {
        TimelineView(.periodic(from: opened, by: 0.1)) { t in
            let armed = t.date.timeIntervalSince(opened) >= 0.7
            HStack(spacing: 6) {
                Text("y").font(.system(size: Size.body, weight: .heavy).monospaced())
                    .foregroundStyle(armed ? Color.black : Palette.dim)
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(armed ? color : Color.white.opacity(0.14)))
                Text("send").font(.system(size: Size.body, weight: .semibold))
                    .foregroundStyle(armed ? Palette.text : Palette.dim)
            }
        }
    }
}

// MARK: - "unknown, may be live": sticky, loud, cleared with a hold

struct AlertView: View {
    @EnvironmentObject var m: Model
    @State private var holding = false

    var body: some View {
        if let a = m.alert {
            VStack(alignment: .leading, spacing: 0) {
            Banner(text: "Order may be live", color: Palette.bad, icon: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.alarmSubject ?? a.text).font(.system(size: Size.title, weight: .bold)).foregroundStyle(Palette.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    ModeBadge()
                }
                if m.alarmSubject != nil {
                    Text(a.text).font(.system(size: Size.body)).foregroundStyle(Palette.dim)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if !a.text.localizedCaseInsensitiveContains("order book") {
                    Text("Check your order book before you try again.")
                        .font(.system(size: Size.body)).foregroundStyle(Palette.dim)
                }
                if let check = m.alarmCheck {
                    Text(check).font(.system(size: Size.body, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.text)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Check orders") { m.checkAlarmOrder() }.buttonStyle(PillButton(color: Palette.text))
                    if let d = a.details { DetailsLink(text: d) }
                    Spacer()
                    Text(holding ? "keep holding…" : "hold to clear")
                        .font(.system(size: Size.body, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(holding ? Palette.warn : Palette.bad))
                        .onLongPressGesture(minimumDuration: 1.2, pressing: { holding = $0 }) { m.clearAlert() }
                }
            }
            .padding(16)
            }
        }
    }
}

// MARK: - first run: real money, and not advice

struct NoticeView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Before your first order").font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                ModeBadge()
            }
            line("indianrupeesign.circle", "Every order you send with y is real, with real money, through your Shoonya account.")
            line("person.crop.circle", "Sayso places the orders you ask for. It is not investment advice and decides nothing for you.")
            line("eye", "Read each card before you press y. When in doubt, press esc: nothing is sent.")
            Spacer(minLength: 0)
            HStack {
                Text("Try a 1-share order first.")
                    .font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                Spacer()
                Button("I understand") { m.acceptNotice() }
                    .buttonStyle(PillButton(color: Palette.text))
            }
        }
        .padding(16)
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Palette.dim).frame(width: 16)
            Text(text).font(.system(size: Size.body)).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - login: credentials go to the engine once and are never saved

struct LoginView: View {
    @EnvironmentObject var m: Model
    // The IDs are remembered on this Mac; the secret never is.
    @AppStorage("sayso.clientID") private var clientID = ""
    @AppStorage("sayso.userID") private var userID = ""
    @State private var secret = ""
    @State private var ip = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Connect Shoonya").font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                ModeBadge()
            }
            if m.loginWaiting {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(m.loginMessage ?? "Finish logging in, in your browser.").foregroundStyle(Palette.dim)
                }
                Spacer()
                Button("Cancel") { m.closeLogin() }.buttonStyle(PillButton(color: Palette.dim))
            } else {
                Field(label: "Client ID", hint: "ends in _U", text: $clientID)
                Field(label: "User ID", hint: "no _U", text: $userID)
                HStack {
                    Text("Secret code").font(.system(size: Size.body)).foregroundStyle(Palette.dim).frame(width: 96, alignment: .leading)
                    SecureField("from the API key page", text: $secret).textFieldStyle(.roundedBorder)
                }
                Field(label: "Registered IP", hint: "optional — from the API key page", text: $ip)
                HStack(spacing: 8) {
                    Text("Redirect URL on the API key page:").font(.system(size: Size.small)).foregroundStyle(Palette.dim)
                    Text(verbatim: "http://127.0.0.1:8787/").font(.system(size: Size.small).monospaced())
                        .foregroundStyle(Palette.text).textSelection(.enabled)
                    DetailsLink(text: "http://127.0.0.1:8787/", label: "copy")
                }
                Text("The secret is used for this login only and never saved.").font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                if let msg = m.loginMessage { Text(msg).font(.system(size: Size.small)).foregroundStyle(Palette.bad) }
                HStack {
                    Button("Cancel") { m.closeLogin() }.buttonStyle(PillButton(color: Palette.dim))
                    Spacer()
                    Button("Connect") {
                        m.login(clientID: clientID, userID: userID, secret: secret, ip: ip)
                        secret = ""
                    }
                    .buttonStyle(PillButton(color: Palette.live))
                    .keyboardShortcut(.defaultAction)
                    .disabled(clientID.isEmpty || userID.isEmpty || secret.isEmpty)
                }
            }
        }
        .padding(16)
        .onExitCommand { m.closeLogin() }
    }
}

struct Field: View {
    let label: String
    let hint: String
    @Binding var text: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: Size.body)).foregroundStyle(Palette.dim).frame(width: 96, alignment: .leading)
            TextField(hint, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - typed command

struct CommandView: View {
    @EnvironmentObject var m: Model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").foregroundStyle(Palette.dim)
            TextField("buy nifty call two lots · funds · what do I own", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: Size.body))
                .focused($focused)
                .onSubmit { m.runCommand(text); text = "" }
                .onExitCommand { m.closeCommand() }
            ModeBadge()
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - small parts

struct Chip: View {
    let text: String
    let color: Color
    var filled = false
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: Size.small, weight: .bold)).tracking(0.8)
            .foregroundStyle(filled ? .black : color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(filled ? color : .clear))
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.6), lineWidth: 1))
    }
}

/// The raw technical text behind a plain message (rule 19): hover to read,
/// click to copy it. Tooltips alone may never show on a panel
/// that doesn't take focus.
struct DetailsLink: View {
    let text: String
    var label = "copy details"
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Text(copied ? "copied" : label)
                .font(.system(size: Size.small)).underline().foregroundStyle(Palette.faint)
        }
        .buttonStyle(.plain)
        .help(text)
    }
}

/// A full-width band across the top of a shape. It changes the silhouette,
/// so it reads from across the room: amber for an unusual order, red for
/// an order that may be live.
struct Banner: View {
    let text: String
    let color: Color
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: Size.body, weight: .heavy)) }
            Text(text.uppercased()).font(.system(size: Size.body, weight: .heavy)).tracking(1)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .background(color)
    }
}

/// The desktop, blurred, behind the panel.
struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct KeyHint: View {
    let key: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: Size.small, weight: .bold).monospaced())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.14)))
            Text(text).font(.system(size: Size.small))
        }
        .foregroundStyle(Palette.dim)
    }
}

struct PillButton: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Size.body, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// A depleting bar: readable in peripheral vision, no numbers. It turns red
/// in the last 1.5 s. It only ever shows time running out; the engine side
/// decides what running out means (for the card: cancel).
struct ExpiryBar: View {
    let start: Date
    let end: Date
    let onExpire: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let total = max(end.timeIntervalSince(start), 0.1)
            let left = max(end.timeIntervalSince(ctx.date), 0)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Palette.dim)       // never red: running out cancels, safely
                        .frame(width: g.size.width * left / total)
                }
            }
            .frame(height: 3)
            .onChange(of: left == 0) { _, expired in if expired { onExpire() } }
        }
    }
}


// MARK: - mic set-up: Sayso's two measurements, in the panel

struct CalibrateView: View {
    @EnvironmentObject var m: Model
    private let phrase = "buy one call at market"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "mic").foregroundStyle(Palette.warn)
                Text("Set up the microphone").font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                ModeBadge()
            }
            switch m.calibStep {
            case "quiet":
                Measuring(step: "STEP 1 OF 2", instruction: "Stay silent.", detail: nil)
            case "speech":
                Measuring(step: "STEP 2 OF 2", instruction: "Keep repeating:", detail: "“\(phrase)”")
            case "quietDone":
                if m.calibNoisy {
                    Text("Step 1 picked up noise. Was someone talking, or is something loud nearby?")
                        .font(.system(size: Size.body)).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Step 1 done.", systemImage: "checkmark.circle.fill")
                        .font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.good)
                    Step(n: "2", text: "Press Start, then keep repeating “\(phrase)” for 5 seconds.")
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Cancel") { m.closeCalibration() }.buttonStyle(PillButton(color: Palette.dim))
                    Spacer()
                    if m.calibNoisy {
                        Button("Redo step 1") { m.measure("quiet") }.buttonStyle(PillButton(color: Palette.dim))
                        Button("Continue to step 2") { m.measure("speech") }.buttonStyle(PillButton(color: Palette.text))
                    } else {
                        Button("Start step 2") { m.measure("speech") }.buttonStyle(PillButton(color: Palette.text))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case "saved":
                Spacer(minLength: 0)
                Label("Microphone set. Press \(m.talkKeyLabel) to talk.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.good)
                Spacer(minLength: 0)
            case "error":
                Text(m.calibMessage ?? "Couldn't measure the microphone.")
                    .font(.system(size: Size.body)).foregroundStyle(Palette.bad).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Button("Close") { m.closeCalibration() }.buttonStyle(PillButton(color: Palette.dim))
                    Spacer()
                    if m.micDenied {
                        Button("Open Microphone Settings") { MicAccess.openSettings() }
                            .buttonStyle(PillButton(color: Palette.text))
                    }
                    Button("Start again") { m.measure("quiet") }.buttonStyle(PillButton(color: Palette.text))
                }
            default:
                Text("macOS will ask for microphone access first — the countdown starts after you allow it.")
                    .font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Step(n: "1", text: "3 seconds of silence.")
                Step(n: "2", text: "5 seconds repeating “\(phrase)”.")
                if let msg = m.calibMessage { Text(msg).font(.system(size: Size.small)).foregroundStyle(Palette.warn) }
                Spacer(minLength: 0)
                HStack {
                    Button("Cancel") { m.closeCalibration() }.buttonStyle(PillButton(color: Palette.dim))
                    Spacer()
                    Button("Start step 1") { m.measure("quiet") }.buttonStyle(PillButton(color: Palette.text))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
    }
}

private struct Step: View {
    let n: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n).font(.system(size: Size.body, weight: .heavy)).foregroundStyle(.black)
                .frame(width: 20, height: 20).background(Circle().fill(Palette.text))
            Text(text).font(.system(size: Size.body)).foregroundStyle(Palette.text)
        }
    }
}

/// A step in progress: what to do, and a countdown you can follow. Numbers
/// are fine here — this is set-up, not a card you glance at over a chart.
private struct Measuring: View {
    @EnvironmentObject var m: Model
    let step: String
    let instruction: String
    let detail: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let left = max((m.calibUntil ?? ctx.date).timeIntervalSince(ctx.date), 0)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step).font(.system(size: Size.small, weight: .heavy)).tracking(1.2).foregroundStyle(Palette.warn)
                    Text(instruction).font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                    if let d = detail {
                        Text(d).font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.warn)
                    }
                }
                Spacer()
                Text("\(Int(left.rounded(.up)))")
                    .font(.system(size: Size.hero, weight: .bold).monospacedDigit())
                    .foregroundStyle(Palette.text)
            }
        }
        if let s = m.calibStarted, let u = m.calibUntil { ExpiryBar(start: s, end: u) {} }
    }
}
