import AppKit

// The About and Credits panels, built the same way as Comet Cursor's About: an
// icon, a few centred lines and link buttons, in a floating panel made once and
// reused.
//
// The package builds a bare executable with no Info.plist, so the version comes
// from the VERSION file at the repo root, copied into the bundle by build.sh,
// rather than CFBundleShortVersionString; the icon is the same SF Symbol the
// menu bar uses rather than the app icon.
//
// VERSION is the only place the number lives, so a release bumps one file.
let headsUpVersion: String = {
    guard let url = Bundle.module.url(forResource: "VERSION", withExtension: nil),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else {
        NSLog("HeadsUp: VERSION missing from the bundle; run ./build.sh")
        return "unknown"
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}()

final class AboutWindow {
    private var aboutPanel: NSPanel?
    private var creditsPanel: NSPanel?

    func showAbout() {
        if aboutPanel == nil { aboutPanel = buildAbout() }
        present(aboutPanel)
    }

    func showCredits() {
        if creditsPanel == nil { creditsPanel = buildCredits() }
        present(creditsPanel)
    }

    private func present(_ panel: NSPanel?) {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        if panel.frame.origin == .zero { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func buildAbout() -> NSPanel {
        let name = NSTextField(labelWithString: "HeadsUp")
        name.font = .systemFont(ofSize: 20, weight: .semibold)

        let email = linkButton("sunny.sudarshan@gmail.com", action: #selector(emailTapped))
        email.setAccessibilityLabel("Email Sudarshan Chaudhari")

        return panel(title: "About HeadsUp", width: 380, views: [icon(), name]
            + [
                label("Version: \(headsUpVersion)"),
                label("Author: Sudarshan Chaudhari"),
                label("Company: SudarshanTechLabs"),
                label("© 2026 SudarshanTechLabs."),
                label("All rights reserved."),
            ]
            + [email])
    }

    // The robot is not mine, and neither is most of the code that draws it, so
    // the credit belongs in the app and not only in the README.
    private func buildCredits() -> NSPanel {
        let title = NSTextField(labelWithString: "Credits")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let robotHeads = linkButton("github.com/fayazara/robot-heads", action: #selector(robotHeadsTapped))
        robotHeads.setAccessibilityLabel("Open the robot-heads repository")

        let heading = NSTextField(labelWithString: "The robot")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.alignment = .center

        return panel(title: "Credits", width: 420, views: [
            icon(), title,
            heading,
            label("robot-heads 0.3.0 by Fayaz Ahmed"),
            robotHeads,
            label("Used under the MIT licence, without React."),
            label("Its renderer is the larger part of this app:"),
            label("1,946 of 2,129 source lines."),
            label("HeadsUp adds the macOS window,"),
            label("the state file and the Claude Code hook."),
        ])
    }

    private func panel(title: String, width: CGFloat, views: [NSView]) -> NSPanel {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        // A fixed width keeps the lines off the edges; the height is whatever the
        // content needs, so no empty band is left under the last line.
        let size = NSSize(width: width, height: stack.fittingSize.height)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.contentView = stack
        panel.setContentSize(size)
        return panel
    }

    private func icon() -> NSImageView {
        let view = NSImageView()
        if let symbol = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "HeadsUp") {
            view.image = symbol.withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
        } else {
            view.image = NSApp.applicationIconImage
        }
        view.contentTintColor = .controlAccentColor
        view.imageScaling = .scaleProportionallyUpOrDown
        view.widthAnchor.constraint(equalToConstant: 72).isActive = true
        view.heightAnchor.constraint(equalToConstant: 72).isActive = true
        view.setAccessibilityLabel("HeadsUp icon")
        return view
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .linkColor
        // Without this the first link draws a focus ring the moment the panel opens.
        button.refusesFirstResponder = true
        return button
    }

    @objc private func emailTapped() {
        open("mailto:sunny.sudarshan@gmail.com")
    }

    @objc private func robotHeadsTapped() {
        open("https://github.com/fayazara/robot-heads")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else {
            NSLog("HeadsUp: bad link: \(string)")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
