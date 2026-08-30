import AppKit
import AppCore
import Sparkle

/// The single `NSStatusItem` and the unified menu.
///
/// Shape:
/// ```
/// ⚠︎ <warnings from the shell + every running tool>
///    <detail lines>
///    Grant Accessibility… / Retry shortcuts / Reset configuration…
/// ──────────
/// Zones      ▸  Edit Layout… · ⇧-drag to snap ✓
/// Cycler     ▸  Reload bindings
/// Hyperkey   ▸  (status only, or nothing)
/// ──────────
/// Settings…                 ⌘,
/// Launch at login           ✓
/// ──────────
/// Check for Updates…            → target: AppUpdater.shared
/// About Lineup
/// ──────────
/// Quit Lineup               ⌘Q
/// ```
/// A tool contributing exactly one item gets it inlined instead of a submenu.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let registry: ToolRegistry
    private let permissions: PermissionCenter

    /// Shell-level warnings (config unreadable, etc.), recomputed on each build.
    var shellWarnings: () -> [ToolWarning] = { [] }
    var showMenuBarIcon: () -> Bool = { true }
    var onOpenSettings: () -> Void = {}
    var onShowAbout: () -> Void = {}

    init(registry: ToolRegistry, permissions: PermissionCenter) {
        self.registry = registry
        self.permissions = permissions
        super.init()
    }

    /// Rebuild from scratch. Cheap, and it is the only way a menu built once can reflect a
    /// permission that was granted while the app kept running.
    func refresh() {
        guard showMenuBarIcon() else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Brand.menuBarLogo()
            item.button?.toolTip = "\(Product.name): snapping, tiling, app cycling, and hyper key"
            statusItem = item
        }
        statusItem?.menu = buildMenu()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Actionable problems ONLY, at the top. Healthy states show nothing.
        var warnings = shellWarnings()
        if !permissions.isAccessibilityTrusted {
            warnings.insert(ToolWarning(
                id: "shell.accessibility",
                text: "⚠︎ Accessibility not granted",
                actionTitle: "Grant Accessibility…",
                action: { [weak self] in self?.permissions.openAccessibilitySettings() }), at: 0)
        }
        for tool in registry.runningTools { warnings.append(contentsOf: tool.warnings) }

        for warning in warnings {
            addInfo(menu, warning.text)
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
                let parent = NSMenuItem(title: tool.displayName, action: nil, keyEquivalent: "")
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
        let loginItem = actionItem("Launch at login", symbol: "power") { [weak self] in
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
