import AppKit
import AppCore
import SwiftUI

/// The arrow is a boundary the user places with Command-drag: apps whose icons sit on its hidden
/// side disappear when it collapses and reappear in place when it expands. Only their native
/// visibility flags change; system controls and capture indicators are never restricted.
/// A separate recovery process restores the flags on exit, including a crash or SIGKILL.
/// Lineup never moves the pointer or posts input events.
@MainActor
final class MenuBarTool: NSObject, Tool, ObservableObject {
    let id = ToolID.menuBar
    let displayName = "Menu Bar"
    let summary = "Tuck the menu bar icons you use less often behind one arrow."
    let iconSymbol = "menubar.rectangle"
    let requiredPermissions: Set<Permission> = [.accessibility]
    let defaultEnabled = false
    @Published private(set) var isRunning = false
    @Published private(set) var settings = MenuBarSettings()
    @Published private(set) var items: [MenuBarObservedItem] = []
    /// Apps in the hidden group: as last applied while collapsed, as currently arranged otherwise.
    @Published private(set) var hiddenGroup: Set<String> = []
    @Published private(set) var collapsed = false
    @Published private(set) var message: String?
    @Published private(set) var sectionLoadError: String?
    @Published private(set) var hasPendingRecovery = false
    let available = MenuBarPreferenceAccess.available
    private var services: ToolServices?
    private var toggle: NSStatusItem?
    private var recovery: Process?
    private var work: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var rehideTimer: Timer?
    private var reapplyTimer: Timer?
    private var settleTimer: Timer?
    private var layoutReadyAfter: TimeInterval = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Bumped whenever a pending activation or scan must no longer win.
    private var generation = 0
    @Published private(set) var busy = false
    private var paneVisible = false
    private var scanning = false
    private var rescan = false
    private var appInfo: [String: (name: String, icon: NSImage)] = [:]
    private let journal: URL
    private enum CollapseRequest { case automatic, manual, idle }
    private enum LayoutChange { case wake, display }

    init(recoveryURL: URL = Product.configURL.deletingLastPathComponent().appendingPathComponent("menu-bar-recovery.json")) {
        journal = recoveryURL
        super.init()
    }

