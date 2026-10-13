import AppKit
import WebKit

// Floating robot heads that show what Claude Code is doing.
// Each live session's hook writes one word to ~/.headsup/sessions/<id>.state;
// this app polls the directory, keeps one head per session, and hands each its
// word through the page's window.setState(). The menu bar sets how they look
// through window.setLook().
// A first guess only: the page reports its real bounds back from setLook(),
// and they move with the shape and the antenna.
let headSize = NSSize(width: 132, height: 164) // frameFor(rectangle, antenna, 120) in web/src/main.ts
let happyHold: TimeInterval = 5

// Which part of the look a menu item sets; the value rides in the item's
// representedObject.
enum LookField: Int { case shape, shell, trim, screen, speed }

final class HeadView: WKWebView {
    // Drag the window from anywhere on the head; right-click to quit.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    // WebKit builds its own context menu (Reload, …); swap its items for Quit.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
        let quit = NSMenuItem(title: "Quit HeadsUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// One head per session id, in the order they appeared.
    var heads: [String: Head] = [:]
    var order: [String] = []
    var hidden = false
    var timer: Timer?
    var status: NSStatusItem!
    let stateItem = NSMenuItem(title: "State: —", action: nil, keyEquivalent: "")
    let visibilityItem = NSMenuItem(title: "Hide Head", action: #selector(toggleHead), keyEquivalent: "")
    let sessionsItem = NSMenuItem(title: "Sessions: —", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
    let antennaItem = NSMenuItem(title: "Antenna", action: #selector(toggleAntenna), keyEquivalent: "")
    var look = Look.load()
    var lookMenus: [LookField: NSMenu] = [:]
    let about = AboutWindow()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildStatusItem()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    // One pass over the session files: open heads for new sessions, update the
    // ones already on screen, and retire the sessions that have finished.
    func poll() {
        let readings = Sessions.read(happyHold: happyHold)
        var live: Set<String> = []

        for reading in readings {
            if Sessions.isOver(reading) {
                Sessions.forget(reading)
                continue
            }
            live.insert(reading.id)
            if let head = heads[reading.id] {
                head.setState(reading.state)
            } else {
                open(reading)
            }
        }

        for id in order where !live.contains(id) { close(id) }
    }

    func open(_ reading: Sessions.Reading) {
        // The first head keeps the remembered position; the rest fan out to its
        // left, so a second session never lands exactly on top of the first.
        let first = order.isEmpty
        let step = CGFloat(order.count) * (headSize.width + 16)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.maxX - headSize.width - 24 - step, y: screen.minY + 24)

        let head = Head(session: reading.id, look: look, origin: origin, autosave: first ? "HeadsUp" : nil)
        if hidden { head.hide() }
        head.setState(reading.state)
        heads[reading.id] = head
        order.append(reading.id)
    }

    func close(_ id: String) {
        heads.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
    }

    // The head has no Dock icon, so the menu bar is where everything else lives.
    func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Fall back to text, so a missing symbol never leaves an invisible item.
        if let icon = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "HeadsUp") {
            status.button?.image = icon
        } else {
            status.button?.title = "HeadsUp"
        }
        status.button?.toolTip = "HeadsUp"

        let menu = NSMenu()
        menu.delegate = self
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        sessionsItem.isEnabled = false
        menu.addItem(sessionsItem)
        menu.addItem(.separator())
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(lookSubmenu("Shape", .shape, Look.shapes.map { ($0.capitalized, $0) }))
        menu.addItem(lookSubmenu("Shell", .shell, Look.shells.map { ($0, $0) }))
        menu.addItem(lookSubmenu("Trim", .trim, Look.trims.map { ($0, $0) }))
        menu.addItem(lookSubmenu("Screen", .screen, Look.screens.map { ($0, $0) }))
        menu.addItem(lookSubmenu("Speed", .speed, Look.speeds.map { (Look.speedLabel($0), $0) }))
        antennaItem.target = self
        menu.addItem(antennaItem)
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "About HeadsUp…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let creditsItem = NSMenuItem(title: "Credits…", action: #selector(showCredits), keyEquivalent: "")
        creditsItem.target = self
        menu.addItem(creditsItem)
        let quit = NSMenuItem(title: "Quit HeadsUp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        status.menu = menu
    }

    /// One submenu of look choices: a title to show, a value to send.
    func lookSubmenu(_ title: String, _ field: LookField, _ choices: [(String, Any)]) -> NSMenuItem {
        let menu = NSMenu()
        for (label, value) in choices {
            let item = NSMenuItem(title: label, action: #selector(pickLook(_:)), keyEquivalent: "")
            item.target = self
            item.tag = field.rawValue
            item.representedObject = value
            menu.addItem(item)
        }
        lookMenus[field] = menu
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    // Both toggles can change behind our back, so read the truth on open.
    func menuWillOpen(_ menu: NSMenu) {
        let states = order.compactMap { heads[$0]?.state }.filter { !$0.isEmpty }
        stateItem.title = "State: \(states.first ?? "—")"
        switch order.count {
        case 0: sessionsItem.title = "No sessions"
        case 1: sessionsItem.title = "1 session"
        default: sessionsItem.title = "\(order.count) sessions: \(states.joined(separator: ", "))"
        }
        visibilityItem.title = hidden ? "Show Heads" : "Hide Heads"
        loginItem.state = LoginItem.isInstalled ? .on : .off
        antennaItem.state = look.antenna ? .on : .off
        pauseItem.state = look.paused ? .on : .off
        mark(.shape, look.shape)
        mark(.shell, look.shell)
        mark(.trim, look.trim)
        mark(.screen, look.screen)
        mark(.speed, look.speed)
    }

    /// Tick the one item in a submenu that matches the current look.
    func mark(_ field: LookField, _ value: Any) {
        for item in lookMenus[field]?.items ?? [] {
            let chosen: Bool
            if let want = value as? String {
                chosen = item.representedObject as? String == want
            } else if let want = value as? Double {
                chosen = item.representedObject as? Double == want
            } else {
                chosen = false
            }
            item.state = chosen ? .on : .off
        }
    }

    @objc func pickLook(_ item: NSMenuItem) {
        switch LookField(rawValue: item.tag) {
        case .shape: look.shape = item.representedObject as? String ?? look.shape
        case .shell: look.shell = item.representedObject as? String ?? look.shell
        case .trim: look.trim = item.representedObject as? String ?? look.trim
        case .screen: look.screen = item.representedObject as? String ?? look.screen
        case .speed: look.speed = item.representedObject as? Double ?? look.speed
        case .none: return
        }
        look.save()
        pushLook()
    }

    @objc func togglePause() {
        look.paused.toggle()
        look.save()
        pushLook()
    }

    @objc func showAbout() {
        about.showAbout()
    }

    @objc func showCredits() {
        about.showCredits()
    }

    @objc func toggleAntenna() {
        look.antenna.toggle()
        look.save()
        pushLook()
    }

    func pushLook() {
        for head in heads.values { head.apply(look) }
    }

    @objc func toggleHead() {
        hidden.toggle()
        for head in heads.values {
            if hidden { head.hide() } else { head.show() }
        }
    }

    @objc func toggleLogin() {
        do {
            if LoginItem.isInstalled {
                _ = try LoginItem.uninstall()
            } else {
                _ = try LoginItem.install()
            }
        } catch {
            NSLog("HeadsUp: login item failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Could not change Start at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        loginItem.state = LoginItem.isInstalled ? .on : .off
    }

}

// `HeadsUp --login-item …` manages the LaunchAgent and exits without a window.
if let code = runLoginItemCommand(CommandLine.arguments) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
