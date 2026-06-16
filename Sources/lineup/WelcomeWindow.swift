import AppKit

/// First-launch welcome. Shown once, BEFORE the system Accessibility prompt, so a new user
/// understands what Lineup is and why it needs permission instead of being dropped cold into a
/// scary OS dialog for an app whose window they never saw (Lineup is a menu-bar agent). Native
/// chrome on purpose: it should read like a standard macOS first-run sheet.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onGrant: () -> Void
    private let onClose: () -> Void

    /// `onGrant` runs the permission request; `onClose` fires once when the window is dismissed
    /// by any means (Grant, Not now, or the close button) so the caller can mark onboarding done.
    init(onGrant: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onGrant = onGrant
        self.onClose = onClose
        super.init()
    }

    func show() {
        let size = NSSize(width: 460, height: 388)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "Welcome to Lineup"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = makeContent(size: size)
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func makeContent(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let icon = NSImageView(frame: NSRect(x: size.width / 2 - 44, y: size.height - 124, width: 88, height: 88))
        icon.image = appIcon()
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        let title = NSTextField(labelWithString: "Welcome to Lineup")
        title.frame = NSRect(x: 30, y: size.height - 166, width: size.width - 60, height: 28)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        view.addSubview(title)

        let body = NSTextField(wrappingLabelWithString:
            "Lineup lives in your menu bar, at the top of your screen. To move and resize your windows it needs one permission, Accessibility. That is the only thing it asks for, and it never collects your data.")
        body.frame = NSRect(x: 44, y: 132, width: size.width - 88, height: 96)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        view.addSubview(body)

        let later = NSButton(title: "Not now", target: self, action: #selector(laterTapped))
        later.bezelStyle = .rounded
        later.frame = NSRect(x: 30, y: 28, width: 120, height: 32)
        later.setAccessibilityLabel("Continue without granting Accessibility yet")
        view.addSubview(later)

        let grant = NSButton(title: "Grant Access", target: self, action: #selector(grantTapped))
        grant.bezelStyle = .rounded
        grant.keyEquivalent = "\r"
        grant.contentTintColor = Brand.blue   // one blue: the brand accent, not the system accent
        grant.frame = NSRect(x: size.width - 30 - 150, y: 28, width: 150, height: 32)
        view.addSubview(grant)

        return view
    }

    @objc private func grantTapped() { onGrant(); window?.close() }
    @objc private func laterTapped() { window?.close() }

    // Single dismissal hook: whichever way the window closes, onboarding is recorded once.
    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }

    private func appIcon() -> NSImage {
        if let icon = NSImage(named: "AppIcon") { return icon }
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
        return NSApplication.shared.applicationIconImage
    }
}
