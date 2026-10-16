import AppKit
import ApplicationServices
import ZonesCore

/// Remembers the frame a window had before WE snapped it, making every snap reversible:
/// dragging a snapped window away brings its old size back, and the Restore shortcut puts
/// it back where it was. Rectangle's WindowHistory semantics: the pre-snap frame is seeded
/// once and only re-seeded after the window moves externally; re-snapping (cycling widths,
/// hopping zones) just updates where we last put it. In-memory only, capped, no IDs — the
/// AXUIElement itself is the key (CFEqual compares the underlying element).
///
/// `@MainActor` since the 2.0 merge: it is only ever touched from the main thread (hotkey
/// actions, the drag monitor) and it retains `AXUIElement`s, which `ZonesTool.stop()` has to be
/// able to drop deterministically — see `reset()`.
@MainActor
final class SnapMemory {
    static let shared = SnapMemory()
    var recovery: [FrameEffect<AXUIElement>] = []
    var records = SnapRecords<AXUIElement>(equal: { CFEqual($0, $1) })

    var isEmpty: Bool { records.entries.isEmpty }

    func recordSnap(of window: AXUIElement, from: CGRect, to: CGRect) {
        records.recordSnap(window, from: from, to: to)
    }

    func preFrame(of window: AXUIElement, currentFrame: CGRect) -> CGRect? {
        records.preFrame(window, current: currentFrame)
    }

    func preFrame(of window: AXUIElement, draggedFrame: CGRect, originTol: CGFloat) -> CGRect? {
        records.preFrame(window, current: draggedFrame, originTolerance: originTol)
    }

    func forget(_ window: AXUIElement) { records.forget(window) }
    func reset() { records.removeAll(); recovery.removeAll() }

}

/// Moves/resizes the frontmost window of the frontmost app via the Accessibility API.
/// All public input is Cocoa-space; the single AX coordinate flip happens here.
///
/// `@MainActor` since the 2.0 merge: AX messaging and `NSScreen` reads must happen on the main
/// thread, and both callers (the Zones hotkey actions and the drag monitor) are isolated there.
@MainActor
enum WindowMover {
    typealias PlacementHandler = (AXUIElement, NSScreen, CGRect) -> Void

    /// Snap the focused window via a quick-action id ("full"/"left"/.../"rightHalf"),
    /// resolved against the per-screen layout for the screen the window is on.
    /// Returns false (silently) if there's no focused window or AX isn't trusted.
    @discardableResult
    static func snapFocusedWindow(toQuickAction id: String, config: LineupConfig,
                                  onPlacement: PlacementHandler) -> Bool {
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

        if id == "full" {
            return maximizeOrReturn(window, current: currentCocoa, target: target, screenKey: info.key)
        }

        // Record where the window was steered (fixed-size windows get centered, not the
        // zone rect) so the unsnap match works against where it really ends up.
        let landed = setFrame(target, of: window)
        guard let landed else { return false }
        SnapMemory.shared.recordSnap(of: window, from: currentCocoa, to: landed)
        onPlacement(window, screen, target)
        return true
    }

    @discardableResult
    static func maximizeOrReturn(_ window: AXUIElement, current: CGRect, target: CGRect,
                                 screenKey: String) -> Bool {
        let action = SnapMemory.shared.records.maximizeAction(window, current: current,
                                                              full: target, screenKey: screenKey)
        let destination: CGRect
        switch action {
        case .none: return false
        case .maximize(let rect), .returnTo(let rect): destination = rect
        }
        guard !SnapMemory.shared.recovery.contains(where: { CFEqual($0.window, window) }),
              let landed = setFrame(destination, of: window) else { return false }
        SnapMemory.shared.records.recordMaximize(window, action: action, from: current,
                                                  landed: landed, screenKey: screenKey)
        if case .returnTo = action,
           !SnapRecords<AXUIElement>.matches(landed, destination, originTolerance: 1, sizeTolerance: 1) {
            return false
        }
        return true
    }

    struct VisibleWindow {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let window: AXUIElement?
        let appName: String
        let title: String
    }

