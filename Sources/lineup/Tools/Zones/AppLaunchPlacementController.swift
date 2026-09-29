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
    private var watches: [pid_t: LaunchWindowWatch] = [:]

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
        sessions = ZoneLaunchRestoration()
    }

    /// Explicit placement wins over any launch still waiting for its first regular window.
    func cancel(_ pid: pid_t) {
        sessions.cancel(pid)
        watches.removeValue(forKey: pid)?.cancel()
    }

    private func launched(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier,
              let bundleID = application.bundleIdentifier,
              sessions.launched(process: application.processIdentifier, placement: placement(bundleID),
                                accessibilityTrusted: AXIsProcessTrusted()) else { return }
        let pid = application.processIdentifier
        let watch = LaunchWindowWatch(pid: pid) { [weak self] watch, window in
            guard let self, self.watches[pid] === watch else { return }
            let target = self.sessions.firstWindow(process: pid)
            self.cancel(pid)
            guard AXIsProcessTrusted(), let window, let target else { return }
            self.restore(window, target)
        }
        watches[pid] = watch
        watch.start()
    }
}

/// AX messaging stays on a per-launch queue. The main run loop only delivers notifications;
/// it also hosts Hyperkey's event tap and must never wait for a launching app to answer AX.
private final class LaunchWindowWatch {
    private let pid: pid_t
    private let queue: DispatchQueue
    private let completion: @MainActor (LaunchWindowWatch, AXUIElement?) -> Void
    private let lock = NSLock()
    // These two fields are shared with main-run-loop cancellation and observer installation.
    private var cancelled = false
    private var observer: AXObserver?
    // Remaining state belongs exclusively to queue.
    private lazy var app = AXUIElementCreateApplication(pid)
    private var deadline: TimeInterval = 0
    private var retryDelay: TimeInterval = 0.25
    private var unresolvedList = false
    private enum DiscoveryError: Error { case unreadableWindow }

    init(pid: pid_t, completion: @escaping @MainActor (LaunchWindowWatch, AXUIElement?) -> Void) {
        self.pid = pid
        self.completion = completion
        queue = DispatchQueue(label: "com.caiano.lineup.launch-discovery.\(pid)", qos: .utility)
    }

    func start() {
        queue.async { [self] in
            deadline = ProcessInfo.processInfo.systemUptime + 5
            AXUIElementSetMessagingTimeout(app, 0.25)
            probe()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let previous = observer
        observer = nil
        if let previous {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(previous), .commonModes)
        }
        lock.unlock()
        // Releasing the observer may unregister remote notifications. Keep that off main too.
        queue.async { withExtendedLifetime(previous) {} }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var isObserving: Bool { lock.lock(); defer { lock.unlock() }; return observer != nil }

    private func probe() {
        guard !isCancelled else { return }
        guard AXIsProcessTrusted() else { finish(nil); return }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            if !isObserving || unresolvedList { finish(nil) }
            return
        }
        if !isObserving { installObserver() }
        inspect()
        guard !isCancelled else { return }
        queue.asyncAfter(deadline: .now() + retryDelay) { [self] in probe() }
    }

    private func installObserver() {
        var candidate: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let watch = Unmanaged<LaunchWindowWatch>.fromOpaque(context).takeUnretainedValue()
            let created = (notification as String) == kAXWindowCreatedNotification ? element : nil
            watch.queue.async { watch.inspect(created: created) }
        }, &candidate) == .success, let candidate else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let created = AXObserverAddNotification(candidate, app, kAXWindowCreatedNotification as CFString, context)
        guard !isCancelled else { return }
        let focused = AXObserverAddNotification(candidate, app, kAXFocusedWindowChangedNotification as CFString, context)
        guard created == .success || focused == .success else {
            retryDelay = min(retryDelay * 2, 1)
            return
        }
        lock.lock()
        if !cancelled {
            observer = candidate
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate), .commonModes)
        }
        lock.unlock()
    }

    private func inspect(created: AXUIElement? = nil) {
        guard !isCancelled else { return }
        guard AXIsProcessTrusted() else { finish(nil); return }
        do {
            let window = try LaunchWindowEligibility.firstEligible(notified: created, windows: { [self] in
                guard !isCancelled else { return [] }
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                guard result == .success, let windows = value as? [AXUIElement] else {
                    unresolvedList = true
                    retryDelay = min(retryDelay * 2, 1)
                    if result == .invalidUIElement || ProcessInfo.processInfo.systemUptime >= deadline { finish(nil) }
                    return []
                }
                unresolvedList = false
                return windows
            }, isEligible: isRegular)
            if let window { finish(window) }
        } catch {
            // An unreadable window may be the first document. Do not leave a pending restore
            // that a later document or focus change could consume instead.
            finish(nil)
        }
    }

    private func finish(_ window: AXUIElement?) {
        guard !isCancelled else { return }
        cancel()
        DispatchQueue.main.async { [self] in completion(self, window) }
    }

    private func isRegular(_ window: AXUIElement) throws -> Bool {
        guard !isCancelled else { return false }
        AXUIElementSetMessagingTimeout(window, 0.25)
        func attribute(_ name: String, optional: Bool = false) throws -> CFTypeRef? {
            guard !isCancelled else { return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, name as CFString, &value)
            if optional && (result == .attributeUnsupported || result == .noValue) { return nil }
            guard result == .success else { throw DiscoveryError.unreadableWindow }
            return value
        }
        let role = try attribute(kAXRoleAttribute) as? String
        let subrole = try attribute(kAXSubroleAttribute) as? String
        guard let role, let subrole else { throw DiscoveryError.unreadableWindow }
        // Avoid optional attribute queries for a known panel or sheet.
        guard LaunchWindowEligibility.isEligible(role: role, subrole: subrole, modal: nil,
                                                 minimized: nil, fullscreen: nil) else { return false }
        return try LaunchWindowEligibility.isEligible(
            role: role, subrole: subrole,
            modal: attribute(kAXModalAttribute, optional: true) as? Bool,
            minimized: attribute(kAXMinimizedAttribute, optional: true) as? Bool,
            fullscreen: attribute("AXFullScreen", optional: true) as? Bool)
    }
}
