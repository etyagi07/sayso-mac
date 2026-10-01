import AppKit

MainActor.assumeIsolated {
    // `--snapshot DIR`: render every state to PNG and exit.
    if Snapshot.runIfAsked() || Snapshot.iconIfAsked() { exit(0) }

    // One Sayso at a time: two panels would share the talk key and could
    // show cards from two different engines. The lock dies with the process.
    let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("com.ekanshtyagi.sayso.lock").path
    let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
    if lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) != 0 {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Sayso is already running."
        a.informativeText = "Only one Sayso panel can be open at a time. Quit the other one first (right-click it, Quit Sayso)."
        a.runModal()
        exit(0)
    }

    // No dock icon, no menu bar: the panel is the whole app.
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
