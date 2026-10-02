import AppKit
import AppCore
import ScrollCore
import SwiftUI

/// Reverses mouse and trackpad scrolling independently, on top of the single macOS direction.
///
/// Off by default: a silent update must never change how the user's scrolling behaves. The tap is
/// installed only while the tool runs with something to reverse and Accessibility is granted;
/// every other state leaves scrolling exactly as macOS delivers it.
@MainActor
final class ScrollTool: Tool, ObservableObject {
    enum State: Equatable {
        case off
        /// Running with no device or direction selected, so nothing is intercepted.
        case idle
        case active
        case needsAccessibility
        /// Accessibility is granted but macOS still refused the event tap.
        case refused
        /// The private HID interface that identifies devices is missing on this macOS.
        case unsupported
    }

    let id = ToolID.scroll
    var displayName: String { id.displayName }
    let summary = "Reverse mouse and trackpad scrolling separately."
    let iconSymbol = "arrow.up.arrow.down"
    let requiredPermissions: Set<Permission> = [.accessibility]
    let defaultEnabled = false

    @Published private(set) var isRunning = false
    @Published private(set) var settings = ScrollSettings()
    @Published private(set) var state = State.off
    @Published private(set) var sectionUnreadable = false
    @Published private(set) var message: String?
    @Published private(set) var systemUsesNaturalScrolling = true

    private let tap = ScrollEventTap()
    private var services: ToolServices?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var permissionTimer: Timer?

    var canEdit: Bool { !sectionUnreadable && services?.config.canWrite == true }
    var blockedMessage: String? {
        sectionUnreadable
            ? "Scroll settings could not be read. They were left untouched, and scrolling keeps the macOS direction. Repair the scroll section in config.json and restart Lineup."
            : services?.config.blockedMessage
    }

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            settings = try services.config.load(ScrollSettings.self) ?? ScrollSettings()
            sectionUnreadable = false
        } catch {
            settings = ScrollSettings()
            sectionUnreadable = true
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        attach(services)
        isRunning = true
        services.termination.addCleanup(id) { [weak self] in self?.tap.stop() }
        // Grants and revocations post this notification; sleep can disable the tap; returning
        // from System Settings is when a fresh grant usually becomes visible.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api"),
                recheckAfter: 1)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        observe(.default, NSApplication.didBecomeActiveNotification)
        reconcile()
    }

    func stop() {
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        services?.termination.removeCleanup(id)
        reconcile()
    }

    /// `recheckAfter` covers a trust change that the notification announces before
    /// `AXIsProcessTrusted()` reports it.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         recheckAfter delay: TimeInterval? = nil) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
            guard let delay else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.reconcile() }
            }
        }
        observers.append((center, token))
    }

    /// Brings the tap in line with the running flag, settings and permission. Safe to repeat.
    func reconcile() {
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        if natural != systemUsesNaturalScrolling { systemUsesNaturalScrolling = natural }
        let reversal = sectionUnreadable ? ScrollReversal() : settings.reversal
        tap.setReversal(reversal)
        let next: State
        if !isRunning {
            next = .off
        } else if reversal.isEmpty {
            next = .idle
        } else if services?.permissions.isAccessibilityTrusted != true {
            next = .needsAccessibility
        } else {
            do {
                try tap.start()
                next = .active
            } catch ScrollEventTap.StartFailure.unsupported {
                next = .unsupported
            } catch {
                next = .refused
            }
        }
        if next != .active { tap.stop() }
        // Grants are also checked on a light timer: the notification is not always delivered.
        if next == .needsAccessibility, permissionTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcile() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        } else if next != .needsAccessibility {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
        guard next != state else { return }
        state = next
        services?.refreshMenu()
        services?.refreshSettings()
    }

    // MARK: - Settings

    func setReverseMouse(_ on: Bool) { save { $0.reverseMouse = on } }
    func setReverseTrackpad(_ on: Bool) { save { $0.reverseTrackpad = on } }
    func setReverseVertical(_ on: Bool) { save { $0.reverseVertical = on } }
    func setReverseHorizontal(_ on: Bool) { save { $0.reverseHorizontal = on } }

    private func save(_ edit: (inout ScrollSettings) -> Void) {
        guard canEdit, let services else { return }
        var proposed = settings
        edit(&proposed)
        guard proposed != settings else { return }
        do {
            try services.config.save(proposed)
            settings = proposed
            message = nil
        } catch {
            message = "Scroll settings could not be saved. Your previous settings are still in use."
        }
        reconcile()
        services.refreshMenu()
    }

    func openAccessibilitySettings() {
        services?.permissions.openAccessibilitySettings()
    }

    // MARK: - Menu

    func menuItems() -> [NSMenuItem] {
        let mouse = ToolMenu.item("Reverse mouse", symbol: "computermouse") { [weak self] in
            guard let self else { return }
            self.setReverseMouse(!self.settings.reverseMouse)
        }
        mouse.state = settings.reverseMouse ? .on : .off
        let trackpad = ToolMenu.item("Reverse trackpad", symbol: "rectangle.and.hand.point.up.left") { [weak self] in
            guard let self else { return }
            self.setReverseTrackpad(!self.settings.reverseTrackpad)
        }
        trackpad.state = settings.reverseTrackpad ? .on : .off
        for item in [mouse, trackpad] { item.isEnabled = canEdit }
        return [mouse, trackpad]
    }

    /// Missing Accessibility is already the shell's warning at the top of the menu.
    var warnings: [ToolWarning] {
        var out: [ToolWarning] = []
        if let text = sectionUnreadable ? "⚠︎ Scroll settings couldn’t be read" : message {
            out.append(ToolWarning(id: "scroll.config", text: text))
        }
        switch state {
        case .refused:
            out.append(ToolWarning(id: "scroll.blocked", text: "⚠︎ macOS blocked Scroll",
                                   detailLines: ["Scrolling keeps the macOS direction."],
                                   actionTitle: "Try Again",
                                   action: { [weak self] in self?.reconcile() }))
        case .unsupported:
            out.append(ToolWarning(id: "scroll.unsupported",
                                   text: "⚠︎ Scroll can’t identify devices on this macOS version"))
        default:
            break
        }
        return out
    }

    func makeSettingsPane() -> AnyView { AnyView(ScrollSettingsPane(tool: self)) }
}
