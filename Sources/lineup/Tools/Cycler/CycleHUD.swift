import AppKit

/// A small, non-activating window switcher shown while cycling an app's windows: the app, plus the
/// list of its windows with the current one highlighted, so you can see where the next press lands.
/// It never becomes key/main, so it cannot steal focus from the app being cycled.
@MainActor
final class CycleHUD {
    static let shared = CycleHUD()

    struct WindowItem {
        var title: String
        var context: String?
    }

    struct AppGroupItem {
        var name: String
        var icon: NSImage?
        var isRunning: Bool
        var isSelected: Bool
    }

    private enum Mode {
        case windows
        case appGroup
    }

    private let panel: HUDPanel
    private let iconView = NSImageView()
    private let appLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let rowStack = NSStackView()
    private var rowViews: [HUDRow] = []
    private var measureView: NSView!     // the padded content; drives the panel's fitting size
    private var dismissWorkItem: DispatchWorkItem?
    private var generation = 0
    private var shownCount = 0
    private var shownMode: Mode?

    private let corner: CGFloat = 14
    private let width: CGFloat = 384      // fixed: titles truncate, panel never resizes while cycling
    private let maxVisibleRows = 7

    private init() {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
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

    /// Show the app's windows with `selectedIndex` highlighted. No-op for fewer than two windows.
    func show(appIcon: NSImage?, appName: String, windows: [WindowItem], selectedIndex: Int) {
        guard windows.count > 1 else { return }

        generation += 1
        dismissWorkItem?.cancel()

        iconView.image = appIcon
        iconView.contentTintColor = nil
        appLabel.stringValue = appName
        countLabel.stringValue = "\(selectedIndex + 1) of \(windows.count)"

        // Rebuild rows only when the window set changes; otherwise just move the highlight so the
        // panel never resizes or flickers mid-cycle.
        let window = visibleWindow(count: windows.count, selected: selectedIndex)
        let slice = Array(windows[window])
        if slice.count != shownCount || shownMode != .windows { rebuildRows(slice.count, mode: .windows) }
        shownCount = slice.count
        for (offset, row) in rowViews.enumerated() {
            let absolute = window.lowerBound + offset
            row.update(
                title: slice[offset].title,
                selected: absolute == selectedIndex,
                context: slice[offset].context)
        }

        present()
    }

    /// Show a multi-app shortcut's configured order, with the chosen app highlighted.
    func showAppGroup(apps: [AppGroupItem], selectedIndex: Int) {
        guard apps.count > 1, apps.indices.contains(selectedIndex) else { return }

        generation += 1
        dismissWorkItem?.cancel()

        iconView.image = Self.groupIcon()
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        appLabel.stringValue = "App Group"
        countLabel.stringValue = "\(apps.count) apps"

        let window = visibleWindow(count: apps.count, selected: selectedIndex)
        let slice = Array(apps[window])
        if slice.count != shownCount || shownMode != .appGroup { rebuildRows(slice.count, mode: .appGroup) }
        shownCount = slice.count
        for (offset, row) in rowViews.enumerated() {
            row.update(
                title: slice[offset].name,
                selected: slice[offset].isSelected,
                icon: slice[offset].icon,
                dimmed: !slice[offset].isRunning && !slice[offset].isSelected,
                reserveIcon: true)
        }

        present()
    }

    /// Tear the HUD down right now, cancelling the pending auto-dismiss.
    ///
    /// Added for Lineup 2.0: `CycleHUD` is a singleton that outlives the tool, so `CyclerTool.stop()`
    /// has to be able to take the panel off screen immediately. Bumping `generation` also makes any
    /// fade-out already in flight a no-op, so a later `show()` can't be undone by a stale completion.
    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        generation += 1
        guard panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func present() {
        if let content = measureView {
            content.layoutSubtreeIfNeeded()
            let size = NSSize(width: width, height: content.fittingSize.height)
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? .zero
            let origin = NSPoint(x: round(visible.midX - size.width / 2),
                                 y: round(visible.midY - size.height / 2))
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HUDMotion.duration(HUDMotion.fadeIn)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func hide() {
        let gen = generation
        dismissWorkItem = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HUDMotion.duration(HUDMotion.fadeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { // AppKit animation completions arrive on the main thread
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func rebuildRows(_ count: Int, mode: Mode) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = (0..<count).map { _ in HUDRow() }
        rowViews.forEach { rowStack.addArrangedSubview($0) }
        rowViews.forEach { $0.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true }
        shownMode = mode
    }

    private func visibleWindow(count: Int, selected: Int) -> Range<Int> {
        guard count > maxVisibleRows else { return 0..<count }
        var start = max(0, selected - maxVisibleRows / 2)
        start = min(start, count - maxVisibleRows)
        return start..<(start + maxVisibleRows)
    }

    private func buildContainer() -> NSView {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        appLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        appLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        appLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let header = NSStackView(views: [iconView, appLabel, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 1
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [header, separator, rowStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 9
        column.setCustomSpacing(8, after: separator)
        column.translatesAutoresizingMaskIntoConstraints = false

        // `content` is the padded surface we measure for the panel's fitting size; it lives inside
        // whichever glass/blur container we choose below.
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            rowStack.widthAnchor.constraint(equalTo: column.widthAnchor),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        measureView = content

        // macOS 26+: real Liquid Glass, which adapts to whatever's behind it. A subtle dark tint
        // keeps the white text legible even over bright/white backgrounds.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = corner
            glass.tintColor = NSColor(white: 0.0, alpha: 0.42)
            glass.contentView = content
            // Every label in this HUD is hard white, so the surface under them must be dark
            // whatever the user's Mac is set to. Glass follows the effective appearance unless it
            // is pinned, and on a light desktop the panel came up pale with white text on it —
            // the pre-26 fallback below has always forced .vibrantDark for exactly this reason.
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.translatesAutoresizingMaskIntoConstraints = false
            return glass
        }

        // Fallback (< macOS 26): vibrancy forced to a dark appearance so it stays a readable dark
        // HUD on any background, rounded via a mask image.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .vibrantDark)
        blur.maskImage = Self.roundedMask(radius: corner)
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
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private static func groupIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

/// One row in the switcher. Reused across presses; only its content and selection change, so the
/// panel layout stays stable (no resize, no text jump).
private final class HUDRow: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!
    private var iconSpacing: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 0)
        iconSpacing = label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            iconWidth,
            iconSpacing,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(
        title: String,
        selected: Bool,
        context: String? = nil,
        icon: NSImage? = nil,
        dimmed: Bool = false,
        reserveIcon: Bool = false
    ) {
        let hasIcon = icon != nil
        iconView.image = icon
        iconView.isHidden = !hasIcon
        iconView.alphaValue = selected ? 1 : (dimmed ? 0.38 : 0.78)
        iconWidth.constant = (hasIcon || reserveIcon) ? 18 : 0
        iconSpacing.constant = (hasIcon || reserveIcon) ? 8 : 0
        label.attributedStringValue = Self.titleString(
            title: title.isEmpty ? "Untitled" : title,
            context: context,
            selected: selected,
            dimmed: dimmed)
        // A soft white wash for the selection — subtle, not a loud brand pill.
        layer?.backgroundColor = selected
            ? NSColor.white.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }

    private static func titleString(title: String, context: String?, selected: Bool, dimmed: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleColor = selected ? NSColor.white : NSColor.white.withAlphaComponent(dimmed ? 0.42 : 0.7)
        if let context = context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            result.append(NSAttributedString(
                string: context,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: selected ? NSColor.white : NSColor.white.withAlphaComponent(0.84),
                ]))
            result.append(NSAttributedString(
                string: " · ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(selected ? 0.58 : 0.44),
                ]))
        }
        result.append(NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                .foregroundColor: titleColor,
            ]))
        return result
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
