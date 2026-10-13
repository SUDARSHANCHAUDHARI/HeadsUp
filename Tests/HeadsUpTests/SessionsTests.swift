import XCTest
@testable import HeadsUp

// Sessions decides how many heads are on screen and when one goes away, from
// files a hook writes and a crash can leave behind. Every test works in its own
// temporary directory, never the real ~/.headsup.
final class SessionsTests: XCTestCase {
    private var root: URL!
    private var directory: URL!
    private var legacy: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HeadsUpTests-\(UUID().uuidString)")
        directory = root.appendingPathComponent("sessions")
        legacy = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ state: String, session: String, name: String = "", ago: TimeInterval = 0) throws {
        let url = session.isEmpty ? legacy! : directory.appendingPathComponent("\(session).state")
        try "\(state)\n\(name)\n".write(to: url, atomically: true, encoding: .utf8)
        if ago > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: url.path
            )
        }
    }

    private func read(happyHold: TimeInterval = 5) -> [Sessions.Reading] {
        Sessions.read(happyHold: happyHold, directory: directory, legacyFile: legacy)
    }

    func testNoFilesMeansNoHeads() {
        XCTAssertTrue(read().isEmpty)
    }

    func testOneHeadPerSessionFile() throws {
        try write("thinking", session: "a")
        try write("working", session: "b")

        let found = read()
        XCTAssertEqual(Set(found.map(\.id)), ["a", "b"])
        XCTAssertEqual(Set(found.map(\.state)), ["thinking", "working"])
    }

    /// Heads keep a stable order on screen, so the list is oldest file first.
    func testSessionsComeBackOldestFirst() throws {
        try write("idle", session: "new")
        try write("idle", session: "old", ago: 60)

        XCTAssertEqual(read().map(\.id), ["old", "new"])
    }

    /// An old hook that only knows the single file still drives one head.
    func testTheLegacyFileIsUsedWhenNoSessionFilesExist() throws {
        try write("working", session: "")

        let found = read()
        XCTAssertEqual(found.map(\.id), [Sessions.legacyID])
        XCTAssertEqual(found.first?.state, "working")
    }

    /// With both present the legacy file is ignored, or a new hook would show
    /// one real head and one ghost.
    func testSessionFilesWinOverTheLegacyFile() throws {
        try write("sleeping", session: "")
        try write("thinking", session: "a")

        XCTAssertEqual(read().map(\.id), ["a"])
    }

    func testHappyFadesToIdleOnceItsMomentHasPassed() throws {
        try write("happy", session: "a")
        XCTAssertEqual(read().first?.state, "happy")

        try write("happy", session: "a", ago: 30)
        XCTAssertEqual(read().first?.state, "idle")
    }

    func testTheSecondLineIsTheProjectName() throws {
        try write("working", session: "a", name: "MyApp")
        XCTAssertEqual(read().first?.name, "MyApp")
    }

    /// The hook wrote one line before labels existed; that file still works,
    /// it just has no name to show.
    func testAOneLineFileHasNoName() throws {
        try "thinking\n".write(to: directory.appendingPathComponent("a.state"), atomically: true, encoding: .utf8)

        let found = read()
        XCTAssertEqual(found.first?.state, "thinking")
        XCTAssertEqual(found.first?.name, "")
    }

    func testAnEmptyFileIsNotASession() throws {
        try "   \n".write(to: directory.appendingPathComponent("a.state"), atomically: true, encoding: .utf8)
        XCTAssertTrue(read().isEmpty)
    }

    func testOnlyStateFilesCount() throws {
        try "thinking\n".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(read().isEmpty)
    }

    func testAFinishedSessionKeepsItsHeadBrieflyThenLosesIt() throws {
        try write("sleeping", session: "a")
        XCTAssertFalse(Sessions.isOver(try XCTUnwrap(read().first)))

        try write("sleeping", session: "a", ago: Sessions.farewell + 5)
        XCTAssertTrue(Sessions.isOver(try XCTUnwrap(read().first)))
    }

    /// A session that died without saying goodbye — a crash, a kill, a reboot —
    /// must not leave a head on screen for ever.
    func testAnAbandonedSessionIsRetiredWhateverItsState() throws {
        try write("working", session: "a", ago: Sessions.abandoned + 60)
        XCTAssertTrue(Sessions.isOver(try XCTUnwrap(read().first)))
    }

    func testAWorkingSessionIsNeverRetired() throws {
        try write("working", session: "a")
        XCTAssertFalse(Sessions.isOver(try XCTUnwrap(read().first)))
    }

    /// The single head from an old hook is the app's whole interface; it stays.
    func testTheLegacyHeadIsNeverRetired() throws {
        try write("sleeping", session: "", ago: Sessions.abandoned + 60)
        XCTAssertFalse(Sessions.isOver(try XCTUnwrap(read().first)))
    }

    func testForgettingASessionRemovesItsFileButSparesTheLegacyOne() throws {
        try write("sleeping", session: "a")
        Sessions.forget(try XCTUnwrap(read().first))
        XCTAssertTrue(read().isEmpty)

        try write("sleeping", session: "")
        Sessions.forget(try XCTUnwrap(read().first))
        XCTAssertEqual(read().map(\.id), [Sessions.legacyID])
    }
}
