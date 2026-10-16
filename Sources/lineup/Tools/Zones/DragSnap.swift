import AppKit
import ZonesCore
import ScreenCaptureKit

struct DragSnapInput {
    var addGlobalMonitor: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Any?
    var removeMonitor: (Any) -> Void
    var pointer: () -> CGPoint
    var modifiers: () -> NSEvent.ModifierFlags
    var isKeyDown: (CGKeyCode) -> Bool
    var isTrusted: () -> Bool
    /// Monotonic seconds, the clock that `secondsSince` ages are measured against.
    var now: () -> TimeInterval
    var secondsSince: (CGEventType) -> TimeInterval
    var pressedButtons: () -> Int
    /// Runs `action` once on the main run loop after `delay`; the returned closure cancels it.
    var schedule: (TimeInterval, @escaping () -> Void) -> () -> Void

    static let system = DragSnapInput(
        addGlobalMonitor: { NSEvent.addGlobalMonitorForEvents(matching: $0, handler: $1) },
        removeMonitor: { NSEvent.removeMonitor($0) },
        pointer: { NSEvent.mouseLocation },
        modifiers: { NSEvent.modifierFlags },
        isKeyDown: { CGEventSource.keyState(.combinedSessionState, key: $0) },
        isTrusted: { AXIsProcessTrusted() },
        now: { ProcessInfo.processInfo.systemUptime },
        secondsSince: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) },
        pressedButtons: { NSEvent.pressedMouseButtons },
        schedule: { delay, action in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        })
}

/// Modifier-drag snapping: while the configured bind is held, dragging a real window
/// highlights the zone under the cursor; on mouse-release, snap the dragged window into it.
///
/// Every edge of a zone has a 5% hot band that targets that HALF of the zone instead, and
/// a corner (two bands at once) targets that QUARTER — so a column can hold two apps
/// stacked, or four apps in a grid, without editing the layout. The highlight always
/// previews exactly what release will do; lingering in a zone fades in a one-line hint
/// that teaches the edge snaps.
///
/// Uses a global mouse monitor (mouse events need no extra permission beyond the
/// Accessibility grant the app already requires to move windows). Reads modifiers from the
/// mouse event and, for key-based binds, asks CoreGraphics whether that key is held.
///
/// `@MainActor` since the 2.0 merge: every AppKit and AX call below already had to be on the
/// main thread, and the Zones tool that owns this controller is main-actor isolated. The event
/// monitor and timer callbacks are delivered on the main run loop, which `MainActor.assumeIsolated`
/// states for the compiler (the same shape Cycler already used).
@MainActor
final class DragSnapController {
    typealias Outcome = ExactCommit.Outcome<AXUIElement>
    private let input: DragSnapInput
    private let visibleWindows: @MainActor (Set<pid_t>?) -> [WindowMover.VisibleWindow]?
    private var monitor: Any?
    private var escapeMonitor: Any?
    private let commitDivider: (NSScreen, Node, Node, [FrameEffect<AXUIElement>]) -> Outcome
    private let canInteract: () -> Bool
    private let canEditLayout: () -> Bool
    private let assistAllowed: () -> Bool
    private let refreshStatus: () -> Void
    private struct FillOffer {
        let screen: NSScreen
        let display: AppZonePlacement.Display
        let root: Node
        let destination: CGRect
        let source: AXUIElement
        let filled: CGRect
    }
    private var fillPanel: ZoneFillPanel?
    private var fillOffer: FillOffer?
    private var fillCandidates: [WindowMover.VisibleWindow] = []
    private var fillTask: Task<Void, Never>?
    private var fillCapture: SingleFrameCapture?
    private var fillGeneration = UUID()
    private var offerTimeout: Timer?
    private var outsideMonitor: Any?
    private var localOutsideMonitor: Any?
    private var grip: DividerGripPanel?
    private var gripPhase: DividerGrip.Phase?
    private var gripScreen: NSScreen?
    private var gripHandle: Layout.DividerHandle?
    private var dwell: DividerDwell?
    private var cancelDwell: (() -> Void)?
    private struct DividerSession {
        let screen: NSScreen
        let display: AppZonePlacement.Display
        let old: Node
        let handle: Layout.DividerHandle
        let records: SnapRecords<AXUIElement>
        let frozen: [(SnapRecords<AXUIElement>.Entry, WindowMover.Observation)]
        var proposed: Node
        var effects: [FrameEffect<AXUIElement>]
    }
    private var dividerSession: DividerSession?
    private var previews: [HighlightWindow] = []
    private var notice: ZoneNoticePanel?
    private var inputWatch: Timer?
    private var cancellationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private let configProvider: () -> LineupConfig
    private let triggerProvider: () -> DragSnapTrigger
    private let onPlacement: WindowMover.PlacementHandler
    private var targetScreenKey: String?
    private var shareRecords: [SnapRecords<AXUIElement>.Entry] = []
    private var shareEntry = ShareEntry()
    private var shareRail: ShareRailPanel?
    private struct SharePlan {
        let screen: NSScreen
        let root: Node
        let incumbent: SnapRecords<AXUIElement>.Entry
        let target: ShareTarget
        let incomingRect: CGRect
    }
    private var sharePlan: SharePlan?
    private var sharePreview: HighlightWindow?

    private var captured: AXUIElement?   // the window grabbed at drag start
    private var armed = false            // trigger modifier held + a window captured
    private var dragSuppressed = false
    private var dragCandidate: (window: AXUIElement, startFrame: CGRect, startPoint: CGPoint, startedInMoveBand: Bool)?
    private var preArmFrameChecks = 0
    private static let maxPreArmFrameChecks = 10
    private var highlight: HighlightWindow?
    private var lastTargetRect: CGRect?  // what release will snap to (zone or half)

