import AppKit
import WebKit

// One robot head: a transparent panel, the page that draws it, and the state
// it is currently showing. One of these exists per live Claude Code session.
//
// The head owns nothing about where state comes from; the delegate polls the
// files and hands each head its word.
final class Head: NSObject, WKNavigationDelegate {
    /// Room under the head for the session's name.
    static let labelHeight: CGFloat = 18

    let session: String
    let panel: NSPanel
    let web: HeadView
    let label = NSTextField(labelWithString: "")
    private var shown = ""
    private var loaded = false
    private var look: Look
    /// Set once the page is up, so a state that arrived during loading is not lost.
    private var pending: String?

    init(session: String, look: Look, origin: NSPoint, autosave: String?) {
        self.session = session
        self.look = look
        let size = NSSize(width: headSize.width, height: headSize.height + Head.labelHeight)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        web = HeadView(frame: NSRect(x: 0, y: Head.labelHeight, width: headSize.width, height: headSize.height),
                       configuration: WKWebViewConfiguration())
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // Only the first head remembers where it was put: session ids are new
        // every time, so saving a frame per session would pile up junk.
        if let autosave {
            if !panel.setFrameUsingName(autosave) { panel.setFrameOrigin(origin) }
            panel.setFrameAutosaveName(autosave)
        }

        // Undocumented KVC key; the only way to give WKWebView a transparent background on macOS.
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self

        // The name sits on the desktop with nothing behind it, so it carries its
        // own shadow rather than relying on the wallpaper being dark.
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()
        label.frame = NSRect(x: 0, y: 0, width: panel.frame.width, height: Head.labelHeight)

        let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        content.addSubview(web)
        content.addSubview(label)
        panel.contentView = content

        guard let dir = Bundle.module.url(forResource: "web", withExtension: nil) else {
            fatalError("web resources missing from bundle; run ./build.sh")
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        web.navigationDelegate = nil
    }

    /// The folder this session is working in. Empty hides the label and the
    /// room it takes, so a hook that does not send one costs nothing.
    var name: String = "" {
        didSet {
            guard name != oldValue else { return }
            label.stringValue = name
            label.toolTip = name.isEmpty ? nil : name
            layout()
        }
    }

    var isVisible: Bool { panel.isVisible }
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    /// What this head is showing, for the menu.
    var state: String { shown }

    func setState(_ next: String) {
        guard next != shown else { return }
        guard loaded else {
            pending = next
            return
        }
        // Record it only once the page took it, so a failed call is retried.
        web.evaluateJavaScript("setState(\(jsString(next)))") { [weak self] _, error in
            if let error {
                NSLog("HeadsUp: setState failed: \(error)")
                return
            }
            self?.shown = next
        }
    }

    // The page owns the head's bounds, so take the size it reports and fit the
    // window to it, keeping the top-left corner where it was.
    func apply(_ look: Look) {
        self.look = look
        guard loaded else { return }
        web.evaluateJavaScript("setLook(\(look.json))") { [weak self] result, error in
            if let error {
                NSLog("HeadsUp: setLook failed: \(error)")
                return
            }
            guard let self,
                  let size = (result as? [NSNumber])?.map(\.doubleValue),
                  size.count == 2, size[0] > 0, size[1] > 0
            else { return }
            self.resize(to: NSSize(width: size[0], height: size[1]))
        }
    }

    /// The size the page last reported for its canvas.
    private var headBounds = headSize

    private func resize(to size: NSSize) {
        headBounds = size
        layout()
    }

    /// The window is the head plus, when there is one, a line of text under it.
    private func layout() {
        let room = name.isEmpty ? 0 : Head.labelHeight
        let size = NSSize(width: headBounds.width, height: headBounds.height + room)
        var next = panel.frame
        // Keep the top edge still, so a head does not jump when its name arrives.
        next.origin.y = next.maxY - size.height
        next.size = size
        if panel.frame != next { panel.setFrame(next, display: true) }
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        web.frame = NSRect(x: 0, y: room, width: size.width, height: headBounds.height)
        label.frame = NSRect(x: 0, y: 0, width: size.width, height: Head.labelHeight)
        label.isHidden = name.isEmpty
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A reload leaves the fresh page knowing nothing of what it was showing,
        // and back on the stock look.
        loaded = true
        shown = ""
        apply(look)
        if let pending {
            self.pending = nil
            setState(pending)
        }
    }

    func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"idle\"]"
        return String(array.dropFirst().dropLast())
    }
}
