import AppKit
import AppCore
import HyperkeyCore
import SwiftUI
import os

/// The Hyperkey tool: turns one key into a system-wide ⌃⌥⇧⌘ modifier, so Lineup's own shortcuts
/// (and everyone else's hyper-based ones) work without Karabiner or Raycast.
///
/// Off by default, and it is the only tool that needs Input Monitoring — which is requested
/// LAZILY, on the first enable, never at launch. `HyperKeyController.ensureListenEventAccess()`
/// is the single request site, reached only from `apply()` with the tool running.
///
/// Two flags describe "enabled" and they are NOT peers:
///  * `config.json → tools.hyperkey.enabled` (the ToolSection flag, owned by `ToolRegistry`) is
///    **authoritative**. It is what starts and stops this object.
///  * `HyperKeySettings.enabled`, inside the section blob, exists only because the blob is the
///    legacy Cycler `hyperKey` shape (plan §2.2) and the migration seeds the tool flag from it.
///    It is written to match the tool flag on every save and is never read to decide anything.
@MainActor
final class HyperkeyTool: Tool {
    let id = ToolID.hyperkey
    let displayName = "Hyperkey"
    let summary = "Turn one key into a system-wide ⌃⌥⇧⌘ modifier."
    let iconSymbol = "capslock"
    let requiredPermissions: Set<Permission> = [.inputMonitoring]
    /// A silent auto-update must never spontaneously grab the user's Caps Lock.
    let defaultEnabled = false

    private(set) var isRunning = false
    private(set) var settings: HyperKeySettings = .disabled

    private let controller = HyperKeyController()
    private var log = Logger(subsystem: Product.logSubsystem, category: "hyperkey-tool")
    /// Kept after `stop()` on purpose: the Settings pane is rendered even when the tool is off, so
    /// a trigger change made while disabled still has somewhere to persist to.
    private var services: ToolServices?
    /// Edits made from the pane before this tool has EVER been started in this launch. `Tool` is
    /// frozen and the shell only mints a `ToolConfigScope` in `start()`, so there is nowhere to
    /// persist to yet; the edit is held here and written the moment the tool starts. The pane must
    /// stay editable while the tool is off (picking a trigger before turning Hyperkey on is the
    /// normal order), and losing an unused trigger choice at quit is the cheapest possible cost.
    /// If the shell ever hands tools a config scope at registration time, delete this.
    private var pendingSettings: HyperKeySettings?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// `stop()` must not persist `enabled = false` when the whole app is quitting — only when the
    /// USER turned the tool off. `AppShell.applicationWillTerminate` runs the termination cleanups
    /// before `registry.stopAll()`, so our cleanup block is a reliable "we are quitting" signal.
    /// If that ordering ever changed the worst case is a stale `false` in the blob, which nothing
    /// reads: the tool flag is authoritative on load.
    private var isTerminating = false

    /// Cached because `orphanedMappingDetected()` spawns `hidutil`, and `warnings` is recomputed
    /// on every menu build. Refreshed on the events that can actually change it.
    private(set) var orphanedMapping = false
    private var lastOrphanProbe: Date?

    private lazy var paneModel = HyperkeyPaneModel(tool: self)

    // MARK: - Lifecycle

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        isTerminating = false
        settings = pendingSettings
            ?? ((try? services.config.load(HyperKeySettings.self)) ?? .disabled)
        pendingSettings = nil

        // Before the first apply(): a Caps Lock remap left by a previous standalone-Cycler install
        // must become ours, or we would use it and never clean it up (plan §5.2).
        CapsLockHandoff.adoptLegacyOwnershipIfNeeded()

