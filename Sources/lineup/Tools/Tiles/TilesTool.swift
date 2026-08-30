import AppKit
import AppCore
import Carbon.HIToolbox
import SwiftUI
import TilesCore
import ZonesCore
import os

/// Actions the shell can ask the Tiles runtime to perform.
///
/// The protocol is deliberately small and contains no Accessibility types. The runtime worker
/// implements it without making Settings know about AX elements.
enum TilesRuntimeAction: Equatable {
    case switchWorkspace(Int)
    case nextWorkspace
    case previousWorkspace
    case nextWindow
    case previousWindow
    case moveFocusedWindow(toWorkspace: Int)
    case moveFocusedWindowToNextWorkspace
    case moveFocusedWindowToPreviousWorkspace
    case focusTile(TileDirection)
    case moveFocusedWindowToTile(TileDirection)
    case toggleFocusedSplitOrientation
}

/// Small stack preview supplied by a running coordinator for the non-activating HUD.
/// Window identity never crosses into TilesCore or the persisted settings section.
struct TilesStackPreview {
    var appIcon: NSImage?
    var titles: [String]
    var selectedIndex: Int
}

/// User feedback emitted only after the runtime has confirmed an action. This keeps the HUD in
/// step with the committed workspace and stack state instead of guessing from stale state.
enum TilesPresentation {
    case workspace(Int)
    case movedWindow(Int)
    case stack(TilesStackPreview)
    case confirmation(String)
    case recoveryCompleted
    case failure(String)
}

/// Shell/runtime seam for Tiles.
///
/// A concrete coordinator owns the AX worker, Zones layout source, observers and recovery journal.
/// `TilesTool` owns only lifecycle, config, hotkeys and user-facing state. Keeping this protocol in
/// the app target prevents Settings from owning AX work.
@MainActor
protocol TilesCoordinatorProtocol: AnyObject {
    var activeWorkspace: Int { get }
    var recoveryRequired: Bool { get }
    var stackPreview: TilesStackPreview? { get }
    var onStateChange: (() -> Void)? { get set }
    var onPresentation: ((TilesPresentation) -> Void)? { get set }

    func start(settings: TilesSettings) throws
    func update(settings: TilesSettings)
    func stop()
    func perform(_ action: TilesRuntimeAction)
    func restoreWindows()
}

/// Tiles automatically places eligible windows in the leaves owned by Zones and exposes four
/// lightweight workspaces. This shell owns persisted settings and hotkeys; the coordinator owns
/// all Accessibility work and can be replaced by the runtime implementation without changing
/// the Settings contract.
@MainActor
final class TilesTool: Tool {
    let id = ToolID.tiles
    let displayName = "Tiles"
    let summary = "Automatically tile windows into your Zones, with workspaces and stacks."
    let iconSymbol = "square.grid.3x3.fill"
    /// Tiles reads and changes normal application windows through public Accessibility APIs.
    let requiredPermissions: Set<Permission> = [.accessibility]
    /// A silent update must not begin arranging windows on an existing desktop.
    let defaultEnabled = false

    private(set) var isRunning = false
    private(set) var settings = TilesSettings()

    /// A section that exists but cannot be decoded must remain untouched. The pane then offers a
    /// reset, and start acquires no runtime resources until the user repairs the section.
    private(set) var sectionLoadError: String?

    private var services: ToolServices?
    private let coordinator: TilesCoordinatorProtocol
    private var coordinatorStarted = false
    private(set) var runtimeReady = false
    private(set) var runtimeBlockedMessage: String?
    private(set) var isRestoringWindows = false
    private var hotkeyTokens: [HotkeyManager.Token] = []
    private var failedHotkeys: [FailedHotkey] = []
    private var failedHotkeyRetryTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// `ToolRegistry.boundCombos()` asks every tool for its persisted rows. Tiles also needs
    /// that aggregate while deciding whether a generated reverse is safe, so guard the one
    /// intentional re-entry and let the nested Tiles call contribute only its own rows.
    private var isComputingPersistedCombos = false
    /// Avoid constructing the singleton panel on a blocked start/stop path. A disabled tool
    /// should leave no visible UI or HUD object behind if it never displayed one.
    private var hudWasUsed = false
    private lazy var settingsModel = TilesSettingsModel(tool: self)
    private var log: Logger { services?.log ?? Logger(subsystem: Product.logSubsystem, category: "tiles") }

    private enum Action: String, CaseIterable {
        case nextWorkspace
        case nextWindow
        case moveWindowToNextWorkspace
        case focusTileLeft
        case focusTileRight
        case focusTileUp
        case focusTileDown
        case moveWindowLeft
        case moveWindowRight
        case moveWindowUp
        case moveWindowDown
        case toggleSplitOrientation

