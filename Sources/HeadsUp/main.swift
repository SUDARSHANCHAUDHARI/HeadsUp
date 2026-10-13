import AppKit
import WebKit

// A floating robot head that shows what Claude Code is doing.
// Claude Code hooks write one word to ~/.headsup/state; this app polls it
// and hands it to the page's window.setState(). The menu bar sets how the
// head looks through window.setLook().

let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".headsup/state")
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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSMenuDelegate {
    var panel: NSPanel!
    var web: HeadView!
    var shown = ""
    var timer: Timer?
    var status: NSStatusItem!
    let stateItem = NSMenuItem(title: "State: —", action: nil, keyEquivalent: "")
    let visibilityItem = NSMenuItem(title: "Hide Head", action: #selector(toggleHead), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let pauseItem = NSMenuItem(title: "Pause Animation", action: #selector(togglePause), keyEquivalent: "")
    let antennaItem = NSMenuItem(title: "Antenna", action: #selector(toggleAntenna), keyEquivalent: "")
    var look = Look.load()
    var lookMenus: [LookField: NSMenu] = [:]
    let about = AboutWindow()

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: headSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        if !panel.setFrameUsingName("HeadsUp") {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrameOrigin(NSPoint(x: screen.maxX - headSize.width - 24, y: screen.minY + 24))
        }
        panel.setFrameAutosaveName("HeadsUp")

        web = HeadView(frame: NSRect(origin: .zero, size: headSize), configuration: WKWebViewConfiguration())
        // Undocumented KVC key; the only way to give WKWebView a transparent background on macOS.
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        panel.contentView = web

        guard let dir = Bundle.module.url(forResource: "web", withExtension: nil) else {
            fatalError("web resources missing from bundle; run ./build.sh")
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        panel.orderFrontRegardless()
        buildStatusItem()
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
        stateItem.title = "State: \(shown.isEmpty ? currentState() : shown)"
        visibilityItem.title = panel.isVisible ? "Hide Head" : "Show Head"
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

    // The page owns the head's bounds, so take the size it reports and fit the
    // window to it, keeping the top-left corner where it was.
    func pushLook() {
        web.evaluateJavaScript("setLook(\(look.json))") { [weak self] result, error in
            if let error {
                NSLog("HeadsUp: setLook failed: \(error)")
                return
            }
            guard let self,
                  let size = (result as? [NSNumber])?.map(\.doubleValue),
                  size.count == 2, size[0] > 0, size[1] > 0
            else { return }
            self.resizeHead(to: NSSize(width: size[0], height: size[1]))
        }
    }

    func resizeHead(to size: NSSize) {
        guard panel.frame.size != size else { return }
        var next = panel.frame
        next.origin.y = next.maxY - size.height
        next.size = size
        panel.setFrame(next, display: true)
        web.frame = NSRect(origin: .zero, size: size)
    }

    @objc func toggleHead() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A reload would otherwise leave the previous poller running, and the
        // fresh page knows nothing of what the old one was showing.
        timer?.invalidate()
        shown = ""
        // A fresh page is back on the stock look, so send ours before anything
        // is drawn.
        pushLook()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        let next = currentState()
        guard next != shown else { return }
        // Record it only once the page took it, so a failed call is retried.
        web.evaluateJavaScript("setState(\(jsString(next)))") { [weak self] _, error in
            if let error {
                NSLog("HeadsUp: setState failed: \(error)")
                return
            }
            self?.shown = next
        }
    }

    // No file yet means no session has run: show it asleep.
    func currentState() -> String {
        guard let text = try? String(contentsOf: stateURL, encoding: .utf8) else { return "sleeping" }
        let state = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if state == "happy",
           let modified = try? stateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) > happyHold {
            return "idle"
        }
        return state
    }

    func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"idle\"]"
        return String(array.dropFirst().dropLast())
    }
}

// `HeadsUp --login-item …` manages the LaunchAgent and exits without a window.
if let code = runLoginItemCommand(CommandLine.arguments) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