    static func visibleWindows(pids: Set<pid_t>? = nil) -> [VisibleWindow]? {
        guard AXIsProcessTrusted(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let cg = list.filter {
            guard let pid = $0[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return ($0[kCGWindowLayer as String] as? Int) == 0 && pid != getpid()
                && pids.map { $0.contains(pid) } != false
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }
        var axByPID: [pid_t: [(AXUIElement, CGRect, String)]] = [:]
        for pid in Set(cg.compactMap { $0[kCGWindowOwnerPID as String] as? Int32 }) {
            guard NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            let app = tame(AXUIElementCreateApplication(pid))
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { axByPID[pid] = []; continue }
            axByPID[pid] = windows.compactMap { window in
                guard isEligible(window), let rect = frame(of: window) else { return nil }
                var title: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                return (window, rect, title as? String ?? "Untitled window")
            }
        }
        return cg.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let cocoa = Coord.cocoaRect(fromAX: rect, primaryMaxY: primaryMaxY())
            let matches = (axByPID[pid] ?? []).filter {
                WindowIdentityGeometry.matches(surface: cocoa, accessibility: $0.1)
            }
            let sameCG = cg.filter { other in
                guard other[kCGWindowOwnerPID as String] as? Int32 == pid,
                      let bounds = other[kCGWindowBounds as String] as? [String: Any],
                      let otherRect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                guard matches.count == 1 else { return false }
                let otherCocoa = Coord.cocoaRect(fromAX: otherRect, primaryMaxY: primaryMaxY())
                return WindowIdentityGeometry.matches(surface: otherCocoa, accessibility: matches[0].1)
            }
            let exact = matches.count == 1 && sameCG.count == 1 ? matches[0] : nil
            return VisibleWindow(id: id, pid: pid, frame: exact?.1 ?? cocoa, window: exact?.0,
                                 appName: app.localizedName ?? "Application", title: exact?.2 ?? "Window unavailable")
        }
    }

    static func isOnScreen(_ window: AXUIElement, in visible: [VisibleWindow]) -> Bool {
        visible.contains { $0.window.map { CFEqual($0, window) } == true }
    }

    enum Observation { case current, excluded, unresolved }

    static func observe(_ entry: SnapRecords<AXUIElement>.Entry, in visible: [VisibleWindow]?) -> Observation {
        if isGone(entry.window) { return .excluded }
        guard let eligible = eligibility(entry.window) else { return .unresolved }
        if !eligible { return .excluded }
        guard let visible else { return .unresolved }
        var pid: pid_t = 0
        guard AXUIElementGetPid(entry.window, &pid) == .success else { return .unresolved }
        let onScreen = isOnScreen(entry.window, in: visible)
        let ambiguous = visible.contains { $0.pid == pid && $0.window == nil }
        if !onScreen && !ambiguous { return .excluded }
        guard let frame = frame(of: entry.window) else { return .unresolved }
        if !SnapRecords<AXUIElement>.matches(frame, entry.snappedTo, originTolerance: 1, sizeTolerance: 1) {
            return .excluded
        }
        return onScreen ? .current : .unresolved
    }

    static func isEligible(_ window: AXUIElement) -> Bool { eligibility(window) == true }

    private static func eligibility(_ window: AXUIElement) -> Bool? {
        func attribute(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(tame(window), key as CFString, &value) == .success else { return nil }
            return value
        }
        guard let role = attribute(kAXRoleAttribute) as? String else { return nil }
        if role != "AXWindow" { return false }
        guard let subrole = attribute(kAXSubroleAttribute) as? String else { return nil }
        if subrole != "AXStandardWindow" { return false }
        for key in [kAXModalAttribute, kAXMinimizedAttribute, "AXFullScreen"] {
            guard let value = attribute(key) as? Bool else { return nil }
            if value { return false }
        }
        return true
    }

    static func canFitExactly(_ window: AXUIElement) -> Bool {
        isEligible(window) && settable(window, kAXPositionAttribute) && settable(window, kAXSizeAttribute)
    }

    static func pids(of windows: [AXUIElement]) -> Set<pid_t> {
        Set(windows.compactMap { window in
            var pid: pid_t = 0
            return AXUIElementGetPid(window, &pid) == .success ? pid : nil
        })
    }

    @discardableResult
    static func commit(_ effects: [FrameEffect<AXUIElement>], validate: () -> Bool,
                       persist: () throws -> Void) -> ExactCommit.Outcome<AXUIElement> {
        guard SnapMemory.shared.recovery.isEmpty, AXIsProcessTrusted() else { return .rejected }
        let outcome = ExactCommit.apply(effects, validate: { AXIsProcessTrusted() && validate() },
                                        read: frame, eligible: isEligible,
                                        write: { setFrame($1, of: $0, fitting: .exact) != nil }, persist: persist)
        switch outcome {
        case .committed:
            var records = SnapMemory.shared.records
            for effect in effects {
                records.recordSnap(effect.window, from: effect.before, to: effect.after, placement: effect.placement)
            }
            SnapMemory.shared.records = records
        case .recovery(let receipt): SnapMemory.shared.recovery = receipt
        case .rejected, .rolledBack: break
        }
        return outcome
    }

    /// Without Accessibility nothing can be known, so the receipt stays as it is.
    @discardableResult
    static func retryRestore() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        SnapMemory.shared.recovery = ExactCommit.restore(SnapMemory.shared.recovery, read: frame,
            write: { setFrame($1, of: $0, fitting: .exact) != nil }, isGone: isGone)
        return SnapMemory.shared.recovery.isEmpty
    }