        /// Only cyclic actions get an implicit Shift reverse.  Keeping this
        /// metadata on the action prevents directional shortcuts from
        /// accidentally acquiring a reverse when new actions are added.
        private enum ReverseAction {
            case previousWorkspace
            case previousWindow
            case moveWindowToPreviousWorkspace
        }

        private var reverseAction: ReverseAction? {
            switch self {
            case .nextWorkspace: return .previousWorkspace
            case .nextWindow: return .previousWindow
            case .moveWindowToNextWorkspace: return .moveWindowToPreviousWorkspace
            default: return nil
            }
        }

        var hasGeneratedReverse: Bool { reverseAction != nil }

        var title: String {
            switch self {
            case .nextWorkspace: return "Next Workspace"
            case .nextWindow: return "Next Window in Tile"
            case .moveWindowToNextWorkspace: return "Move Window to Next Workspace"
            case .focusTileLeft: return "Focus Tile Left"
            case .focusTileRight: return "Focus Tile Right"
            case .focusTileUp: return "Focus Tile Up"
            case .focusTileDown: return "Focus Tile Down"
            case .moveWindowLeft: return "Move Window Left"
            case .moveWindowRight: return "Move Window Right"
            case .moveWindowUp: return "Move Window Up"
            case .moveWindowDown: return "Move Window Down"
            case .toggleSplitOrientation: return "Switch Split Direction"
            }
        }

        var binding: (TilesSettings) -> ShortcutBinding? {
            switch self {
            case .nextWorkspace: return { $0.nextWorkspace }
            case .nextWindow: return { $0.nextWindow }
            case .moveWindowToNextWorkspace: return { $0.moveWindowToNextWorkspace }
            case .focusTileLeft: return { $0.focusTileLeft }
            case .focusTileRight: return { $0.focusTileRight }
            case .focusTileUp: return { $0.focusTileUp }
            case .focusTileDown: return { $0.focusTileDown }
            case .moveWindowLeft: return { $0.moveWindowLeft }
            case .moveWindowRight: return { $0.moveWindowRight }
            case .moveWindowUp: return { $0.moveWindowUp }
            case .moveWindowDown: return { $0.moveWindowDown }
            case .toggleSplitOrientation: return { $0.toggleSplitOrientation }
            }
        }
    }

    private struct HotkeyCombo: Hashable {
        var keyCode: Int
        var modifiers: UInt32
    }

    private struct FailedHotkey {
        var action: Action
        var keyCode: Int
        var modifiers: UInt32
        var reason: String
        var generatedReverse: Bool
    }

    init(coordinator: TilesCoordinatorProtocol) {
        self.coordinator = coordinator
    }

    // MARK: Lifecycle

    /// Registration gives the tool its config scope. It acquires no runtime resource, so Settings
    /// remains editable while Tiles is off.
    func attach(_ services: ToolServices) {
        self.services = services
        loadSettings()
        settingsModel.refresh()
    }

