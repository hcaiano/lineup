#if DEBUG
import AppKit
import SwiftUI
import AppCore
import CyclerCore
import WorldClockCore
import ZonesCore

/// Opens the production tools and shared panel with an isolated config. Capture mode only
/// reads hardware; interactive changes use the same actions as the normal app.
@MainActor
final class MenuPanelReview: NSObject, NSApplicationDelegate {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var registry: ToolRegistry?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var settingsModel: SettingsStore?
    private var displayTool: DisplayControlTool?
    private var scrollTool: ScrollTool?
    private var discoveryTimer: Timer?
    private var directory: URL?
    private var capture = false
    private let reviewHUD = DisplayControlHUD()
    private let reviewBlackScreen = DisplayBlackScreen()
    private var reviewEscape: HotkeyManager.Token?
    private var blackScreenTimeout: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard !AppUpdater.isBundled else {
                throw Failure(message: "Run the panel review with .build/debug/lineup so the bundled updater cannot start.")
            }
            let environment = ProcessInfo.processInfo.environment
            // Preview both native appearances without changing the user's system preferences.
            if let appearance = environment["LINEUP_MENU_PANEL_REVIEW_APPEARANCE"] {
                if appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
                if appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            }
            guard let path = environment["LINEUP_MENU_PANEL_REVIEW_DIR"], !path.isEmpty else {
                throw Failure(message: "Choose a separate review directory.")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let live = Product.configDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard root != live, !root.path.hasPrefix(live.path + "/") else {
                throw Failure(message: "The panel review must use a separate config directory.")
            }
            let configURL = root.appendingPathComponent("review-config.json")
            guard configURL.resolvingSymlinksInPath() == configURL else {
                throw Failure(message: "The review config must be a regular file in the review directory.")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = root
            capture = environment["LINEUP_MENU_PANEL_CAPTURE"] == "1"
            let store = LineupAppConfigStore(url: configURL)
            _ = store.load()
            guard store.canWrite else {
                throw Failure(message: "The review config could not be loaded. Its bytes were left untouched.")
            }

            // A reused review directory may contain manually enabled media keys. Always begin
            // with read-only display detection and a clock in the shared panel.
            var display = try store.config.settings(DisplayControlSettings.self, for: .displayControl) ?? .init()
            display.brightnessKeys = false
            display.volumeKeys = false
            try store.setSettings(display, for: .displayControl)
            var clock = try store.config.settings(WorldClockSettings.self, for: .worldClock) ?? Self.sampleClockSettings()
            clock.showSeparateMenuBarItem = false
            try store.setSettings(clock, for: .worldClock)
            try store.update { $0.general.showMenuBarIcon = true }
            // Sample app shortcuts let the Cycler pane be reviewed populated. Cycler never starts
            // here, so none of them is registered.
            if (try store.config.settings(CyclerToolSettings.self, for: .cycler))?.bindings.isEmpty ?? true {
                let hyper: UInt32 = 256 | 512 | 2048 | 4096
                try store.setSettings(CyclerToolSettings(bindings: [
                    AppBinding(keyCode: 3, modifiers: hyper, bundleIdentifier: "com.apple.finder"),
                    AppBinding(keyCode: 1, modifiers: hyper, bundleIdentifier: "com.apple.Safari"),
                    AppBinding(keyCode: 17, modifiers: hyper, bundleIdentifiers: ["com.apple.Terminal", "com.apple.Notes"]),
                ]), for: .cycler)
            }
            // Text Capture has no shortcut until one is recorded, so running it adds no input hook.
            for id in [ToolID.displayControl, .awake, .worldClock, .textCapture] {
                try store.setEnabled(true, for: id)
            }
            // Registered only so Settings can render their panes. They never start: each would
            // install shortcuts, event taps or a key remapping. Menu Bar is left out entirely
            // because registration restores icons from the live recovery journal, and Keyboard
            // Remap because its Settings pane refreshes the live keyboard maps.
            for id in [ToolID.zones, .cycler, .hyperkey, .scroll] {
                try store.setEnabled(false, for: id)
            }

            let registry = ToolRegistry(store: store)
            self.registry = registry
            let displayTool = DisplayControlTool()
            self.displayTool = displayTool
            registry.register(ZonesTool())
            registry.register(CyclerTool())
            registry.register(HyperkeyTool())
            registry.register(WorldClockTool())
            registry.register(AwakeTool())
            registry.register(TextCaptureTool())
            registry.register(displayTool)
            let scrollTool = ScrollTool()
            self.scrollTool = scrollTool
            registry.register(scrollTool)
            let item = StatusItemController(registry: registry, permissions: .shared)
            statusItem = item
            item.showMenuBarIcon = { store.config.general.showMenuBarIcon }
            let model = SettingsStore(registry: registry, permissions: .shared,
                showMenuBarIcon: store.config.general.showMenuBarIcon,
                onMenuBarIconChange: { [weak item] value in
                    do {
                        try store.update { $0.general.showMenuBarIcon = value }
                        item?.refresh()
                    } catch {
                        fputs("Panel review settings could not be saved: \(error.localizedDescription)\n", stderr)
                    }
                    return store.config.general.showMenuBarIcon
                })
            model.selection = .tool(.worldClock)
            let settings = SettingsWindowController(store: model)
            settingsModel = model
            settingsWindow = settings
            item.onOpenSettings = { [weak settings] in settings?.show() }
            item.onOpenToolSettings = { [weak settings, weak model] id in
                model?.selection = .tool(id)
                settings?.show()
            }
            registry.onChange = { [weak item] in item?.refresh() }
            registry.onOpenPanel = { [weak item] id in item?.showPanel(tool: id) }
            registry.onSettingsChange = { [weak settings, weak item] in
                settings?.refresh()
                item?.refresh()
            }
            ActivationCoordinator.shared.applyBaseline()
            TerminationCoordinator.shared.installSignalHandlers()
            registry.startEnabledTools()
            item.refresh()
            print("Panel review PID: \(ProcessInfo.processInfo.processIdentifier), config: \(configURL.path)")
            waitForDiscovery()
        } catch { fail(error) }
    }

