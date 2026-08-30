import AppKit
import AppCore
import ApplicationServices
import Foundation
import TilesCore

@MainActor
final class TilesCoordinator: TilesCoordinatorProtocol {
    nonisolated(unsafe) private let windowSystem: TilesWindowSystem
    private let layoutSource: ZoneLayoutSource
    private let placementCenter: WindowPlacementCenter
    private let layoutMutationCenter: ZoneLayoutMutationCenter
    nonisolated(unsafe) private let journalStore: TilesRecoveryJournalStore
    private let runtimeQueue = DispatchQueue(label: "com.caiano.lineup.tiles.coordinator",
                                             qos: .userInitiated)

    private var screens: [LiveScreen] = []
    private var layouts = LayoutSnapshot()
    nonisolated(unsafe) private var session = TilesSession.empty
    nonisolated(unsafe) private var journal = RecoveryJournal()
    nonisolated(unsafe) private var recordKeys: [WindowToken: String] = [:]
    /// A freeform Zones action detaches a window for the rest of this Tiles
    /// session. Explicit Zone placement or a close clears this runtime-only
    /// marker.
    nonisolated(unsafe) private var detachedTokens: Set<WindowToken> = []
    nonisolated(unsafe) private var acceptingEvents = false
    nonisolated(unsafe) private var runtimePaused = false
    private var layoutObservation: ZoneLayoutObservation?
    private var placementObservation: WindowPlacementObservation?
    private var coalescedWork: [String: DispatchWorkItem] = [:]
    nonisolated(unsafe) private var healingWork: [DispatchWorkItem] = []

    private(set) var activeWorkspace = 1
    private(set) var recoveryRequired = false
    private(set) var stackPreview: TilesStackPreview?
    private var settings = TilesSettings()
    var onStateChange: (() -> Void)?
    var onPresentation: ((TilesPresentation) -> Void)?

    init(store: LineupAppConfigStore,
         placementCenter: WindowPlacementCenter,
         layoutMutationCenter: ZoneLayoutMutationCenter = ZoneLayoutMutationCenter(),
         windowSystem: TilesWindowSystem = AXWindowSystem(),
         journalStore: TilesRecoveryJournalStore = TilesRecoveryJournalStore()) {
        self.windowSystem = windowSystem
        self.layoutSource = PersistedZoneLayoutSource(store: store)
        self.placementCenter = placementCenter
        self.layoutMutationCenter = layoutMutationCenter
        self.journalStore = journalStore
    }

    init(windowSystem: TilesWindowSystem,
         layoutSource: ZoneLayoutSource,
         placementCenter: WindowPlacementCenter,
         journalStore: TilesRecoveryJournalStore,
         layoutMutationCenter: ZoneLayoutMutationCenter = ZoneLayoutMutationCenter()) {
        self.windowSystem = windowSystem
        self.layoutSource = layoutSource
        self.placementCenter = placementCenter
        self.layoutMutationCenter = layoutMutationCenter
        self.journalStore = journalStore
    }