    // Linger hint: if the cursor stays in the same zone a moment without targeting a half,
    // teach the feature. A timer is required — a stationary cursor emits no drag events.
    private var lingerZone: CGRect?
    private var lingerTimer: Timer?
    private var hintShown = false
    private var teachHint = false   // first modifier-drag ever: surface the edge hint right away
    private static let seenEdgeHintKey = "lineup.seenEdgeHint"

    // Unsnap restore: dragging a snapped window away brings its pre-snap size back under
    // the cursor. Two phases — match the window early in the drag (while it's still
    // near its snapped frame), restore only after real movement WITH an unchanged size
    // (a changing size means the user is resizing, never an unsnap). Matching and restore
    // run at most once per drag, with bounded frame sampling only while snaps exist.
    private var dragStart: CGPoint?
    private var restoreChecked = false
    private var restoreCandidate: (window: AXUIElement, preFrame: CGRect, frameAtMatch: CGRect)?
    private var restoreSampling: (deadline: TimeInterval, lastSample: TimeInterval)?
    private static let restoreGrace: TimeInterval = 0.5
    private static let restoreSampleInterval: TimeInterval = 0.02

    init(configProvider: @escaping () -> LineupConfig, triggerProvider: @escaping () -> DragSnapTrigger,
         onPlacement: @escaping WindowMover.PlacementHandler,
         commitDivider: @escaping (NSScreen, Node, Node, [FrameEffect<AXUIElement>]) -> Outcome = { _, _, _, _ in .rejected },
         canInteract: @escaping () -> Bool = { true },
         canEditLayout: @escaping () -> Bool = { true },
         assistAllowed: @escaping () -> Bool = { false },
         refreshStatus: @escaping () -> Void = {},
         input: DragSnapInput = .system,
         visibleWindows: @escaping @MainActor (Set<pid_t>?) -> [WindowMover.VisibleWindow]? = { WindowMover.visibleWindows(pids: $0) }) {
        self.configProvider = configProvider
        self.triggerProvider = triggerProvider
        self.onPlacement = onPlacement
        self.commitDivider = commitDivider
        self.canInteract = canInteract
        self.canEditLayout = canEditLayout
        self.assistAllowed = assistAllowed
        self.refreshStatus = refreshStatus
        self.input = input
        self.visibleWindows = visibleWindows
    }

    var isEnabled: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = input.addGlobalMonitor(
            [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            // Global monitors are delivered on the main run loop; the closure type just isn't
            // isolated, so state it.
            MainActor.assumeIsolated { self?.handle(event) }
        }
        for (center, name) in [(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
                               (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
                               (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelSessions() }
            }
            cancellationObservers.append((center, token))
        }
    }

    /// Escape arrives through the Accessibility-authorized key monitor, with key-state polling as a
    /// fallback; neither suppresses any application's input.
    private func watchInput() {
        guard inputWatch == nil else { return }
        escapeMonitor = input.addGlobalMonitor(.keyDown) { [weak self] event in
            MainActor.assumeIsolated { if event.keyCode == 53 { self?.cancelSessions() } }
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkInput() }
        }
        RunLoop.main.add(timer, forMode: .common)
        inputWatch = timer
    }

    private func checkInput() {
        grip?.checkActivationKey()
        if fillOffer != nil && !fillIsCurrent(fillGeneration) { cancelFill(); refreshStatus() }
        if !canInteract() || !input.isTrusted() || input.isKeyDown(53) {
            cancelSessions()
        } else if !triggerMatches(input.modifiers()) {
            sendGrip(.bindUp)
            hideHighlight()
        }
    }

