import AppKit
import AppCore
import ApplicationServices
import Foundation
import SwiftUI
import ZonesCore

/// Zones: the window manager Lineup 1.x was. Snap the focused window into a zone with a global
/// shortcut, cycle widths, restore, and drag a window onto a zone with a modifier held.
///
/// This is 1.x's `AppDelegate` minus everything the shell now owns (status item, Sparkle,
/// launch at login, the Accessibility watch, About, Welcome, quit). What is left is exactly the
/// tool's own state: the config section, the hotkeys, the drag monitor, the layout editor and the
/// screen observer — and `stop()` gives every one of them back.
@MainActor
final class ZonesTool: Tool {
    let id = ToolID.zones
    let displayName = "Zones"
    let summary = "Snap and resize windows with shortcuts or a modifier-drag."
    let iconSymbol = "square.grid.2x2"
    let requiredPermissions: Set<Permission> = [.accessibility]
    /// Zones is what every existing Lineup user already has, so it is on unless they turn it off.
    let defaultEnabled = true

    private(set) var isRunning = false

    /// Kept after `stop()`: the pane is rendered even while the tool is disabled, and it still has
    /// to read and save the section. Only the RESOURCES are released on stop, never the handle.
    private var services: ToolServices?

    private var config = LineupConfig()
    private var configState: ConfigState = .ok
    /// True while we are running on built-in defaults because the section isn't on disk yet.
    /// The screen observer re-reads only in this state, mirroring 1.x, where the reload was
    /// limited to a deferred migration.
    private var usingDefaults = true

    private var cycleState: CycleState?            // left/right cycle progress between presses
    private var editorOverlay: LayoutEditorOverlayController?
    private var hotkeyTokens: [HotkeyManager.Token] = []
    private var failedHotkeys: [FailedHotkey] = []
    private var screenObserver: NSObjectProtocol?
    /// Held so the open pane keeps its published state across SwiftUI rebuilds, and so the tool
    /// can push changes it makes itself (a menu toggle) into an open Settings window.
    private var settingsModel: ZonesSettingsModel?

    private lazy var dragSnap = DragSnapController(
        configProvider: { [weak self] in self?.config ?? LineupConfig() },
        triggerProvider: { [weak self] in self?.dragSnapTrigger ?? .default })

    private enum ConfigState: Equatable {
        case ok
        /// The section exists but doesn't decode, or was written by a newer Lineup. Run defaults
        /// and BLOCK writes, so a save can't clobber something the user might still recover.
        case sectionUnreadable
    }

    private struct FailedHotkey {
        let action: String
        let keyCode: Int
        let modifiers: Int
        let reason: String
    }

    // MARK: - Lifecycle

