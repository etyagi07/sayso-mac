import XCTest
@testable import SaysoFace

/// The packaged engine is copied into Application Support: once per version,
/// and never left half-copied.
final class EngineInstallTests: XCTestCase {
    func testAFrozenEngineIsReplacedOnlyAfterTheLimit() {
        let now = Date()
        let start = now.addingTimeInterval(-120)
        // Silent for a moment: still fine. Silent past the limit: frozen.
        XCTAssertFalse(BridgeProcess.isHung(startedAt: start, silentSince: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(BridgeProcess.isHung(startedAt: start, silentSince: now.addingTimeInterval(-31), now: now))
        // Just started (loading): the clock runs from the start, not before it.
        XCTAssertFalse(BridgeProcess.isHung(startedAt: now.addingTimeInterval(-10),
                                            silentSince: now.addingTimeInterval(-60), now: now))
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sayso-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func bundle(_ version: String, file: String) throws -> URL {
        let b = dir.appendingPathComponent("bundled-\(version)")
        try FileManager.default.createDirectory(at: b.appendingPathComponent("sayso"), withIntermediateDirectories: true)
        try version.write(to: b.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try file.write(to: b.appendingPathComponent("sayso/agent.py"), atomically: true, encoding: .utf8)
        return b
    }

    private func read(_ root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent("sayso/agent.py"), encoding: .utf8)
    }

    func testInstallsThenSkipsTheSameVersionThenReplacesOnUpdate() throws {
        let root = dir.appendingPathComponent("Sayso/engine")
        try EngineLocation.install(from: try bundle("v1", file: "one"), to: root)
        XCTAssertEqual(read(root), "one")

        try "touched".write(to: root.appendingPathComponent("sayso/agent.py"), atomically: true, encoding: .utf8)
        try EngineLocation.install(from: try bundle("v1", file: "one"), to: root)
        XCTAssertEqual(read(root), "touched", "same version: left alone")

        try EngineLocation.install(from: try bundle("v2", file: "two"), to: root)
        XCTAssertEqual(read(root), "two", "new version: replaced")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Sayso").path)
        XCTAssertEqual(leftovers, ["engine"], "no staging folder left behind")
    }

    func testAnOlderCopyOfTheAppNeverRollsTheEngineBack() throws {
        let root = dir.appendingPathComponent("Sayso/engine")
        try EngineLocation.install(from: try bundle("bbb-20261002090000", file: "new"), to: root)
        XCTAssertThrowsError(try EngineLocation.install(from: try bundle("aaa-20261001090000", file: "old"), to: root))
        XCTAssertEqual(read(root), "new")
        // Signing the same package is not older; a later package replaces it.
        try EngineLocation.install(from: try bundle("bbb-20261002090000+signed", file: "signed"), to: root)
        XCTAssertEqual(read(root), "signed")
        try EngineLocation.install(from: try bundle("ccc-dirty-20261003090000", file: "newer"), to: root)
        XCTAssertEqual(read(root), "newer")
    }

    func testLeftoversFromAnInterruptedInstallAreSwept() throws {
        let parent = dir.appendingPathComponent("Sayso")
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("engine-installing-dead"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("engine-old-dead"),
                                                withIntermediateDirectories: true)
        try EngineLocation.install(from: try bundle("v1", file: "one"), to: parent.appendingPathComponent("engine"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["engine"])
    }

    func testTheInstalledCopyDoesNotKeepTheDownloadQuarantine() throws {
        let b = try bundle("v1", file: "one")
        let file = b.appendingPathComponent("sayso/agent.py")
        let flag = "com.apple.quarantine"
        let value = "0083;00000000;Safari;"
        XCTAssertEqual(setxattr(file.path, flag, value, value.utf8.count, 0, 0), 0)
        let root = dir.appendingPathComponent("Sayso/engine")
        try EngineLocation.install(from: b, to: root)
        XCTAssertEqual(getxattr(root.appendingPathComponent("sayso/agent.py").path, flag, nil, 0, 0, 0), -1)
        XCTAssertGreaterThan(getxattr(file.path, flag, nil, 0, 0, 0), 0, "the app's own bundle is untouched")
    }

    func testAFailedConnectorDownloadKeepsTheEngineInPlace() throws {
        let root = dir.appendingPathComponent("Sayso/engine")
        try EngineLocation.install(from: try bundle("v1", file: "one"), to: root)
        // v2 wants the connector, but has no Python to fetch it with: as if offline.
        let v2 = try bundle("v2", file: "two")
        try "NorenRestApiOAuth==0.0.41".write(to: v2.appendingPathComponent("sdk-requirements.txt"),
                                               atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EngineLocation.install(from: v2, to: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("needs the internet once"))
        }
        XCTAssertEqual(read(root), "one", "the working engine is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path),
                       ["engine"], "and nothing half-installed is left")
    }

    func testABundleWithoutAVersionIsRefused() throws {
        let b = dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        XCTAssertThrowsError(try EngineLocation.install(from: b, to: dir.appendingPathComponent("Sayso/engine")))
    }
}
