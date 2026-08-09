import AppKit
import Foundation

/// The facts both Abouts show. One producer, so the AppKit window and the SwiftUI Settings pane
/// cannot drift apart the way they had: after 2.0 became a private build this window still
/// carried an open-source licence line and a source-repository link, and the pane did not.
enum AboutFacts {
    /// Nil when the executable can't be dated (nothing to show is better than a wrong date).
    static func buildDateLine() -> String? {
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

    /// No licence clause: Lineup 2.0 is proprietary. Kept byte-identical to the Settings pane's.
    static let copyright = "© 2026 Henrique Caiano. All rights reserved."
}

/// A layer-backed view whose colours FOLLOW the effective appearance.
///
/// `NSColor.cgColor` resolves against whatever appearance happens to be current at that moment, so
/// assigning `layer.backgroundColor` once freezes the colour at creation time: an About window
/// left open across a Dark Mode switch (or the automatic sunset one) kept its light card and its
/// light border on a dark window. Resolving in `updateLayer`, under this view's own appearance,
/// is what makes the switch land.
private final class AppearanceLayerView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The menu bar's About window. Shows exactly what Settings › About shows — brand mark, version,
/// build date, the product site — because a user can reach both and they must not disagree.
///
/// No source-repository link and no open-source licence line: this branch is private.
@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private static let shared = AboutWindowController()

    /// The size the layout below is designed at. Shrunk from 430 when the repository row and the
    /// licence footer came out.
    static let naturalSize = NSSize(width: 420, height: 344)

    private var window: NSWindow?

    /// This window needs real app focus like Settings, Welcome and What's New do, so it takes the
    /// same ref-counted `.regular` activation. Without it, About opened from the menu bar on an
    /// agent-only app came up behind whatever was frontmost.
    private static let activationReason = "about"

    static func show() {
        shared.showWindow()
    }

    /// The About content as an embeddable view (Settings hosts it in an About tab).
    /// Pass `naturalSize`; the caller centers it in its container.
    static func makeEmbeddedContent(size: NSSize) -> NSView {
        shared.makeContent(size: size)
    }

    private func showWindow() {
        if let window {
            // Retain is a set insert, so re-showing an open window cannot unbalance the count.
            ActivationCoordinator.shared.retain(Self.activationReason)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let size = Self.naturalSize
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

        ActivationCoordinator.shared.retain(Self.activationReason)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        ActivationCoordinator.shared.release(Self.activationReason)
    }

    private func makeContent(size: NSSize) -> NSView {
        let view = AppearanceLayerView(frame: NSRect(origin: .zero, size: size))
        view.fill = .windowBackgroundColor

        let icon = NSImageView(frame: NSRect(x: size.width / 2 - 42, y: size.height - 108, width: 84, height: 84))
        icon.image = appIcon()
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)

        // Taller box than the 12pt rows: a 24pt line needs ~34pt or the "p" descender clips.
        let title = label("Lineup", y: size.height - 154, size: 24, weight: .semibold, color: .labelColor, height: 34)
        title.alignment = .center
        view.addSubview(title)

        let version = label(versionLine(), y: size.height - 176, size: 12, weight: .regular, color: .secondaryLabelColor)
        version.alignment = .center
        view.addSubview(version)

        if let built = AboutFacts.buildDateLine() {
            let build = label(built, y: size.height - 198, size: 12, weight: .regular, color: .secondaryLabelColor)
            build.alignment = .center
            view.addSubview(build)
        }

        // One row now the repository link is gone; the card is sized to it, not left half empty.
        let card = AppearanceLayerView(frame: NSRect(x: 42, y: size.height - 262, width: size.width - 84, height: 48))
        card.fill = .controlBackgroundColor
        card.border = .separatorColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        view.addSubview(card)

        addLinkRow(to: card, y: 13, title: "Website", value: "lineup.caiano.com", url: "https://lineup.caiano.com")

        let footerDivider = NSBox(frame: NSRect(x: 42, y: size.height - 286, width: size.width - 84, height: 1))
        footerDivider.boxType = .separator
        view.addSubview(footerDivider)

        let footer = label(AboutFacts.copyright, y: size.height - 320, size: 12, weight: .regular, color: .secondaryLabelColor)
        footer.alignment = .center
        view.addSubview(footer)

        return view
    }

    private func label(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, height: CGFloat = 22) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.frame = NSRect(x: 42, y: y, width: 336, height: height)
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
}
