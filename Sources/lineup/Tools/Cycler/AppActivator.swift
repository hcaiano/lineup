import AppKit
import AppCore
import ApplicationServices
import os
import CyclerCore

private let log = Logger(subsystem: Product.logSubsystem, category: "cycler.activator")

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The heart of Cycler: press a per-app hotkey to bring an app to the front; press it again to
/// walk that app's windows one at a time. Multi-app groups use the same app activation helpers,
/// but intentionally stay window-agnostic.
///
/// First press (app not already frontmost) = "go to this app": activate it and remember its main
/// standard window. Repeat press (app already frontmost) = advance through a stable CGWindowID
/// order via the pure `WindowCycle` order, wrapping around. Window focus comes from the
/// Accessibility API, so the app must be Accessibility-trusted (the menu surfaces this when it
/// isn't). A bound app that is not running yet is launched and activated on first press.
@MainActor
final class AppActivator {
    static let shared = AppActivator()

    /// Index of the window we focused last time, per bundle id, so a repeat press advances from
    /// where we left off if the system's main-window readback is momentarily stale.
    private var lastIndex: [String: Int] = [:]

    /// Drop every remembered window position. `AppActivator` is a shared singleton that outlives
    /// the Cycler tool, so `CyclerTool.stop()` calls this: a disabled tool must not keep per-app
    /// state alive, and re-enabling should start from a clean slate rather than resume a cycle
    /// the user abandoned several minutes ago.
    func reset() {
        lastIndex.removeAll()
    }

    /// Bring `bundleIdentifier` forward, or cycle its windows if it's already frontmost.
    func engage(bundleIdentifier: String, direction: WindowCycle.Direction = .forward) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !apps.isEmpty else {
            Self.launch(bundleIdentifier: bundleIdentifier)
            lastIndex.removeValue(forKey: bundleIdentifier)
            return
        }

        guard AXIsProcessTrusted() else {
            log.error("Accessibility not granted; cannot cycle windows.")
            return
        }

        let windows = Self.windows(of: apps)
        let app = Self.preferredApplication(from: apps, bundleIdentifier: bundleIdentifier, windows: windows)
        let alreadyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier

        if windows.isEmpty, let minimizedWindow = Self.firstMinimizedWindow(of: apps) {
            Self.activate(minimizedWindow.app)
            Self.raise(minimizedWindow.element)
            lastIndex.removeValue(forKey: bundleIdentifier)
            return
        }

        if !alreadyFront {
            // First press: go to the app. Show the current window position without advancing, so
            // the HUD appears consistently on the first engagement for multi-window apps.
            Self.activate(app)
            // A second full AX sweep is only worth its cost when the first one found nothing —
            // a hidden app whose windows appear once `activate()` unhides it. Otherwise the list
            // we already have is the one we cycle, and `indexOfMain` reads each window's live
            // `AXMain` anyway, so nothing here is stale.
            let visibleWindows = windows.isEmpty ? Self.windows(of: apps) : windows
            let remembered = lastIndex[bundleIdentifier].flatMap { visibleWindows.indices.contains($0) ? $0 : nil }
            let current = Self.indexOfMain(in: visibleWindows)
                ?? remembered
                ?? (visibleWindows.isEmpty ? nil : 0)
            if let current {
                let selectedWindow = visibleWindows[current]
                Self.raise(selectedWindow.element)
                lastIndex[bundleIdentifier] = current
                Self.showWindowHUD(selectedWindow.app, windows: visibleWindows, selectedIndex: current)
            }
            return
        }

        guard windows.count >= 2 else {
            // With nothing to cycle, repeat presses become a show/hide toggle.
            app.hide()
            lastIndex.removeValue(forKey: bundleIdentifier)
            return
        }

