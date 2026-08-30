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
        check(decoded.focusTileLeft == nil && decoded.toggleSplitOrientation == nil,
              "tiles settings: legacy schema leaves new shortcuts unassigned")

        func binding(_ action: String, _ keyCode: Int) -> ShortcutBinding {
            ShortcutBinding(action: action, keyCode: keyCode, modifiers: 256)
        }
        let full = TilesSettings(
            tileSpacingEnabled: false,
            focusTileLeft: binding("focusTileLeft", 0),
            focusTileRight: binding("focusTileRight", 1),
            focusTileUp: binding("focusTileUp", 2),
            focusTileDown: binding("focusTileDown", 3),
            moveWindowLeft: binding("moveWindowLeft", 4),
            moveWindowRight: binding("moveWindowRight", 5),
            moveWindowUp: binding("moveWindowUp", 6),
            moveWindowDown: binding("moveWindowDown", 7),
            toggleSplitOrientation: binding("toggleSplitOrientation", 8))
        check(try TilesSettings.decode(full.encoded()) == full,
              "tiles settings: spacing and all directional shortcuts round-trip")
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
    check(axSource.contains("candidateToEntry") &&
          !axSource.contains("if matches.count == 1"),
          "tiles runtime: same-frame windows use collective one-to-one correlation")
    check(axSource.contains("candidateEntries[index].entry"),
          "tiles runtime: recovery keeps the matcher candidate-to-entry mapping")
    check(axSource.contains("case kAXFocusedWindowChangedNotification") &&
          axSource.contains("externalActivation(focused)"),
          "tiles runtime: focused-window changes carry the focused token")
    check(axSource.contains("return .failure(effect, .cannotComplete)"),
          "tiles runtime: an existing unreachable window is not reported as gone")
    check(axSource.contains("eligibilityResolved") &&
          axSource.contains("initiallyMinimized") &&
          axSource.contains("let hasUsableFrame") &&
          axSource.contains("hasUsableFrame && minimized != nil"),
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
    check(coordinatorSource.contains("deminimizesWindow") &&
          coordinatorSource.contains("priorStageIntent"),
          "tiles runtime: staging intent survives until verified deminimize")
    check(coordinatorSource.contains("detachedTokens") &&
          coordinatorSource.contains("includeDetached: true"),
          "tiles runtime: freeform detachment persists until explicit placement")
    check(coordinatorSource.contains("removing(identityKey: oldKey)"),
          "tiles runtime: title changes remove the previous journal identity")
    check(coordinatorSource.contains("synchronizeJournalWithSession()") &&
          coordinatorSource.contains("windowSystem.apply(compensation)"),
          "tiles runtime: failed effects rewrite the journal from the prior session")
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
    check(coordinatorSource.contains("func update(settings: TilesSettings)") &&
          coordinatorSource.contains("layouts.gapPoints = effectiveGapPoints") &&
          coordinatorSource.contains("enqueue(.layoutChanged)"),
          "tiles runtime: settings updates apply spacing and reflow once")
    check(coordinatorSource.contains("rawFrame(for: address)") &&
          reducerSource.contains("layouts.frame(for: managed.tile)"),
          "tiles runtime: placement uses raw geometry while AX effects use spaced frames")
    check(coordinatorSource.contains("case .focusTile(let direction)") &&
           coordinatorSource.contains("case .moveFocusedWindowToTile(let direction)") &&
           coordinatorSource.contains("case .toggleFocusedSplitOrientation"),
          "tiles runtime: all directional and split actions reach the coordinator")
    check(coordinatorSource.contains("enqueueRelativeWorkspaceMove(forward:") &&
           coordinatorSource.contains("let source = self.session.activeWorkspace"),
          "tiles runtime: relative window moves resolve from serialized workspace state")
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
          toolSource.contains("coordinator.perform(.moveFocusedWindowToTile(.down))"),
          "tiles runtime: shortcuts map to all four directional runtime actions")
    check(paneSource.contains("Space between tiles") &&
          paneSource.contains("Keep \\(Int(TilesSettings.tileSpacingPoints)) pt") &&
          toolSource.contains("Focus Tile Left") &&
          toolSource.contains("Move Window Down") &&
          toolSource.contains("Switch Split Direction"),
          "tiles runtime: Settings exposes the concise spacing and shortcut controls")
    check(paneSource.contains("Workspace and stacks") &&
          paneSource.contains("Focus tile") &&
          paneSource.contains("Move window") &&
          paneSource.contains("Layout"),
          "tiles runtime: directional shortcuts are grouped for readable Settings")
    check(toolSource.contains("let focus = NSMenuItem(title: \"Focus Tile\"") &&
          toolSource.contains("let moveTile = NSMenuItem(title: \"Move Focused Window\"") &&
          toolSource.contains("Switch Split Direction") &&
          toolSource.contains("item.isEnabled = runtimeReady"),
          "tiles runtime: menu exposes directional controls only when runtime is ready")
    check(layoutSource.contains("framesByScreen") &&
          mutationSource.contains("enum ZoneLayoutMutationResult") &&
          mutationSource.contains("toggleParentSplit"),
          "tiles runtime: Zones geometry and split edits use typed shell seams")
    check(journalSource.contains("0o600") && journalSource.contains("Darwin.rename"),
          "tiles runtime: journal uses mode 0600 and atomic rename")
}
