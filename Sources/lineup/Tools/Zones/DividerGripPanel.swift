import AppKit
import ZonesCore

/// The handle on the line between two zones, a painted copy of that line and, while the divider
/// locks onto a guide, a badge naming it. All three share the phase's alpha.
@MainActor
final class DividerGripPanel: NSPanel {
    override var canBecomeKey: Bool { phase == .pinned }
    private let grip: GripView
    private let line: NSWindow
    private let badge: NSWindow
    private let lineView: LineView
    private let badgeView: GuideBadgeView
    private var phase: DividerGrip.Phase?

    init(bindHeld: @escaping () -> Bool, activationKey: @escaping () -> UInt16?,
         isKeyDown: @escaping (UInt16) -> Bool,
         input: @escaping (DividerGrip.Input) -> Void) {
        grip = GripView(bindHeld: bindHeld, activationKey: activationKey, isKeyDown: isKeyDown, input: input)
        let lineView = LineView(), badgeView = GuideBadgeView()
        self.lineView = lineView; self.badgeView = badgeView
        line = Self.clickThroughWindow(lineView)
        badge = Self.clickThroughWindow(badgeView)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .floating; hidesOnDeactivate = false
        collectionBehavior = [.stationary]
        animationBehavior = .none
        contentView = grip
    }

    private static func clickThroughWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .floating; window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary]
        window.animationBehavior = .none
        window.contentView = view
        view.setAccessibilityElement(false)
        return window
    }

    /// `segment` is the painted line in screen coordinates; it moves with the handle.
    func place(_ rect: CGRect, axis: Axis, line segment: CGRect) {
        grip.axis = axis
        showGuide(nil)
        line.setFrame(segment, display: true)
        setFrame(rect, display: true)
        grip.needsDisplay = true
        grip.noteFocusRingMaskChanged()
        invalidateCursorRects(for: grip)
    }

    func move(to rect: CGRect) {
        line.setFrameOrigin(CGPoint(x: line.frame.minX + rect.minX - frame.minX, y: line.frame.minY + rect.minY - frame.minY))
        setFrame(rect, display: true)
        placeBadge()
    }

    func prepare(_ phase: DividerGrip.Phase,
                 increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        guard phase != self.phase || increaseContrast != grip.contrast else { return }
        self.phase = phase
        grip.phase = phase
        grip.contrast = increaseContrast; lineView.contrast = increaseContrast; badgeView.contrast = increaseContrast
        grip.needsDisplay = true; lineView.needsDisplay = true; badgeView.needsDisplay = true
        grip.noteFocusRingMaskChanged()
        ignoresMouseEvents = phase == .revealed
        alphaValue = phase == .revealed ? 0.8 : 1
        line.alphaValue = alphaValue
        badge.alphaValue = alphaValue
        invalidateCursorRects(for: grip)
    }

    func apply(_ phase: DividerGrip.Phase) {
        if case .pressed = phase, self.phase == .armed { grip.latchActivationKey() }
        prepare(phase)
        orderFront(nil)
        line.order(.below, relativeTo: windowNumber)
        // Divider previews are ordered below the line after this, so a visible badge must be
        // raised again or they would cover it.
        if grip.guide != nil { badge.order(.above, relativeTo: windowNumber) }
    }

    func pin() {
        grip.checkActivationKey()
        makeKey()
        makeFirstResponder(grip)
        NSAccessibility.post(element: grip, notification: .focusedUIElementChanged)
    }

    func hide() {
        phase = nil
        grip.heldActivationKey = nil
        showGuide(nil)
        // `NSCursor.current` is this app's cursor, not necessarily the one on screen, so the arrow
        // is restored only when the handle being hidden is visible under the pointer.
        if isVisible, frame.contains(NSEvent.mouseLocation), NSCursor.current == grip.resizeCursor { NSCursor.arrow.set() }
        orderOut(nil)
        line.orderOut(nil)
    }

    var lineWindow: NSWindow { line }
    var guideWindow: NSWindow { badge }
    var resizeCursor: NSCursor { grip.resizeCursor }

    func showGuide(_ label: String?) {
        grip.guide = label
        grip.needsDisplay = true
        guard let label else { badge.orderOut(nil); return }
        badgeView.label = label
        placeBadge()
        if isVisible, !badge.isVisible { badge.order(.above, relativeTo: windowNumber) }
    }

    private func placeBadge() {
        guard let label = grip.guide else { return }
        let size = GuideBadgeView.size(for: label), gap: CGFloat = 8
        let display = NSScreen.screens.first { $0.frame.intersects(frame) }?.frame ?? frame.insetBy(dx: -200, dy: -200)
        var capsule: CGRect
        if grip.axis == .vertical {
            capsule = CGRect(x: frame.maxX + gap, y: frame.midY - size.height / 2, width: size.width, height: size.height)
            if capsule.maxX > display.maxX { capsule.origin.x = frame.minX - gap - size.width }
        } else {
            capsule = CGRect(x: frame.midX - size.width / 2, y: frame.maxY + gap, width: size.width, height: size.height)
            if capsule.maxY > display.maxY { capsule.origin.y = frame.minY - gap - size.height }
        }
        capsule.origin.x = min(max(capsule.minX, display.minX), display.maxX - capsule.width)
        capsule.origin.y = min(max(capsule.minY, display.minY), display.maxY - capsule.height)
        badge.setFrame(capsule.insetBy(dx: -GuideBadgeView.shadowMargin, dy: -GuideBadgeView.shadowMargin), display: true)
    }

    func checkActivationKey() { grip.checkActivationKey() }

    override func sendEvent(_ event: NSEvent) {
        if phase == .pinned, event.type == .keyUp { grip.keyUp(with: event); return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        grip.input(.resignedKey)
    }
}

