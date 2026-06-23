import AppKit
import ApplicationServices
import LineupCore

/// Remembers the frame a window had before WE snapped it, making every snap reversible:
/// dragging a snapped window away brings its old size back, and the Restore shortcut puts
/// it back where it was. Rectangle's WindowHistory semantics: the pre-snap frame is seeded
/// once and only re-seeded after the window moves externally; re-snapping (cycling widths,
/// hopping zones) just updates where we last put it. In-memory only, capped, no IDs — the
/// AXUIElement itself is the key (CFEqual compares the underlying element).
final class SnapMemory {
    static let shared = SnapMemory()
    private struct Entry {
        let window: AXUIElement
        var preFrame: CGRect   // where the USER last had it
        var snappedTo: CGRect  // where WE last put it
    }
    private var entries: [Entry] = []
    private let cap = 16

    var isEmpty: Bool { entries.isEmpty }

    /// Record a snap we performed; `from` is the window's frame just before it.
    func recordSnap(of window: AXUIElement, from: CGRect, to: CGRect) {
        if let i = entries.firstIndex(where: { CFEqual($0.window, window) }) {
            var e = entries.remove(at: i)
            // Still where we put it -> a cycle/zone hop; the original preFrame survives.
            // Moved externally since -> the user re-placed it; THAT becomes the preFrame.
            if !SnapMemory.approx(e.snappedTo, from) { e.preFrame = from }
            e.snappedTo = to
            entries.append(e)
        } else {
            entries.append(Entry(window: window, preFrame: from, snappedTo: to))
            if entries.count > cap { entries.removeFirst() }
        }
    }

    /// The pre-snap frame — only while `window` is still where we snapped it.
    func preFrame(of window: AXUIElement, currentFrame: CGRect) -> CGRect? {
        guard let e = entries.first(where: { CFEqual($0.window, window) }),
              SnapMemory.approx(e.snappedTo, currentFrame) else { return nil }
        return e.preFrame
    }

    /// Drag-away restore needs looser matching (the window has already moved a little by
    /// the first drag event): origin within `originTol`, size within 4pt. A size mismatch
    /// means the user is RESIZING the snapped window, which is never an unsnap.
    func preFrame(of window: AXUIElement, draggedFrame: CGRect, originTol: CGFloat) -> CGRect? {
        guard let e = entries.first(where: { CFEqual($0.window, window) }),
              abs(e.snappedTo.width - draggedFrame.width) <= 4,
              abs(e.snappedTo.height - draggedFrame.height) <= 4,
              abs(e.snappedTo.minX - draggedFrame.minX) <= originTol,
              abs(e.snappedTo.minY - draggedFrame.minY) <= originTol else { return nil }
        return e.preFrame
    }

    func forget(_ window: AXUIElement) {
        entries.removeAll { CFEqual($0.window, window) }
    }

    private static func approx(_ a: CGRect, _ b: CGRect, tol: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
}

/// Moves/resizes the frontmost window of the frontmost app via the Accessibility API.
/// All public input is Cocoa-space; the single AX coordinate flip happens here.
enum WindowMover {

    /// Snap the focused window via a quick-action id ("full"/"left"/.../"rightHalf"),
    /// resolved against the per-screen layout for the screen the window is on.
    /// Returns false (silently) if there's no focused window or AX isn't trusted.
    @discardableResult
    static func snapFocusedWindow(toQuickAction id: String, config: LineupConfig) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let window = focusedWindow() else { return false }

        // Current window frame in Cocoa space, to decide which screen it's on.
        guard let currentCocoa = currentCocoaFrame(of: window) else { return false }
        guard let screen = screen(for: currentCocoa) else { return false }

        let info = ScreenIdentity.info(for: screen)
        let root = config.layout(forKey: info.key)
        guard let target = QuickAction.rect(
            id, root: root,
            frame: screen.frame, visibleFrame: screen.visibleFrame,
            pixelsWide: info.pixelsWide) else { return false }

        // Record where the window was steered (fixed-size windows get centered, not the
        // zone rect) so the unsnap match works against where it really ends up.
        let landed = setFrame(target, of: window)
        SnapMemory.shared.recordSnap(of: window, from: currentCocoa, to: landed)
        return true
    }

    // MARK: - AX element access