    /// Start keeps the enabled tool visible in the menu even when a required preflight is blocked,
    /// but it does not acquire hotkeys or coordinator resources in that state.
    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        loadSettings()
        isRunning = true
        runtimeReady = false
        runtimeBlockedMessage = nil
        attemptRuntimeStart()
        settingsModel.refresh()
        services.refreshMenu()
        services.refreshSettings()
    }

    /// Stop is synchronous and idempotent. Every resource acquired by start is returned here,
    /// including the coordinator boundary, hotkeys, retry timer, observer and HUD.
    func stop() {
        guard isRunning else { return }
        services?.hotkeys.unregisterAll()
        hotkeyTokens.removeAll()
        failedHotkeys.removeAll()
        failedHotkeyRetryTimer?.invalidate()
        failedHotkeyRetryTimer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        coordinator.onStateChange = nil
        coordinator.onPresentation = nil
        if coordinatorStarted { coordinator.stop() }
        coordinatorStarted = false
        runtimeReady = false
        runtimeBlockedMessage = nil
        isRunning = false
        if hudWasUsed {
            TilesHUD.shared.dismiss()
            hudWasUsed = false
        }
        settingsModel.refresh()
        services?.refreshMenu()
        services?.refreshSettings()
    }

    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    if self.runtimeReady {
                        self.retryFailedHotkeys()
                    } else {
                        self.attemptRuntimeStart()
                    }
                }
            }
    }

    private func attemptRuntimeStart() {
        guard isRunning, !runtimeReady else { return }

        guard sectionLoadError == nil else {
            runtimeBlockedMessage = nil
            settingsModel.refresh()
            services?.refreshMenu()
            return
        }
        guard let services else { return }
        guard services.config.canWrite else {
            runtimeBlockedMessage = services.config.blockedMessage
                ?? "Tiles cannot start because your settings file cannot be saved."
            settingsModel.refresh()
            services.refreshMenu()
            return
        }
        // A config rejection is repaired explicitly from the pane and owns no retry observer.
        // Accessibility is different: the user can grant it in System Settings while Tiles
        // stays enabled, so keep one app-activation retry observer for that preflight only.
        installActivationObserver()
        guard services.permissions.isAccessibilityTrusted else {
            runtimeBlockedMessage = "Tiles needs Accessibility access to arrange application windows."
            settingsModel.refresh()
            services.refreshMenu()
            return
        }

        coordinator.onStateChange = { [weak self] in
            guard let self else { return }
            self.settingsModel.refresh()
            self.services?.refreshMenu()
            self.services?.refreshSettings()
        }
        coordinator.onPresentation = { [weak self] presentation in
            guard let self else { return }
            self.handle(presentation)
        }
        do {
            try coordinator.start(settings: settings)
            coordinatorStarted = true
            runtimeReady = true
            runtimeBlockedMessage = nil
            registerHotkeys()
        } catch {
            // A coordinator must leave no resource alive when start fails. Calling stop is safe
            // for a coordinator that failed before acquiring anything and closes partial starts.
            coordinator.stop()
            coordinator.onStateChange = nil
            coordinator.onPresentation = nil
            coordinatorStarted = false
            runtimeReady = false
            runtimeBlockedMessage = "Tiles could not start safely: \(error.localizedDescription)"
            log.error("Tiles coordinator start failed: \(error, privacy: .public)")
        }
        settingsModel.refresh()
        services.refreshMenu()
        services.refreshSettings()
    }

    // MARK: Config

    private func loadSettings() {
        guard let services else { return }
        do {
            let loaded = try services.config.load(TilesSettings.self) ?? TilesSettings()
            try validate(loaded)
            settings = loaded
            sectionLoadError = nil
        } catch {
            settings = TilesSettings()
            sectionLoadError = "\(error)"
            log.error("Tiles settings could not be decoded (left untouched): \(error, privacy: .public)")
        }
    }

    private func validate(_ candidate: TilesSettings) throws {
        guard candidate.schemaVersion > 0,
              candidate.schemaVersion <= TilesSettings.currentSchema else {
            throw TilesToolError.invalidSettings("Unsupported Tiles settings schema \(candidate.schemaVersion).")
        }
        var seen = Set<HotkeyCombo>()
        for binding in bindings(in: candidate) {
            guard (0...127).contains(binding.keyCode) else {
                throw TilesToolError.invalidSettings("The Tiles shortcut key code is invalid.")
            }
            let modifiers = binding.modifiers
            guard modifiers >= 0, modifiers & ~DragSnapModifierMask.all == 0 else {
                throw TilesToolError.invalidSettings("The Tiles shortcut modifiers are invalid.")
            }
            guard seen.insert(HotkeyCombo(keyCode: binding.keyCode,
                                         modifiers: UInt32(truncatingIfNeeded: modifiers))).inserted else {
                throw TilesToolError.invalidSettings("Two Tiles actions use the same shortcut.")
            }
        }
    }

    private func bindings(in source: TilesSettings) -> [ShortcutBinding] {
        Action.allCases.compactMap { $0.binding(source) }
    }

    var canPersist: Bool { sectionLoadError == nil && (services?.config.canWrite ?? false) }
    var canEdit: Bool { canPersist }
    var canReset: Bool { services?.config.canWrite ?? false }

    var configBlockedMessage: String? {
        if sectionLoadError != nil {
            return "Your Tiles settings couldn’t be read. They were left untouched. Reset them to start editing again."
        }
        return services?.config.blockedMessage
    }

    func resetSection() {
        guard let services else { return }
        do {
            if let rejected = try services.config.load(JSONValue.self) {
                let url = Product.configDirectory.appendingPathComponent(
                    "config.tiles-rejected-\(LineupAppConfigStore.timestamp()).json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rejected).write(to: url, options: .atomic)
            }
            let fresh = TilesSettings()
            try services.config.save(fresh)
            settings = fresh
            sectionLoadError = nil
            if isRunning {
                runtimeBlockedMessage = nil
                attemptRuntimeStart()
            }
        } catch {
            log.error("Tiles reset aborted (settings left untouched): \(error, privacy: .public)")
        }
        settingsModel.refresh()
        services.refreshMenu()
        services.refreshSettings()
    }

    func save(_ newSettings: TilesSettings) throws {
        guard let services else { throw TilesToolError.notRegistered }
        guard sectionLoadError == nil else { throw TilesToolError.sectionUnreadable }
        try validate(newSettings)
        let spacingChanged = settings.tileSpacingEnabled != newSettings.tileSpacingEnabled
        try services.config.save(newSettings)
        settings = newSettings
        if runtimeReady {
            if spacingChanged { coordinator.update(settings: newSettings) }
            registerHotkeys()
        }
        settingsModel.refresh()
        services.refreshMenu()
    }

    func setTileSpacingEnabled(_ enabled: Bool) {
        guard canEdit, settings.tileSpacingEnabled != enabled else { return }
        var updated = settings
        updated.tileSpacingEnabled = enabled
        saveFromPane(updated)
    }

    // MARK: Hotkeys

    private func registerHotkeys() {
        guard isRunning, runtimeReady, let services else { return }
        services.hotkeys.unregisterAll()
        hotkeyTokens.removeAll()

        let persisted = services.boundCombos()
        let explicit = Set(bindings(in: settings).map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        var failures: [FailedHotkey] = []

        for action in Action.allCases {
            guard let binding = action.binding(settings) else { continue }
            let combo = HotkeyCombo(keyCode: binding.keyCode,
                                    modifiers: UInt32(truncatingIfNeeded: binding.modifiers))
            if let owner = persisted.conflictOwner(keyCode: combo.keyCode,
                                                   modifiers: combo.modifiers,
                                                   excluding: .tiles) {
                failures.append(FailedHotkey(action: action, keyCode: combo.keyCode,
                                             modifiers: combo.modifiers,
                                             reason: "already used by \(displayName(for: owner))",
                                             generatedReverse: false))
                continue
            }
            let result = services.hotkeys.register(keyCode: combo.keyCode,
                                                   modifiers: combo.modifiers) { [weak self] in
                self?.perform(action, generatedReverse: false)
            }
            switch result {
            case .success(let token): hotkeyTokens.append(token)
            case .failure(let reason):
                failures.append(FailedHotkey(action: action, keyCode: combo.keyCode,
                                             modifiers: combo.modifiers,
                                             reason: reason.displayReason,
                                             generatedReverse: false))
            }
        }

        // A recorded combo without Shift gets one generated reverse. Explicit Shift bindings win
        // their exact combo, so the generated row is intentionally omitted in that case.
        for action in Action.allCases {
            guard action.hasGeneratedReverse,
                  let binding = action.binding(settings),
                  binding.modifiers & DragSnapModifierMask.shift == 0 else { continue }
            let forward = UInt32(truncatingIfNeeded: binding.modifiers)
            let reverse = HotkeyCombo(keyCode: binding.keyCode,
                                      modifiers: forward | UInt32(shiftKey))
            guard !explicit.contains(reverse) else { continue }
            if let owner = persisted.conflictOwner(keyCode: reverse.keyCode,
                                                   modifiers: reverse.modifiers,
                                                   excluding: .tiles) {
                // The forward action remains useful. The Settings pane only advertises the Shift
                // hint when this reverse is available, so the user is never promised a dead key.
                log.error("Tiles reverse shortcut blocked by \(self.displayName(for: owner), privacy: .public)")
                failures.append(FailedHotkey(action: action, keyCode: reverse.keyCode,
                                             modifiers: reverse.modifiers,
                                             reason: "already used by \(self.displayName(for: owner))",
                                             generatedReverse: true))
                continue
            }
            let result = services.hotkeys.register(keyCode: reverse.keyCode,
                                                   modifiers: reverse.modifiers) { [weak self] in
                self?.perform(action, generatedReverse: true)
            }
            if case .success(let token) = result {
                hotkeyTokens.append(token)
            } else if case .failure(let reason) = result {
                failures.append(FailedHotkey(action: action, keyCode: reverse.keyCode,
                                             modifiers: reverse.modifiers,
                                             reason: reason.displayReason,
                                             generatedReverse: true))
            }
        }

        failedHotkeys = failures
        for failure in failures { logHotkeyFailure(failure) }
        updateFailedHotkeyRetryTimer()
    }

    /// The conflict source includes disabled siblings and generated reverse combinations.
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] {
        let includeSiblingConflicts = !isComputingPersistedCombos
        guard includeSiblingConflicts else {
            return ownPersistedCombos(from: settings, siblingCombos: [])
        }

        isComputingPersistedCombos = true
        defer { isComputingPersistedCombos = false }

        var source = settings
        if let services, let stored = try? services.config.load(TilesSettings.self) {
            source = stored
        }
        let persisted = services?.boundCombos() ?? []
        return ownPersistedCombos(from: source, siblingCombos: persisted)
    }

    private func ownPersistedCombos(from source: TilesSettings,
                                    siblingCombos: [ToolCombo]) -> [(keyCode: Int, modifiers: UInt32)] {
        let own = bindings(in: source)
        var out: [(keyCode: Int, modifiers: UInt32)] = []
        var seen = Set<HotkeyCombo>()
        let explicit = Set(own.map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        for binding in own {
            let combo = HotkeyCombo(keyCode: binding.keyCode,
                                    modifiers: UInt32(truncatingIfNeeded: binding.modifiers))
            if seen.insert(combo).inserted { out.append((combo.keyCode, combo.modifiers)) }
        }
        for action in Action.allCases where action.hasGeneratedReverse {
            guard let binding = action.binding(source),
                  binding.modifiers & DragSnapModifierMask.shift == 0 else { continue }
            let forward = UInt32(truncatingIfNeeded: binding.modifiers)
            let reverse = HotkeyCombo(keyCode: binding.keyCode,
                                      modifiers: forward | UInt32(shiftKey))
            guard !explicit.contains(reverse),
                  siblingCombos.conflictOwner(keyCode: reverse.keyCode,
                                              modifiers: reverse.modifiers,
                                              excluding: .tiles) == nil else { continue }
            if seen.insert(reverse).inserted { out.append((reverse.keyCode, reverse.modifiers)) }
        }
        return out
    }

    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {
        guard isRunning, runtimeReady else { return }
        for failure in failures {
            let combo = HotkeyCombo(keyCode: failure.keyCode, modifiers: failure.modifiers)
            guard !failedHotkeys.contains(where: {
                HotkeyCombo(keyCode: $0.keyCode, modifiers: $0.modifiers) == combo
            }) else { continue }
            guard let match = matchingAction(for: combo) else { continue }
            failedHotkeys.append(FailedHotkey(action: match.action, keyCode: combo.keyCode,
                                              modifiers: combo.modifiers,
                                              reason: HotkeyFailure.carbon(failure.status).displayReason,
                                              generatedReverse: match.generatedReverse))
        }
        updateFailedHotkeyRetryTimer()
        services?.refreshMenu()
    }

    private func matchingAction(for combo: HotkeyCombo) -> (action: Action, generatedReverse: Bool)? {
        for action in Action.allCases {
            guard let binding = action.binding(settings) else { continue }
            let forward = HotkeyCombo(keyCode: binding.keyCode,
                                      modifiers: UInt32(truncatingIfNeeded: binding.modifiers))
            if forward == combo { return (action, false) }
            if action.hasGeneratedReverse,
               binding.modifiers & DragSnapModifierMask.shift == 0,
               HotkeyCombo(keyCode: binding.keyCode,
                           modifiers: forward.modifiers | UInt32(shiftKey)) == combo {
                return (action, true)
            }
        }
        return nil
    }

    private func updateFailedHotkeyRetryTimer() {
        guard isRunning, runtimeReady, !failedHotkeys.isEmpty else {
            failedHotkeyRetryTimer?.invalidate()
            failedHotkeyRetryTimer = nil
            return
        }
        guard failedHotkeyRetryTimer == nil else { return }
        failedHotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.retryFailedHotkeys() }
        }
    }

    private func retryFailedHotkeys() {
        guard isRunning, runtimeReady, !(services?.hotkeys.isSuspended ?? false) else {
            updateFailedHotkeyRetryTimer()
            return
        }
        registerHotkeys()
        services?.refreshMenu()
    }

    private func logHotkeyFailure(_ failure: FailedHotkey) {
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        let reverse = failure.generatedReverse ? " reverse" : ""
        log.error("Tiles\(reverse, privacy: .public) shortcut \(failure.action.title, privacy: .public) \(combo, privacy: .public) blocked: \(failure.reason, privacy: .public)")
    }

    // MARK: Actions

    private func handle(_ presentation: TilesPresentation) {
        hudWasUsed = true
        switch presentation {
        case .workspace(let workspace):
            TilesHUD.shared.showWorkspace(number: workspace)
        case .movedWindow(let workspace):
            TilesHUD.shared.showConfirmation("Moved to Workspace \(workspace)")
        case .stack(let preview):
            TilesHUD.shared.showStack(appIcon: preview.appIcon, titles: preview.titles,
                                      selectedIndex: preview.selectedIndex)
        case .confirmation(let message):
            TilesHUD.shared.showConfirmation(message)
        case .recoveryCompleted:
            isRestoringWindows = false
            TilesHUD.shared.showConfirmation("Windows restored")
        case .failure(let message):
            isRestoringWindows = false
            TilesHUD.shared.showFailure(message)
        }
        settingsModel.refresh()
        services?.refreshMenu()
        services?.refreshSettings()
    }

    private func perform(_ action: Action, generatedReverse: Bool) {
        guard runtimeReady else { return }
        switch action {
        case .nextWorkspace:
            coordinator.perform(generatedReverse ? .previousWorkspace : .nextWorkspace)
        case .nextWindow:
            coordinator.perform(generatedReverse ? .previousWindow : .nextWindow)
        case .moveWindowToNextWorkspace:
            coordinator.perform(generatedReverse
                                 ? .moveFocusedWindowToPreviousWorkspace
                                 : .moveFocusedWindowToNextWorkspace)
        case .focusTileLeft:
            coordinator.perform(.focusTile(.left))
        case .focusTileRight:
            coordinator.perform(.focusTile(.right))
        case .focusTileUp:
            coordinator.perform(.focusTile(.up))
        case .focusTileDown:
            coordinator.perform(.focusTile(.down))
        case .moveWindowLeft:
            coordinator.perform(.moveFocusedWindowToTile(.left))
        case .moveWindowRight:
            coordinator.perform(.moveFocusedWindowToTile(.right))
        case .moveWindowUp:
            coordinator.perform(.moveFocusedWindowToTile(.up))
        case .moveWindowDown:
            coordinator.perform(.moveFocusedWindowToTile(.down))
        case .toggleSplitOrientation:
            coordinator.perform(.toggleFocusedSplitOrientation)
        }
        settingsModel.refresh()
        services?.refreshMenu()
    }

    func selectWorkspace(_ workspace: Int) {
        guard runtimeReady, (1...4).contains(workspace) else { return }
        coordinator.perform(.switchWorkspace(workspace))
        settingsModel.refresh()
        services?.refreshMenu()
    }

    func cycleFocusedTile() {
        perform(.nextWindow, generatedReverse: false)
    }

    func focusTile(_ direction: TileDirection) {
        guard runtimeReady else { return }
        coordinator.perform(.focusTile(direction))
        settingsModel.refresh()
    }

    func moveFocusedWindowToTile(_ direction: TileDirection) {
        guard runtimeReady else { return }
        coordinator.perform(.moveFocusedWindowToTile(direction))
        settingsModel.refresh()
    }

    func toggleFocusedSplitOrientation() {
        guard runtimeReady else { return }
        coordinator.perform(.toggleFocusedSplitOrientation)
        settingsModel.refresh()
    }

    func moveFocusedWindowToWorkspace(_ workspace: Int) {
        guard runtimeReady, (1...4).contains(workspace) else { return }
        coordinator.perform(.moveFocusedWindow(toWorkspace: workspace))
        settingsModel.refresh()
    }

    var activeWorkspace: Int { min(max(coordinator.activeWorkspace, 1), 4) }
    var recoveryRequired: Bool { coordinator.recoveryRequired }

    func restoreWindows() {
        guard runtimeReady, !isRestoringWindows else { return }
        isRestoringWindows = true
        settingsModel.refresh()
        coordinator.restoreWindows()
        services?.refreshMenu()
    }

    func retryRuntime() {
        guard isRunning else { return }
        if coordinatorStarted {
            coordinator.onStateChange = nil
            coordinator.onPresentation = nil
            coordinator.stop()
            coordinatorStarted = false
        }
        runtimeReady = false
        runtimeBlockedMessage = nil
        attemptRuntimeStart()
    }

    // MARK: Menu and warnings

    func menuItems() -> [NSMenuItem] {
        let workspaces = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        workspaces.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let workspaceMenu = NSMenu()
        workspaceMenu.autoenablesItems = false
        for workspace in 1...4 {
            let item = ToolMenu.item("Workspace \(workspace)", symbol: "square.fill") {
                [weak self] in self?.selectWorkspace(workspace)
            }
            item.state = activeWorkspace == workspace ? .on : .off
            item.isEnabled = runtimeReady
            workspaceMenu.addItem(item)
        }
        workspaces.submenu = workspaceMenu

        let move = NSMenuItem(title: "Move Focused Window to Workspace", action: nil, keyEquivalent: "")
        move.image = NSImage(systemSymbolName: "arrow.right.square", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let moveMenu = NSMenu()
        moveMenu.autoenablesItems = false
        for workspace in 1...4 {
            let item = ToolMenu.item("Workspace \(workspace)", symbol: "arrow.right.square") {
                [weak self] in self?.moveFocusedWindowToWorkspace(workspace)
            }
            item.isEnabled = runtimeReady
            moveMenu.addItem(item)
        }
        move.submenu = moveMenu

        let cycle = ToolMenu.item("Next Window in Tile", symbol: "arrow.triangle.2.circlepath") {
            [weak self] in self?.cycleFocusedTile()
        }
        cycle.isEnabled = runtimeReady

        let focus = NSMenuItem(title: "Focus Tile", action: nil, keyEquivalent: "")
        focus.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let focusMenu = NSMenu()
        focusMenu.autoenablesItems = false
        for (direction, title, symbol) in Self.directionMenuEntries {
            let item = ToolMenu.item(title, symbol: symbol) { [weak self] in
                self?.focusTile(direction)
            }
            item.isEnabled = runtimeReady
            focusMenu.addItem(item)
        }
        focus.submenu = focusMenu
        focus.isEnabled = runtimeReady

        let moveTile = NSMenuItem(title: "Move Focused Window", action: nil, keyEquivalent: "")
        moveTile.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let moveTileMenu = NSMenu()
        moveTileMenu.autoenablesItems = false
        for (direction, title, symbol) in Self.directionMenuEntries {
            let item = ToolMenu.item(title, symbol: symbol) { [weak self] in
                self?.moveFocusedWindowToTile(direction)
            }
            item.isEnabled = runtimeReady
            moveTileMenu.addItem(item)
        }
        moveTile.submenu = moveTileMenu
        moveTile.isEnabled = runtimeReady

        let toggleSplit = ToolMenu.item("Switch Split Direction", symbol: "rectangle.split.2x1") {
            [weak self] in self?.toggleFocusedSplitOrientation()
        }
        toggleSplit.isEnabled = runtimeReady

        var items: [NSMenuItem] = [workspaces, move, focus, moveTile, toggleSplit, cycle]
        if coordinator.recoveryRequired {
            let restore = ToolMenu.item("Restore Windows", symbol: "arrow.counterclockwise") {
                [weak self] in self?.restoreWindows()
            }
            restore.isEnabled = runtimeReady
            items.append(restore)
        }
        return items
    }

    private static let directionMenuEntries: [(TileDirection, String, String)] = [
        (.left, "Left", "arrow.left"),
        (.right, "Right", "arrow.right"),
        (.up, "Up", "arrow.up"),
        (.down, "Down", "arrow.down"),
    ]

    var warnings: [ToolWarning] {
        var out: [ToolWarning] = []
        if let sectionLoadError {
            out.append(ToolWarning(
                id: "tiles.config",
                text: "⚠︎ Tiles settings could not be read",
                detailLines: [sectionLoadError, "Editing is disabled until you reset them."],
                actionTitle: "Reset Tiles settings…",
                action: { [weak self] in self?.resetSection() }))
        }
        if let runtimeBlockedMessage {
            let accessibility = runtimeBlockedMessage.contains("Accessibility")
            out.append(ToolWarning(
                id: accessibility ? "tiles.accessibility" : "tiles.runtime",
                text: accessibility ? "⚠︎ Tiles needs Accessibility" : "⚠︎ Tiles is paused",
                detailLines: [runtimeBlockedMessage],
                actionTitle: accessibility ? "Open Accessibility Settings…" : "Retry Tiles",
                action: accessibility ? { [weak self] in
                    self?.services?.permissions.openAccessibilitySettings()
                } : { [weak self] in self?.retryRuntime() }))
        }
        if !failedHotkeys.isEmpty {
            var details = failedHotkeys.prefix(4).map { failure in
                let prefix = failure.generatedReverse ? "Reverse " : ""
                return "\(prefix)\(failure.action.title) \(ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)): \(failure.reason)"
            }
            if failedHotkeys.count > 4 { details.append("…and \(failedHotkeys.count - 4) more") }
            out.append(ToolWarning(
                id: "tiles.hotkeys",
                text: "⚠︎ \(failedHotkeys.count) Tiles shortcut\(failedHotkeys.count == 1 ? "" : "s") blocked",
                detailLines: details,
                actionTitle: "Retry shortcuts",
                action: { [weak self] in self?.retryFailedHotkeys() }))
        }
        return out
    }

    private func displayName(for id: ToolID) -> String {
        switch id {
        case .tiles: return displayName
        case .zones: return "Zones"
        case .cycler: return "Cycler"
        case .hyperkey: return "Hyperkey"
        default: return id.rawValue.capitalized
        }
    }

    // MARK: Settings

    func makeSettingsPane() -> AnyView {
        AnyView(TilesSettingsPane(model: settingsModel))
    }

    func boundCombos() -> [ToolCombo] {
        services?.boundCombos() ?? []
    }

    func openAccessibilitySettings() {
        services?.permissions.openAccessibilitySettings()
    }

    func binding(for action: String) -> ShortcutBinding? {
        guard let action = Action(rawValue: action) else { return nil }
        return action.binding(settings)
    }

    func reverseAvailable(for action: String) -> Bool {
        guard let action = Action(rawValue: action), action.hasGeneratedReverse,
              let binding = action.binding(settings),
              binding.modifiers & DragSnapModifierMask.shift == 0 else { return false }
        let reverse = HotkeyCombo(keyCode: binding.keyCode,
                                  modifiers: UInt32(truncatingIfNeeded: binding.modifiers)
                                    | UInt32(shiftKey))
        let explicit = Set(bindings(in: settings).map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        guard !explicit.contains(reverse) else { return false }
        return services?.boundCombos().conflictOwner(keyCode: reverse.keyCode,
                                                     modifiers: reverse.modifiers,
                                                     excluding: .tiles) == nil
    }

    func applyCapture(_ capture: ShortcutRecorder.Capture, for actionID: String) {
        guard canEdit, let action = Action(rawValue: actionID) else { return }
        switch capture {
        case .clear:
            var updated = settings
            switch action {
            case .nextWorkspace: updated.nextWorkspace = nil
            case .nextWindow: updated.nextWindow = nil
            case .moveWindowToNextWorkspace: updated.moveWindowToNextWorkspace = nil
            case .focusTileLeft: updated.focusTileLeft = nil
            case .focusTileRight: updated.focusTileRight = nil
            case .focusTileUp: updated.focusTileUp = nil
            case .focusTileDown: updated.focusTileDown = nil
            case .moveWindowLeft: updated.moveWindowLeft = nil
            case .moveWindowRight: updated.moveWindowRight = nil
            case .moveWindowUp: updated.moveWindowUp = nil
            case .moveWindowDown: updated.moveWindowDown = nil
            case .toggleSplitOrientation: updated.toggleSplitOrientation = nil
            }
            saveFromPane(updated)

        case .modifiersOnly:
            NSSound.beep()

        case .combo(let keyCode, let modifiers):
            if let owner = settingsModel.boundCombos.conflictOwner(keyCode: keyCode,
                                                                   modifiers: modifiers,
                                                                   excluding: .tiles) {
                settingsModel.showAlert(title: "Shortcut already in use",
                                        message: "This combo is used by \(settingsModel.toolDisplayName(owner)). Choose a different shortcut, or change it in that tool's settings.")
                return
            }
            let duplicate = bindings(in: settings).contains {
                $0.action != action.rawValue && $0.keyCode == keyCode
                    && $0.modifiers == Int(truncatingIfNeeded: modifiers)
            }
            guard !duplicate else {
                settingsModel.showAlert(title: "Shortcut already in use",
                                        message: "This combo is already assigned to another Tiles action. Choose a different shortcut.")
                return
            }
            var updated = settings
            let binding = ShortcutBinding(action: action.rawValue, keyCode: keyCode,
                                           modifiers: Int(truncatingIfNeeded: modifiers))
            switch action {
            case .nextWorkspace: updated.nextWorkspace = binding
            case .nextWindow: updated.nextWindow = binding
            case .moveWindowToNextWorkspace: updated.moveWindowToNextWorkspace = binding
            case .focusTileLeft: updated.focusTileLeft = binding
            case .focusTileRight: updated.focusTileRight = binding
            case .focusTileUp: updated.focusTileUp = binding
            case .focusTileDown: updated.focusTileDown = binding
            case .moveWindowLeft: updated.moveWindowLeft = binding
            case .moveWindowRight: updated.moveWindowRight = binding
            case .moveWindowUp: updated.moveWindowUp = binding
            case .moveWindowDown: updated.moveWindowDown = binding
            case .toggleSplitOrientation: updated.toggleSplitOrientation = binding
            }
            saveFromPane(updated)
        }
    }

    private func saveFromPane(_ updated: TilesSettings) {
        do {
            try save(updated)
        } catch {
            settingsModel.showAlert(title: "Could not save Tiles settings.",
                                    message: error.localizedDescription)
        }
    }
}

enum TilesToolError: LocalizedError {
    case notRegistered
    case sectionUnreadable
    case invalidSettings(String)

    var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Tiles is not ready yet. Try again in a moment."
        case .sectionUnreadable:
            return "Your Tiles settings could not be read. They were left untouched. Reset them to start editing again."
        case .invalidSettings(let message):
            return message
        }
    }
}
