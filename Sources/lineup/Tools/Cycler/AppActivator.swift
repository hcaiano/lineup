import AppKit
import AppCore
import ApplicationServices
import os
import CyclerCore

private let log = Logger(subsystem: Product.logSubsystem, category: "cycler.activator")

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Tiles classifies each AX window without exposing its model to Cycler. A freeform window is
/// unmanaged for routing purposes: it stays available in the current context.
enum CyclerWindowContext: Equatable {
    case currentContext
    case unmanaged
    case inactiveWorkspace(workspace: Int, focusEpoch: UInt64)
    /// Tiles knows the window, but cannot safely change its workspace right now.
    case unavailable(message: String)
}

struct CyclerWindowRoute {
    let context: CyclerWindowContext
    let requestInactiveActivation: (@MainActor () -> Void)?

    init(context: CyclerWindowContext,
         requestInactiveActivation: (@MainActor () -> Void)? = nil) {
        self.context = context
        self.requestInactiveActivation = requestInactiveActivation
    }

    @MainActor @discardableResult
    func activateIfInactive() -> Bool {
        guard case .inactiveWorkspace = context, let requestInactiveActivation else { return false }
        requestInactiveActivation()
        return true
    }
}

struct CyclerWindowRouting {
    let route: @MainActor (AXUIElement) -> CyclerWindowRoute
}

typealias CyclerWindowRoutingProvider = @MainActor () -> CyclerWindowRouting?

/// The heart of Cycler: press a per-app hotkey to bring an app to the front; press it again to
/// walk that app's windows one at a time. Multi-app groups still cycle apps, but can raise one
/// routed window after choosing the next app.
///
/// First press (app not already frontmost) = "go to this app": activate it and remember its main
/// standard window. Repeat press (app already frontmost) = advance through a stable CGWindowID
/// order via the pure `WindowCycle` order, wrapping around. Window focus comes from the
/// Accessibility API, so the app must be Accessibility-trusted (the menu surfaces this when it
/// isn't). A bound app that is not running yet is launched and activated on first press.
@MainActor
final class AppActivator {
    static let shared = AppActivator()

    /// Window we focused last time, per bundle id, so filtering a different Tiles context does not
    /// make an old array index point at another window.
    private var lastWindowID: [String: CGWindowID] = [:]

    /// Drop every remembered window position. `AppActivator` is a shared singleton that outlives
    /// the Cycler tool, so `CyclerTool.stop()` calls this: a disabled tool must not keep per-app
    /// state alive, and re-enabling should start from a clean slate rather than resume a cycle
    /// the user abandoned several minutes ago.
    func reset() {
        lastWindowID.removeAll()
    }

    /// Bring `bundleIdentifier` forward, or cycle its windows if it's already frontmost.
    func engage(bundleIdentifier: String,
                direction: WindowCycle.Direction = .forward,
                windowRouting: CyclerWindowRouting? = nil) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard !apps.isEmpty else {
            Self.launch(bundleIdentifier: bundleIdentifier)
            lastWindowID.removeValue(forKey: bundleIdentifier)
            return
        }

        guard AXIsProcessTrusted() else {
            log.error("Accessibility not granted; cannot cycle windows.")
            return
        }

        let allWindows = windowRouting.map { Self.allWindows(of: apps, using: $0) }
            ?? Self.windows(of: apps)
        let selection = Self.candidateSelection(from: allWindows, using: windowRouting)
        let windows = selection.windows
        let app = Self.preferredApplication(from: apps, bundleIdentifier: bundleIdentifier, windows: windows)
        let alreadyFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier

        if windowRouting == nil, windows.isEmpty,
           let minimizedWindow = Self.firstMinimizedWindow(of: apps) {
            Self.activate(minimizedWindow.app)
            Self.raise(minimizedWindow.element)
            lastWindowID[bundleIdentifier] = minimizedWindow.windowID
            return
        }

