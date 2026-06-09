import AppKit
import LineupCore

/// Shift-drag snapping: while the user drags a window with SHIFT held, highlight the
/// column under the cursor; on mouse-release, snap the dragged window into that column.
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
    private var lastZoneRect: CGRect?

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
            if armed, let win = captured, let rect = lastZoneRect {
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
        guard let rect = currentZoneRect() else { hideHighlight(); return }
        if rect == lastZoneRect, highlight != nil { return } // unchanged — skip redraw
        lastZoneRect = rect
        if highlight == nil { highlight = HighlightWindow() }
        highlight?.show(at: rect)
    }

    private func hideHighlight() {
        highlight?.orderOut(nil)
        lastZoneRect = nil
    }

    private func reset() {
        captured = nil
        armed = false
        highlight?.orderOut(nil)
        highlight = nil
        lastZoneRect = nil
    }

    private func screenContaining(_ p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}

/// Translucent, click-through block highlight. The window frame IS the highlighted zone.
private final class HighlightWindow: NSWindow {
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
        v.layer?.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.22).cgColor
        v.layer?.borderColor = NSColor.systemIndigo.withAlphaComponent(0.95).cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 14
        contentView = v
    }

    func show(at rect: CGRect) {
        setFrame(rect, display: true)
        orderFront(nil) // not key — don't steal focus from the drag
    }
}
