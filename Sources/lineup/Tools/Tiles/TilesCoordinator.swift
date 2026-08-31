import AppKit
import AppCore
import ApplicationServices
import Foundation
import TilesCore
import ZonesCore

@MainActor
final class TilesCoordinator: TilesCoordinatorProtocol {
    nonisolated(unsafe) private let windowSystem: TilesWindowSystem
    private let layoutSource: ZoneLayoutSource
    private let placementCenter: WindowPlacementCenter
    private let layoutMutationCenter: ZoneLayoutMutationCenter
    private let currentScreens: @MainActor () -> [LiveScreen]
    nonisolated(unsafe) private let journalStore: TilesRecoveryJournalStore
    private let runtimeQueue = DispatchQueue(label: "com.caiano.lineup.tiles.coordinator",
                                             qos: .userInitiated)

    private var screens: [LiveScreen] = []
    private var layouts = LayoutSnapshot()
    nonisolated(unsafe) private var session = TilesSession.empty
    nonisolated(unsafe) private var journal = RecoveryJournal()
    /// What the journal file already holds. Every write validates, encodes,
    /// fsyncs and renames, so an identical rewrite is pure cost.
    nonisolated(unsafe) private var lastPersistedJournal: RecoveryJournal?
    nonisolated(unsafe) private var recordKeys: [WindowToken: String] = [:]
    /// A freeform Zones action detaches a window for the rest of this Tiles
    /// session. Explicit Zone placement, a toggle back to tiled, or a close
    /// clears this runtime-only marker.
    nonisolated(unsafe) private var detachedTokens: Set<WindowToken> = []
    nonisolated(unsafe) private var acceptingEvents = false
    nonisolated(unsafe) private var runtimePauseReason: String?
    private var layoutObservation: ZoneLayoutObservation?
    private var placementObservation: WindowPlacementObservation?
    private var coalescedWork: [String: DispatchWorkItem] = [:]
    nonisolated(unsafe) private var healingWork: [DispatchWorkItem] = []

    private(set) var activeWorkspace = 1
    private(set) var recoveryRequired = false
    private(set) var stackPreview: TilesStackPreview?
    private(set) var runtimePauseMessage: String?
    var isCyclerRoutingActive: Bool { acceptingEvents }
    private var settings = TilesSettings()
    var onStateChange: (() -> Void)?
    var onPresentation: ((TilesPresentation) -> Void)?

    init(store: LineupAppConfigStore,
         placementCenter: WindowPlacementCenter,
         layoutMutationCenter: ZoneLayoutMutationCenter = ZoneLayoutMutationCenter(),
         windowSystem: TilesWindowSystem = AXWindowSystem(),
         journalStore: TilesRecoveryJournalStore = TilesRecoveryJournalStore(),
         currentScreens: @escaping @MainActor () -> [LiveScreen] = LiveScreen.current) {
        self.windowSystem = windowSystem
        self.layoutSource = PersistedZoneLayoutSource(store: store)
        self.placementCenter = placementCenter
        self.layoutMutationCenter = layoutMutationCenter
        self.journalStore = journalStore
        self.currentScreens = currentScreens
    }

    init(windowSystem: TilesWindowSystem,
         layoutSource: ZoneLayoutSource,
         placementCenter: WindowPlacementCenter,
         journalStore: TilesRecoveryJournalStore,
         layoutMutationCenter: ZoneLayoutMutationCenter = ZoneLayoutMutationCenter(),
         currentScreens: @escaping @MainActor () -> [LiveScreen] = LiveScreen.current) {
        self.windowSystem = windowSystem
        self.layoutSource = layoutSource
        self.placementCenter = placementCenter
        self.layoutMutationCenter = layoutMutationCenter
        self.journalStore = journalStore
        self.currentScreens = currentScreens
    }

    func start(settings: TilesSettings) throws {
        guard !acceptingEvents else { return }
        try settings.validate()
        self.settings = settings
        let journal = try journalStore.preflight()
        let screens = currentScreens()
        var layouts = try layoutSource.snapshot(for: screens)
        layouts.gapPoints = effectiveGapPoints(for: settings)
        guard !layouts.screenKeys.isEmpty else { throw TilesCoordinatorError.noUsableDisplays }

        self.screens = screens
        self.layouts = layouts
        self.journal = journal
        lastPersistedJournal = journal
        windowSystem.updateScreens(screens)
        try windowSystem.start { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        acceptingEvents = true
        runtimePauseMessage = nil
        runtimeQueue.sync { runtimePauseReason = nil }
        layoutObservation = layoutSource.observe { [weak self] in self?.layoutChanged() }
        placementObservation = placementCenter.observe { [weak self] in self?.placed($0) }

        let initialJournal = journal
        let initialLayouts = layouts
        runtimeQueue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            let recovery = self.windowSystem.recover(
                initialJournal, deadline: .now() + .milliseconds(1200))
            guard self.acceptingEvents else { return }
            var recoveredJournal = initialJournal
            for key in recovery.restoredIdentityKeys {
                recoveredJournal = recoveredJournal.removing(identityKey: key)
            }
            do {
                try self.persistJournal(recoveredJournal)
                self.journal = recoveredJournal
            } catch {
                self.publishState(presentation: .failure(
                    "Tiles could not save its recovery state."))
            }
            self.process(.adoptVisible, layouts: initialLayouts)
        }
    }

