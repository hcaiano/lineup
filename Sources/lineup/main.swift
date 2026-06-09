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
    private var overlay: AlignmentOverlayController?
    private var settings: SettingsWindowController?
    private lazy var dragSnap = DragSnapController(configProvider: { [weak self] in
        self?.config ?? LineupConfig()
    })

    /// Hyper+key -> quick-action id (resolved per-screen). Fixed-per-key for now; left/right
    /// cycling lands in a later phase.
    private let bindings: [(key: Int, zone: String)] = [
        (kVK_UpArrow, "full"),
        (kVK_DownArrow, "center"),
        (kVK_LeftArrow, "left"),
        (kVK_RightArrow, "right"),
        (kVK_ANSI_LeftBracket, "leftHalf"),
        (kVK_ANSI_RightBracket, "rightHalf"),
    ]

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

    @objc private func reloadConfigFromMenu() {
        reloadConfig()
        buildStatusItem()
    }

    // MARK: - Settings window

    @objc private func openSettings() {
        if settings != nil { settings?.show(); return }
        let ctx = SettingsContext(
            config: { [weak self] in self?.config ?? LineupConfig() },
            applyLayout: { [weak self] node, info in self?.applyLayout(node, for: info) },
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

    // MARK: - Alignment overlay

    @objc private func openAlignmentOverlay() {
        // Never overwrite a preserved corrupt/future config via a save.
        guard configCanWrite else { return }
        // Edit the seams of the widest display (the G9). Per-screen: saves to that screen.
        guard let screen = NSScreen.screens.max(by: {
                ScreenIdentity.info(for: $0).pixelsWide < ScreenIdentity.info(for: $1).pixelsWide
              }) ?? NSScreen.main else { return }
        let info = ScreenIdentity.info(for: screen)
        let frame = screen.frame
        // Seed the lines from the screen's current root columns (interior divider x's).
        let root = config.layout(forKey: info.key)
        let cols = Layout.rootColumns(root, frame: frame, visibleFrame: screen.visibleFrame, pixelsWide: info.pixelsWide)
        let initial: [CGFloat] = cols?.dropLast().map { $0.maxX - frame.minX } ?? [frame.width / 2]

        overlay = AlignmentOverlayController(
            screen: screen,
            pixelsWide: info.pixelsWide,
            initialDividerPoints: initial,
            onSave: { [weak self] dividerPixels, _ in
                guard let self else { return }
                let newRoot = Node.columns(dividerPixels.map { Boundary($0, .pixels) })
                self.config = self.config.setting(layout: newRoot, for: info, now: ISO8601DateFormatter().string(from: Date()))
                do {
                    try self.config.write(to: AppDelegate.configURL)
                } catch {
                    FileHandle.standardError.write(Data("failed to save config: \(error)\n".utf8))
                }
                self.buildStatusItem()
            },
            onClose: { [weak self] in self?.overlay = nil })
        overlay?.show()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        var failed = 0
        for b in bindings {
            let ok = HotkeyManager.shared.register(keyCode: b.key) { [weak self] in
                guard let self else { return }
                WindowMover.snapFocusedWindow(toQuickAction: b.zone, config: self.config)
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

        let trusted = AXIsProcessTrusted()
        let statusLine = NSMenuItem(
            title: trusted ? "Accessibility: granted" : "Accessibility: NOT granted",
            action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        if !trusted {
            menu.addItem(NSMenuItem(
                title: "Request Accessibility permission…",
                action: #selector(requestAccessibility), keyEquivalent: ""))
        }

        let total = bindings.count
        let hkLine = NSMenuItem(
            title: failedHotkeys == 0
                ? "Hotkeys: OK (\(total) active)"
                : "Hotkeys: \(failedHotkeys)/\(total) FAILED — disable Magnet, then Retry",
            action: nil, keyEquivalent: "")
        hkLine.isEnabled = false
        menu.addItem(hkLine)
        if failedHotkeys > 0 {
            menu.addItem(NSMenuItem(
                title: "Retry hotkey registration",
                action: #selector(retryHotkeys), keyEquivalent: ""))
        }

        menu.addItem(.separator())
        if configState != .ok {
            let msg = configState == .migrationDeferred
                ? "⚠︎ Saved layout waiting for its display — saving is disabled"
                : "⚠︎ Config couldn't be loaded — saving is disabled"
            let warn = NSMenuItem(title: msg, action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            menu.addItem(NSMenuItem(
                title: configState == .migrationDeferred ? "Discard saved layout & reset…" : "Reset configuration…",
                action: #selector(resetConfig), keyEquivalent: ""))
        }
        let cfgLine = NSMenuItem(
            title: "Config: \(FileManager.default.fileExists(atPath: AppDelegate.configURL.path) ? AppDelegate.configURL.path : "defaults (halves)")",
            action: nil, keyEquivalent: "")
        cfgLine.isEnabled = false
        menu.addItem(cfgLine)
        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        let alignItem = NSMenuItem(
            title: "Align dividers on screen…", action: #selector(openAlignmentOverlay), keyEquivalent: "")
        alignItem.isEnabled = configCanWrite // never overwrite a preserved corrupt/future config
        menu.addItem(alignItem)
        menu.addItem(NSMenuItem(
            title: "Reload config", action: #selector(reloadConfigFromMenu), keyEquivalent: "r"))

        let dragItem = NSMenuItem(
            title: "Shift-drag to snap", action: #selector(toggleDragSnap), keyEquivalent: "")
        dragItem.state = dragSnap.isEnabled ? .on : .off
        menu.addItem(dragItem)

        let loginItem = NSMenuItem(
            title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        for b in bindings {
            let item = NSMenuItem(title: "Hyper + \(keyLabel(b.key))  →  \(b.zone)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lineup", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func keyLabel(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        default: return "?"
        }
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