    var supported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 }
    private var own: String { Bundle.main.bundleIdentifier ?? Product.bundleID }
    private var leftToRight: Bool { NSApp.userInterfaceLayoutDirection == .leftToRight }

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            settings = try services.config.load(MenuBarSettings.self) ?? MenuBarSettings()
            sectionLoadError = nil
        } catch { sectionLoadError = error.localizedDescription }
        hiddenGroup = settings.hiddenOwners
        // Recovery is independent of enabled/config state, including a crash before disabling.
        restoreIcons()
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        guard supported else { message = "Menu Bar currently supports macOS 27."; return }
        guard sectionLoadError == nil else { return }
        isRunning = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Lineup.MenuBar.Toggle"
        item.button?.target = self
        item.button?.action = #selector(toggleVisibility)
        toggle = item
        updateToggle()
        services.termination.addCleanup(id) { [weak self] in self?.release() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged(.wake) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appLaunched(app) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.paneVisible == true { self?.refresh() } }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged(.display) }
        }))
        updateMonitoring()
        // Let the bar settle so the arrow and the other icons report their positions.
        layoutReadyAfter = ProcessInfo.processInfo.systemUptime + 1
        collapse(.automatic)
    }

    func stop() {
        release()
        collapsed = false
        settleTimer?.invalidate(); settleTimer = nil
        cancelRehide()
        reapplyTimer?.invalidate(); reapplyTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let toggle { NSStatusBar.system.removeStatusItem(toggle) }
        toggle = nil
        services?.termination.removeCleanup(id)
        isRunning = false
        items = []
    }

    func setPaneVisible(_ visible: Bool) {
        paneVisible = visible
        updateMonitoring()
        if visible { refresh() }
    }

    private func updateMonitoring() {
        let needed = isRunning && (paneVisible || collapsed)
        if !needed { refreshTimer?.invalidate(); refreshTimer = nil; return }
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Without Accessibility the groups cannot be read again, so fail open.
                if self.collapsed && !AXIsProcessTrusted() { self.expand(autoHide: false) }
                if self.paneVisible { self.refresh() }
            }
        }
        refreshTimer?.tolerance = 0.5
    }

    // MARK: Groups

    /// The arrow in the global top-left coordinates used by Accessibility.
    private var arrowFrame: CGRect? {
        guard let window = toggle?.button?.window, let primary = NSScreen.screens.first else { return nil }
        let frame = window.frame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func arranged(_ observed: [MenuBarObservedItem]) -> Set<String>? {
        guard let arrow = arrowFrame else { return nil }
        return MenuBarLayout.hiddenOwners(items: observed.map { ($0.owner, $0.frame) }, arrow: arrow,
                                          displayBounds: MenuBarInventory.displayBounds(),
                                          leftToRight: leftToRight, previous: settings.hiddenOwners)
    }

    func refresh() {
        guard isRunning, AXIsProcessTrusted() else { return }
        guard !scanning else { rescan = true; return }
        scanning = true
        let revision = generation
        MenuBarInventory.read { [weak self] observed in
            guard let self else { return }
            self.scanning = false
            guard self.isRunning else { return }
            // Hidden icons report stale positions, so only an unrestricted bar updates the groups.
            if self.generation == revision {
                self.accept(observed)
                if !self.collapsed && !self.busy,
                   ProcessInfo.processInfo.systemUptime >= self.layoutReadyAfter,
                   let arranged = self.arranged(observed) { self.hiddenGroup = arranged }
            }
            if self.rescan { self.rescan = false; self.refresh() }
        }
    }

    private func accept(_ observed: [MenuBarObservedItem]) {
        items = observed
        for item in observed { appInfo[item.owner] = (item.appName, item.icon) }
    }

    /// Hidden apps with no item on screen, because the group is collapsed or the app is not running.
    var offscreenHiddenApps: [(owner: String, name: String, icon: NSImage)] {
        let shown = collapsed ? [] : Set(items.map(\.owner))
        return hiddenGroup.subtracting(shown).map { owner in
            let info = appInfo[owner] ?? Self.installedInfo(owner)
            appInfo[owner] = info
            return (owner, info.name, info.icon)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func installedInfo(_ owner: String) -> (name: String, icon: NSImage) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) else {
            return (owner, NSImage(named: NSImage.applicationIconName)!)
        }
        return (url.deletingPathExtension().lastPathComponent, NSWorkspace.shared.icon(forFile: url.path))
    }

    /// Remembered so apps that launch while collapsed, or after login, start in their group.
    private func remember(_ hidden: Set<String>) -> Bool {
        guard hidden != settings.hiddenOwners else { hiddenGroup = hidden; return true }
        var next = settings
        next.hiddenOwners = hidden
        guard let services, services.config.canWrite, sectionLoadError == nil else {
            message = "The hidden group could not be saved, so icons stay visible. Check your configuration in General settings."
            return false
        }
        do {
            try services.config.save(next)
            settings = next
            hiddenGroup = hidden
            return true
        } catch { message = error.localizedDescription; return false }
    }

    // MARK: Visibility

    @objc func toggleVisibility() {
        if collapsed { expand(autoHide: true) } else { collapse(.manual) }
    }

    /// Idle hides check interaction against the freshly observed group that will be hidden.
    private func collapse(_ request: CollapseRequest) {
        let quiet = request != .manual
        cancelRehide()
        guard isRunning, !collapsed, !busy, !hasPendingRecovery else { return }
        guard settings.preferencesBookmark != nil else {
            message = "Grant Menu Bar access to show and hide icons."
            if !quiet { chooseAccess() }
            return
        }
        let remaining = layoutReadyAfter - ProcessInfo.processInfo.systemUptime
        if remaining > 0 {
            settleTimer?.invalidate()
            settleTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleTimer = nil; self?.collapse(request) }
            }
            return
        }
        guard available else {
            if !quiet { message = Self.unavailableText }
            return
        }
        guard AXIsProcessTrusted() else {
            if !quiet { message = "Allow Accessibility for Lineup in General settings so it can see which side of the arrow each icon is on." }
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.surteesstudios.Bartender").contains(where: { !$0.isTerminated }) {
            if !quiet { message = "Quit Bartender before hiding icons with Lineup." }
            return
        }
        message = nil
        busy = true
        generation += 1
        let revision = generation
        MenuBarInventory.read { [weak self] observed in
            guard let self, self.generation == revision, self.isRunning else { return }
            self.accept(observed)
            guard let hidden = self.arranged(observed) else {
                self.busy = false
                if !quiet { self.message = "The arrow's position cannot be read yet. Try again in a moment." }
                return
            }
            if request == .idle {
                if self.isInteracting(with: hidden) {
                    self.busy = false
                    self.scheduleRehide(after: MenuBarAutoHide.retry)
                    return
                }
            }
            guard self.remember(hidden) else { self.busy = false; return }
            guard !hidden.isEmpty else {
                self.busy = false
                if !quiet { self.message = "Hold Command and drag icons to the left of the arrow to hide them." }
                return
            }
            self.hide(hidden, revision: revision, request: request)
        }
    }

    /// Recovery must be running and acknowledge this exact journal before any icon hides.
    private func hide(_ hidden: Set<String>, revision: Int, request: CollapseRequest) {
        let quiet = request != .manual
        guard let bookmark = settings.preferencesBookmark else {
            busy = false
            message = "Grant Menu Bar access to show and hide icons."
            updateToggle()
            return
        }
        work = Task { [weak self] in
            guard let self else { return }
            let session = UUID()
            let ready = journal.appendingPathExtension(session.uuidString + ".ready")
            var helper: Process?
            defer {
                if generation == revision { busy = false; work = nil; updateToggle() }
                try? FileManager.default.removeItem(at: ready)
            }
            do {
                try MenuBarPreferenceAccess.restore(journal: journal)
                let snapshot = try MenuBarPreferenceAccess.snapshot(bookmark: bookmark)
                let original = originals(in: snapshot, hidden: hidden)
                guard !original.isEmpty else {
                    if !quiet { message = "No visible icon is in the hidden group yet." }
                    return
                }
                try MenuBarPreferenceAccess.prepare(MenuBarRecoveryRecord(session: session, bookmark: bookmark,
                    original: original), journal: journal)
                guard let executable = Bundle.main.executableURL else {
                    throw MenuBarPreferenceAccess.Failure(message: "Run the signed Lineup app to enable recovery.")
                }
                let process = Process()
                helper = process
                process.executableURL = executable
                process.arguments = ["--menu-bar-recovery", journal.path, ready.path, String(getpid()), session.uuidString]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self, weak process] _ in
                    Task { @MainActor in
                        guard let self, let process, self.recovery === process else { return }
                        self.expand(autoHide: false)
                        self.message = "Recovery stopped unexpectedly, so icons have been restored."
                    }
                }
                try process.run()
                recovery = process
                for _ in 0..<50 {
                    if FileManager.default.fileExists(atPath: ready.path) { break }
                    guard process.isRunning else { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                guard isRunning, generation == revision, process.isRunning,
                      (try? String(contentsOf: ready)) == session.uuidString else {
                    throw MenuBarPreferenceAccess.Failure(message: "Recovery could not start. Your menu bar has been left visible.")
                }
                // The user can open a menu while the recovery process starts.
                if request == .idle && isInteracting(with: hidden) {
                    expand(autoHide: false)
                    scheduleRehide(after: MenuBarAutoHide.retry)
                    return
                }
                try MenuBarPreferenceAccess.hide(journal: journal, session: session)
                collapsed = true
                message = nil
            } catch {
                do { try MenuBarPreferenceAccess.restore(journal: journal, session: session) }
                catch {
                    if generation == revision { message = "Some icons could not be restored. Choose Restore Icons. " + error.localizedDescription }
                }
                if recovery === helper { recovery = nil }
                if helper?.isRunning == true { helper?.terminate() }
                if generation == revision, message == nil, !(error is CancellationError) {
                    message = error.localizedDescription
                }
            }
            hasPendingRecovery = FileManager.default.fileExists(atPath: journal.path) && recovery?.isRunning != true
        }
    }

    /// Native preferences track installed apps by bundle and other items by executable URL.
    /// Resolve those URL records through the owning app bundle, including its tray helpers.
    private func originals(in snapshot: MenuBarPreferences, hidden: Set<String>) -> [String: Bool] {
        let owners = hidden.subtracting([own, Product.bundleID]).filter { !$0.hasPrefix("com.apple.") }
        var bundles: [String: [URL]] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let owner = app.bundleIdentifier, let url = app.bundleURL {
                bundles[owner, default: []].append(url)
            }
        }
        let registeredOwners = snapshot.allowed.keys.filter { URL(string: $0)?.isFileURL != true }
        for owner in Set(registeredOwners).union(owners) where bundles[owner] == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) { bundles[owner] = [url] }
        }
        return snapshot.originalFlags(for: owners, bundles: bundles)
    }

    private func expand(autoHide: Bool) {
        release()
        reapplyTimer?.invalidate(); reapplyTimer = nil
        settleTimer?.invalidate()
        layoutReadyAfter = ProcessInfo.processInfo.systemUptime + 0.6
        updateToggle()
        if autoHide { scheduleRehide(after: MenuBarAutoHide.delay) }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleTimer = nil; self?.refresh() }
        }
    }

    /// Cancels pending work before restoring flags, so an old activation cannot hide later.
    private func release() {
        generation += 1
        work?.cancel(); work = nil
        busy = false
        do {
            try MenuBarPreferenceAccess.restore(journal: journal)
            collapsed = false
            message = nil
        } catch {
            message = "Some icons could not be restored. Grant access again, then choose Restore Icons. " + error.localizedDescription
        }
        let helper = recovery
        recovery = nil
        if helper?.isRunning == true { helper?.terminate() }
        hasPendingRecovery = FileManager.default.fileExists(atPath: journal.path)
    }

    private func appLaunched(_ app: NSRunningApplication?) {
        if paneVisible && !collapsed { refresh() }
        guard collapsed, let owner = app?.bundleIdentifier, settings.hiddenOwners.contains(owner) else { return }
        reapplyTimer?.invalidate()
        reapplyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.collapsed, let bookmark = self.settings.preferencesBookmark else { return }
                do {
                    let snapshot = try MenuBarPreferenceAccess.snapshot(bookmark: bookmark)
                    try MenuBarPreferenceAccess.extend(self.originals(in: snapshot, hidden: self.settings.hiddenOwners),
                                                       journal: self.journal)
                } catch {
                    self.expand(autoHide: false)
                    self.message = "The new icon could not be hidden safely, so icons stay visible. " + error.localizedDescription
                }
            }
        }
    }

    private func layoutChanged(_ change: LayoutChange) {
        guard isRunning else { return }
        let wasCollapsed = collapsed
        expand(autoHide: false)
        cancelRehide()
        layoutReadyAfter = ProcessInfo.processInfo.systemUptime + 1
        if change == .wake { collapse(.automatic) }
        else if wasCollapsed { collapse(.idle) }
        else { scheduleRehide(after: MenuBarAutoHide.delay) }
    }

    private func scheduleRehide(after delay: TimeInterval) {
        rehideTimer?.invalidate()
        rehideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehide() }
        }
        rehideTimer?.tolerance = 0.5
    }

    private func cancelRehide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    private func rehide() {
        rehideTimer = nil
        guard isRunning, !collapsed else { return }
        collapse(.idle)
    }

    private func isInteracting(with hidden: Set<String>) -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(hidden.contains) == true
        }.map(\.processIdentifier))
        return NSEvent.pressedMouseButtons != 0
            || MenuBarAutoHide.shouldWait(pointer: CGEvent(source: nil)?.location ?? .zero,
                menuBars: MenuBarInventory.menuBars(), windows: MenuBarInventory.windows(), hiddenPIDs: pids)
    }

    private func updateToggle() {
        updateMonitoring()
        let label = collapsed ? "Show hidden menu bar icons" : "Hide the menu bar icons left of this arrow"
        toggle?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: label)
        toggle?.button?.setAccessibilityLabel(label)
        toggle?.button?.toolTip = label
        toggle?.button?.isEnabled = !busy
        services?.refreshMenu()
    }

    static let unavailableText = "This version of macOS does not let Lineup hide menu bar icons, so they stay visible."

    // MARK: Recovery

    /// Recovery also runs when disabled or after a failed activation.
    func restoreIcons() {
        release()
        updateToggle()
    }

    func chooseAccess() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = MenuBarPreferenceAccess.expectedURL.deletingLastPathComponent()
        panel.message = "Choose group.com.apple.controlcenter.plist so Lineup can show and hide the icons you select."
        panel.prompt = "Grant Access"
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let bookmark = try url.bookmarkData(options: .withSecurityScope,
                        includingResourceValuesForKeys: nil, relativeTo: nil)
                    _ = try MenuBarPreferenceAccess.snapshot(bookmark: bookmark)
                    var next = self.settings
                    next.preferencesBookmark = bookmark
                    if let services = self.services, services.config.canWrite, self.sectionLoadError == nil {
                        try services.config.save(next)
                        self.settings = next
                    }
                    try MenuBarPreferenceAccess.renewAccess(bookmark, journal: self.journal)
                    self.restoreIcons()
                } catch { self.message = error.localizedDescription }
            }
        }
    }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: collapsed ? "Show Hidden Icons" : "Hide Icons", action: #selector(toggleVisibility), keyEquivalent: "")
        item.target = self
        item.isEnabled = !busy
        return [item]
    }

    var warnings: [ToolWarning] {
        guard let text = sectionLoadError ?? message else { return [] }
        return [ToolWarning(id: "menu-bar", text: text)]
    }

    func makeSettingsPane() -> AnyView { AnyView(MenuBarPane(tool: self)) }
}
