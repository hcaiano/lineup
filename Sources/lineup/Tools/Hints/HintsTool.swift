import AppKit
import ApplicationServices
import AppCore
import HintsCore
import SwiftUI
import os

// ============================================================================
// Hints tool: the fourth `Tool`, wired exactly like Zones/Cycler/Hyperkey through
// `ToolID.hints`. The shell owns the registration, branding switches, and the
// shared-file assertions; the session controller is the single lifecycle owner.
//
// Contract summary (see the orchestration file for the session side):
//   * `attach` loads settings ONLY (the pane is usable while disabled; no resources).
//   * Default DISABLED. Accessibility is the ONLY required permission; the pane's button
//     opens System Settings without ever firing the one-shot system prompt.
//   * The runtime (controller + adapters) is created lazily on the first enable.
//   * Persisted state is ONLY the activation shortcut and the label alphabet. Mode,
//     search and scroll behavior is transient keyboard behavior — no new settings.
//   * Persisted combos are reported even while disabled (cross-tool conflict surface).
//   * Every edit saves FIRST and commits live state only on success, preserving unknown
//     top-level fields and nested shortcut members (the Codable model owns that).
//   * A hotkey conflict/Carbon failure becomes a warning with a MANUAL retry; there is
//     deliberately no retry timer and no automatic re-grab loop.
//   * A malformed Hints section blocks ALL of this tool's writes, hotkeys, and runtime;
//     the opaque section on disk is preserved and there is deliberately NO Hints-specific
//     reset path (store-level reset owns recovery, preserving the rejected bytes first).
//   * Termination cleanup releases the session runtime synchronously via the controller's
//     hard stop (`HintAXService.stopAndWait()` underneath).
// ============================================================================

@MainActor
final class HintsTool: Tool {
    let id = ToolID.hints
    let displayName = "Hints"
    let summary = "Type letters over on-screen controls to press them or scroll them."
    let iconSymbol = "keyboard"
    /// Reading another app's window tree and dispatching its advertised actions is all
    /// Accessibility. Hints never uses Input Monitoring: modal input lives in the
    /// Presentation lane's nonactivating panel, and the trigger is a Carbon hotkey.
    let requiredPermissions: Set<Permission> = [.accessibility]
    /// A silent auto-update must not start reading window trees or grabbing a combo.
    let defaultEnabled = false

    private(set) var isRunning = false

    /// Kept after `stop()` on purpose: the pane renders while the tool is off and must be
    /// able to read and write the `hints` config section.
    private var services: ToolServices?
    private(set) var settings = HintsSettings()
    /// Set when our own section is on disk but does NOT decode (wrong types, unsupported
    /// newer version). Envelope-level damage is the SHELL's warning; this one is
    /// specifically "your Hints settings are unreadable" and it blocks every write in this
    /// class — no edit, no hotkey registration, no runtime.
    private(set) var sectionLoadErrorMessage: String?

    /// The one activation shortcut's failed registration, if any. Manual retry only.
    private struct FailedShortcut: Equatable {
        var keyCode: Int
        var modifiers: UInt32
        var reason: HotkeyFailure
    }
    private var failedShortcut: FailedShortcut?

    /// Created lazily on start; never touched while the tool is off (and never handed a
    /// hidden permission prompt, an app registration, or an eager singleton).
    private(set) var controller: HintSessionController?
    private var isTerminating = false

    private var log: Logger { services?.log ?? Logger(subsystem: Product.logSubsystem, category: "hints") }

    // MARK: - Lifecycle

    /// Registration, not start: take the config scope and read the section so the pane is
    /// fully usable — and persistable — while Hints is off. Acquires nothing.
    func attach(_ services: ToolServices) {
        self.services = services
        loadSettings()
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        isTerminating = false
        loadSettings()
        log.info("enabled (runtime stays lazy until first activation)")

        // Malformed section: NO lifecycle resources are acquired at all — no termination
        // cleanup entry, no runtime, no hotkey, and every write stays blocked. The warning
        // (plus the store-level reset recovery) handles it; the section is untouched.
        guard sectionLoadErrorMessage == nil else {
            services.refreshMenu()
            services.refreshSettings()
            return
        }

        // `stop()`/signals must drain the AX lane synchronously, exactly like Zones/Cycler.
        services.termination.addCleanup(ToolID.hints) { [weak self] in
            MainActor.assumeIsolated { self?.performTerminationCleanup() }
        }

        isRunning = true
        registerActivationShortcut()
        services.refreshMenu()
        services.refreshSettings()
    }

