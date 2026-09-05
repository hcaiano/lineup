import AppKit
import AppCore
import os

/// Owns the tool list, their enabled state, and their lifecycles.
///
/// The registry stays tool-agnostic: the shell decides which tools to register and in what
/// order, and each tool brings only its own runtime.
@MainActor
final class ToolRegistry {
    private(set) var tools: [any Tool] = []
    /// One `ToolServices` per tool, minted at `register()` and reused by `start()`.
    private var servicesByTool: [ToolID: ToolServices] = [:]
    private let store: LineupAppConfigStore
    private let log = Logger(subsystem: Product.logSubsystem, category: "registry")

    /// Rebuild the menu / Settings when a tool's state changes. Set by `AppShell`.
    var onChange: (() -> Void)?
    var onSettingsChange: (() -> Void)?

    init(store: LineupAppConfigStore) {
        self.store = store
    }

    /// Services are minted HERE, not in `start()`: a tool's pane is rendered even while the tool
    /// is disabled, and it still has to read and write the tool's config section. `attach` acquires
    /// nothing — the same instance is handed to `start()` when the tool is switched on.
    func register(_ tool: any Tool) {
        guard !tools.contains(where: { $0.id == tool.id }) else { return }
        tools.append(tool)
        let services = services(for: tool.id)
        servicesByTool[tool.id] = services
        tool.attach(services)
    }

    func tool(_ id: ToolID) -> (any Tool)? { tools.first { $0.id == id } }

    var runningTools: [any Tool] { tools.filter(\.isRunning) }

    /// A tool's persisted enabled flag, falling back to its own default when it has no section
    /// yet (a fresh install, or an existing 1.x user whose config.json was just created).
    func isEnabled(_ id: ToolID) -> Bool {
        store.config.isEnabled(id) ?? (tool(id)?.defaultEnabled ?? false)
    }

    /// Start every enabled tool. Called once, after the shell is up.
    ///
    /// Seeds a missing section's `enabled` flag first. Without this, a tool running on its default
    /// (Zones, which defaults to ON) would have its first settings edit create the section through
    /// `setSettings`, which can only write `enabled: false` — and Zones would silently be OFF at
    /// the next launch. Writing the flag once, at startup, makes the on-disk state agree with what
    /// the user is actually looking at.
    func startEnabledTools() {
        for tool in tools {
            if store.config.isEnabled(tool.id) == nil, store.canWrite {
                do {
                    try store.setEnabled(tool.defaultEnabled, for: tool.id)
                } catch {
                    log.error("could not seed \(tool.id.rawValue, privacy: .public) enabled=\(tool.defaultEnabled): \(error, privacy: .public)")
                }
            }
            if isEnabled(tool.id), !tool.isRunning { start(tool) }
        }
    }

    /// Why the last enable toggle did not take, or `nil`. Read by the Settings window, which is
    /// the only place a user can flip a tool and expect an explanation.
    private(set) var lastEnableError: String?

    /// Sidebar toggle / menu toggle. PERSISTS FIRST and only then starts or stops.
    ///
    /// The old order (act, then persist, then log a failure) made the switch lie: with the store
    /// write-blocked the tool really started, the flag never reached disk, and the next launch
    /// came back with it off. Persisting first means a refused write leaves the tool exactly where
    /// it was — the switch springs back, because `isEnabled` reads the store — and the reason is
    /// kept for the UI to show.
    func setEnabled(_ enabled: Bool, for id: ToolID) {
        guard let tool = tool(id) else { return }
        do {
            try store.setEnabled(enabled, for: id)
            lastEnableError = nil
        } catch {
            log.error("could not persist \(id.rawValue, privacy: .public) enabled=\(enabled): \(error, privacy: .public)")
            lastEnableError = store.blockedMessage
                ?? "\(tool.displayName) couldn’t be turned \(enabled ? "on" : "off"). Your settings file couldn’t be saved."
            onChange?()
            onSettingsChange?()
            return
        }
        if enabled {
            if !tool.isRunning { start(tool) }
        } else {
            if tool.isRunning { tool.stop() }
        }
        onChange?()
        onSettingsChange?()
    }

    func clearEnableError() { lastEnableError = nil }

    /// Make a tool re-read its section. The one caller is the shell, when a DEFERRED legacy import
    /// finally lands.
    ///
    /// A STOPPED tool is re-attached rather than skipped: it keeps its `ToolServices` for the
    /// whole process lifetime and its pane reads through them, so leaving it alone left stale
    /// in-memory settings on screen (and being edited) until the next launch. Enablement is
    /// re-asserted from the persisted flag in the same pass, so the sidebar switch and the running
    /// state cannot end up disagreeing.
    func restart(_ id: ToolID) {
        guard let tool = tool(id) else { return }
        if tool.isRunning { tool.stop() }
        if isEnabled(id) {
            start(tool)                                       // start() re-reads the section
        } else {
            tool.attach(servicesByTool[id] ?? services(for: id)) // acquires nothing; re-reads only
        }
        onChange?()
        onSettingsChange?()
    }

    /// Release everything, in reverse registration order. Used by termination.
    func stopAll() {
        for tool in tools.reversed() where tool.isRunning { tool.stop() }
    }

    private func start(_ tool: any Tool) {
        tool.start(servicesByTool[tool.id] ?? services(for: tool.id))
    }

    private func services(for id: ToolID) -> ToolServices {
        ToolServices(
            id: id,
            config: ToolConfigScope(owner: id, store: store),
            permissions: PermissionCenter.shared,
            activation: ActivationCoordinator.shared,
            termination: TerminationCoordinator.shared,
            refreshMenu: { [weak self] in self?.onChange?() },
            refreshSettings: { [weak self] in self?.onSettingsChange?() },
            peers: { [weak self] in
                guard let self else { return [:] }
                return Dictionary(uniqueKeysWithValues: self.tools.map { ($0.id, $0.isRunning) })
            },
            boundCombos: { [weak self] in self?.boundCombos() ?? [] })
    }

    /// Every combo any registered tool has bound, tagged with its owner.
    ///
    /// Persisted combos come FIRST, in registration order, so the owner a conflict message names
    /// is deterministic — `HotkeyManager.registeredCombos()` walks a dictionary and has no stable
    /// order. The live pass only adds what is not already persisted (a combo registered from
    /// built-in defaults that were never written to disk).
    func boundCombos() -> [ToolCombo] {
        var out: [ToolCombo] = []
        var seen = Set<ToolCombo>()
        for tool in tools {
            for combo in tool.persistedCombos() {
                let entry = ToolCombo(owner: tool.id, keyCode: combo.keyCode, modifiers: combo.modifiers)
                if seen.insert(entry).inserted { out.append(entry) }
            }
        }
        for live in HotkeyManager.shared.registeredCombos() {
            let entry = ToolCombo(owner: live.owner, keyCode: live.keyCode, modifiers: live.modifiers)
            if seen.insert(entry).inserted { out.append(entry) }
        }
        return out
    }

    /// Every permission any registered tool needs, with the tools that need it — drives the
    /// "required by: Zones, Cycler" hints in General › Permissions.
    func permissionRequirements() -> [(permission: Permission, tools: [String])] {
        var byPermission: [Permission: [String]] = [:]
        for tool in tools {
            for permission in tool.requiredPermissions {
                byPermission[permission, default: []].append(tool.displayName)
            }
        }
        return [Permission.accessibility, .inputMonitoring].compactMap { permission in
            guard let names = byPermission[permission] else { return nil }
            return (permission, names)
        }
    }
}
