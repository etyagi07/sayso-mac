import Foundation

/// Where the engine is, and where its per-user state goes.
///
/// - A development build (`build.sh`) names its checkout in Info.plist
///   (`SaysoProject`), or `SAYSO_PROJECT` overrides it. The checkout's own
///   venv runs, and state stays beside the code, as in a terminal.
/// - A packaged build (`package.sh`) carries the engine and a Python runtime
///   in `Resources/engine`. It is installed to
///   `~/Library/Application Support/Sayso/engine` on first launch and after
///   every update, and all state (login, settings, logs) lives beside it.
struct EngineLocation {
    let root: URL           // holds bridge/ and sayso/
    let python: URL
    let home: URL?          // SAYSO_HOME; nil keeps state beside the code
    let bundled: URL?       // the copy inside the app, for a packaged build

    var logs: URL { (home ?? root).appendingPathComponent("logs") }

    static func find() -> EngineLocation? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["SAYSO_PROJECT"] ?? Bundle.main.object(forInfoDictionaryKey: "SaysoProject") as? String {
            let root = URL(fileURLWithPath: p)
            return EngineLocation(root: root, python: root.appendingPathComponent("sayso/.venv/bin/python"),
                                  home: nil, bundled: nil)
        }
        guard let bundled = Bundle.main.url(forResource: "engine", withExtension: nil) else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sayso")
        let root = support.appendingPathComponent("engine")
        return EngineLocation(root: root, python: root.appendingPathComponent("python/bin/python3"),
                              home: support, bundled: bundled)
    }

    enum InstallError: LocalizedError {
        case connector(String)
        case older
        var errorDescription: String? {
            switch self {
            case .older:
                return "A newer Sayso is already installed on this Mac. Open that one, " +
                       "and delete this older copy."
            case .connector(let detail):
                return "Sayso needs the internet once, to download Shoonya's connector. " +
                       "It will try again by itself. (\(detail))"
            }
        }
    }

    /// Shoonya's connector (NorenRestApiOAuth) may not be copied, so the app
    /// never carries it: it is downloaded here, into the staged engine, from
    /// PyPI, pinned to one file by its checksum (`sdk-requirements.txt`). A
    /// dev build has it in its own venv and no such file.
    static func installConnector(_ root: URL) throws {
        let requirements = root.appendingPathComponent("sdk-requirements.txt")
        guard FileManager.default.fileExists(atPath: requirements.path) else { return }
        let pip = Process()
        pip.executableURL = root.appendingPathComponent("python/bin/python3")
        pip.arguments = ["-s", "-E", "-m", "pip", "install", "--no-deps", "--require-hashes",
                         "--no-cache-dir", "--disable-pip-version-check", "--no-warn-script-location",
                         "--quiet", "-r", requirements.path]
        let output = Pipe()
        pip.standardOutput = output
        pip.standardError = output
        do {
            try pip.run()
        } catch {
            throw InstallError.connector(error.localizedDescription)
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pip.waitUntilExit()
        guard pip.terminationStatus == 0 else {
            let last = text.split(separator: "\n").last.map(String.init) ?? "pip failed"
            throw InstallError.connector(String(last.prefix(160)))
        }
    }

    /// A copy keeps macOS's download quarantine flag. The engine is this
    /// app's own content, approved when the app was opened (and, once
    /// signed, notarised with it), so the installed copy doesn't carry the
    /// flag: with it, Gatekeeper would judge each binary again when the
    /// engine starts, and refuse them offline. Only this copy is touched.
    static func stripQuarantine(_ root: URL) {
        let flag = "com.apple.quarantine"
        removexattr(root.path, flag, XATTR_NOFOLLOW)
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let relative as String in walk {
            removexattr(root.appendingPathComponent(relative).path, flag, XATTR_NOFOLLOW)
        }
    }

    /// Copy the bundled engine into place unless that exact version is
    /// already there. A half-finished copy never becomes the engine: it is
    /// staged beside it and swapped in by renames, and nothing half-copied
    /// is ever left behind to fill the disk.
    /// When a package was made: the end of its VERSION (package.sh), as in
    /// "53dfddd-20261001001221" or "…+signed". nil for anything else.
    static func stamp(_ version: String) -> String? {
        let last = version.split(separator: "+").first?.split(separator: "-").last.map(String.init) ?? ""
        return last.count == 14 && last.allSatisfy(\.isNumber) ? last : nil
    }

    static func install(from bundled: URL, to root: URL) throws {
        let fm = FileManager.default
        func version(_ dir: URL) -> String? {
            (try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let want = version(bundled) else { throw CocoaError(.fileReadCorruptFile) }
        if version(root) == want { return }
        if let have = version(root).flatMap(stamp), let new = stamp(want), new < have {
            throw InstallError.older       // an old copy of the app must not roll the engine back
        }
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Leftovers from an interrupted install.
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasPrefix("engine-installing-") || name.hasPrefix("engine-old-") {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
        let staging = parent.appendingPathComponent("engine-installing-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: bundled, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        stripQuarantine(staging)
        do {
            try installConnector(staging)
        } catch {
            try? fm.removeItem(at: staging)        // the engine in place stays as it is
            throw error
        }
        let old = parent.appendingPathComponent("engine-old-\(UUID().uuidString)")
        if fm.fileExists(atPath: root.path) { try fm.moveItem(at: root, to: old) }
        do {
            try fm.moveItem(at: staging, to: root)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: root) }   // put it back
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: old)
    }
}

/// Starts the Sayso bridge in the right mode, replaces one left over from an
/// earlier launch, and relaunches it if it dies, backing off if it keeps
/// failing. Stops it on quit if this app started it. It never stops an engine
/// another Sayso window is using: the bridge refuses that itself.
///
///   SAYSO_PROJECT   path to a source checkout (development)
///   SAYSO_ACCOUNT   Sayso account profile
@MainActor
final class BridgeProcess {
    private var process: Process?
    private let env = ProcessInfo.processInfo.environment
    private var failures = 0
    private let location = EngineLocation.find()
    private var installed = false
    private var restarting = false
    private var startedAt = Date.distantPast
    private var silentSince: Date?
    static let accountKey = "sayso.account"
    /// How long our own engine may run without answering before it is replaced.
    nonisolated static let hangLimit: TimeInterval = 30

    /// Running but silent for longer than hangLimit, counting from its start
    /// at the earliest (loading the engine takes a few seconds).
    nonisolated static func isHung(startedAt: Date, silentSince: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(max(startedAt, silentSince)) > hangLimit
    }

    var logsFolder: URL? { location?.logs }
    /// Where the bridge writes this run's secret (bridge.py token_file).
    var tokenFile: URL? { location?.logs.appendingPathComponent(".token-\(AppMode.port)") }

    /// The account profile: chosen in the menu, else SAYSO_ACCOUNT.
    private var account: String? {
        UserDefaults.standard.string(forKey: Self.accountKey) ?? env["SAYSO_ACCOUNT"]
    }

    /// Where the engine runs from and its last log lines, to trace a problem.
    func diagnostics() -> String {
        guard let loc = location else { return "engine: not included in this build" }
        let version = (try? String(contentsOf: loc.root.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "checkout"
        let log = (try? String(contentsOf: loc.logs.appendingPathComponent("bridge.log"), encoding: .utf8)) ?? ""
        let tail = log.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
        return "engine \(version) at \(loc.root.path)\n── bridge.log (last 40 lines)\n\(tail)"
    }

    /// Stop the engine this app started and let the watchdog start it again
    /// (with the account now chosen). Nothing adopts the old one meanwhile.
    func restart(client: BridgeClient, model: Model) async {
        guard let p = process, p.isRunning else {
            model.toast = "Quit and reopen Sayso to switch accounts."
            model.recompute()
            return
        }
        restarting = true
        p.terminate()
        for _ in 0..<160 {
            if process?.isRunning != true, !(await client.answers()) { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        restarting = false
    }

    /// Put a packaged engine in place before the first start. False, with
    /// the reason on the panel, if there is no engine to run.
    func prepare(model: Model) async -> Bool {
        guard let loc = location else {
            model.engineProblem = "This build of Sayso doesn't include its engine."
            return false
        }
        guard let bundled = loc.bundled, !installed else { return true }
        model.engineProblem = "Installing the engine (the first time, it downloads Shoonya's connector)…"
        let root = loc.root
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try EngineLocation.install(from: bundled, to: root); return nil }
            catch { return error.localizedDescription }
        }.value
        if let error = result {
            model.engineProblem = "Couldn't install the engine: \(error)"
            return false
        }
        installed = true
        model.engineProblem = nil
        return true
    }

    /// Keep an engine in the right mode running for as long as the app is open.
    func keepRunning(client: BridgeClient, model: Model) async {
        while true {
            let up = await ensureRunning(client: client, model: model)
            // A silent engine of ours is watched every 3 s, so a frozen one
            // is replaced on time.
            failures = up || silentSince != nil ? 0 : failures + 1
            // 3 s while healthy; 6, 12, 24, 48, 60 s while it keeps failing.
            let wait = min(3 * pow(2, Double(min(failures, 5))), 60)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// True once an engine in the right mode answers.
    @discardableResult
    func ensureRunning(client: BridgeClient, model: Model, adoptExisting: Bool = true) async -> Bool {
        if restarting { return false }
        if await client.answers() {
            silentSince = nil
            // An engine left from an earlier launch is replaced on start-up:
            // the microphone grant belongs to this app, and only a child of
            // this app is covered by it. The login survives (it's on disk).
            if adoptExisting || process != nil {
                model.engineProblem = nil
                return true
            }
            let (code, body) = await client.send("/shutdown")
            if code == 409 && body["held"] as? Bool == true {
                // It holds news of a real order nobody has seen: keep it, so
                // this window shows that news first.
                model.engineProblem = nil
                return true
            }
            if code == 409 {
                model.engineProblem = "Another Sayso window is using the engine."
                return false
            }
            for _ in 0..<20 {
                if !(await client.answers()) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        if let p = process, p.isRunning {
            // Ours, still starting up, or frozen: a frozen one is replaced.
            let since = silentSince ?? Date()
            silentSince = since
            guard Self.isHung(startedAt: startedAt, silentSince: since) else { return false }
            silentSince = nil
            model.engineProblem = "The engine stopped responding, so Sayso is restarting it."
            p.terminate()
            for _ in 0..<20 where p.isRunning { try? await Task.sleep(nanoseconds: 250_000_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return false
        }
        guard await prepare(model: model), start(model: model) else { return false }
        for _ in 0..<40 {
            if await client.answers() { return true }
            if process?.isRunning != true { return false }   // exited: the reason is on screen
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func start(model: Model) -> Bool {
        guard let loc = location else { return false }
        let script = loc.root.appendingPathComponent("bridge/bridge.py")
        // -s -E: nothing from the user's own Python set-up leaks in.
        var args = ["-s", "-E", script.path, "--port", AppMode.port]
        if let a = account, !a.isEmpty { args += ["--account", a] }

        // Appended, never truncated: the log of the run that crashed survives
        // the restart that follows it. Past 5 MB it rolls over to .1.
        let fm = FileManager.default
        try? fm.createDirectory(at: loc.logs, withIntermediateDirectories: true)
        let logURL = loc.logs.appendingPathComponent("bridge.log")
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5_000_000 {
            let old = loc.logs.appendingPathComponent("bridge.log.1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: logURL, to: old)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }

        let p = Process()
        p.executableURL = loc.python
        p.arguments = args
        p.currentDirectoryURL = loc.root
        if let home = loc.home {
            // The speech model is kept with Sayso's own state, not in a shared cache.
            p.environment = env.merging(["SAYSO_HOME": home.path,
                                         "HF_HOME": home.appendingPathComponent("models").path]) { $1 }
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            // The throwing calls: a full disk is an error, not a crash.
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data("\n── \(Date()) starting engine on \(AppMode.port)\n".utf8))
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak model] proc in
            let code = proc.terminationStatus
            Task { @MainActor in model?.engineExited(code) }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
            silentSince = nil
            return true
        } catch {
            process = nil
            model.engineProblem = "Couldn't start the engine: \(loc.python.path) is missing."
            return false
        }
    }

    func stopIfOwned() {
        process?.terminate()        // the bridge cancels any card and lets an order finish
    }
}
