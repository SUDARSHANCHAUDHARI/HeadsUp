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
        var state = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.isEmpty { return nil }
        // Happy is a flash at the end of a turn, not a resting state.
        if state == "happy", Date().timeIntervalSince(modified) > happyHold { state = "idle" }
        return Reading(id: id, state: state, modified: modified, url: url)
    }

    /// True once a finished session has had its moment and its head should go.
    static func isOver(_ reading: Reading) -> Bool {
        guard reading.id != legacyID else { return false } // the old single head never leaves
        let age = Date().timeIntervalSince(reading.modified)
        return (reading.state == "sleeping" && age > farewell) || age > abandoned
    }

    /// Tidy up after a head we closed, so the next scan does not find it again.
    static func forget(_ reading: Reading) {
        guard reading.id != legacyID else { return }
        try? FileManager.default.removeItem(at: reading.url)
    }
}
