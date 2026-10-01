import SwiftUI

// MARK: - account panes: positions, today's orders, funds

/// What the terminal answered in sentences, as a glanceable table. Read-only,
/// and read from the engine: nothing here is computed.
struct PaneView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(["positions", "orders", "funds"], id: \.self) { which in
                    Button(which.capitalized) { m.openPane(which) }
                        .buttonStyle(TabButton(selected: m.pane == which))
                }
                Spacer()
                Button { if let p = m.pane { m.openPane(p) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Refresh")
                Button { m.closePane() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Close")
                ModeBadge()
            }
            Divider().overlay(Palette.faint.opacity(0.4))
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .onExitCommand { m.closePane() }
    }

    @ViewBuilder private var content: some View {
        if m.paneLoading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading from Shoonya…").foregroundStyle(Palette.dim) }
                .font(.system(size: Size.body))
        } else if let e = m.paneError {
            VStack(alignment: .leading, spacing: 4) {
                Text(e).font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.warn)
                if let d = m.paneDetails {
                    DetailsLink(text: d)
                }
            }
        } else if m.pane == "funds" {
            FundsTable(funds: m.paneFunds ?? [:])
        } else if m.paneRows.isEmpty {
            Text(m.pane == "orders" ? "No orders today." : "No open positions.")
                .font(.system(size: Size.body)).foregroundStyle(Palette.dim)
        } else if Snapshot.active {
            rows                                  // a scroll view can't be rendered to PNG
        } else {
            ScrollView { rows }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(m.paneRows.indices, id: \.self) { i in
                if m.pane == "orders" { OrderRow(row: m.paneRows[i]) } else { PositionRow(row: m.paneRows[i]) }
            }
        }
    }
}

private func num(_ row: [String: Any], _ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
private func name(_ row: [String: Any]) -> String { row["display"] as? String ?? row["symbol"] as? String ?? "—" }

struct PositionRow: View {
    let row: [String: Any]
    var body: some View {
        let qty = Int(num(row, "qty") ?? 0)
        let pnl = num(row, "unrealised_pnl")
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name(row)).font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(qty > 0 ? "+\(qty)" : "\(qty)").foregroundStyle(qty >= 0 ? Palette.buy : Palette.sell)
            Text("\(Fmt.price(num(row, "avg_price"))) → \(Fmt.price(num(row, "ltp")))").foregroundStyle(Palette.dim)
            Text(pnl.map(Fmt.signed) ?? "—")
                .foregroundStyle(pnl.map { $0 >= 0 ? Palette.good : Palette.bad } ?? Palette.dim)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .font(.system(size: Size.body).monospacedDigit())
    }
}

struct OrderRow: View {
    let row: [String: Any]
    var body: some View {
        let side = row["side"] as? String ?? ""
        let status = row["status"] as? String ?? ""
        let qty = Int(num(row, "quantity") ?? 0)
        let filled = Int(num(row, "filled") ?? 0)
        let byVoice = (row["tag"] as? String)?.hasPrefix("sayso-") == true
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(time).foregroundStyle(Palette.faint)
            Text(side).font(.system(size: Size.small, weight: .heavy))
                .foregroundStyle(side == "SELL" ? Palette.sell : Palette.buy)
                .frame(width: 32, alignment: .leading)
            Text(name(row)).font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            if byVoice {
                Image(systemName: "waveform").font(.system(size: Size.small)).foregroundStyle(Palette.dim)
                    .help("Placed by voice")
            }
            Spacer(minLength: 4)
            Text("\(filled)/\(qty)").foregroundStyle(Palette.dim)
            Text(Fmt.price(num(row, "avg_fill_price") ?? num(row, "price"))).foregroundStyle(Palette.text)
            Chip(text: statusWord(status), color: statusColor(status))
                .help(row["reason"] as? String ?? "")
        }
        .font(.system(size: Size.body).monospacedDigit())
    }

    /// "HH:MM:SS DD-MM-YYYY" -> "HH:MM"
    private var time: String { String((row["time"] as? String ?? "").prefix(5)) }

    private func statusWord(_ s: String) -> String { OrderWords.status(s) }
    private func statusColor(_ s: String) -> Color {
        switch s {
        case "COMPLETE": return Palette.good
        case "REJECTED": return Palette.bad
        case "OPEN", "PENDING", "TRIGGER_PENDING": return Palette.warn
        default: return Palette.dim
        }
    }
}

struct FundsTable: View {
    let funds: [String: Any]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line("Available to trade", "available", big: true)
            line("Cash", "cash_settled")
            line("Pay-in today", "payin_today")
            line("Blocked", "blocked")
        }
    }

    @ViewBuilder private func line(_ label: String, _ key: String, big: Bool = false) -> some View {
        if let v = (funds[key] as? NSNumber)?.doubleValue {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: Size.body)).foregroundStyle(Palette.dim)
                Spacer()
                Text(Fmt.rupees(v)).font(.system(size: big ? Size.large : Size.body, weight: big ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(Palette.text)
            }
        }
    }
}

