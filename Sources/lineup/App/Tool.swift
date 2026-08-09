import AppKit
import AppCore
import Carbon.HIToolbox
import SwiftUI
import os

// The Tool contract. FROZEN at the end of Phase 3 — Zones, Cycler and Hyperkey are all built
// against exactly this surface, in parallel. Changing anything here needs a coordination round.

/// A system permission a tool needs to do its job. Surfaced in General › Permissions with a
/// "required by: …" hint derived from every registered tool's `requiredPermissions`.
enum Permission: Hashable {
    case accessibility
    case inputMonitoring

    var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        }
    }
}

/// An actionable problem, surfaced at the top of the menu and in the owning tool's pane.
/// Healthy states produce NO warnings — the menu shows nothing when everything works.
struct ToolWarning: Identifiable {
    let id: String
    let text: String
    var detailLines: [String] = []
    var actionTitle: String?
    var action: (() -> Void)?

    init(id: String, text: String, detailLines: [String] = [],
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.id = id
        self.text = text
        self.detailLines = detailLines
        self.actionTitle = actionTitle
        self.action = action
    }
}

/// Why a Carbon registration didn't take.
/// `Error` is required by `Result`'s Failure constraint; the contract is otherwise §2.3's.
enum HotkeyFailure: Error, Equatable {
    /// Carbon refused it. `-9878` (`eventHotKeyExistsErr`) means another *app* owns the combo.
    case carbon(OSStatus)
    /// Another Lineup TOOL already registered this combo. Caught before Carbon so the warning
    /// can name the owner instead of showing an opaque status code.
    case ownedByTool(ToolID)
}

/// A tool's window onto the shared Carbon registry. Tools never touch `HotkeyManager` directly,
/// so `unregisterAll()` in `stop()` can't accidentally take a sibling's hotkeys down with it.
@MainActor
struct HotkeyScope {
    let owner: ToolID

    @discardableResult
    func register(keyCode: Int, modifiers: UInt32,
                  action: @escaping () -> Void) -> Result<HotkeyManager.Token, HotkeyFailure> {
        HotkeyManager.shared.register(owner: owner, keyCode: keyCode, modifiers: modifiers, action: action)
    }

    func unregister(_ token: HotkeyManager.Token) {
        HotkeyManager.shared.unregister(token)
    }

    /// MUST be called from `Tool.stop()`.
    func unregisterAll() {
        HotkeyManager.shared.unregisterAll(owner: owner)
    }

    /// Combos owned by OTHER tools — for cross-tool conflict UX in the recorders.
    func foreignCombos() -> [(owner: ToolID, keyCode: Int, modifiers: UInt32)] {
        HotkeyManager.shared.registeredCombos().filter { $0.owner != owner }
    }
}

/// A tool's window onto `config.json`. Reads and writes only its own section; siblings and
/// unknown sections are preserved by the store.
@MainActor
struct ToolConfigScope {
    let owner: ToolID
    private let store: LineupAppConfigStore

    init(owner: ToolID, store: LineupAppConfigStore) {
        self.owner = owner
        self.store = store
    }

    /// `nil` means "no section yet" — the tool uses its own defaults.
    func load<T: Decodable>(_ type: T.Type) throws -> T? {
        try store.config.settings(type, for: owner)
    }

    /// Atomic; siblings preserved.
    func save<T: Encodable>(_ value: T) throws {
        try store.setSettings(value, for: owner)
    }

    var canWrite: Bool { store.canWrite }
    var blockedMessage: String? { store.blockedMessage }
}

/// Everything the shell lends a tool. Tools must not reach for shell singletons directly —
/// that is what makes a tool startable, stoppable and testable in isolation.
@MainActor
final class ToolServices {
    let id: ToolID
    let hotkeys: HotkeyScope
    let config: ToolConfigScope
    let permissions: PermissionCenter
    let activation: ActivationCoordinator
    let termination: TerminationCoordinator
    let log: Logger
    let refreshMenu: () -> Void
    let refreshSettings: () -> Void
    /// Read-only view of sibling tools, for cross-tool hints (e.g. Hyperkey noticing that
    /// Zones/Cycler have hyper-based shortcuts bound). Never used to mutate a sibling.
    let peers: () -> [ToolID: Bool]

    init(id: ToolID,
         config: ToolConfigScope,
         permissions: PermissionCenter,
         activation: ActivationCoordinator,
         termination: TerminationCoordinator,
         refreshMenu: @escaping () -> Void,
         refreshSettings: @escaping () -> Void,
         peers: @escaping () -> [ToolID: Bool]) {
        self.id = id
        self.hotkeys = HotkeyScope(owner: id)
        self.config = config
        self.permissions = permissions
        self.activation = activation
        self.termination = termination
        self.log = Logger(subsystem: Product.logSubsystem, category: id.rawValue)
        self.refreshMenu = refreshMenu
        self.refreshSettings = refreshSettings
        self.peers = peers
    }
}

/// One of Lineup's three tools. A tool owns its hotkeys, taps, monitors, timers and observers,
/// and must be able to give every one of them back.
@MainActor
protocol Tool: AnyObject {
    var id: ToolID { get }
    var displayName: String { get }
    var summary: String { get }
    var iconSymbol: String { get }
    var requiredPermissions: Set<Permission> { get }
    /// Zones: true (1.x users already have it). Cycler/Hyperkey: false — a silent auto-update
    /// must never spontaneously start an event tap or grab Caps Lock.
    var defaultEnabled: Bool { get }

    var isRunning: Bool { get }

    /// Acquire every resource: hotkeys, event taps, monitors, timers, observers.
    func start(_ services: ToolServices)

    /// Release EVERY resource `start()` acquired. Idempotent; safe when not running.
    func stop()

    /// Only called while running.
    func menuItems() -> [NSMenuItem]
    /// Recomputed on each menu build.
    var warnings: [ToolWarning] { get }
    /// Rendered even when the tool is disabled, so the user can configure it before enabling.
    func makeSettingsPane() -> AnyView
}
