import AppKit
import HyperkeyCore

@MainActor
final class HyperKeyBlockedPill {
    static let shared = HyperKeyBlockedPill()

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private enum Episode: Equatable {
        case ready
        case notified(UUID)
    }
    private var episode = Episode.ready
    private var animationGeneration = UUID()
    private var cancelAutoDismissal: (() -> Void)?
    private let scheduleDismissal: @MainActor (TimeInterval, @escaping () -> Void) -> () -> Void

    init(scheduleDismissal: @escaping @MainActor (TimeInterval, @escaping () -> Void) -> () -> Void = HyperKeyBlockedPill.schedule) {
        self.scheduleDismissal = scheduleDismissal
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
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

    func show(message: String, diagnostic: SecureInputDiagnostic? = nil) {
        titleLabel.stringValue = diagnostic == nil ? "Hyperkey unavailable" : "Hyperkey paused by Secure Input"
        hintLabel.stringValue = diagnostic?.notice ?? Self.displayDetail(for: message)
        guard episode == .ready else {
            if panel.isVisible { position() }
            return
        }
        let id = UUID()
        episode = .notified(id)
        animationGeneration = UUID()
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeIn)
            panel.animator().alphaValue = 1
        }
        cancelAutoDismissal = scheduleDismissal(4) { [weak self] in
            guard let self, self.episode == .notified(id) else { return }
            self.cancelAutoDismissal = nil
            self.dismiss()
        }
    }

    func endEpisode() {
        episode = .ready
        cancelAutoDismissal?()
        cancelAutoDismissal = nil
        dismiss()
    }

    func showAfterAttempt(message: String, diagnostic: SecureInputDiagnostic? = nil) {
        if cancelAutoDismissal == nil { endEpisode() }
        show(message: message, diagnostic: diagnostic)
    }

    private func dismiss() {
        animationGeneration = UUID()
        let generation = animationGeneration
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private static func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    static func frame(in visible: NSRect, height: CGFloat) -> NSRect {
        let inset = min(16, max(0, min(visible.width, visible.height) / 4))
        let width = min(340, max(0, visible.width - inset * 2))
        let height = min(height, max(0, visible.height - inset * 2))
        return NSRect(x: visible.maxX - inset - width, y: visible.maxY - inset - height,
                      width: width, height: height)
    }

    private func position() {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let width = Self.frame(in: visible, height: 0).width
        let textWidth = max(1, width - 59)
        for label in [titleLabel, hintLabel] { label.preferredMaxLayoutWidth = textWidth }
        func height(of label: NSTextField) -> CGFloat {
            ceil(label.attributedStringValue.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let height = height(of: titleLabel) + height(of: hintLabel) + 28
        panel.setFrame(Self.frame(in: visible, height: height), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func buildContainer() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemOrange
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, hintLabel] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.usesSingleLineMode = false
            label.cell?.isScrollable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, titleLabel, hintLabel] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            hintLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let container: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = content
            container = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 16
            blur.layer?.masksToBounds = true
            blur.addSubview(content)
            container = blur
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private static func displayDetail(for message: String) -> String {
        if message.contains("Input Monitoring") {
            return "Allow Lineup in System Settings → Input Monitoring."
        }
        if message.contains("Raycast") {
            return "Raycast is using Caps Lock. Turn off its Hyper Key."
        }
        if message.contains("Cycler is running") {
            return "Quit the standalone Cycler app. Lineup does this now."
        }
        if message.contains("already remaps") || message.contains("conflicts with Hyperkey") {
            return "Caps Lock is already remapped by another app."
        }
        if message.contains("could not be recovered") || message.contains("refused to apply") || message.contains("did not keep") {
            return "Couldn’t remap Caps Lock. Open Hyperkey Settings and retry."
        }
        if message.contains("CGEvent.tapCreate") {
            return "Couldn’t monitor the keyboard. Check Input Monitoring."
        }
        return "Open Lineup Settings → Hyperkey for details."
    }
}
