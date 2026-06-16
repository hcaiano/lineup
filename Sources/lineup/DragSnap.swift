import AppKit
import LineupCore

/// Shift-drag snapping: while the user drags a window with SHIFT held, highlight the
/// zone under the cursor; on mouse-release, snap the dragged window into it.
///
/// Every edge of a zone has a 5% hot band that targets that HALF of the zone instead, and
/// a corner (two bands at once) targets that QUARTER — so a column can hold two apps
/// stacked, or four apps in a grid, without editing the layout. The highlight always
/// previews exactly what release will do; lingering in a zone fades in a one-line hint
/// that teaches the edge snaps.
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
    private var teachHint = false   // first shift-drag ever: surface the edge hint right away
    private static let seenEdgeHintKey = "lineup.seenEdgeHint"

    // Unsnap restore: dragging a snapped window away brings its pre-snap size back under
    // the cursor. Two phases — match the window early in the drag (while it's still
    // near its snapped frame), restore only after real movement WITH an unchanged size
    // (a changing size means the user is resizing, never an unsnap). Both phases run at
    // most once per drag and only while there are snaps to restore, so an ordinary drag
    // costs nothing extra.
    private var dragStart: CGPoint?
    private var restoreChecked = false
    private var restoreCandidate: (window: AXUIElement, preFrame: CGRect, frameAtMatch: CGRect)?
    private var restoreRetries = 0

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
            dragStart = NSEvent.mouseLocation
        case .leftMouseDragged:
            if event.modifierFlags.contains(.shift) {
                if captured == nil { captured = WindowMover.window(atCocoaPoint: NSEvent.mouseLocation) }
                if captured != nil {
                    if !armed { armEdgeHintIfFirstEver() } // on the disarmed -> armed transition
                    armed = true
                }
            } else {
                // SHIFT released mid-drag: disarm and hide (re-arms if SHIFT returns).
                armed = false
                hideHighlight()
            }
            // After the capture so a shift-drag's hit-test is shared, not repeated.
            maybeRestoreUnsnappedSize()
            if armed { updateHighlight() }
        case .leftMouseUp:
            if armed, let win = captured, let rect = lastTargetRect {
                WindowMover.snap(win, toCocoaRect: rect)
            }
            reset()
        default:
            break
        }
    }

    // MARK: - Unsnap restore

    /// If the dragged window is one we snapped, give it back its pre-snap size under the
    /// cursor once the drag is real. Works for plain drags and shift-drags alike —
    /// dragging away IS the undo.
    private func maybeRestoreUnsnappedSize() {
        guard !restoreChecked, !SnapMemory.shared.isEmpty, let start = dragStart else { return }
        let p = NSEvent.mouseLocation

        // Phase 1, first drag event: is this a window we snapped, still (almost) where we
        // put it? The window may have moved a few points before the event reached us.
        if restoreCandidate == nil {
            guard let window = captured ?? WindowMover.window(atCocoaPoint: p),
                  let frame = WindowMover.frame(of: window),
                  let pre = SnapMemory.shared.preFrame(of: window, draggedFrame: frame, originTol: 24)
            else { restoreChecked = true; return } // not a snapped window — done for this drag
            restoreCandidate = (window, pre, frame)
            return
        }

        // Phase 2, real movement. The WINDOW must be moving too, with its size unchanged:
        // a drag inside the window (selecting text, dragging a file) moves only the
        // cursor, and an edge-resize changes the size — neither is an unsnap. A busy app
        // can report a stale frame on the first read, so "hasn't moved yet" retries over
        // the next few events instead of giving up on one sample.
        guard hypot(p.x - start.x, p.y - start.y) > 10 else { return }
        guard let c = restoreCandidate, let current = WindowMover.frame(of: c.window)
        else { restoreChecked = true; return }
        if abs(current.width - c.frameAtMatch.width) > 4 ||
           abs(current.height - c.frameAtMatch.height) > 4 {
            restoreChecked = true // size changed: definitively a resize, never an unsnap
            return
        }
        guard hypot(current.minX - c.frameAtMatch.minX, current.minY - c.frameAtMatch.minY) > 5 else {
            restoreRetries += 1
            if restoreRetries >= 5 { restoreChecked = true } // content drag — stop sampling
            return
        }
        restoreChecked = true
        let restored = UnsnapRestore.frame(preSize: c.preFrame.size, current: current, cursor: p)
        WindowMover.restoreDuringDrag(c.window, toCocoaRect: restored)
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
        // A tactile tick each time the target changes (zone to zone, zone to half, half to
        // quarter) — trackpads only, free elsewhere. You feel the snap before you drop it.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    /// Arm/refresh the linger timer per zone; once it fires, the hint rides along with the
    /// highlight until the user targets a half or leaves the zone.
    private func trackLinger(zone: CGRect, targetingHalf: Bool) {
        if targetingHalf { clearLinger(); return }
        if zone != lingerZone {
            lingerZone = zone
            // First-ever shift-drag: show the hint right away (updateHighlight draws it on this
            // same pass) instead of waiting out the linger, so everyone meets the edge snap once.
            if teachHint {
                hintShown = true
                UserDefaults.standard.set(true, forKey: Self.seenEdgeHintKey) // it's actually on screen now
                lingerTimer?.invalidate(); lingerTimer = nil
                return
            }
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

    /// The half/quarter edge snap is delightful but hidden: today you only meet it by lingering.
    /// Teach it ONCE. On the user's first-ever shift-drag, surface the hint immediately; after
    /// that the linger behavior still teaches anyone who hesitates, and we never force it again.
    private func armEdgeHintIfFirstEver() {
        // Arm the one-time teach, but DON'T burn the flag yet: if this first drag goes straight to
        // a half/quarter the hint never renders, so we persist "seen" only when it actually shows
        // (in trackLinger). teachHint clears on drag end; the next drag re-arms until it's seen.
        if !UserDefaults.standard.bool(forKey: Self.seenEdgeHintKey) { teachHint = true }
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
        teachHint = false
        highlight?.orderOut(nil)
        highlight = nil
        lastTargetRect = nil
        clearLinger()
        dragStart = nil
        restoreChecked = false
        restoreCandidate = nil
        restoreRetries = 0
    }

    private func screenContaining(_ p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}

/// Translucent, click-through block highlight. The window frame IS the highlighted target;
/// an optional one-line hint teaches the half-snap when the user lingers.
private final class HighlightWindow: NSWindow {
    static let halfHint = "Edges fill half, corners a quarter"

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
            // The pill must sit fully INSIDE the highlight; in a zone too small or narrow
            // to host it cleanly, show nothing rather than something clipped.
            if rect.width < w + 16 || rect.height < h + 26 {
                hintLabel.isHidden = true
            } else {
                let y = min(18, max(6, rect.height - h - 6))
                hintLabel.frame = NSRect(x: (rect.width - w) / 2, y: y, width: w, height: h)
                hintLabel.isHidden = false
            }
        } else {
            hintLabel.isHidden = true
        }
        orderFront(nil) // not key — don't steal focus from the drag
    }
}