        // Repeat press: advance from whatever window is focused now (falling back to our last
        // remembered index), then raise the next one.
        let current = Self.indexOfMain(in: windows) ?? lastIndex[bundleIdentifier]
        guard let nextIdx = WindowCycle.next(count: windows.count, current: current, direction: direction) else { return }
        let targetWindow = windows[nextIdx]
        Self.activate(targetWindow.app)
        Self.raise(targetWindow.element)
        lastIndex[bundleIdentifier] = nextIdx
        Self.showWindowHUD(targetWindow.app, windows: windows, selectedIndex: nextIdx)
    }

    /// Cycle between the running members of an app group. Groups deliberately do not inspect or
    /// cycle windows: a multi-app shortcut means "switch apps", while a single-app shortcut keeps
    /// the per-window behaviour above.
    func engageGroup(bundleIdentifiers: [String], direction: WindowCycle.Direction = .forward) {
        guard bundleIdentifiers.count > 1 else {
            if let bundleIdentifier = bundleIdentifiers.first {
                engage(bundleIdentifier: bundleIdentifier, direction: direction)
            }
            return
        }

        let running = Set(bundleIdentifiers.filter { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        })
        let installed: Set<String> = running.isEmpty
            ? Set(bundleIdentifiers.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
            : []
        let action = AppGroupCycle.next(
            group: bundleIdentifiers,
            installed: installed,
            running: running,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            direction: direction)
        let display = AppGroupCycle.display(group: bundleIdentifiers, running: running, action: action)

        switch action {
        case .launch(let bundleIdentifier):
            Self.launch(bundleIdentifier: bundleIdentifier)
            Self.showGroupHUD(display)
        case .activate(let bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
            Self.activate(app)
            Self.showGroupHUD(display)
        case .hide(let bundleIdentifier):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
            app.hide()
        case .none:
            let label = bundleIdentifiers.joined(separator: ", ")
            log.error("no installed apps found for group \(label, privacy: .public).")
        }
    }

    private static func showGroupHUD(_ display: AppGroupCycle.Display) {
        guard let selectedIndex = display.selectedIndex else { return }
        CycleHUD.shared.showAppGroup(
            apps: display.rows.map { row in
                CycleHUD.AppGroupItem(
                    name: appName(for: row.bundleIdentifier),
                    icon: appIcon(for: row.bundleIdentifier),
                    isRunning: row.isRunning,
                    isSelected: row.isSelected)
            },
            selectedIndex: selectedIndex)
    }

    private static func showWindowHUD(_ app: NSRunningApplication, windows: [WindowRecord], selectedIndex: Int) {
        let items = windows.map { Self.windowItem(for: $0) }
        CycleHUD.shared.show(
            appIcon: app.icon,
            appName: app.localizedName ?? "",
            windows: items,
            selectedIndex: selectedIndex)
    }

    // MARK: - AX helpers

    private struct WindowRecord {
        var app: NSRunningApplication
        var element: AXUIElement
        var windowID: CGWindowID
    }

    /// Every AX call below is synchronous on the main thread, and a beachballing target app blocks
    /// each one for the system default of SIX seconds — long enough to freeze the menu bar, the
    /// HUD and Zones, and long enough for the system to kill Hyperkey's event tap for being slow.
    /// A quarter second is generous for a healthy app; past that the cycle simply does nothing.
    /// (`WindowMover` does the same with its own budget.)
    ///
    /// The timeout is PER-ELEMENT, so every element we go on to talk to — the windows read out of
    /// the application element included — has to be tamed as well.
    private static func tame(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    private static func axApplication(_ pid: pid_t) -> AXUIElement {
        tame(AXUIElementCreateApplication(pid))
    }

    private static func windows(of apps: [NSRunningApplication]) -> [WindowRecord] {
        apps
            .flatMap { app in windows(of: axApplication(app.processIdentifier), app: app) }
            .sorted { lhs, rhs in lhs.windowID < rhs.windowID }
    }

    private static func windows(of axApp: AXUIElement, app: NSRunningApplication) -> [WindowRecord] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
            .map { tame($0) }
            .filter { isStandardWindow($0) && !isMinimized($0) }
            .compactMap { window in
                guard let windowID = windowID(of: window) else { return nil }
                return WindowRecord(app: app, element: window, windowID: windowID)
            }
    }

    private static func firstMinimizedWindow(of apps: [NSRunningApplication]) -> WindowRecord? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let orderedApps = apps.sorted { lhs, rhs in
            if lhs.processIdentifier == frontmostPID { return true }
            if rhs.processIdentifier == frontmostPID { return false }
            return lhs.processIdentifier < rhs.processIdentifier
        }

        for app in orderedApps {
            let axApp = axApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement],
                  let window = windows.lazy.map({ tame($0) })
                      .first(where: { isStandardWindow($0) && isMinimized($0) }) else {
                continue
            }
            return WindowRecord(app: app, element: window, windowID: windowID(of: window) ?? CGWindowID(0))
        }
        return nil
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == kAXStandardWindowSubrole as String
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool else { return false }
        return minimized
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID? {
        var windowID = CGWindowID(0)
        guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    /// Index of the app's main window within the stable CGWindowID order, if any.
    private static func indexOfMain(in windows: [WindowRecord]) -> Int? {
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           windows.contains(where: { $0.app.processIdentifier == frontmostPID }) {
            return windows.firstIndex { $0.app.processIdentifier == frontmostPID && isMain($0.element) }
        }
        return windows.firstIndex { isMain($0.element) }
    }

    private static func isMain(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &value) == .success
            && (value as? Bool) == true
    }

    private static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return "" }
        return title
    }

    private static func windowItem(for window: WindowRecord) -> CycleHUD.WindowItem {
        let rawTitle = Self.title(of: window.element)
        let windowApp = window.app
        guard WindowContext.supportsTrailingContext(bundleIdentifier: windowApp.bundleIdentifier),
              let appName = windowApp.localizedName else {
            return CycleHUD.WindowItem(title: rawTitle, context: nil)
        }
        let parsed = WindowContext.trailingContext(title: rawTitle, appName: appName)
        return CycleHUD.WindowItem(title: parsed.title, context: parsed.context)
    }

    private static func preferredApplication(
        from apps: [NSRunningApplication],
        bundleIdentifier: String,
        windows: [WindowRecord]
    ) -> NSRunningApplication {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier == bundleIdentifier,
           let app = apps.first(where: { $0.processIdentifier == frontmost.processIdentifier }) {
            return app
        }
        let windowCounts = Dictionary(grouping: windows, by: { $0.app.processIdentifier }).mapValues(\.count)
        return apps.max { lhs, rhs in
            (windowCounts[lhs.processIdentifier] ?? 0) < (windowCounts[rhs.processIdentifier] ?? 0)
        } ?? apps[0]
    }

    /// Raise a window and make it the app's main/focused window.
    private static func raise(_ window: AXUIElement) {
        if isMinimized(window) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func activate(_ app: NSRunningApplication) {
        // A hidden app must be un-hidden first — activate() alone leaves it hidden, which is why a
        // single-window app toggled off with hide() never came back.
        if app.isHidden { app.unhide() }
        app.activate(options: [.activateAllWindows])
    }

    private static func launch(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            log.error("no installed app found for \(bundleIdentifier, privacy: .public).")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                log.error("could not launch \(bundleIdentifier, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private static func appName(for bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = bundle.object(forInfoDictionaryKey: key) as? String, !name.isEmpty {
                    return name
                }
            }
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
    }

    private static func appIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
