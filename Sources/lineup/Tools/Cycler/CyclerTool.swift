import AppKit
import AppCore
import Carbon.HIToolbox
import CyclerCore
import SwiftUI
import os

/// The Cycler tool: press a per-app hotkey to jump to that app, press it again to walk its
/// windows; a multi-app binding cycles between apps instead.
///
/// Ported from standalone Cycler's `AppDelegate`, minus everything the shell now owns (status
/// item, Sparkle, launch at login, Accessibility watch, About, activation policy, quit) and minus
/// every hyper-key member — Hyperkey is its own tool in 2.0 (plan §2.2). Cycler bindings store raw
/// Carbon modifier masks, so they fire whether ⌃⌥⇧⌘ comes from Lineup's Hyperkey tool, Karabiner,
/// Raycast, or four physically-held modifiers. There is deliberately no reference to Hyperkey here.
@MainActor
final class CyclerTool: Tool {
    let id = ToolID.cycler
    let displayName = "Cycler"
    let summary = "Jump to an app with one shortcut, press again to cycle its windows."
    let iconSymbol = "arrow.triangle.2.circlepath"
    /// Reading another app's window list and focusing a window is all Accessibility. Cycler never
    /// needs Input Monitoring — it uses Carbon hotkeys, not an event tap.
    let requiredPermissions: Set<Permission> = [.accessibility]
    /// Off by default: a silent 2.0 auto-update must not start grabbing an existing user's keys.
    let defaultEnabled = false

    private(set) var isRunning = false

    /// Kept after `stop()` on purpose: the Settings pane is rendered even while the tool is off,
    /// and it still has to be able to read and write the `cycler` config section.
    private var services: ToolServices?
    private(set) var settings = CyclerToolSettings()
    /// Set when our own section is on disk but undecodable. Envelope-level damage is the shell's
    /// warning to show; this one is specifically "your bindings are unreadable".
    private(set) var sectionLoadError: String?

    private var failedHotkeys: [FailedHotkey] = []
    private var failedHotkeyRetryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private lazy var settingsModel = CyclerSettingsModel(tool: self)

    private var log: Logger { services?.log ?? Logger(subsystem: Product.logSubsystem, category: "cycler") }

    // MARK: - Lifecycle