    private static func sampleClockSettings() -> WorldClockSettings {
        var places = [
            ClockPlace(id: "city:5128581", name: "New York", timeZoneID: "America/New_York",
                coordinates: .init(latitude: 40.71427, longitude: -74.00597), region: "New York, United States"),
            ClockPlace(id: "city:1850147", name: "Tokyo", timeZoneID: "Asia/Tokyo",
                coordinates: .init(latitude: 35.6895, longitude: 139.69171), region: "Tokyo, Japan")
        ]
        if TimeZone.autoupdatingCurrent.identifier != "Europe/Lisbon" {
            places.insert(ClockPlace(id: "city:2267057", name: "Lisbon", timeZoneID: "Europe/Lisbon",
                coordinates: .init(latitude: 38.72509, longitude: -9.1498), region: "Lisbon, Portugal"), at: 0)
        }
        return WorldClockSettings(places: places, showSeparateMenuBarItem: false)
    }

    private func waitForDiscovery() {
        let deadline = Date().addingTimeInterval(45)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.displayTool?.isDiscovering == false {
                    timer.invalidate()
                    self.discoveryTimer = nil
                    self.openOverview()
                } else if Date() >= deadline {
                    timer.invalidate()
                    self.discoveryTimer = nil
                    self.fail(Failure(message: "Display detection did not finish within 45 seconds."))
                }
            }
        }
        discoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func openOverview() {
        statusItem?.showPanel()
        if ProcessInfo.processInfo.environment["LINEUP_MENU_PANEL_REVIEW_BLACK_SCREEN"] == "1" {
            showBlackScreenReview()
            return
        }
        if ProcessInfo.processInfo.environment["LINEUP_MENU_PANEL_REVIEW_HUD"] == "1",
           let tool = displayTool, let monitor = tool.monitors.first, let level = monitor.brightness.level {
            // This preview uses a detected reading and sends no keyboard event or hardware command.
            reviewHUD.show(.init(monitorName: monitor.name, control: .brightness, level: level),
                           on: tool.reviewScreen(for: monitor.connection))
            print("System OSD review: confirmed brightness \(Int((level.normalized * 100).rounded()))%; no hardware command sent.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.describe(self.statusItem?.reviewPanelView, name: "Lineup controls")
            guard self.capture else { return }
            self.runCaptures(self.captureSteps())
        }
    }

    /// A two-second renderer/recovery review. It never sends a media key or display command.
    private func showBlackScreenReview() {
        guard let tool = displayTool, let monitor = tool.monitors.first,
              let screen = tool.reviewScreen(for: monitor.connection),
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return }
        let scope = HotkeyScope(owner: .displayControl)
        guard case .success(let token) = scope.register(keyCode: 53, modifiers: 0, action: { [weak self] in
            self?.finishBlackScreenReview(reason: "Escape")
        }) else {
            print("Black-screen review refused: Escape could not be registered.")
            return
        }
        reviewEscape = token
        let timeout = DispatchWorkItem { [weak self] in self?.finishBlackScreenReview(reason: "automatic timeout") }
        blackScreenTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        guard reviewBlackScreen.apply(displayIDs: [displayID]).contains(displayID) else {
            finishBlackScreenReview(reason: "display unavailable or mirrored")
            return
        }
        statusItem?.closePanel()
        reviewHUD.show(.init(monitorName: monitor.name, control: .brightness,
                             level: monitor.brightness.level, isBlackedOut: true), on: screen)
        print("Black-screen review: display \(displayID), full frame \(NSStringFromRect(screen.frame)); hardware brightness unchanged at \(monitor.brightness.level?.current.description ?? "unknown").")
        fflush(stdout)
    }

    private func finishBlackScreenReview(reason: String) {
        blackScreenTimeout?.cancel()
        blackScreenTimeout = nil
        reviewBlackScreen.hideAll()
        reviewHUD.hide(immediately: true)
        if let token = reviewEscape { HotkeyScope(owner: .displayControl).unregister(token) }
        reviewEscape = nil
        print("Black-screen review restored: \(reason); no hardware command sent.")
        fflush(stdout)
    }

    /// Each step presents one state, then the visible window is captured with its composed
    /// materials and native control layers.
    private func captureSteps() -> [(name: String, show: () -> NSView?)] {
        let panel: (ToolID) -> (String, () -> NSView?) = { [weak self] id in
            ("panel-\(id.rawValue).png", {
                self?.statusItem?.showPanel(tool: id)
                return self?.statusItem?.reviewPanelView
            })
        }
        let settings: (SettingsSection, String) -> (String, () -> NSView?) = { [weak self] section, name in
            ("settings-\(name).png", {
                self?.statusItem?.closePanel()
                self?.settingsModel?.selection = section
                self?.settingsWindow?.show()
                let window = NSApp.windows.first { $0.title == "\(Product.name) Settings" }
                // Tall enough to review a whole pane in one capture where the screen allows it.
                if let window, let screen = window.screen {
                    let height = min(1040, screen.visibleFrame.height - 60)
                    if window.frame.height < height {
                        window.setFrame(NSRect(x: window.frame.minX, y: screen.visibleFrame.maxY - height - 20,
                                               width: window.frame.width, height: height), display: true)
                    }
                }
                return window?.contentView
            })
        }
        // A short real session shows the active state; stopping it releases the power assertion.
        let awakeActive: (String, () -> NSView?) = ("panel-awake-active.png", { [weak self] in
            let awake = self?.registry?.tool(.awake) as? AwakeTool
            if awake?.isActive == false { awake?.startSession() }
            self?.statusItem?.showPanel(tool: .awake)
            return self?.statusItem?.reviewPanelView
        })
        let awakeStopped: (String, () -> NSView?) = ("panel-awake-stopped.png", { [weak self] in
            (self?.registry?.tool(.awake) as? AwakeTool)?.stopSession()
            self?.statusItem?.showPanel(tool: .awake)
            return self?.statusItem?.reviewPanelView
        })
        let widgets: (String, () -> NSView?) = ("panel-widgets-sample.png", { [weak self] in
            self?.statusItem?.closePanel()
            return self?.showWidgetSample()
        })
        // Opt-in: the editor covers every display for about a second. Save is a no-op.
        let editor: [(String, () -> NSView?)] = ProcessInfo.processInfo.environment["LINEUP_MENU_PANEL_REVIEW_EDITOR"] == "1"
            ? [("layout-editor.png", { [weak self] in
                self?.statusItem?.closePanel()
                return self?.showEditorSample()
            }), ("layout-editor-closed", { [weak self] in
                self?.editor?.forceClose()
                self?.editor = nil
                return nil
            })]
            : []
        let notices: [(String, () -> NSView?)] = [
            ("overlay-capture-copied.png", { [weak self] in
                self?.statusItem?.closePanel()
                if self?.notice.reviewView == nil || self?.noticeKind != 0 {
                    self?.noticeKind = 0
                    self?.notice.show("Text copied. Paste with Command-V.", success: true)
                }
                return self?.notice.reviewView
            }),
            ("overlay-capture-failed.png", { [weak self] in
                if self?.noticeKind != 1 {
                    self?.noticeKind = 1
                    self?.notice.show("Portuguese and English recognition are not both available on this Mac. Update macOS and try again. Clipboard unchanged.")
                }
                return self?.notice.reviewView
            }),
            ("overlay-drag-hint.png", { [weak self] in
                guard let self else { return nil }
                self.notice.hide()
                if self.highlight == nil {
                    let screen = NSScreen.main?.visibleFrame ?? .zero
                    let window = HighlightWindow()
                    window.show(at: NSRect(x: screen.midX - 300, y: screen.midY - 200, width: 600, height: 400),
                                hint: HighlightWindow.halfHint)
                    self.highlight = window
                }
                return self.highlight?.contentView
            }),
            ("overlay-done", { [weak self] in
                self?.highlight?.orderOut(nil)
                self?.highlight = nil
                return nil
            }),
        ]
        return editor + notices + [panel(.displayControl), panel(.awake), awakeActive, awakeStopped, panel(.worldClock),
                panel(.textCapture), widgets,
                settings(.general, "general"), settings(.tool(.zones), "zones"),
                settings(.tool(.cycler), "cycler"), settings(.tool(.hyperkey), "hyperkey"),
                settings(.tool(.worldClock), "world-clock"), settings(.tool(.awake), "awake"),
                settings(.tool(.textCapture), "text-capture"),
                settings(.tool(.displayControl), "display-control"), settings(.tool(.scroll), "scroll"),
                settings(.about, "about")]
    }

    private var widgetWindow: NSPanel?
    private let notice = TextCaptureNotice()
    private var noticeKind = -1
    private var highlight: HighlightWindow?
    private var editor: LayoutEditorOverlayController?

    private func showEditorSample() -> NSView? {
        if let editor { return editor.reviewWindow?.contentView }
        let third = 1.0 / 3.0
        let sample = Node.split(axis: .vertical,
                                dividers: [Boundary(third, .fraction), Boundary(2 * third, .fraction)],
                                children: [.leaf, .leaf, .split(axis: .horizontal,
                                                                 dividers: [Boundary(0.5, .fraction)],
                                                                 children: [.leaf, .leaf])])
        let controller = LayoutEditorOverlayController(
            canWrite: true, blockedMessage: nil,
            candidate: { LineupConfig(defaultLayout: sample) },
            save: { _ in false }, onClose: {})
        editor = controller
        controller.show()
        return controller.reviewWindow?.contentView
    }

    /// Tools that cannot run in this review (shortcuts, event taps, Caps Lock) still have value
    /// views. This draws them with sample data on the popover material, at the panel's width.
    private func showWidgetSample() -> NSView? {
        if let widgetWindow { return widgetWindow.contentView }
        let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        let notes = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
        let content = VStack(alignment: .leading, spacing: 0) {
            ZonesQuickPanel(dragSnapOn: true, dragBind: "⇧", canWrite: true, warnings: [],
                            editLayout: {}, setDragSnap: { _ in })
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            Divider()
            CyclerQuickPanel(entries: [
                .init(id: 0, title: "Finder", icons: [finder], shortcut: "⌃⌥⇧⌘F", installed: true, open: {}),
                .init(id: 1, title: "Safari", icons: [safari], shortcut: "⌃⌥⇧⌘S", installed: true, open: {}),
                .init(id: 2, title: "Notes + Safari", icons: [notes, safari], shortcut: "⌃⌥⇧⌘N", installed: true, open: {}),
            ], warnings: [])
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            Divider()
            HyperkeyQuickPanel(trigger: "Caps Lock", modifiers: "⌃⌥⇧⌘", isActive: true, warnings: [])
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            Divider()
            TextCaptureQuickPanel(isCapturing: false, isRunning: true, shortcut: "⌃⇧2", warnings: [],
                                  capture: {}, cancel: {})
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            if let scrollTool {
                Divider()
                ScrollQuickPanel(tool: scrollTool)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            }
            Divider()
            // Never attached, so it reads no keyboard and has no mapping service.
            KeyboardRemapQuickPanel(tool: KeyboardRemapTool())
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
        }
        .frame(width: 352)
        let host = NSHostingView(rootView: content)
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        material.blendingMode = .behindWindow
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
            host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        let size = host.fittingSize
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = material
        window.center()
        window.orderFrontRegardless()
        widgetWindow = window
        return material
    }

    private func runCaptures(_ steps: [(name: String, show: () -> NSView?)]) {
        guard let step = steps.first else {
            stop()
            NSApp.terminate(nil)
            return
        }
        _ = step.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            do {
                let view = step.show()
                guard step.name.hasSuffix(".png") else {
                    self.runCaptures(Array(steps.dropFirst()))
                    return
                }
                self.describe(view, name: step.name)
                try self.write(view, name: step.name)
                self.runCaptures(Array(steps.dropFirst()))
            } catch { self.fail(error) }
        }
    }

    private func write(_ view: NSView?, name: String) throws {
        guard let view, let window = view.window, let directory else {
            throw Failure(message: "The \(name) view is unavailable.")
        }
        let url = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "The \(name) window could not be captured. Screen Recording may be required.")
        }
        print("Captured \(url.path)")
    }

    private func describe(_ view: NSView?, name: String) {
        guard let view, let window = view.window else { return }
        print("\(name): window \(window.windowNumber), frame \(NSStringFromRect(window.frame)), content \(NSStringFromRect(view.bounds))")
        fflush(stdout)
    }

    private func stop() {
        notice.hide()
        highlight?.orderOut(nil)
        editor?.forceClose()
        blackScreenTimeout?.cancel()
        blackScreenTimeout = nil
        reviewBlackScreen.hideAll()
        if let token = reviewEscape { HotkeyScope(owner: .displayControl).unregister(token) }
        reviewEscape = nil
        widgetWindow?.close()
        reviewHUD.hide(immediately: true)
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        statusItem?.closePanel()
        registry?.stopAll()
        TerminationCoordinator.shared.runCleanups()
    }

    private func fail(_ error: Error) {
        fputs("Menu panel review failed: \(error.localizedDescription)\n", stderr)
        stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { stop() }
}
#endif