struct TabButton: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Size.body, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Palette.dim)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Palette.text : Color.clear))
            .overlay(Capsule().strokeBorder(Palette.faint, lineWidth: selected ? 0 : 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - setup and health: the first-run wizard, and the answer to "why won't it work?"

struct SetupView: View {
    @EnvironmentObject var m: Model
    @State private var ips = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Setup & health").font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Button { m.closeSetup() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.dim).help("Close")
                ModeBadge()
            }
            Check(ok: m.modelReady, title: "Speech model",
                  detail: m.modelReady ? "Ready" : (m.modelError != nil ? "Couldn't load"
                          : m.modelDownloadMB.map { "Downloading, \($0) MB (once)…" } ?? "Loading…"),
                  pending: !m.modelReady && m.modelError == nil) {
                if m.modelError != nil {
                    Button("Retry") { m.retryModel() }.buttonStyle(PillButton(color: Palette.text))
                }
            }
            Check(ok: m.calibrated, title: "Microphone", detail: m.calibrated ? "Set up" : "Not set up") {
                if !m.calibrated {
                    Button("Set up") { m.closeSetup(); m.openCalibration() }.buttonStyle(PillButton(color: Palette.text))
                }
            }
            Check(ok: ipOK, title: "Registered IP", detail: ipDetail, pending: m.networkState == "unknown") {
                if m.networkState == "mismatch" || m.networkState == "unset" {
                    TextField("IP from the API key page", text: $ips)
                        .textFieldStyle(.roundedBorder).frame(width: 128)
                        .onSubmit { m.saveIPs(ips) }
                    Button("Save") { m.saveIPs(ips) }.buttonStyle(PillButton(color: Palette.text))
                }
            }
            Check(ok: m.loggedIn, title: "Shoonya", detail: m.loggedIn ? "Logged in as \(m.account ?? "—")" : "Not logged in") {
                if !m.loggedIn {
                    Button("Connect") { m.closeSetup(); m.openLogin() }.buttonStyle(PillButton(color: Palette.text))
                }
            }
            if m.loggedIn && !m.accountChecks.isEmpty {
                // The terminal doctor's account checks: market data, and
                // the two derivatives segments. A missing segment only
                // limits what can be traded, so it isn't shown as a problem.
                let failed = m.accountChecks.filter { $0["ok"] as? Bool != true }
                let blocking = failed.filter { $0["blocking"] as? Bool == true }
                Check(ok: blocking.isEmpty, title: "Account",
                      detail: failed.isEmpty ? "Market data and F&O segments working"
                        : failed.compactMap { $0["fix"] as? String }.filter { !$0.isEmpty }
                            .joined(separator: " "))
            }
            Check(ok: m.talkKeyWorks, title: "Talk key",
                  detail: m.talkKeyWorks ? "\(m.talkKeyLabel). If nothing happens when you press it, macOS may use it for switching input sources: pick another (right-click → Talk key)."
                                         : "\(m.talkKeyLabel) is taken by another app. Pick another: right-click → Talk key.")
            Check(ok: true, title: "Your limits", detail: limitsLine) {
                Button("Change") { m.closeSetup(); m.openLimits() }.buttonStyle(PillButton(color: Palette.text))
            }
            Spacer(minLength: 0)
            if let msg = m.setupMessage {
                Text(msg).font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Palette.bad)
            } else {
                Text(m.setupReady ? "All set. Press \(m.talkKeyLabel) and speak." : "Every order needs all four.")
                    .font(.system(size: Size.body)).foregroundStyle(m.setupReady ? Palette.good : Palette.dim)
            }
            HStack {
                Text([m.marketHours.map { $0 ? "Market hours" : "Market closed" },
                      m.optionOrdersLeft.map { "\($0) option orders left today" }]
                        .compactMap { $0 }.joined(separator: " · "))
                Spacer()
                Text("Sayso \(Model.version)")
            }
            .font(.system(size: Size.small)).foregroundStyle(Palette.faint)
        }
        .padding(16)
        .onExitCommand { m.closeSetup() }
        .onAppear { ips = m.networkCurrent ?? "" }
    }

    private var limitsLine: String {
        let l = m.limits
        func n(_ k: String) -> String { (l[k] as? NSNumber).map { String($0.intValue) } ?? "—" }
        let lots = (l["max_lots"] as? [String: Any]) ?? [:]
        let lotLine = ["NIFTY", "BANKNIFTY", "SENSEX"].map { (lots[$0] as? NSNumber).map { String($0.intValue) } ?? "—" }
            .joined(separator: "/")
        let money = (l["max_order_value"] as? NSNumber).map { Fmt.rupees($0.doubleValue).replacingOccurrences(of: ".00", with: "") } ?? "—"
        return "\(money) a stock order · \(n("max_option_orders_per_day")) option orders a day · lots \(lotLine)"
    }

    private var ipOK: Bool { m.networkState == "ok" }
    private var ipDetail: String {
        let allowed = m.networkRegistered.joined(separator: " or ")
        switch m.networkState {
        case "ok": return "On \(m.networkCurrent ?? "—")"
        case "mismatch": return "You're on \(m.networkCurrent ?? "?"); your key allows \(allowed)"
        case "unset": return "Not saved yet. This Mac is on \(m.networkCurrent ?? "an unknown address"): register that on the API key page"
        default: return "Couldn't check just now"
        }
    }
}