    func start(settings: TilesSettings) throws {
        guard !acceptingEvents else { return }
        try settings.validate()
        self.settings = settings
        try journalStore.preflight()
        let screens = LiveScreen.current()
        var layouts = try layoutSource.snapshot(for: screens)
        layouts.gapPoints = effectiveGapPoints(for: settings)
        guard !layouts.screenKeys.isEmpty else { throw TilesCoordinatorError.noUsableDisplays }
        let journal = try journalStore.load()

        self.screens = screens
        self.layouts = layouts
        self.journal = journal
        windowSystem.updateScreens(screens)
        try windowSystem.start { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        acceptingEvents = true
        runtimePaused = false
        layoutObservation = layoutSource.observe { [weak self] in self?.layoutChanged() }
        placementObservation = placementCenter.observe { [weak self] in self?.placed($0) }

        let initialJournal = journal
        let initialLayouts = layouts
        runtimeQueue.async { [weak self] in
            guard let self else { return }
            let recovery = self.windowSystem.recover(
                initialJournal, deadline: .now() + .milliseconds(1200))
            var recoveredJournal = initialJournal
            for key in recovery.restoredIdentityKeys {
                recoveredJournal = recoveredJournal.removing(identityKey: key)
            }
            self.journal = recoveredJournal
            try? self.persistJournal(recoveredJournal)
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
            journal = remaining
            if remaining.records.isEmpty {
                try? journalStore.remove()
            } else {
                try? journalStore.write(remaining)
            }
            session = .empty
            recordKeys.removeAll()
            detachedTokens.removeAll()
        }
        windowSystem.stop()
        activeWorkspace = 1
        recoveryRequired = journal.records.contains(where: \.stageIntent)
        stackPreview = nil
        onPresentation = nil
        onStateChange?()
    }

    func update(settings: TilesSettings) {
        self.settings = settings
        guard acceptingEvents else { return }
        layouts.gapPoints = effectiveGapPoints(for: settings)
        enqueue(.layoutChanged)
    }

    func perform(_ action: TilesRuntimeAction) {
        guard acceptingEvents else { return }
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
            let destination = activeWorkspace == 4 ? 1 : activeWorkspace + 1
            enqueue(.moveFocusedWindow(to: WorkspaceID(rawValue: destination)))
        case .moveFocusedWindowToPreviousWorkspace:
            let destination = activeWorkspace == 1 ? 4 : activeWorkspace - 1
            enqueue(.moveFocusedWindow(to: WorkspaceID(rawValue: destination)))
        case .focusTile(let direction):
            enqueue(.focusTile(direction))
        case .moveFocusedWindowToTile(let direction):
            enqueue(.moveFocusedWindowToTile(direction))
        case .toggleFocusedSplitOrientation:
            toggleFocusedSplitOrientation()
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
            coalesce(key: "create:\(pid)", delay: .milliseconds(120), event: .reconcile)
            retryReconcile(after: .milliseconds(360))
            retryReconcile(after: .milliseconds(900))
        case .windowChanged(let token):
            coalesceWindowChange(token)
        case .windowDestroyed(let token):
            enqueue(.windowClosed(token))
        case .applicationChanged(let pid):
            coalesce(key: "app:\(pid)", delay: .milliseconds(120), event: .reconcile)
        case .applicationActivated(let pid):
            let layouts = self.layouts
            runtimeQueue.async { [weak self] in self?.processActivation(pid: pid, layouts: layouts) }
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

    nonisolated private func processActivation(pid: pid_t, layouts: LayoutSnapshot) {
        let snapshot = windowSystem.snapshot(.pid(pid))
        if let focused = snapshot.focused, session.windows[focused] != nil {
            process(.externalActivation(focused), snapshot: windowSystem.snapshot(.all), layouts: layouts)
        } else {
            // Activation can mean a native Space change. Refresh reachability only; do not
            // adopt and move a newly visible window because activation alone is not placement intent.
            publishState()
        }
    }

    private func layoutChanged() {
        guard acceptingEvents else { return }
        do {
            var updated = try layoutSource.snapshot(for: screens)
            updated.gapPoints = effectiveGapPoints(for: settings)
            layouts = updated
            runtimeQueue.async { [weak self] in self?.runtimePaused = false }
            enqueue(.layoutChanged)
        } catch {
            // Keep the last valid snapshot. No AX mutation runs from an invalid Zones section.
            runtimeQueue.async { [weak self] in self?.runtimePaused = true }
        }
    }

    private func topologySettled() {
        guard acceptingEvents else { return }
        let updatedScreens = LiveScreen.current()
        do {
            var updatedLayouts = try layoutSource.snapshot(for: updatedScreens)
            updatedLayouts.gapPoints = effectiveGapPoints(for: settings)
            screens = updatedScreens
            layouts = updatedLayouts
            runtimeQueue.async { [weak self] in self?.runtimePaused = false }
            windowSystem.updateScreens(updatedScreens)
            enqueue(.layoutChanged)
        } catch {
            // Keep the previous topology until Zones is valid again.
            runtimeQueue.async { [weak self] in self?.runtimePaused = true }
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
                self.process(.adopt(token), layouts: layouts, includeDetached: true)
                self.process(.place(token, at: address), layouts: layouts,
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

    private func coalesce(key: String, delay: DispatchTimeInterval, event: TilesEvent) {
        coalescedWork[key]?.cancel()
        let layouts = self.layouts
        let work = DispatchWorkItem { [weak self] in
            self?.process(event, layouts: layouts)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.coalescedWork[key] = nil }
            }
        }
        coalescedWork[key] = work
        runtimeQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func coalesceWindowChange(_ token: WindowToken) {
        let key = "window:\(token.rawValue)"
        coalescedWork[key]?.cancel()
        let layouts = self.layouts
        let work = DispatchWorkItem { [weak self] in
            self?.processWindowChange(token, layouts: layouts)
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

    nonisolated private func process(_ event: TilesEvent, layouts: LayoutSnapshot) {
        process(event, snapshot: windowSystem.snapshot(.all), layouts: layouts)
    }

    nonisolated private func process(_ event: TilesEvent, layouts: LayoutSnapshot,
                                     includeDetached: Bool) {
        process(event, snapshot: windowSystem.snapshot(.all), layouts: layouts,
                includeDetached: includeDetached)
    }

    nonisolated private func processWindowChange(_ token: WindowToken, layouts: LayoutSnapshot) {
        let snapshot = windowSystem.snapshot(.all)
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
                                     includeDetached: Bool = false) {
        guard acceptingEvents, !runtimePaused else { return }
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
            synchronizeJournalWithSession()
            publishState(presentation: noOpPresentation(for: event))
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
            let deminimizesWindow = plan.effects.contains {
                if case .setMinimized(let effectToken, false, _) = $0 { return effectToken == token }
                return false
            }
            let priorStageIntent = intendedRecordKeys[token].flatMap { key in
                intendedJournal.records.first(where: { $0.identityKey == key })?.stageIntent
            } ?? false
            // Keep a previously journaled staging intent through the
            // deminimize call. synchronizeJournalWithSession clears it only
            // after the verified effect has committed.
            let stageIntent = stagesWindow || managed.visibility == .stagedByTiles ||
                priorStageIntent || deminimizesWindow
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

        let priorSession = session
        let results = windowSystem.apply(plan.effects)
        let committed = TilesReducer.commit(state: priorSession, plan: plan, results: results)
        if committed == priorSession && !plan.effects.isEmpty {
            let compensation = TilesReducer.compensation(
                for: plan, results: results, priorState: priorSession, snapshot: snapshot)
            _ = windowSystem.apply(compensation)
            // The intent was written before mutation. If the mutation or its
            // compensation fails, the live model is still priorSession, so
            // rewrite the journal from that state before reporting failure.
            // Otherwise a crash in this interval could recover a plan that
            // never committed.
            synchronizeJournalWithSession()
            publishState(presentation: failurePresentation(for: event,
                                                            message: "Tiles could not complete that action."))
            return
        }
        let previousActiveWorkspace = priorSession.activeWorkspace
        session = committed
        switch event {
        case .detach(let token):
            detachedTokens.insert(token)
        case .place(let token, _):
            detachedTokens.remove(token)
        default:
            break
        }
        synchronizeJournalWithSession()
        if let destination = workspaceDestination(for: event, from: previousActiveWorkspace),
           session.activeWorkspace != destination {
            publishState()
            runtimeQueue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
                self?.process(event, layouts: layouts)
            }
            return
        }
        let preview: TilesStackPreview?
        if case .cycleFocusedTile = event {
            preview = currentStackPreview(snapshot: snapshot)
        } else {
            preview = nil
        }
        publishState(preview: preview,
                     presentation: presentationAfterCommit(for: event, preview: preview))
        scheduleHealingPasses(layouts: layouts)
    }

    nonisolated private func synchronizeJournalWithSession() {
        var updated = journal
        var updatedRecordKeys = recordKeys
        let liveTokens = Set(session.windows.keys)
        for (token, key) in recordKeys where !liveTokens.contains(token) {
            updated = updated.removing(identityKey: key)
            updatedRecordKeys[token] = nil
        }
        for managed in session.windows.values {
            if let record = windowSystem.recoveryRecord(
                for: managed.token, managed: managed,
                stageIntent: managed.visibility == .stagedByTiles) {
                // Titles and exact-peer ordinals can change while a window is
                // alive. Replace the previous identity instead of leaving an
                // unreachable stale record in the journal.
                if let oldKey = updatedRecordKeys[managed.token], oldKey != record.identityKey {
                    updated = updated.removing(identityKey: oldKey)
                }
                updated = updated.adding(record)
                updatedRecordKeys[managed.token] = record.identityKey
            }
        }
        journal = updated
        recordKeys = updatedRecordKeys
        try? persistJournal(updated)
    }

    nonisolated private func workspaceDestination(for event: TilesEvent,
                                                  from source: WorkspaceID) -> WorkspaceID? {
        switch event {
        case .switchWorkspace(let destination):
            return destination
        case .nextWorkspace:
            return WorkspaceID(rawValue: source.rawValue == 4 ? 1 : source.rawValue + 1)
        case .previousWorkspace:
            return WorkspaceID(rawValue: source.rawValue == 1 ? 4 : source.rawValue - 1)
        default:
            return nil
        }
    }

    nonisolated private func persistJournal(_ journal: RecoveryJournal) throws {
        if journal.records.isEmpty { try journalStore.remove() }
        else { try journalStore.write(journal) }
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

    nonisolated private func noOpPresentation(for event: TilesEvent) -> TilesPresentation? {
        switch event {
        case .cycleFocusedTile:
            return .failure("No other reachable window is available in the focused tile.")
        case .focusTile(let direction):
            return .failure("No reachable window is available to the \(directionName(direction)).")
        case .moveFocusedWindowToTile(let direction):
            return .failure("The focused window could not move \(directionName(direction)).")
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
             .moveFocusedWindow, .focusTile, .moveFocusedWindowToTile:
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

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum TilesCoordinatorError: LocalizedError {
    case noUsableDisplays

    var errorDescription: String? {
        "Tiles could not resolve a valid Zones layout for a connected display."
    }
}