    private func stopInputWatchIfIdle() {
        guard gripPhase == nil, !armed, fillOffer == nil else { return }
        inputWatch?.invalidate(); inputWatch = nil
        if let escapeMonitor { input.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }

    func stop() {
        if let m = monitor { input.removeMonitor(m); monitor = nil }
        for (center, token) in cancellationObservers { center.removeObserver(token) }
        cancellationObservers.removeAll()
        cancelSessions()
        inputWatch?.invalidate(); inputWatch = nil
        if let escapeMonitor { input.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        grip = nil
        notice = nil
    }

    func cancelSessions() {
        if dragStart != nil || armed { dragSuppressed = true }
        reset()
        cancelDivider()
        cancelFill()
        notice?.dismiss()
    }

    private func cancelDivider() {
        endDwell()
        gripPhase = nil
        dividerSession = nil
        previews.forEach { $0.orderOut(nil) }; previews.removeAll()
        grip?.hide()
        gripScreen = nil; gripHandle = nil
        stopInputWatchIfIdle()
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) {
        guard canInteract(), input.isTrusted() else { cancelSessions(); return }
        switch event.type {
        case .mouseMoved:
            if dividerSession == nil && captured == nil { discoverDivider(at: input.pointer()) }
        case .rightMouseDown, .otherMouseDown:
            endDwell()
            sendGrip(.outsidePress)
        case .leftMouseDown:
            endDwell()
            notice?.dismiss()
            cancelFill()
            sendGrip(.outsidePress)
            reset()
            dragSuppressed = false
            dragStart = input.pointer()
            // Preserve the natural Shift-first UX: if the bind is already down, sample the
            // candidate window now, then wait for its AX frame to move before arming. App
            // content drags (Figma selection, canvas moves, etc.) leave the window frame still.
            if dragTriggerMatches(event) { sampleDragCandidate(at: input.pointer()) }
        case .leftMouseDragged:
            guard !dragSuppressed else { break }
            if dragTriggerMatches(event) {
                if captured == nil { captured = movingWindowCandidate(at: input.pointer()) }
                if let captured {
                    if !armed {
                        armEdgeHintIfFirstEver()
                        notice?.dismiss()
                        shareRecords = WindowMover.canFitExactly(captured)
                            ? currentShareRecords(excluding: captured, among: SnapMemory.shared.records.entries) : []
                    }
                    armed = true
                    watchInput()
                } else {
                    armed = false
                    hideHighlight()
                }
            } else {
                // Trigger modifier released mid-drag: disarm and hide (re-arms if it returns).
                armed = false
                hideHighlight()
            }
            // After the capture so a modifier-drag's hit-test is shared, not repeated.
            maybeRestoreUnsnappedSize()
            if armed { updateHighlight() }
        case .leftMouseUp:
            if !dragSuppressed, armed, dragTriggerMatches(event), let win = captured {
                if let plan = sharePlan {
                    releaseShare(plan, window: win)
                } else if let rect = lastTargetRect,
                          let screen = NSScreen.screens.first(where: { ScreenIdentity.info(for: $0).key == targetScreenKey }),
                          WindowMover.snap(win, toCocoaRect: rect) {
                    onPlacement(win, screen, rect)
                    offerFill(after: rect, on: screen, source: win)
                }
            }
            dragSuppressed = false
            reset()
        default:
            break
        }
    }

    private func dragTriggerMatches(_ event: NSEvent) -> Bool {
        triggerMatches(event.modifierFlags)
    }

    private func triggerMatches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let trigger = triggerProvider()
        let keyDown = trigger.keyCode.map { input.isKeyDown(CGKeyCode($0)) } ?? false
        return trigger.matches(
            activeKeyDown: keyDown,
            activeModifiers: ShortcutKit.carbonModifiers(from: flags))
    }

    private func display(for screen: NSScreen) -> AppZonePlacement.Display {
        let info = ScreenIdentity.info(for: screen)
        return AppZonePlacement.Display(key: info.key, frame: screen.frame,
                                        visibleFrame: screen.visibleFrame, pixelsWide: info.pixelsWide)
    }

    private func isCurrent(_ display: AppZonePlacement.Display) -> Bool {
        NSScreen.screens.contains { ScreenIdentity.info(for: $0).key == display.key
            && $0.frame == display.frame && $0.visibleFrame == display.visibleFrame }
    }

    private func currentShareRecords(excluding incoming: AXUIElement,
                                     among entries: [SnapRecords<AXUIElement>.Entry]) -> [SnapRecords<AXUIElement>.Entry] {
        let bound = entries.filter { $0.placement?.zoneIndex != nil && !CFEqual($0.window, incoming) }
        guard !bound.isEmpty, let visible = visibleWindows(WindowMover.pids(of: bound.map(\.window)))
        else { return [] }
        let observations = bound.map { ($0, WindowMover.observe($0, in: visible)) }
        guard !observations.contains(where: { $0.1 == .unresolved }) else { return [] }
        return observations.compactMap { entry, observation in
            observation == .current && WindowMover.canFitExactly(entry.window) ? entry : nil
        }
    }


    private func sendGrip(_ gripInput: DividerGrip.Input) {
        guard let phase = gripPhase else { return }
        let (next, effect) = DividerGrip.next(phase, gripInput)
        gripPhase = next
        if let next { grip?.apply(next) }
        switch effect {
        case .none, .arm, .disarm: break
        case .begin: beginDivider()
        case .preview(let point): previewDivider(at: point)
        case .pin: grip?.pin()
        case .nudge(let delta): nudgeDivider(CGFloat(delta))
        case .commit: finishDivider()
        case .cancel: cancelDivider()
        }
    }

    /// The grip appears only after the pointer pauses on one line (`DividerDwell`), so crossing
    /// lines on the way to a click or a window shows nothing. A shown grip stays where it appeared;
    /// leaving its keep region hides it, and a new pause elsewhere shows it there.
    private func discoverDivider(at point: CGPoint) {
        guard canEditLayout(), triggerMatches(input.modifiers()), SnapMemory.shared.recovery.isEmpty,
              let screen = screenContaining(point) else { cancelDivider(); return }
        if let grip, gripPhase != nil, grip.frame.contains(point) { sendGrip(.pointer(inside: true)); return }
        let key = ScreenIdentity.info(for: screen).key
        let handles = dividerHandles(on: screen)
        if gripPhase != nil {
            if let grip, let shown = gripHandle, gripScreen.map({ ScreenIdentity.info(for: $0).key }) == key,
               let same = handles.first(where: { $0.path == shown.path && $0.index == shown.index && $0.line == shown.line }),
               DividerGrip.keeps(grip.frame, handle: same, pointer: point) {
                sendGrip(.pointer(inside: false))
                return
            }
            cancelDivider()
        }
        let next = DividerDwell.track(dwell, handle: DividerGrip.handle(at: point, in: handles), screenKey: key,
                                      pointer: point, now: input.now())
        guard next != dwell else { return }
        endDwell()
        dwell = next
        if let next { scheduleDwell(next, after: DividerDwell.delay) }
    }

    private func dividerHandles(on screen: NSScreen) -> [Layout.DividerHandle] {
        let info = ScreenIdentity.info(for: screen)
        return Layout.dividerHandles(configProvider().layout(forKey: info.key),
            container: Layout.rootContainer(frame: screen.frame, visibleFrame: screen.visibleFrame),
            pixelsWide: info.pixelsWide, thickness: 24)
    }

    private func scheduleDwell(_ pending: DividerDwell, after delay: TimeInterval) {
        cancelDwell = input.schedule(delay) { [weak self] in
            MainActor.assumeIsolated { self?.dwellElapsed(pending) }
        }
    }

    private func endDwell() {
        cancelDwell?(); cancelDwell = nil
        dwell = nil
    }

    /// Everything that admitted the pause is read again here, because nothing reported the time
    /// in between: keys, scrolls and modifier changes are judged by their age, not by a monitor.
    private func dwellElapsed(_ pending: DividerDwell) {
        guard dwell == pending else { return }
        cancelDwell = nil
        let point = input.pointer()
        guard monitor != nil, canInteract(), input.isTrusted(), canEditLayout(), triggerMatches(input.modifiers()),
              SnapMemory.shared.recovery.isEmpty, input.pressedButtons() == 0,
              captured == nil, dragStart == nil, dividerSession == nil, gripPhase == nil,
              let screen = screenContaining(point) else { endDwell(); return }
        let handles = dividerHandles(on: screen)
        let handle = DividerGrip.handle(at: point, in: handles)
        switch pending.verdict(handle: handle, screenKey: ScreenIdentity.info(for: screen).key, pointer: point,
                               now: input.now(), interruptionAges: DividerDwell.interruptions.map(input.secondsSince)) {
        case .drop: endDwell()
        case .wait(let remaining): scheduleDwell(pending, after: remaining)
        case .reveal:
            dwell = nil
            if let handle { revealGrip(handle, on: screen, at: point) }
        }
    }

    private func revealGrip(_ handle: Layout.DividerHandle, on screen: NSScreen, at point: CGPoint) {
        guard let rect = DividerGrip.rect(for: handle, pointer: point) else { return }
        let panel = grip ?? DividerGripPanel(
            bindHeld: { [weak self] in self.map { $0.triggerMatches($0.input.modifiers()) } ?? false },
            activationKey: { [weak self] in self?.triggerProvider().keyCode.map { UInt16($0) } },
            isKeyDown: { [weak self] in self?.input.isKeyDown($0) == true },
            input: { [weak self] in self?.sendGrip($0) })
        grip = panel
        gripScreen = screen; gripHandle = handle
        gripPhase = .revealed
        panel.place(rect, axis: handle.axis, line: DividerGrip.segment(for: handle))
        panel.apply(.revealed)
        watchInput()
    }

    private func beginDivider() {
        guard canInteract(), let screen = gripScreen, let handle = gripHandle,
              SnapMemory.shared.recovery.isEmpty else { cancelDivider(); return }
        let display = display(for: screen)
        var records = SnapMemory.shared.records
        let bound = records.entries.filter { $0.placement?.screenKey == display.key }
        let visible = bound.isEmpty ? [] : visibleWindows(WindowMover.pids(of: bound.map(\.window)))
        let frozen = bound.map { ($0, WindowMover.observe($0, in: visible)) }
        for (entry, observation) in frozen where observation == .excluded {
            records.bind(entry.window, placement: nil)
        }
        let root = configProvider().layout(forKey: display.key)
        dividerSession = DividerSession(screen: screen, display: display, old: root, handle: handle,
                                        records: records, frozen: frozen, proposed: root, effects: [])
    }

    private func previewDivider(at point: CGPoint, useGuides: Bool = true) {
        guard var session = dividerSession else { return }
        let h = session.handle
        let length = h.axis == .vertical ? h.container.width : h.container.height
        let proposed = h.axis == .vertical ? (point.x - h.container.minX) / length
            : (h.container.maxY - point.y) / length
        guard case let .split(_, boundaries, _) = session.old.node(at: h.path),
              boundaries.indices.contains(h.index) else { cancelDivider(); return }
        func fraction(_ boundary: Boundary) -> Double {
            boundary.distance(alongLength: length, pixelsTotal: session.display.pixelsWide) / length
        }
        let lower = h.index > 0 ? fraction(boundaries[h.index - 1]) : 0
        let upper = h.index + 1 < boundaries.count ? fraction(boundaries[h.index + 1]) : 1
        let snapped = DividerSnap.apply(Double(proposed), guides: DividerSnap.guides(neighborLower: lower,
            neighborUpper: upper), threshold: useGuides ? Double(6 / length) : 0)
        session.proposed = LayoutEdit.setDivider(session.old, at: h.path, index: h.index,
            fraction: snapped.fraction, rootPixelsWide: session.display.pixelsWide, containerLength: Double(length))
        if session.proposed == dividerSession?.proposed { return }
        let effects = ZoneScene.divider(records: session.records, screen: session.display,
                                       old: session.old, new: session.proposed)
        session.effects = session.frozen.contains { entry, observation in
            observation == .unresolved && effects.contains { CFEqual($0.window, entry.window) }
        } ? [] : effects
        dividerSession = session
        while previews.count > session.effects.count { previews.removeLast().orderOut(nil) }
        while previews.count < session.effects.count { previews.append(HighlightWindow(style: .divider)) }
        for (preview, effect) in zip(previews, session.effects) {
            preview.show(at: effect.after, hint: nil, below: grip?.lineWindow)
        }
        if let updated = Layout.dividerHandles(session.proposed,
            container: Layout.rootContainer(frame: session.display.frame, visibleFrame: session.display.visibleFrame),
            pixelsWide: session.display.pixelsWide).first(where: { $0.path == h.path && $0.index == h.index }), let grip {
            var rect = grip.frame
            if h.axis == .vertical { rect.origin.x = updated.line.midX - rect.width / 2 }
            else { rect.origin.y = updated.line.midY - rect.height / 2 }
            grip.move(to: rect)
            let realized = h.axis == .vertical ? (updated.line.midX - h.container.minX) / length
                : (h.container.maxY - updated.line.midY) / length
            let tolerance = 0.5 / CGFloat(session.display.pixelsWide)
            grip.showGuide(abs(realized - snapped.fraction) <= tolerance ? snapped.guide?.label : nil)
        }
    }

    private func nudgeDivider(_ delta: CGFloat) {
        guard let session = dividerSession,
              let current = Layout.dividerHandles(session.proposed,
                container: Layout.rootContainer(frame: session.display.frame, visibleFrame: session.display.visibleFrame),
                pixelsWide: session.display.pixelsWide).first(where: { $0.path == session.handle.path && $0.index == session.handle.index })
        else { return }
        let scale = CGFloat(session.display.pixelsWide) / session.display.frame.width
        let point = session.handle.axis == .vertical
            ? CGPoint(x: current.line.midX + delta / scale, y: current.line.midY)
            : CGPoint(x: current.line.midX, y: current.line.midY + delta / scale)
        previewDivider(at: point, useGuides: false)
    }

    private func finishDivider() {
        guard let session = dividerSession else { cancelDivider(); return }
        let anchor = grip.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? input.pointer()
        cancelDivider()
        guard session.proposed != session.old, canInteract() else { return }
        let windows = session.frozen.map { $0.0.window }
        let visible = windows.isEmpty ? [] : visibleWindows(WindowMover.pids(of: windows))
        let affected = ZoneScene.divider(records: session.records, screen: session.display,
                                         old: session.old, new: session.proposed)
        let resolved = session.frozen.allSatisfy { entry, observation in
            let current = WindowMover.observe(entry, in: visible)
            if observation == .unresolved && affected.contains(where: { CFEqual($0.window, entry.window) }) { return false }
            return current == observation
        }
        let outcome: Outcome = resolved
            ? commitDivider(session.screen, session.old, session.proposed, session.effects) : .rejected
        showNotice(outcome, context: .divider, anchor: anchor, screen: session.screen)
    }

    private func showNotice(_ outcome: Outcome, context: ZoneNotice.Context, anchor: CGPoint, screen: NSScreen) {
        var appName: String?
        if case .rolledBack(.refused(let window)) = outcome {
            var pid: pid_t = 0
            if AXUIElementGetPid(window, &pid) == .success {
                appName = NSRunningApplication(processIdentifier: pid)?.localizedName
            }
        }
        guard let text = ZoneNotice.text(for: outcome, context: context, appName: appName) else { return }
        let panel = notice ?? ZoneNoticePanel()
        notice = panel
        panel.show(title: text.title, detail: text.detail, near: anchor,
                   visible: (screenContaining(anchor) ?? screen).visibleFrame)
    }


    private func releaseShare(_ plan: SharePlan, window win: AXUIElement) {
        let anchor = input.pointer()
        let display = display(for: plan.screen)
        let zone = plan.incumbent.placement?.zoneIndex
        let occupants = SnapMemory.shared.records.entries.filter {
            $0.placement?.screenKey == display.key && $0.placement?.layout == plan.root && $0.placement?.zoneIndex == zone
        }
        let outcome: Outcome
        if let zone, let before = WindowMover.frame(of: win), isCurrent(display),
           let incumbent = ZoneScene.shareIncumbent(currentShareRecords(excluding: win, among: occupants),
                                                   screen: display, layout: plan.root, zoneIndex: zone, isCurrent: { _ in true }),
           CFEqual(incumbent.window, plan.incumbent.window),
           let effects = ZoneScene.share(incoming: win, before: before, incumbent: incumbent,
                                         target: plan.target, screen: display) {
            outcome = WindowMover.commit(effects, validate: { [self] in
                canInteract() && configProvider().layout(forKey: display.key) == plan.root && isCurrent(display)
            }, persist: {})
        } else {
            outcome = .rejected
        }
        refreshStatus()
        if outcome.isCommitted {
            onPlacement(win, plan.screen, plan.incomingRect)
            offerFill(after: plan.incomingRect, on: plan.screen, source: win)
        } else {
            showNotice(outcome, context: .share, anchor: anchor, screen: plan.screen)
        }
    }


    private func cancelFill() {
        fillGeneration = UUID()
        fillTask?.cancel(); fillTask = nil
        fillCapture?.cancel(); fillCapture = nil
        offerTimeout?.invalidate(); offerTimeout = nil
        if let outsideMonitor { input.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        if let localOutsideMonitor { NSEvent.removeMonitor(localOutsideMonitor); self.localOutsideMonitor = nil }
        fillPanel?.orderOut(nil); fillPanel = nil
        fillCandidates.removeAll(); fillOffer = nil
        stopInputWatchIfIdle()
    }

    private func offerFill(after target: CGRect, on screen: NSScreen, source: AXUIElement) {
        cancelFill()
        guard assistAllowed(), canInteract(), SnapMemory.shared.recovery.isEmpty,
              let visible = visibleWindows(nil) else { return }
        let display = display(for: screen)
        let root = configProvider().layout(forKey: display.key)
        let zones = Layout.zones(root, frame: screen.frame, visibleFrame: screen.visibleFrame, pixelsWide: display.pixelsWide)
        guard let free = ZoneVacancy.destination(zones: zones, filled: target, visibleFrames: visible.map(\.frame)),
              visible.contains(where: { $0.window.map { !CFEqual($0, source) } == true })
        else { return }
        let offer = FillOffer(screen: screen, display: display, root: root, destination: free, source: source, filled: target)
        fillOffer = offer
        watchInput()
        watchOutsideClicks()
        let generation = fillGeneration
        fillTask = Task { [weak self] in
            guard let self else { return }
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard self.fillGeneration == generation else { return }
            guard let content, self.fillIsCurrent(generation), !Task.isCancelled,
                  let current = self.visibleWindows(nil),
                  ZoneVacancy.isFree(offer.destination, visibleFrames: current.map(\.frame)) else { self.cancelFill(); return }
            let matched = visible.compactMap { candidate -> (WindowMover.VisibleWindow, SCWindow)? in
                guard let window = candidate.window, !CFEqual(window, offer.source), self.isUnchanged(candidate, in: current),
                      let sc = content.windows.first(where: { $0.windowID == candidate.id && $0.isOnScreen
                        && $0.owningApplication?.processID == candidate.pid }),
                      WindowIdentityGeometry.matches(surface: Coord.cocoaRect(fromAX: sc.frame,
                        primaryMaxY: NSScreen.screens.first?.frame.maxY ?? 0), accessibility: candidate.frame) else { return nil }
                return (candidate, sc)
            }
            var ids: Set<CGWindowID> = []
            let candidates = Array(matched.filter { ids.insert($0.0.id).inserted }.prefix(32))
            guard !candidates.isEmpty else { self.cancelFill(); return }
            self.presentFill(candidates.map { $0.0 }, for: offer)
            for (index, candidate) in candidates.enumerated() {
                guard self.fillIsCurrent(generation), !Task.isCancelled else { return }
                let capture = SingleFrameCapture()
                self.fillCapture = capture
                let size = ThumbnailSize.fit(candidate.1.frame.size, maximum: CGSize(width: 312, height: 192))
                let image = try? await capture.capture(filter: SCContentFilter(desktopIndependentWindow: candidate.1),
                                                      width: Int(size.width), height: Int(size.height))
                guard self.fillGeneration == generation else { return }
                guard self.fillIsCurrent(generation), !Task.isCancelled,
                      let after = self.visibleWindows(nil),
                      ZoneVacancy.isFree(offer.destination, visibleFrames: after.map(\.frame)),
                      self.isUnchanged(candidate.0, in: after)
                else { self.cancelFill(); return }
                self.fillCapture = nil
                self.fillPanel?.setThumbnail(image, at: index)
            }
            self.fillTask = nil
        }
    }

    private func presentFill(_ candidates: [WindowMover.VisibleWindow], for offer: FillOffer) {
        fillCandidates = candidates
        let panel = ZoneFillPanel(select: { [weak self] index in self?.selectFill(index) },
                                  cancel: { [weak self] in self?.cancelFill() })
        panel.show(candidates.map { candidate in
            let center = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            let other = screen.map { ScreenIdentity.info(for: $0).key != offer.display.key } ?? false
            return ZoneFillPanel.Candidate(app: candidate.appName, title: candidate.title,
                display: other ? screen?.localizedName : nil,
                icon: NSRunningApplication(processIdentifier: candidate.pid)?.icon)
        }, free: offer.destination, filled: offer.filled, visible: offer.screen.visibleFrame)
        fillPanel = panel
        scheduleFillTimeout()
    }

    private func watchOutsideClicks() {
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: presses) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.fillPanel { self?.cancelFill() }
            }
            return event
        }
        outsideMonitor = input.addGlobalMonitor(presses) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelFill() }
        }
    }

    private func scheduleFillTimeout() {
        offerTimeout = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.fillPanel else { return }
                self.offerTimeout = nil
                if Self.fillInUse(loading: self.fillTask != nil, focused: panel.isKeyWindow, frame: panel.frame, input: self.input) {
                    self.scheduleFillTimeout()
                } else {
                    self.cancelFill()
                }
            }
        }
    }

    /// Typing never reaches the unfocused chooser, so global input ages tell whether the pointer came
    /// back to choose: it moved or scrolled no earlier than the last key press. A pointer resting on
    /// the chooser while someone types elsewhere does not hold it, and an unreadable age never does.
    static func fillInUse(loading: Bool, focused: Bool, frame: CGRect, input: DragSnapInput) -> Bool {
        if loading || focused { return true }
        guard frame.contains(input.pointer()) else { return false }
        let key = input.secondsSince(.keyDown)
        return [CGEventType.mouseMoved, .scrollWheel].contains { input.secondsSince($0) <= key }
    }

    private func fillIsCurrent(_ generation: UUID) -> Bool {
        guard fillGeneration == generation, canInteract(), assistAllowed(), SnapMemory.shared.recovery.isEmpty,
              let offer = fillOffer, configProvider().layout(forKey: offer.display.key) == offer.root else { return false }
        return isCurrent(offer.display)
    }

    private func isUnchanged(_ candidate: WindowMover.VisibleWindow, in current: [WindowMover.VisibleWindow]) -> Bool {
        guard let window = candidate.window else { return false }
        return current.contains { $0.id == candidate.id && $0.pid == candidate.pid
            && $0.window.map { CFEqual($0, window) } == true
            && SnapRecords<AXUIElement>.matches($0.frame, candidate.frame, originTolerance: 1, sizeTolerance: 1) }
    }

    private func selectFill(_ index: Int) {
        let generation = fillGeneration
        guard fillIsCurrent(generation), let offer = fillOffer, fillCandidates.indices.contains(index),
              let window = fillCandidates[index].window, !CFEqual(window, offer.source),
              let current = visibleWindows(nil), isUnchanged(fillCandidates[index], in: current),
              ZoneVacancy.isFree(offer.destination, visibleFrames: current.map(\.frame)),
              let before = WindowMover.frame(of: window) else { cancelFill(); return }
        let placement = AppZonePlacement(screenKey: offer.display.key, layout: offer.root, target: offer.destination,
            frame: offer.display.frame, visibleFrame: offer.display.visibleFrame, pixelsWide: offer.display.pixelsWide)
        let outcome = WindowMover.commit([FrameEffect(window: window, before: before, after: offer.destination, placement: placement)],
                                         validate: { [self] in fillIsCurrent(generation) }, persist: {})
        cancelFill()
        if outcome.isCommitted { onPlacement(window, offer.screen, offer.destination) }
        else { showNotice(outcome, context: .fill, anchor: input.pointer(), screen: offer.screen) }
        refreshStatus()
    }

    private func sampleDragCandidate(at point: CGPoint) {
        guard dragCandidate == nil else { return }
        guard let window = WindowMover.window(atCocoaPoint: point),
              let frame = WindowMover.frame(of: window)
        else {
            preArmFrameChecks += 1
            return
        }
        dragCandidate = (
            window,
            frame,
            point,
            DragSnapWindowMotion.isLikelyWindowMoveStart(point: point, windowFrame: frame)
        )
        preArmFrameChecks = 0
    }

    private func movingWindowCandidate(at point: CGPoint) -> AXUIElement? {
        if let captured { return captured }
        guard preArmFrameChecks < Self.maxPreArmFrameChecks else { return nil }
        if dragCandidate == nil {
            sampleDragCandidate(at: point)
            return nil
        }
        guard let candidate = dragCandidate else { return nil }
        preArmFrameChecks += 1
        guard let current = WindowMover.frame(of: candidate.window) else {
            preArmFrameChecks = Self.maxPreArmFrameChecks
            return nil
        }
        switch DragSnapWindowMotion.classify(start: candidate.startFrame, current: current) {
        case .moved:
            return candidate.window
        case .resized:
            preArmFrameChecks = Self.maxPreArmFrameChecks
            return nil
        case .stationary:
            if candidate.startedInMoveBand,
               hypot(point.x - candidate.startPoint.x, point.y - candidate.startPoint.y) > 6 {
                return candidate.window
            }
            return nil
        }
    }

    // MARK: - Unsnap restore

    /// If the dragged window is one we snapped, give it back its pre-snap size under the
    /// cursor once the drag is real. Works for plain drags and modifier-drags alike —
    /// dragging away IS the undo.
    private func maybeRestoreUnsnappedSize() {
        guard !restoreChecked, !SnapMemory.shared.isEmpty, let start = dragStart else { return }
        let p = input.pointer()

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
        // can report a stale frame across several events. Allow a short grace period
        // independent of event rate, with spaced AX reads to bound work on content drags.
        guard hypot(p.x - start.x, p.y - start.y) > 10 else { return }
        let now = input.now()
        if let sampling = restoreSampling {
            guard now < sampling.deadline else { restoreChecked = true; return }
            guard now - sampling.lastSample >= Self.restoreSampleInterval else { return }
            restoreSampling = (sampling.deadline, now)
        } else {
            restoreSampling = (now + Self.restoreGrace, now)
        }
        guard let c = restoreCandidate, let current = WindowMover.frame(of: c.window)
        else { restoreChecked = true; return }
        if abs(current.width - c.frameAtMatch.width) > 4 ||
           abs(current.height - c.frameAtMatch.height) > 4 {
            restoreChecked = true // size changed: definitively a resize, never an unsnap
            return
        }
        guard hypot(current.minX - c.frameAtMatch.minX, current.minY - c.frameAtMatch.minY) > 5 else { return }
        restoreChecked = true
        let restored = UnsnapRestore.frame(preSize: c.preFrame.size, current: current, cursor: p)
        WindowMover.restoreDuringDrag(c.window, toCocoaRect: restored)
    }

    // MARK: - Highlight

    private func currentZoneRect() -> CGRect? {
        let p = input.pointer()
        guard let screen = screenContaining(p) else { return nil }
        let info = ScreenIdentity.info(for: screen)
        targetScreenKey = info.key
        let root = configProvider().layout(forKey: info.key)
        // The leaf zone whose rect contains the cursor; fall back to the nearest by center.
        let zones = Layout.zones(root, frame: screen.frame, visibleFrame: screen.visibleFrame, pixelsWide: info.pixelsWide)
        if let hit = zones.first(where: { $0.contains(p) }) { return hit }
        return zones.min(by: { hypot($0.midX - p.x, $0.midY - p.y) < hypot($1.midX - p.x, $1.midY - p.y) })
    }

    private func updateHighlight() {
        guard let zone = currentZoneRect() else { hideHighlight(); return }
        let ordinary = DragTarget.rect(zone: zone, cursor: input.pointer())
        let target = updateShare(zone: zone) ?? ordinary
        trackLinger(zone: zone, targetingHalf: target != zone)
        if target == lastTargetRect, highlight != nil { return } // unchanged — skip redraw
        lastTargetRect = target
        if highlight == nil { highlight = HighlightWindow() }
        highlight?.show(at: target, hint: hintShown && target == zone ? HighlightWindow.halfHint : nil)
        // A tactile tick each time the target changes (zone to zone, zone to half, half to
        // quarter) — trackpads only, free elsewhere. You feel the snap before you drop it.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    private func updateShare(zone: CGRect) -> CGRect? {
        sharePlan = nil
        sharePreview?.orderOut(nil)
        guard let key = targetScreenKey,
              let screen = NSScreen.screens.first(where: { ScreenIdentity.info(for: $0).key == key }),
              let incoming = captured else { shareRail?.orderOut(nil); return nil }
        let display = display(for: screen)
        let root = configProvider().layout(forKey: key)
        let zones = Layout.zones(root, frame: screen.frame, visibleFrame: screen.visibleFrame, pixelsWide: display.pixelsWide)
        guard let index = zones.firstIndex(of: zone), SnapMemory.shared.recovery.isEmpty,
              let incumbent = ZoneScene.shareIncumbent(shareRecords, screen: display, layout: root,
                                                       zoneIndex: index, isCurrent: { _ in true }) else {
            shareRail?.orderOut(nil)
            _ = shareEntry.update(targets: [], cursor: input.pointer())
            return nil
        }
        let targets = ShareTarget.targets(in: zone)
        if shareRail == nil { shareRail = ShareRailPanel() }
        let selected = shareEntry.update(targets: targets, cursor: input.pointer())
        shareRail?.show(targets: targets, active: selected)
        guard let selected,
              let effects = ZoneScene.share(incoming: incoming, before: .zero, incumbent: incumbent, target: selected,
                                            screen: display),
              let last = effects.last else { return nil }
        if sharePreview == nil { sharePreview = HighlightWindow(style: .neighbor) }
        sharePreview?.show(at: effects[0].after, hint: nil)
        sharePlan = SharePlan(screen: screen, root: root, incumbent: incumbent, target: selected, incomingRect: last.after)
        return last.after
    }

    /// Arm/refresh the linger timer per zone; once it fires, the hint rides along with the
    /// highlight until the user targets a half or leaves the zone.
    private func trackLinger(zone: CGRect, targetingHalf: Bool) {
        if targetingHalf { clearLinger(); return }
        if zone != lingerZone {
            lingerZone = zone
            // First-ever modifier-drag: show the hint right away (updateHighlight draws it on this
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
                MainActor.assumeIsolated {
                    guard let self, self.armed, self.lingerZone == zone else { return }
                    self.hintShown = true
                    if let target = self.lastTargetRect, target == zone {
                        self.highlight?.show(at: target, hint: HighlightWindow.halfHint)
                    }
                }
            }
        }
    }

    /// The half/quarter edge snap is delightful but hidden: today you only meet it by lingering.
    /// Teach it ONCE. On the user's first-ever modifier-drag, surface the hint immediately; after
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
        shareRail?.orderOut(nil); sharePreview?.orderOut(nil)
        sharePlan = nil
        shareEntry = ShareEntry()
        highlight?.orderOut(nil)
        lastTargetRect = nil
        targetScreenKey = nil
        clearLinger()
    }

    private func reset() {
        shareRail?.orderOut(nil); shareRail = nil
        sharePreview?.orderOut(nil); sharePreview = nil
        sharePlan = nil; shareRecords.removeAll(); shareEntry = ShareEntry()
        captured = nil
        armed = false
        dragCandidate = nil
        preArmFrameChecks = 0
        teachHint = false
        highlight?.orderOut(nil)
        highlight = nil
        lastTargetRect = nil
        targetScreenKey = nil
        clearLinger()
        dragStart = nil
        restoreChecked = false
        restoreCandidate = nil
        restoreSampling = nil
        stopInputWatchIfIdle()
    }

    private func screenContaining(_ p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }
}