        // apply() resolves asynchronously (hidutil runs on a background queue), so the pill, the
        // menu and the pane must refresh on this callback, not on apply()'s return.
        controller.onStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .blocked(let message) = state {
                    self.log.error("Hyper Key blocked: \(message, privacy: .public)")
                    HyperKeyBlockedPill.shared.show(message: message)
                } else {
                    HyperKeyBlockedPill.shared.hide()
                }
                self.refreshRecoveryState()
                self.services?.refreshMenu()
                self.services?.refreshSettings()
                self.paneModel.refresh()
            }
        }

        // The shell owns signals now (cycler's installHyperKeySignalCleanup() is NOT ported), but
        // the tap and the hidutil mapping still have to come down on SIGTERM/SIGINT/SIGHUP.
        services.termination.addCleanup(.hyperkey) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTerminating = true
                self.controller.stop()
                HyperKeyBlockedPill.shared.hide()
            }
        }

        // Sleep tears the tap down and can drop the hidutil mapping; re-apply on wake.
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        // Coming back from System Settings is when a fresh Input Monitoring grant becomes visible
        // — and when a just-quit standalone Cycler stops blocking us.
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification)

        isRunning = true
        // The tool flag is authoritative and it is now true; mirror it into the blob.
        mirrorEnabledFlag()
        refreshRecoveryState(force: true)
        apply()
        paneModel.refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // Disables the tap, removes the run-loop source, invalidates the Secure Input timer and
        // clears the hidutil mapping IF we own it.
        controller.stop()
        controller.onStateChange = nil
        HyperKeyBlockedPill.shared.hide()
        services?.termination.removeCleanup(.hyperkey)
        for entry in observers { entry.center.removeObserver(entry.token) }
        observers.removeAll()
        // The user turned it off; quitting must not persist that.
        if !isTerminating { mirrorEnabledFlag() }
        refreshRecoveryState(force: true)
        paneModel.refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                // Debounced: didBecomeActive fires on every app activation and the probe is a
                // subprocess.
                self.refreshRecoveryState()
                self.apply()
            }
        }
        observers.append((center, token))
    }

    // MARK: - Apply

    /// Re-evaluates every gate and hands the controller the effective settings.
    private func apply() {
        guard isRunning else { return }
        // Checked here rather than inside the controller because NSRunningApplication lookups are
        // main-actor work and the controller deliberately is not @MainActor.
        controller.blockedByStandaloneCycler = SingleInstance.standaloneCyclerIsRunning() != nil
        var effective = settings
        effective.enabled = true // the TOOL flag is authoritative, and it is true while running
        controller.apply(effective)
    }

    /// Start/stop path only. Writing `config.json` on every launch just to restate a flag nothing
    /// reads would be pure churn (and pointless risk on a file three tools share), so this writes
    /// only when the blob actually disagrees with the authoritative tool flag.
    private func mirrorEnabledFlag() {
        guard settings.enabled != isRunning else { return }
        save()
    }

    /// Mirrors the tool flag into the blob and persists. Never called from the quit path.
    private func save() {
        settings.enabled = isRunning
        guard let services else {
            pendingSettings = settings // never started: flush on the first start()
            return
        }
        guard services.config.canWrite else {
            log.error("hyperkey settings not saved: \(services.config.blockedMessage ?? "writes blocked", privacy: .public)")
            return
        }
        do {
            try services.config.save(settings)
        } catch {
            log.error("could not save hyperkey settings: \(error, privacy: .public)")
        }
    }

    // MARK: - Settings edits (from the pane; valid whether or not the tool is running)

    func setTrigger(_ trigger: TriggerKey) {
        guard settings.triggerKey != trigger else { return }
        settings.triggerKey = trigger
        save()
        apply()
        paneModel.refresh()
    }

    func setIncludeShift(_ includeShift: Bool) {
        guard settings.includeShift != includeShift else { return }
        settings.includeShift = includeShift
        save()
        apply()
        paneModel.refresh()
    }

    /// The pane's "Restore Caps Lock" button.
    func restoreCapsLock() {
        CapsLockHandoff.restoreCapsLock()
        refreshRecoveryState(force: true)
        if isRunning { apply() }
        services?.refreshMenu()
        paneModel.refresh()
    }

    var statusText: String? { controller.settingsStatus }
    var needsInputMonitoring: Bool { controller.needsInputMonitoring }
    var permissions: PermissionCenter? { services?.permissions ?? PermissionCenter.shared }

    /// `hidutil` is a subprocess; keep the probe off the hot paths. `force` is for the moments the
    /// answer genuinely just changed (a restore, the pane opening, start/stop).
    func refreshRecoveryState(force: Bool = false) {
        if !force, let last = lastOrphanProbe, Date().timeIntervalSince(last) < 5 { return }
        lastOrphanProbe = Date()
        orphanedMapping = CapsLockHandoff.orphanedMappingDetected()
    }

    // MARK: - Menu

    /// Status only, or nothing: Hyperkey has no actions of its own. A blocked state is a warning,
    /// not a menu row, so it appears at the TOP of the menu with its recovery action.
    func menuItems() -> [NSMenuItem] {
        guard case .active = controller.state, let status = controller.menuStatus else { return [] }
        return [ToolMenu.info(status)]
    }

    var warnings: [ToolWarning] {
        var out: [ToolWarning] = []
        if case .blocked = controller.state, let status = controller.menuStatus {
            let needsIM = controller.needsInputMonitoring
            out.append(ToolWarning(
                id: needsIM ? "hyperkey.inputMonitoring" : "hyperkey.blocked",
                text: status,
                actionTitle: needsIM ? "Grant Input Monitoring…" : nil,
                action: needsIM ? { [weak self] in
                    self?.permissions?.openInputMonitoringSettings()
                } : nil))
        }
        if orphanedMapping {
            out.append(ToolWarning(
                id: "hyperkey.orphanedMapping",
                text: "⚠︎ Caps Lock is still remapped by an app that isn’t running",
                detailLines: ["Left behind by a Cycler install that quit without cleaning up."],
                actionTitle: "Restore Caps Lock",
                action: { [weak self] in self?.restoreCapsLock() }))
        }
        return out
    }

    // MARK: - Settings pane

    func makeSettingsPane() -> AnyView {
        paneModel.refresh()
        return AnyView(HyperkeySettingsPane(model: paneModel))
    }
}
