import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = Model()
    private var bridge: BridgeProcess!
    private var client: BridgeClient!
    private var panel: FloatingPanel!
    private var subs = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        bridge = BridgeProcess()
        client = BridgeClient(model: model, tokenFile: bridge.tokenFile)
        model.client = client

        panel = FloatingPanel(model: model)
        panel.orderFrontRegardless()

        // Push-to-talk: one global chord, always registered, swallows nothing else.
        registerTalkKey()
        model.chooseTalkKey = { [weak self] key in
            TalkKey.current = key
            HotKeys.shared.unregister(.talk)
            self?.registerTalkKey()
        }

        // "Are you sure?" before any limit goes up. "No" is the default.
        model.confirmRaise = { raised in
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Raise your limits?"
            a.informativeText = "This lets Sayso send bigger orders, or more of them, than before (\(raised)). Every order still needs y. Are you sure?"
            a.addButton(withTitle: "No")
            a.addButton(withTitle: "Yes, raise them")
            return Focus.ask(a) == .alertSecondButtonReturn
        }

        // y / p / esc exist globally only while a card is open (CLAUDE.md rule 15).
        model.$cardKeysWanted
            .removeDuplicates()
            .sink { wanted in
                if wanted {
                    HotKeys.shared.register(.send) { [weak self] in self?.model.send() }
                    HotKeys.shared.register(.price) { [weak self] in self?.model.openPriceEntry() }
                    HotKeys.shared.register(.cancel) { [weak self] in self?.model.cancel() }
                } else {
                    HotKeys.shared.unregister(.send)
                    HotKeys.shared.unregister(.price)
                    HotKeys.shared.unregister(.cancel)
                }
            }
            .store(in: &subs)

        // 1 / 2 / 3 exist globally only while a question with quick-picks is open.
        model.$pickKeys
            .removeDuplicates()
            .sink { n in
                for (i, key) in HotKey.picks.enumerated() {
                    if i < n {
                        HotKeys.shared.register(key) { [weak self] in self?.model.pick(i) }
                    } else {
                        HotKeys.shared.unregister(key)
                    }
                }
            }
            .store(in: &subs)

        // Another account profile: restart the engine this app runs with it.
        model.switchAccount = { [weak self] name in
            guard let self else { return }
            guard self.model.inflight == nil, self.model.card == nil, self.model.working.isEmpty else {
                self.model.toast = "Finish or close open orders first."
                self.model.recompute()
                return
            }
            self.switchAccount(to: name, thenSetup: false)
        }
        // A new account profile: a name, then the engine restarts with it and
        // the checklist walks through logging in.
        model.newAccount = { [weak self] in
            guard let self else { return }
            guard self.model.inflight == nil, self.model.card == nil, self.model.working.isEmpty else {
                self.model.toast = "Finish or close open orders first."
                self.model.recompute()
                return
            }
            let a = NSAlert()
            a.messageText = "New account profile"
            a.informativeText = "A short name for the other Shoonya account: letters, digits, - or _. You'll log in to it next."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.placeholderString = "e.g. family"
            a.accessoryView = field
            a.addButton(withTitle: "Create")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = field
            guard Focus.ask(a) == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard name.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil else {
                self.model.toast = "Account names are letters, digits, - or _."
                self.model.recompute()
                return
            }
            self.switchAccount(to: name, thenSetup: true)
        }
        model.copyDiagnostics = { [weak self] in
            guard let self else { return }
            let text = self.model.diagnostics + "\n" + self.bridge.diagnostics()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self.model.toast = "Diagnostics copied."
            self.model.recompute()
        }
        model.openLogs = { [weak self] in
            guard let folder = self?.bridge.logsFolder else { return }
            NSWorkspace.shared.open(folder)
        }

        // Nothing stays open across sleep. (The engine also checks the wall
        // clock, which keeps running while the Mac sleeps.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.sleeping() }
        }

        Task { @MainActor in
            await bridge.ensureRunning(client: client, model: model, adoptExisting: false)
            client.start()
            await bridge.keepRunning(client: client, model: model)
        }
    }

    /// The engine restarts with the chosen profile. The old account's
    /// checks go; a new account then gets the checklist, against the new engine.
    private func switchAccount(to name: String, thenSetup: Bool) {
        guard model.inflight == nil, model.card == nil, model.working.isEmpty else {
            model.toast = "Finish or close open orders first."
            model.recompute()
            return
        }
        UserDefaults.standard.set(name == "default" ? nil : name, forKey: BridgeProcess.accountKey)
        model.accountChecks = []
        Task { @MainActor in
            await self.bridge.restart(client: self.client, model: self.model)
            if thenSetup { self.model.openSetup() }
        }
    }

    private func registerTalkKey() {
        let ok = HotKeys.shared.register(.talk) { [weak self] in self?.model.talk() }
        model.talkKeyLabel = TalkKey.current.label
        model.talkKeyWorks = ok
        model.recompute()
    }

    /// An order that is out finishes, and its result is seen, before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.inflight == nil && !model.working.isEmpty {
            return restingOrdersLetUsQuit() ? .terminateNow : .terminateCancel
        }
        guard model.inflight != nil, model.connected else { return .terminateNow }
        model.toast = "An order is out. Quitting once its result is in…"
        model.recompute()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while model.inflight != nil && model.connected && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if model.inflight != nil && model.connected {
                model.quitTimedOut()                              // never quit on an order that's out
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)     // long enough to read it
            // It may have come back "resting": ask, as for any resting order.
            let quit = model.working.isEmpty || restingOrdersLetUsQuit()
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    /// A resting order stays with the broker, but nobody will be told when it
    /// fills: say so, and quit only on a clear yes.
    private func restingOrdersLetUsQuit() -> Bool {
        let a = NSAlert()
        let n = model.working.count
        a.messageText = "\(n) order\(n == 1 ? " is" : "s are") still resting."
        a.informativeText = "\(model.working.values.sorted().joined(separator: "\n"))\n\nIt stays with the broker if you quit, but Sayso stops following it and won't tell you when it fills."
        a.addButton(withTitle: "Don't Quit")
        a.addButton(withTitle: "Quit")
        return Focus.ask(a) == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ note: Notification) {
        bridge.stopIfOwned()
    }
}