    func stop() {
        guard acceptingEvents else { return }
        acceptingEvents = false
        windowSystem.cancelPending()
        layoutObservation?.cancel()
        layoutObservation = nil
        placementObservation?.cancel()
        placementObservation = nil
        for work in coalescedWork.values { work.cancel() }
        coalescedWork.removeAll()

        runtimeQueue.sync {
            // healingWork is owned by the runtime queue. Cancelling it here
            // prevents a delayed retry from racing stop or scheduling work
            // after the AX session has been torn down.
            for work in healingWork { work.cancel() }
            healingWork.removeAll()
            let recovery = windowSystem.restore(
                session, journal: journal, deadline: .now() + .milliseconds(1500))
            var remaining = journal
            for key in recovery.restoredIdentityKeys {
                remaining = remaining.removing(identityKey: key)
            }
            do {
                try persistJournal(remaining)
                journal = remaining
            } catch {
                // Keep the in-memory journal equal to the durable file. The next start keeps the
                // recovery warning instead of claiming that restored state was saved.
            }
            session = .empty
            recordKeys.removeAll()
            detachedTokens.removeAll()
            runtimePauseReason = nil
        }
        windowSystem.stop()
        activeWorkspace = 1
        recoveryRequired = journal.records.contains(where: \.stageIntent)
        stackPreview = nil
        runtimePauseMessage = nil
        onPresentation = nil
        onStateChange?()
    }

    func update(settings: TilesSettings) {
        self.settings = settings
        guard acceptingEvents else { return }
        layouts.gapPoints = effectiveGapPoints(for: settings)
        enqueue(.layoutChanged)
    }

    /// Route one Cycler candidate against Tiles' live ownership. The returned inactive action
    /// closes over the resolved token, so selecting it does not repeat AX identity lookup.
    func cyclerWindowRoute(for element: AXUIElement) -> CyclerWindowRoute {
        guard acceptingEvents, let token = windowSystem.token(for: element) else {
            return CyclerWindowRoute(context: .unmanaged)
        }
        return runtimeQueue.sync {
            guard acceptingEvents,
                  !detachedTokens.contains(token),
                  let managed = session.windows[token] else {
                return CyclerWindowRoute(context: .unmanaged)
            }
            if managed.workspace == session.activeWorkspace {
                return CyclerWindowRoute(context: .currentContext)
            }
            guard runtimePauseReason == nil else {
                return CyclerWindowRoute(context: .unavailable(
                    message: "Tiles is paused, so it cannot switch workspaces."))
            }
            return CyclerWindowRoute(
                context: .inactiveWorkspace(workspace: managed.workspace.rawValue,
                                            focusEpoch: managed.focusEpoch),
                requestInactiveActivation: { [weak self] in
                    self?.enqueueCyclerExternalActivation(token)
                })
        }
    }

    /// A frontmost application does not publish NSWorkspace activation when Cycler restores one
    /// of its inactive windows. Send the same reducer event explicitly and let Tiles own every AX
    /// effect. The main actor only queues work; snapshot and mutations stay on the runtime worker.
    private func enqueueCyclerExternalActivation(_ token: WindowToken) {
        guard acceptingEvents else { return }
        let layouts = self.layouts
        runtimeQueue.async { [weak self] in
            guard let self, self.acceptingEvents,
                  self.runtimePauseReason == nil,
                  !self.detachedTokens.contains(token),
                  let managed = self.session.windows[token],
                  managed.workspace != self.session.activeWorkspace else { return }
            let snapshot = self.windowSystem.snapshot(.all)
            self.process(.externalActivation(token), snapshot: snapshot, layouts: layouts)
        }
    }

    func perform(_ action: TilesRuntimeAction) {
        guard acceptingEvents else { return }
        if let runtimePauseMessage {
            onPresentation?(.failure(runtimePauseMessage))
            return
        }
        switch action {
        case .switchWorkspace(let raw):
            guard let id = WorkspaceID.from(raw) else { return }
            enqueue(.switchWorkspace(id))
        case .nextWorkspace:
            enqueue(.nextWorkspace)
        case .previousWorkspace:
            enqueue(.previousWorkspace)
        case .nextWindow:
            enqueue(.cycleFocusedTile(.forward))
        case .previousWindow:
            enqueue(.cycleFocusedTile(.reverse))
        case .moveFocusedWindow(let raw):
            guard let id = WorkspaceID.from(raw) else { return }
            enqueue(.moveFocusedWindow(to: id))
        case .moveFocusedWindowToNextWorkspace:
            enqueueRelativeWorkspaceMove(forward: true)
        case .moveFocusedWindowToPreviousWorkspace:
            enqueueRelativeWorkspaceMove(forward: false)
        case .focusTile(let direction):
            enqueue(.focusTile(direction))
        case .moveFocusedWindowToTile(let direction):
            enqueue(.moveFocusedWindowToTile(direction))
        case .toggleFocusedSplitOrientation:
            toggleFocusedSplitOrientation()
        case .toggleFocusedTiled:
            toggleFocusedTiled()
        }
    }

