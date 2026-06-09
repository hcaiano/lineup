import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import LineupCore

/// Minimal menu-bar agent: loads the zone config, registers Hyper+key global hotkeys,
/// and snaps the focused window into the matching zone.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private enum ConfigState { case ok, loadError, migrationDeferred }
    private var config = LineupConfig()
    private var configState: ConfigState = .ok
    private var configCanWrite: Bool { configState == .ok } // block writes unless clean
    private var failedHotkeys = 0
    private var cycleState: CycleState?   // carries left/right cycle progress between presses
    private var editorOverlay: LayoutEditorOverlayController?
    private var settings: SettingsWindowController?

    private var configBlockedMessage: String? {
        switch configState {
        case .migrationDeferred: return "Your saved layout is waiting for its display. Editing is disabled until it reconnects or you reset from the menu."
        case .loadError: return "The config file couldn't be loaded. Editing is disabled until you reset it from the menu."
        case .ok: return nil
        }
    }
    private lazy var dragSnap = DragSnapController(configProvider: { [weak self] in
        self?.config ?? LineupConfig()
    })

    /// The effective shortcut set (user config, or built-in defaults).
    private var shortcuts: Shortcuts { config.shortcuts ?? ShortcutKit.defaults }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lineup/zones.json")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // agent: no Dock icon (also LSUIElement)
        reloadConfig()
        registerHotkeys()      // must precede buildStatusItem so the menu shows real
        dragSnap.start()       // shift-drag-to-snap (default on)
        buildStatusItem()      // hotkey status (e.g. failures if Magnet owns the combos)
        requestAccessibility() // prompt up front; hotkeys can't move windows without it
    }

    @objc private func toggleDragSnap() {
        if dragSnap.isEnabled { dragSnap.stop() } else { dragSnap.start() }
        buildStatusItem()
    }

    // MARK: - Config

    private func reloadConfig() {
        let url = AppDelegate.configURL
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            let outcome = try LineupConfig.loadOrMigrate(
                from: url, now: now,
                backup: { data in
                    // Must succeed before we risk replacing the only legacy copy.
                    let backupURL = url.deletingPathExtension().appendingPathExtension("backup-\(Self.timestamp()).json")
                    try data.write(to: backupURL, options: .atomic)
                },
                resolveLegacyTarget: { old in
                    // Migrate the seams onto the display they were drawn on. If the legacy
                    // pixel width implies a specific display and it isn't connected, DEFER.
                    let screens = NSScreen.screens.map { ScreenIdentity.info(for: $0) }
                    if let w = LineupConfig.inferredLegacyWidth(old) {
                        return screens.filter { abs($0.pixelsWide - w) <= 8 }
                            .max(by: { $0.pixelsWide < $1.pixelsWide })
                    }
                    return screens.max(by: { $0.pixelsWide < $1.pixelsWide })
                })
            switch outcome {
            case .loaded(let cfg), .fresh(let cfg):
                config = cfg
                configState = .ok
            case .migrated(let cfg):
                config = cfg
                configState = .ok
                do { try config.write(to: url) }
                catch { FileHandle.standardError.write(Data("migration write failed (legacy file + backup preserved): \(error)\n".utf8)) }
            case .deferred:
                // The saved layout belongs to a display that isn't connected. Run defaults
                // but BLOCK writes so a save can't overwrite the preserved legacy file. It
                // migrates automatically the next time that display is present.
                FileHandle.standardError.write(Data("legacy config deferred: original display not connected\n".utf8))
                config = LineupConfig()
                configState = .migrationDeferred
            }
        } catch {
            // Corrupt/unsupported file: surface it, do NOT overwrite, and BLOCK writes until
            // an explicit reset — so a later save can't clobber the preserved file.
            FileHandle.standardError.write(Data("config could not be loaded (left untouched): \(error)\n".utf8))
            config = LineupConfig()
            configState = .loadError
        }
    }

    /// Millisecond-precision stamp so rapid backup/rejected copies don't collide.
    private static func timestamp() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    @objc private func resetConfig() {
        let url = AppDelegate.configURL
        do {
            // Preserve the rejected/deferred file FIRST; if that fails, do not reset.
            if let data = try? Data(contentsOf: url) {
                let rejected = url.deletingPathExtension().appendingPathExtension("rejected-\(Self.timestamp()).json")
                try data.write(to: rejected, options: .atomic) // throws -> abort reset (no clobber)
            }
            config = LineupConfig()
            try config.write(to: url)
            configState = .ok
        } catch {
            FileHandle.standardError.write(Data("reset aborted (preservation or write failed; config left untouched): \(error)\n".utf8))
            // leave configState as-is so writes stay blocked
        }
        buildStatusItem()
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if settings != nil { settings?.show(); return }
        let ctx = SettingsContext(
            config: { [weak self] in self?.config ?? LineupConfig() },
            canWrite: { [weak self] in self?.configCanWrite ?? false },
            blockedMessage: { [weak self] in self?.configBlockedMessage },
            shortcuts: { [weak self] in self?.shortcuts ?? ShortcutKit.defaults },
            setShortcuts: { [weak self] s in self?.applyShortcuts(s) },
            isDragSnapOn: { [weak self] in self?.dragSnap.isEnabled ?? false },
            toggleDragSnap: { [weak self] in self?.toggleDragSnap() },
            isLaunchAtLoginOn: { SMAppService.mainApp.status == .enabled },
            toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            isTrusted: { AXIsProcessTrusted() },
            requestAccessibility: { [weak self] in self?.requestAccessibility() })
        let controller = SettingsWindowController(context: ctx)
        controller.onClose = { [weak self] in self?.settings = nil }
        settings = controller
        controller.show()
    }

    /// Persist an edited layout for a specific screen. write() validates first, so an
    /// invalid tree never reaches disk and the in-memory config isn't updated on failure.
    private func applyLayout(_ node: Node, for screen: ScreenInfo) {
        guard configCanWrite else { return }
        let updated = config.setting(layout: node, for: screen, now: ISO8601DateFormatter().string(from: Date()))
        do {
            try updated.write(to: AppDelegate.configURL)
            config = updated
            buildStatusItem()
        } catch {
            FileHandle.standardError.write(Data("settings layout save failed (not applied): \(error)\n".utf8))
        }
    }

    /// Persist a new shortcut set and re-register the global hotkeys.
    private func applyShortcuts(_ newShortcuts: Shortcuts) {
        guard configCanWrite else { return }
        var updated = config
        updated.shortcuts = newShortcuts
        do {
            try updated.write(to: AppDelegate.configURL)
            config = updated
            HotkeyManager.shared.unregisterAll()
            registerHotkeys()
            buildStatusItem()
        } catch {
            FileHandle.standardError.write(Data("shortcuts save failed (not applied): \(error)\n".utf8))
        }
    }

    // MARK: - Layout editor overlay

    @objc private func openEditor() {
        if editorOverlay != nil { return }
        let controller = LayoutEditorOverlayController(
            config: config,
            canWrite: configCanWrite,
            blockedMessage: configBlockedMessage,
            applyLayout: { [weak self] node, info in self?.applyLayout(node, for: info) },
            onClose: { [weak self] in self?.editorOverlay = nil })
        editorOverlay = controller
        controller.show()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        var failed = 0
        for b in shortcuts.bindings {
            let action = b.action
            let ok = HotkeyManager.shared.register(keyCode: b.keyCode, modifiers: UInt32(b.modifiers)) { [weak self] in
                guard let self else { return }
                let now = Date().timeIntervalSinceReferenceDate
                switch action {
                case "left":
                    self.cycleState = WindowMover.cycleFocusedWindow(.left, config: self.config, now: now, prev: self.cycleState)
                case "right":
                    self.cycleState = WindowMover.cycleFocusedWindow(.right, config: self.config, now: now, prev: self.cycleState)
                default:
                    self.cycleState = nil // any other action breaks an in-progress cycle
                    if let zoneIndex = ZoneAction.zeroBasedIndex(from: action) {
                        WindowMover.snapFocusedWindow(toZoneIndex: zoneIndex, config: self.config)
                    } else {
                        WindowMover.snapFocusedWindow(toQuickAction: action, config: self.config)
                    }
                }
            }
            if !ok { failed += 1 }
        }
        failedHotkeys = failed
    }

    @objc private func retryHotkeys() {
        HotkeyManager.shared.unregisterAll()
        registerHotkeys()
        buildStatusItem()
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.title = "▦"
            statusItem.button?.toolTip = "Lineup — window manager"
        }
        let menu = NSMenu()

        // Actionable problems ONLY, at the top. Healthy states show nothing.
        var hasWarning = false
        if !AXIsProcessTrusted() {
            addInfo(menu, "⚠︎ Accessibility not granted")
            menu.addItem(NSMenuItem(title: "Grant Accessibility…", action: #selector(requestAccessibility), keyEquivalent: ""))
            hasWarning = true
        }
        if failedHotkeys > 0 {
            addInfo(menu, "⚠︎ \(failedHotkeys) shortcut\(failedHotkeys == 1 ? "" : "s") blocked by another app")
            menu.addItem(NSMenuItem(title: "Retry shortcuts", action: #selector(retryHotkeys), keyEquivalent: ""))
            hasWarning = true
        }
        if configState != .ok {
            addInfo(menu, configState == .migrationDeferred
                ? "⚠︎ Saved layout waiting for its display"
                : "⚠︎ Config couldn't be loaded")
            menu.addItem(NSMenuItem(
                title: configState == .migrationDeferred ? "Discard & reset…" : "Reset configuration…",
                action: #selector(resetConfig), keyEquivalent: ""))
            hasWarning = true
        }
        if hasWarning { menu.addItem(.separator()) }

        let editItem = NSMenuItem(title: "Edit Layout…", action: #selector(openEditor), keyEquivalent: "")
        editItem.isEnabled = configCanWrite // blocked config routes to Reset instead
        menu.addItem(editItem)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(.separator())
        let dragItem = NSMenuItem(title: "Shift-drag to snap", action: #selector(toggleDragSnap), keyEquivalent: "")
        dragItem.state = dragSnap.isEnabled ? .on : .off
        menu.addItem(dragItem)
        let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lineup", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            FileHandle.standardError.write(Data("launch-at-login toggle failed: \(error)\n".utf8))
        }
        buildStatusItem()
    }

    @objc private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
