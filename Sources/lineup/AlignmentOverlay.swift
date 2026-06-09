import AppKit
import LineupCore

/// Full-screen, transparent overlay for setting the column dividers by eye: drag the
/// vertical lines onto the monitor's physical seams and hit Save. No config editing.
///
/// Coordinate note: the overlay window covers `screen.frame` (points). A divider's x is
/// stored in points-from-left while dragging; on save we convert to physical pixels with
/// `scale = pixelsWide / frame.width` so the saved config lands on the seam regardless of
/// HiDPI scaling.
final class AlignmentOverlayController {
    private var window: OverlayWindow?
    private var pendingView: OverlayView?
    private var previousApp: NSRunningApplication?
    private let screen: NSScreen
    private let pixelsWide: Int
    private let minColumnPixels: Double = 40
    private let onSave: (_ dividerPixels: [Double], _ halfPixels: Double) -> Void
    private let onClose: () -> Void

    /// - initialDividerPoints: starting line positions, in points from the screen's left.
    init(screen: NSScreen,
         pixelsWide: Int,
         initialDividerPoints: [CGFloat],
         onSave: @escaping (_ dividerPixels: [Double], _ halfPixels: Double) -> Void,
         onClose: @escaping () -> Void) {
        self.screen = screen
        self.pixelsWide = pixelsWide
        self.onSave = onSave
        self.onClose = onClose
        let view = OverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            pixelsWide: pixelsWide,
            initialDividers: initialDividerPoints)
        view.onSave = { [weak self] points in self?.commit(points) }
        view.onCancel = { [weak self] in self?.close() }
        self.pendingView = view
    }

    func show() {
        guard let view = pendingView else { return }
        previousApp = NSWorkspace.shared.frontmostApplication // restore focus on close
        let win = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.ignoresMouseEvents = false
        win.hidesOnDeactivate = false
        win.contentView = view
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
    }

    private func commit(_ points: [CGFloat]) {
        let w = screen.frame.width
        let scale = w > 0 ? CGFloat(pixelsWide) / w : 1
        // Clamp to the screen (points) -> pixels (rounded) -> clamp to pixel range -> sort.
        let pxs = points.map { Double((min(max($0, 0), w) * scale).rounded()) }
        let spaced = ColumnConfig.clampPixelDividers(pxs, pixelsWide: pixelsWide, minColumn: minColumnPixels)
        let halfPixels = Double(pixelsWide) / 2.0 // Hyper+[ ] splits at the physical center
        onSave(spaced, halfPixels)
        close()
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
        pendingView = nil
        // Return focus to whatever the user was using before the overlay grabbed it.
        if let prev = previousApp, prev != NSRunningApplication.current {
            if #available(macOS 14.0, *) {
                prev.activate()
            } else {
                prev.activate(options: [])
            }
        }
        previousApp = nil
        onClose()
    }
}

/// Borderless windows can't become key by default; an `.accessory` app needs this to
/// receive mouse drags and Esc/Return.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    var onSave: (([CGFloat]) -> Void)?
    var onCancel: (() -> Void)?

    private var dividers: [CGFloat]          // x positions in points (view space)
    private let pixelsWide: Int
    private var activeDivider: Int?
    private let hitThreshold: CGFloat = 22
    private let labelNames = ["left", "center", "right"]

    init(frame: NSRect, pixelsWide: Int, initialDividers: [CGFloat]) {
        self.pixelsWide = pixelsWide
        self.dividers = initialDividers
        super.init(frame: frame)
        addButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Buttons

    private func addButtons() {
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"          // Return
        save.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"    // Esc — robust window-wide key equivalent
        cancel.bezelStyle = .rounded

        let w: CGFloat = 110, h: CGFloat = 32, gap: CGFloat = 16
        let cx = bounds.midX, y: CGFloat = 56
        cancel.frame = NSRect(x: cx - w - gap / 2, y: y, width: w, height: h)
        save.frame = NSRect(x: cx + gap / 2, y: y, width: w, height: h)
        addSubview(cancel)
        addSubview(save)
    }

    @objc private func saveTapped() { onSave?(dividers) }
    @objc private func cancelTapped() { onCancel?() }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Faint dim so the lines read clearly; light enough that the physical seam shows.
        NSColor.black.withAlphaComponent(0.10).setFill()
        bounds.fill()

        let edges = [0] + dividers.sorted() + [bounds.width]

        // Column width labels, centered in each column.
        for i in 0..<(edges.count - 1) {
            let left = edges[i], right = edges[i + 1]
            let widthPx = Int(((right - left) / bounds.width) * CGFloat(pixelsWide))
            let name = labelLabel(index: i, count: edges.count - 1)
            drawCenteredLabel("\(name)\n\(widthPx) px",
                              centerX: (left + right) / 2, centerY: bounds.midY)
        }

        // Divider lines + handles.
        for x in dividers {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            path.lineWidth = 2
            NSColor.systemRed.setStroke()
            path.stroke()

            let r: CGFloat = 7
            let dot = NSBezierPath(ovalIn: NSRect(x: x - r, y: bounds.midY - r, width: 2 * r, height: 2 * r))
            NSColor.systemRed.setFill()
            dot.fill()
        }

        drawCenteredLabel("Drag the red lines onto the seams · Return = Save · Esc = Cancel",
                          centerX: bounds.midX, centerY: bounds.height - 60, large: true)
    }

    private func labelLabel(index: Int, count: Int) -> String {
        if count == 3 { return labelNames[index] }
        if index == 0 { return "left" }
        if index == count - 1 { return "right" }
        return "col \(index + 1)"
    }

    private func drawCenteredLabel(_ text: String, centerX: CGFloat, centerY: CGFloat, large: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: large ? 15 : 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(in: NSRect(x: centerX - size.width / 2, y: centerY - size.height / 2,
                          width: size.width, height: size.height))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var nearest: Int?
        var best = hitThreshold
        for (i, x) in dividers.enumerated() {
            let d = abs(x - p.x)
            if d < best { best = d; nearest = i }
        }
        activeDivider = nearest
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = activeDivider else { return }
        let p = convert(event.locationInWindow, from: nil)
        dividers[i] = min(max(p.x, 0), bounds.width)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activeDivider = nil
    }

    // MARK: Keyboard (robust cancel/save independent of which control is first responder)

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()              // Esc
        case 36, 76: onSave?(dividers)    // Return / keypad Enter
        default: super.keyDown(with: event)
        }
    }
}
