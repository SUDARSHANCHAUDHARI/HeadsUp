import Foundation

// Pending permission requests, and the answers that release them.
//
// headsup-ask.sh writes ~/.headsup/ask/<session>.<hook pid>.json and then
// blocks, polling for a matching .answer file. This is the other half: read the
// requests, write the answers, and keep the heartbeat the hook checks before it
// agrees to wait at all.
//
// The shape mirrors Sessions on purpose — a directory of small files, written
// write-then-rename, polled on a timer, with its own staleness rule.
enum Ask {
    static let home = Sessions.home
    static let directory = home.appendingPathComponent("ask")
    static let aliveFile = home.appendingPathComponent("alive")

    /// How often the heartbeat is rewritten. The hook ignores one older than
    /// 30 seconds, so this has to be comfortably under that.
    static let heartbeatEvery: TimeInterval = 10

    /// A request this old belongs to a hook that has already stopped waiting:
    /// its own timeout is 60s, so anything past that can never be answered.
    static let expired: TimeInterval = 75

    enum Verdict: String {
        case allow
        case deny
        /// Deny with the wording for a plan sent back rather than refused.
        case planDeny = "plan-deny"
    }

    struct Request: Equatable {
        /// The file's basename, `<session>.<hook pid>` — unique per request,
        /// because tools run in parallel and a session id alone is not enough.
        let id: String
        let session: String
        /// The folder the session is working in.
        let project: String
        let tool: String
        /// The command, the file, or the plan's heading: what you judge.
        let detail: String
        /// An ExitPlanMode request, which reads as approve or send back.
        let isPlan: Bool
        let url: URL

        /// What the buttons should say.
        var allowTitle: String { isPlan ? "Approve" : "Allow" }
        var denyTitle: String { isPlan ? "Send back" : "Deny" }

        /// One line for the head and the menu.
        var summary: String {
            if isPlan { return detail.isEmpty ? "Plan ready" : detail }
            return detail.isEmpty ? tool : "\(tool): \(detail)"
        }
    }

    // MARK: - heartbeat

    /// Tell the hook this app is running. Without a fresh file here the hook
    /// exits immediately and permission prompts behave as if HeadsUp were not
    /// installed, which is the behaviour we want when it really is not.
    static func heartbeat(home: URL = Ask.home) {
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let file = home.appendingPathComponent("alive")
            try "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: file, atomically: true, encoding: .utf8)
        } catch {
            // A missing heartbeat costs the feature, never the session: the
            // hook treats it as "not running" and gets out of the way.
            NSLog("HeadsUp: heartbeat failed: \(error.localizedDescription)")
        }
    }

    /// On the way out, so a hook started a moment later does not wait for a
    /// window that has gone.
    static func stopHeartbeat(home: URL = Ask.home) {
        try? FileManager.default.removeItem(at: home.appendingPathComponent("alive"))
    }

    // MARK: - reading

    /// Every request still worth asking about, oldest first so the queue keeps
    /// a stable order while you look at it.
    ///
    /// `directory` is a seam for the tests; the app always uses the real one.
    static func read(directory: URL = Ask.directory) -> [Request] {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let requests = (urls ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { read($0) }
        return requests.sorted { $0.modified < $1.modified }
            .filter { Date().timeIntervalSince($0.modified) <= expired }
            .map(\.request)
    }

    private struct Dated {
        let request: Request
        let modified: Date
    }

    private static func read(_ url: URL) -> Dated? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        let request = Request(
            id: url.deletingPathExtension().lastPathComponent,
            session: object["session"] as? String ?? "",
            project: object["project"] as? String ?? "",
            tool: object["tool"] as? String ?? "",
            detail: object["detail"] as? String ?? "",
            isPlan: object["plan"] as? Bool ?? false,
            url: url
        )
        guard !request.id.isEmpty else { return nil }
        return Dated(request: request, modified: modified)
    }

    // MARK: - answering

    /// Release the waiting hook. Written then renamed, so the hook can never
    /// read a half-written verdict.
    ///
    /// Returns false when the file could not be written, which leaves the hook
    /// to time out and the terminal to decide — the safe direction to fail.
    @discardableResult
    static func answer(_ request: Request, _ verdict: Verdict) -> Bool {
        let answer = request.url.deletingPathExtension().appendingPathExtension("answer")
        let tmp = answer.deletingLastPathComponent()
            .appendingPathComponent(".\(request.id).answer.tmp")
        do {
            try verdict.rawValue.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(answer, withItemAt: tmp)
            return true
        } catch {
            NSLog("HeadsUp: could not answer \(request.id): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// The verdict for a request, given which button was pressed.
    static func verdict(for request: Request, allow: Bool) -> Verdict {
        if allow { return .allow }
        return request.isPlan ? .planDeny : .deny
    }

    /// Drop a request without answering it: the hook sees its file vanish and
    /// hands the decision back to Claude Code's own prompt.
    static func withdraw(_ request: Request) {
        try? FileManager.default.removeItem(at: request.url)
    }
}
