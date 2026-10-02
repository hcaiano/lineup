import AppKit
import AppCore
import Sparkle
import SwiftUI

/// Owns the Lineup status item: left click opens shared controls, right click opens
/// the native action menu. Tools keep their own services and contribute only views.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let registry: ToolRegistry
    private let permissions: PermissionCenter
    private let panelModel = MenuPanelModel()
    private var popover: NSPopover?
    private var panelTools: [ToolID: any Tool] = [:]

    #if DEBUG
    /// Captures the presented view in the isolated manual review, without rehosting its state.
    var reviewPanelView: NSView? { popover?.contentViewController?.view }
    #endif

    /// Shell-level warnings (config unreadable, etc.), recomputed on each build.
    var shellWarnings: () -> [ToolWarning] = { [] }
    var showMenuBarIcon: () -> Bool = { true }
    var onOpenSettings: () -> Void = {}
    var onOpenToolSettings: (ToolID) -> Void = { _ in }
    var onShowAbout: () -> Void = {}

    init(registry: ToolRegistry, permissions: PermissionCenter) {
        self.registry = registry
        self.permissions = permissions
        super.init()
        panelModel.openSettings = { [weak self] in
            self?.closePanel()
            self?.onOpenSettings()
        }
        panelModel.openToolSettings = { [weak self] id in
            self?.closePanel()
            self?.onOpenToolSettings(id)
        }
        panelModel.moreItems = { [weak self] in self?.appActions() ?? [] }
        panelModel.invoke = { [weak self] item in self?.invoke(item) }
        panelModel.close = { [weak self] in self?.closePanel() }
        panelModel.selectionChanged = { [weak self] in self?.syncPanelTools() }
    }

    /// Rebuild from scratch. Cheap, and it is the only way a menu built once can reflect a
    /// permission that was granted while the app kept running.
    func refresh() {
        guard showMenuBarIcon() else {
            if let statusItem {
                closePanel()
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            refreshPanel()
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Brand.menuBarLogo()
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        let awake = (registry.tool(.awake) as? AwakeTool)?.isActive == true
        statusItem?.button?.title = awake ? " Awake" : ""
        statusItem?.button?.toolTip = awake ? "Lineup: Keep Awake is active" : "Lineup"
        refreshPanel()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
        // Let the selected action run before rebuilding.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            guard let statusItem, let button = statusItem.button else { return }
            statusItem.menu = buildMenu()
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover?.isShown == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel(tool id: ToolID? = nil) {
        // Settings can explicitly open a tool even when the main icon is hidden.
        guard let anchor = statusItem?.button ?? NSApp.keyWindow?.contentView else { return }
        let statusAnchor = anchor is NSStatusBarButton
        let anchorRect = statusAnchor ? anchor.bounds : NSRect(x: anchor.bounds.midX,
            y: anchor.bounds.maxY - 1, width: 1, height: 1)
        refreshPanel()
        panelModel.open(tool: id)
        if popover?.isShown == true {
            syncPanelTools()
            return
        }
        let panel = NSPopover()
        panel.appearance = NSApp.appearance
        panel.behavior = .transient
        panel.animates = false
        panel.delegate = self
        let available = (anchor.window?.screen?.visibleFrame.height ?? 760) - 44
        let view = MenuPanel(model: panelModel, maximumHeight: min(640, max(200, available)))
        let controller = MenuPanelHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        controller.onResize = { [weak self, weak panel, weak anchor] size in
            guard let self, let panel, let anchor, self.popover === panel, panel.isShown else { return }
            panel.contentSize = size
            panel.show(relativeTo: anchorRect, of: anchor, preferredEdge: .minY)
        }
        panel.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        panel.contentSize = controller.view.fittingSize
        popover = panel
        syncPanelTools()
        panel.show(relativeTo: anchorRect, of: anchor, preferredEdge: .minY)
        panel.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePanel() {
        let closing = popover
        popover = nil
        for tool in panelTools.values { tool.panelDidClose() }
        panelTools = [:]
        panelModel.didClose()
        closing?.delegate = nil
        closing?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        closePanel()
    }


    private func syncPanelTools() {
        let running = registry.runningTools.filter { $0.id == panelModel.session.selectedTool }
        let enabled = Set(running.map(\.id))
        for (id, tool) in panelTools where !enabled.contains(id) {
            tool.panelDidClose()
            panelTools[id] = nil
        }
        for tool in running where panelTools[tool.id] == nil {
            panelTools[tool.id] = tool
            tool.panelWillOpen()
        }
    }

    private func refreshPanel() {
        var warnings = shellWarnings()
        if !permissions.isAccessibilityTrusted,
           registry.runningTools.contains(where: { $0.requiredPermissions.contains(.accessibility) }) {
            warnings.insert(ToolWarning(id: "shell.accessibility", text: "Accessibility access needed",
                                       actionTitle: "Open Accessibility Settings…",
                                       action: { [weak self] in self?.permissions.openAccessibilitySettings() }), at: 0)
        }
        panelModel.update(tools: registry.runningTools, warnings: warnings)
        if popover?.isShown == true { syncPanelTools() }
    }

    private func invoke(_ item: NSMenuItem) {
        guard item.isEnabled, let action = item.action else { return }
        closePanel()
        // Overlays and capture begin only after the popover has left the screen.
        DispatchQueue.main.async { NSApp.sendAction(action, to: item.target, from: item) }
    }

    private func appActions() -> [NSMenuItem] {
        let login = actionItem("Open at Login", symbol: "power") { [weak self] in
            LaunchAtLogin.toggle()
            self?.refresh()
        }
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = AppUpdater.shared
        update.isEnabled = AppUpdater.shared.updater.canCheckForUpdates
        return [login, update,
                actionItem("About Lineup", symbol: "info.circle") { [weak self] in self?.onShowAbout() },
                .separator(),
                actionItem("Quit Lineup", key: "q", symbol: "xmark.circle") { NSApp.terminate(nil) }]
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Actionable problems ONLY, at the top. Healthy states show nothing.
        var warnings = shellWarnings()
        if !permissions.isAccessibilityTrusted,
           registry.runningTools.contains(where: { $0.requiredPermissions.contains(.accessibility) }) {
            warnings.insert(ToolWarning(
                id: "shell.accessibility",
                text: "Accessibility access needed",
                actionTitle: "Open Accessibility Settings…",
                action: { [weak self] in self?.permissions.openAccessibilitySettings() }), at: 0)
        }
        for tool in registry.runningTools { warnings.append(contentsOf: tool.warnings) }

        for warning in warnings {
            addWarning(menu, warning.text)
            for line in warning.detailLines { addInfo(menu, "  \(line)") }
            if let title = warning.actionTitle, let action = warning.action {
                menu.addItem(actionItem(title, symbol: symbol(forWarning: warning), run: action))
            }
        }
        if !warnings.isEmpty { menu.addItem(.separator()) }

        // Tools, in registry order. Only running tools contribute rows.
        var addedToolSection = false
        for tool in registry.tools where tool.isRunning {
            let items = tool.menuItems()
            guard !items.isEmpty else { continue }
            addedToolSection = true
            if items.count == 1, let only = items.first {
                menu.addItem(only)
            } else {
                let active = (tool as? AwakeTool)?.isActive == true
                let parent = NSMenuItem(title: active ? "Keep Awake · Active" : tool.displayName,
                                        action: nil, keyEquivalent: "")
                parent.image = NSImage(systemSymbolName: tool.iconSymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                for item in items { submenu.addItem(item) }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        if addedToolSection { menu.addItem(.separator()) }

        menu.addItem(actionItem("Settings…", key: ",", symbol: "gearshape") { [weak self] in
            self?.onOpenSettings()
        })
        let loginItem = actionItem("Open at Login", symbol: "power") { [weak self] in
            LaunchAtLogin.toggle()
            self?.refresh()
        }
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        // Sparkle owns this item: it runs the check AND enables/disables the item via
        // canCheckForUpdates, so it targets the updater controller, not us.
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                     keyEquivalent: "")
        updatesItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        updatesItem.target = AppUpdater.shared
        menu.addItem(updatesItem)
        menu.addItem(actionItem("About \(Product.name)", symbol: "info.circle") { [weak self] in
            self?.onShowAbout()
        })

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit \(Product.name)", key: "q", symbol: "xmark.circle") {
            NSApp.terminate(nil)
        })
        return menu
    }

    private func symbol(forWarning warning: ToolWarning) -> String {
        if warning.id.contains("accessibility") { return "lock.shield" }
        if warning.id.contains("inputMonitoring") { return "keyboard" }
        if warning.id.contains("config") { return "arrow.counterclockwise" }
        return "arrow.clockwise"
    }

    /// The warning's title with an orange triangle, matching the panel. Tools write a leading
    /// "⚠︎" for text-only surfaces; the image replaces it here.
    private func addWarning(_ menu: NSMenu, _ text: String) {
        let title = text.hasPrefix("⚠") ? String(text.drop(while: { $0 == "⚠" || $0 == "\u{FE0E}" || $0 == "\u{FE0F}" || $0 == " " })) : text
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange])))
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// A menu row with a consistent SF Symbol icon, so every action lines up the same way
    /// (titles share one image column; the checkmark for toggles sits in the state column).
    private func actionItem(_ title: String, key: String = "", symbol: String,
                            run: @escaping () -> Void) -> NSMenuItem {
        let item = MenuActionItem(title: title, keyEquivalent: key, run: run)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        return item
    }
}

/// An `NSMenuItem` that carries its own closure, so the shell doesn't need an `@objc` selector
/// (and a target) for every row. Tools use the same helper via `ToolMenu`.
@MainActor
final class MenuActionItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, keyEquivalent: String = "", run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        self.target = self
        self.isEnabled = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}

/// Shared helpers for tools building their own menu rows, so every row in the unified menu
/// looks the same regardless of which tool contributed it.
@MainActor
enum ToolMenu {
    static func item(_ title: String, key: String = "", symbol: String,
                     run: @escaping () -> Void) -> NSMenuItem {
        let item = MenuActionItem(title: title, keyEquivalent: key, run: run)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            item.image = img.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        return item
    }

    static func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