        if !alreadyFront {
            // First press: go to the app. Show the current window position without advancing, so
            // the HUD appears consistently on the first engagement for multi-window apps.
            if windowRouting == nil { Self.activate(app) }
            // A second full AX sweep is only worth its cost when the first one found nothing —
            // a hidden app whose windows appear once it is unhidden. Otherwise the list
            // we already have is the one we cycle, and `indexOfMain` reads each window's live
            // `AXMain` anyway, so nothing here is stale.
            let visibleSelection: CandidateSelection
            if windows.isEmpty, allWindows.isEmpty {
                // Some hidden apps publish no AXWindows until they are unhidden. With routing,
                // the first pass therefore has no target to classify. Make the app publish its
                // windows, then route the refreshed target in this same key press.
                // Do not activate every app window before Tiles has selected the routed target.
                // That activation can make an unrelated AXMain window switch the workspace.
                if windowRouting != nil, app.isHidden { app.unhide() }
                let refreshed = windowRouting.map { Self.allWindows(of: apps, using: $0) }
                    ?? Self.windows(of: apps)
                visibleSelection = Self.candidateSelection(from: refreshed, using: windowRouting)
            } else {
                visibleSelection = selection
            }
            let visibleWindows = visibleSelection.windows
            let remembered = lastWindowID[bundleIdentifier].flatMap { rememberedID in
                visibleWindows.firstIndex { $0.windowID == rememberedID }
            }
            let current = Self.indexOfMain(in: visibleWindows)
                ?? remembered
                ?? (visibleWindows.isEmpty ? nil : 0)
            if let current {
                let selectedWindow = visibleWindows[current]
                let tilesOwnsFeedback: Bool
                if windowRouting == nil {
                    Self.raise(selectedWindow.element)
                    tilesOwnsFeedback = false
                } else {
                    tilesOwnsFeedback = Self.activateRoutedWindow(selectedWindow)
                }
                lastWindowID[bundleIdentifier] = selectedWindow.windowID
                if !tilesOwnsFeedback {
                    Self.showWindowHUD(selectedWindow.app, windows: visibleWindows,
                                       selectedIndex: current)
                }
            } else if windowRouting != nil {
                if let message = visibleSelection.unavailableMessage {
                    CycleHUD.shared.showBlocked(message)
                } else if allWindows.isEmpty {
                    Self.activate(app)
                }
            }
            return
        }

        // A non-empty AX list with no routed candidates means every window is managed by Tiles
        // but temporarily unavailable. Do not turn that state into Cycler's single-window hide.
        if windowRouting != nil, windows.isEmpty, !allWindows.isEmpty {
            if let message = selection.unavailableMessage {
                CycleHUD.shared.showBlocked(message)
            }
            return
        }

        if windows.count == 1, windows[0].isMinimized {
            let targetWindow = windows[0]
            let tilesOwnsFeedback = Self.activateRoutedWindow(targetWindow)
            lastWindowID[bundleIdentifier] = targetWindow.windowID
            if !tilesOwnsFeedback {
                Self.showWindowHUD(targetWindow.app, windows: windows, selectedIndex: 0)
            }
            return
        }

        // An inactive-workspace fallback is intentionally a single target. Raising it lets Tiles
        // switch context; another quick key press must not select a second inactive workspace.
        if windowRouting != nil, !windows.isEmpty, !selection.hasCurrentCandidates {
            let targetWindow = windows[0]
            let tilesOwnsFeedback = Self.activateRoutedWindow(targetWindow)
            lastWindowID[bundleIdentifier] = targetWindow.windowID
            if !tilesOwnsFeedback {
                Self.showWindowHUD(targetWindow.app, windows: windows, selectedIndex: 0)
            }
            return
        }

        guard windows.count >= 2 else {
            // With nothing to cycle, repeat presses become a show/hide toggle.
            app.hide()
            lastWindowID.removeValue(forKey: bundleIdentifier)
            return
        }

