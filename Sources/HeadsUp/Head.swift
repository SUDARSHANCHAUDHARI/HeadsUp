import AppKit
import WebKit

// One robot head: a transparent panel, the page that draws it, and the state
// it is currently showing. One of these exists per live Claude Code session.
//
// Under the head sit up to three more rows, each appearing only when it has
// something to say: the session's folder, what the current tool is doing, and
// — when Claude is waiting on a permission — Allow and Deny.
//
// The head owns nothing about where any of that comes from; the delegate polls
// the files and hands each head its values.
final class Head: NSObject, WKNavigationDelegate {
    /// Room under the head for the session's name.
    static let labelHeight: CGFloat = 18
    /// Room for the line saying what the tool is doing.
    static let detailHeight: CGFloat = 15
    /// Room for the Allow/Deny row.
    static let buttonHeight: CGFloat = 26
    /// A head is narrower than two readable buttons, so a pending request
    /// widens the window to at least this.
    static let buttonRowWidth: CGFloat = 150

    let session: String
    let panel: NSPanel
    let web: HeadView
    let label = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let allowButton = NSButton(title: "Allow", target: nil, action: nil)
    let denyButton = NSButton(title: "Deny", target: nil, action: nil)
    private var shown = ""
    private var loaded = false
    private var look: Look
    /// Set once the page is up, so a state that arrived during loading is not lost.
    private var pending: String?

    /// Called when Allow or Deny is pressed. The head does not know what a
    /// decision means; it only reports which button was hit.
    var onDecision: ((Ask.Request, Bool) -> Void)?

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
        style(label, size: 11, weight: .semibold, alpha: 1)
        // The detail is the quieter of the two, and the one that can be long,
        // so it truncates in the middle: the end of a path matters as much as
        // its start.
        style(detailLabel, size: 10, weight: .regular, alpha: 0.82)
        detailLabel.lineBreakMode = .byTruncatingMiddle

        for button in [allowButton, denyButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.isHidden = true
        }
        allowButton.action = #selector(allowPressed)
        denyButton.action = #selector(denyPressed)
        // No key equivalent on Allow: a Return pressed anywhere would approve
        // whatever is pending, and a permission is not something to grant by
        // accident.
        allowButton.keyEquivalent = ""

        let content = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        content.addSubview(web)
        content.addSubview(label)
        content.addSubview(detailLabel)
        content.addSubview(allowButton)
        content.addSubview(denyButton)
        panel.contentView = content

        guard let dir = Bundle.module.url(forResource: "web", withExtension: nil) else {
            fatalError("web resources missing from bundle; run ./build.sh")
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        panel.orderFrontRegardless()
    }

    private func style(_ field: NSTextField, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = NSColor.white.withAlphaComponent(alpha)
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        web.navigationDelegate = nil
        onDecision = nil
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

    /// What the current tool is doing. Same deal: empty costs no room.
    var detail: String = "" {
        didSet {
            guard detail != oldValue else { return }
            detailLabel.stringValue = detail
            detailLabel.toolTip = detail.isEmpty ? nil : detail
            layout()
        }
    }

    /// The permission Claude is waiting on, if any. Setting it puts the two
    /// buttons under the head; clearing it takes them away again.
    var request: Ask.Request? {
        didSet {
            guard request?.id != oldValue?.id || request?.detail != oldValue?.detail else { return }
            if let request {
                allowButton.title = request.allowTitle
                denyButton.title = request.denyTitle
                // Read aloud, "Allow" on its own says nothing about what is
                // being allowed, so the whole request goes in the label.
                allowButton.setAccessibilityLabel("\(request.allowTitle): \(request.summary)")
                denyButton.setAccessibilityLabel("\(request.denyTitle): \(request.summary)")
                allowButton.toolTip = request.summary
                denyButton.toolTip = request.summary
            }
            allowButton.isHidden = request == nil
            denyButton.isHidden = request == nil
            layout()
        }
    }

    @objc private func allowPressed() {
        guard let request else { return }
        onDecision?(request, true)
    }

    @objc private func denyPressed() {
        guard let request else { return }
        onDecision?(request, false)
    }

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

    /// The window is the head plus whichever of the three rows under it have
    /// something to show. Each row costs nothing when it is empty.
    private func layout() {
        let nameRoom = name.isEmpty ? 0 : Head.labelHeight
        let detailRoom = detail.isEmpty ? 0 : Head.detailHeight
        let buttonRoom = request == nil ? 0 : Head.buttonHeight
        let width = max(headBounds.width, request == nil ? 0 : Head.buttonRowWidth)
        let size = NSSize(width: width, height: headBounds.height + nameRoom + detailRoom + buttonRoom)

        var next = panel.frame
        // Keep the top edge still, so a head does not jump when a row arrives.
        next.origin.y = next.maxY - size.height
        next.size = size
        if panel.frame != next { panel.setFrame(next, display: true) }
        panel.contentView?.frame = NSRect(origin: .zero, size: size)

        // Laid out from the bottom up: buttons, detail, name, then the head.
        var y: CGFloat = 0
        if buttonRoom > 0 {
            let gap: CGFloat = 6
            let buttonWidth = (width - gap) / 2
            denyButton.frame = NSRect(x: 0, y: y + 2, width: buttonWidth, height: Head.buttonHeight - 4)
            allowButton.frame = NSRect(x: buttonWidth + gap, y: y + 2, width: buttonWidth, height: Head.buttonHeight - 4)
            y += buttonRoom
        }
        if detailRoom > 0 {
            detailLabel.frame = NSRect(x: 2, y: y, width: width - 4, height: Head.detailHeight)
            y += detailRoom
        }
        if nameRoom > 0 {
            label.frame = NSRect(x: 2, y: y, width: width - 4, height: Head.labelHeight)
            y += nameRoom
        }
        web.frame = NSRect(x: (width - headBounds.width) / 2, y: y,
                           width: headBounds.width, height: headBounds.height)

        label.isHidden = name.isEmpty
        detailLabel.isHidden = detail.isEmpty
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
