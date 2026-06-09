import AppKit

final class AboutWindowController: NSObject, NSWindowDelegate {
    private static let shared = AboutWindowController()

    private var window: NSWindow?

    static func show() {
        shared.showWindow()
    }

    /// The About content as an embeddable view (Settings hosts it in an About tab).
    /// Pass the 420×430 natural size; the caller centers it in its container.
    static func makeEmbeddedContent(size: NSSize) -> NSView {
        shared.makeContent(size: size)
    }

    private func showWindow() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 420, height: 430)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "About Lineup"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = makeContent(size: size)
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func makeContent(size: NSSize) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let icon = NSImageView(frame: NSRect(x: size.width / 2 - 42, y: size.height - 108, width: 84, height: 84))
        icon.image = appIcon()
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        let title = label("Lineup", y: size.height - 148, size: 24, weight: .semibold, color: .labelColor)
        title.alignment = .center
        view.addSubview(title)

        let version = label(versionLine(), y: size.height - 176, size: 12, weight: .regular, color: .secondaryLabelColor)
        version.alignment = .center
        view.addSubview(version)

        if let built = buildDateLine() {
            let build = label(built, y: size.height - 198, size: 12, weight: .regular, color: .secondaryLabelColor)
            build.alignment = .center
            view.addSubview(build)
        }

        let card = NSView(frame: NSRect(x: 42, y: 104, width: size.width - 84, height: 150))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.borderWidth = 1
        view.addSubview(card)

        addLinkRow(to: card, y: 102, title: "Website", value: "lineup.caiano.com", url: "https://lineup.caiano.com")
        addDivider(to: card, y: 93)
        addLinkRow(to: card, y: 56, title: "GitHub", value: "github.com/hcaiano/lineup", url: "https://github.com/hcaiano/lineup")
        addDivider(to: card, y: 47)
        addLinkRow(to: card, y: 10, title: "Email", value: "henrique@gam3s.gg", url: "mailto:henrique@gam3s.gg")

        let footerDivider = NSBox(frame: NSRect(x: 42, y: 82, width: size.width - 84, height: 1))
        footerDivider.boxType = .separator
        view.addSubview(footerDivider)

        let footer = label("© 2026 Henrique Caiano · MIT License.", y: 46, size: 12, weight: .regular, color: .secondaryLabelColor)
        footer.alignment = .center
        view.addSubview(footer)

        return view
    }

    private func label(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.frame = NSRect(x: 42, y: y, width: 336, height: 22)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    private func addLinkRow(to parent: NSView, y: CGFloat, title: String, value: String, url: String) {
        let titleField = NSTextField(labelWithString: title)
        titleField.frame = NSRect(x: 16, y: y, width: 78, height: 22)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = .labelColor
        parent.addSubview(titleField)

        let button = NSButton(title: value, target: self, action: #selector(openLink(_:)))
        button.frame = NSRect(x: 96, y: y - 2, width: parent.bounds.width - 112, height: 26)
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = Brand.blue
        button.identifier = NSUserInterfaceItemIdentifier(url)
        parent.addSubview(button)
    }

    private func addDivider(to parent: NSView, y: CGFloat) {
        let divider = NSBox(frame: NSRect(x: 16, y: y, width: parent.bounds.width - 32, height: 1))
        divider.boxType = .separator
        parent.addSubview(divider)
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func appIcon() -> NSImage {
        if let icon = NSImage(named: "AppIcon") { return icon }
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
        return NSApplication.shared.applicationIconImage
    }

    private func versionLine() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }

    private func buildDateLine() -> String? {
        guard
            let url = Bundle.main.executableURL,
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let date = values.contentModificationDate
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Built \(formatter.string(from: date))"
    }
}