@MainActor
private final class GripView: NSView {
    var axis: Axis = .vertical
    var contrast = false
    var guide: String?
    var phase: DividerGrip.Phase = .revealed
    let bindHeld: () -> Bool
    let activationKey: () -> UInt16?
    let isKeyDown: (UInt16) -> Bool
    var heldActivationKey: UInt16?
    let input: (DividerGrip.Input) -> Void
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(bindHeld: @escaping () -> Bool, activationKey: @escaping () -> UInt16?,
         isKeyDown: @escaping (UInt16) -> Bool,
         input: @escaping (DividerGrip.Input) -> Void) {
        self.bindHeld = bindHeld; self.activationKey = activationKey; self.isKeyDown = isKeyDown; self.input = input
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Resize the zones beside this line")
        toolTip = "Drag to resize zones"
        setAccessibilityHelp("Drag to resize. Or click it, use the arrow keys, and press Return. Escape cancels.")
    }
    required init?(coder: NSCoder) { nil }

    var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) { return axis == .vertical ? .columnResize : .rowResize }
        return axis == .vertical ? .resizeLeftRight : .resizeUpDown
    }

    /// Stays inside the 28 by 48 point hit rect.
    private var knob: CGRect {
        let long: CGFloat = phase == .revealed ? 36 : 40, short: CGFloat = phase == .revealed ? 6 : 9
        return axis == .vertical
            ? CGRect(x: bounds.midX - short / 2, y: bounds.midY - long / 2, width: short, height: long)
            : CGRect(x: bounds.midX - long / 2, y: bounds.midY - short / 2, width: long, height: short)
    }

    private var rim: NSBezierPath {
        let rect = knob.insetBy(dx: -1, dy: -1), radius = min(rect.width, rect.height) / 2
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        let knob = knob, radius = min(knob.width, knob.height) / 2
        let body: CGFloat = phase == .revealed ? 0.55 : guide == nil ? 0.78 : 1
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.textBackgroundColor.withAlphaComponent(contrast ? 0.9 : 0.6).setFill()
        rim.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(contrast ? max(body, 0.9) : body).setFill()
        NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius).fill()
    }

    override var focusRingMaskBounds: NSRect { knob.insetBy(dx: -1, dy: -1) }
    override func drawFocusRingMask() { rim.fill() }

    override func resetCursorRects() {
        if phase != .revealed { addCursorRect(bounds, cursor: resizeCursor) }
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    override func mouseDown(with event: NSEvent) { input(.press(screenPoint(event), bindHeld: bindHeld())) }
    override func mouseDragged(with event: NSEvent) { input(.drag(screenPoint(event), bindHeld: bindHeld())) }
    override func mouseUp(with event: NSEvent) { input(.release(bindHeld: bindHeld())) }

    func latchActivationKey() { heldActivationKey = activationKey().flatMap { isKeyDown($0) ? $0 : nil } }

    func checkActivationKey() {
        if let code = heldActivationKey, !isKeyDown(code) { heldActivationKey = nil }
    }

    override func keyUp(with event: NSEvent) {
        if heldActivationKey == event.keyCode { heldActivationKey = nil }
        else { super.keyUp(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { input(.escape); return }
        if heldActivationKey == event.keyCode { return }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 36, 76: input(.confirm)
        case 123 where axis == .vertical, 125 where axis == .horizontal: input(.nudge(-step))
        case 124 where axis == .vertical, 126 where axis == .horizontal: input(.nudge(step))
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { input(.nudge(10)); return true }
    override func accessibilityPerformDecrement() -> Bool { input(.nudge(-10)); return true }
}

@MainActor
private final class LineView: NSView {
    var contrast = false

    override func draw(_ dirtyRect: NSRect) {
        let vertical = bounds.height >= bounds.width
        let core: CGFloat = contrast ? 3 : 2
        let rule = backingAlignedRect(vertical
            ? CGRect(x: bounds.midX - core / 2, y: bounds.minY + 1, width: core, height: max(0, bounds.height - 2))
            : CGRect(x: bounds.minX + 1, y: bounds.midY - core / 2, width: max(0, bounds.width - 2), height: core),
            options: .alignAllEdgesNearest)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        shadow.set()
        (contrast ? NSColor.labelColor : .systemGray).setFill()
        NSBezierPath(roundedRect: rule, xRadius: core / 2, yRadius: core / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class GuideBadgeView: NSView {
    static let shadowMargin: CGFloat = 4
    var contrast = false
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    var label = "" { didSet { needsDisplay = true } }

    static func size(for label: String) -> CGSize {
        CGSize(width: max(28, ceil(label.size(withAttributes: [.font: font]).width) + 14), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        let path = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        NSColor.labelColor.withAlphaComponent(contrast ? 1 : 0.85).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.textBackgroundColor]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: capsule.midX - size.width / 2, y: capsule.midY - size.height / 2), withAttributes: attributes)
    }
}
