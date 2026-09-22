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

    // MARK: - Runtime zone numbering (Phase 2)
    //
    // Global `zone:N` actions are GLOBAL numbers across all saved displays. They resolve
    // through a snapshot built on demand from the CURRENT config + CURRENT NSScreens, so
    // nothing here caches stale screen state: every rebuild re-reads `NSScreen.screens` and
    // re-derives identities.

    /// One connected screen as the snapshot sees it: the config key the numbering map uses
    /// for it — always the screen's EXACT freshly-derived key, since durable preparation
    /// binds every connected display to its current key — and the display id used to find
    /// the live `NSScreen` again at move time. `liveKey` is the freshly derived live
    /// `ScreenInfo.key`: a UUID-less (virtual/headless) display has no display-id match
    /// to rely on, so its live key is the move-time fallback identity.
    private struct ConnectedScreen {
        let displayID: CGDirectDisplayID?
        let configKey: String
        let liveKey: String
    }

    /// The CANDIDATE result of one preparation pass: tentative adoption/materialization
    /// over an explicit base config, then order normalization. It is what reconciliation
    /// and explicit canWrite-gated user writes persist — NEVER what `zone:N` actions
    /// route through (routing is committed-only, see `CommittedZoneSnapshot`).
    /// `@MainActor`: its lookup re-reads `NSScreen` and derives identities synchronously
    /// through the @MainActor `ScreenIdentity`, so the annotation keeps those calls legal
    /// under Swift 5.9 without introducing any task hop.
    @MainActor
    private struct ZoneRuntimeSnapshot {
        let config: LineupConfig
        let numbering: ZoneNumbering
        /// Connected screens in the spatial order that seeded the normalization.
        let connected: [ConnectedScreen]

        func isConnected(configKey: String) -> Bool {
            connected.contains { $0.configKey == configKey }
        }

        /// The live `NSScreen` a snapshot config key is currently connected to. Delegates
        /// to the shared move-time lookup; re-reads `NSScreen.screens` rather than holding
        /// screen objects, so a screen that disconnected between snapshot and move yields
        /// nil (safe no-op) instead of a stale display.
        func screen(forKey configKey: String) -> NSScreen? {
            guard let entry = connected.first(where: { $0.configKey == configKey }) else { return nil }
            return ZoneRuntimeSnapshot.liveScreen(for: entry)
        }

        /// Shared move-time screen lookup for both snapshot flavors: display-id matching
        /// is preferred; a UUID-less (virtual/headless) display has no display id, so it
        /// matches by the freshly derived live `ScreenInfo.key` stored as `liveKey`.
        static func liveScreen(for entry: ConnectedScreen) -> NSScreen? {
            if let id = entry.displayID,
               let match = NSScreen.screens.first(where: { ScreenIdentity.displayIdentifier(for: $0) == id }) {
                return match
            }
            return NSScreen.screens.first { ScreenIdentity.info(for: $0).key == entry.liveKey }
        }

        /// Initial display order for previously unordered connected screens: spatial
        /// left-to-right, ties broken top-to-bottom in Cocoa coordinates (up is +y, so the
        /// TOP screen has the LARGER minY and comes first), then stable screen key.
        static func spatiallyOrdered(_ screens: [NSScreen]) -> [NSScreen] {
            screens.sorted { a, b in
                if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
                if a.frame.minY != b.frame.minY { return a.frame.minY > b.frame.minY }
                return ScreenIdentity.info(for: a).key < ScreenIdentity.info(for: b).key
            }
        }
    }

    private lazy var dragSnap = DragSnapController(
        configProvider: { [weak self] in self?.config ?? LineupConfig() },
        triggerProvider: { [weak self] in self?.dragSnapTrigger ?? .default })

    /// Build the runtime numbering snapshot from the live config and connected screens.
    private func runtimeNumberingSnapshot() -> ZoneRuntimeSnapshot {
        runtimeNumberingSnapshot(base: config)
    }

    /// The current connected screens in the shared spatial order, paired with their freshly
    /// derived identities. Pure collection of live state — no config or ownership decisions
    /// happen here; both snapshot flavors start from exactly these pairs.
    private func currentSpatialScreens() -> [(screen: NSScreen, info: ScreenInfo)] {
        ZoneRuntimeSnapshot.spatiallyOrdered(NSScreen.screens).map { ($0, ScreenIdentity.info(for: $0)) }
    }

    /// Build the CANDIDATE numbering snapshot from an explicit base config and the CURRENT
    /// connected screens: spatially order the screens, collect their `ScreenInfo`s, let the
    /// pure `ZoneScreenPreparation` helper adopt/materialize entries under each screen's
    /// EXACT key (durable alias ownership — no live display stays bound to a legacy alias),
    /// normalize orders with the returned exact connected keys — disconnected saved
    /// layouts stay in the config so their global ranges remain reserved — and map the
    /// result. Pure wrt persisted state: this never writes; persistence is
    /// `reconcileDisplayOrders()`/the user-write path. The explicit base lets an explicit
    /// user write normalize even while `usingDefaults` (fresh install / deferred import),
    /// and lets `resetSection` normalize a fresh config without reading the unreadable
    /// live section. This snapshot is TENTATIVE: nothing it adopts is real until a
    /// successful save commits it — routing must use `committedNumberingSnapshot()`.
    private func runtimeNumberingSnapshot(base: LineupConfig) -> ZoneRuntimeSnapshot {
        let spatial = currentSpatialScreens()
        let prepared = ZoneScreenPreparation.prepare(config: base, screens: spatial.map { $0.info })
        let normalized = ZoneOrderNormalizer.normalizeOrders(
            in: prepared.config, connectedKeys: prepared.connectedKeys)
        // After preparation the map's config key for a live screen IS its exact current
        // key — identical to the freshly derived live key.
        let connected = spatial.map { screen, info in
            ConnectedScreen(
                displayID: ScreenIdentity.displayIdentifier(for: screen),
                configKey: info.key,
                liveKey: info.key)
        }
        return ZoneRuntimeSnapshot(
            config: normalized,
            numbering: ZoneNumbering(config: normalized),
            connected: connected)
    }

    /// Build the COMMITTED routing snapshot for `zone:N` shortcut actions: strictly the
    /// current live `config` — the last successfully loaded or saved state — plus the
    /// connected screens mapped ONLY by their exact current `ScreenInfo.key`. Unlike the
    /// candidate `runtimeNumberingSnapshot(base:)`, this performs NO alias adoption, NO
    /// materialization, and NO order normalization, and it never mutates config; the
    /// `ZoneNumbering` map is constructed directly from the committed config. By design:
    /// a legacy alias whose adoption has not been committed stays in the map with no
    /// connected exact owner (its `zone:N` actions are safe no-ops, whatever lookalike is
    /// connected), and a connected exact screen whose order is still nil owns no numbers
    /// until a successful write commits the normalized candidate.
    private func committedNumberingSnapshot() -> CommittedZoneSnapshot {
        let spatial = currentSpatialScreens()
        let targets = spatial.map { screen, info in
            ConnectedScreen(
                displayID: ScreenIdentity.displayIdentifier(for: screen),
                configKey: info.key,
                liveKey: info.key)
        }
        return CommittedZoneSnapshot(config: config, numbering: ZoneNumbering(config: config), targets: targets)
    }

    /// The COMMITTED routing snapshot type for `zone:N` actions. Deliberately separate
    /// from `ZoneRuntimeSnapshot` (the candidate) so the two cannot be confused: candidate
    /// snapshots adopt and normalize tentatively; committed snapshots only ever describe
    /// state that a successful load/save has already made real.
    @MainActor
    private struct CommittedZoneSnapshot {
        let config: LineupConfig
        let numbering: ZoneNumbering
        /// Connected screens under their exact current keys, in the shared spatial order.
        let targets: [ConnectedScreen]

        func isConnected(configKey: String) -> Bool {
            targets.contains { $0.configKey == configKey }
        }

        func screen(forKey configKey: String) -> NSScreen? {
            guard let entry = targets.first(where: { $0.configKey == configKey }) else { return nil }
            return ZoneRuntimeSnapshot.liveScreen(for: entry)
        }
    }

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
        reconcileDisplayOrders()
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        reloadConfig()
        reconcileDisplayOrders()
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
            // Reset is an explicit user write: seed it from a normalized snapshot of a
            // FRESH config (never the unreadable live section), validate, and save exactly
            // once — display orders for the currently connected screens persist with the
            // reset itself, no follow-up reconciliation write needed.
            let fresh = runtimeNumberingSnapshot(base: LineupConfig()).config
            try fresh.validate()
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
        // Reconcile the persisted display orders with the (possibly changed) connected
        // screens: attach/start reloads and every display change come through here, and the
        // guards inside skip fresh-install/deferred-import state and blocked sections.
        reconcileDisplayOrders()
        // The running screen-change path OWNS refreshing an open editor (single observer):
        // it rebases onto the new topology, preserves drafts by exact key, recomputes the
        // global offsets, and requires an explicit Save on the updated numbering.
        editorOverlay?.refreshForDisplayChange()
        services?.refreshMenu()
        settingsModel?.refresh()
    }

    /// Persist normalized display orders (and any newly materialized connected screens)
    /// after a reload or a display change. Only for a section we actually own
    /// (`usingDefaults == false` — a fresh install or a deferred legacy import must NOT be
    /// auto-created from a screen event), and only through the standard write-first
    /// discipline: validate, save, THEN assign; a failed save keeps the last known-good
    /// config. Skipped entirely when the snapshot matches what we already hold.
    private func reconcileDisplayOrders() {
        guard canWrite, !usingDefaults, let services else { return }
        let updated = runtimeNumberingSnapshot().config
        guard updated != config else { return }
        do {
            try updated.validate()
            try services.config.save(updated)
            config = updated
        } catch {
            services.log.error("display order reconciliation failed (kept last known-good config): \(error, privacy: .public)")
        }
    }

    // MARK: - Persistence
    //
    // Every one of these writes FIRST and assigns to `config` only on success, and every one is
    // gated on `canWrite`. That ordering is why a failed save never corrupts live state: the
    // app keeps running on the last known-good config and the user keeps their draft. Do not
    // "simplify" it into an assign-then-write.

    /// The config an EXPLICIT user write starts from: whenever the write gate passes
    /// (`canWrite`), that is the runtime-normalized snapshot config — display orders and
    /// materialized connected screens persist as part of the user's intentional write,
    /// INCLUDING while `usingDefaults` (a fresh install's first layout/shortcut/drag save
    /// creates the section with normalized order already in place). The no-auto-create
    /// rule applies to AUTOMATIC reconciliation only (`reconcileDisplayOrders` keeps its
    /// `!usingDefaults` guard), never to an explicit, canWrite-gated user save.
    private var preparedConfigForUserWrite: LineupConfig {
        guard canWrite else { return config }
        return runtimeNumberingSnapshot().config
    }

    /// Persist the layout editor's COMPLETE proposed config (candidate base + drafts) as ONE
    /// atomic write. Save is an explicit user write, so candidate-only display-order
    /// normalization, screen materialization, and alias adoption commit even when no tree
    /// changed — that is what makes adoption durable the moment the user confirms. The
    /// physical write is skipped only when the proposal already equals the committed config
    /// (a genuine no-op succeeds without touching disk).
    ///
    /// The validation is explicit here because the store does not do it: the section is an opaque
    /// blob to `LineupAppConfigStore`. Refusing an invalid layout at write time is what stops it
    /// becoming an unreadable section — and a bricked Zones pane — at the next launch.
    @discardableResult
    private func applyEditorProposal(_ proposal: LineupConfig) -> Bool {
        guard canWrite, let services else { return false }
        if proposal == config { return true } // complete no-op: nothing to commit, no write
        do {
            try proposal.validate()
            try services.config.save(proposal)
            config = proposal
            usingDefaults = false
            services.refreshMenu()
            // Settings behind the editor must reflect the new zone counts/ranges at once:
            // the zone shortcut groups re-derive from the freshly committed config.
            settingsModel?.refresh()
            return true
        } catch {
            services.log.error("layout save failed (not applied): \(error, privacy: .public)")
            return false
        }
    }

    /// Persist a new shortcut set and re-register the global hotkeys.
    private func applyShortcuts(_ newShortcuts: Shortcuts) {
        guard canWrite, let services else { return }
        var updated = preparedConfigForUserWrite
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
        var updated = preparedConfigForUserWrite
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
        var updated = preparedConfigForUserWrite
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
                // Global numbered zone: `zone:N` is the Nth zone across ALL saved displays
                // (stable numbering), not the Nth zone of the window's current screen.
                moveFocusedWindowToGlobalZone(globalNumber: zoneIndex + 1)
            } else {
                WindowMover.snapFocusedWindow(toQuickAction: action, config: config)
            }
        }
    }

    /// Resolve a 1-based global zone number through the COMMITTED numbering snapshot and
    /// move the focused window to the owning display's local zone — even if the window
    /// starts on another monitor. Routing uses only committed state
    /// (`committedNumberingSnapshot()`), never the tentative candidate snapshot, so uncommitted alias adoption
    /// can never retarget a lookalike display. A number owned by a DISCONNECTED saved
    /// display is a safe no-op (its range stays reserved; it must never retarget another
    /// display). Out-of-range numbers are also no-ops, exactly like the old per-screen
    /// out-of-range bindings.
    @discardableResult
    private func moveFocusedWindowToGlobalZone(globalNumber: Int) -> Bool {
        // COMMITTED routing only: never the candidate/prepared snapshot. Tentative alias
        // adoption that a failed save did not commit must not route — otherwise a legacy
        // alias could retarget one lookalike display now and a different one after a
        // topology change. After a successful reconcile/write, the committed config owns
        // the adopted exact entry and this snapshot activates it.
        let snapshot = committedNumberingSnapshot()
        guard let hit = snapshot.numbering.resolve(globalNumber: globalNumber) else { return false }
        guard snapshot.isConnected(configKey: hit.key),
              let screen = snapshot.screen(forKey: hit.key) else {
            return false // disconnected/reserved, or the display vanished mid-snapshot
        }
        return WindowMover.snapFocusedWindow(
            toZoneIndex: hit.zoneIndex, on: screen, configKey: hit.key, config: snapshot.config)
    }

    /// Settings presentation uses the candidate map only for untouched built-in defaults, where
    /// the first explicit shortcut save will commit those exact display orders. Once a section is
    /// loaded or saved, it mirrors committed routing instead. That keeps a failed alias
    /// reconciliation visibly unavailable rather than promoting its tentative live owner.
    private var zoneShortcutGroupsForSettings: [ZonesSettingsModel.ZoneShortcutGroup] {
        let numbering: ZoneNumbering
        let connectedKeys: Set<String>
        if usingDefaults {
            let snapshot = runtimeNumberingSnapshot()
            numbering = snapshot.numbering
            connectedKeys = Set(snapshot.connected.map(\.configKey))
        } else {
            let snapshot = committedNumberingSnapshot()
            numbering = snapshot.numbering
            connectedKeys = Set(snapshot.targets.map(\.configKey))
        }

        var groups = numbering.displays.compactMap { display -> ZonesSettingsModel.ZoneShortcutGroup? in
            guard display.zoneCount > 0, let first = display.firstZoneNumber else { return nil }
            let last = first + display.zoneCount - 1
            let status: ZonesSettingsModel.ZoneShortcutGroup.Status = connectedKeys.contains(display.key)
                ? .connected
                : .notConnected
            let displayName = display.label.isEmpty ? "Display" : display.label
            let context = "\(displayName), \(status.accessibilityDescription)"
            let rows = (first...last).map { number in
                ZonesSettingsModel.ShortcutRow(
                    id: ZoneAction.id(number),
                    label: "Zone \(number)",
                    accessibilityContext: context)
            }
            return ZonesSettingsModel.ZoneShortcutGroup(
                id: "display:\(display.key)",
                title: displayName,
                rangeLabel: first == last ? "Zone \(first)" : "Zones \(first)–\(last)",
                status: status,
                rows: rows)
        }

        // A saved binding can outlive the layout range it once addressed. Keep only those actual
        // bindings visible so they can be inspected or cleared; never invent empty orphan rows.
        let orphanNumbers = Set(shortcuts.bindings.compactMap { binding -> Int? in
            guard let index = ZoneAction.zeroBasedIndex(from: binding.action) else { return nil }
            let number = index + 1
            return number > numbering.totalZones ? number : nil
        }).sorted()
        if !orphanNumbers.isEmpty {
            let status = ZonesSettingsModel.ZoneShortcutGroup.Status.notInSavedLayout
            groups.append(ZonesSettingsModel.ZoneShortcutGroup(
                id: "unavailable-zones",
                title: "Unavailable zones",
                rangeLabel: nil,
                status: status,
                rows: orphanNumbers.map { number in
                    ZonesSettingsModel.ShortcutRow(
                        id: ZoneAction.id(number),
                        label: "Zone \(number)",
                        accessibilityContext: status.accessibilityDescription)
                }))
        }
        return groups
    }

    // MARK: - Layout editor

    private func openEditor() {
        guard editorOverlay == nil else { return }
        // The editor is an explicit-save flow over the CANDIDATE prepared config: exact
        // connected keys and display orders match what Save will commit, while live routing
        // state stays committed-only until that commit succeeds. Drafts and numbering live
        // in the controller's pure `ZoneEditorSession`.
        let controller = LayoutEditorOverlayController(
            canWrite: canWrite,
            blockedMessage: configBlockedMessage,
            candidate: { [weak self] in self?.runtimeNumberingSnapshot().config },
            save: { [weak self] proposal in self?.applyEditorProposal(proposal) ?? false },
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
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutKit.defaults },
            setShortcuts: { [weak self] in self?.applyShortcuts($0) },
            isDragSnapOn: { [weak self] in self?.isDragSnapOn ?? false },
            setDragSnapOn: { [weak self] in self?.setDragSnapEnabled($0) },
            dragTrigger: { [weak self] in self?.dragSnapTrigger ?? .default },
            setDragTrigger: { [weak self] in self?.applyDragSnapTrigger($0) },
            openLayoutEditor: { [weak self] in self?.openEditor() },
            isRunning: { [weak self] in self?.isRunning ?? false },
            zoneShortcutGroups: { [weak self] in self?.zoneShortcutGroupsForSettings ?? [] },
            boundCombos: { [weak self] in self?.services?.boundCombos() ?? [] }))
    }
}