/// Translucent, click-through block highlight. The window frame IS the highlighted target;
/// an optional one-line hint teaches the half-snap when the user lingers.
@MainActor
final class HighlightWindow: NSWindow {
    /// `divider` draws the neighbor tone 3 points inside its exact frame, so the moving line
    /// between two previews stays visible. The window frame itself is never inset.
    enum Style { case target, neighbor, divider }
    static let halfHint = "Edges fill half, corners a quarter"

    private let hintLabel = NSTextField(labelWithString: HighlightWindow.halfHint)
    private let hintPill = NSView()
    private let fill = NSView()
    private let inset: CGFloat

    init(style: Style = .target) {
        inset = style == .divider ? 3 : 0
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true   // never interfere with the drag
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let v = fill
        v.wantsLayer = true
        v.layer?.backgroundColor = Brand.blue.withAlphaComponent(style == .target ? 0.22 : 0.12).cgColor
        v.layer?.borderColor = Brand.blue.withAlphaComponent(style == .target ? 0.95 : 0.55).cgColor
        v.layer?.borderWidth = style == .target ? 3 : 1.5
        v.layer?.cornerRadius = 14

        hintLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hintLabel.textColor = .white
        hintLabel.alignment = .center
        // The capsule is its own view: a label's layer background sat the text at the top of a
        // taller box. Inside a separate pill the text is centred on both axes.
        hintPill.wantsLayer = true
        hintPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hintPill.isHidden = true
        hintPill.addSubview(hintLabel)
        v.addSubview(hintPill)
        let content = NSView()
        content.addSubview(v)
        contentView = content
    }

