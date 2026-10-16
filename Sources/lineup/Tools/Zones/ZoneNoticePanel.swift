import AppKit
import ZonesCore

/// A brief, click-through note near a coordinated move that did not apply. It never takes focus,
/// so VoiceOver hears it as an announcement. Same tokens as `HyperKeyBlockedPill`.
@MainActor
final class ZoneNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var dismissal: Timer?
    private var generation = UUID()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = buildContainer()
    }

    func show(title: String, detail: String, near anchor: CGPoint, visible: CGRect) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        let textWidth: CGFloat = 300 - 59
        func height(of label: NSTextField) -> CGFloat {
            label.preferredMaxLayoutWidth = textWidth
            return ceil(label.attributedStringValue.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let size = CGSize(width: 300, height: height(of: titleLabel) + height(of: detailLabel) + 28)
        setFrame(ZoneNotice.frame(size: size, anchor: anchor, visible: visible), display: true)
        contentView?.layoutSubtreeIfNeeded()
        generation = UUID()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeIn)
            animator().alphaValue = 1
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(title). \(detail)", .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        dismissal?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissal = timer
    }

    func dismiss() {
        dismissal?.invalidate(); dismissal = nil
        guard isVisible else { return }
        generation = UUID()
        let current = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.orderOut(nil)
            }
        }
    }

    private func buildContainer() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        icon.contentTintColor = .systemOrange
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.usesSingleLineMode = false
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, titleLabel, detailLabel] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
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
}
