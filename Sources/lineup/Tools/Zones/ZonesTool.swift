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
    private let placementCenter: WindowPlacementCenter
    private let layoutMutationCenter: ZoneLayoutMutationCenter
    private let hyperkeyIncludesShift: () -> Bool

    init(placementCenter: WindowPlacementCenter,
         layoutMutationCenter: ZoneLayoutMutationCenter,
         hyperkeyIncludesShift: @escaping () -> Bool = { false }) {
        self.placementCenter = placementCenter
        self.layoutMutationCenter = layoutMutationCenter
        self.hyperkeyIncludesShift = hyperkeyIncludesShift
    }

    private lazy var dragSnap = DragSnapController(
        configProvider: { [weak self] in self?.config ?? LineupConfig() },
        triggerProvider: { [weak self] in self?.dragSnapTrigger ?? .default },
        placementCenter: placementCenter)

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
        // Tiles can remain enabled while Zones is stopped. Keep this shell seam installed for
        // the lifetime of the attached tool, but capture Zones weakly so a restart/deallocation
        // cannot leave the center retaining the tool or its resources.
        layoutMutationCenter.installHandler { [weak self] screenKey, leafIndex in
            self?.toggleParentSplit(screenKey: screenKey, leafIndex: leafIndex)
                ?? .unavailable("Zones is unavailable.")
        }
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
    private var shortcuts: Shortcuts {
        if let stored = config.shortcuts { return stored }
        return usingDefaults
            ? ShortcutKit.zonesDefaults(includeShift: hyperkeyIncludesShift())
            : ShortcutKit.defaults
    }

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
            return "Your Zones settings couldn’t be read. They were left untouched. Reset them "
                + "to start editing again; the unreadable file is kept next to your settings."
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
            // Read with `try`, never `try?`: a section we cannot even read back is exactly the
            // case this reset exists for, and swallowing that error would write fresh settings
            // over bytes that were never preserved.
            if let rejected = try services.config.load(JSONValue.self) {
                let url = Product.configDirectory.appendingPathComponent(
                    "config.zones-rejected-\(LineupAppConfigStore.timestamp()).json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rejected).write(to: url, options: .atomic) // throws -> abort
            }
            var fresh = LineupConfig()
            fresh.shortcuts = ShortcutKit.zonesDefaults(includeShift: hyperkeyIncludesShift())
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

    /// Persist edited layouts for one or more screens ATOMICALLY: build one updated config,
    /// validate the WHOLE thing, and save once. Returns false on failure WITHOUT mutating the
    /// live config — so the editor can keep the user's draft and report it, and a multi-screen
    /// save can never partially persist.
    ///
    /// The validation is explicit here because the store does not do it: the section is an opaque
    /// blob to `LineupAppConfigStore`. Refusing an invalid layout at write time is what stops it
    /// becoming an unreadable section — and a bricked Zones pane — at the next launch.
    @discardableResult
    private func applyLayouts(_ changes: [(screen: ScreenInfo, layout: Node)]) -> Bool {
        guard canWrite, let services else { return false }
        guard !changes.isEmpty else { return true }
        var updated = config
        materializeFreshShortcutsIfNeeded(in: &updated)
        let now = ISO8601DateFormatter().string(from: Date())
        for change in changes {
            updated = updated.setting(layout: change.layout, for: change.screen, now: now)
        }
        do {
            try updated.validate()
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
    /// global mouse monitor uninstalled at the next launch — see `start`).
    ///
    /// Only reached with `canWrite` already true — `setDragSnapEnabled` refuses the whole edit
    /// otherwise, rather than flipping the switch for this session and quietly losing it. A save
    /// that fails anyway keeps the live state and is logged.
    private func persistDragSnapEnabled(_ enabled: Bool) {
        guard canWrite, let services else { return }
        var updated = config
        materializeFreshShortcutsIfNeeded(in: &updated)
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
        materializeFreshShortcutsIfNeeded(in: &updated)
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

    /// Refused outright while writes are blocked: a switch that flips now and is back where it
    /// started at the next launch is worse than one that visibly does not move. The pane disables
    /// its toggle and the menu row for the same reason.
    private func setDragSnapEnabled(_ enabled: Bool) {
        guard canWrite else { return }
        if isRunning {
            if enabled { dragSnap.start() } else { dragSnap.stop() }
        }
        persistDragSnapEnabled(enabled)
        services?.refreshMenu()
    }

    /// A missing Zones section may run on an adaptive in-memory preset. Materialize that preset
    /// before any first write, so a later reload does not reinterpret the saved nil as legacy
    /// full-Hyper defaults. A real stored section with `shortcuts == nil` is deliberately left
    /// alone: it is the legacy shape and must not be migrated implicitly.
    private func materializeFreshShortcutsIfNeeded(in config: inout LineupConfig) {
        guard usingDefaults, config.shortcuts == nil else { return }
        config.shortcuts = ShortcutKit.zonesDefaults(includeShift: hyperkeyIncludesShift())
    }

    private func toggleDragSnap() {
        setDragSnapEnabled(!isDragSnapOn)
        settingsModel?.refresh()
    }

    // MARK: - Layout mutations requested by Tiles

    /// Toggle the split containing the requested live leaf. Zones remains the only owner of the
    /// persisted tree: Tiles supplies only a screen key and leaf index through the center.
    private func toggleParentSplit(screenKey: String, leafIndex: Int) -> ZoneLayoutMutationResult {
        guard editorOverlay == nil else {
            return .unavailable("Close the layout editor before changing orientation.")
        }
        guard let screen = NSScreen.screens.first(where: {
            ScreenIdentity.info(for: $0).key == screenKey
        }) else {
            return .unavailable("That display is no longer available.")
        }

        let info = ScreenIdentity.info(for: screen)
        let root = config.layout(forKey: info.key)
        let container = Layout.rootContainer(frame: screen.frame, visibleFrame: screen.visibleFrame)
        guard container.width > 0, container.height > 0, info.pixelsWide > 0 else {
            return .unavailable("That display has no usable layout area.")
        }
        let leaves = Layout.leaves(root, container: container, pixelsWide: info.pixelsWide)
        guard leaves.indices.contains(leafIndex) else {
            return .unavailable("That tile is no longer available.")
        }
        let leafPath = leaves[leafIndex].path
        guard !leafPath.isEmpty else {
            return .unavailable("The layout has no split to change.")
        }

        let changed = LayoutEdit.toggleParentAxis(
            root, at: leafPath, rootPixelsWide: info.pixelsWide,
            rootPointsWide: Double(container.width))
        guard changed != root else {
            return .unavailable("The layout could not change orientation.")
        }
        guard case let .split(newAxis, _, _) = changed.node(at: Array(leafPath.dropLast())) else {
            return .unavailable("The layout could not change orientation.")
        }
        // `applyLayouts` validates the whole config, saves atomically, and only then updates the
        // live copy. Do not report a changed orientation before that persistence succeeds.
        guard applyLayouts([(screen: info, layout: changed)]) else {
            return .unavailable("The layout could not be saved.")
        }
        return .changed(newAxis)
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

    /// A Settings recorder suspended the whole registry and these rows did not come back — some
    /// other app took the combo in the meantime. `registerHotkeys()` never runs for them, so
    /// without this they are dead rows in the registry that nothing reports: recording them here
    /// puts them in the blocked-shortcuts warning, with its "Retry shortcuts" action.
    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {
        guard isRunning else { return }
        var added = false
        for failure in failures {
            guard !failedHotkeys.contains(where: {
                $0.keyCode == failure.keyCode && UInt32($0.modifiers) == failure.modifiers
            }) else { continue }
            guard let binding = shortcuts.bindings.first(where: {
                $0.keyCode == failure.keyCode && UInt32($0.modifiers) == failure.modifiers
            }) else { continue }
            failedHotkeys.append(FailedHotkey(
                action: binding.action,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                reason: HotkeyFailure.carbon(failure.status).displayReason))
            added = true
        }
        guard added else { return }
        services?.refreshMenu()
        settingsModel?.refresh()
    }

    private func retryHotkeys() {
        registerHotkeys()
        services?.refreshMenu()
    }

    private func performCycle(_ side: Side, now: Double) {
        cycleState = WindowMover.cycleFocusedWindow(
            side, config: config, now: now, prev: cycleState,
            onPlacement: { [weak self] placement in
                self?.placementCenter.publish(WindowPlacementEvent(
                    window: placement.window,
                    target: .freeform(frame: placement.frame)))
            })
    }

    private func perform(_ action: String) {
        let now = Date().timeIntervalSinceReferenceDate
        switch action {
        case "left":
            performCycle(.left, now: now)
        case "right":
            performCycle(.right, now: now)
        case "center":
            performCycle(.center, now: now)
        case "restore":
            cycleState = nil
            WindowMover.restoreFocusedWindow()
        default:
            cycleState = nil // any other action breaks an in-progress cycle
            if let zoneIndex = ZoneAction.zeroBasedIndex(from: action) {
                let screens = NSScreen.screens
                if let placement = WindowMover.snapFocusedWindow(toZoneIndex: zoneIndex, config: config),
                   let screenIndex = ScreenPicker.bestScreenIndex(
                       forWindow: placement.frame, screens: screens.map(\.frame)) {
                    let key = ScreenIdentity.info(for: screens[screenIndex]).key
                    placementCenter.publish(WindowPlacementEvent(
                        window: placement.window,
                        target: .zone(screenKey: key, index: zoneIndex, frame: placement.frame)))
                }
            } else {
                if let placement = WindowMover.snapFocusedWindow(toQuickAction: action, config: config) {
                    placementCenter.publish(WindowPlacementEvent(
                        window: placement.window, target: .freeform(frame: placement.frame)))
                }
            }
        }
    }

    /// How many zones the CURRENT display's layout resolves to, so the Settings pane can mark the
    /// Zone-N rows past it. Zero when there is no screen to ask about (offscreen test runs).
    ///
    /// Resolved against a unit container: only the leaf COUNT is wanted, and that is independent
    /// of the rectangle the layout is drawn into.
    private var mainScreenZoneCount: Int {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return 0 }
        let info = ScreenIdentity.info(for: screen)
        let root = config.layout(forKey: info.key)
        return Layout.zones(root,
                            container: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                            pixelsWide: max(info.pixelsWide, 1)).count
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
        drag.isEnabled = canWrite // the toggle cannot be persisted, so it must not appear to work
        return [edit, drag]
    }

    var warnings: [ToolWarning] {
        var out: [ToolWarning] = []
        if !failedHotkeys.isEmpty {
            let count = failedHotkeys.count
            var details = failedHotkeys.prefix(4).map {
                "\(ShortcutKit.display(keyCode: $0.keyCode, modifiers: $0.modifiers)) "
                    + "\(Self.label(for: $0.action)): \($0.reason)"
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

    /// Cross-tool conflict source (§5.6): the combos Zones holds whether or not it is running.
    ///
    /// Read back through the config scope rather than from `self.config`, so the answer reflects
    /// what is actually persisted; falls back to the effective set (which is the built-in
    /// defaults on a fresh install, and those ARE registered the moment Zones starts).
    ///
    /// The drag bind is deliberately absent: it is a key held during a mouse drag, not a Carbon
    /// hotkey, and it is checked separately inside the Zones pane.
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] {
        var effective = shortcuts
        if let services,
           let stored = try? services.config.load(LineupConfig.self),
           let storedShortcuts = stored.shortcuts {
            effective = storedShortcuts
        }
        return effective.bindings.map { ($0.keyCode, UInt32(truncatingIfNeeded: $0.modifiers)) }
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
            canReset: { [weak self] in self?.services?.config.canWrite ?? false },
            resetSection: { [weak self] in self?.resetSection() },
            shortcuts: { [weak self] in
                self?.shortcuts ?? ShortcutKit.zonesDefaults(includeShift: false)
            },
            setShortcuts: { [weak self] in self?.applyShortcuts($0) },
            isDragSnapOn: { [weak self] in self?.isDragSnapOn ?? false },
            setDragSnapOn: { [weak self] in self?.setDragSnapEnabled($0) },
            dragTrigger: { [weak self] in self?.dragSnapTrigger ?? .default },
            setDragTrigger: { [weak self] in self?.applyDragSnapTrigger($0) },
            openLayoutEditor: { [weak self] in self?.openEditor() },
            isRunning: { [weak self] in self?.isRunning ?? false },
            zoneCount: { [weak self] in self?.mainScreenZoneCount ?? 0 },
            boundCombos: { [weak self] in self?.services?.boundCombos() ?? [] }))
    }
}