struct Check<Action: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    var pending = false
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pending ? "circle.dotted" : (ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                .foregroundStyle(pending ? Palette.dim : (ok ? Palette.good : Palette.warn))
                .font(.system(size: Size.title))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: Size.body, weight: .semibold)).foregroundStyle(Palette.text)
                Text(detail).font(.system(size: Size.small)).foregroundStyle(Palette.dim)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            action()
        }
    }
}

extension Check where Action == EmptyView {
    init(ok: Bool, title: String, detail: String, pending: Bool = false) {
        self.init(ok: ok, title: title, detail: detail, pending: pending) { EmptyView() }
    }
}

// MARK: - this account's limits

/// Today's limits are the defaults; a trader changes their own. Lowering
/// applies at once; raising asks "are you sure?" (and the engine insists).
struct LimitsView: View {
    @EnvironmentObject var m: Model
    @State private var values: [String: String] = [:]
    @State private var lots: [String: String] = [:]

    private let rows: [(key: String, label: String, money: Bool)] = [
        ("max_order_value", "Per stock order", true),
        ("max_value_per_day", "Stocks a day", true),
        ("max_orders_per_day", "Stock orders a day", false),
        ("max_quantity", "Shares per order", false),
        ("max_option_orders_per_day", "Option orders a day", false),
    ]
    private let indices: [(key: String, label: String)] = [
        ("NIFTY", "Nifty"), ("BANKNIFTY", "Bank Nifty"), ("SENSEX", "Sensex")]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your limits").font(.system(size: Size.title, weight: .semibold)).foregroundStyle(Palette.text)
                Spacer()
                ModeBadge()
            }
            ForEach(rows, id: \.key) { row in
                HStack {
                    Text(row.label).font(.system(size: Size.body)).foregroundStyle(Palette.text)
                        .frame(width: 150, alignment: .leading)
                    if row.money { Text("₹").foregroundStyle(Palette.dim) }
                    TextField("", text: binding(row.key)).textFieldStyle(.roundedBorder).frame(width: 110)
                    Spacer()
                    Text("default \(shown(m.defaultLimits[row.key], money: row.money))")
                        .font(.system(size: Size.small)).foregroundStyle(Palette.faint)
                }
            }
            HStack {
                Text("Lots per order").font(.system(size: Size.body)).foregroundStyle(Palette.text)
                    .frame(width: 150, alignment: .leading)
                ForEach(indices, id: \.key) { index in
                    Text(index.label).font(.system(size: Size.small)).foregroundStyle(Palette.dim)
                    TextField("", text: lotBinding(index.key)).textFieldStyle(.roundedBorder).frame(width: 36)
                }
                Spacer()
            }
            Spacer(minLength: 0)
            if let msg = m.limitsMessage {
                Text(msg).font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Palette.warn)
            }
            HStack {
                Button("Defaults") { m.resetLimits() }.buttonStyle(PillButton(color: Palette.dim))
                Spacer()
                Button("Cancel") { m.closeLimits() }.buttonStyle(PillButton(color: Palette.dim))
                Button("Save") { save() }.buttonStyle(PillButton(color: Palette.text))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onExitCommand { m.closeLimits() }
        .onAppear(perform: load)
    }

    private func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    private func shown(_ any: Any?, money: Bool) -> String {
        guard let v = number(any) else { return "—" }
        return money ? Fmt.rupees(v).replacingOccurrences(of: ".00", with: "") : String(Int(v))
    }

    private func load() {
        for row in rows {
            if let v = number(m.limits[row.key]) { values[row.key] = String(Int(v)) }
        }
        let current = m.limits["max_lots"] as? [String: Any] ?? [:]
        for index in indices {
            if let v = number(current[index.key]) { lots[index.key] = String(Int(v)) }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
    private func lotBinding(_ key: String) -> Binding<String> {
        Binding(get: { lots[key] ?? "" }, set: { lots[key] = $0 })
    }

    /// Only what changed goes to the engine, as numbers.
    private func save() {
        var changes: [String: Any] = [:]
        for row in rows {
            let text = (values[row.key] ?? "").replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let v = Double(text), v > 0, v.isFinite else {
                m.limitsMessage = "\(row.label) must be a number above zero."
                return
            }
            if v != number(m.limits[row.key]) { changes[row.key] = v }   // the engine checks whole numbers
        }
        var lotChanges: [String: Int] = [:]
        let current = m.limits["max_lots"] as? [String: Any] ?? [:]
        for index in indices {
            guard let n = Int((lots[index.key] ?? "").trimmingCharacters(in: .whitespaces)), n >= 1 else {
                m.limitsMessage = "\(index.label) lots must be a whole number, at least 1."
                return
            }
            if Double(n) != number(current[index.key]) { lotChanges[index.key] = n }
        }
        if !lotChanges.isEmpty { changes["max_lots"] = lotChanges }
        m.saveLimits(changes)
    }
}
