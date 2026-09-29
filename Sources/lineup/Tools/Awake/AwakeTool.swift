import AppKit
import AppCore
import SwiftUI

@MainActor
final class AwakeTool: Tool, ObservableObject {
    let id = ToolID.awake
    let displayName = "Keep Awake"
    let summary = "Keep your Mac awake for a timed session."
    let iconSymbol = "sun.max"
    let requiredPermissions: Set<Permission> = []
    let defaultEnabled = false

    @Published private(set) var isRunning = false
    @Published private(set) var settings = AwakeSettings()
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var message: String?
    @Published private(set) var configError: String?
    private let session = AwakeSession(power: AwakePowerController())
    private var services: ToolServices?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var countdownItem: NSMenuItem?
    private weak var stopItem: NSMenuItem?
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now

    var isActive: Bool { session.isActive }
    var canEdit: Bool { configError == nil && services?.config.canWrite == true }
    var statusText: String {
        guard isActive else { return "No active session" }
        return "Awake · \(remainingSeconds / 60):\(String(format: "%02d", remainingSeconds % 60)) remaining"
    }
    private var now: TimeInterval {
        let parts = origin.duration(to: clock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            settings = try services.config.load(AwakeSettings.self) ?? AwakeSettings()
            configError = services.config.blockedMessage
        } catch {
            configError = "Keep Awake settings could not be read. They were left untouched."
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        attach(services)
        isRunning = true
        services.termination.addCleanup(id) { [weak self] in self?.stopSession() }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSession() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
    }

    func stop() {
        stopSession()
        isRunning = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        services?.termination.removeCleanup(id)
    }

    func startSession(minutes: Int? = nil) {
        guard isRunning, canEdit else { return }
        if let minutes, !savePreferences({ $0.durationMinutes = minutes }) { return }
        message = nil
        do {
            try session.start(duration: TimeInterval(settings.durationMinutes * 60),
                              keepDisplayOn: settings.keepDisplayOn, now: now)
            startTimer()
        } catch {
            message = "The session could not start. \(error.localizedDescription) Try again."
        }
        updateState()
    }

    func stopSession() {
        session.cancel()
        message = nil
        updateState()
    }

    func setDuration(_ minutes: Int) {
        guard savePreferences({ $0.durationMinutes = minutes }) else { return }
        if isActive { startSession() }
        else { updateState() }
    }

    func setDisplayOn(_ enabled: Bool) {
        guard savePreferences({ $0.keepDisplayOn = enabled }) else { return }
        message = nil
        do { try session.setDisplayOn(enabled, now: now) }
        catch { message = "The session could not start. \(error.localizedDescription) Try again." }
        updateState()
    }

    private func savePreferences(_ edit: (inout AwakeSettings) -> Void) -> Bool {
        guard canEdit, let services else { return false }
        var proposed = settings
        edit(&proposed)
        guard AwakeSettings.durations.contains(proposed.durationMinutes) else { return false }
        do {
            try services.config.save(proposed)
            settings = proposed
            message = nil
            return true
        } catch {
            message = "Keep Awake settings could not be saved. Your previous settings are still in use."
            services.refreshMenu()
            return false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        // Countdown and expiration must also run while the menu tracks the pointer.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let wasActive = isActive
        session.expire(now: now)
        updateState(refreshMenu: wasActive != isActive)
    }

    private func updateState(refreshMenu: Bool = true) {
        remainingSeconds = Int(ceil(session.remaining(now: now)))
        if !isActive { timer?.invalidate(); timer = nil }
        countdownItem?.title = statusText
        stopItem?.isEnabled = isActive
        if let menu = countdownItem?.menu,
           let parent = menu.supermenu?.items.first(where: { $0.submenu === menu }) {
            parent.title = isActive ? "Keep Awake · Active" : displayName
        }
        if refreshMenu { services?.refreshMenu() }
    }

    var warnings: [ToolWarning] {
        [configError, message].compactMap { text in
            text.map { ToolWarning(id: "awake", text: $0) }
        }
    }

    func menuItems() -> [NSMenuItem] {
        let status = ToolMenu.info(statusText)
        countdownItem = status
        var items = [status]
        for minutes in AwakeSettings.durations {
            let item = ToolMenu.item("\(isActive ? "Restart" : "Start") for \(AwakeSettings.durationLabel(minutes))",
                                     symbol: "timer") { [weak self] in self?.startSession(minutes: minutes) }
            item.isEnabled = canEdit
            items.append(item)
        }
        items.append(.separator())
        let display = ToolMenu.item("Keep display on", symbol: "display") { [weak self] in
            guard let self else { return }
            self.setDisplayOn(!self.settings.keepDisplayOn)
        }
        display.state = settings.keepDisplayOn ? .on : .off
        display.isEnabled = canEdit
        items.append(display)
        let stop = ToolMenu.item("Stop Keep Awake", symbol: "stop.circle") { [weak self] in self?.stopSession() }
        stop.isEnabled = isActive
        stopItem = stop
        items.append(stop)
        return items
    }

    func makeSettingsPane() -> AnyView { AnyView(AwakeSettingsPane(tool: self)) }
}
