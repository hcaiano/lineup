import AppKit

/// Persistent, non-activating status pill shown while Hyper Key cannot receive keyboard events.
/// It stays visible across Spaces and disappears as soon as HyperKeyController recovers.
///
/// Copied from standalone Cycler; the user-facing detail lines are retargeted to Lineup and one
/// case is new (standalone Cycler.app still running). Deliberately NOT an activation-policy
/// client — it is an ambient overlay, like the cycle HUD and the layout editor.
@MainActor
final class HyperKeyBlockedPill {
    static let shared = HyperKeyBlockedPill()

    private let panel: NSPanel
    private let messageLabel = NSTextField(labelWithString: "")
    private let width: CGFloat = 620
    private let height: CGFloat = 44
    private var generation = 0

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = buildContainer()
    }

    func show(message: String) {
        generation += 1
        messageLabel.attributedStringValue = Self.message(Self.displayDetail(for: message))
        position()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeIn)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        generation += 1
        let hiddenGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hiddenGeneration else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func position() {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: round(visible.midX - width / 2),
            y: round(visible.minY + 28))
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func buildContainer() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = Brand.hyperkeyAccent
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        messageLabel.cell?.usesSingleLineMode = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, messageLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            content.heightAnchor.constraint(equalToConstant: height),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = height / 2
            glass.tintColor = NSColor(white: 0, alpha: 0.48)
            glass.contentView = content
            // The pill's text is hard white, so its surface is pinned dark rather than left to
            // follow the desktop — the same reason the pre-26 fallback below forces .vibrantDark.
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.translatesAutoresizingMaskIntoConstraints = false
            return glass
        }

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = height / 2
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }

    private static func message(_ detail: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "Hyper Key unavailable",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        result.append(NSAttributedString(
            string: "  ·  \(detail)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            ]))
        return result
    }

    private static func displayDetail(for message: String) -> String {
        if message.contains("Secure Input") {
            return "Secure Input is active. Quit and reopen your password app."
        }
        if message.contains("Input Monitoring") {
            return "Allow Lineup in System Settings → Input Monitoring."
        }
        if message.contains("Raycast") {
            return "Raycast is using Caps Lock. Disable its Hyper Key or choose another trigger."
        }
        if message.contains("Cycler is running") {
            return "Quit the standalone Cycler app. Lineup does this now."
        }
        if message.contains("existing hidutil UserKeyMapping") {
            return "Caps Lock is already remapped by another app."
        }
        if message.contains("hidutil failed") {
            return "Couldn’t remap Caps Lock. Try toggling Hyper Key off and on."
        }
        if message.contains("CGEvent.tapCreate") {
            return "Couldn’t monitor the keyboard. Check Input Monitoring."
        }
        return "Open Lineup Settings → Hyperkey for details."
    }
}