    /// True only on definitive evidence: the owning process has exited, or AX reports the
    /// element invalid. A timeout, an unreadable attribute or missing permission is not proof.
    static func isGone(_ window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) == .success, pid > 0, kill(pid, 0) != 0, errno == ESRCH { return true }
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(tame(window), kAXRoleAttribute as CFString, &role) == .invalidUIElement
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

    /// Snap the focused window into positional Zone `index` (0-based) of an EXPLICIT target
    /// display — the global-numbered-zone path. The caller (ZonesTool) resolved the global
    /// zone number through the stable `ZoneNumbering` snapshot to `(configKey, index)` and
    /// hands over the NSScreen that config key is connected to, so a window starting on
    /// another monitor is moved across displays onto the owning display's zone.
    ///
    /// Geometry comes from the TARGET screen (frame/visibleFrame/pixels), never from the
    /// window's current screen. Same AX trust/focused-window checks, same
    /// size->position->size cross-display dance, same SnapMemory seeding from the window's
    /// ORIGINAL frame as every other snap path.
    @discardableResult
    static func snapFocusedWindow(toZoneIndex index: Int,
                                  on target: NSScreen,
                                  configKey: String,
                                  config: LineupConfig,
                                  onPlacement: PlacementHandler) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let window = focusedWindow() else { return false }
        guard let currentCocoa = currentCocoaFrame(of: window) else { return false }
        let info = ScreenIdentity.info(for: target)
        // Resolve through the CONFIG KEY the numbering map used — after durable
        // preparation it is always the owning screen's exact key.
        let root = config.layout(forKey: configKey)
        guard let targetRect = Layout.zoneRect(
            index: index, root: root,
            frame: target.frame, visibleFrame: target.visibleFrame,
            pixelsWide: info.pixelsWide) else { return false }
        let landed = setFrame(targetRect, of: window)
        guard let landed else { return false }
        SnapMemory.shared.recordSnap(of: window, from: currentCocoa, to: landed)
        onPlacement(window, target, targetRect)
        return true
    }

    /// Advance the left/right/center cycle for the focused window. Returns the new cycle
    /// state to carry forward (or the previous state unchanged if nothing could be moved).
    static func cycleFocusedWindow(_ side: Side, config: LineupConfig, now: Double, prev: CycleState?,
                                   onPlacement: PlacementHandler) -> CycleState? {
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
        guard let landed else { return prev }
        SnapMemory.shared.recordSnap(of: window, from: currentCocoa, to: landed)
        onPlacement(window, screen, target)
        return CycleState(action: actionId, stepIndex: idx, lastTime: now, screenKey: info.key, lastRect: target)
    }

    /// Snap a specific window element to a Cocoa-space rect (used by modifier-drag snapping,
    /// where the dragged window isn't necessarily the focused one yet).
    @discardableResult
    static func snap(_ window: AXUIElement, toCocoaRect rect: CGRect) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let before = currentCocoaFrame(of: window)
        guard let landed = setFrame(rect, of: window) else { return false }
        if let before {
            SnapMemory.shared.recordSnap(of: window, from: before, to: landed)
        }
        return true
    }

    /// The Restore shortcut: put the focused window back at its pre-snap frame. Only
    /// fires while the window is still where we snapped it; otherwise a no-op.
    @discardableResult
    static func restoreFocusedWindow() -> Bool {
        guard AXIsProcessTrusted(), let window = focusedWindow(),
              let current = currentCocoaFrame(of: window),
              let pre = SnapMemory.shared.preFrame(of: window, currentFrame: current)
        else { return false }
        guard setFrame(pre, of: window) != nil else { return false }
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
    enum Fitting { case bestEffort, exact }

    private static func setFrame(_ cocoa: CGRect, of window: AXUIElement,
                                 fitting: Fitting = .bestEffort) -> CGRect? {
        if fitting == .exact {
            guard cocoa.width > 0, cocoa.height > 0,
                  [cocoa.minX, cocoa.minY, cocoa.width, cocoa.height].allSatisfy({ $0.isFinite }),
                  settable(window, kAXPositionAttribute), settable(window, kAXSizeAttribute)
            else { return nil }
            let restoreEnhanced = suspendEnhancedUserInterface(of: window)
            defer { if let app = restoreEnhanced { setBool(app, enhancedUserInterfaceAttribute, true) } }
            let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY())
            guard setSize(window, kAXSizeAttribute, ax.size),
                  setPoint(window, kAXPositionAttribute, ax.origin),
                  setSize(window, kAXSizeAttribute, ax.size),
                  let actual = frame(of: window),
                  SnapRecords<AXUIElement>.matches(actual, cocoa, originTolerance: 1, sizeTolerance: 1)
            else { return nil }
            return actual
        }
        var movable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success,
           !movable.boolValue { return nil }
        let restoreEnhanced = suspendEnhancedUserInterface(of: window)
        defer { if let appEl = restoreEnhanced { setBool(appEl, enhancedUserInterfaceAttribute, true) } }

        // Non-resizable window (Terminal's grid snap, fixed dialogs): don't fight it.
        // Center its current size in the zone — a move it can always honor.
        if !isResizable(window) {
            if let size = axSize(window, kAXSizeAttribute) {
                return place(size: size, in: cocoa, of: window)
            }
            return nil
        }

        let before = axSize(window, kAXSizeAttribute)
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY())
        setSize(window, kAXSizeAttribute, ax.size)
        let moved = setPoint(window, kAXPositionAttribute, ax.origin)
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
        guard moved || positionMatches(ax.origin, of: window) else { return nil }
        return cocoa
    }

    /// Position-only placement: center `size` in the target zone, clamped to the zone's
    /// screen so the window stays fully on-screen. Returns the placed frame.
    @discardableResult
    private static func place(size: CGSize, in zone: CGRect, of window: AXUIElement) -> CGRect? {
        let bounds = screen(for: zone)?.visibleFrame ?? zone
        let target = FixedPlacement.center(size: size, in: zone, boundedBy: bounds)
        let ax = Coord.axRect(fromCocoa: target, primaryMaxY: primaryMaxY())
        guard setPoint(window, kAXPositionAttribute, ax.origin) || positionMatches(ax.origin, of: window) else { return nil }
        return target
    }

    private static func settable(_ window: AXUIElement, _ key: String) -> Bool {
        var flag = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(tame(window), key as CFString, &flag) == .success && flag.boolValue
    }

    private static func positionMatches(_ target: CGPoint, of window: AXUIElement) -> Bool {
        guard let actual = axPoint(window, kAXPositionAttribute) else { return false }
        return abs(actual.x - target.x) <= 1 && abs(actual.y - target.y) <= 1
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

    @discardableResult
    private static func setPoint(_ el: AXUIElement, _ attr: String, _ point: CGPoint) -> Bool {
        var p = point
        guard let axv = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, axv) == .success
    }

    @discardableResult
    private static func setSize(_ el: AXUIElement, _ attr: String, _ size: CGSize) -> Bool {
        var s = size
        guard let axv = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, axv) == .success
    }

    private static func setBool(_ el: AXUIElement, _ attr: String, _ value: Bool) {
        AXUIElementSetAttributeValue(el, attr as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