    /// Registration, not start: take the config scope and read the section, so the pane shows and
    /// saves real settings even if Zones is never switched on. Acquires nothing.
    func attach(_ services: ToolServices) {
        self.services = services
        reloadConfig()
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        reloadConfig()
        registerHotkeys()
        // Modifier-drag-to-snap defaults to on; respect a saved opt-out.
        if config.dragSnapEnabled ?? true { dragSnap.start() }
        // A layout can be saved for a display that isn't connected yet, and (from Phase 8) a
        // deferred legacy import completes the moment its display comes back. Watch for displays
        // arriving so that lands NOW rather than at the next launch.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                // Posted on the main run loop; the block's type just isn't isolated.
                MainActor.assumeIsolated { self?.screensChanged() }
            }
        isRunning = true
        services.refreshMenu()
        settingsModel?.refresh()
    }

    /// Releases EVERY resource `start()` acquired. Idempotent, and safe when not running.
    func stop() {
        services?.hotkeys.unregisterAll()          // Carbon refs released; siblings untouched
        hotkeyTokens.removeAll()
        failedHotkeys.removeAll()
        dragSnap.stop()                            // global NSEvent monitor + lingerTimer
        editorOverlay?.forceClose()                // every EditorWindow, WITHOUT committing
        editorOverlay = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        SnapMemory.shared.reset()                  // drop retained AXUIElements
        cycleState = nil
        isRunning = false
        services?.refreshMenu()
        settingsModel?.refresh()
    }

    // MARK: - Effective settings

    /// The effective shortcut set (user config, or the built-in defaults).
    private var shortcuts: Shortcuts { config.shortcuts ?? ShortcutKit.defaults }

    /// The effective drag-snap bind, with nil/unknown config values falling back to Shift.
    private var dragSnapTrigger: DragSnapTrigger {
        DragSnapTrigger(keyCode: config.dragSnapKeyCode,
                        modifiers: config.dragSnapModifiers ?? ShortcutKit.defaultDragSnapModifiers)
    }

    /// Live while running; the persisted flag while stopped, so the pane tells the truth about
    /// what will happen when Zones is switched back on.
    private var isDragSnapOn: Bool {
        isRunning ? dragSnap.isEnabled : (config.dragSnapEnabled ?? true)
    }

    /// Writes are blocked when the envelope was rejected (shell-level) OR when our own section
    /// was (tool-level). Both are recoverable, never destructive.
    private var canWrite: Bool {
        configState == .ok && (services?.config.canWrite ?? false)
    }

    private var configBlockedMessage: String? {
        if configState == .sectionUnreadable {
            return "Your Zones settings couldn’t be read. They were left untouched — reset them "
                + "from the menu to start editing again."
        }
        return services?.config.blockedMessage
    }

    // MARK: - Config

    private func reloadConfig() {
        guard let services else {
            config = LineupConfig(); usingDefaults = true; configState = .ok
            return
        }
        do {
            guard let loaded = try services.config.load(LineupConfig.self) else {
                // No section yet (fresh install, or the legacy import hasn't run). Defaults, and
                // writes stay ALLOWED — there is nothing on disk to clobber.
                config = LineupConfig(); usingDefaults = true; configState = .ok
                return
            }
            // Same two gates 1.x applied to zones.json: a newer schema, or a layout that doesn't
            // validate, is a file we must not overwrite.
            guard loaded.schemaVersion <= LineupConfig.currentSchema else {
                throw LineupConfigError.unsupportedSchema(loaded.schemaVersion)
            }
            try loaded.validate()
            config = loaded
            usingDefaults = false
            configState = .ok
        } catch {
            services.log.error("zones settings could not be read (left untouched): \(error, privacy: .public)")
            config = LineupConfig()
            usingDefaults = false
            configState = .sectionUnreadable
        }
    }

    /// Recovery from `.sectionUnreadable`: preserve the rejected blob FIRST, and abort if that
    /// fails — exactly 1.x's reset discipline, so a bad section is never silently destroyed.
    private func resetSection() {
        guard let services else { return }
        do {
            if let rejected = (try? services.config.load(JSONValue.self)) ?? nil {
                let url = Product.configDirectory.appendingPathComponent(
                    "config.zones-rejected-\(LineupAppConfigStore.timestamp()).json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rejected).write(to: url, options: .atomic) // throws -> abort
            }
            let fresh = LineupConfig()
            try services.config.save(fresh)
            config = fresh
            usingDefaults = false
            configState = .ok
            registerHotkeys()
        } catch {
            services.log.error("zones reset aborted (settings left untouched): \(error, privacy: .public)")
        }
        services.refreshMenu()
        settingsModel?.refresh()
    }

    private func screensChanged() {
        // A section that appeared since we started (a deferred legacy import completing on
        // reconnect) is adopted without a relaunch. A section we already hold is left alone.
        if usingDefaults { reloadConfig() }
        services?.refreshMenu()
        settingsModel?.refresh()
    }

    // MARK: - Persistence
    //
    // Every one of these writes FIRST and assigns to `config` only on success, and every one is
    // gated on `canWrite`. That ordering is why a failed save never corrupts live state: the app
    // keeps running on the last known-good config and the user keeps their draft. Do not
    // "simplify" it into an assign-then-write.

    /// Persist edited layouts for one or more screens ATOMICALLY: build one updated config and
    /// save once (which validates the whole thing). Returns false on failure WITHOUT mutating the
    /// live config — so the editor can keep the user's draft and report it, and a multi-screen
    /// save can never partially persist.
    @discardableResult
    private func applyLayouts(_ changes: [(screen: ScreenInfo, layout: Node)]) -> Bool {
        guard canWrite, let services else { return false }
        guard !changes.isEmpty else { return true }
        var updated = config
        let now = ISO8601DateFormatter().string(from: Date())
        for change in changes {
            updated = updated.setting(layout: change.layout, for: change.screen, now: now)
        }
        do {
            try services.config.save(updated)
            config = updated
            usingDefaults = false
            services.refreshMenu()
            return true
        } catch {
            services.log.error("layout save failed (not applied): \(error, privacy: .public)")
            return false
        }
    }

    /// Persist a new shortcut set and re-register the global hotkeys.
    private func applyShortcuts(_ newShortcuts: Shortcuts) {
        guard canWrite, let services else { return }
        var updated = config
        updated.shortcuts = newShortcuts
        do {
            try services.config.save(updated)
            config = updated
            usingDefaults = false
            if isRunning { registerHotkeys() }   // a disabled tool must not grab hotkeys
            services.refreshMenu()
        } catch {
            services.log.error("shortcuts save failed (not applied): \(error, privacy: .public)")
        }
    }

    /// Persist the modifier-drag toggle so it survives relaunch (a disabled state keeps the
    /// global mouse monitor uninstalled at the next launch — see `start`). Best-effort: if
    /// writes are blocked or the save fails, the in-session toggle still holds, we just don't
    /// persist it.
    private func persistDragSnapEnabled(_ enabled: Bool) {
        guard canWrite, let services else { return }
        var updated = config
        updated.dragSnapEnabled = enabled
        do {
            try services.config.save(updated)
            config = updated
            usingDefaults = false
        } catch {
            services.log.error("drag-snap setting save failed (kept in session): \(error, privacy: .public)")
        }
    }

    private func applyDragSnapTrigger(_ trigger: DragSnapTrigger) {
        guard canWrite, let services else { return }
        var updated = config
        updated.dragSnapKeyCode = trigger.keyCode
        updated.dragSnapModifiers = trigger.modifiers
        do {
            try services.config.save(updated)
            config = updated
            usingDefaults = false
            services.refreshMenu()
        } catch {
            services.log.error("drag-snap bind save failed (not applied): \(error, privacy: .public)")
        }
    }

    private func setDragSnapEnabled(_ enabled: Bool) {
        if isRunning {
            if enabled { dragSnap.start() } else { dragSnap.stop() }
        }
        persistDragSnapEnabled(enabled)
        services?.refreshMenu()
    }

    private func toggleDragSnap() {
        setDragSnapEnabled(!isDragSnapOn)
        settingsModel?.refresh()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        guard let services else { return }
        services.hotkeys.unregisterAll()
        hotkeyTokens.removeAll()
        var failures: [FailedHotkey] = []
        for binding in shortcuts.bindings {
            let action = binding.action
            let result = services.hotkeys.register(keyCode: binding.keyCode,
                                                   modifiers: UInt32(binding.modifiers)) { [weak self] in
                self?.perform(action)
            }
            switch result {
            case .success(let token):
                hotkeyTokens.append(token)
            case .failure(let failure):
                failures.append(FailedHotkey(action: action, keyCode: binding.keyCode,
                                             modifiers: binding.modifiers,
                                             reason: failure.displayReason))
            }
        }
        failedHotkeys = failures
    }

    private func retryHotkeys() {
        registerHotkeys()
        services?.refreshMenu()
    }

    private func perform(_ action: String) {
        let now = Date().timeIntervalSinceReferenceDate
        switch action {
        case "left":
            cycleState = WindowMover.cycleFocusedWindow(.left, config: config, now: now, prev: cycleState)
        case "right":
            cycleState = WindowMover.cycleFocusedWindow(.right, config: config, now: now, prev: cycleState)
        case "center":
            cycleState = WindowMover.cycleFocusedWindow(.center, config: config, now: now, prev: cycleState)
        case "restore":
            cycleState = nil
            WindowMover.restoreFocusedWindow()
        default:
            cycleState = nil // any other action breaks an in-progress cycle
            if let zoneIndex = ZoneAction.zeroBasedIndex(from: action) {
                WindowMover.snapFocusedWindow(toZoneIndex: zoneIndex, config: config)
            } else {
                WindowMover.snapFocusedWindow(toQuickAction: action, config: config)
            }
        }
    }

    // MARK: - Layout editor

    private func openEditor() {
        guard editorOverlay == nil else { return }
        let controller = LayoutEditorOverlayController(
            config: config,
            canWrite: canWrite,
            blockedMessage: configBlockedMessage,
            commit: { [weak self] changes in self?.applyLayouts(changes) ?? false },
            onClose: { [weak self] in self?.editorOverlay = nil })
        editorOverlay = controller
        controller.show()
    }

    // MARK: - Menu

    func menuItems() -> [NSMenuItem] {
        let edit = ToolMenu.item("Edit Layout…", symbol: "square.grid.2x2") { [weak self] in
            self?.openEditor()
        }
        edit.isEnabled = canWrite // a blocked config routes the user to the Reset row instead

        let trigger = dragSnapTrigger
        let bind = ShortcutKit.dragSnapDisplay(keyCode: trigger.keyCode, modifiers: trigger.modifiers)
        let drag = ToolMenu.item("\(bind)-drag to snap", symbol: "hand.draw") { [weak self] in
            self?.toggleDragSnap()
        }
        drag.state = isDragSnapOn ? .on : .off
        return [edit, drag]
    }

    var warnings: [ToolWarning] {
        var out: [ToolWarning] = []
        if !failedHotkeys.isEmpty {
            let count = failedHotkeys.count
            var details = failedHotkeys.prefix(4).map {
                "\(ShortcutKit.display(keyCode: $0.keyCode, modifiers: $0.modifiers)) "
                    + "\(Self.label(for: $0.action)) — \($0.reason)"
            }
            if count > 4 { details.append("…and \(count - 4) more") }
            out.append(ToolWarning(
                id: "zones.hotkeys",
                text: "⚠︎ \(count) shortcut\(count == 1 ? "" : "s") blocked",
                detailLines: details,
                actionTitle: "Retry shortcuts",
                action: { [weak self] in self?.retryHotkeys() }))
        }
        if configState == .sectionUnreadable {
            out.append(ToolWarning(
                id: "zones.config",
                text: "⚠︎ Zones settings couldn’t be read",
                detailLines: ["Editing is disabled until you reset them."],
                actionTitle: "Reset Zones settings…",
                action: { [weak self] in self?.resetSection() }))
        }
        return out
    }

    static func label(for action: String) -> String {
        ShortcutKit.quickActions.first(where: { $0.id == action })?.label
            ?? ZoneAction.zeroBasedIndex(from: action).map { "Zone \($0 + 1)" }
            ?? action
    }

    // MARK: - Settings

    func makeSettingsPane() -> AnyView {
        // No refresh() here: this runs inside a SwiftUI view update, and publishing from there is
        // not allowed. The pane refreshes itself in `onAppear`.
        let model = settingsModel ?? makeSettingsModel()
        settingsModel = model
        // The recorder's `SettingsStore` arrives through the environment, injected by
        // `SettingsStore.pane(for:)`.
        return AnyView(ZonesSettingsPane(model: model))
    }

    private func makeSettingsModel() -> ZonesSettingsModel {
        ZonesSettingsModel(context: ZonesSettingsModel.Context(
            canWrite: { [weak self] in self?.canWrite ?? false },
            blockedMessage: { [weak self] in self?.configBlockedMessage },
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutKit.defaults },
            setShortcuts: { [weak self] in self?.applyShortcuts($0) },
            isDragSnapOn: { [weak self] in self?.isDragSnapOn ?? false },
            setDragSnapOn: { [weak self] in self?.setDragSnapEnabled($0) },
            dragTrigger: { [weak self] in self?.dragSnapTrigger ?? .default },
            setDragTrigger: { [weak self] in self?.applyDragSnapTrigger($0) },
            foreignOwner: { [weak self] keyCode, modifiers in
                self?.services?.hotkeys.foreignCombos()
                    .first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.owner
            }))
    }
}
