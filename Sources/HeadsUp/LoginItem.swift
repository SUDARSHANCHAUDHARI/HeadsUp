import Foundation

// Start at login, as a per-user LaunchAgent.
//
// SMAppService.mainApp would be the modern route, but it needs a bundled .app
// registered with LaunchServices and the Swift package builds a bare
// executable. A LaunchAgent needs neither a bundle nor a signature.
//
// This is the only place that writes the plist. scripts/login-item.sh and the
// menu-bar toggle both come through here.
enum LoginItem {
    static let label = "com.sudarshantechlabs.headsup"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var domain: String { "gui/\(getuid())" }

    /// The running binary, resolved through symlinks so the plist keeps working
    /// if the caller was launched through one.
    private static var executablePath: String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var isLoaded: Bool {
        run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    @discardableResult
    static func install() throws -> String {
        let exe = executablePath
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            throw Failure("not executable: \(exe)")
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            // No KeepAlive: quitting from the menu stays quit until next login.
            "ProcessType": "Interactive",
        ]
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        } catch {
            throw Failure("could not build the plist: \(error.localizedDescription)")
        }
        let url = plistURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure("could not write \(url.path): \(error.localizedDescription)")
        }
        // Replace any previous registration; bootout fails harmlessly when absent.
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let boot = run("/bin/launchctl", ["bootstrap", domain, url.path])
        guard boot.status == 0 else {
            throw Failure("launchctl bootstrap failed (\(boot.status)): \(boot.output)")
        }
        return url.path
    }

    @discardableResult
    static func uninstall() throws -> Bool {
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        guard isInstalled else { return false }
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch {
            throw Failure("could not remove \(plistURL.path): \(error.localizedDescription)")
        }
        return true
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "could not run \(tool): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// `HeadsUp --login-item install|uninstall|status`, so the shell script and the
/// menu-bar toggle share one implementation. Returns an exit code, or nil when
/// the arguments are not a login-item command and the app should launch.
func runLoginItemCommand(_ arguments: [String]) -> Int32? {
    guard arguments.count >= 2, arguments[1] == "--login-item" else { return nil }
    let action = arguments.count >= 3 ? arguments[2] : ""
    do {
        switch action {
        case "install":
            let path = try LoginItem.install()
            print("installed: \(path)")
            print("HeadsUp will start at every login, and is starting now.")
        case "uninstall":
            print(try LoginItem.uninstall() ? "removed: \(LoginItem.plistURL.path)" : "nothing to remove")
        case "status":
            print("plist:   \(LoginItem.isInstalled ? LoginItem.plistURL.path : "not installed")")
            print("agent:   \(LoginItem.isLoaded ? "loaded" : "not loaded")")
        default:
            FileHandle.standardError.write(Data("usage: HeadsUp --login-item install | uninstall | status\n".utf8))
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 1
    }
}
