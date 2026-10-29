import Foundation

// Where the hook puts what it knows.
//
// Each live Claude Code session writes ~/.headsup/sessions/<id>.state. The
// single ~/.headsup/state file is what the hook wrote before sessions existed;
// it is still read, but only when no session file exists, so an old hook keeps
// working and a new one never shows a duplicate head.
enum Sessions {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".headsup")
    static let directory = home.appendingPathComponent("sessions")
    static let legacyFile = home.appendingPathComponent("state")

    /// The id used for the head driven by the pre-sessions state file.
    static let legacyID = "legacy"

    /// A head goes away this long after its session said goodbye, so the
    /// sleeping face is seen before the window disappears.
    static let farewell: TimeInterval = 20
    /// A session file nobody has touched for this long is from a session that
    /// died without a SessionEnd — a crash, a kill, a reboot.
    static let abandoned: TimeInterval = 60 * 60

    struct Reading {
        let id: String
        let state: String
        /// The folder the session is working in, shown under its head so the
        /// heads can be told apart. Empty when the hook did not say.
        let name: String
        /// What the current tool is doing — a command, a file name. Empty when
        /// nothing is running, and empty for the two-line files an older hook
        /// wrote before v0.6.
        let detail: String
        /// The pid of the session's Claude Code process. Nil for the files an
        /// older hook wrote, which is why the age fallback below stays.
        let owner: pid_t?
        let modified: Date
        let url: URL
    }

    /// Every session worth showing a head for, oldest file first so heads keep
    /// a stable order on screen.
    ///
    /// The two URLs are a seam for the tests; the app always uses the real ones.
    static func read(
        happyHold: TimeInterval,
        directory: URL = Sessions.directory,
        legacyFile: URL = Sessions.legacyFile
    ) -> [Reading] {
        var found = files(in: directory).compactMap {
            read($0, id: $0.deletingPathExtension().lastPathComponent, happyHold: happyHold)
        }
        if found.isEmpty, let legacy = read(legacyFile, id: legacyID, happyHold: happyHold) {
            found = [legacy]
        }
        return found.sorted { $0.modified < $1.modified }
    }

    private static func files(in directory: URL) -> [URL] {
        let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )
        return (urls ?? []).filter { $0.pathExtension == "state" }
    }

    private static func read(_ url: URL, id: String, happyHold: TimeInterval) -> Reading? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        // Line one is the state, line two the folder, line three what the tool
        // is doing. A shorter file is what an older hook wrote — one line
        // before labels existed, two before detail — so a missing line is a
        // missing value, never a reason to drop the head.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var state = (lines.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        if state.isEmpty { return nil }
        let name = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespaces) : ""
        let detail = lines.count > 2 ? String(lines[2]).trimmingCharacters(in: .whitespaces) : ""
        let owner = lines.count > 3
            ? pid_t(String(lines[3]).trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
            : nil
        // Happy is a flash at the end of a turn, not a resting state.
        if state == "happy", Date().timeIntervalSince(modified) > happyHold { state = "idle" }
        return Reading(id: id, state: state, name: name, detail: detail, owner: owner, modified: modified, url: url)
    }

    /// Whether a pid still belongs to a running process. EPERM means it is
    /// alive but owned by someone else, which is still alive.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// True once a finished session has had its moment and its head should go.
    ///
    /// `isRunning` is a seam for the tests; the app always uses the real one.
    static func isOver(_ reading: Reading, isRunning: (pid_t) -> Bool = Sessions.isRunning) -> Bool {
        guard reading.id != legacyID else { return false } // the old single head never leaves
        let age = Date().timeIntervalSince(reading.modified)
        // A file dated in the future never ages out, so it would otherwise
        // leave a head on screen for ever. Checked before anything else,
        // including the goodbye, which also compares against the age.
        if age < 0 { return true }
        // A goodbye is shown for its moment first, even though the process is
        // usually already gone by the time SessionEnd's file lands.
        if reading.state == "sleeping" { return age > farewell }
        // The session's process is gone: closing a terminal fires no
        // SessionEnd, so there is nothing to wait an hour for. Liveness
        // replaces the hour here rather than adding to it, because a live
        // session left idle overnight must keep its head, and its file's mtime
        // is as old as its last event.
        // shortcut: a pid recycled onto an unrelated process keeps the head
        // until HeadsUp restarts; upgrade to checking the pid is still a
        // claude process if that is ever seen in practice.
        if let owner = reading.owner { return !isRunning(owner) }
        return age > abandoned
    }

    /// Tidy up after a head we closed, so the next scan does not find it again.
    static func forget(_ reading: Reading) {
        guard reading.id != legacyID else { return }
        try? FileManager.default.removeItem(at: reading.url)
    }
}