    private func effectiveGapPoints(for settings: TilesSettings) -> CGFloat {
        settings.tileSpacingEnabled ? TilesSettings.tileSpacingPoints : 0
    }

    /// Resolve the focused managed tile on the serial runtime queue first. The
    /// actual Zones edit then crosses back to MainActor through the injected
    /// center, and feedback is emitted only after the center has persisted it.
    private func toggleFocusedSplitOrientation() {
        guard acceptingEvents else { return }
        runtimeQueue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            let snapshot = self.windowSystem.snapshot(.all)
            guard let focused = snapshot.focused,
                  let managed = self.session.windows[focused],
                  managed.workspace == self.session.activeWorkspace else {
                self.publishState(presentation: .failure(
                    "No focused tiled window is available."))
                return
            }
            let screenKey = managed.tile.screenKey
            let leafIndex = managed.tile.leafIndex
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.acceptingEvents else { return }
                    let result = self.layoutMutationCenter.toggleParentSplit(
                        screenKey: screenKey, leafIndex: leafIndex)
                    switch result {
                    case .changed:
                        self.onPresentation?(.confirmation("Split: \(result.userFacingText)"))
                    case .unavailable(let message):
                        self.onPresentation?(.failure(message))
                    }
                }
            }
        }
    }

    /// Toggle only the focused window. A managed window is first restored to
    /// its recorded adoption frame and that write must verify before the pure
    /// detach mutation commits. A detached window is adopted through the same
    /// reducer path as a new window, with the marker cleared only after commit.
    private func toggleFocusedTiled() {
        guard acceptingEvents else { return }
        let layouts = self.layouts
        let screens = currentScreens()
        runtimeQueue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            let snapshot = self.windowSystem.snapshot(.all)
            guard let focused = snapshot.focused,
                  let entry = snapshot.windows[focused] else {
                self.publishState(presentation: .failure(
                    "No focused tiled or freeform window is available."))
                return
            }

            if let managed = self.session.windows[focused] {
                guard managed.workspace == self.session.activeWorkspace,
                      managed.visibility == .visible,
                      entry.isAvailableForPlacement else {
                    self.publishState(presentation: .failure(
                        "The focused tiled window is not available."))
                    return
                }
                guard let adoptionFrame = Self.safeAdoptionFrame(managed.adoptionFrame,
                                                                  screens: screens) else {
                    self.publishState(presentation: .failure(
                        "Tiles could not find a connected display for this window."))
                    return
                }
                let baseGeneration = self.session.transition?.mutationID.rawValue
                    ?? self.session.mutationGeneration
                let effect = WindowEffect.setFrame(
                    focused, adoptionFrame,
                    MutationID(rawValue: baseGeneration &+ 1))
                self.process(.detach(focused), snapshot: snapshot, layouts: layouts,
                             includeDetached: true,
                             presentationOverride: .confirmation("Window is freeform."),
                             preCommit: {
                                 self.windowSystem.apply([effect]).first?.succeeded == true
                             },
                             preCommitFailureMessage: "Tiles could not restore a safe freeform frame.")
                return
            }

            guard self.detachedTokens.contains(focused) else {
                self.publishState(presentation: .failure(
                    "No focused tiled or freeform window is available."))
                return
            }
            self.process(.adopt(focused), snapshot: snapshot, layouts: layouts,
                         includeDetached: true,
                         presentationOverride: .confirmation("Window is tiled."))
        }
    }

    /// A display can disappear while a window remains managed. Before restoring its freeform
    /// frame, keep the original size but clamp it to a connected display. If its old display is
    /// gone, center it on the nearest live display so the toggle cannot strand it off-screen.
    private nonisolated static func safeAdoptionFrame(_ frame: CGRect,
                                                      screens: [LiveScreen]) -> CGRect? {
        guard !screens.isEmpty,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              let index = ScreenPicker.bestScreenIndex(forWindow: frame,
                                                       screens: screens.map(\.frame)),
              screens.indices.contains(index) else { return nil }
        let screen = screens[index]
        let bounds = screen.visibleFrame.width > 0 && screen.visibleFrame.height > 0
            ? screen.visibleFrame : screen.frame
        let anchor = screen.frame.intersects(frame) ? frame : screen.frame
        return FixedPlacement.center(size: frame.size, in: anchor, boundedBy: bounds)
    }

    func restoreWindows() {
        guard acceptingEvents else { return }
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            let before = self.journal
            let recovery = self.windowSystem.recover(
                self.journal, deadline: .now() + .milliseconds(1500))
            for key in recovery.restoredIdentityKeys {
                self.journal = self.journal.removing(identityKey: key)
            }
            do {
                try self.persistJournal(self.journal)
            } catch {
                self.publishState(presentation: .failure("Tiles could not save recovery state."))
                return
            }
            if !before.records.isEmpty && recovery.restoredIdentityKeys.isEmpty {
                self.publishState(presentation: .failure("Tiles could not restore any windows."))
            } else if !self.journal.records.isEmpty {
                self.publishState(presentation: .failure("Some windows could not be restored."))
            } else {
                self.publishState(presentation: .recoveryCompleted)
            }
        }
    }

    private func handle(_ event: WindowSystemEvent) {
        guard acceptingEvents else { return }
        switch event {
        case .windowCreated(let pid):
            coalesce(key: "create:\(pid)", delay: .milliseconds(120), event: .reconcile,
                     snapshotScope: .pid(pid))
            retryReconcile(after: .milliseconds(360))
            retryReconcile(after: .milliseconds(900))
        case .windowChanged(let token, let pid):
            coalesceWindowChange(token, pid: pid)
        case .windowDestroyed(let token):
            enqueue(.windowClosed(token))
        case .applicationChanged(let pid):
            coalesce(key: "app:\(pid)", delay: .milliseconds(120), event: .reconcile,
                     snapshotScope: .pid(pid))
        case .applicationActivated:
            let layouts = self.layouts
            runtimeQueue.async { [weak self] in self?.processActivation(layouts: layouts) }
        case .externalActivation(let token):
            let layouts = self.layouts
            runtimeQueue.async { [weak self] in
                guard let self else { return }
                let snapshot = self.windowSystem.snapshot(.all)
                self.process(.externalActivation(token), snapshot: snapshot, layouts: layouts)
            }
        case .topologyChanged:
            let work = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.topologySettled() }
                }
            }
            coalescedWork["topology"]?.cancel()
            coalescedWork["topology"] = work
            runtimeQueue.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
        }
    }

    nonisolated private func processActivation(layouts: LayoutSnapshot) {
        // One discovery per activation. The focused token is the same in every
        // scope, so a scoped snapshot would only add a second full sweep.
        let snapshot = windowSystem.snapshot(.all)
        if let focused = snapshot.focused, session.windows[focused] != nil {
            process(.externalActivation(focused), snapshot: snapshot, layouts: layouts)
        } else {
            // Activation can mean a native Space change. Refresh reachability only; do not
            // adopt and move a newly visible window because activation alone is not placement
            // intent. Keep only already-managed entries in the reconcile snapshot so existing
            // assignments are refreshed without turning activation into adoption.
            var existingOnly = snapshot
            existingOnly.windows = snapshot.windows.filter { session.windows[$0.key] != nil }
            process(.reconcile, snapshot: existingOnly, layouts: layouts)
        }
    }

    private func layoutChanged() {
        refreshLayout(screens: screens, updateWindowSystem: false)
    }

    private func topologySettled() {
        refreshLayout(screens: currentScreens(), updateWindowSystem: true)
    }

    /// A Zones edit and a settled display change need the same work; only the
    /// screen list and the window system update differ. A failure keeps the
    /// last valid snapshot, so no AX mutation runs from an invalid Zones
    /// section or an unresolved topology.
    private func refreshLayout(screens updatedScreens: [LiveScreen], updateWindowSystem: Bool) {
        guard acceptingEvents else { return }
        do {
            var updatedLayouts = try layoutSource.snapshot(for: updatedScreens)
            updatedLayouts.gapPoints = effectiveGapPoints(for: settings)
            screens = updatedScreens
            layouts = updatedLayouts
            transitionRuntimePause(to: nil)
            if updateWindowSystem { windowSystem.updateScreens(updatedScreens) }
            enqueue(.layoutChanged)
        } catch {
            transitionRuntimePause(to:
                "Tiles paused because the Zones layout is unavailable for a connected monitor. " +
                "Check Zones and your monitors. Tiles will resume automatically.")
        }
    }

    private func transitionRuntimePause(to message: String?) {
        let previous = runtimePauseMessage
        guard previous != message else { return }
        runtimePauseMessage = message
        runtimeQueue.async { [weak self] in self?.runtimePauseReason = message }
        onStateChange?()
        if let message {
            onPresentation?(.failure(message))
        } else if previous != nil {
            onPresentation?(.confirmation("Tiles resumed"))
        }
    }

    private func placed(_ event: WindowPlacementEvent) {
        guard acceptingEvents, let token = windowSystem.token(for: event.window) else { return }
        let layouts = self.layouts
        switch event.target {
        case .zone(let screenKey, let index, let frame):
            let address = TileAddress(screenKey: screenKey, leafIndex: index,
                                      normalizedCenter: .zero)
            guard let rawFrame = layouts.rawFrame(for: address),
                  RecoveryModel.compatibleFrame(rawFrame, with: frame) else { return }
            let leaf = layouts.screens[screenKey]?.first(where: { $0.index == index })
            guard let address = leaf?.address(screenKey: screenKey) else { return }
            // A detached token is not in the pure session, so explicitly
            // adopting it must precede the placement event. Both operations
            // stay on the same serial runtime queue and the marker is cleared
            // only after the placement plan commits.
            runtimeQueue.async { [weak self] in
                guard let self else { return }
                // One discovery serves both steps; adoption changes the model,
                // not the AX state the snapshot describes.
                let snapshot = self.windowSystem.snapshot(.all)
                self.process(.adopt(token), snapshot: snapshot, layouts: layouts,
                             includeDetached: true)
                self.process(.place(token, at: address), snapshot: snapshot, layouts: layouts,
                             includeDetached: true)
            }
        case .freeform:
            enqueue(.detach(token))
        }
    }

    private func enqueue(_ event: TilesEvent) {
        let layouts = self.layouts
        runtimeQueue.async { [weak self] in self?.process(event, layouts: layouts) }
    }

    /// Resolve a relative destination on the serial runtime queue. The
    /// main-actor workspace value is only a presentation mirror and can lag a
    /// switch that is already queued immediately before this action.
    private func enqueueRelativeWorkspaceMove(forward: Bool) {
        let layouts = self.layouts
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            let source = self.session.activeWorkspace
            let destination = forward ? source.next : source.previous
            self.process(.moveFocusedWindow(to: destination), layouts: layouts)
        }
    }

    private func coalesce(key: String, delay: DispatchTimeInterval, event: TilesEvent,
                          snapshotScope: SnapshotScope = .all) {
        coalescedWork[key]?.cancel()
        let layouts = self.layouts
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.windowSystem.snapshot(snapshotScope)
            self.process(event, snapshot: snapshot, layouts: layouts)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.coalescedWork[key] = nil }
            }
        }
        coalescedWork[key] = work
        runtimeQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func coalesceWindowChange(_ token: WindowToken, pid: pid_t) {
        let key = "window:\(token.rawValue)"
        coalescedWork[key]?.cancel()
        let layouts = self.layouts
        let work = DispatchWorkItem { [weak self] in
            self?.processWindowChange(token, pid: pid, layouts: layouts)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.coalescedWork[key] = nil }
            }
        }
        coalescedWork[key] = work
        runtimeQueue.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    private func retryReconcile(after delay: DispatchTimeInterval) {
        let layouts = self.layouts
        runtimeQueue.async { [weak self] in
            guard let self, self.acceptingEvents else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.process(.reconcile, layouts: layouts)
            }
            self.healingWork.append(work)
            self.runtimeQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    nonisolated private func process(_ event: TilesEvent, layouts: LayoutSnapshot,
                                     includeDetached: Bool = false,
                                     presentationOverride: TilesPresentation? = nil,
                                     preCommit: (() -> Bool)? = nil,
                                     preCommitFailureMessage: String? = nil) {
        process(event, snapshot: windowSystem.snapshot(.all), layouts: layouts,
                includeDetached: includeDetached,
                presentationOverride: presentationOverride,
                preCommit: preCommit,
                preCommitFailureMessage: preCommitFailureMessage)
    }

    nonisolated private func processWindowChange(_ token: WindowToken, pid: pid_t,
                                                 layouts: LayoutSnapshot) {
        let snapshot = windowSystem.snapshot(.pid(pid))
        if let managed = session.windows[token], managed.visibility == .visible,
           managed.workspace == session.activeWorkspace,
           let entry = snapshot.windows[token], entry.isVisible,
           let leaves = layouts.screens[entry.screenKey] {
            let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
            if let leaf = leaves.first(where: { leaf in
                let address = leaf.address(screenKey: entry.screenKey)
                guard let frame = layouts.rawFrame(for: address) else { return false }
                return frame.contains(center)
            }) {
                let address = leaf.address(screenKey: entry.screenKey)
                if address.id != managed.tile.id {
                    process(.place(token, at: address), snapshot: snapshot, layouts: layouts)
                    return
                }
            }
        }
        process(.reconcile, snapshot: snapshot, layouts: layouts)
    }

    nonisolated private func process(_ event: TilesEvent, snapshot: WindowSnapshot,
                                     layouts: LayoutSnapshot,
                                     includeDetached: Bool = false,
                                     presentationOverride: TilesPresentation? = nil,
                                     preCommit: (() -> Bool)? = nil,
                                     preCommitFailureMessage: String? = nil) {
        guard acceptingEvents, runtimePauseReason == nil else { return }
        if case .windowClosed(let token) = event {
            // A destroyed detached window has no model plan, but its marker
            // must still be released so a future token cannot inherit it.
            detachedTokens.remove(token)
        }
        let reducerSnapshot: WindowSnapshot
        if includeDetached || detachedTokens.isEmpty {
            reducerSnapshot = snapshot
        } else {
            var filtered = snapshot
            filtered.windows = snapshot.windows.filter { !detachedTokens.contains($0.key) }
            if let focused = snapshot.focused, detachedTokens.contains(focused) {
                filtered.focused = nil
            }
            reducerSnapshot = filtered
        }
        let plan = TilesReducer.plan(state: session, event: event,
                                     snapshot: reducerSnapshot, layouts: layouts)
        if plan.isNoOp {
            // AX title changes can alter the recovery identity without any
            // model/effect change. Keep journal replacement on the runtime
            // queue so an old identity key is removed even for a no-op
            // reconciliation.
            guard synchronizeJournalWithSession() else {
                publishState(presentation: .failure(
                    "Tiles could not save its recovery state."))
                return
            }
            publishState(presentation: noOpPresentation(for: event, snapshot: snapshot))
            return
        }

        var intendedJournal = journal
        var intendedRecordKeys = recordKeys
        for token in Set(plan.effects.map(\.token)) {
            guard let managed = plan.nextState.windows[token] ?? session.windows[token] else { continue }
            let stagesWindow = plan.effects.contains {
                if case .setMinimized(let effectToken, true, _) = $0 { return effectToken == token }
                return false
            }
            let priorStageIntent = intendedRecordKeys[token].flatMap { key in
                intendedJournal.records.first(where: { $0.identityKey == key })?.stageIntent
            } ?? false
            let wasStagedByTiles = session.windows[token]?.visibility == .stagedByTiles
            // Keep a previously journaled staging intent through the
            // deminimize call. synchronizeJournalWithSession clears it only
            // after the verified effect has committed. A Cycler request can also deminimize a
            // window that the user minimized. That request must never create Tiles recovery
            // ownership if it fails before commit.
            let stageIntent = stagesWindow || managed.visibility == .stagedByTiles ||
                wasStagedByTiles || priorStageIntent
            if let record = windowSystem.recoveryRecord(for: token, managed: managed,
                                                        stageIntent: stageIntent) {
                if let oldKey = intendedRecordKeys[token], oldKey != record.identityKey {
                    intendedJournal = intendedJournal.removing(identityKey: oldKey)
                }
                intendedJournal = intendedJournal.adding(record)
                intendedRecordKeys[token] = record.identityKey
            }
        }
        do {
            try persistJournal(intendedJournal)
            journal = intendedJournal
            recordKeys = intendedRecordKeys
        } catch {
            publishState(presentation: failurePresentation(
                for: event, message: "Tiles could not save its recovery state."))
            return
        }

        // Some events need one verified AX mutation before their pure reducer state can commit.
        // Keeping it after the journal write makes both failure paths fail closed: an unwritable
        // journal leaves the managed state untouched, while a rejected frame leaves the journal
        // and in-memory session describing the still-managed window.
        if let preCommit, !preCommit() {
            publishState(presentation: .failure(
                preCommitFailureMessage ?? "Tiles could not complete that action."))
            return
        }

        let priorSession = session
        let results = windowSystem.apply(plan.effects)
        let committed = TilesReducer.commit(state: priorSession, plan: plan, results: results)
        if committed.mutationGeneration != plan.mutationID.rawValue {
            let compensation = TilesReducer.compensation(
                for: plan, results: results, priorState: priorSession, snapshot: snapshot)
            let compensationResults = windowSystem.apply(compensation)
            var goneTokens: Set<WindowToken> = []
            var unresolvedTokens: Set<WindowToken> = []
            let isRecoveryEffect: (WindowEffect) -> Bool = { effect in
                switch effect {
                case .setFrame, .setMinimized: return true
                case .raise, .focus: return false
                }
            }
            for effect in plan.effects where isRecoveryEffect(effect) {
                guard let result = results.first(where: { $0.effect == effect }) else {
                    unresolvedTokens.insert(effect.token)
                    continue
                }
                if result.isGone { goneTokens.insert(effect.token) }
                else if !result.succeeded { unresolvedTokens.insert(effect.token) }
            }
            for effect in compensation {
                guard let result = compensationResults.first(where: { $0.effect == effect }) else {
                    unresolvedTokens.insert(effect.token)
                    continue
                }
                if !result.succeeded { unresolvedTokens.insert(effect.token) }
            }
            let compensatedTokens = Set(compensation.map(\.token))
            for effect in plan.effects where isRecoveryEffect(effect) {
                guard results.first(where: { $0.effect == effect })?.succeeded == true,
                      !compensatedTokens.contains(effect.token) else { continue }
                // No compensating write means the successful forward mutation
                // remains unresolved; keep its durable recovery intent.
                unresolvedTokens.insert(effect.token)
            }
            unresolvedTokens.subtract(goneTokens)
            // `commit` removes confirmed-gone tokens while keeping the prior
            // generation. Keep that result as the in-memory baseline and only
            // rewrite records whose forward and compensating writes are both
            // resolved. Unresolved records retain their pre-mutation intent.
            session = committed
            let journalSaved = synchronizeJournalWithSession(preserving: unresolvedTokens)
            let message = journalSaved
                ? "Tiles could not complete that action."
                : "Tiles could not complete that action or save recovery state."
            publishState(presentation: failurePresentation(for: event, message: message))
            return
        }
        let previousActiveWorkspace = priorSession.activeWorkspace
        session = committed
        switch event {
        case .detach(let token):
            detachedTokens.insert(token)
        case .adopt(let token):
            detachedTokens.remove(token)
        case .place(let token, _):
            detachedTokens.remove(token)
        default:
            break
        }
        let clearedStageIntentTokens = Set(results.compactMap { result -> WindowToken? in
            guard result.succeeded,
                  case .setMinimized(let token, false, _) = result.effect else { return nil }
            return token
        })
        let journalSaved = synchronizeJournalWithSession(
            clearingStageIntentFor: clearedStageIntentTokens)
        if let destination = workspaceDestination(for: event, from: previousActiveWorkspace),
           session.activeWorkspace != destination {
            publishState(presentation: journalSaved ? nil : .failure(
                "Tiles completed a step but could not save recovery state."))
            runtimeQueue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
                self?.process(event, layouts: layouts)
            }
            return
        }
        let preview: TilesStackPreview?
        if case .cycleFocusedTile = event {
            preview = currentStackPreview(snapshot: snapshot)
        } else if case .moveFocusedWindowToTile = event {
            preview = currentStackPreview(snapshot: snapshot)
        } else {
            preview = nil
        }
        let presentation = journalSaved
            ? (presentationOverride ?? presentationAfterCommit(for: event, preview: preview))
            : .failure("Tiles completed the action but could not save recovery state.")
        publishState(preview: preview, presentation: presentation)
        scheduleHealingPasses(layouts: layouts)
    }

    /// Resolve the whole record set once. `removing` plus `adding` per managed
    /// window copies the journal twice per window and rebuilds `identityKey`
    /// for every record it walks, which is quadratic in the number of managed
    /// windows. The stored shape is unchanged: records stay an array.
    @discardableResult
    nonisolated private func synchronizeJournalWithSession(
        preserving preservedTokens: Set<WindowToken> = [],
        clearingStageIntentFor clearedTokens: Set<WindowToken> = []) -> Bool {
        var updatedRecordKeys = recordKeys
        let liveTokens = Set(session.windows.keys)
        var removedKeys: Set<String> = []
        for (token, key) in recordKeys where !liveTokens.contains(token) {
            removedKeys.insert(key)
            updatedRecordKeys[token] = nil
        }
        var replacements: [String: RecoveryRecord] = [:]
        for managed in session.windows.values where !preservedTokens.contains(managed.token) {
            let previousKey = updatedRecordKeys[managed.token]
            let priorStageIntent = previousKey.flatMap { key in
                journal.records.first(where: { $0.identityKey == key })?.stageIntent
            } ?? false
            // Once Tiles has staged a window, keep that recovery ownership through AX identity
            // changes and reconciliation. Only a verified deminimize in a fully committed plan
            // may clear it; a failed or delayed minimize must remain recoverable.
            let stageIntent = managed.visibility == .stagedByTiles ||
                (priorStageIntent && !clearedTokens.contains(managed.token))
            guard let record = windowSystem.recoveryRecord(
                for: managed.token, managed: managed,
                stageIntent: stageIntent) else { continue }
            // Titles and exact-peer ordinals can change while a window is
            // alive. Replace the previous identity instead of leaving an
            // unreachable stale record in the journal.
            if let previousKey, previousKey != record.identityKey {
                removedKeys.insert(previousKey)
            }
            replacements[record.identityKey] = record
            updatedRecordKeys[managed.token] = record.identityKey
        }

        var records: [RecoveryRecord] = []
        records.reserveCapacity(journal.records.count + replacements.count)
        var written: Set<String> = []
        for record in journal.records {
            let key = record.identityKey
            if let replacement = replacements[key] {
                records.append(replacement)
                written.insert(key)
            } else if !removedKeys.contains(key) {
                records.append(record)
                written.insert(key)
            }
        }
        // Sorted so an unchanged session always produces the same bytes and the
        // persist step can skip an identical write.
        for key in replacements.keys.sorted() where !written.contains(key) {
            if let record = replacements[key] { records.append(record) }
        }

        let updated = RecoveryJournal(schemaVersion: journal.schemaVersion, records: records)
        do {
            try persistJournal(updated)
            journal = updated
            recordKeys = updatedRecordKeys
            return true
        } catch {
            return false
        }
    }

    nonisolated private func workspaceDestination(for event: TilesEvent,
                                                  from source: WorkspaceID) -> WorkspaceID? {
        switch event {
        case .switchWorkspace(let destination):
            return destination
        case .nextWorkspace:
            return source.next
        case .previousWorkspace:
            return source.previous
        case .externalActivation(let token):
            // A barrier plan commits the destination window's visible state
            // before the workspace switch. Resolve the retry from that
            // committed ownership rather than the pre-barrier workspace.
            return session.windows[token]?.workspace
        default:
            return nil
        }
    }

    nonisolated private func persistJournal(_ journal: RecoveryJournal) throws {
        guard journal != lastPersistedJournal else { return }
        if journal.records.isEmpty { try journalStore.remove() }
        else { try journalStore.write(journal) }
        lastPersistedJournal = journal
    }

    nonisolated private func scheduleHealingPasses(layouts: LayoutSnapshot) {
        // Called only from runtimeQueue (after a committed mutation). Keep
        // every read/write of healingWork on that queue; stop and retry
        // registration use the same serialization point.
        guard acceptingEvents else { return }
        for work in healingWork { work.cancel() }
        healingWork.removeAll(keepingCapacity: true)
        for delay in [250, 1_000, 3_000] {
            let work = DispatchWorkItem { [weak self] in self?.process(.reconcile, layouts: layouts) }
            healingWork.append(work)
            runtimeQueue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
        }
    }

    nonisolated private func currentStackPreview(snapshot: WindowSnapshot) -> TilesStackPreview? {
        guard let focused = snapshot.focused,
              let workspace = session.workspaces[session.activeWorkspace] else { return nil }
        for screen in workspace.screens.keys.sorted() {
            for stack in workspace.screens[screen] ?? [] {
                guard stack.contains(focused) else { continue }
                // The committed model selection is authoritative after a
                // cycle; the pre-effect snapshot still names the old focused
                // member until AX posts its notification.
                let selected = stack.selected ?? focused
                guard stack.contains(selected) else { continue }
                let available = stack.order.filter {
                    snapshot.windows[$0]?.isAvailableForPlacement ?? false
                }
                guard available.count > 1, available.contains(selected) else { continue }
                return windowSystem.stackPreview(tokens: available, selected: selected)
            }
        }
        return nil
    }

    nonisolated private func noOpPresentation(for event: TilesEvent,
                                              snapshot: WindowSnapshot) -> TilesPresentation? {
        switch event {
        case .cycleFocusedTile, .focusTile, .moveFocusedWindowToTile:
            // Reaching an edge, an empty tile, or a stack with no available
            // peer is a normal no-op. Only an unmanaged focus is actionable
            // feedback, so it keeps the orange failure presentation.
            guard let focused = snapshot.focused,
                  session.windows[focused] != nil else {
                return .failure("No focused tiled window is available.")
            }
            return nil
        case .switchWorkspace(let workspace):
            return workspace == session.activeWorkspace
                ? nil
                : .failure("Workspace \(workspace.rawValue) is unavailable.")
        case .nextWorkspace, .previousWorkspace:
            return .failure("No workspace change was applied.")
        case .moveFocusedWindow(let workspace):
            return .failure("The focused window could not move to Workspace \(workspace.rawValue).")
        default:
            return nil
        }
    }

    nonisolated private func failurePresentation(for event: TilesEvent,
                                                 message: String) -> TilesPresentation? {
        switch event {
        case .cycleFocusedTile, .switchWorkspace, .nextWorkspace, .previousWorkspace,
             .moveFocusedWindow, .focusTile, .moveFocusedWindowToTile, .detach, .adopt:
            return .failure(message)
        default:
            return nil
        }
    }

    nonisolated private func presentationAfterCommit(for event: TilesEvent,
                                                     preview: TilesStackPreview?) -> TilesPresentation? {
        switch event {
        case .switchWorkspace, .nextWorkspace, .previousWorkspace:
            return .workspace(session.activeWorkspace.rawValue)
        case .moveFocusedWindow(let destination):
            return .movedWindow(destination.rawValue)
        case .moveFocusedWindowToTile(let direction):
            if let preview { return .addedToStack(preview) }
            return .confirmation("Moved window \(directionName(direction))")
        case .cycleFocusedTile:
            return preview.map(TilesPresentation.stack)
        default:
            return nil
        }
    }

    nonisolated private func directionName(_ direction: TileDirection) -> String {
        switch direction {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }

    nonisolated private func publishState(preview: TilesStackPreview? = nil,
                                          presentation: TilesPresentation? = nil) {
        let active = session.activeWorkspace.rawValue
        let needsRecovery = journal.records.contains(where: \.stageIntent)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.activeWorkspace = active
                self.recoveryRequired = needsRecovery
                self.stackPreview = preview
                self.onStateChange?()
                if let presentation {
                    self.onPresentation?(presentation)
                }
            }
        }
    }
}

enum TilesCoordinatorError: LocalizedError {
    case noUsableDisplays

    var errorDescription: String? {
        "Tiles could not resolve a valid Zones layout for a connected display."
    }
}