    func show(at rect: CGRect, hint: String?, below: NSWindow? = nil) {
        prepare(at: rect, hint: hint)
        if let below, below.isVisible { order(.below, relativeTo: below.windowNumber) }
        else { orderFront(nil) }
    }

    func prepare(at rect: CGRect, hint: String?) {
        fill.frame = CGRect(origin: .zero, size: rect.size).insetBy(dx: inset, dy: inset)
        setFrame(rect, display: true)
        if let hint {
            hintLabel.stringValue = hint
            hintLabel.sizeToFit()
            let text = hintLabel.frame.size
            let w = ceil(text.width) + 24, h = ceil(text.height) + 10
            // The pill must sit fully INSIDE the highlight; in a zone too small or narrow
            // to host it cleanly, show nothing rather than something clipped.
            if rect.width < w + 16 || rect.height < h + 26 {
                hintPill.isHidden = true
            } else {
                let y = min(18, max(6, rect.height - h - 6))
                hintPill.frame = NSRect(x: (rect.width - w) / 2, y: y, width: w, height: h)
                hintPill.layer?.cornerRadius = h / 2
                hintLabel.frame = NSRect(x: (w - text.width) / 2, y: (h - text.height) / 2,
                                         width: text.width, height: text.height)
                hintPill.isHidden = false
            }
        } else {
            hintPill.isHidden = true
        }
    }
}
