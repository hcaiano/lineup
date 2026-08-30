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
    case toggleFocusedTiled
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
    var hyperkeyIncludesShiftForSettings: Bool { hyperkeyIncludesShift() }
    /// `nil` from the config scope means the tool has never stored its own settings. An enabled
    /// flag-only section still counts as first use; a decoded section, including all-null rows,
    /// is explicit user state and must not be replaced by defaults.
    private var hasStoredSettings = false

    /// A section that exists but cannot be decoded must remain untouched. The pane then offers a
    /// reset, and start acquires no runtime resources until the user repairs the section.
    private(set) var sectionLoadError: String?

    private var services: ToolServices?
    private let coordinator: TilesCoordinatorProtocol
    /// AppShell supplies this read-only view of Hyperkey's persisted mode. First-use/reset presets
    /// use it directly; an explicit mode change only rebases a preset whose shortcut rows remain
    /// untouched.
    private let hyperkeyIncludesShift: () -> Bool
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

    /// Internal, not private: the Settings pane renders its shortcut rows from
    /// these cases so a renamed action can never drift from its row.
    enum Action: String, CaseIterable {
        case workspace1
        case workspace2
        case workspace3
        case workspace4
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
        case toggleTiled

        /// The Settings pane heading each action belongs to.
        enum Group {
            case workspaceAndStacks
            case focus
            case move
            case layout
        }

        var group: Group {
            switch self {
            case .workspace1, .workspace2, .workspace3, .workspace4,
                 .nextWorkspace, .nextWindow, .moveWindowToNextWorkspace:
                return .workspaceAndStacks
            case .focusTileLeft, .focusTileRight, .focusTileUp, .focusTileDown:
                return .focus
            case .moveWindowLeft, .moveWindowRight, .moveWindowUp, .moveWindowDown:
                return .move
            case .toggleSplitOrientation, .toggleTiled:
                return .layout
            }
        }

        var workspaceNumber: Int? {
            switch self {
            case .workspace1: return 1
            case .workspace2: return 2
            case .workspace3: return 3
            case .workspace4: return 4
            default: return nil
            }
        }

        var hasGeneratedWorkspaceMove: Bool { workspaceNumber != nil }

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
            case .workspace1: return "Workspace 1"
            case .workspace2: return "Workspace 2"
            case .workspace3: return "Workspace 3"
            case .workspace4: return "Workspace 4"
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
            case .toggleTiled: return "Toggle Tiled / Freeform"
            }
        }

        /// The one place an action is tied to its stored field. Reading,
        /// clearing and assigning a binding all go through this key path, so
        /// the named fields on disk stay unchanged while the shell
        /// keeps a single mapping.
        var keyPath: WritableKeyPath<TilesSettings, ShortcutBinding?> {
            switch self {
            case .workspace1: return \.workspace1
            case .workspace2: return \.workspace2
            case .workspace3: return \.workspace3
            case .workspace4: return \.workspace4
            case .nextWorkspace: return \.nextWorkspace
            case .nextWindow: return \.nextWindow
            case .moveWindowToNextWorkspace: return \.moveWindowToNextWorkspace
            case .focusTileLeft: return \.focusTileLeft
            case .focusTileRight: return \.focusTileRight
            case .focusTileUp: return \.focusTileUp
            case .focusTileDown: return \.focusTileDown
            case .moveWindowLeft: return \.moveWindowLeft
            case .moveWindowRight: return \.moveWindowRight
            case .moveWindowUp: return \.moveWindowUp
            case .moveWindowDown: return \.moveWindowDown
            case .toggleSplitOrientation: return \.toggleSplitOrientation
            case .toggleTiled: return \.toggleTiled
            }
        }

        func binding(_ settings: TilesSettings) -> ShortcutBinding? {
            settings[keyPath: keyPath]
        }

        /// The relative workspace actions remain decodable for old settings, but they are no
        /// longer part of the Tiles shortcut surface. Keep them inert so an old value cannot
        /// register a Carbon hotkey or reserve a combo from another tool.
        var isRegistered: Bool {
            switch self {
            case .nextWorkspace, .moveWindowToNextWorkspace:
                return false
            default:
                return true
            }
        }

        static var registeredCases: [Action] { allCases.filter(\.isRegistered) }
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
        var generatedWorkspaceMove: Bool = false
    }

    init(coordinator: TilesCoordinatorProtocol,
         hyperkeyIncludesShift: @escaping () -> Bool = { false }) {
        self.coordinator = coordinator
        self.hyperkeyIncludesShift = hyperkeyIncludesShift
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
        settingsModel.refreshShortcutSnapshot()
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
        // Clear the in-flight recovery state even when the tool is already stopped. This keeps
        // the Settings pane from retaining a stale progress state after every stop path.
        isRestoringWindows = false
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
        // A missing Tiles settings section is the only first-use path. Materialize the adaptive
        // preset before acquiring runtime resources, so a failed save cannot leave hotkeys active
        // with settings that will disappear on the next launch.
        guard materializeDefaultsIfNeeded() else {
            runtimeBlockedMessage = "Tiles cannot start because its default shortcuts could not be saved."
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
            let stored = try services.config.load(TilesSettings.self)
            let loaded = stored ?? ShortcutKit.tilesDefaults(includeShift: hyperkeyIncludesShift())
            try validate(loaded)
            settings = loaded
            hasStoredSettings = stored != nil
            sectionLoadError = nil
        } catch {
            settings = TilesSettings()
            hasStoredSettings = false
            sectionLoadError = "\(error)"
            log.error("Tiles settings could not be decoded (left untouched): \(error, privacy: .public)")
        }
    }

    /// Refresh the recommendation or the atomically adapted stored preset after Hyperkey changes
    /// its emitted modifier mask. Customized shortcuts were not changed by the shell and reload
    /// unchanged here.
    func hyperkeyModeDidChange() {
        loadSettings()
        if runtimeReady { registerHotkeys() }
        settingsModel.refreshShortcutSnapshot()
        services?.refreshMenu()
        services?.refreshSettings()
    }

    /// Persist the adaptive first-use preset once, immediately before runtime startup. The
    /// missing-section check is kept in memory so a disabled Tiles tool never reserves these
    /// combinations in `persistedCombos()`.
    private func materializeDefaultsIfNeeded() -> Bool {
        guard !hasStoredSettings else { return true }
        guard let services, services.config.canWrite, sectionLoadError == nil else { return false }

        let defaults = ShortcutKit.tilesDefaults(includeShift: hyperkeyIncludesShift())
        do {
            try validate(defaults)
            try services.config.save(defaults)
            settings = defaults
            hasStoredSettings = true
            return true
        } catch {
            log.error("Tiles default shortcuts could not be saved: \(error, privacy: .public)")
            return false
        }
    }

    private func validate(_ candidate: TilesSettings) throws {
        guard candidate.schemaVersion > 0,
              candidate.schemaVersion <= TilesSettings.currentSchema else {
            throw TilesToolError.invalidSettings("Unsupported Tiles settings schema \(candidate.schemaVersion).")
        }
        var seen = Set<HotkeyCombo>()
        // An explicit Shift variant can already be stored by an older/custom configuration. Keep
        // it loadable and untouched; applyCapture rejects only a new edit that would steal a
        // generated reverse or numbered-workspace move.
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
        Action.registeredCases.compactMap { $0.binding(source) }
    }

    /// Return the Tiles action whose generated physical-Shift combo would be replaced by this
    /// explicit capture. Stored settings are allowed to keep such a value for compatibility;
    /// rejecting it here only protects a new recorder edit from silently disabling a reverse or
    /// numbered-workspace move.
    private func generatedCounterpartOwner(keyCode: Int, modifiers: UInt32) -> Action? {
        guard modifiers & UInt32(shiftKey) != 0 else { return nil }
        return Action.registeredCases.first { action in
            guard action.hasGeneratedReverse || action.hasGeneratedWorkspaceMove,
                  let binding = action.binding(settings),
                  binding.modifiers & DragSnapModifierMask.shift == 0,
                  binding.keyCode == keyCode else { return false }
            return (UInt32(truncatingIfNeeded: binding.modifiers) | UInt32(shiftKey)) == modifiers
        }
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
            let fresh = ShortcutKit.tilesDefaults(includeShift: hyperkeyIncludesShift())
            let spacingChanged = settings.tileSpacingEnabled != fresh.tileSpacingEnabled
            try validate(fresh)
            try services.config.save(fresh)
            settings = fresh
            hasStoredSettings = true
            sectionLoadError = nil
            if runtimeReady {
                if spacingChanged { coordinator.update(settings: fresh) }
                registerHotkeys()
            } else if isRunning {
                runtimeBlockedMessage = nil
                attemptRuntimeStart()
            }
        } catch {
            log.error("Tiles reset aborted (settings left untouched): \(error, privacy: .public)")
        }
        settingsModel.refreshShortcutSnapshot()
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
        hasStoredSettings = true
        if runtimeReady {
            if spacingChanged { coordinator.update(settings: newSettings) }
            registerHotkeys()
        }
        settingsModel.refreshShortcutSnapshot()
        services.refreshMenu()
    }

    func setTileSpacingEnabled(_ enabled: Bool) {
        guard canEdit, settings.tileSpacingEnabled != enabled else { return }
        refreshRecommendedDefaultsIfNeeded()
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

        for action in Action.registeredCases {
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
        for action in Action.registeredCases {
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

        // A numbered workspace combo gets a physical Shift counterpart that
        // moves the focused window without changing the active workspace.
        // Hyperkey's include-Shift mode cannot distinguish that counterpart,
        // so only bindings without Shift receive the generated move.
        for action in Action.registeredCases {
            guard action.hasGeneratedWorkspaceMove,
                  let binding = action.binding(settings),
                  binding.modifiers & DragSnapModifierMask.shift == 0 else { continue }
            let forward = UInt32(truncatingIfNeeded: binding.modifiers)
            let move = HotkeyCombo(keyCode: binding.keyCode,
                                   modifiers: forward | UInt32(shiftKey))
            guard !explicit.contains(move) else { continue }
            if let owner = persisted.conflictOwner(keyCode: move.keyCode,
                                                   modifiers: move.modifiers,
                                                   excluding: .tiles) {
                log.error("Tiles workspace move shortcut blocked by \(self.displayName(for: owner), privacy: .public)")
                failures.append(FailedHotkey(action: action, keyCode: move.keyCode,
                                             modifiers: move.modifiers,
                                             reason: "already used by \(self.displayName(for: owner))",
                                             generatedReverse: false,
                                             generatedWorkspaceMove: true))
                continue
            }
            let result = services.hotkeys.register(keyCode: move.keyCode,
                                                   modifiers: move.modifiers) { [weak self] in
                self?.perform(action, generatedWorkspaceMove: true)
            }
            if case .success(let token) = result {
                hotkeyTokens.append(token)
            } else if case .failure(let reason) = result {
                failures.append(FailedHotkey(action: action, keyCode: move.keyCode,
                                             modifiers: move.modifiers,
                                             reason: reason.displayReason,
                                             generatedReverse: false,
                                             generatedWorkspaceMove: true))
            }
        }

        failedHotkeys = failures
        for failure in failures { logHotkeyFailure(failure) }
        updateFailedHotkeyRetryTimer()
    }

    /// The conflict source includes disabled siblings and generated reverse combinations.
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] {
        // The in-memory adaptive preset is for the disabled pane only. Until the first activation
        // or an explicit edit persists it, it must not reserve combinations from Zones/Cycler.
        guard hasStoredSettings else { return [] }
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
        for action in Action.registeredCases where action.hasGeneratedReverse {
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
        for action in Action.registeredCases where action.hasGeneratedWorkspaceMove {
            guard let binding = action.binding(source),
                  binding.modifiers & DragSnapModifierMask.shift == 0 else { continue }
            let forward = UInt32(truncatingIfNeeded: binding.modifiers)
            let move = HotkeyCombo(keyCode: binding.keyCode,
                                   modifiers: forward | UInt32(shiftKey))
            guard !explicit.contains(move),
                  siblingCombos.conflictOwner(keyCode: move.keyCode,
                                              modifiers: move.modifiers,
                                              excluding: .tiles) == nil else { continue }
            if seen.insert(move).inserted { out.append((move.keyCode, move.modifiers)) }
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
                                              generatedReverse: match.generatedReverse,
                                              generatedWorkspaceMove: match.generatedWorkspaceMove))
        }
        updateFailedHotkeyRetryTimer()
        services?.refreshMenu()
    }

    private func matchingAction(for combo: HotkeyCombo) -> (action: Action,
                                                             generatedReverse: Bool,
                                                             generatedWorkspaceMove: Bool)? {
        for action in Action.registeredCases {
            guard let binding = action.binding(settings) else { continue }
            let forward = HotkeyCombo(keyCode: binding.keyCode,
                                      modifiers: UInt32(truncatingIfNeeded: binding.modifiers))
            if forward == combo { return (action, false, false) }
            if action.hasGeneratedReverse,
               binding.modifiers & DragSnapModifierMask.shift == 0,
               HotkeyCombo(keyCode: binding.keyCode,
                           modifiers: forward.modifiers | UInt32(shiftKey)) == combo {
                return (action, true, false)
            }
            if action.hasGeneratedWorkspaceMove,
               binding.modifiers & DragSnapModifierMask.shift == 0,
               HotkeyCombo(keyCode: binding.keyCode,
                           modifiers: forward.modifiers | UInt32(shiftKey)) == combo {
                return (action, false, true)
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
        settingsModel.refreshShortcutSnapshot()
        services?.refreshMenu()
        services?.refreshSettings()
    }

    private func logHotkeyFailure(_ failure: FailedHotkey) {
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        let suffix = failure.generatedReverse ? " reverse" :
            (failure.generatedWorkspaceMove ? " workspace move" : "")
        log.error("Tiles\(suffix, privacy: .public) shortcut \(failure.action.title, privacy: .public) \(combo, privacy: .public) blocked: \(failure.reason, privacy: .public)")
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
        // Presentation follows a committed coordinator state change, which has
        // already refreshed the menu. Only the pane needs this pass.
        settingsModel.refresh()
        services?.refreshSettings()
    }

    private func perform(_ action: Action, generatedReverse: Bool = false,
                         generatedWorkspaceMove: Bool = false) {
        guard runtimeReady else { return }
        if generatedWorkspaceMove, let workspace = action.workspaceNumber {
            coordinator.perform(.moveFocusedWindow(toWorkspace: workspace))
            settingsModel.refresh()
            return
        }
        switch action {
        case .workspace1:
            coordinator.perform(.switchWorkspace(1))
        case .workspace2:
            coordinator.perform(.switchWorkspace(2))
        case .workspace3:
            coordinator.perform(.switchWorkspace(3))
        case .workspace4:
            coordinator.perform(.switchWorkspace(4))
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
        case .toggleTiled:
            coordinator.perform(.toggleFocusedTiled)
        }
        // The coordinator's onStateChange rebuilds the menu once the action has
        // committed. Rebuilding it here as well would query every tool and the
        // login-item daemon again on every keypress.
        settingsModel.refresh()
    }

    func selectWorkspace(_ workspace: Int) {
        guard runtimeReady, WorkspaceID.from(workspace) != nil else { return }
        coordinator.perform(.switchWorkspace(workspace))
        settingsModel.refresh()
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
        guard runtimeReady, WorkspaceID.from(workspace) != nil else { return }
        coordinator.perform(.moveFocusedWindow(toWorkspace: workspace))
        settingsModel.refresh()
    }

    func toggleFocusedTiled() {
        guard runtimeReady else { return }
        coordinator.perform(.toggleFocusedTiled)
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
            let action = Action.registeredCases.first { $0.workspaceNumber == workspace }
            let title = action.map { menuTitle("Workspace \(workspace)", action: $0) }
                ?? "Workspace \(workspace)"
            let item = ToolMenu.item(title, symbol: "square.fill") {
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
            let action = Action.registeredCases.first { $0.workspaceNumber == workspace }
            let title = action.map {
                menuTitle("Workspace \(workspace)", action: $0, addingShift: true)
            } ?? "Workspace \(workspace)"
            let item = ToolMenu.item(title, symbol: "arrow.right.square") {
                [weak self] in self?.moveFocusedWindowToWorkspace(workspace)
            }
            item.isEnabled = runtimeReady
            moveMenu.addItem(item)
        }
        move.submenu = moveMenu

        let cycle = ToolMenu.item(menuTitle("Next Window in Tile", action: .nextWindow),
                                  symbol: "arrow.triangle.2.circlepath") {
            [weak self] in self?.cycleFocusedTile()
        }
        cycle.isEnabled = runtimeReady

        let focus = NSMenuItem(title: "Focus Tile", action: nil, keyEquivalent: "")
        focus.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        let focusMenu = NSMenu()
        focusMenu.autoenablesItems = false
        for (direction, title, symbol) in Self.directionMenuEntries {
            let item = ToolMenu.item(menuTitle(title, action: focusAction(for: direction)),
                                     symbol: symbol) { [weak self] in
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
            let item = ToolMenu.item(menuTitle(title, action: moveAction(for: direction)),
                                     symbol: symbol) { [weak self] in
                self?.moveFocusedWindowToTile(direction)
            }
            item.isEnabled = runtimeReady
            moveTileMenu.addItem(item)
        }
        moveTile.submenu = moveTileMenu
        moveTile.isEnabled = runtimeReady

        let toggleSplit = ToolMenu.item(
            menuTitle("Switch Split Direction", action: .toggleSplitOrientation),
            symbol: "rectangle.split.2x1") {
            [weak self] in self?.toggleFocusedSplitOrientation()
        }
        toggleSplit.isEnabled = runtimeReady

        let toggleTiled = ToolMenu.item(
            menuTitle("Toggle Tiled / Freeform", action: .toggleTiled),
            symbol: "rectangle.inset.filled.and.person.filled") {
            [weak self] in self?.toggleFocusedTiled()
        }
        toggleTiled.isEnabled = runtimeReady

        var items: [NSMenuItem] = [workspaces, move, focus, moveTile, toggleSplit, toggleTiled, cycle]
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

    /// Show configured global shortcuts as reference text without assigning AppKit key
    /// equivalents. The Carbon hotkey remains the single dispatcher, including while this menu
    /// is open, so an action cannot fire twice.
    private func menuTitle(_ title: String, action: Action, addingShift: Bool = false) -> String {
        guard let binding = action.binding(settings) else { return title }
        var modifiers = UInt32(truncatingIfNeeded: binding.modifiers)
        if addingShift {
            guard modifiers & UInt32(shiftKey) == 0 else { return title }
            modifiers |= UInt32(shiftKey)
        }
        return "\(title)  \(ShortcutKit.display(keyCode: binding.keyCode, modifiers: modifiers))"
    }

    private func focusAction(for direction: TileDirection) -> Action {
        switch direction {
        case .left: return .focusTileLeft
        case .right: return .focusTileRight
        case .up: return .focusTileUp
        case .down: return .focusTileDown
        }
    }

    private func moveAction(for direction: TileDirection) -> Action {
        switch direction {
        case .left: return .moveWindowLeft
        case .right: return .moveWindowRight
        case .up: return .moveWindowUp
        case .down: return .moveWindowDown
        }
    }

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
                let prefix = failure.generatedReverse ? "Reverse " :
                    (failure.generatedWorkspaceMove ? "Move " : "")
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
        guard let action = Action(rawValue: action), action.isRegistered else { return nil }
        return action.binding(settings)
    }

    enum WorkspaceMoveShortcutState: Equatable {
        case shortcut(String)
        case workspaceShortcutMissing
        case unavailableWithIncludeShift
        case unavailable(String)
    }

    /// Derive the physical-Shift workspace move from the same snapshot and failure state used by
    /// registration. A derived combo is only shown as functional when it is free in Tiles and in
    /// every sibling tool, and when Carbon accepted it (or has not tried it yet).
    func workspaceMoveShortcutState(for workspace: Int,
                                    boundCombos: [ToolCombo]) -> WorkspaceMoveShortcutState {
        guard let action = Action.registeredCases.first(where: { $0.workspaceNumber == workspace }),
              let binding = action.binding(settings) else {
            return .workspaceShortcutMissing
        }
        guard binding.modifiers & DragSnapModifierMask.shift == 0 else {
            return .unavailableWithIncludeShift
        }
        if let reason = workspaceMoveUnavailableReason(for: action, binding: binding,
                                                       boundCombos: boundCombos) {
            return .unavailable(reason)
        }
        return .shortcut(ShortcutKit.display(
            keyCode: binding.keyCode,
            modifiers: UInt32(truncatingIfNeeded: binding.modifiers) | UInt32(shiftKey)))
    }

    private func workspaceMoveUnavailableReason(for action: Action,
                                                binding: ShortcutBinding,
                                                boundCombos: [ToolCombo]) -> String? {
        let move = HotkeyCombo(
            keyCode: binding.keyCode,
            modifiers: UInt32(truncatingIfNeeded: binding.modifiers) | UInt32(shiftKey))
        let explicit = Set(bindings(in: settings).map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        guard !explicit.contains(move) else {
            return "Shortcut already assigned in Tiles"
        }
        if let owner = boundCombos.conflictOwner(keyCode: move.keyCode,
                                                 modifiers: move.modifiers,
                                                 excluding: .tiles) {
            return "Shortcut used by \(displayName(for: owner))"
        }
        if failedHotkeys.contains(where: {
            $0.action == action && $0.generatedWorkspaceMove
                && $0.keyCode == move.keyCode && $0.modifiers == move.modifiers
        }) {
            return "macOS rejected this shortcut"
        }
        return nil
    }

    /// Refresh the in-memory recommendation before the first explicit edit. No config write occurs
    /// here, so the disabled tool still reserves no combinations until the user saves or activates
    /// it. Once any edit is stored, the guard preserves every user-owned row unchanged.
    func refreshRecommendedDefaultsIfNeeded(excluding actionID: String? = nil) {
        guard !hasStoredSettings, sectionLoadError == nil else { return }
        let spacing = settings.tileSpacingEnabled
        let preservedAction = actionID.flatMap(Action.init(rawValue:))
        let preservedBinding = preservedAction?.binding(settings)
        var refreshed = ShortcutKit.tilesDefaults(includeShift: hyperkeyIncludesShift())
        refreshed.tileSpacingEnabled = spacing
        if let preservedAction {
            refreshed[keyPath: preservedAction.keyPath] = preservedBinding
        }
        settings = refreshed
    }

    /// True when at least one cyclic action still owns its generated Shift
    /// reverse. Answered from a single `boundCombos()` snapshot: that query
    /// reloads every tool's persisted section, so the pane must not repeat it
    /// per row while drawing.
    func anyReverseShortcutAvailable(boundCombos persisted: [ToolCombo]) -> Bool {
        let explicit = Set(bindings(in: settings).map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        return Action.registeredCases.contains { action in
            guard action.hasGeneratedReverse,
                  let binding = action.binding(settings),
                  binding.modifiers & DragSnapModifierMask.shift == 0 else { return false }
            let reverse = HotkeyCombo(keyCode: binding.keyCode,
                                      modifiers: UInt32(truncatingIfNeeded: binding.modifiers)
                                        | UInt32(shiftKey))
            guard !explicit.contains(reverse), !isFailedHotkey(reverse) else { return false }
            return persisted.conflictOwner(keyCode: reverse.keyCode,
                                           modifiers: reverse.modifiers,
                                           excluding: .tiles) == nil
        }
    }

    func anyWorkspaceMoveShortcutAvailable(boundCombos persisted: [ToolCombo]) -> Bool {
        let explicit = Set(bindings(in: settings).map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        return Action.registeredCases.contains { action in
            guard action.hasGeneratedWorkspaceMove,
                  let binding = action.binding(settings),
                  binding.modifiers & DragSnapModifierMask.shift == 0 else { return false }
            let move = HotkeyCombo(keyCode: binding.keyCode,
                                   modifiers: UInt32(truncatingIfNeeded: binding.modifiers)
                                     | UInt32(shiftKey))
            guard !explicit.contains(move), !isFailedHotkey(move) else { return false }
            return persisted.conflictOwner(keyCode: move.keyCode,
                                           modifiers: move.modifiers,
                                           excluding: .tiles) == nil
        }
    }

    func nextWindowReverseShortcutAvailable(boundCombos persisted: [ToolCombo]) -> Bool {
        let action = Action.nextWindow
        guard let binding = action.binding(settings),
              binding.modifiers & DragSnapModifierMask.shift == 0 else { return false }
        let reverse = HotkeyCombo(keyCode: binding.keyCode,
                                  modifiers: UInt32(truncatingIfNeeded: binding.modifiers)
                                    | UInt32(shiftKey))
        let explicit = Set(bindings(in: settings).map {
            HotkeyCombo(keyCode: $0.keyCode,
                        modifiers: UInt32(truncatingIfNeeded: $0.modifiers))
        })
        guard !explicit.contains(reverse), !isFailedHotkey(reverse) else { return false }
        return persisted.conflictOwner(
            keyCode: reverse.keyCode, modifiers: reverse.modifiers,
            excluding: .tiles) == nil
    }

    private func isFailedHotkey(_ combo: HotkeyCombo) -> Bool {
        failedHotkeys.contains {
            $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers
        }
    }

    func applyCapture(_ capture: ShortcutRecorder.Capture, for actionID: String) {
        guard canEdit, let action = Action(rawValue: actionID), action.isRegistered else { return }
        refreshRecommendedDefaultsIfNeeded(excluding: actionID)
        switch capture {
        case .clear:
            var updated = settings
            updated[keyPath: action.keyPath] = nil
            saveFromPane(updated)

        case .modifiersOnly:
            NSSound.beep()

        case .combo(let keyCode, let modifiers):
            if let owner = generatedCounterpartOwner(keyCode: keyCode, modifiers: modifiers) {
                let generatedKind = owner.hasGeneratedWorkspaceMove
                    ? "the Shift-number window move"
                    : "the Shift reverse"
                settingsModel.showAlert(
                    title: "Shortcut reserved",
                    message: "\(ShortcutKit.display(keyCode: keyCode, modifiers: modifiers)) is reserved for \(generatedKind) of \(owner.title). Record the base shortcut instead.")
                return
            }
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
            updated[keyPath: action.keyPath] = binding
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
