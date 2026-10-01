import AppKit
import Combine
import SwiftUI

/// A non-activating panel: it floats over the chart and never takes focus,
/// except briefly when something has to be typed (a price, a command, login).
final class FloatingPanel: NSPanel {
    private let model: Model
    private var subs = Set<AnyCancellable>()
    private var allowKey = false
    private static let anchorKey = "sayso.anchor"

    init(model: Model) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 48),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: RootView().environmentObject(model))
        // The panel's size comes only from its shape. Left to itself, the
        // hosting view resizes the window to whatever its content prefers,
        // which grew the set-up card off the bottom of the screen.
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 48)
        host.autoresizingMask = [.width, .height]
        contentView = host

        placeInitially()

        model.$shape
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shape in self?.resize(to: shape.size) }
            .store(in: &subs)

        model.$wantsKeyboard
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] wants in self?.setKeyboard(wants) }
            .store(in: &subs)

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: self, queue: .main) { [weak self] _ in
            self?.rememberAnchor()
        }
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }

    /// An app with no menu bar has no Edit menu, and ⌘V/⌘C/⌘X/⌘A/⌘Z are
    /// normally delivered through it. Route them to the focused field directly
    /// so credentials, prices and commands can be pasted.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch (key, mods.contains(.shift)) {
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("a", false): action = #selector(NSResponder.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true):  action = Selector(("redo:"))
        default:           action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func setKeyboard(_ wants: Bool) {
        allowKey = wants
        if wants {
            Focus.borrow()
            makeKey()
        } else {
            if isKeyWindow { resignKey() }
            Focus.giveBack()
        }
    }

    // MARK: anchoring — the corner nearest a screen edge stays put, so the
    // BUY/SELL line lands in the same physical spot every time.

    private var screenFrame: NSRect { (screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    private func anchorCorner(for f: NSRect) -> (left: Bool, bottom: Bool) {
        let s = screenFrame
        return (f.midX < s.midX, f.midY < s.midY)
    }

    private func resize(to size: CGSize) {
        let old = frame
        let (left, bottom) = anchorCorner(for: old)
        let x = left ? old.minX : old.maxX - size.width
        let y = bottom ? old.minY : old.maxY - size.height
        var new = NSRect(x: x, y: y, width: size.width, height: size.height)
        new = clamp(new)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().setFrame(new, display: true)
        }
    }

    private func clamp(_ r: NSRect) -> NSRect {
        let s = screenFrame
        var r = r
        r.origin.x = min(max(r.origin.x, s.minX + 8), s.maxX - r.width - 8)
        r.origin.y = min(max(r.origin.y, s.minY + 8), s.maxY - r.height - 8)
        return r
    }

    private func placeInitially() {
        let s = screenFrame
        let size = Shape.pill.size
        if let saved = UserDefaults.standard.array(forKey: Self.anchorKey) as? [Double], saved.count == 2 {
            setFrame(clamp(NSRect(x: saved[0], y: saved[1], width: size.width, height: size.height)), display: false)
        } else {
            // Bottom-right by default, clear of the dock.
            setFrame(NSRect(x: s.maxX - size.width - 24, y: s.minY + 24,
                            width: size.width, height: size.height), display: false)
        }
    }

    private func rememberAnchor() {
        UserDefaults.standard.set([Double(frame.minX), Double(frame.minY)], forKey: Self.anchorKey)
    }
}
