import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import LineupCore

/// Minimal menu-bar agent: loads the zone config, registers Hyper+key global hotkeys,
/// and snaps the focused window into the matching zone.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = ColumnConfig.default
    private var failedHotkeys = 0
    private var overlay: AlignmentOverlayController?

    /// Hyper+key -> zone id. Fixed-per-key (deterministic seam alignment).
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
        buildStatusItem()      // hotkey status (e.g. failures if Magnet owns the combos)
        requestAccessibility() // prompt up front; hotkeys can't move windows without it
    }

    // MARK: - Config

    private func reloadConfig() {
        do {
            config = try ColumnConfig.load(from: AppDelegate.configURL)
        } catch {
            FileHandle.standardError.write(Data("config load failed, using defaults: \(error)\n".utf8))
            config = .default
        }
    }

    @objc private func reloadConfigFromMenu() {
        reloadConfig()
        buildStatusItem()
    }

    // MARK: - Alignment overlay

    @objc private func openAlignmentOverlay() {
        // The G9 is the display with the most horizontal pixels; configure in its pixels.
        guard let screen = NSScreen.screens.max(by: {
                WindowMover.pixelsWide(of: $0) < WindowMover.pixelsWide(of: $1)
              }) ?? NSScreen.main else { return }
        let pixelsWide = WindowMover.pixelsWide(of: screen)
        let frame = screen.frame
        // Seed line positions from the current config (points from the screen's left).
        let initial = config.dividers.map { $0.x(in: frame, pixelsWide: pixelsWide) - frame.minX }

        overlay = AlignmentOverlayController(
            screen: screen,
            pixelsWide: pixelsWide,
            initialDividerPoints: initial,
            onSave: { [weak self] dividerPixels, halfPixels in
                guard let self else { return }
                self.config = ColumnConfig.fromPixels(dividers: dividerPixels, halfPixels: halfPixels)
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
                WindowMover.snapFocusedWindow(to: b.zone, config: self.config)
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
        let cfgLine = NSMenuItem(
            title: "Config: \(FileManager.default.fileExists(atPath: AppDelegate.configURL.path) ? AppDelegate.configURL.path : "defaults (thirds)")",
            action: nil, keyEquivalent: "")
        cfgLine.isEnabled = false
        menu.addItem(cfgLine)
        menu.addItem(NSMenuItem(
            title: "Align dividers on screen…", action: #selector(openAlignmentOverlay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Reload config", action: #selector(reloadConfigFromMenu), keyEquivalent: "r"))

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