    /// Registration, not start: take the config scope and read the bindings, so the pane is fully
    /// usable — and persistable — while Cycler is off. Acquires no hotkeys and no observers.
    func attach(_ services: ToolServices) {
        self.services = services
        loadSettings()
        settingsModel.reload()
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        isRunning = true
        loadSettings()
        registerHotkeys()
        // Another app can hold a combo we want (a login item that started first, a full-screen
        // game). Coming back to Lineup is the cheapest moment to try again — plus the 10s timer.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryFailedHotkeys() }
            })
        settingsModel.reload()
    }

    /// Releases everything `start()` took. Idempotent, and safe when the tool never ran.
    func stop() {
        services?.hotkeys.unregisterAll()
        failedHotkeys.removeAll()
        failedHotkeyRetryTimer?.invalidate()
        failedHotkeyRetryTimer = nil
        CycleHUD.shared.dismiss()      // no floating panel may outlive the tool
        AppActivator.shared.reset()    // drop the remembered per-app window positions
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        isRunning = false
    }

    // MARK: - Config

    private func loadSettings() {
        guard let services else { return }
        do {
            let loaded = try services.config.load(CyclerToolSettings.self) ?? CyclerToolSettings()
            settings = loaded.coalescingDuplicateShortcuts()
            sectionLoadError = nil
        } catch {
            // Keep an empty binding set and say so; the section on disk is left exactly as it is,
            // so a hand-edit mistake stays recoverable.
            log.error("cycler settings could not be decoded (left untouched): \(error, privacy: .public)")
            settings = CyclerToolSettings()
            sectionLoadError = "\(error)"
        }
    }

    /// Whether the pane can persist edits at all. The config scope arrives at registration, so this
    /// stays true while Cycler is switched OFF — only a write-blocked store turns it false.
    var canPersist: Bool { services?.config.canWrite ?? false }

    var configBlockedMessage: String? { services?.config.blockedMessage }

    /// Persist a new binding set and re-register. Write-then-assign, so a failed save leaves the
    /// live state exactly as the user last saw it working.
    func save(_ newSettings: CyclerToolSettings) throws {
        guard let services else { throw CyclerToolError.notStarted }
        let coalesced = newSettings.coalescingDuplicateShortcuts()
        try services.config.save(coalesced)
        settings = coalesced
        sectionLoadError = nil
        reloadHotkeys()
        services.refreshMenu()
    }

    /// Menu action: re-read the section from the store and rebuild every registration.
    private func reloadBindings() {
        loadSettings()
        reloadHotkeys()
        settingsModel.reload()
        services?.refreshMenu()
        services?.refreshSettings()
    }

    // MARK: - Hotkeys

    private struct HotkeyCombo: Hashable {
        var keyCode: Int
        var modifiers: UInt32
    }

    private struct FailedHotkey {
        var label: String
        var keyCode: Int
        var modifiers: UInt32
        var reason: HotkeyFailure
        var generatedReverse: Bool
    }

    /// Every binding gets its combo, plus a Shift-added reverse combo that cycles backwards.
    ///
    /// The reverse pass is verbatim from standalone Cycler, including the two rules that make it
    /// predictable: a binding that already includes Shift gets no generated reverse (there is no
    /// second Shift to add), and a generated reverse is skipped when some other binding already
    /// claims that exact combo explicitly — the explicit binding wins, and the pane warns about it.
    private func registerHotkeys() {
        guard isRunning, let services else { return }

        var failed: [FailedHotkey] = []
        let explicitCombos = Set(settings.bindings.map { HotkeyCombo(keyCode: $0.keyCode, modifiers: $0.modifiers) })
        for b in settings.bindings {
            let binding = b
            let result = services.hotkeys.register(keyCode: b.keyCode, modifiers: b.modifiers) { [weak self] in
                self?.engage(binding, direction: .forward)
            }
            if case .failure(let reason) = result {
                failed.append(FailedHotkey(
                    label: bindingTitle(for: b.bundleIdentifiers),
                    keyCode: b.keyCode,
                    modifiers: b.modifiers,
                    reason: reason,
                    generatedReverse: false))
            }
        }
        for b in settings.bindings {
            guard b.modifiers & UInt32(shiftKey) == 0 else { continue }
            let backwardModifiers = b.modifiers | UInt32(shiftKey)
            let combo = HotkeyCombo(keyCode: b.keyCode, modifiers: backwardModifiers)
            guard !explicitCombos.contains(combo) else { continue }

            let binding = b
            let result = services.hotkeys.register(keyCode: b.keyCode, modifiers: backwardModifiers) { [weak self] in
                self?.engage(binding, direction: .backward)
            }
            if case .failure(let reason) = result {
                failed.append(FailedHotkey(
                    label: bindingTitle(for: b.bundleIdentifiers),
                    keyCode: b.keyCode,
                    modifiers: backwardModifiers,
                    reason: reason,
                    generatedReverse: true))
            }
        }
        failedHotkeys = failed
        for failure in failedHotkeys { logHotkeyFailure(failure) }
        updateFailedHotkeyRetryTimer()
    }

    /// Cross-tool conflict source (§5.6): every combo `registerHotkeys()` would install, whether
    /// or not Cycler is running — the explicit bindings AND the ⇧ reverses generated from them.
    ///
    /// The reverses matter: leaving them out would let Zones' recorder take ⌃⌥⇧⌘T while Cycler is
    /// off, and Cycler's backwards-cycle for ⌃⌥⌘T would then fail to register at the next enable.
    /// Read back through the config scope so a disabled tool answers from what is persisted.
    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] {
        var bindings = settings.bindings
        if let services, let stored = try? services.config.load(CyclerToolSettings.self) {
            bindings = stored.coalescingDuplicateShortcuts().bindings
        }
        var out: [(keyCode: Int, modifiers: UInt32)] = []
        var seen = Set<HotkeyCombo>()
        for b in bindings where seen.insert(HotkeyCombo(keyCode: b.keyCode, modifiers: b.modifiers)).inserted {
            out.append((b.keyCode, b.modifiers))
        }
        for b in bindings where b.modifiers & UInt32(shiftKey) == 0 {
            let reverse = HotkeyCombo(keyCode: b.keyCode, modifiers: b.modifiers | UInt32(shiftKey))
            if seen.insert(reverse).inserted { out.append((reverse.keyCode, reverse.modifiers)) }
        }
        return out
    }

    /// Every combo any OTHER tool has bound, for the pane's cross-tool conflict check.
    func boundCombos() -> [ToolCombo] { services?.boundCombos() ?? [] }

    private func reloadHotkeys() {
        guard isRunning, let services else { return }
        services.hotkeys.unregisterAll()
        registerHotkeys()
    }

    private func engage(_ binding: AppBinding, direction: WindowCycle.Direction) {
        if binding.isGroup {
            AppActivator.shared.engageGroup(bundleIdentifiers: binding.bundleIdentifiers, direction: direction)
        } else {
            AppActivator.shared.engage(bundleIdentifier: binding.bundleIdentifier, direction: direction)
        }
    }

    private func retryHotkeys() {
        reloadHotkeys()
        services?.refreshMenu()
    }

    private func updateFailedHotkeyRetryTimer() {
        guard !failedHotkeys.isEmpty, isRunning else {
            failedHotkeyRetryTimer?.invalidate()
            failedHotkeyRetryTimer = nil
            return
        }
        guard failedHotkeyRetryTimer == nil else { return }
        failedHotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryFailedHotkeys() } // Timer fires on the main run loop
        }
    }

    private func retryFailedHotkeys() {
        // While a Settings recorder holds the registry suspended, register() records rows without
        // installing them, so every retry would "succeed" and hide a real conflict. Wait it out;
        // SettingsStore reports whatever fails to come back when the capture ends.
        guard !failedHotkeys.isEmpty, isRunning, !(services?.hotkeys.isSuspended ?? false) else {
            updateFailedHotkeyRetryTimer()
            return
        }
        reloadHotkeys()
        services?.refreshMenu()
    }

    private func logHotkeyFailure(_ failure: FailedHotkey) {
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        let direction = failure.generatedReverse ? " reverse" : ""
        log.error("hotkey registration failed (\(failure.reason.displayReason, privacy: .public)) for\(direction, privacy: .public) \(failure.label, privacy: .public) \(combo, privacy: .public) key \(failure.keyCode, privacy: .public)")
    }

    // MARK: - Menu

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if settings.bindings.isEmpty {
            items.append(ToolMenu.info("No shortcuts yet"))
        }
        items.append(ToolMenu.item("Reload bindings", symbol: "arrow.clockwise") { [weak self] in
            self?.reloadBindings()
        })
        return items
    }

    var warnings: [ToolWarning] {
        var result: [ToolWarning] = []
        if let sectionLoadError {
            result.append(ToolWarning(
                id: "cycler.settings",
                text: "⚠︎ Cycler shortcuts couldn’t be loaded",
                detailLines: [sectionLoadError]))
        }
        if !failedHotkeys.isEmpty {
            // Cap the detail at 4 rows: a menu that lists 30 blocked combos is unreadable and
            // pushes everything else off screen.
            var lines = failedHotkeys.prefix(4).map(blockedHotkeyTitle)
            if failedHotkeys.count > 4 {
                lines.append("…and \(failedHotkeys.count - 4) more")
            }
            result.append(ToolWarning(
                id: "cycler.hotkeys",
                text: "⚠︎ \(failedHotkeys.count) Cycler shortcut\(failedHotkeys.count == 1 ? "" : "s") blocked",
                detailLines: lines,
                actionTitle: "Retry shortcuts",
                action: { [weak self] in self?.retryHotkeys() }))
        }
        return result
    }

    private func blockedHotkeyTitle(_ failure: FailedHotkey) -> String {
        let prefix = failure.generatedReverse ? "Reverse " : ""
        let combo = ShortcutKit.display(keyCode: failure.keyCode, modifiers: failure.modifiers)
        return "\(prefix)\(failure.label) \(combo) — \(failure.reason.displayReason)"
    }

    // MARK: - Settings

    func makeSettingsPane() -> AnyView {
        // The recorder needs the window's `SettingsStore` (the sole owner of the global hotkey
        // suspension). It arrives through the environment — `SettingsStore.pane(for:)` injects it.
        AnyView(CyclerSettingsPane(model: settingsModel))
    }

    // MARK: - Labels

    private func appName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }

    private func bindingTitle(for bundleIdentifiers: [String]) -> String {
        let names = bundleIdentifiers.map(appName)
        switch names.count {
        case 0:
            return "Empty group"
        case 1:
            return names[0]
        case 2, 3:
            return names.joined(separator: " + ")
        default:
            return "\(names[0]) + \(names[1]) + \(names.count - 2) more"
        }
    }
}

enum CyclerToolError: LocalizedError {
    case notStarted

    var errorDescription: String? {
        switch self {
        case .notStarted: return "Turn Cycler on before changing its shortcuts."
        }
    }
}