    /// Releases everything `start()` took. Idempotent, and safe when the tool never ran.
    /// Ordering: non-activatable FIRST, hotkeys gone SECOND, AX drain LAST — so no hotkey
    /// callback can enter the runtime while the drain is running.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        // The user turned it off; quitting must not persist that, so the flag mirrors
        // Hyperkey's discipline (the cleanup block sets `isTerminating` first).
        services?.hotkeys.unregisterAll()
        if !isTerminating { controller?.hardStop() }
        controller = nil
        services?.termination.removeCleanup(ToolID.hints)
        failedShortcut = nil
        services?.refreshMenu()
        services?.refreshSettings()
    }

    /// Termination ordering (signal or applicationWillTerminate): make the tool
    /// non-activatable, unregister so no Carbon callback races the drain, THEN hard-stop
    /// the controller synchronously (`HintAXService.stopAndWait()` underneath). Never
    /// writes settings on the way out. Idempotent.
    private func performTerminationCleanup() {
        guard !isTerminating else { return }
        isTerminating = true
        isRunning = false
        services?.hotkeys.unregisterAll()
        controller?.hardStop()
        controller = nil
    }

    // MARK: - Config

    private func loadSettings() {
        guard let services else { return }
        do {
            settings = try services.config.load(HintsSettings.self) ?? HintsSettings()
            sectionLoadErrorMessage = nil
        } catch {
            // Keep defaults in memory and say so; the section on disk is left EXACTLY as
            // it is, and every write path checks this flag first.
            log.error("hints settings could not be decoded (left untouched): \(error, privacy: .public)")
            settings = HintsSettings()
            sectionLoadErrorMessage = "\(error)"
        }
    }

    /// Whether the pane may edit: the store must accept writes AND our section must have
    /// decoded. An unreadable section leaves `settings` as the EMPTY/DEFAULT value, and
    /// the first edit would save that default straight over the user's blob — so editing
    /// stays off until the store-level reset recovers the section.
    var canEditSettings: Bool {
        sectionLoadErrorMessage == nil && (services?.config.canWrite ?? false)
    }

    /// Why the STORE refuses writes, if it does (kept separate so blocked vs. unreadable
    /// states can be shown distinctly).
    var storeBlockedMessage: String? { services?.config.blockedMessage }

    /// Live trust state for the setup row; true even while the tool is disabled — the pane
    /// shows setup state before enabling, and computing it costs one `AXIsProcessTrusted()`.
    var isAccessibilityTrusted: Bool {
        services?.permissions.isAccessibilityTrusted ?? PermissionCenter.shared.isAccessibilityTrusted
    }

    // MARK: - Frozen settings API (Settings pane owns the capture/validation UX)

    /// The SETTINGS-facing snapshot of persisted Hints settings (shortcut + alphabet).
    var settingsSnapshot: HintsSettings { settings }

    /// Every combo any OTHER tool has bound, for the pane's cross-tool conflict check.
    /// May decode sibling sections; the pane snapshots it once per capture.
    func boundCombos() -> [ToolCombo] { services?.boundCombos() ?? [] }

    /// Opens System Settings' Accessibility pane WITHOUT firing the one-shot system
    /// prompt (macOS will not re-prompt anyway; Hints' only recovery is the user flipping
    /// the toggle). No prompt is ever requested from this tool.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Persist a new activation shortcut, or clear it. The only persisted settings are the
    /// shortcut and the alphabet; everything else is transient keyboard behavior.
    ///
    /// Save FIRST: a failed save throws with no live change (fresh defaults/rollback-free —
    /// `settings` only advances after the store accepted the write). Clearing keeps any
    /// nested unknown members the previous unassigned carrier held (the model's encode
    /// rules handle the exact JSON shape), preserving a newer schema's data.
    ///
    /// - Returns the settings as persisted, for the pane to commit atomically.
    @discardableResult
    func updateActivationShortcut(_ shortcut: HintShortcut?) throws -> HintsSettings {
        guard let services else { throw HintsToolError.notReady }
        guard sectionLoadErrorMessage == nil else { throw HintsToolError.sectionUnreadable }
        guard services.config.canWrite else {
            throw HintsToolError.writesBlocked(services.config.blockedMessage)
        }
        var updated = settings
        if let shortcut {
            // Assignment requires a valid key code AND nonzero modifiers (the model's
            // whole-shortcut predicate); anything else never reserves a global combo.
            guard shortcut.normalizedLeniently() != nil else { throw HintsToolError.invalidShortcut }
            // Re-recording a shortcut must not drop the previous carrier's unknown
            // members (a newer schema's data): merge them into the incoming carrier with
            // INCOMING values winning. Done here, on every assignment, without touching
            // the frozen Core model.
            var incoming = shortcut
            if let previous = updated.activationShortcut, !previous.extra.isEmpty {
                var merged = previous.extra
                for (key, value) in incoming.extra { merged[key] = value }
                incoming.extra = merged
            }
            updated.assignShortcut(incoming)
        } else if let previous = updated.activationShortcut, previous.isAssigned {
            // Clearing an assignment: keep nested unknown members as unknown-only data so
            // they re-emerge on the next decode without reviving an invalid carrier.
            var emptied = HintShortcut(keyCode: HintShortcut.unassignedKeyCode, modifiers: 0)
            emptied.extra = previous.extra
            updated.activationShortcut = emptied
        }
        try services.config.save(updated)
        settings = updated
        reapplyRuntime()
        services.refreshMenu()
        services.refreshSettings()
        return updated
    }

    /// Persist a new label alphabet. Invalid input throws (the pane validates with the
    /// same `HintLabelMaker` predicate first, so this is defense in depth, never the UX).
    @discardableResult
    func updateAlphabet(_ alphabet: String) throws -> HintsSettings {
        guard let services else { throw HintsToolError.notReady }
        guard sectionLoadErrorMessage == nil else { throw HintsToolError.sectionUnreadable }
        guard services.config.canWrite else {
            throw HintsToolError.writesBlocked(services.config.blockedMessage)
        }
        do {
            _ = try HintLabelMaker(alphabet: alphabet)
        } catch {
            throw HintsToolError.invalidAlphabet
        }
        var updated = settings
        updated.alphabet = HintsSettings.validatedAlphabet(alphabet)
        try services.config.save(updated)
        settings = updated
        reapplyRuntime()
        services.refreshMenu()
        services.refreshSettings()
        return updated
    }

    // MARK: - Runtime reapply

    /// Rebuilds the tool's live state after an accepted settings change: re-registers the
    /// accepted shortcut, and keeps any provisioned runtime honest (alphabet or modifier
    /// changes invalidate a live session — transient keyboard behavior is not preserved).
    private func reapplyRuntime() {
        guard isRunning, let services, sectionLoadErrorMessage == nil else { return }
        services.hotkeys.unregisterAll()
        failedShortcut = nil
        registerActivationShortcut()
        if let shortcut = assignedShortcut(), let controller {
            controller.reconfigure(alphabet: settings.alphabet, activationModifierMask: shortcut.modifiers)
        } else if controller != nil, assignedShortcut() == nil {
            // No assigned shortcut: nothing may capture, ever.
            controller?.hardStop()
            controller = nil
        }
    }

    /// The effective assigned shortcut after lenient normalization; the unassigned carrier
    /// never registers and never appears as persisted.
    private func assignedShortcut() -> HintShortcut? {
        settings.activationShortcut?.normalizedLeniently()
    }

    /// The PERSISTED, known-good activation shortcut, read from `settings` (the accepted
    /// on-decode state) rather than the live Carbon registry — the same answer whether the
    /// tool is running or disabled, so a sibling's recorder can never claim our combo.
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] {
        guard let shortcut = assignedShortcut() else { return [] }
        return [(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)]
    }

    // MARK: - Hotkeys (assignment-driven; manual retry ONLY, no timer)

    private func registerActivationShortcut() {
        guard isRunning, let services, let shortcut = assignedShortcut() else { return }
        let result = services.hotkeys.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.activateSession()
        }
        if case .failure(let reason) = result {
            let failure = FailedShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, reason: reason)
            failedShortcut = failure
            logHotkeyFailure(failure)
        } else {
            failedShortcut = nil
        }
    }

    /// Menu-warning action: the manual retry. A Settings recorder holding the registry
    /// suspended is waited out here too (rows would register without installing), but
    /// there is NO timer and NO automatic loop — the user retries, or the warning persists.
    func retryActivationShortcut() {
        guard isRunning, let services else { return }
        guard !services.hotkeys.isSuspended else { return }
        failedShortcut = nil
        services.hotkeys.unregisterAll()
        registerActivationShortcut()
        services.refreshMenu()
    }

    /// The shell reports these after a Settings recording; recording a dead row into the
    /// same failed list keeps the "Retry shortcut" warning honest without a timer. The
    /// failure is built from OUR MATCHED ROW's status — never `failures[0]`, which may be
    /// some other tool's row.
    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {
        guard isRunning, let shortcut = assignedShortcut() else { return }
        guard let matched = failures.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers })
        else { return }
        let failure = FailedShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, reason: .carbon(matched.status))
        failedShortcut = failure
        logHotkeyFailure(failure)
        services?.refreshMenu()
    }

    private func logHotkeyFailure(_ failure: FailedShortcut) {
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        log.error("activation shortcut registration failed (\(failure.reason.displayReason, privacy: .public)) for \(combo, privacy: .public)")
    }

    /// The controller (and the adapters beneath it) exist only from the first activation
    /// onward — no eager singleton, no observers, no permission prompt before that.
    private func ensureController() -> HintSessionController? {
        guard let shortcut = assignedShortcut() else { return nil }
        if let controller {
            if controller.deps.alphabet != settings.alphabet
                || controller.deps.activationModifierMask != shortcut.modifiers {
                controller.reconfigure(alphabet: settings.alphabet, activationModifierMask: shortcut.modifiers)
            }
            return controller
        }
        let newController = HintSessionController(deps: .live(
            limits: .standard,
            alphabet: settings.alphabet,
            activationModifierMask: shortcut.modifiers,
            accessibility: { [weak self] in
                self?.isAccessibilityTrusted ?? AXIsProcessTrusted()
            }
        ))
        newController.onPhaseChange = { [weak self] in
            self?.services?.refreshMenu()
        }
        controller = newController
        return newController
    }

    /// Hotkey entry into the runtime. Returns quickly: the controller snapshots the target
    /// and schedules everything else asynchronously.
    private func activateSession() {
        guard isRunning, let controller = ensureController() else { return }
        controller.activate()
    }

    // MARK: - Menu

    /// Minimal setup status for the running tool. Disabled discovery is shell-owned and opens
    /// Settings, where the pane header remains the sole enable-switch owner.
    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        guard isRunning, sectionLoadErrorMessage == nil else { return items }
        if let shortcut = assignedShortcut() {
            let combo = ShortcutKit.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
            if controller?.isSessionActive == true {
                items.append(ToolMenu.info("Hints active: press Esc to cancel"))
            } else {
                items.append(ToolMenu.info("Press \(combo) to show hints"))
            }
        } else {
            items.append(ToolMenu.info("No activation shortcut: set one in Hints settings"))
        }
        return items
    }

    var warnings: [ToolWarning] {
        var result: [ToolWarning] = []
        if let sectionLoadErrorMessage {
            // Deliberately NO reset action: Hints has no self-reset. The store-level reset
            // is the recovery owner and preserves the rejected bytes first.
            result.append(ToolWarning(
                id: "hints.settings",
                text: "⚠︎ Hints settings couldn’t be read",
                detailLines: [sectionLoadErrorMessage, "Editing and Hotkeys are off; the unreadable section is preserved."]))
        }
        if isRunning, !isAccessibilityTrusted {
            result.append(ToolWarning(
                id: "hints.accessibility",
                text: "⚠︎ Hints needs Accessibility access",
                actionTitle: "Open Accessibility Settings…",
                action: { [weak self] in self?.openAccessibilitySettings() }))
        }
        if let failure = failedShortcut {
            result.append(ToolWarning(
                id: "hints.shortcut",
                text: "⚠︎ Hints activation shortcut blocked",
                detailLines: ["\(ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)): \(failure.reason.displayReason)", "Another app or tool owns the combination."],
                actionTitle: "Retry shortcut",
                action: { [weak self] in self?.retryActivationShortcut() }))
        }
        return result
    }

    // MARK: - Settings pane

    func makeSettingsPane() -> AnyView {
        AnyView(HintsSettingsPane(tool: self))
    }
}

