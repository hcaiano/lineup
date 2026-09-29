import AppKit
import AppCore
import SwiftUI
import WorldClockCore

@MainActor
final class WorldClockTool: NSObject, Tool, NSPopoverDelegate {
    let id = ToolID.worldClock
    let displayName = "World Clock"
    let summary = "Local time, cities and a shared moment around the world."
    let iconSymbol = "clock"
    let requiredPermissions: Set<Permission> = []
    let defaultEnabled = false
    private(set) var isRunning = false
    let model = WorldClockModel()
    private var services: ToolServices?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            let settings = try services.config.load(WorldClockSettings.self) ?? WorldClockSettings()
            model.configure(settings: settings, blockedMessage: services.config.blockedMessage)
        } catch {
            model.configure(settings: WorldClockSettings(), blockedMessage:
                "World Clock settings couldn’t be read and were left untouched. Restore valid settings or update Lineup to edit places.")
        }
        model.save = { [weak self] settings in
            guard let self, self.model.blockedMessage == nil, let services = self.services else {
                throw LineupAppConfigError.writesBlocked
            }
            try services.config.save(settings)
        }
        model.onChange = { [weak self] in
            self?.updateStatus()
            self?.scheduleTick()
            self?.services?.refreshSettings()
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        isRunning = true
        model.isRunning = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
        observe(.default, NSNotification.Name.NSSystemTimeZoneDidChange)
        observe(.default, NSLocale.currentLocaleDidChangeNotification)
        observe(.default, NSNotification.Name.NSSystemClockDidChange)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        updateStatus()
        scheduleTick()
    }

    func stop() {
        popover?.close()
        popover = nil
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        model.cancelSearch()
        model.isRunning = false
        isRunning = false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.model.tick()
                self.updateStatus()
                self.scheduleTick()
            }
        }
        observers.append((center, token))
    }

    @objc private func togglePanel() {
        if popover?.isShown == true { popover?.performClose(nil) } else { showPanel() }
    }

    func showPanel() {
        guard isRunning, let button = statusItem?.button else { return }
        model.reset()
        let panel = NSPopover()
        panel.appearance = NSApp.appearance
        panel.behavior = .transient
        panel.animates = false
        panel.delegate = self
        let availableHeight = (button.window?.screen?.visibleFrame.height ?? 700) - 36
        let controller = ClockPopoverController(rootView:
            WorldClockPanel(model: model, maximumHeight: min(560, availableHeight),
                            close: { [weak self] in self?.popover?.performClose(nil) }))
        controller.onResize = { [weak self, weak panel] size in
            guard let self, let panel, self.popover === panel, panel.isShown,
                  let button = self.statusItem?.button else { return }
            panel.contentSize = size
            // SwiftUI can change the fitting height after presentation (search, edits, errors).
            // Re-anchor explicitly: an unconstrained resize can grow above the menu bar.
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        controller.view.layoutSubtreeIfNeeded()
        panel.contentViewController = controller
        panel.contentSize = controller.view.fittingSize
        popover = panel
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        scheduleTick()
    }

    func popoverDidClose(_ notification: Notification) {
        model.cancelSearch()
        model.reset()
        scheduleTick()
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let pinned = model.settings.pinnedID
        let place = model.settings.places.first { $0.id == pinned }
        let zone = pinned == "local" ? TimeZone.autoupdatingCurrent : place?.timeZone
        if let zone, let name = pinned == "local" ? "Local" : place?.name {
            let shortName = name.count > 16 ? String(name.prefix(15)) + "…" : name
            button.image = nil
            // This always uses real time. The popover's simulated instant must never leak here.
            button.title = "\(shortName)  \(ClockPresentation.time(Date(), in: zone))"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "\(name) · \(zone.identifier) · World Clock"
            button.setAccessibilityLabel("World Clock, \(name), \(ClockPresentation.time(Date(), in: zone))")
        } else {
            button.title = ""
            let image = NSImage(systemSymbolName: "clock", accessibilityDescription: "World Clock")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "World Clock"
            button.setAccessibilityLabel("World Clock")
        }
    }

    /// No timer while the icon is static and the panel is closed. A pinned clock wakes once per
    /// minute; clock/locale/zone changes and wake notifications refresh it immediately.
    private func scheduleTick() {
        timer?.invalidate()
        timer = nil
        guard isRunning, model.settings.pinnedID != nil || popover?.isShown == true else { return }
        let delay = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.05
        let tick = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.tick()
                self?.updateStatus()
                self?.scheduleTick()
            }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }

    func menuItems() -> [NSMenuItem] {
        [ToolMenu.item("World Clock…", symbol: "clock", run: { [weak self] in self?.showPanel() })]
    }

    var warnings: [ToolWarning] {
        guard let message = model.blockedMessage else { return [] }
        return [ToolWarning(id: "worldClock.config", text: "World Clock settings couldn’t be read", detailLines: [message])]
    }

    func makeSettingsPane() -> AnyView {
        AnyView(WorldClockSettingsPane(model: model, openPanel: { [weak self] in self?.showPanel() }))
    }
}

@MainActor
private final class ClockPopoverController: NSHostingController<WorldClockPanel> {
    var onResize: ((NSSize) -> Void)?
    private var reportedSize = NSSize.zero

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = view.fittingSize
        guard size.width > 0, size.height > 0, size != reportedSize else { return }
        reportedSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedSize == size else { return }
            self.onResize?(size)
        }
    }
}
