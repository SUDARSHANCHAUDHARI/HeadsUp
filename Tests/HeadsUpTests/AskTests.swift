import XCTest
@testable import HeadsUp

// Ask is the half of the permission channel that runs in the app: it reads the
// requests the hook parks, and writes the answers that release it. Getting an
// answer wrong leaves a session waiting, so the write path is tested as closely
// as the read path. Every test works in its own temporary directory, never the
// real ~/.headsup.
final class AskTests: XCTestCase {
    private var root: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HeadsUpAskTests-\(UUID().uuidString)")
        directory = root.appendingPathComponent("ask")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Write a request the way hooks/headsup-ask.sh does.
    @discardableResult
    private func write(
        id: String,
        session: String = "s1",
        project: String = "website",
        tool: String = "Bash",
        detail: String = "npm install",
        plan: Bool = false,
        ago: TimeInterval = 0
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(id).json")
        let body: [String: Any] = [
            "session": session, "project": project, "tool": tool, "detail": detail, "plan": plan,
        ]
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        if ago > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: url.path
            )
        }
        return url
    }

    private func read() -> [Ask.Request] {
        Ask.read(directory: directory)
    }

    // MARK: - reading

    func testNoFilesMeansNothingPending() {
        XCTAssertTrue(read().isEmpty)
    }

    func testARequestIsReadBackWhole() throws {
        try write(id: "s1.4242", project: "site", tool: "Edit", detail: "page.tsx")
        let request = try XCTUnwrap(read().first)
        XCTAssertEqual(request.id, "s1.4242")
        XCTAssertEqual(request.session, "s1")
        XCTAssertEqual(request.project, "site")
        XCTAssertEqual(request.tool, "Edit")
        XCTAssertEqual(request.detail, "page.tsx")
        XCTAssertFalse(request.isPlan)
    }

    func testOnlyJsonFilesCount() throws {
        try write(id: "s1.1")
        try "allow".write(to: directory.appendingPathComponent("s1.1.answer"), atomically: true, encoding: .utf8)
        try "noise".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(read().count, 1)
    }

    func testRequestsComeBackOldestFirst() throws {
        try write(id: "s1.300", ago: 1)
        try write(id: "s1.100", ago: 30)
        try write(id: "s1.200", ago: 15)
        XCTAssertEqual(read().map(\.id), ["s1.100", "s1.200", "s1.300"])
    }

    func testARequestOlderThanTheHooksOwnWaitIsIgnored() throws {
        // The hook gives up after 60s, so answering a 90s-old request would
        // write into a void and leave the button looking live.
        try write(id: "s1.1", ago: 90)
        XCTAssertTrue(read().isEmpty)
    }

    func testAMalformedRequestIsSkippedRatherThanCrashing() throws {
        try "{ not json".write(to: directory.appendingPathComponent("s1.9.json"), atomically: true, encoding: .utf8)
        try write(id: "s1.10")
        XCTAssertEqual(read().map(\.id), ["s1.10"])
    }

    func testAMissingFieldLeavesAnEmptyValueNotAMissingRequest() throws {
        let url = directory.appendingPathComponent("s1.11.json")
        try JSONSerialization.data(withJSONObject: ["session": "s1"]).write(to: url)
        let request = try XCTUnwrap(read().first)
        XCTAssertEqual(request.tool, "")
        XCTAssertEqual(request.detail, "")
        XCTAssertFalse(request.isPlan)
    }

    // MARK: - what the buttons say

    func testAnOrdinaryRequestReadsAsAllowAndDeny() throws {
        try write(id: "s1.1", tool: "Bash", detail: "npm install")
        let request = try XCTUnwrap(read().first)
        XCTAssertEqual(request.allowTitle, "Allow")
        XCTAssertEqual(request.denyTitle, "Deny")
        XCTAssertEqual(request.summary, "Bash: npm install")
    }

    func testAPlanReadsAsApproveAndSendBack() throws {
        try write(id: "s1.1", tool: "ExitPlanMode", detail: "Ship v0.6", plan: true)
        let request = try XCTUnwrap(read().first)
        XCTAssertTrue(request.isPlan)
        XCTAssertEqual(request.allowTitle, "Approve")
        XCTAssertEqual(request.denyTitle, "Send back")
        XCTAssertEqual(request.summary, "Ship v0.6")
    }

    func testASummaryFallsBackToTheToolWhenThereIsNoDetail() throws {
        try write(id: "s1.1", tool: "WebFetch", detail: "")
        XCTAssertEqual(try XCTUnwrap(read().first).summary, "WebFetch")
    }

    func testAPlanWithNoHeadingStillSaysSomething() throws {
        try write(id: "s1.1", tool: "ExitPlanMode", detail: "", plan: true)
        XCTAssertEqual(try XCTUnwrap(read().first).summary, "Plan ready")
    }

    // MARK: - answering

    func testAllowWritesTheVerdictBesideTheRequest() throws {
        try write(id: "s1.77")
        let request = try XCTUnwrap(read().first)
        XCTAssertTrue(Ask.answer(request, .allow))
        let answer = directory.appendingPathComponent("s1.77.answer")
        XCTAssertEqual(try String(contentsOf: answer, encoding: .utf8), "allow")
    }

    func testDenyWritesDeny() throws {
        try write(id: "s1.78")
        let request = try XCTUnwrap(read().first)
        XCTAssertTrue(Ask.answer(request, .deny))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("s1.78.answer"), encoding: .utf8),
            "deny"
        )
    }

    func testSendingAPlanBackIsItsOwnVerdict() throws {
        // The hook turns plan-deny into different wording for Claude, so the
        // two must not collapse into one.
        try write(id: "s1.79", tool: "ExitPlanMode", plan: true)
        let request = try XCTUnwrap(read().first)
        XCTAssertEqual(Ask.verdict(for: request, allow: false), .planDeny)
        XCTAssertEqual(Ask.verdict(for: request, allow: true), .allow)
        XCTAssertTrue(Ask.answer(request, .planDeny))
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("s1.79.answer"), encoding: .utf8),
            "plan-deny"
        )
    }

    func testAnOrdinaryDenyIsNotThePlanWording() throws {
        try write(id: "s1.80", tool: "Bash", plan: false)
        let request = try XCTUnwrap(read().first)
        XCTAssertEqual(Ask.verdict(for: request, allow: false), .deny)
    }

    func testNoHalfWrittenAnswerIsLeftBehind() throws {
        try write(id: "s1.81")
        let request = try XCTUnwrap(read().first)
        XCTAssertTrue(Ask.answer(request, .allow))
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "a temporary file would be read as a stale request")
    }

    func testAnswersStayInsideTheirOwnRequest() throws {
        try write(id: "s1.1")
        try write(id: "s1.2")
        let requests = read()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(Ask.answer(requests[0], .allow))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(requests[0].id).answer").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(requests[1].id).answer").path))
    }

    // MARK: - withdrawing

    func testWithdrawingRemovesTheRequestWithoutAnsweringIt() throws {
        try write(id: "s1.90")
        let request = try XCTUnwrap(read().first)
        Ask.withdraw(request)
        XCTAssertTrue(read().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("s1.90.answer").path),
            "withdrawing must not look like a decision"
        )
    }

    // MARK: - heartbeat

    func testTheHeartbeatHoldsThisProcessId() throws {
        Ask.heartbeat(home: root)
        let text = try String(contentsOf: root.appendingPathComponent("alive"), encoding: .utf8)
        XCTAssertEqual(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                       ProcessInfo.processInfo.processIdentifier)
    }

    func testTheHeartbeatCreatesItsDirectory() throws {
        let fresh = root.appendingPathComponent("not-there-yet")
        Ask.heartbeat(home: fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appendingPathComponent("alive").path))
    }

    func testStoppingRemovesTheHeartbeat() throws {
        Ask.heartbeat(home: root)
        Ask.stopHeartbeat(home: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("alive").path))
    }

    func testStoppingTwiceIsHarmless() {
        Ask.stopHeartbeat(home: root)
        Ask.stopHeartbeat(home: root)
    }
}