/// Localized failures for the Settings-facing update paths. The pane alerts with
/// `localizedDescription`; every message stays actionable and copy-reviewable.
enum HintsToolError: LocalizedError {
    /// No `ToolServices` yet (registration hasn't happened).
    case notReady
    /// The STORE rejected the file and refuses every write until it is fixed.
    case writesBlocked(String?)
    /// OUR section is on disk but does not decode; writing would destroy preserved data.
    /// Recovery is deliberately store-level (preserving the rejected bytes), not Hints'.
    case sectionUnreadable
    /// The shortcut fails the whole-assignment predicate (in-range key + modifiers) —
    /// a bare modifierless combination is never accepted.
    case invalidShortcut
    /// The alphabet fails the `HintLabelMaker` predicate (empty, non-ASCII letters, or
    /// case-insensitive duplicates).
    case invalidAlphabet

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Hints isn’t ready yet. Try again in a moment."
        case .writesBlocked(let message):
            return message ?? "Your settings file couldn’t be read, so changes can’t be saved."
        case .sectionUnreadable:
            return "Your Hints settings couldn’t be read. They were left untouched. Recovery "
                + "happens through the store’s reset, which keeps a copy of the unreadable data."
        case .invalidShortcut:
            return "Choose a key together with at least one modifier."
        case .invalidAlphabet:
            return "Use one or more unique letters A through Z."
        }
    }
}
