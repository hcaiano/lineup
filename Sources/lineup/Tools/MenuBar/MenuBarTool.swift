import AppKit
import AppCore
import SwiftUI

@MainActor
final class MenuBarTool: NSObject, Tool, ObservableObject {
    let id = ToolID.menuBar
    let displayName = "Menu Bar"
    let summary = "Arrange your menu bar and tuck away the items you use less often."
    let iconSymbol = "menubar.rectangle"
    let requiredPermissions: Set<Permission> = [.accessibility]
    let defaultEnabled = false
    @Published private(set) var isRunning = false
    @Published private(set) var settings = MenuBarSettings()
    @Published private(set) var items: [MenuBarObservedItem] = []
    @Published private(set) var collapsed = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var sectionLoadError: String?
    private var services: ToolServices?
    private var toggle: NSStatusItem?
    private var refreshTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var work: Task<Void, Never>?
    private var recovery: Process?
    private var paneVisible = false
    private var scanning = false
    private var generation = 0
    private let journal: URL

    init(recoveryURL: URL = Product.configURL.deletingLastPathComponent().appendingPathComponent("menu-bar-recovery.json")) {
        journal = recoveryURL
        super.init()
    }

    var supported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 }
    var canEdit: Bool { sectionLoadError == nil && services?.config.canWrite == true && !busy }
    var canGrantAccess: Bool { !busy && (canEdit || FileManager.default.fileExists(atPath: journal.path)) }

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            settings = try services.config.load(MenuBarSettings.self) ?? MenuBarSettings()
            sectionLoadError = nil
        } catch { sectionLoadError = error.localizedDescription }
        // Recovery is independent of enabled/config state: a previous crash may
        // have happened just before the user disabled the tool or edited config.
        restore()
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
        services.termination.addCleanup(id) { [weak self] in self?.restore() }
        for (center, name) in [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore(); self?.refresh() }
            }
            observers.append((center, token))
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let center = NSWorkspace.shared.notificationCenter
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.paneVisible == true { self?.refresh() } }
            }))
        }
        updateMonitoring()
        if paneVisible { refresh() }
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
                if self.collapsed && !AXIsProcessTrusted() { self.restore() }
                if self.paneVisible { self.refresh() }
            }
        }
        refreshTimer?.tolerance = 0.5
    }

    func stop() {
        generation += 1
        work?.cancel()
        restore()
        refreshTimer?.invalidate(); refreshTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let toggle { NSStatusBar.system.removeStatusItem(toggle) }
        toggle = nil
        services?.termination.removeCleanup(id)
        isRunning = false
        items = []
    }

    func refresh() {
        guard isRunning, !busy, !collapsed, !scanning, AXIsProcessTrusted() else { return }
        scanning = true
        let revision = generation
        MenuBarInventory.read { [weak self] observed in
            guard let self else { return }
            self.scanning = false
            guard self.isRunning, self.generation == revision else { return }
            guard !self.busy, !self.collapsed else { return }
            self.items = observed
        }
    }

    private func save(_ next: MenuBarSettings) -> Bool {
        guard canEdit, let services else { return false }
        do {
            try services.config.save(next)
            settings = next
            message = nil
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func chooseAccess() {
        guard canGrantAccess else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = MenuBarPreferenceAccess.expectedURL.deletingLastPathComponent()
        panel.message = "Choose group.com.apple.controlcenter.plist so Lineup can show and hide the apps you select. Their visibility is restored when Menu Bar is turned off."
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
                    // Recovery must remain possible even when config.json is
                    // write-blocked. Renew only our recovery record in that case.
                    if self.canEdit { _ = self.save(next) }
                    try MenuBarPreferenceAccess.renewAccess(bookmark, journal: self.journal)
                    self.restore()
                } catch { self.message = error.localizedDescription }
            }
        }
    }

    func setHidden(_ hidden: Bool, owner: String) {
        guard supported, isRunning, canEdit else { return }
        restore()
        guard !FileManager.default.fileExists(atPath: journal.path) else { return }
        var next = settings
        next.setHidden(hidden, owner: owner)
        _ = save(next)
        refresh()
    }

    @objc func toggleVisibility() {
        guard !busy else { return }
        if collapsed { restore(); refresh(); return }
        guard isRunning, supported, canEdit, AXIsProcessTrusted() else {
            message = "Enable Menu Bar and allow Accessibility in General settings first."; return
        }
        guard let bookmark = settings.preferencesBookmark else { chooseAccess(); return }
        guard !settings.hiddenOwners.isEmpty else { message = "Move an app into Hidden Items first."; return }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.surteesstudios.Bartender").contains(where: { !$0.isTerminated }) {
            message = "Quit Bartender before hiding items with Lineup."; return
        }
        busy = true
        message = nil
        updateToggle()
        work = Task { [weak self] in
            guard let self else { return }
            let session = UUID()
            let ready = journal.appendingPathExtension(session.uuidString + ".ready")
            defer { busy = false; updateToggle(); try? FileManager.default.removeItem(at: ready) }
            do {
                try MenuBarPreferenceAccess.restore(journal: journal)
                let snapshot = try MenuBarPreferenceAccess.snapshot(bookmark: bookmark)
                let original = snapshot.originalsToHide(selected: settings.hiddenOwners,
                    excluding: Set([Bundle.main.bundleIdentifier, Product.bundleID].compactMap { $0 }))
                guard !original.isEmpty else { throw MenuBarPreferenceAccess.Failure(message: "None of the selected apps is currently allowed in the menu bar.") }
                let record = MenuBarRecoveryRecord(session: session, bookmark: bookmark, original: original)
                try MenuBarPreferenceAccess.prepare(record, journal: journal)
                let helper = Process()
                guard let executable = Bundle.main.executableURL else { throw MenuBarPreferenceAccess.Failure(message: "Run the installed Lineup app to enable recovery.") }
                helper.executableURL = executable
                helper.arguments = ["--menu-bar-recovery", journal.path, ready.path, String(getpid()), session.uuidString]
                helper.standardOutput = FileHandle.nullDevice
                helper.standardError = FileHandle.nullDevice
                helper.terminationHandler = { [weak self, weak helper] _ in
                    Task { @MainActor in
                        guard let self, let helper, self.recovery === helper else { return }
                        self.restore()
                    }
                }
                try helper.run()
                recovery = helper
                for _ in 0..<50 {
                    if FileManager.default.fileExists(atPath: ready.path) { break }
                    guard helper.isRunning else { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                guard isRunning, helper.isRunning,
                      (try? String(contentsOf: ready)) == session.uuidString else {
                    throw MenuBarPreferenceAccess.Failure(message: "The recovery helper could not start. Your menu bar has been left visible.")
                }
                try MenuBarPreferenceAccess.hide(journal: journal, session: session)
                collapsed = true
                message = nil
            } catch {
                do { try MenuBarPreferenceAccess.restore(journal: journal, session: session) }
                catch { message = "Visibility could not be restored. Use Restore Items before quitting. " + error.localizedDescription }
                recovery?.terminate(); recovery = nil
                if message == nil && !(error is CancellationError) { message = error.localizedDescription }
            }
            services?.refreshMenu()
        }
    }

    func restore() {
        work?.cancel()
        MenuBarInventory.cancelMove()
        do {
            try MenuBarPreferenceAccess.restore(journal: journal)
            collapsed = false
            message = nil
        } catch { message = "Could not restore menu bar items. Grant access again, then choose Restore Items. " + error.localizedDescription }
        recovery?.terminate(); recovery = nil
        updateToggle()
        services?.refreshMenu()
    }

    func move(_ itemID: String, before targetID: String) {
        guard supported, canEdit, isRunning, itemID != targetID else { return }
        restore()
        guard !FileManager.default.fileExists(atPath: journal.path) else { return }
        busy = true
        updateToggle()
        work = Task { [weak self] in
            guard let self else { return }
            defer { busy = false; updateToggle(); refresh() }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                let previous = await MenuBarInventory.read()
                try Task.checkCancellation()
                guard let source = previous.first(where: { $0.id == itemID }),
                      let target = previous.first(where: { $0.id == targetID }) else {
                    throw MenuBarPreferenceAccess.Failure(message: "The menu bar items changed. Refresh and try again.")
                }
                try await MenuBarInventory.move(source, before: target)
                try await Task.sleep(nanoseconds: 400_000_000)
                let observed = await MenuBarInventory.read()
                try Task.checkCancellation()
                items = observed
                guard MenuBarOrder.verifiesMove(itemID, before: targetID,
                    previous: previous.map(\.id), observed: observed.map(\.id)) else {
                    throw MenuBarPreferenceAccess.Failure(message: "macOS did not move this item to the requested position. You can also hold Command and drag it directly in the menu bar.")
                }
                message = nil
            } catch { if !(error is CancellationError) { message = error.localizedDescription } }
        }
    }

    private func updateToggle() {
        updateMonitoring()
        let label = collapsed ? "Show hidden menu bar items" : "Hide selected menu bar items"
        toggle?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: label)
        toggle?.button?.setAccessibilityLabel(label)
        toggle?.button?.toolTip = label
        toggle?.button?.isEnabled = !busy
    }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: collapsed ? "Show Hidden Items" : "Hide Selected Items", action: #selector(toggleVisibility), keyEquivalent: "")
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
