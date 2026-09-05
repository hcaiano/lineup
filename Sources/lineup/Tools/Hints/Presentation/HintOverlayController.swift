import AppKit
import HintsCore

/// Owns every Hints overlay panel, including ordering, key-window capture, animation, topology
/// invalidation, and teardown. It never activates Lineup and has no dependency on shared app
/// activation state.
@MainActor
final class HintOverlayController {
    private struct Surface {
        var descriptor: HintPresentationScreenDescriptor
        var panel: HintOverlayPanel
        var canvas: HintCanvasView
    }

    private struct InstalledResponder {
        var view: NSView
        var frame: NSRect
        var alphaValue: CGFloat
        var isHidden: Bool
        var autoresizingMask: NSView.AutoresizingMask
    }

    /// Set by Phase 3. Display changes hide every panel before this callback is delivered, so the
    /// session can only cancel or begin a separately captured context.
    var onInvalidated: ((HintOverlayInvalidation) -> Void)?

    private var surfaces: [Surface] = []
    private var currentKey: HintSessionKey?
    private var currentTargetPID: pid_t?
    private var latestSeenKey: HintSessionKey?
    private var animationRevision: UInt64 = 0
    private var installedResponder: InstalledResponder?
    private var capturePanel: HintOverlayPanel?
    private var captureLostHandler: (() -> Void)?
    private var captureObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    init() {}

    /// Shows a count/content-free state such as scanning or a permission warning. `false` means
    /// Presentation could not prove the supplied global screens map to the current NSScreens or
    /// could not preserve the captured frontmost process; the caller must cancel the session.
    @discardableResult
    func show(
        generation key: HintSessionKey,
        context: HintTargetContext,
        screens: [NSScreen],
        status: HintOverlayStatus = .scanning
    ) -> Bool {
        render(generation: key, context: context, screens: screens, snapshot: nil, status: status)
    }

    /// Draws the core-authoritative visible pool. Presentation assigns each candidate with
    /// `HintOverlayGeometry`; it never repeats filtering/search decisions from HintsCore.
    @discardableResult
    func update(
        snapshot: HintPresentationSnapshot,
        context: HintTargetContext,
        screens: [NSScreen],
        status: HintOverlayStatus = .active
    ) -> Bool {
        let resolvedStatus = status == .active && snapshot.visible.isEmpty ? .noMatches : status
        return render(
            generation: snapshot.key,
            context: context,
            screens: screens,
            snapshot: snapshot,
            status: resolvedStatus
        )
    }

    /// Changes only the visual state of the live generation. This is intentionally immediate: key
    /// filtering and state changes do not replay entrance motion or move panels.
    @discardableResult
    func transition(to status: HintOverlayStatus, generation key: HintSessionKey) -> Bool {
        guard currentKey == key else { return false }
        animationRevision &+= 1
        surfaces.forEach { $0.canvas.transition(to: status) }
        return true
    }