    /// All AX calls run on the main thread, and a hung target app blocks each one for the
    /// system default of 6 seconds. One second is generous for a healthy app; past that we
    /// fail the snap fast instead of beachballing the menu bar (AeroSpace's lesson).
    private static func tame(_ el: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(el, 1.0)
        return el
    }

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Never target our own UI (e.g. the alignment overlay while it's frontmost).
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        let appEl = tame(AXUIElementCreateApplication(app.processIdentifier))
        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef)
        guard err == .success, let win = winRef else { return nil }
        // tame() BEFORE the role read below: the messaging timeout is per-element, and the
        // freshly-returned window element starts at the system default 6s. isConfirmedNonWindow
        // sends an AX message, so a hung frontmost app would beachball the menu bar for 6s
        // unless we bound it to 1s first (matches enclosingWindow's order).
        guard let raw = AXExtract.element(win) else { return nil }
        let window = tame(raw)
        // The focused "window" can be a sheet or system overlay (role != AXWindow);
        // snapping one of those away from its parent looks broken. Leave them alone.
        // Fail OPEN: a flaky role read must not refuse a real window.
        if isConfirmedNonWindow(window) { return nil }
        return window
    }

    /// True only when the role read SUCCEEDS and says "not a window". Errors and
    /// timeouts return false, so flaky-but-real windows still snap.
    private static func isConfirmedNonWindow(_ el: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }
        return role != (kAXWindowRole as String)
    }

    /// Hit-test the window under a global Cocoa point (bottom-left origin). Returns the
    /// containing window element, or nil if there's no window there (e.g. the desktop).
    static func window(atCocoaPoint p: CGPoint) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let axY = primaryMaxY() - p.y // CG hit-test uses top-left origin from primary
        let sys = tame(AXUIElementCreateSystemWide())
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(axY), &hitRef) == .success,
              let hit = hitRef else { return nil }
        return enclosingWindow(of: tame(hit))
    }

    /// Walk up the AX hierarchy to the element's window (via kAXWindow shortcut, then by
    /// role). Bounded depth so a pathological tree can't spin.
    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depth = 0
        while let e = current, depth < 16 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == (kAXWindowRole as String) {
                return e
            }
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXWindowAttribute as CFString, &winRef) == .success,
               let candidate = AXExtract.element(winRef) {
                // The kAXWindow shortcut can hand back a sheet/overlay (e.g. from inside
                // a Save sheet). Confirmed non-windows are not drag targets.
                let tamed = tame(candidate)
                return isConfirmedNonWindow(tamed) ? nil : tamed
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = AXExtract.element(parentRef) {
                current = tame(parent)
            } else {
                current = nil
            }
            depth += 1
        }
        return nil
    }

    /// Snap the focused window into positional Zone `index` (0-based) of its screen's
    /// layout. No-op if that zone doesn't exist on this screen (out-of-range binding).
    @discardableResult
    static func snapFocusedWindow(toZoneIndex index: Int, config: LineupConfig) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let window = focusedWindow() else { return false }
        guard let currentCocoa = currentCocoaFrame(of: window) else { return false }
        guard let screen = screen(for: currentCocoa) else { return false }
        let info = ScreenIdentity.info(for: screen)
        let root = config.layout(forKey: info.key)
        guard let target = Layout.zoneRect(
            index: index, root: root,
            frame: screen.frame, visibleFrame: screen.visibleFrame,
            pixelsWide: info.pixelsWide) else { return false }
        let landed = setFrame(target, of: window)
        SnapMemory.shared.recordSnap(of: window, from: currentCocoa, to: landed)
        return true
    }

    /// Advance the left/right/center cycle for the focused window. Returns the new cycle
    /// state to carry forward (or the previous state unchanged if nothing could be moved).
    static func cycleFocusedWindow(_ side: Side, config: LineupConfig, now: Double, prev: CycleState?) -> CycleState? {
        guard AXIsProcessTrusted() else { return prev }
        guard let window = focusedWindow() else { return prev }
        guard let currentCocoa = currentCocoaFrame(of: window) else { return prev }
        guard let screen = screen(for: currentCocoa) else { return prev }
        let info = ScreenIdentity.info(for: screen)
        let root = config.layout(forKey: info.key)
        let steps = Cycle.steps(side, root: root, frame: screen.frame, visibleFrame: screen.visibleFrame, pixelsWide: info.pixelsWide)
        guard !steps.isEmpty else { return prev }

        let actionId: String
        switch side {
        case .left: actionId = "left"
        case .right: actionId = "right"
        case .center: actionId = "center"
        }
        let idx = Cycle.nextStep(action: actionId, now: now, screenKey: info.key,
                                 focusedFrame: currentCocoa, prev: prev, stepCount: steps.count)
        let target = steps[idx]
        let landed = setFrame(target, of: window)
        SnapMemory.shared.recordSnap(of: window, from: currentCocoa, to: landed)
        return CycleState(action: actionId, stepIndex: idx, lastTime: now, screenKey: info.key, lastRect: target)
    }

    /// Snap a specific window element to a Cocoa-space rect (used by modifier-drag snapping,
    /// where the dragged window isn't necessarily the focused one yet).
    static func snap(_ window: AXUIElement, toCocoaRect rect: CGRect) {
        guard AXIsProcessTrusted() else { return }
        let before = currentCocoaFrame(of: window)
        let landed = setFrame(rect, of: window)
        if let before {
            SnapMemory.shared.recordSnap(of: window, from: before, to: landed)
        }
    }

    /// The Restore shortcut: put the focused window back at its pre-snap frame. Only
    /// fires while the window is still where we snapped it; otherwise a no-op.
    @discardableResult
    static func restoreFocusedWindow() -> Bool {
        guard AXIsProcessTrusted(), let window = focusedWindow(),
              let current = currentCocoaFrame(of: window),
              let pre = SnapMemory.shared.preFrame(of: window, currentFrame: current)
        else { return false }
        setFrame(pre, of: window)
        // Forget AFTER the move: if a hung app made it fail, the next press can retry.
        SnapMemory.shared.forget(window)
        return true
    }

    /// Mid-drag size restore (drag-away unsnap). Position first, then size — the window
    /// is under the user's hand, so the initial size-set of the normal dance would just
    /// add a visible stutter (Rectangle's adjustSizeFirst:false).
    static func restoreDuringDrag(_ window: AXUIElement, toCocoaRect rect: CGRect) {
        guard AXIsProcessTrusted() else { return }
        SnapMemory.shared.forget(window)
        let restoreEnhanced = suspendEnhancedUserInterface(of: window)
        defer { if let appEl = restoreEnhanced { setBool(appEl, enhancedUserInterfaceAttribute, true) } }
        let ax = Coord.axRect(fromCocoa: rect, primaryMaxY: primaryMaxY())
        setPoint(window, kAXPositionAttribute, ax.origin)
        setSize(window, kAXSizeAttribute, ax.size)
    }

    /// The window's current Cocoa-space frame, if readable (drag-away restore needs it).
    static func frame(of window: AXUIElement) -> CGRect? {
        currentCocoaFrame(of: window)
    }

    /// Read the window's AX frame and convert to Cocoa space.
    private static func currentCocoaFrame(of window: AXUIElement) -> CGRect? {
        guard let pos = axPoint(window, kAXPositionAttribute),
              let size = axSize(window, kAXSizeAttribute)
        else { return nil }
        let axRect = CGRect(origin: pos, size: size)
        return Coord.cocoaRect(fromAX: axRect, primaryMaxY: primaryMaxY())
    }

    /// Apply a Cocoa-space rect to the window. Order size -> position -> size makes
    /// cross-display moves and apps that clamp size-before-position behave (Rectangle).
    /// Windows that can't (or won't) take the zone's size are centered in it instead of
    /// being abandoned wherever the resize gave up. Returns the frame the window was
    /// ultimately steered to — the INTENT, which callers record; reading the result back
    /// instead would capture in-between junk from apps that resize asynchronously.
    @discardableResult
    private static func setFrame(_ cocoa: CGRect, of window: AXUIElement) -> CGRect {
        let restoreEnhanced = suspendEnhancedUserInterface(of: window)
        defer { if let appEl = restoreEnhanced { setBool(appEl, enhancedUserInterfaceAttribute, true) } }

        // Non-resizable window (Terminal's grid snap, fixed dialogs): don't fight it.
        // Center its current size in the zone — a move it can always honor.
        if !isResizable(window) {
            if let size = axSize(window, kAXSizeAttribute) {
                return place(size: size, in: cocoa, of: window)
            }
            return cocoa
        }

        let before = axSize(window, kAXSizeAttribute)
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY())
        setSize(window, kAXSizeAttribute, ax.size)
        setPoint(window, kAXPositionAttribute, ax.origin)
        setSize(window, kAXSizeAttribute, ax.size)

        // Verify: apps with a minimum size accept the move but refuse the resize, leaving
        // the window hanging out of the zone. Re-place what we actually got — but ONLY on
        // a genuine refusal (size unchanged from before). Apps that resize asynchronously
        // (JetBrains' AX bridge) read back a stale in-between size; re-placing on that
        // would mis-position the final frame, so those are left alone.
        if let actual = axSize(window, kAXSizeAttribute), let before,
           abs(actual.width - cocoa.width) > 1 || abs(actual.height - cocoa.height) > 1,
           abs(actual.width - before.width) <= 1, abs(actual.height - before.height) <= 1 {
            return place(size: actual, in: cocoa, of: window)
        }
        return cocoa
    }

    /// Position-only placement: center `size` in the target zone, clamped to the zone's
    /// screen so the window stays fully on-screen. Returns the placed frame.
    @discardableResult
    private static func place(size: CGSize, in zone: CGRect, of window: AXUIElement) -> CGRect {
        let bounds = screen(for: zone)?.visibleFrame ?? zone
        let target = FixedPlacement.center(size: size, in: zone, boundedBy: bounds)
        let ax = Coord.axRect(fromCocoa: target, primaryMaxY: primaryMaxY())
        setPoint(window, kAXPositionAttribute, ax.origin)
        return target
    }

    /// Resizable unless AX says otherwise; if the query itself fails, assume resizable
    /// and let the verify step clean up (Rectangle's rule).
    private static func isResizable(_ window: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success
        else { return true }
        return settable.boolValue
    }

    /// "AXEnhancedUserInterface" on an app (set by VoiceOver and some Electron apps) makes
    /// it animate and re-constrain AX moves, so frames land somewhere else or not at all.
    /// Every serious mover (Rectangle, Loop, Hammerspoon) flips it off around the move and
    /// restores it after. Returns the app element to restore on, or nil if it was off.
    private static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    private static func suspendEnhancedUserInterface(of window: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let appEl = tame(AXUIElementCreateApplication(pid)) // fresh element: tame it too
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, enhancedUserInterfaceAttribute as CFString, &ref) == .success,
              (ref as? Bool) == true else { return nil }
        setBool(appEl, enhancedUserInterfaceAttribute, false)
        return appEl
    }

    // MARK: - Screen helpers

    private static func primaryMaxY() -> CGFloat {
        // NSScreen.screens[0] is always the primary (menu-bar) display.
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private static func screen(for cocoaWindow: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        let frames = screens.map { $0.frame }
        guard let idx = ScreenPicker.bestScreenIndex(forWindow: cocoaWindow, screens: frames) else {
            return screens.first
        }
        return screens[idx]
    }

    static func pixelsWide(of screen: NSScreen) -> Int {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let num = screen.deviceDescription[key] as? NSNumber else {
            return Int(screen.frame.width) // fallback: assume 1:1 (non-retina)
        }
        let displayID = CGDirectDisplayID(num.uint32Value)
        let px = CGDisplayPixelsWide(displayID)
        return px > 0 ? px : Int(screen.frame.width)
    }

    // MARK: - AXValue glue (concrete value types — no generics, so the compiler can
    // prove there's no object reference under the raw pointer).

    private static func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return AXExtract.point(ref)
    }

    private static func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return AXExtract.size(ref)
    }

    private static func setPoint(_ el: AXUIElement, _ attr: String, _ point: CGPoint) {
        var p = point
        guard let axv = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(el, attr as CFString, axv)
    }

    private static func setSize(_ el: AXUIElement, _ attr: String, _ size: CGSize) {
        var s = size
        guard let axv = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(el, attr as CFString, axv)
    }

    private static func setBool(_ el: AXUIElement, _ attr: String, _ value: Bool) {
        AXUIElementSetAttributeValue(el, attr as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
