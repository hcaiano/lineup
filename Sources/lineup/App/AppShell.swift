import AppKit
import AppCore
import ApplicationServices
import os
import Sparkle
import ZonesCore

/// The one `NSApplicationDelegate`.
///
/// The shell owns everything that is NOT a tool: single-instance election, the status item,
/// Settings, Sparkle, permissions, launch at login, activation policy and termination. Tools own
/// their hotkeys, taps, monitors, timers and observers, and nothing else.
///
/// The shell registers the four tools (Zones, Cycler, Hyperkey, Hints) in the fixed menu order;
/// each tool brings only its own runtime, never a second config, hotkey, permission, updater or
/// activation owner.
@MainActor
final class AppShell: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: Product.logSubsystem, category: "shell")
    private let store = LineupAppConfigStore(url: Product.configURL)
    private lazy var registry = ToolRegistry(store: store)
    private lazy var statusItem = StatusItemController(registry: registry,
                                                       permissions: PermissionCenter.shared)
    private var settings: SettingsWindowController?
    private var welcome: WelcomeWindowController?
    private var whatsNew: WhatsNewWindowController?

    /// What the last `LegacyImport.run` reported. Kept because two of its outcomes outlive the
    /// call: a deferred Zones import becomes a shell warning and a retry, and a Cycler import
    /// becomes a line in the onboarding window.
    private var importReport = LegacyImport.Report()
    /// Retries a DEFERRED Zones import when the display its layout was drawn on comes back.
    private var deferredImportObserver: NSObjectProtocol?
    /// This machine also ran Lineup 1.x. Decided once at launch, from disk + UserDefaults.
    private var hasLineupHistory = false

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

        // Which audience this launch belongs to is decided from the state on disk BEFORE the
        // import writes anything — the import itself creates config.json, which would otherwise
        // make every first launch look like a returning one.
        let outcome = store.load()
        var hasConfig = true
        switch outcome {
        case .loaded:
            break
        case .fresh:
            hasConfig = false
        case .failed(let state):
            log.error("config.json rejected (\(String(describing: state), privacy: .public)); running on defaults with writes blocked")
        }
        let hasLegacyZones = FileManager.default.fileExists(atPath: Product.legacyZonesURL.path)
        let audience = Onboarding.audience(
            hasConfig: hasConfig,
            hasLegacyZones: hasLegacyZones,
            didOnboard: UserDefaults.standard.bool(forKey: Self.didOnboardKey))
        // Traces of Lineup 1.x on this machine, independent of the audience (which becomes
        // `.returning` once config.json exists). Only used to decide whether standalone Cycler's
        // hidden-menu-bar-icon preference may be adopted.
        hasLineupHistory = hasLegacyZones
            || UserDefaults.standard.bool(forKey: Self.didOnboardKey)

        // BEFORE the tools start: a tool that started first would read an empty section, run on
        // defaults, and then have to be told to reload. Seeding the envelope first means Zones
        // simply finds the imported layout where it expects it.
        runLegacyImport()

        PermissionCenter.shared.onChange = { [weak self] in
            self?.statusItem.refresh()
            self?.settings?.refresh()
        }
        registry.onChange = { [weak self] in self?.statusItem.refresh() }
        registry.onSettingsChange = { [weak self] in self?.settings?.refresh() }

        statusItem.shellWarnings = { [weak self] in self?.shellWarnings() ?? [] }
        statusItem.showMenuBarIcon = { [weak self] in self?.store.config.general.showMenuBarIcon ?? true }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenToolSettings = { [weak self] toolID in self?.openSettings(tool: toolID) }
        statusItem.onShowAbout = { AboutWindowController.show() }

        // Registered in the fixed menu/sidebar order: Zones, Cycler, Hyperkey, Hints.
        registry.register(ZonesTool())
        registry.register(CyclerTool())
        registry.register(HyperkeyTool())
        registry.register(HintsTool())
        registry.startEnabledTools()
        statusItem.refresh()

        // The three audiences (plan §3 Phase 8), in the order they exclude each other:
        //
        //  * brand-new  -> Welcome. The ONLY path that proactively asks for a permission, and it
        //                  asks for Accessibility only — never Input Monitoring.
        //  * 1.x upgrade -> What's New, once. No prompt of any kind: their Accessibility grant,
        //                  login item and shortcuts all survived the update untouched.
        //  * returning  -> nothing.
        let didOnboard = UserDefaults.standard.bool(forKey: Self.didOnboardKey)
        let showingWelcome = Onboarding.shouldShowWelcome(audience: audience, didOnboard: didOnboard)
        if showingWelcome {
            showWelcome()
        } else if Onboarding.shouldShowWhatsNew(audience: audience,
                                                didShowWhatsNew2: store.config.general.didShowWhatsNew2,
                                                showingWelcome: showingWelcome,
                                                canPersist: store.canWrite) {
            showWhatsNew()
        }
        PermissionCenter.shared.startAccessibilityWatch()

        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Legacy import

    /// Seed `config.json` from `~/.config/lineup/zones.json` and `~/.config/cycler/bindings.json`.
    ///
    /// Both sources are READ-ONLY here and forever: `zones.json` in particular is the rollback
    /// safety net for anyone who downgrades to 1.x. `LegacyImport` is idempotent per source, so
    /// this can be called again — and is, when a deferred Zones layout's display reconnects.
    private func runLegacyImport() {
        // A rejected envelope blocks writes; importing into it would throw on every save and
        // could only make the situation harder to recover from by hand.
        guard store.canWrite else { return }
        let general = store.config.general
        guard !(general.didImportLegacyZones && general.didImportLegacyCycler) else { return }

        var report = LegacyImport.Report()
        do {
            try store.update { config in
                report = LegacyImport.run(
                    into: &config,
                    zonesURL: Product.legacyZonesURL,
                    cyclerBindingsURL: Product.legacyCyclerBindingsURL,
                    now: ISO8601DateFormatter().string(from: Date()),
                    // A 1.x user keeps their menu-bar icon whatever standalone Cycler's own
                    // icon preference was — it is the suite's only icon now.
                    hasLineupHistory: hasLineupHistory,
                    resolveLegacyScreen: Self.resolveLegacyScreen)
            }
        } catch {
            log.error("legacy import could not be saved (legacy files untouched): \(error, privacy: .public)")
            return
        }
        if let zonesError = report.zonesError {
            log.error("legacy zones.json not imported (left untouched): \(zonesError, privacy: .public)")
        }
        if let cyclerError = report.cyclerError {
            log.error("legacy cycler bindings.json not imported (left untouched): \(cyclerError, privacy: .public)")
        }
        // Accumulate: a retry that finally lands the Zones layout must not erase the Cycler
        // counts the first pass reported.
        if report.importedZones { importReport.importedZones = true }
        if report.importedCycler {
            importReport.importedCycler = true
            importReport.importedBindingCount = report.importedBindingCount
            importReport.importedHyperkey = report.importedHyperkey
            importReport.hyperkeyWasEnabled = report.hyperkeyWasEnabled
        }
        importReport.zonesDeferred = report.zonesDeferred
        if report.zonesDeferred { watchForDeferredDisplay() }
    }

    /// The pre-schema-3 `ColumnConfig` migration needs to know which display the seams were drawn
    /// on. Same rule 1.x used: match the inferred legacy pixel width, else the widest screen; a
    /// legacy width that matches nothing means the display is absent, so the import DEFERS.
    private static func resolveLegacyScreen(_ old: ColumnConfig) -> ScreenInfo? {
        let screens = NSScreen.screens.map { ScreenIdentity.info(for: $0) }
        if let width = LineupConfig.inferredLegacyWidth(old) {
            return screens.filter { abs($0.pixelsWide - width) <= 8 }
                .max(by: { $0.pixelsWide < $1.pixelsWide })
        }
        return screens.max(by: { $0.pixelsWide < $1.pixelsWide })
    }

    /// Registered only while an import is deferred, and torn down the moment it lands — this is
    /// installed BEFORE any tool starts, so the shell's retry runs before `ZonesTool`'s own
    /// screen-change handler and the tool is restarted onto the freshly imported section.
    private func watchForDeferredDisplay() {
        guard deferredImportObserver == nil else { return }
        deferredImportObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryDeferredImport() }
            }
    }

    private func retryDeferredImport() {
        guard importReport.zonesDeferred else { return }
        // A store that can no longer be written to (the envelope was rejected in the meantime)
        // makes `runLegacyImport()` a guaranteed no-op, so stop watching rather than re-run it on
        // every display change for the rest of the session. The shell warning stays up, and the
        // import runs at the next launch once the config is fixed.
        guard store.canWrite else {
            removeDeferredImportObserver()
            return
        }
        runLegacyImport()
        guard !importReport.zonesDeferred else { return }   // still absent; keep waiting
        removeDeferredImportObserver()
        // Restart Zones so it re-reads the section it was running defaults for. Deterministic,
        // and rare enough (once, when a missing display returns) that re-registering its hotkeys
        // costs nothing.
        registry.restart(.zones)
        statusItem.refresh()
        settings?.refresh()
    }

    private func removeDeferredImportObserver() {
        guard let deferredImportObserver else { return }
        NotificationCenter.default.removeObserver(deferredImportObserver)
        self.deferredImportObserver = nil
    }

    // MARK: - Warnings

    /// Shell-level problems. Tool problems come from each running tool's `warnings`.
    private func shellWarnings() -> [ToolWarning] {
        var out: [ToolWarning] = []
        if let message = store.blockedMessage {
            out.append(ToolWarning(
                id: "shell.config",
                text: "⚠︎ Settings couldn’t be loaded",
                detailLines: [message],
                actionTitle: "Reset configuration…",
                action: { [weak self] in self?.resetConfig() }))
        }
        if importReport.zonesDeferred {
            // 1.x's wording, kept verbatim: the same situation, so the same sentence.
            out.append(ToolWarning(
                id: "shell.zonesDeferred",
                text: "⚠︎ Saved layout waiting for its display",
                detailLines: ["Your saved layout is waiting for its display. It is imported "
                              + "automatically when that display reconnects."]))
        }
        if SingleInstance.standaloneCyclerIsRunning() != nil {
            out.append(ToolWarning(
                id: "shell.standaloneCycler",
                text: Onboarding.cyclerRunningWarning,
                detailLines: [Onboarding.cyclerUninstallBanner],
                actionTitle: Self.cyclerAppURL == nil ? nil : "Reveal Cycler in Finder",
                action: Self.cyclerAppURL == nil ? nil : { Self.revealCyclerApp() }))
        }
        return out
    }

    // MARK: - Standalone Cycler

    /// Where the standalone app is installed, if it still is. Resolved fresh each time: the user
    /// may well delete it while Lineup keeps running, and the banner should stop offering to
    /// reveal something that is gone.
    private static var cyclerAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: SingleInstance.legacyCyclerBundleID)
    }

    private static func revealCyclerApp() {
        guard let url = cyclerAppURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// What the onboarding windows say about the import that just ran.
    private func onboardingImportContext() -> OnboardingImportContext {
        let summary = Onboarding.cyclerImportSummary(importReport)
        let cyclerPresent = summary != nil || SingleInstance.standaloneCyclerIsRunning() != nil
        return OnboardingImportContext(
            cyclerSummary: summary,
            revealCycler: Self.cyclerAppURL == nil ? nil : { Self.revealCyclerApp() },
            showUninstallBanner: cyclerPresent)
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

    private func openSettings(tool: ToolID? = nil) {
        if let settings {
            if let tool { settings.store.selection = .tool(tool) }
            settings.show()
            return
        }
        let store = SettingsStore(
            registry: registry,
            permissions: PermissionCenter.shared,
            showMenuBarIcon: self.store.config.general.showMenuBarIcon,
            // A dead shell can't have changed anything, so report the value back unchanged.
            onMenuBarIconChange: { [weak self] show in self?.setShowMenuBarIcon(show) ?? show })
        let controller = SettingsWindowController(store: store)
        controller.onClose = { [weak self] in self?.settings = nil }
        settings = controller
        if let tool { store.selection = .tool(tool) }
        controller.show()
    }

    /// - Returns: what is ACTUALLY in force afterwards. `store.update` only commits in memory when
    ///   the write succeeded, so a refused save returns the old value and Settings puts its switch
    ///   back rather than showing a preference the user does not have.
    @discardableResult
    private func setShowMenuBarIcon(_ show: Bool) -> Bool {
        do {
            try store.update { $0.general.showMenuBarIcon = show }
        } catch {
            log.error("could not persist showMenuBarIcon: \(error, privacy: .public)")
        }
        statusItem.refresh()
        return store.config.general.showMenuBarIcon
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
        // Only when there is NO Settings window yet. This fires on every activation — including
        // the one Settings itself causes, and the one that follows dismissing an alert — so
        // reopening unconditionally de-minimized the window the user had just minimized and
        // fought whatever sheet was on it. `applicationShouldHandleReopen` covers the Dock and
        // Spotlight route back in for a hidden menu-bar icon.
        if !store.config.general.showMenuBarIcon, settings == nil { openSettings() }
    }

    // MARK: - Welcome / What's New

    private func showWelcome() {
        let controller = WelcomeWindowController(
            importContext: onboardingImportContext(),
            // Accessibility only. Input Monitoring is never requested from a launch path — it is
            // asked for lazily, the first time Hyperkey is switched on.
            onGrant: { PermissionCenter.shared.requestAccessibility() },
            onClose: { [weak self] in
                UserDefaults.standard.set(true, forKey: AppShell.didOnboardKey)
                // A brand-new user has just been introduced to all three tools; What's New would
                // repeat that at the next launch, so retire it here.
                self?.markWhatsNewSeen()
                ActivationCoordinator.shared.release("welcome")
                self?.welcome = nil
            })
        welcome = controller
        ActivationCoordinator.shared.retain("welcome")
        controller.show()
    }

    private func showWhatsNew() {
        let controller = WhatsNewWindowController(
            importContext: onboardingImportContext(),
            onOpenSettings: { [weak self] in self?.openSettings() },
            onClose: { [weak self] in
                self?.markWhatsNewSeen()
                ActivationCoordinator.shared.release("whatsNew")
                self?.whatsNew = nil
            })
        whatsNew = controller
        ActivationCoordinator.shared.retain("whatsNew")
        controller.show()
    }

    /// Written however the window was dismissed, so it is shown exactly once. A write-blocked
    /// store means it may reappear at the next launch — the alternative is losing the note
    /// entirely for a user whose config is already broken.
    private func markWhatsNewSeen() {
        guard !store.config.general.didShowWhatsNew2 else { return }
        do {
            try store.update { $0.general.didShowWhatsNew2 = true }
        } catch {
            log.error("could not record didShowWhatsNew2: \(error, privacy: .public)")
        }
    }

    // MARK: - Termination

    func applicationWillTerminate(_ notification: Notification) {
        TerminationCoordinator.shared.runCleanups()
        registry.stopAll()
    }

    #if DEBUG
    /// Render the onboarding + About content views to PNGs for offscreen visual QA. Debug-only.
    private static func renderPreviews(to dir: String) {
        func write(_ view: NSView, _ name: String) {
            let win = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = view
            view.layoutSubtreeIfNeeded()
            view.display()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }
        func sized(_ view: NSView, _ size: NSSize) -> NSView {
            view.frame = NSRect(origin: .zero, size: size)
            return view
        }
        write(WelcomeWindowController.makeEmbeddedContent(), "preview-welcome.png")
        write(WhatsNewWindowController.makeEmbeddedContent(), "preview-whatsnew.png")
        write(sized(AboutWindowController.makeEmbeddedContent(size: AboutWindowController.naturalSize),
                    AboutWindowController.naturalSize), "preview-about.png")
    }
    #endif
}
