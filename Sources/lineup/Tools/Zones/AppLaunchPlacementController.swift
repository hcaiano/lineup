import AppKit
import ApplicationServices
import ZonesCore

/// Watches only new launches with a saved destination. The AX observer is removed before
/// the first regular window is moved; it never observes movement or enforces a position.
@MainActor
final class AppLaunchPlacementController {
    private let placement: (String) -> AppZonePlacement?
    private let restore: (AXUIElement, AppZonePlacement) -> Void
    private var sessions = ZoneLaunchRestoration()
    private var workspaceObservers: [NSObjectProtocol] = []
    private struct Watch {
        let app: AXUIElement
        let observer: AXObserver?
        var initialProbes = 0
    }
    private var watches: [pid_t: Watch] = [:]
    private var initialProbeTimer: Timer?

    init(placement: @escaping (String) -> AppZonePlacement?,
         restore: @escaping (AXUIElement, AppZonePlacement) -> Void) {
        self.placement = placement
        self.restore = restore
    }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        sessions = ZoneLaunchRestoration(runningProcesses: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                      object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.launched(app) }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                      object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.cancel(app.processIdentifier)
                self?.sessions.terminated(app.processIdentifier)
            }
        })
    }

    func stop() {
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        for pid in Array(watches.keys) { cancel(pid) }
        initialProbeTimer?.invalidate()
        initialProbeTimer = nil
        sessions = ZoneLaunchRestoration()
    }

    /// Explicit placement wins over any launch still waiting for its first regular window.
    func cancel(_ pid: pid_t) {
        sessions.cancel(pid)
        if let watch = watches.removeValue(forKey: pid), let observer = watch.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if !watches.values.contains(where: { $0.initialProbes < 20 }) {
            initialProbeTimer?.invalidate()
            initialProbeTimer = nil
        }
    }

    private func launched(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleID = application.bundleIdentifier,
              sessions.launched(process: application.processIdentifier, placement: placement(bundleID),
                                accessibilityTrusted: AXIsProcessTrusted()) else { return }
        let pid = application.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var observer: AXObserver?
        if AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<AppLaunchPlacementController>.fromOpaque(context).takeUnretainedValue()
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success else { return }
                controller.inspect(pid, created: (notification as String) == kAXWindowCreatedNotification ? element : nil)
            }
        }, &observer) == .success, let candidate = observer {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let created = AXObserverAddNotification(candidate, app, kAXWindowCreatedNotification as CFString, context)
            let focused = AXObserverAddNotification(candidate, app, kAXFocusedWindowChangedNotification as CFString, context)
            if created == .success || focused == .success {
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate), .commonModes)
            } else {
                observer = nil
            }
        }
        watches[pid] = Watch(app: app, observer: observer)
        inspect(pid)
        // Some apps expose their AX windows just after the workspace launch notification.
        // Bounded discovery covers this race and apps without notifications. Once settled,
        // an installed observer can wait for a delayed first document without polling.
        if watches[pid] != nil, initialProbeTimer == nil {
            initialProbeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.probeInitialWindows() }
            }
        }
    }

    private func probeInitialWindows() {
        for pid in Array(watches.keys) {
            guard let watch = watches[pid], watch.initialProbes < 20 else { continue }
            watches[pid]?.initialProbes += 1
            inspect(pid)
            if let current = watches[pid], current.initialProbes >= 20, current.observer == nil {
                cancel(pid)
            }
        }
        if !watches.values.contains(where: { $0.initialProbes < 20 }) {
            initialProbeTimer?.invalidate()
            initialProbeTimer = nil
        }
    }

    private func inspect(_ pid: pid_t, created: AXUIElement? = nil) {
        guard let watch = watches[pid], sessions.isPending(pid) else { return }
        guard AXIsProcessTrusted() else { cancel(pid); return }
        var windows: [AXUIElement] = []
        if let created { windows.append(created) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(watch.app, kAXWindowsAttribute as CFString, &value)
        if result == .success, let list = value as? [AXUIElement] { windows += list }
        // An unresponsive or dead process must not stall the menu bar on every timer tick.
        if result == .cannotComplete || result == .invalidUIElement { cancel(pid); return }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.25)
            guard isRegular(window) else { continue }
            guard let target = sessions.firstWindow(process: pid, isRegular: true,
                                                     accessibilityTrusted: AXIsProcessTrusted()) else { cancel(pid); return }
            cancel(pid)
            restore(window, target)
            return
        }
    }

    private func isRegular(_ window: AXUIElement) -> Bool {
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success else { return nil }
            return value
        }
        guard attribute(kAXRoleAttribute) as? String == kAXWindowRole,
              attribute(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              attribute(kAXModalAttribute) as? Bool == false else { return false }
        return attribute(kAXMinimizedAttribute) as? Bool != true
            && attribute("AXFullScreen") as? Bool != true
    }
}
