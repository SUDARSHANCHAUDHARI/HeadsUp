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
    /// Which fan-out slot each head sits in, so a head opening after one in the
    /// middle has closed takes the gap rather than landing on its neighbour.
    var slots: [String: Int] = [:]
    var hidden = false
    var timer: Timer?
    /// Rewrites ~/.headsup/alive. The ask hook refuses to wait on a stale
    /// heartbeat, which is what makes a crashed app harmless to a session.
    var heartbeatTimer: Timer?
    var status: NSStatusItem!
    let visibilityItem = NSMenuItem(title: "Hide Head", action: #selector(toggleHead), keyEquivalent: "")
    let sessionsItem = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
    /// The submenu behind the session count, one row per session.
    let sessionsMenu = NSMenu()
    let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
    let antennaItem = NSMenuItem(title: "Antenna", action: #selector(toggleAntenna), keyEquivalent: "")
    var look = Look.load()
    var lookMenus: [LookField: NSMenu] = [:]
    let about = AboutWindow()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildStatusItem()
        // Before the first poll: the hook checks this file to decide whether
        // anything is listening, and a request written before we say we are
        // here would be waited on by nobody.
        Ask.heartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Ask.heartbeatEvery, repeats: true) { _ in
            Ask.heartbeat()
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    func applicationWillTerminate(_ note: Notification) {
        // Say we have gone, then hand back anything still pending: a hook left
        // waiting on a closed app would sit there for its full 60 seconds,
        // when Claude Code could be asking in the terminal instead.
        Ask.stopHeartbeat()
        for request in Ask.read() { Ask.withdraw(request) }
    }

    // One pass over the session files: open heads for new sessions, update the
    // ones already on screen, and retire the sessions that have finished.
    func poll() {
        let readings = Sessions.read(happyHold: happyHold)
        // Oldest first, so the head shows the request that has been waiting
        // longest. Tools run in parallel, so one session can have several.
        var pending: [String: Ask.Request] = [:]
        for request in Ask.read() where pending[request.session] == nil {
            pending[request.session] = request
        }
        var live: Set<String> = []

        for reading in readings {
            if Sessions.isOver(reading) {
                Sessions.forget(reading)
                continue
            }
            live.insert(reading.id)
            if let head = heads[reading.id] {
                head.name = reading.name
                head.request = pending[reading.id]
                head.setState(reading.state)
            } else {
                open(reading, request: pending[reading.id])
            }
        }

        for id in order where !live.contains(id) { close(id) }
    }

    /// Answer the permission the head is showing, then take the buttons away.
    /// The hook deletes its own files, so nothing is cleaned up here.
    func decide(_ request: Ask.Request, allow: Bool) {
        Ask.answer(request, Ask.verdict(for: request, allow: allow))
        heads[request.session]?.request = nil
    }

    func open(_ reading: Sessions.Reading, request: Ask.Request? = nil) {
        // The first head keeps the remembered position; the rest fan out to its
        // left, into the lowest free slot.
        let first = order.isEmpty
        var slot = 0
        while slots.values.contains(slot) { slot += 1 }
        slots[reading.id] = slot
        let step = CGFloat(slot) * (headSize.width + 16)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(x: screen.maxX - headSize.width - 24 - step, y: screen.minY + 24)

        let head = Head(session: reading.id, look: look, origin: origin, autosave: first ? "HeadsUp" : nil)
        if hidden { head.hide() }
        head.onDecision = { [weak self] request, allow in self?.decide(request, allow: allow) }
        head.name = reading.name
        head.request = request
        head.setState(reading.state)
        heads[reading.id] = head
        order.append(reading.id)
    }

    func close(_ id: String) {
        // A head going away while Claude still waits: hand the question back
        // rather than leave the hook waiting on a window that has gone.
        if let request = heads[id]?.request { Ask.withdraw(request) }
        heads.removeValue(forKey: id)?.close()
        order.removeAll { $0 == id }
        slots.removeValue(forKey: id)
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
        // The count on the menu, the detail one row per session behind it: all of
        // them on one line made the menu wider than the screen deserves, and all
        // of them inline made it taller the more sessions were running.
        sessionsItem.title = order.isEmpty ? "No sessions"
            : (order.count == 1 ? "1 session" : "\(order.count) sessions")
        sessionsMenu.removeAllItems()
        for id in order {
            guard let head = heads[id] else { continue }
            var title = head.name.isEmpty ? head.state : "\(head.name) — \(head.state)"
            if let request = head.request {
                title += " — waiting: \(request.summary)"
            }
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.isEnabled = false
            sessionsMenu.addItem(row)
        }
        sessionsItem.submenu = order.isEmpty ? nil : sessionsMenu
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
