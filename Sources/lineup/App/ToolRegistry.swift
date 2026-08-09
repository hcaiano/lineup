import AppKit
import AppCore
import os

/// Owns the tool list, their enabled state, and their lifecycles.
///
/// Phase 3 deliberately ships with ZERO tools registered: the shell (menu bar, Settings, Sparkle,
/// permissions, launch at login) must stand on its own before Zones, Cycler and Hyperkey are
/// built against it in parallel.
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

    /// Sidebar toggle / menu toggle. Starts or stops for real, then persists — a failed write
    /// leaves the tool in the state the user just saw, which is the honest outcome.
    func setEnabled(_ enabled: Bool, for id: ToolID) {
        guard let tool = tool(id) else { return }
        if enabled {
            if !tool.isRunning { start(tool) }
        } else {
            if tool.isRunning { tool.stop() }
        }
        do {
            try store.setEnabled(enabled, for: id)
        } catch {
            log.error("could not persist \(id.rawValue, privacy: .public) enabled=\(enabled): \(error, privacy: .public)")
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
            })
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
