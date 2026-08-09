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

/// One registration that did NOT come back when a Settings recorder released the registry —
/// another app claimed the combo while every tool's hotkeys were suspended.
///
/// `HotkeyManager` keeps such a row with a nil `ref`, so it is recorded but dead: without telling
/// the owner, nothing ever retries it and the user's shortcut stays broken for the session.
struct HotkeyRestoreFailure: Equatable {
    let keyCode: Int
    let modifiers: UInt32
    let status: OSStatus
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

    // No `foreignCombos()` here on purpose. The live registry only knows about tools that are
    // RUNNING, so a recorder checking it would happily claim a switched-off sibling's combo.
    // `ToolServices.boundCombos()` is the conflict source; see `ToolCombo`.

    /// True while a Settings recorder holds the whole registry suspended. A tool that retries a
    /// failed registration must wait this out: while suspended, `register` records the row without
    /// installing it, so every retry would "succeed" and hide a real conflict. Exposed here so no
    /// tool has to reach for `HotkeyManager.shared` directly.
    var isSuspended: Bool { HotkeyManager.shared.isSuspended }
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
    /// Every combo EVERY registered tool has bound, running or not — the conflict source for the
    /// Settings recorders (§5.6). Read from the tools' persisted sections, so switching a tool
    /// off does not release its shortcuts to a sibling's recorder. Not free (it decodes each
    /// section), so panes take one snapshot per capture rather than calling it per keystroke.
    let boundCombos: () -> [ToolCombo]

    init(id: ToolID,
         config: ToolConfigScope,
         permissions: PermissionCenter,
         activation: ActivationCoordinator,
         termination: TerminationCoordinator,
         refreshMenu: @escaping () -> Void,
         refreshSettings: @escaping () -> Void,
         peers: @escaping () -> [ToolID: Bool],
         boundCombos: @escaping () -> [ToolCombo] = { [] }) {
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
        self.boundCombos = boundCombos
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

    /// Handed the tool's services at REGISTRATION time, before anything is started and whether or
    /// not the tool is ever enabled. This is what lets a disabled tool's pane read and persist its
    /// own config section: the pane is rendered even when the tool is off, and a config scope that
    /// only appeared in `start()` would leave a never-started tool with nowhere to write.
    ///
    /// Acquires NO resources — no hotkeys, taps, monitors, timers or observers. Those belong to
    /// `start()`, which receives the same `ToolServices` instance.
    func attach(_ services: ToolServices)

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

    /// The combos this tool has PERSISTED, read from its own config section rather than from the
    /// live Carbon registry — so the answer is the same whether or not the tool is running.
    ///
    /// Additive to the Phase 3 contract and defaulted to empty, so a tool with no shortcuts
    /// (Hyperkey) implements nothing. Must include anything the tool would register on start,
    /// generated combos included, or a sibling's recorder can claim a combo the tool then fails
    /// to register when it is switched back on.
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)]

    /// The tool's OWN rows that failed to re-register after a Settings recording (see
    /// `HotkeyRestoreFailure`). The shell reports them to the user itself; this is what lets the
    /// tool put them back into its own blocked list, so its retry — the 10s timer, the
    /// didBecomeActive pass, the "Retry shortcuts" warning — can pick them up again.
    ///
    /// Additive to the Phase 3 contract and defaulted to a no-op, so a tool with no shortcuts
    /// (Hyperkey) implements nothing.
    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure])
}

extension Tool {
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] { [] }
    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {}
}
