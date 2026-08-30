import AppKit

/// The Tiles overlay is deliberately separate from Cycler's window list HUD. It is a
/// non-activating, click-through panel: it reports workspace and stack state without changing the
/// focused application.
@MainActor
final class TilesHUD {
    static let shared = TilesHUD()

    private enum Mode {
        case workspace
        case stack
        case confirmation
        case failure
    }

    private let panel: TilesHUDPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let indicatorStack = NSStackView()
    private let rowStack = NSStackView()
    private var rowViews: [TilesHUDRow] = []
    private var contentViewForMeasurement: NSView!
    private var dismissWorkItem: DispatchWorkItem?
    private var generation = 0
    private var mode: Mode = .workspace

    private let width: CGFloat = 360
    private let cornerRadius: CGFloat = 14
    private let maxVisibleRows = 7

    private init() {
        panel = TilesHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .floating
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

    func showWorkspace(number: Int) {
        let workspace = min(max(number, 1), 4)
        generation += 1
        dismissWorkItem?.cancel()
        mode = .workspace
        iconView.image = NSImage(systemSymbolName: "square.grid.3x3.fill",
                                 accessibilityDescription: "Tiles")
        iconView.contentTintColor = Brand.blue
        titleLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.preferredMaxLayoutWidth = 0
        titleLabel.stringValue = "\(workspace)"
        titleLabel.textColor = .white
        subtitleLabel.stringValue = "Workspace"
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        subtitleLabel.isHidden = false
        setIndicators(selected: workspace)
        clearRows()
        present()
        announce("Workspace \(workspace)")
    }

    func showStack(appIcon: NSImage?, titles: [String], selectedIndex: Int) {
        guard !titles.isEmpty else { return }
        generation += 1
        dismissWorkItem?.cancel()
        mode = .stack
        iconView.image = appIcon ?? NSImage(systemSymbolName: "square.stack.3d.up",
                                            accessibilityDescription: "Window stack")
        iconView.contentTintColor = Brand.blue
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.preferredMaxLayoutWidth = 0
        let selectedInStack = min(max(selectedIndex, 0), titles.count - 1)
        let visibleStart = titles.count <= maxVisibleRows
            ? 0
            : min(max(0, selectedInStack - maxVisibleRows / 2), titles.count - maxVisibleRows)
        let visibleEnd = min(titles.count, visibleStart + maxVisibleRows)
        let visibleTitles = Array(titles[visibleStart..<visibleEnd])
        titleLabel.stringValue = "Focused tile"
        titleLabel.textColor = .white
        subtitleLabel.stringValue = "Window \(selectedInStack + 1) of \(titles.count)"
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        subtitleLabel.isHidden = false
        indicatorStack.isHidden = true
        rebuildRows(visibleTitles.count)
        for (idx, row) in rowViews.enumerated() {
            row.update(title: visibleTitles[idx].isEmpty ? "Untitled" : visibleTitles[idx],
                       selected: idx == selectedInStack - visibleStart)
        }
        present()
        announce("Window \(selectedInStack + 1) of \(titles.count)")
    }

    func showFailure(_ message: String) {
        guard !message.isEmpty else { return }
        generation += 1
        dismissWorkItem?.cancel()
        mode = .failure
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                 accessibilityDescription: "Warning")
        iconView.contentTintColor = .systemOrange
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = 300
        titleLabel.stringValue = message
        titleLabel.textColor = .systemOrange
        subtitleLabel.stringValue = "Tiles could not complete this action."
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        subtitleLabel.isHidden = false
        indicatorStack.isHidden = true
        clearRows()
        present(duration: 2.5)
        announce(message)
    }

    func showConfirmation(_ message: String) {
        guard !message.isEmpty else { return }
        generation += 1
        dismissWorkItem?.cancel()
        mode = .confirmation
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                 accessibilityDescription: "Complete")
        iconView.contentTintColor = .systemGreen
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.preferredMaxLayoutWidth = 0
        titleLabel.stringValue = message
        titleLabel.textColor = .white
        subtitleLabel.stringValue = ""
        subtitleLabel.isHidden = true
        indicatorStack.isHidden = true
        clearRows()
        present()
        announce(message)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        generation += 1
        guard panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func setIndicators(selected: Int) {
        indicatorStack.isHidden = false
        indicatorStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for workspace in 1...4 {
            let label = NSTextField(labelWithString: workspace == selected ? "●" : "○")
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = workspace == selected
                ? Brand.blue
                : NSColor.white.withAlphaComponent(0.45)
            label.alignment = .center
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setAccessibilityLabel("Workspace \(workspace)", value: workspace == selected ? "Selected" : "Not selected")
            indicatorStack.addArrangedSubview(label)
        }
    }

    private func rebuildRows(_ count: Int) {
        clearRows()
        rowViews = (0..<count).map { _ in TilesHUDRow() }
        rowViews.forEach { rowStack.addArrangedSubview($0) }
        rowViews.forEach { $0.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
    }

    private func clearRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
    }

    private func present(duration: TimeInterval = 1.0) {
        contentViewForMeasurement.layoutSubtreeIfNeeded()
        contentViewForMeasurement.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: contentViewForMeasurement.fittingSize.height)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(x: round(visible.midX - size.width / 2),
                             y: round(visible.midY - size.height / 2))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeIn)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hide() {
        let expected = generation
        dismissWorkItem = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expected else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app,
                             notification: .announcementRequested,
                             userInfo: [.announcement: text])
    }

    private func buildContainer() -> NSView {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        indicatorStack.orientation = .horizontal
        indicatorStack.spacing = 5
        indicatorStack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [iconView, titleLabel, NSView(), indicatorStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 1
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [header, subtitleLabel, rowStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        contentViewForMeasurement = content

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor(white: 0, alpha: 0.42)
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.translatesAutoresizingMaskIntoConstraints = false
            glass.contentView = content
            return glass
        }

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.maskImage = Self.roundedMask(radius: cornerRadius)
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

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let dimension = radius * 2 + 1
        let image = NSImage(size: NSSize(width: dimension, height: dimension), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class TilesHUDRow: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(title: String, selected: Bool) {
        label.stringValue = title
        label.textColor = selected ? .white : NSColor.white.withAlphaComponent(0.72)
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        layer?.backgroundColor = selected ? Brand.blue.withAlphaComponent(0.82).cgColor : nil
    }
}

private final class TilesHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSTextField {
    func setAccessibilityLabel(_ label: String, value: String) {
        setAccessibilityElement(true)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
    }
}
