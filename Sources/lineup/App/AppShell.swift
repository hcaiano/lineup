import AppKit
import AppCore
import ApplicationServices
import os
import Sparkle

/// The one `NSApplicationDelegate`.
///
/// The shell owns everything that is NOT a tool: single-instance election, the status item,
/// Settings, Sparkle, permissions, launch at login, activation policy and termination. Tools own
/// their hotkeys, taps, monitors, timers and observers, and nothing else.
///
/// Phase 3 registers ZERO tools on purpose — the shell has to stand up by itself before Zones,
/// Cycler and Hyperkey are built against it in parallel.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: Product.logSubsystem, category: "shell")
    private let store = LineupAppConfigStore(url: Product.configURL)
    private lazy var registry = ToolRegistry(store: store)
    private lazy var statusItem = StatusItemController(registry: registry,
                                                       permissions: PermissionCenter.shared)
    private var settings: SettingsWindowController?
    private var welcome: WelcomeWindowController?

    /// Kept in the `com.caiano.lineup` domain and UNCHANGED from 1.x, so existing users are
    /// never re-onboarded.
    private static let didOnboardKey = "lineup.didOnboard"

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Offscreen UI preview: `LINEUP_RENDER_PREVIEW=<dir> swift run lineup` writes PNGs of the
        // Welcome + About content from the real view code, then exits. Debug-only; never ships.
        if let dir = ProcessInfo.processInfo.environment["LINEUP_RENDER_PREVIEW"] {
            Self.renderPreviews(to: dir)
            NSApp.terminate(nil)
            return
        }
        #endif

        // Two live instances fight over the same Carbon hotkeys. Deterministic election: the
        // older launch wins, lower pid breaks ties, so a same-wave double launch can never make
        // BOTH copies exit.
        if let incumbent = SingleInstance.incumbent() {
            log.warning("another \(Product.name, privacy: .public) instance is already running (pid \(incumbent.processIdentifier, privacy: .public)); exiting")
            NSApp.terminate(nil)
            return
        }

        ActivationCoordinator.shared.applyBaseline() // agent: no Dock icon (also LSUIElement)
        TerminationCoordinator.shared.installSignalHandlers()
        _ = AppUpdater.shared // start Sparkle's scheduled background update checks

        switch store.load() {
        case .loaded, .fresh:
            break
        case .failed(let state):
            log.error("config.json rejected (\(String(describing: state), privacy: .public)); running on defaults with writes blocked")
        }

        PermissionCenter.shared.onChange = { [weak self] in
            self?.statusItem.refresh()
            self?.settings?.refresh()
        }
        registry.onChange = { [weak self] in self?.statusItem.refresh() }
        registry.onSettingsChange = { [weak self] in self?.settings?.refresh() }

        statusItem.shellWarnings = { [weak self] in self?.shellWarnings() ?? [] }
        statusItem.showMenuBarIcon = { [weak self] in self?.store.config.general.showMenuBarIcon ?? true }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onShowAbout = { AboutWindowController.show() }

        // Tools are registered here in phases 4-6. Nothing yet, by design.
        registry.startEnabledTools()
        statusItem.refresh()

        // First launch only: explain who we are and why we need Accessibility BEFORE any OS
        // prompt (a menu-bar agent has no window, so an unexplained permission sheet is jarring
        // and easy to decline). Returning launches do NOT proactively prompt.
        if !UserDefaults.standard.bool(forKey: Self.didOnboardKey) {
            showWelcome()
        }
        PermissionCenter.shared.startAccessibilityWatch()

        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Warnings

    /// Shell-level problems. Tool problems come from each running tool's `warnings`.
    private func shellWarnings() -> [ToolWarning] {
        guard let message = store.blockedMessage else { return [] }
        return [ToolWarning(
            id: "shell.config",
            text: "⚠︎ Settings couldn’t be loaded",
            detailLines: [message],
            actionTitle: "Reset configuration…",
            action: { [weak self] in self?.resetConfig() })]
    }

    private func resetConfig() {
        do {
            try store.reset()
        } catch {
            // Preservation or the write failed: leave the file exactly as it was and keep writes
            // blocked, rather than clobber something the user might still recover by hand.
            log.error("reset aborted (config left untouched): \(error, privacy: .public)")
        }
        statusItem.refresh()
        settings?.refresh()
    }

    // MARK: - Settings

    private func openSettings() {
        if let settings {
            settings.show()
            return
        }
        let store = SettingsStore(
            registry: registry,
            permissions: PermissionCenter.shared,
            showMenuBarIcon: self.store.config.general.showMenuBarIcon,
            onMenuBarIconChange: { [weak self] show in self?.setShowMenuBarIcon(show) })
        let controller = SettingsWindowController(store: store)
        controller.onClose = { [weak self] in self?.settings = nil }
        settings = controller
        controller.show()
    }

    private func setShowMenuBarIcon(_ show: Bool) {
        do {
            try store.update { $0.general.showMenuBarIcon = show }
        } catch {
            log.error("could not persist showMenuBarIcon: \(error, privacy: .public)")
        }
        statusItem.refresh()
    }

    /// With the menu-bar icon hidden there is no way back in, so a Dock/Spotlight reopen has to
    /// land on Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !store.config.general.showMenuBarIcon else { return false }
        openSettings()
        return false
    }

    @objc private func applicationBecameActive() {
        // Returning from System Settings is the moment a new grant becomes visible to us.
        PermissionCenter.shared.recheck()
        if !store.config.general.showMenuBarIcon { openSettings() }
    }

    // MARK: - Welcome

    private func showWelcome() {
        let controller = WelcomeWindowController(
            onGrant: { PermissionCenter.shared.requestAccessibility() },
            onClose: { [weak self] in
                UserDefaults.standard.set(true, forKey: AppShell.didOnboardKey)
                ActivationCoordinator.shared.release("welcome")
                self?.welcome = nil
            })
        welcome = controller
        ActivationCoordinator.shared.retain("welcome")
        controller.show()
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        TerminationCoordinator.shared.runCleanups()
        registry.stopAll()
    }

    #if DEBUG
    /// Render the Welcome + About content views to PNGs for offscreen visual QA. Debug-only.
    private static func renderPreviews(to dir: String) {
        func write(_ view: NSView, _ size: NSSize, _ name: String) {
            view.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = view
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }
        write(WelcomeWindowController.makeEmbeddedContent(size: NSSize(width: 460, height: 388)),
              NSSize(width: 460, height: 388), "preview-welcome.png")
        write(AboutWindowController.makeEmbeddedContent(size: NSSize(width: 420, height: 430)),
              NSSize(width: 420, height: 430), "preview-about.png")
    }
    #endif
}
