import AppKit

/// Sayso floats beside the chart and only borrows the keyboard: for a typed
/// price, a command, or an alert. Afterwards the app that had it gets it back,
/// unless the trader has since moved on to another app.
@MainActor
enum Focus {
    private static var previous: NSRunningApplication?

    /// Note who has the keyboard now, before Sayso takes it.
    static func borrow() {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previous = front
        }
    }

    static func giveBack() {
        guard let app = previous else { return }
        previous = nil
        let front = NSWorkspace.shared.frontmostApplication
        guard !app.isTerminated, front == .current || front == app else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// Show an alert in front of everything, then hand the keyboard back.
    /// Over a screen that already has the keyboard (the limits screen), it
    /// stays with Sayso until that screen closes.
    static func ask(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let nested = previous != nil
        borrow()
        NSApp.activate(ignoringOtherApps: true)
        defer { if !nested { giveBack() } }
        return alert.runModal()
    }
}
