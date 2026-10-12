import AppKit
import WebKit

// A floating robot head that shows what Claude Code is doing.
// Claude Code hooks write one word to ~/.headsup/state; this app polls it
// and hands it to the page's window.setState().

let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".headsup/state")
let headSize = NSSize(width: 132, height: 164) // frameFor(rectangle, antenna, 120) in web/src/main.ts
let happyHold: TimeInterval = 5

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

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var panel: NSPanel!
    var web: HeadView!
    var shown = ""
    var timer: Timer?

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
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A reload would otherwise leave the previous poller running, and the
        // fresh page knows nothing of what the old one was showing.
        timer?.invalidate()
        shown = ""
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
