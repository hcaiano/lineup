import AppCore
import Foundation
import TilesCore
import ZonesCore

func runTilesRuntimeTests() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("lineup-tiles-runtime-tests-\(UUID().uuidString)")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    do {
        let store = LineupAppConfigStore(url: directory.appendingPathComponent("config.json"))
        var changes: [Set<ToolID>] = []
        let observation = store.observeToolChanges { changes.append($0) }
        try store.setEnabled(true, for: .zones)
        check(changes == [[.zones]], "tiles runtime: config publishes the changed tool after write")
        try store.setEnabled(true, for: .zones)
        check(changes.count == 1, "tiles runtime: a no-op config update publishes nothing")
        observation.cancel()
        try store.setEnabled(true, for: .tiles)
        check(changes.count == 1, "tiles runtime: cancelled config observation receives nothing")
    }

    do {
        let blocker = directory.appendingPathComponent("not-a-directory")
        check(fileManager.createFile(atPath: blocker.path, contents: Data()),
              "tiles runtime: creates write blocker fixture")
        let store = LineupAppConfigStore(url: blocker.appendingPathComponent("config.json"))
        var published = false
        let observation = store.observeToolChanges { _ in published = true }
        do {
            try store.setEnabled(true, for: .zones)
            check(false, "tiles runtime: blocked config write throws")
        } catch {
            check(!published, "tiles runtime: failed config write publishes nothing")
        }
        observation.cancel()
    }

    do {
        // Settings written by the first Tiles implementation did not contain
        // the newer behavior flag or directional shortcuts.  The decoder
        // keeps that configuration valid and enables the safe default.
        let legacy = Data("{\"schemaVersion\":1}".utf8)
        let decoded = try TilesSettings.decode(legacy)
        check(decoded.tileSpacingEnabled,
              "tiles settings: legacy schema defaults to tile spacing enabled")
        check(!decoded.hasConfirmedInitialArrangement,
              "tiles settings: legacy schema still requires the first arrangement confirmation")
        check(decoded.workspace1 == nil && decoded.workspace4 == nil &&
              decoded.focusTileLeft == nil && decoded.toggleSplitOrientation == nil &&
              decoded.toggleTiled == nil,
              "tiles settings: legacy schema leaves new shortcuts unassigned")

        func binding(_ action: String, _ keyCode: Int) -> ShortcutBinding {
            ShortcutBinding(action: action, keyCode: keyCode, modifiers: 256)
        }
        let full = TilesSettings(
            tileSpacingEnabled: false,
            hasConfirmedInitialArrangement: true,
            workspace1: binding("workspace1", 9),
            workspace2: binding("workspace2", 10),
            workspace3: binding("workspace3", 11),
            workspace4: binding("workspace4", 12),
            focusTileLeft: binding("focusTileLeft", 0),
            focusTileRight: binding("focusTileRight", 1),
            focusTileUp: binding("focusTileUp", 2),
            focusTileDown: binding("focusTileDown", 3),
            moveWindowLeft: binding("moveWindowLeft", 4),
            moveWindowRight: binding("moveWindowRight", 5),
            moveWindowUp: binding("moveWindowUp", 6),
            moveWindowDown: binding("moveWindowDown", 7),
            toggleSplitOrientation: binding("toggleSplitOrientation", 8),
            toggleTiled: binding("toggleTiled", 13))
        check(try TilesSettings.decode(full.encoded()) == full,
              "tiles settings: consent, spacing, and all directional shortcuts round-trip")
    }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let axSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/Tools/Tiles/AXWindowSystem.swift"))
    let coordinatorSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/Tools/Tiles/TilesCoordinator.swift"))
    let toolSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/Tools/Tiles/TilesTool.swift"))
    let paneSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/Tools/Tiles/TilesSettingsPane.swift"))
    let layoutSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/App/ZoneLayoutSource.swift"))
    let mutationSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/App/ZoneLayoutMutationCenter.swift"))
    let reducerSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/TilesCore/TilesReducer.swift"))
    let journalSource = try String(contentsOf: root.appendingPathComponent(
        "Sources/lineup/Tools/Tiles/TilesRecoveryJournalStore.swift"))

    check(axSource.contains("DispatchQueue(label: \"com.caiano.lineup.tiles.ax\""),
          "tiles runtime: AX work has a dedicated serial queue")
    if let implementation = axSource.range(of: "final class AXWindowSystem"),
       let start = axSource.range(of: "func start(_ receive:",
                                  range: implementation.upperBound..<axSource.endIndex),
       let snapshot = axSource.range(of: "func snapshot(_ scope:",
                                     range: start.upperBound..<axSource.endIndex) {
        let body = axSource[start.lowerBound..<snapshot.lowerBound]
        check(axSource.contains("func updateScreens(_ screens: [LiveScreen]) {\n        queue.async") &&
              body.contains("let generation = currentCancellationGeneration()") &&
              body.contains("queue.async { [weak self] in") &&
              body.contains("cancellationGeneration: generation") && !body.contains("queue.sync"),
              "tiles runtime: startup discovery and screen updates do not block MainActor")
    } else {
        check(false, "tiles runtime: startup discovery and screen updates do not block MainActor")
    }
    check(axSource.contains("CFEqual(lhs.element, rhs.element)"),
          "tiles runtime: AX identity uses ephemeral CFEqual matching")
    check(axSource.contains("AXUIElementSetMessagingTimeout(element, 0.25)"),
          "tiles runtime: every retained AX element receives a bounded timeout")
    check(axSource.contains("optionOnScreenOnly"),
          "tiles runtime: eligibility uses the public current-space CG snapshot")
    check(axSource.contains("let reachable = minimized || correlated.contains(entry.token)"),
          "tiles runtime: retained minimized windows remain valid bulk mutation targets")
    check(!axSource.contains("CGS") && !axSource.contains("SkyLight"),
          "tiles runtime: no private Space API is present")
    check(axSource.contains("WindowCorrelation.reachableEntryIndices") &&
          axSource.contains("candidateCount: candidates.count") &&
          !axSource.contains("entry.token.rawValue.uuidString"),
          "tiles runtime: balanced AX/CG stack components stay reachable without identity tie-breaks")
    check(axSource.contains("candidateEntries[index].entry"),
          "tiles runtime: recovery keeps the matcher candidate-to-entry mapping")
    check(axSource.contains("pendingGoneTokens[entry.token] = entry.pid"),
          "tiles runtime: dead-process pruning exposes gone tokens to reconciliation")
    check(axSource.contains("case kAXFocusedWindowChangedNotification") &&
          axSource.contains("externalActivation(focused)"),
          "tiles runtime: focused-window changes carry the focused token")
    check(axSource.contains("return .failure(effect, .cannotComplete)"),
          "tiles runtime: an existing unreachable window is not reported as gone")
    check(axSource.contains("eligibilityResolved") &&
          axSource.contains("initiallyMinimized") &&
          axSource.contains("let hasUsableFrame") &&
          axSource.contains("hasUsableFrame && minimized != nil") &&
          axSource.contains("let fullScreen = fullScreenObservation(of: window)") &&
          axSource.contains("if error == .attributeUnsupported { return false }") &&
          axSource.contains("fullScreen == false"),
          "tiles runtime: incomplete initial eligibility can settle without losing minimized state")
    check(reducerSource.contains("!entry.isMinimized") &&
          reducerSource.contains("isBestEffort"),
          "tiles runtime: Space barrier and best-effort effects have explicit guards")
    check(coordinatorSource.contains("persistJournal(intendedJournal)"),
          "tiles runtime: journal intent is persisted before effects")
    check(coordinatorSource.contains("windowSystem.apply(plan.effects)"),
          "tiles runtime: coordinator applies the pure effect plan")
    check(coordinatorSource.contains("TilesReducer.commit"),
          "tiles runtime: coordinator commits only through TilesCore")
    check(coordinatorSource.contains(
              "committed.mutationGeneration != plan.mutationID.rawValue") &&
          !coordinatorSource.contains("committed == priorSession"),
          "tiles runtime: essential failures are detected by the committed mutation generation")
    check(coordinatorSource.contains("case .externalActivation(let token)") &&
          coordinatorSource.contains("session.windows[token]?.workspace"),
          "tiles runtime: external activation retries from committed window ownership")
    check(coordinatorSource.contains("func cyclerWindowRoute(for element: AXUIElement) -> CyclerWindowRoute") &&
          coordinatorSource.contains("requestInactiveActivation: { [weak self] in") &&
          coordinatorSource.contains("self?.enqueueCyclerExternalActivation(token)") &&
          coordinatorSource.contains("private func enqueueCyclerExternalActivation(_ token: WindowToken)") &&
          coordinatorSource.contains("managed.workspace != self.session.activeWorkspace") &&
          coordinatorSource.contains("self.process(.externalActivation(token), snapshot: snapshot, layouts: layouts)"),
          "tiles runtime: Cycler explicitly queues an inactive managed token as external activation")
    check(coordinatorSource.contains("noOpPresentation(for: event, snapshot: snapshot)") &&
          coordinatorSource.contains("Only an unmanaged focus is actionable"),
          "tiles runtime: normal directional no-ops stay silent while unmanaged focus is reported")
    check(coordinatorSource.contains("snapshotScope: SnapshotScope") &&
          coordinatorSource.contains("snapshot(snapshotScope)") &&
          coordinatorSource.contains("snapshotScope: .pid(pid)") &&
          axSource.contains("case windowChanged(WindowToken, pid_t)"),
          "tiles runtime: coalesced window and application events use pid-scoped snapshots")
    check(coordinatorSource.contains("wasStagedByTiles") &&
          coordinatorSource.contains("priorStageIntent"),
          "tiles runtime: staging intent survives until verified deminimize")
    check(coordinatorSource.contains("detachedTokens") &&
          coordinatorSource.contains("includeDetached: true"),
          "tiles runtime: freeform detachment persists until explicit placement")
    if let toggleStart = coordinatorSource.range(of: "private func toggleFocusedTiled()"),
       let frameStart = coordinatorSource.range(of: "private nonisolated static func safeAdoptionFrame",
                                                range: toggleStart.upperBound..<coordinatorSource.endIndex) {
        let toggleBody = coordinatorSource[toggleStart.lowerBound..<frameStart.lowerBound]
        check(coordinatorSource.contains("private let currentScreens: @MainActor () -> [LiveScreen]") &&
              coordinatorSource.contains("currentScreens: @escaping @MainActor () -> [LiveScreen] = LiveScreen.current") &&
              toggleBody.contains("WindowEffect.setFrame") &&
              toggleBody.contains("managed.adoptionFrame") &&
              toggleBody.contains("let screens = currentScreens()") &&
              !toggleBody.contains("self.screens") &&
              toggleBody.contains("apply([effect]).first?.succeeded == true") &&
              toggleBody.contains("preCommitFailureMessage") &&
              toggleBody.contains("process(.detach(focused)") &&
              toggleBody.contains("process(.adopt(focused)") &&
              coordinatorSource.contains("ScreenPicker.bestScreenIndex") &&
              coordinatorSource.contains("FixedPlacement.center") &&
              coordinatorSource.contains("case .adopt(let token):") &&
              coordinatorSource.contains("detachedTokens.remove(token)"),
              "tiles runtime: the tiled/freeform toggle uses current screens, verifies the safe frame, and clears its marker on adoption")
    } else {
        check(false, "tiles runtime: the tiled/freeform toggle uses current screens, verifies the safe frame, and clears its marker on adoption")
    }
    check(coordinatorSource.contains("private(set) var runtimePauseMessage: String?") &&
          coordinatorSource.contains("runtimePauseReason == nil") &&
          coordinatorSource.contains("transitionRuntimePause(to: nil)") &&
          coordinatorSource.contains("guard previous != message else { return }") &&
          coordinatorSource.contains("Zones layout is unavailable for a connected monitor") &&
          coordinatorSource.contains("Tiles will resume automatically") &&
          coordinatorSource.contains(".confirmation(\"Tiles resumed\")") &&
          coordinatorSource.contains("if let runtimePauseMessage {\n            onPresentation?(.failure(runtimePauseMessage))"),
          "tiles runtime: layout failure pauses once, reports blocked commands, and confirms automatic recovery")
    check(coordinatorSource.contains("removing(identityKey: oldKey)"),
          "tiles runtime: title changes remove the previous journal identity")
    check(coordinatorSource.contains("synchronizeJournalWithSession()") &&
          coordinatorSource.contains("windowSystem.apply(compensation)"),
          "tiles runtime: failed effects rewrite the journal from the prior session")
    check(coordinatorSource.contains("let compensationResults = windowSystem.apply(compensation)") &&
          coordinatorSource.contains("synchronizeJournalWithSession(preserving: unresolvedTokens)") &&
          coordinatorSource.contains("session = committed"),
          "tiles runtime: unresolved compensation keeps recovery intent and removes gone windows")
    check(coordinatorSource.contains("synchronizeJournalWithSession(\n        preserving preservedTokens:") &&
          coordinatorSource.contains("clearingStageIntentFor clearedTokens:") &&
          coordinatorSource.contains("-> Bool") &&
          coordinatorSource.contains("try persistJournal(updated)\n            journal = updated") &&
          coordinatorSource.contains("completed the action but could not save recovery state"),
          "tiles runtime: post-commit journal failures are surfaced without undoing committed AX work")
    check(coordinatorSource.contains("let priorStageIntent = previousKey.flatMap") &&
          coordinatorSource.contains("priorStageIntent && !clearedTokens.contains(managed.token)") &&
          coordinatorSource.contains("case .setMinimized(let token, false, _) = result.effect") &&
          coordinatorSource.contains("clearingStageIntentFor: clearedStageIntentTokens"),
          "tiles runtime: staged recovery intent survives identity changes and clears only after committed deminimize")
    check(coordinatorSource.contains("let wasStagedByTiles = session.windows[token]?.visibility == .stagedByTiles") &&
          coordinatorSource.contains("wasStagedByTiles || priorStageIntent") &&
          !coordinatorSource.contains("priorStageIntent || deminimizesWindow"),
          "tiles runtime: restoring a user-minimized Cycler target never creates Tiles recovery ownership")
    check(axSource.contains("for attempt in 0..<3") &&
          axSource.contains("if bool(element, attribute) == value { return .success }") &&
          axSource.contains("if attempt < 2 { usleep(40_000) }") &&
          axSource.contains("return error == .success ? .cannotComplete : error"),
          "tiles runtime: delayed AX Boolean writes use a bounded observed-postcondition check")
    check(axSource.contains("var identityChangedPIDs = Set<pid_t>()") &&
          axSource.components(separatedBy: "identityChangedPIDs.insert(entry.pid)").count - 1 == 2 &&
          axSource.contains("refreshTrackedIdentity(for: identityChangedPIDs") &&
          axSource.contains("cancellationGeneration: generation") &&
          axSource.contains("scanning: pids"),
          "tiles runtime: verified minimize changes refresh recovery identity once per cancellable batch")
    check(coordinatorSource.contains("guard let self, self.acceptingEvents else { return }") &&
          coordinatorSource.contains("guard self.acceptingEvents else { return }"),
          "tiles runtime: a stopped coordinator cannot complete late startup recovery")
    check(coordinatorSource.contains("snapshot.windows[$0]?.isAvailableForPlacement") &&
          coordinatorSource.contains("let entry = snapshot.windows[token], entry.isVisible"),
          "tiles runtime: previews and placement changes require visible stack members")
    check(coordinatorSource.contains("guard let focused = snapshot.focused") &&
          coordinatorSource.contains("guard stack.contains(focused) else { continue }") &&
          !coordinatorSource.contains("session.windows[$0]?.visibility != .minimizedByUser") &&
          !coordinatorSource.contains("The focused tile preview is not available."),
          "tiles runtime: cycle preview stays anchored to the tile that was cycled")
    check(coordinatorSource.contains("runtimeQueue.sync") &&
          coordinatorSource.contains("healingWork.removeAll"),
          "tiles runtime: healing work is cancelled on its owning queue")
    check(!coordinatorSource.contains("prefix(7)"),
          "tiles runtime: stack presentation keeps the complete stack")
    check(coordinatorSource.contains("else if case .moveFocusedWindowToTile = event") &&
          coordinatorSource.contains("if let preview { return .addedToStack(preview) }") &&
          toolSource.contains("case addedToStack(TilesStackPreview)") &&
          toolSource.contains("title: \"Added to stack\""),
          "tiles runtime: moving into an occupied tile reports the committed stack")
    check(coordinatorSource.contains("func update(settings: TilesSettings)") &&
          coordinatorSource.contains("layouts.gapPoints = effectiveGapPoints") &&
          coordinatorSource.contains("enqueue(.layoutChanged)"),
          "tiles runtime: settings updates apply spacing and reflow once")
    check(coordinatorSource.contains("rawFrame(for: address)") &&
          reducerSource.contains("layouts.frame(for: managed.tile)"),
          "tiles runtime: placement uses raw geometry while AX effects use spaced frames")
    check(coordinatorSource.contains("case .focusTile(let direction)") &&
           coordinatorSource.contains("case .moveFocusedWindowToTile(let direction)") &&
           coordinatorSource.contains("case .toggleFocusedSplitOrientation") &&
           coordinatorSource.contains("case .toggleFocusedTiled"),
          "tiles runtime: all directional, split, and toggle actions reach the coordinator")
    check(coordinatorSource.contains("enqueueRelativeWorkspaceMove(forward:") &&
           coordinatorSource.contains("let source = self.session.activeWorkspace"),
          "tiles runtime: relative window moves resolve from serialized workspace state")
    check(coordinatorSource.contains("var existingOnly = snapshot") &&
          coordinatorSource.contains("existingOnly.windows = snapshot.windows.filter") &&
          coordinatorSource.contains("process(.reconcile, snapshot: existingOnly"),
          "tiles runtime: unmanaged application activation reconciles without adoption")
    check(coordinatorSource.contains("toggleParentSplit(") &&
          coordinatorSource.contains("screenKey: screenKey") &&
          coordinatorSource.contains("leafIndex: leafIndex") &&
          coordinatorSource.contains("case .changed") &&
          coordinatorSource.contains("case .unavailable(let message)"),
          "tiles runtime: split feedback follows the persisted Zones result")
    check(toolSource.contains("let spacingChanged = settings.tileSpacingEnabled") &&
          toolSource.contains("if spacingChanged { coordinator.update(settings: newSettings) }") &&
          toolSource.contains("var reverseAction: ReverseAction?"),
          "tiles runtime: only spacing edits reflow and reverse metadata is explicit")
    check(toolSource.contains("coordinator.perform(.focusTile(.left))") &&
          toolSource.contains("coordinator.perform(.moveFocusedWindowToTile(.down))") &&
          toolSource.contains("coordinator.perform(.toggleFocusedTiled)"),
          "tiles runtime: shortcuts map to directional actions and tiled/freeform toggle")
    check(paneSource.contains("Space between tiles") &&
          paneSource.contains("Keep \\(Int(TilesSettings.tileSpacingPoints)) pt") &&
          toolSource.contains("Focus Tile Left") &&
          toolSource.contains("Move Window Down") &&
          toolSource.contains("Switch Split Direction"),
          "tiles runtime: Settings exposes the concise spacing and shortcut controls")
    check(paneSource.contains("Workspace and stacks") &&
          paneSource.contains("Focus tile") &&
          paneSource.contains("Move window") &&
          paneSource.contains("Layout") &&
          paneSource.contains("Workspace shortcuts switch workspaces; physical Shift moves the focused window.") &&
          paneSource.contains("Add physical Shift to the full stack shortcut to cycle in reverse") &&
          paneSource.contains("Add physical Shift to the full stack shortcut to cycle in reverse."),
          "tiles runtime: shortcuts are grouped and explain workspace reverses")
    check(toolSource.contains("let focus = NSMenuItem(title: \"Focus Tile\"") &&
          toolSource.contains("let moveTile = NSMenuItem(title: \"Move Focused Window\"") &&
          toolSource.contains("Switch Split Direction") &&
          toolSource.contains("Toggle Tiled / Freeform") &&
          toolSource.contains("item.isEnabled = runtimeUsable") &&
          toolSource.contains("restore.isEnabled = runtimeReady"),
          "tiles runtime: menu disables mutations during pause but keeps recovery available")
    check(layoutSource.contains("framesByScreen") &&
          mutationSource.contains("enum ZoneLayoutMutationResult") &&
          mutationSource.contains("toggleParentSplit"),
          "tiles runtime: Zones geometry and split edits use typed shell seams")
    check(journalSource.contains("0o600") && journalSource.contains("Darwin.rename"),
          "tiles runtime: journal uses mode 0600 and atomic rename")
}
