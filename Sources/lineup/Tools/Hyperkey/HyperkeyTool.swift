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
    /// Set when our own section is on disk but does NOT decode. Envelope-level damage is the
    /// shell's warning to show; this one is specifically "your Hyperkey settings are unreadable",
    /// and it blocks every write so the bad blob stays recoverable. Same shape as Cycler's.
    private(set) var sectionLoadError: String?

    private let controller = HyperKeyController()
    private var log = Logger(subsystem: Product.logSubsystem, category: "hyperkey-tool")
    /// Handed over at REGISTRATION and kept for the whole process lifetime, `stop()` included: the
    /// pane is rendered even when the tool is off, and picking a trigger before turning Hyperkey on
    /// is the normal order — that edit has to persist immediately, with no tool ever started.
    private var services: ToolServices?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var mappingObserver: UUID?
    /// `stop()` must not persist `enabled = false` when the whole app is quitting — only when the
    /// USER turned the tool off. `AppShell.applicationWillTerminate` runs the termination cleanups
    /// before `registry.stopAll()`, so our cleanup block is a reliable "we are quitting" signal.
    /// If that ordering ever changed the worst case is a stale `false` in the blob, which nothing
    /// reads: the tool flag is authoritative on load.
    private var isTerminating = false

    /// Recovery follows explicit ownership claims from the shared keyboard service.
    /// Cached so the menu and Settings see the same state.
    private(set) var orphanedMapping = false
    private var lastOrphanProbe: Date?

    private lazy var paneModel = HyperkeyPaneModel(tool: self)

    // MARK: - Lifecycle

    /// Registration, not start: take the config scope and read the section, so the pane shows and
    /// saves the real trigger while Hyperkey is off. Acquires no tap, no mapping, no observers.
    func attach(_ services: ToolServices) {
        self.services = services
        controller.useKeyboardMappings(services.keyboardMappings)
        mappingObserver = services.keyboardMappings.observe { [weak self] in
            guard let self else { return }
            self.refreshRecoveryState(force: true)
            self.paneModel.refresh()
            self.services?.refreshMenu()
        }
        loadSettings()
        paneModel.refresh()
    }

    /// `try?` here was destructive: an undecodable section became `.disabled` in memory, and the
    /// very next `mirrorEnabledFlag()` wrote those defaults straight over the user's blob — taking
    /// a migrant's F18 trigger down to Caps Lock on the way. A read failure now blocks writes
    /// instead, exactly as Zones and Cycler do with theirs.
    private func loadSettings() {
        guard let services else { return }
        do {
            settings = try services.config.load(HyperKeySettings.self) ?? .disabled
            sectionLoadError = nil
        } catch {
            log.error("hyperkey settings could not be decoded (left untouched): \(error, privacy: .public)")
            settings = .disabled
            sectionLoadError = "\(error)"
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        isTerminating = false

        // Before the first apply(): a Caps Lock remap left by a previous standalone-Cycler install
        // must become ours, or we would use it and never clean it up (plan §5.2).
        CapsLockHandoff.adoptLegacyOwnershipIfNeeded(using: services.keyboardMappings)

        // apply() resolves asynchronously (keyboard maps apply on a background queue), so the pill, the
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
        // the tap and Hyperkey’s mapping contribution still come down on SIGTERM/SIGINT/SIGHUP.
        services.termination.addCleanup(.hyperkey) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTerminating = true
                self.controller.stop()
                HyperKeyBlockedPill.shared.hide()
            }
        }

        // Sleep can disable the tap and drop HID mappings; reconcile both on wake.
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
        // removes only Hyperkey’s contribution through the shared mapping service.
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
        let didWake = name == NSWorkspace.didWakeNotification
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                // Share the cached recovery state across frequent app activations.
                self.refreshRecoveryState()
                if didWake {
                    // Sleep can eat the trigger's key-up, leaving our synthetic ⌃⌥⇧⌘ latched for
                    // the rest of the session, and it can disable the tap and drop the mapping —
                    // so the wake path always re-applies in full, never the settled fast path.
                    self.controller.resetTriggerState()
                    self.apply(force: true)
                } else {
                    self.apply()
                }
            }
        }
        observers.append((center, token))
    }

    // MARK: - Apply

    /// Re-evaluates every gate and hands the controller the effective settings.
    ///
    /// `force` skips the settled check: wake has to re-arm the tap and re-assert the mapping even
    /// when nothing about the settings changed.
    private func apply(force: Bool = false) {
        guard isRunning else { return }
        // Checked here rather than inside the controller because NSRunningApplication lookups are
        // main-actor work and the controller deliberately is not @MainActor.
        controller.blockedByStandaloneCycler = SingleInstance.standaloneCyclerIsRunning() != nil
        var effective = settings
        effective.enabled = true // the TOOL flag is authoritative, and it is true while running
        // App activation is frequent. A live tap with confirmed shared mappings needs no new
        // application; wake and settings changes still force reconciliation.
        guard force || !controller.isSettled(for: effective) else { return }
        controller.apply(effective)
    }

    /// Start/stop path only. Writing `config.json` on every launch just to restate a flag nothing
    /// reads would be pure churn (and pointless risk on a file three tools share), so this writes
    /// only when the blob actually disagrees with the authoritative tool flag.
    ///
    /// Failures are logged, not surfaced: this runs on start/stop, where there is no edit the user
    /// could be told about and nothing they could do differently.
    private func mirrorEnabledFlag() {
        // Never over an unreadable section: this runs on every start and stop, and it is the path
        // that used to overwrite the user's blob with defaults.
        guard sectionLoadError == nil, settings.enabled != isRunning else { return }
        do {
            try save()
        } catch {
            log.error("could not mirror the hyperkey enabled flag: \(error, privacy: .public)")
        }
    }

    /// Mirrors the tool flag into the blob and persists. Never called from the quit path.
    ///
    /// Throws instead of only logging, so an edit made from the pane can be rolled back and
    /// reported — standalone Cycler alerted on a failed hyper-key save, and swallowing it here
    /// left the pane showing a trigger the user did not actually have.
    private func save() throws {
        guard let services else { throw HyperkeyToolError.notRegistered }
        guard sectionLoadError == nil else { throw HyperkeyToolError.sectionUnreadable }
        guard services.config.canWrite else {
            throw HyperkeyToolError.writesBlocked(services.config.blockedMessage)
        }
        settings.enabled = isRunning
        try services.config.save(settings)
    }

    /// Recovery from an unreadable section: preserve the rejected blob FIRST and abort if that
    /// fails — the store's own reset discipline, so a bad section is never silently destroyed.
    func resetSection() {
        guard let services else { return }
        do {
            if let rejected = try services.config.load(JSONValue.self) {
                let url = Product.configDirectory.appendingPathComponent(
                    "config.hyperkey-rejected-\(LineupAppConfigStore.timestamp()).json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rejected).write(to: url, options: .atomic) // throws -> abort
            }
            sectionLoadError = nil
            settings = .disabled
            try save()
            apply()
        } catch {
            sectionLoadError = sectionLoadError ?? "\(error)"
            log.error("hyperkey reset aborted (settings left untouched): \(error, privacy: .public)")
        }
        services.refreshMenu()
        services.refreshSettings()
        paneModel.refresh()
    }

    // MARK: - Settings edits (from the pane; valid whether or not the tool is running)

    /// Whether the pane can persist edits at all. The config scope arrives at registration, so
    /// this stays true while Hyperkey is switched OFF — a write-blocked store or an unreadable
    /// section of our own turns it false.
    var canPersist: Bool { sectionLoadError == nil && (services?.config.canWrite ?? false) }

    /// Whether the STORE would accept a write — what the recovery reset needs, even though
    /// ordinary editing is off while the section is unreadable. Mirrors Cycler's `canReset`.
    var canResetSection: Bool { services?.config.canWrite ?? false }

    /// Why editing is off, if it is.
    var configBlockedMessage: String? {
        if sectionLoadError != nil {
            return "Your Hyperkey settings couldn’t be read. They were left untouched. Reset them "
                + "to start editing again; the unreadable file is kept next to your settings."
        }
        return services?.config.blockedMessage
    }

    /// The last failed save, consumed by the pane so it alerts exactly once.
    private var saveError: String?

    func takeSaveError() -> String? {
        defer { saveError = nil }
        return saveError
    }

    func setTrigger(_ trigger: TriggerKey) {
        guard settings.triggerKey != trigger else { return }
        let previous = settings
        settings.triggerKey = trigger
        guard persist(rollingBackTo: previous) else { return }
        apply()
        paneModel.refresh()
    }

    func setIncludeShift(_ includeShift: Bool) {
        guard settings.includeShift != includeShift else { return }
        let previous = settings
        settings.includeShift = includeShift
        guard persist(rollingBackTo: previous) else { return }
        apply()
        paneModel.refresh()
    }

    /// Persist an edit, or put `settings` back exactly as it was and record why.
    ///
    /// The rollback is what keeps the pane honest: `apply()` is skipped too, so a refused write
    /// never leaves the tap running on a trigger that isn't on disk.
    private func persist(rollingBackTo previous: HyperKeySettings) -> Bool {
        do {
            try save()
            saveError = nil
            return true
        } catch {
            settings = previous
            saveError = error.localizedDescription
            log.error("could not save hyperkey settings: \(error, privacy: .public)")
            paneModel.refresh()
            return false
        }
    }

    /// Restores only the service’s recorded Caps Lock ownership. Completion follows readback.
    func restoreCapsLock() {
        CapsLockHandoff.restoreCapsLock(using: services?.keyboardMappings ?? .shared) { [weak self] _ in
            guard let self else { return }
            self.refreshRecoveryState(force: true)
            // The mapping (and our claim on it) just went away, so this must not take the settled
            // fast path — a running Caps Lock trigger has to re-apply it.
            if self.isRunning { self.apply(force: true) }
            self.services?.refreshMenu()
            self.paneModel.refresh()
        }
    }

    func retry() {
        services?.keyboardMappings.retry()
        apply(force: true)
    }

    var statusText: String? { controller.settingsStatus }
    var needsInputMonitoring: Bool { controller.needsInputMonitoring }
    var permissions: PermissionCenter? { services?.permissions ?? PermissionCenter.shared }

    /// Updates recovery from the service’s ownership state, including failed cleanup attempts.
    func refreshRecoveryState(force: Bool = false) {
        // Do not publish recovery UI while the app is quitting.
        guard !isTerminating else { return }
        if !force, let last = lastOrphanProbe, Date().timeIntervalSince(last) < 5 { return }
        lastOrphanProbe = Date()
        CapsLockHandoff.orphanedMappingDetected(using: services?.keyboardMappings ?? .shared) { [weak self] orphaned in
            guard let self, self.orphanedMapping != orphaned else { return }
            self.orphanedMapping = orphaned
            self.services?.refreshMenu()
            self.services?.refreshSettings()
            self.paneModel.refresh()
        }
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
        if let sectionLoadError {
            out.append(ToolWarning(
                id: "hyperkey.config",
                text: "⚠︎ Hyperkey settings couldn’t be read",
                detailLines: [sectionLoadError, "Editing is disabled until you reset them."],
                actionTitle: "Reset Hyperkey settings…",
                action: { [weak self] in self?.resetSection() }))
        }
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
                detailLines: ["A keyboard map owned by Lineup or a previous Cycler install could not be released."],
                actionTitle: "Restore Caps Lock",
                action: { [weak self] in self?.restoreCapsLock() }))
        }
        return out
    }

    // MARK: - Settings pane

    /// No `paneModel.refresh()` here: this is called from inside a SwiftUI view update, and
    /// publishing from there is "Modifying state during view update". The pane refreshes itself
    /// in `onAppear`.
    func makeSettingsPane() -> AnyView {
        AnyView(HyperkeySettingsPane(model: paneModel))
    }
}

enum HyperkeyToolError: LocalizedError {
    /// No `ToolServices` yet, so there is no config section to write into.
    case notRegistered
    /// The store rejected the file on load and refuses every write until it is fixed.
    case writesBlocked(String?)
    /// OUR section is on disk but does not decode. Writing would destroy it.
    case sectionUnreadable

    var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Hyperkey isn’t ready yet. Try again in a moment."
        case .writesBlocked(let message):
            return message ?? "Your settings file couldn’t be read, so changes can’t be saved."
        case .sectionUnreadable:
            return "Your Hyperkey settings couldn’t be read. They were left untouched. Reset "
                + "them to start editing again."
        }
    }
}