    /// Generation-keyed and idempotent. Capture ends synchronously so no input can leak while the
    /// short visual fade is completing; an old generation can never hide a newer one.
    ///
    /// Phase 3 effect ordering: Input relinquishes expected capture first
    /// (`HintInputController.relinquishExpectedCapture()`), THEN Presentation hides here, then
    /// AX invokes. Hiding itself is always safe: `removeInputResponder()` takes down the
    /// didResign observer before it resigns the panel, so an expected hide can never fire the
    /// capture-loss path below.
    func hide(generation key: HintSessionKey) {
        guard currentKey == key else { return }
        currentKey = nil
        currentTargetPID = nil
        removeInputResponder()
        endActiveObservation()
        animationRevision &+= 1
        let revision = animationRevision
        guard surfaces.contains(where: { $0.panel.isVisible }) else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeOut)
            surfaces.forEach { $0.panel.animator().alphaValue = 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.animationRevision == revision,
                      self.currentKey == nil
                else { return }
                self.surfaces.forEach { $0.panel.orderOut(nil) }
            }
        }
    }

    /// Immediate, repeatable lifecycle teardown for tool disable and app termination.
    func stop() {
        animationRevision &+= 1
        currentKey = nil
        currentTargetPID = nil
        latestSeenKey = nil
        removeInputResponder()
        endActiveObservation()
        surfaces.forEach {
            $0.panel.alphaValue = 0
            $0.panel.orderOut(nil)
            $0.panel.contentView = nil
        }
        surfaces.removeAll()
    }

    /// Installs the Input lane's invisible responder into the deterministic first participating
    /// panel, makes that nonactivating panel key, and verifies both key and first-responder state.
    /// A `false` result is failed capture and does not invoke `onCaptureLost`; a later verified loss
    /// removes capture, paints the uncertainty state if still visible, then invokes the callback.
    @discardableResult
    func installInputResponder(_ view: NSView, onCaptureLost: @escaping () -> Void) -> Bool {
        guard currentKey != nil,
              let currentTargetPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == currentTargetPID,
              !surfaces.isEmpty,
              view.acceptsFirstResponder,
              view.superview == nil,
              view.window == nil
        else { return false }

        removeInputResponder()
        let surface = surfaces.min { $0.descriptor.geometryIndex < $1.descriptor.geometryIndex }!
        let panel = surface.panel
        guard panel.isVisible else { return false }
        let frontmostPID = currentTargetPID

        let installed = InstalledResponder(
            view: view,
            frame: view.frame,
            alphaValue: view.alphaValue,
            isHidden: view.isHidden,
            autoresizingMask: view.autoresizingMask
        )
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        view.alphaValue = 0
        view.isHidden = false
        view.autoresizingMask = []
        view.setAccessibilityElement(false)
        view.setAccessibilityChildren([])
        panel.contentView?.addSubview(view)
        panel.contentView?.setAccessibilityChildren([])

        panel.makeKey()
        let becameResponder = panel.makeFirstResponder(view)
        let keptFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID
        guard becameResponder, panel.isKeyWindow, panel.firstResponder === view, keptFrontmost else {
            panel.makeFirstResponder(nil)
            panel.resignKey()
            restore(installed)
            return false
        }

        installedResponder = installed
        capturePanel = panel
        captureLostHandler = onCaptureLost
        captureObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.captureWasLost() }
        }
        return true
    }

    /// Idempotent explicit capture removal, silent and safe to call repeatedly (hide, fail-closed,
    /// stop, topology replacement). The didResign observer is removed FIRST, before resigning the
    /// panel, so the expected hide cannot report a capture loss. This path never reports a loss.
    /// Unexpected resign — before this runs and while the observer is installed — reports exactly
    /// one loss (`captureWasLost()` guards on `installedResponder`, then clears it).
    func removeInputResponder() {
        if let captureObserver {
            NotificationCenter.default.removeObserver(captureObserver)
            self.captureObserver = nil
        }
        let installed = installedResponder
        let panel = capturePanel
        installedResponder = nil
        capturePanel = nil
        captureLostHandler = nil
        panel?.makeFirstResponder(nil)
        panel?.resignKey()
        if let installed { restore(installed) }
    }

    private func render(
        generation key: HintSessionKey,
        context: HintTargetContext,
        screens: [NSScreen],
        snapshot: HintPresentationSnapshot?,
        status: HintOverlayStatus
    ) -> Bool {
        guard snapshot?.key == nil || snapshot?.key == key else { return false }
        guard mayAccept(key) else { return false }
        latestSeenKey = key

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid,
              let descriptors = screenDescriptors(context: context, screens: screens),
              !descriptors.isEmpty,
              let contents = canvasContents(
                generation: key,
                snapshot: snapshot,
                status: status,
                context: context,
                screenCount: descriptors.count
              )
        else {
            failClosed()
            return false
        }

        let sameTopology = surfaces.map(\.descriptor) == descriptors
        if !surfaces.isEmpty, !sameTopology, currentKey != nil {
            failClosed()
            return false
        }
        if !sameTopology {
            replaceSurfaces(with: descriptors)
        }

        let previousKey = currentKey
        if let previousKey, previousKey.id != key.id { removeInputResponder() }
        currentKey = key
        currentTargetPID = context.pid
        animationRevision &+= 1
        beginActiveObservation()

        for index in surfaces.indices {
            surfaces[index].panel.setFrame(descriptors[index].panelFrame, display: true)
            surfaces[index].canvas.update(contents[index])
        }

        let shouldMaterialize = previousKey == nil || surfaces.contains { !$0.panel.isVisible }
        for surface in surfaces where !surface.panel.isVisible {
            surface.panel.alphaValue = 0
            surface.panel.orderFrontRegardless()
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else {
            failClosed()
            return false
        }

        if shouldMaterialize {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = HUDMotion.duration(HUDMotion.fadeIn)
                surfaces.forEach { $0.panel.animator().alphaValue = 1 }
            }
        } else {
            surfaces.forEach { $0.panel.alphaValue = 1 }
        }
        return true
    }

    private func mayAccept(_ key: HintSessionKey) -> Bool {
        guard let latestSeenKey else { return true }
        if key.id < latestSeenKey.id { return false }
        if key.id == latestSeenKey.id, key.generation < latestSeenKey.generation { return false }
        if key == latestSeenKey, currentKey == nil { return false }
        return true
    }

    private func replaceSurfaces(with descriptors: [HintPresentationScreenDescriptor]) {
        animationRevision &+= 1
        removeInputResponder()
        surfaces.forEach {
            $0.panel.alphaValue = 0
            $0.panel.orderOut(nil)
            $0.panel.contentView = nil
        }
        surfaces = descriptors.map { descriptor in
            let canvas = HintCanvasView(
                frame: NSRect(origin: .zero, size: descriptor.panelFrame.size),
                descriptor: descriptor
            )
            let panel = HintOverlayPanel(frame: descriptor.panelFrame, canvas: canvas)
            return Surface(descriptor: descriptor, panel: panel, canvas: canvas)
        }
    }

    private func canvasContents(
        generation key: HintSessionKey,
        snapshot: HintPresentationSnapshot?,
        status: HintOverlayStatus,
        context: HintTargetContext,
        screenCount: Int
    ) -> [HintCanvasContent]? {
        var candidates = Array(repeating: [HintCanvasCandidate](), count: screenCount)
        if let snapshot {
            for labelled in snapshot.visible {
                let frame = labelled.candidate.frame
                guard HintOverlayGeometry.validity(of: frame) == .valid,
                      let index = HintOverlayGeometry.displayIndex(for: frame, screens: context.screens),
                      candidates.indices.contains(index)
                else { return nil }
                candidates[index].append(HintCanvasCandidate(
                    label: labelled.label,
                    frame: frame,
                    isSelected: labelled.candidate.token == snapshot.selectedToken
                ))
            }
        }

        return candidates.map { displayCandidates in
            HintCanvasContent(
                key: key,
                status: status,
                mode: snapshot?.mode ?? .labels,
                query: snapshot?.query ?? "",
                candidates: displayCandidates,
                visibleCount: snapshot?.visible.count ?? 0,
                totalCandidates: snapshot?.totalCandidates ?? 0,
                isTruncated: snapshot?.truncated ?? false
            )
        }
    }

    private func screenDescriptors(
        context: HintTargetContext,
        screens: [NSScreen]
    ) -> [HintPresentationScreenDescriptor]? {
        guard !context.screens.isEmpty,
              let primaryScreen = screens.first
        else { return nil }
        // Use the caller's per-activation screen snapshot throughout this conversion. Re-reading
        // live screen order here could mix a changed topology with the captured Hints context.
        let primaryMaxY = primaryScreen.frame.maxY

        struct AvailableScreen {
            var order: Int
            var number: UInt32
            var screen: NSScreen
            var geometryFrame: HintRect
        }

        let numberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let available: [AvailableScreen] = screens.enumerated().map { order, screen in
            let number = (screen.deviceDescription[numberKey] as? NSNumber)?.uint32Value
                ?? UInt32(clamping: order + 1)
            return AvailableScreen(
                order: order,
                number: number,
                screen: screen,
                geometryFrame: HintPresentationGeometry.accessibilityScreenFrame(
                    from: screen.frame,
                    primaryMaxY: primaryMaxY
                )
            )
        }
        var usedOrders = Set<Int>()
        var descriptors: [HintPresentationScreenDescriptor] = []
        descriptors.reserveCapacity(context.screens.count)

        for (geometryIndex, geometryFrame) in context.screens.enumerated() {
            guard HintOverlayGeometry.validity(of: geometryFrame) == .valid else { return nil }
            let matches = available
                .filter {
                    !usedOrders.contains($0.order)
                        && HintPresentationGeometry.approximatelyEqual($0.geometryFrame, geometryFrame)
                }
                .sorted {
                    if $0.number != $1.number { return $0.number < $1.number }
                    return $0.order < $1.order
                }
            guard let match = matches.first else { return nil }
            usedOrders.insert(match.order)

            let frame = match.screen.frame
            let insets = match.screen.safeAreaInsets
            var safeFrame = NSRect(
                x: frame.minX + insets.left,
                y: frame.minY + insets.bottom,
                width: frame.width - insets.left - insets.right,
                height: frame.height - insets.top - insets.bottom
            ).intersection(frame)
            if safeFrame.isNull || safeFrame.isEmpty { safeFrame = frame }
            var visible = match.screen.visibleFrame.intersection(safeFrame)
            if visible.isNull || visible.isEmpty { visible = safeFrame }
            let visibleLocal = NSRect(
                x: visible.minX - frame.minX,
                y: visible.minY - frame.minY,
                width: visible.width,
                height: visible.height
            )
            descriptors.append(HintPresentationScreenDescriptor(
                geometryIndex: geometryIndex,
                screenNumber: match.number,
                geometryFrame: geometryFrame,
                safeGeometryFrame: HintPresentationGeometry.safeGeometryBounds(
                    screenFrame: frame,
                    safeFrame: safeFrame,
                    geometryFrame: geometryFrame
                ),
                panelFrame: frame,
                visibleLocalFrame: visibleLocal,
                backingScaleFactor: max(match.screen.backingScaleFactor, 1)
            ))
        }
        return descriptors
    }

    private func beginActiveObservation() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screenTopologyChanged() }
            }
        }
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.surfaces.forEach { $0.canvas.refreshAccessibilityPreferences() }
                }
            }
        }
    }

    private func endActiveObservation() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }

    private func screenTopologyChanged() {
        guard currentKey != nil else { return }
        failClosed()
        onInvalidated?(.displayTopologyChanged)
    }

    /// Sole verified-loss reporter for Presentation-owned key-window observation: removes
    /// capture first (observer already down), paints the uncertainty state if still visible,
    /// then invokes the callback exactly once. Guarded by `installedResponder`, so repeated
    /// resign notifications or a post-hide resign cannot re-report.
    private func captureWasLost() {
        guard installedResponder != nil else { return }
        let callback = captureLostHandler
        let key = currentKey
        removeInputResponder()
        if let key { _ = transition(to: .captureUncertain, generation: key) }
        callback?()
    }

    private func failClosed() {
        animationRevision &+= 1
        currentKey = nil
        currentTargetPID = nil
        removeInputResponder()
        endActiveObservation()
        surfaces.forEach {
            $0.panel.alphaValue = 0
            $0.panel.orderOut(nil)
        }
    }

    private func restore(_ installed: InstalledResponder) {
        installed.view.removeFromSuperview()
        installed.view.frame = installed.frame
        installed.view.alphaValue = installed.alphaValue
        installed.view.isHidden = installed.isHidden
        installed.view.autoresizingMask = installed.autoresizingMask
    }
}
