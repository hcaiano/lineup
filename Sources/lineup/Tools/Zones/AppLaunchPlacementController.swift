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
        var observer: AXObserver?
        let probeDeadline: TimeInterval
        var isProbing: Bool { ProcessInfo.processInfo.systemUptime < probeDeadline }
    }
    private var watches: [pid_t: Watch] = [:]
    private var initialProbeTimer: Timer?
    private let probeInterval: TimeInterval = 0.25
    private let initialProbeDuration: TimeInterval = 5

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
        if !watches.values.contains(where: { $0.isProbing }) {
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
        watches[pid] = Watch(app: app, observer: makeObserver(pid, app: app),
                             probeDeadline: ProcessInfo.processInfo.systemUptime + initialProbeDuration)
        inspect(pid)
        // Some apps expose their AX windows just after the workspace launch notification.
        // Bounded discovery covers this race and apps without notifications. Once settled,
        // an installed observer can wait for a delayed first document without polling.
        if watches[pid] != nil, initialProbeTimer == nil {
            initialProbeTimer = Timer.scheduledTimer(withTimeInterval: probeInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.probeInitialWindows() }
            }
        }
    }

    private func makeObserver(_ pid: pid_t, app: AXUIElement) -> AXObserver? {
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
        return observer
    }

    private func probeInitialWindows() {
        for pid in Array(watches.keys) {
            guard let watch = watches[pid] else { continue }
            guard watch.isProbing else {
                if watch.observer == nil { cancel(pid) }
                continue
            }
            if watch.observer == nil { watches[pid]?.observer = makeObserver(pid, app: watch.app) }
            inspect(pid)
            if let current = watches[pid], !current.isProbing, current.observer == nil {
                cancel(pid)
            }
        }
        if !watches.values.contains(where: { $0.isProbing }) {
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
        // Startup can temporarily time out. Retry discovery only within the bounded probe window.
        if result == .invalidUIElement { cancel(pid); return }
        if result == .cannotComplete {
            if !watch.isProbing { cancel(pid) }
            return
        }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.25)
            guard isRegular(window) else { continue }
            guard let target = sessions.firstWindow(process: pid) else { cancel(pid); return }
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
        return LaunchWindowEligibility.isEligible(
            role: attribute(kAXRoleAttribute) as? String,
            subrole: attribute(kAXSubroleAttribute) as? String,
            modal: attribute(kAXModalAttribute) as? Bool,
            minimized: attribute(kAXMinimizedAttribute) as? Bool,
            fullscreen: attribute("AXFullScreen") as? Bool)
    }
}
