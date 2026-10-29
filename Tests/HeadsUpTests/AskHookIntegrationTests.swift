import XCTest
@testable import HeadsUp

// The one seam neither unit test covers: hooks/headsup-ask.sh writes the
// request and Ask.swift reads it, and nothing checks that the two agree on the
// format. A mismatch there breaks the whole feature silently — the hook waits,
// the app shows nothing, and the session hangs until the timeout.
//
// So this runs the real hook as a real subprocess, reads it with the real
// Ask.read, answers it with the real Ask.answer, and checks what the hook
// printed on stdout. HOME is redirected, so the real ~/.headsup is untouched.
final class AskHookIntegrationTests: XCTestCase {
    private var home: URL!

    private var hook: URL {
        // Tests/HeadsUpTests/this file -> repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("hooks/headsup-ask.sh")
    }

    private var askDirectory: URL { home.appendingPathComponent(".headsup/ask") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: hook.path), "hook script not found")
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HeadsUpHookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".headsup"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    /// Start the hook on a PermissionRequest event. Returns the process and a
    /// handle on its stdout, which is where the decision lands.
    private func startHook(event: String, timeout: String = "10") throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hook.path]
        process.environment = [
            "HOME": home.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HEADSUP_ASK_TIMEOUT": timeout,
            "HEADSUP_ASK_POLL": "0.05",
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(event.utf8))
        try input.fileHandleForWriting.close()
        return (process, output)
    }

    /// Wait for Ask.read to see the request the hook just wrote.
    private func waitForRequest(timeout: TimeInterval = 5) -> Ask.Request? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = Ask.read(directory: askDirectory).first { return request }
            usleep(50_000)
        }
        return nil
    }

    private func decision(from output: Pipe) -> [String: Any]? {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let specific = object["hookSpecificOutput"] as? [String: Any]
        else { return nil }
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        return specific["decision"] as? [String: Any]
    }

    private func event(tool: String, input: String) -> String {
        """
        {"hook_event_name":"PermissionRequest","session_id":"sess-1",\
        "cwd":"/Users/me/code/website","tool_name":"\(tool)","tool_input":\(input)}
        """
    }

    // MARK: -

    func testTheAppReadsWhatTheHookWrote() throws {
        // Alive, so the hook agrees to wait at all.
        Ask.heartbeat(home: home.appendingPathComponent(".headsup"))
        let (process, output) = try startHook(
            event: event(tool: "Bash", input: #"{"command":"npm install --save-dev vitest"}"#)
        )

        let request = waitForRequest()
        XCTAssertNotNil(request, "Ask.read could not see the hook's request")
        if let request {
            XCTAssertEqual(request.session, "sess-1")
            XCTAssertEqual(request.project, "website")
            XCTAssertEqual(request.tool, "Bash")
            XCTAssertEqual(request.detail, "npm install --save-dev vitest")
            XCTAssertFalse(request.isPlan)
            XCTAssertEqual(request.allowTitle, "Allow")

            XCTAssertTrue(Ask.answer(request, .allow))
        }

        process.waitUntilExit()
        let decision = decision(from: output)
        XCTAssertEqual(decision?["behavior"] as? String, "allow",
                       "the hook did not turn the app's answer into an allow decision")
    }

    func testDenyingFromTheAppReachesClaudeWithAMessage() throws {
        Ask.heartbeat(home: home.appendingPathComponent(".headsup"))
        let (process, output) = try startHook(event: event(tool: "Bash", input: #"{"command":"rm -rf build"}"#))

        let request = try XCTUnwrap(waitForRequest())
        XCTAssertTrue(Ask.answer(request, Ask.verdict(for: request, allow: false)))

        process.waitUntilExit()
        let decision = decision(from: output)
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertEqual(decision?["message"] as? String, "Denied from HeadsUp.")
    }

    func testSendingAPlanBackCarriesTheWordingForAPlan() throws {
        Ask.heartbeat(home: home.appendingPathComponent(".headsup"))
        let (process, output) = try startHook(
            // Two hashes: a plan's heading starts with "#", and in a #"…"#
            // string the "# would close it.
            event: event(tool: "ExitPlanMode", input: ##"{"plan":"# Ship v0.6\n\nsteps here"}"##)
        )

        let request = try XCTUnwrap(waitForRequest())
        XCTAssertTrue(request.isPlan)
        XCTAssertEqual(request.detail, "Ship v0.6")
        XCTAssertEqual(request.allowTitle, "Approve")
        XCTAssertEqual(request.denyTitle, "Send back")
        XCTAssertTrue(Ask.answer(request, Ask.verdict(for: request, allow: false)))

        process.waitUntilExit()
        let message = decision(from: output)?["message"] as? String
        XCTAssertEqual(
            message,
            "The user sent the plan back from HeadsUp. Ask what should be different before building."
        )
    }

    func testWithdrawingHandsTheQuestionBackToTheTerminal() throws {
        Ask.heartbeat(home: home.appendingPathComponent(".headsup"))
        let (process, output) = try startHook(event: event(tool: "Bash", input: #"{"command":"ls"}"#))

        let request = try XCTUnwrap(waitForRequest())
        Ask.withdraw(request)

        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(decision(from: output), "a withdrawn request must leave Claude Code's own prompt to decide")
    }

    func testWithNoHeartbeatTheHookDoesNotEvenWriteARequest() throws {
        // Nothing calls Ask.heartbeat here: this is HeadsUp not running, which
        // has to cost a permission prompt nothing at all.
        let started = Date()
        let (process, output) = try startHook(event: event(tool: "Bash", input: #"{"command":"ls"}"#), timeout: "30")
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(decision(from: output))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "a closed app must not delay a prompt")
        XCTAssertTrue(Ask.read(directory: askDirectory).isEmpty)
    }

    func testTheHookCleansUpAfterItself() throws {
        Ask.heartbeat(home: home.appendingPathComponent(".headsup"))
        let (process, output) = try startHook(event: event(tool: "Bash", input: #"{"command":"ls"}"#))
        let request = try XCTUnwrap(waitForRequest())
        XCTAssertTrue(Ask.answer(request, .allow))
        process.waitUntilExit()
        _ = decision(from: output)

        let left = (try? FileManager.default.contentsOfDirectory(atPath: askDirectory.path)) ?? []
        XCTAssertEqual(left, [], "leftovers would show as a request nobody is waiting on")
    }
}