        // Repeat press: advance from whatever window is focused now (falling back to our last
        // remembered index), then raise the next one.
        let remembered = lastWindowID[bundleIdentifier].flatMap { rememberedID in
            windows.firstIndex { $0.windowID == rememberedID }
        }
        let current = Self.indexOfMain(in: windows) ?? remembered
        guard let nextIdx = WindowCycle.next(count: windows.count, current: current, direction: direction) else { return }
        let targetWindow = windows[nextIdx]
        let tilesOwnsFeedback: Bool
        if windowRouting == nil {
            Self.activate(targetWindow.app)
            Self.raise(targetWindow.element)
            tilesOwnsFeedback = false
        } else {
            tilesOwnsFeedback = Self.activateRoutedWindow(targetWindow)
        }
        lastWindowID[bundleIdentifier] = targetWindow.windowID
        if !tilesOwnsFeedback {
            Self.showWindowHUD(targetWindow.app, windows: windows, selectedIndex: nextIdx)
        }
    }

    /// Cycle between the running members of an app group. A multi-app shortcut still means
    /// "switch apps"; routing only chooses which window to raise after the app member is chosen.
    func engageGroup(bundleIdentifiers: [String],
                     direction: WindowCycle.Direction = .forward,
                     windowRouting: CyclerWindowRouting? = nil) {
        guard bundleIdentifiers.count > 1 else {
            if let bundleIdentifier = bundleIdentifiers.first {
                engage(bundleIdentifier: bundleIdentifier, direction: direction,
                       windowRouting: windowRouting)
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
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            guard let app = apps.first else { return }
            var tilesOwnsFeedback = false
            if let windowRouting {
                var allWindows = Self.allWindows(of: apps, using: windowRouting)
                if allWindows.isEmpty, app.isHidden {
                    // Publish AXWindows without activating an arbitrary main window first.
                    app.unhide()
                    allWindows = Self.allWindows(of: apps, using: windowRouting)
                }
                let selection = Self.candidateSelection(from: allWindows, using: windowRouting)
                if !selection.windows.isEmpty {
                    let targetIndex = Self.indexOfMain(in: selection.windows) ?? 0
                    let targetWindow = selection.windows[targetIndex]
                    tilesOwnsFeedback = Self.activateRoutedWindow(targetWindow)
                } else if let message = selection.unavailableMessage {
                    CycleHUD.shared.showBlocked(message)
                    return
                } else if allWindows.isEmpty {
                    Self.activate(app)
                }
            } else {
                Self.activate(app)
            }
            if !tilesOwnsFeedback { Self.showGroupHUD(display) }
        case .hide(let bundleIdentifier):
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            guard let app = apps.first else { return }
            if let windowRouting {
                let allWindows = Self.allWindows(of: apps, using: windowRouting)
                let selection = Self.candidateSelection(from: allWindows, using: windowRouting)
                // A frontmost process can have every managed window staged in an inactive Tiles
                // workspace. In that state the group key means return to the app's workspace,
                // not hide the already windowless process.
                if !selection.windows.isEmpty, !selection.hasCurrentCandidates {
                    let targetIndex = Self.indexOfMain(in: selection.windows) ?? 0
                    let tilesOwnsFeedback = Self.activateRoutedWindow(selection.windows[targetIndex])
                    if !tilesOwnsFeedback { Self.showGroupHUD(display) }
                    return
                }
                if selection.windows.isEmpty, !allWindows.isEmpty,
                   let message = selection.unavailableMessage {
                    CycleHUD.shared.showBlocked(message)
                    return
                }
            }
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
        /// Captured while enumerating the AX windows. Routed Cycler selection must not ask AX
        /// again just to decide whether a current-context window is a minimized fallback.
        var isMinimized: Bool
        /// Captured once during enumeration. Besides avoiding a second synchronous Tiles lookup,
        /// this proves that a transient nonstandard AX window was already managed by Tiles.
        var route: CyclerWindowRoute?
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
        windows(of: apps, includeMinimized: false, windowRouting: nil)
    }

    private static func allWindows(of apps: [NSRunningApplication],
                                   using windowRouting: CyclerWindowRouting) -> [WindowRecord] {
        windows(of: apps, includeMinimized: true, windowRouting: windowRouting)
    }

    private static func windows(of apps: [NSRunningApplication],
                                includeMinimized: Bool,
                                windowRouting: CyclerWindowRouting?) -> [WindowRecord] {
        apps
            .flatMap { app in
                windows(of: axApplication(app.processIdentifier), app: app,
                        includeMinimized: includeMinimized, windowRouting: windowRouting)
            }
            .sorted { lhs, rhs in lhs.windowID < rhs.windowID }
    }

    private static func windows(of axApp: AXUIElement,
                                app: NSRunningApplication,
                                includeMinimized: Bool,
                                windowRouting: CyclerWindowRouting?) -> [WindowRecord] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
            .map { tame($0) }
            .compactMap { window in
                // Ask Tiles only about windows that can become Cycler candidates. Most AX
                // applications expose transient menus, sheets and other non-window elements in
                // AXWindows; routing each one synchronously crossed both the AX and Tiles worker
                // queues from the main actor before we discarded it below.
                let standard = isStandardWindow(window)
                let minimized = isMinimized(window)
                guard standard || (minimized && hasWindowRole(window)) else { return nil }
                guard includeMinimized || !minimized else { return nil }
                // Capture the route once with the filtered window snapshot. CandidateSelection
                // and every later activation reuse this value, so a Cycler press never repeats
                // the cross-queue lookup for the same AX element.
                let route = windowRouting?.route(window)
                if !standard {
                    guard let route, route.context != .unmanaged else { return nil }
                }
                guard let windowID = windowID(of: window) else { return nil }
                return WindowRecord(app: app, element: window, windowID: windowID,
                                    isMinimized: minimized, route: route)
            }
    }

    private struct CandidateSelection {
        var windows: [WindowRecord]
        var hasCurrentCandidates: Bool
        var unavailableMessage: String?
    }

    /// Current-context and freeform windows cycle in stable CGWindowID order. When none exist,
    /// one inactive target wins by most recent Tiles focus, then by the same stable ID order.
    private static func candidateSelection(from windows: [WindowRecord],
                                           using windowRouting: CyclerWindowRouting?) -> CandidateSelection {
        guard windowRouting != nil else {
            return CandidateSelection(windows: windows,
                                      hasCurrentCandidates: !windows.isEmpty,
                                      unavailableMessage: nil)
        }
        let selection = WindowRoutingSelector.select(windows.map { window in
            let disposition: WindowRoutingDisposition
            switch window.route?.context {
            case .currentContext: disposition = .currentContext
            case .unmanaged: disposition = .unmanaged
            case .inactiveWorkspace(let workspace, let focusEpoch):
                disposition = .inactiveWorkspace(workspace: workspace, focusEpoch: focusEpoch)
            case .unavailable(let message): disposition = .unavailable(message: message)
            case nil: disposition = .unavailable(message: "Window routing is unavailable.")
            }
            return WindowRoutingCandidate(windowID: window.windowID,
                                          isMinimized: window.isMinimized,
                                          disposition: disposition)
        })
        return CandidateSelection(windows: selection.indices.map { windows[$0] },
                                  hasCurrentCandidates: selection.hasCurrentCandidates,
                                  unavailableMessage: selection.unavailableMessage)
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
            return WindowRecord(app: app, element: window,
                                windowID: windowID(of: window) ?? CGWindowID(0),
                                isMinimized: true, route: nil)
        }
        return nil
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == kAXStandardWindowSubrole as String
    }

    private static func hasWindowRole(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return false }
        return role == kAXWindowRole as String
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

    /// Establish the routed target before bringing its app forward. This prevents activating an
    /// unrelated main window from briefly sending Tiles through another workspace first.
    @discardableResult
    private static func activateRoutedWindow(_ window: WindowRecord) -> Bool {
        // Tiles owns an inactive managed window's whole transition, including AX restore and focus.
        // Queue that explicit intent instead of racing it with a direct raise on the main actor.
        if case .inactiveWorkspace = window.route?.context {
            if window.app.isHidden { window.app.unhide() }
            if window.route?.activateIfInactive() == true { return true }
        }
        if window.app.isHidden { window.app.unhide() }
        raise(window.element)
        window.app.activate(options: [])
        raise(window.element)
        return false
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
