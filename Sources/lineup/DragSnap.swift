import AppKit
import LineupCore

/// Shift-drag snapping: while the user drags a window with SHIFT held, highlight the
/// zone under the cursor; on mouse-release, snap the dragged window into it.
///
/// A zone's top/bottom 10% edge band targets that HALF of the zone instead, so a column
/// can hold two apps stacked without editing the layout. The highlight always previews
/// exactly what release will do; lingering in a zone fades in a one-line hint that
/// teaches the half-snap.
///
/// Uses a global mouse monitor (mouse events need no extra permission beyond the
/// Accessibility grant the app already requires to move windows). Reads SHIFT from the
/// mouse event's own modifier flags — no keyboard monitor.
final class DragSnapController {
    private var monitor: Any?
    private let configProvider: () -> LineupConfig

    private var captured: AXUIElement?   // the window grabbed at drag start
    private var armed = false            // SHIFT held + a window captured
    private var highlight: HighlightWindow?
    private var lastTargetRect: CGRect?  // what release will snap to (zone or half)

    // Linger hint: if the cursor stays in the same zone a moment without targeting a half,
    // teach the feature. A timer is required — a stationary cursor emits no drag events.
    private var lingerZone: CGRect?
    private var lingerTimer: Timer?
    private var hintShown = false

    init(configProvider: @escaping () -> LineupConfig) {
        self.configProvider = configProvider
    }

    var isEnabled: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        reset()
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset() // clear stale state; capture happens on the first SHIFT-drag
        case .leftMouseDragged:
            if event.modifierFlags.contains(.shift) {
                if captured == nil { captured = WindowMover.window(atCocoaPoint: NSEvent.mouseLocation) }
                if captured != nil {
                    armed = true
                    updateHighlight()
                }
            } else {
                // SHIFT released mid-drag: disarm and hide (re-arms if SHIFT returns).
                armed = false
                hideHighlight()
            }
        case .leftMouseUp:
            if armed, let win = captured, let rect = lastTargetRect {
                WindowMover.snap(win, toCocoaRect: rect)
            }
            reset()
        default:
            break
        }
    }

    // MARK: - Highlight

    private func currentZoneRect() -> CGRect? {
        let p = NSEvent.mouseLocation
        guard let screen = screenContaining(p) else { return nil }
        let info = ScreenIdentity.info(for: screen)
        let root = configProvider().layout(forKey: info.key)
        // The leaf zone whose rect contains the cursor; fall back to the nearest by center.
        let zones = Layout.zones(root, frame: screen.frame, visibleFrame: screen.visibleFrame, pixelsWide: info.pixelsWide)
        if let hit = zones.first(where: { $0.contains(p) }) { return hit }
        return zones.min(by: { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) })
    }

    private func updateHighlight() {
        guard let zone = currentZoneRect() else { hideHighlight(); return }
        let target = DragTarget.rect(zone: zone, cursor: NSEvent.mouseLocation)
        trackLinger(zone: zone, targetingHalf: target != zone)
        if target == lastTargetRect, highlight != nil { return } // unchanged — skip redraw
        lastTargetRect = target
        if highlight == nil { highlight = HighlightWindow() }
        highlight?.show(at: target, hint: hintShown && target == zone ? HighlightWindow.halfHint : nil)
    }

    /// Arm/refresh the linger timer per zone; once it fires, the hint rides along with the
    /// highlight until the user targets a half or leaves the zone.
    private func trackLinger(zone: CGRect, targetingHalf: Bool) {
        if targetingHalf { clearLinger(); return }
        if zone != lingerZone {
            lingerZone = zone
            hintShown = false
            lingerTimer?.invalidate()
            lingerTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                guard let self, self.armed, self.lingerZone == zone else { return }
                self.hintShown = true
                if let target = self.lastTargetRect, target == zone {
                    self.highlight?.show(at: target, hint: HighlightWindow.halfHint)
                }
            }
        }
    }

    private func clearLinger() {
        lingerZone = nil
        hintShown = false
        lingerTimer?.invalidate()
        lingerTimer = nil
    }

    private func hideHighlight() {
        highlight?.orderOut(nil)
        lastTargetRect = nil
        clearLinger()
    }

    private func reset() {
        captured = nil
        armed = false
        highlight?.orderOut(nil)
        highlight = nil
        lastTargetRect = nil
        clearLinger()
    }

    private func screenContaining(_ p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}

/// Translucent, click-through block highlight. The window frame IS the highlighted target;
/// an optional one-line hint teaches the half-snap when the user lingers.
private final class HighlightWindow: NSWindow {
    static let halfHint = "Drag near the top or bottom edge to fill half"

    private let hintLabel = NSTextField(labelWithString: HighlightWindow.halfHint)

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true   // never interfere with the drag
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = Brand.blue.withAlphaComponent(0.22).cgColor
        v.layer?.borderColor = Brand.blue.withAlphaComponent(0.95).cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 14

        hintLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        hintLabel.wantsLayer = true
        hintLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hintLabel.layer?.cornerRadius = 8
        hintLabel.isHidden = true
        v.addSubview(hintLabel)
        contentView = v
    }

    func show(at rect: CGRect, hint: String?) {
        setFrame(rect, display: true)
        if let hint {
            hintLabel.stringValue = hint
            hintLabel.sizeToFit()
            let w = hintLabel.frame.width + 20, h = hintLabel.frame.height + 8
            hintLabel.frame = NSRect(x: (rect.width - w) / 2, y: 18, width: w, height: h)
            hintLabel.isHidden = false
        } else {
            hintLabel.isHidden = true
        }
        orderFront(nil) // not key — don't steal focus from the drag
    }
}
