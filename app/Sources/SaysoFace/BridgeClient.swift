import Foundation

/// Where the engine listens. 8787 is also the broker's login redirect, as
/// registered on the API key page. There is no demo mode: every order is real.
enum AppMode {
    static let port = "8787"
}

/// Talks to the Sayso bridge on 127.0.0.1: a server-sent event stream in,
/// small JSON posts out.
@MainActor
final class BridgeClient {
    let base: URL
    private let model: Model
    private let session: URLSession

    /// This run's secret, written by the bridge to a file only this user can
    /// read (bridge.py write_token). Read fresh each time: the engine may have
    /// restarted with a new one.
    private let tokenFile: URL?

    init(model: Model, tokenFile: URL?) {
        self.model = model
        self.tokenFile = tokenFile
        base = URL(string: "http://127.0.0.1:\(AppMode.port)")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10          // the bridge sends a keepalive every 2 s
        cfg.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        let token = tokenFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        req.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Sayso")
        return req
    }

    func start() {
        Task { await self.listen() }
    }

    private func listen() async {
        while true {
            do {
                let (bytes, response) = try await session.bytes(for: request("events"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                model.connectionChanged(true)
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let json = Data(line.dropFirst(6).utf8)
                    if let e = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                        model.apply(e)
                    }
                }
            } catch {
                // fall through to reconnect
            }
            model.connectionChanged(false)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Whether a bridge answers.
    func answers() async -> Bool {
        var req = request("status")
        req.timeoutInterval = 1.5
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// A read: status code (0 if the bridge didn't answer) and the JSON reply.
    func get(_ path: String) async -> (Int, [String: Any]) {
        var req = request(String(path.dropFirst()))
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req) else { return (0, [:]) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    /// Status code (0 if the bridge didn't answer) and the JSON reply.
    func send(_ path: String, _ body: [String: Any] = [:]) async -> (Int, [String: Any]) {
        var req = request(String(path.dropFirst()))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        guard let (data, resp) = try? await session.data(for: req) else { return (0, [:]) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
    }

    func post(_ path: String, _ body: [String: Any] = [:],
              done: ((Int, [String: Any]) -> Void)? = nil) {
        Task {
            let (code, out) = await send(path, body)
            done?(code, out)
        }
    }
}
