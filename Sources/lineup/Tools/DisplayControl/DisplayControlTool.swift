import AppKit
import AppCore
import Carbon.HIToolbox
import DisplayControlCore
import SwiftUI

/// A write holds this lock until it finishes. Stop and connection changes invalidate queued work
/// immediately, and wait for a write already in progress before returning.
private final class DisplayWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()

    func replace(_ generation: UUID) {
        lock.lock()
        self.generation = generation
        lock.unlock()
    }

    func accepts(_ generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    func write<T>(_ generation: UUID, _ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return nil }
        return body()
    }
}

@MainActor
final class DisplayControlTool: NSObject, ObservableObject, Tool {
    let id = ToolID.displayControl
    let displayName = "Display Control"
    let summary = "Adjust brightness and volume on your displays."
    let iconSymbol = "display"
    let defaultEnabled = false
    var requiredPermissions: Set<Permission> {
        settings.brightnessKeys || settings.volumeKeys ? [.accessibility] : []
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var monitors: [DisplayControlMonitor] = []
    @Published private(set) var settings = DisplayControlSettings()
    @Published private(set) var configError: String?
    @Published private(set) var keyMessage: String?
    @Published private(set) var saveError: String?
    @Published private(set) var keyFailure: String?
    @Published private(set) var blackScreenMessage: String?
    @Published private(set) var connectionDescriptions: [UUID: String] = [:]

    private var services: ToolServices?
    private var session = DisplayControlSession()
    private let transport = DisplayTransport()
    private let queue = DispatchQueue(label: "com.caiano.lineup.display-control", qos: .userInitiated)
    private let gate = DisplayWriteGate()
    private var displayConnections: [CGDirectDisplayID: UUID] = [:]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshTimer: Timer?
    private var refreshingGeneration: UUID?
    private var asleep = false
    private var draining = false
    private var unmuteLevels: [UUID: Double] = [:]
    private var heldKeyConnections: [MediaKeyAction: (connection: UUID, generation: UUID)] = [:]
    private var heldBrightnessGroups: [MediaKeyAction: DisplayBrightnessGroup] = [:]
    private let keyboardHUD = DisplayControlHUD()
    private var keyboardFeedback: [UUID: (control: DisplayControl, generation: UUID)] = [:]
    private let blackScreen = DisplayBlackScreen()
    private var blackScreenEscape: HotkeyManager.Token?
    private var blackScreenTimer: Timer?
    private var visibleBlackedOutConnections: Set<UUID> = []

    var canEdit: Bool { configError == nil && services?.config.canWrite == true }

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            settings = try services.config.load(DisplayControlSettings.self) ?? DisplayControlSettings()
            configError = services.config.blockedMessage
        } catch {
            configError = "Display Control settings could not be read. They were left untouched."
            settings = DisplayControlSettings()
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        attach(services)
        isRunning = true
        asleep = false
        session.start()
        gate.replace(session.generation)
        services.termination.addCleanup(id) { [weak self] in self?.stop() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.rediscover() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { tool in
            tool.asleep = true
            tool.invalidateConnections()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { tool in
            tool.asleep = false
            tool.rediscover()
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { $0.refreshReadings() }
        // Refresh levels changed by the monitor's own buttons without reapplying preferences.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReadings() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        configureKeys()
        rediscover()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cancelKeyboardFeedback()
        clearBlackScreenWindows()
        services?.mediaKeys.unregisterAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshingGeneration = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        session.stop()
        gate.replace(session.generation)
        draining = false
        monitors = []
        displayConnections = [:]
        connectionDescriptions = [:]
        unmuteLevels = [:]
        heldKeyConnections = [:]
        heldBrightnessGroups = [:]
        isDiscovering = false
        keyMessage = nil
        keyFailure = nil
        blackScreenMessage = nil
        queue.async { [transport] in transport.invalidate() }
        services?.hotkeys.unregisterAll()
        services?.termination.removeCleanup(id)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (DisplayControlTool) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                action(self)
            }
        }
        observers.append((center, observer))
    }

    private func invalidateConnections() {
        cancelKeyboardFeedback()
        clearBlackScreenWindows()
        refreshingGeneration = nil
        session.replaceDisplays([])
        gate.replace(session.generation)
        monitors = []
        displayConnections = [:]
        connectionDescriptions = [:]
        unmuteLevels = [:]
        heldKeyConnections = [:]
        heldBrightnessGroups = [:]
        draining = false
        isDiscovering = false
        queue.async { [transport] in transport.invalidate() }
    }

    func rediscover() {
        guard isRunning, !asleep else { return }
        invalidateConnections()
        isDiscovering = true
        keyMessage = nil
        let generation = session.generation
        queue.async { [transport, gate, weak self] in
            guard gate.accepts(generation) else { return }
            let found = transport.discover()
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.session.generation == generation else { return }
                self.session.replaceDisplays(found.map(\.monitor))
                self.gate.replace(self.session.generation)
                self.displayConnections = Dictionary(uniqueKeysWithValues: found.map { ($0.displayID, $0.monitor.connection) })
                self.connectionDescriptions = Dictionary(uniqueKeysWithValues: found.map { ($0.monitor.connection, $0.connectionDescription) })
                self.isDiscovering = false
                self.publish()
            }
        }
    }

    func setLevel(_ value: Double, connection: UUID, control: DisplayControl) {
        guard isRunning, !asleep else { return }
        if control == .brightness { session.restoreBrightnessVisibility(connection: connection) }
        cancelKeyboardRequests(preservingBlackScreens: true)
        guard session.enqueueAfterReading(connection: connection, control: control, normalizedValue: value) else {
            publish()
            return
        }
        keyMessage = nil
        publish()
        drain()
    }

    func requestedLevel(connection: UUID, control: DisplayControl) -> Double? {
        session.requestedLevel(connection: connection, control: control)
    }

    private func drain() {
        guard !draining else { return }
        guard let command = session.nextCommand(), session.canSend(command) else {
            if session.hasDeferredRequests { refreshReadings() }
            return
        }
        draining = true
        queue.async { [transport, gate, weak self] in
            guard let sent = gate.write(command.generation, {
                transport.write(command.value, control: command.control, connection: command.connection)
            }) else { return }
            let outcome: DisplayControlWriteOutcome
            switch sent {
            case .failure(let error): outcome = .failed(error.localizedDescription)
            case .success:
                guard gate.accepts(command.generation) else { return }
                // Successful transmission does not confirm a level. Only a hardware read does.
                switch transport.read(command.control, connection: command.connection) {
                case .success(let reading): outcome = .confirmed(reading)
                case .failure(let error): outcome = .failed("The value could not be confirmed. \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self, self.session.generation == command.generation else { return }
                self.draining = false
                _ = self.session.finish(command, outcome: outcome)
                self.publish()
                if let feedback = self.keyboardFeedback[command.connection],
                   feedback.control == command.control,
                   feedback.generation == command.generation {
                    self.updateKeyboardFeedback(connections: [command.connection])
                }
                self.drain()
            }
        }
    }

    func refreshReadings() {
        guard isRunning, !asleep, !isDiscovering, !draining else { return }
        let generation = session.generation
        guard refreshingGeneration != generation else { return }
        refreshingGeneration = generation
        let requests = monitors.flatMap { monitor in
            DisplayControl.allCases.filter { monitor[$0].isSupported }.map { (monitor.connection, $0) }
        }
        queue.async { [transport, gate, weak self] in
            var readings: [(connection: UUID, control: DisplayControl,
                            result: Result<DisplayControlLevel, DisplayTransportFailure>)] = []
            for (connection, control) in requests {
                guard gate.accepts(generation) else { return }
                readings.append((connection, control, transport.read(control, connection: connection)))
            }
            let completedReadings = readings
            DispatchQueue.main.async {
                guard let self, self.session.generation == generation else { return }
                self.refreshingGeneration = nil
                guard !self.draining else { return }
                // Apply the full batch before draining. A deferred manual change on the first
                // control must not make later readings in this same batch get discarded.
                for (connection, control, result) in completedReadings {
                    switch result {
                    case .success(let level):
                        _ = self.session.applyReading(level, connection: connection, control: control, generation: generation)
                    case .failure(let error):
                        _ = self.session.applyReadFailure(error.localizedDescription, connection: connection, control: control, generation: generation)
                    }
                }
                self.publish()
                self.drain()
            }
        }
    }

    private func publish() {
        synchronizeBlackScreenWindows()
        monitors = session.monitors
        for monitor in monitors {
            if let level = monitor.volume.level, level.current > 0 {
                unmuteLevels[monitor.connection] = level.normalized
            }
        }
        // Pending slider requests are separate from confirmed levels, and must also redraw.
        objectWillChange.send()
        services?.refreshMenu()
    }

    func setKeys(_ enabled: Bool, control: DisplayControl) {
        guard save({ settings in
            if control == .brightness { settings.brightnessKeys = enabled }
            else { settings.volumeKeys = enabled }
        }) else { return }
        if enabled, isRunning, services?.permissions.isAccessibilityTrusted == false {
            services?.permissions.requestAccessibility()
        }
        configureKeys()
    }

    func setTarget(_ target: String?, control: DisplayControl) {
        _ = save { settings in
            if control == .brightness { settings.brightnessTarget = target }
            else { settings.volumeTarget = target }
        }
    }

    func setMonitorKeys(_ enabled: Bool, stableID: String, control: DisplayControl) {
        _ = save { settings in
            var preferences = settings.monitors[stableID] ?? .init()
            if control == .brightness { preferences.brightnessKeys = enabled }
            else { preferences.volumeKeys = enabled }
            settings.monitors[stableID] = preferences
        }
    }

    func setBrightnessSynchronization(_ enabled: Bool) {
        _ = save { $0.synchronizeBrightness = enabled }
    }

    func setBlackScreenBelowMinimum(_ enabled: Bool) {
        _ = save { $0.blackScreenBelowMinimum = enabled }
    }

    func isBlackedOut(connection: UUID) -> Bool {
        visibleBlackedOutConnections.contains(connection)
    }

    /// Recovery removes the visual cover without restoring a previous hardware brightness.
    func restoreBrightnessVisibility(connection: UUID? = nil) {
        session.restoreBrightnessVisibility(connection: connection)
        blackScreenMessage = nil
        cancelKeyboardRequests(preservingBlackScreens: connection != nil, force: true)
        publish()
    }

    func setBrightnessLimit(_ maximum: Double, stableID: String) {
        guard maximum.isFinite else { return }
        _ = save { settings in
            var preferences = settings.monitors[stableID] ?? .init()
            let lower = min(1, max(0.05, preferences.brightnessMinimum + 0.01))
            preferences.brightnessLimit = min(1, max(lower, maximum))
            settings.monitors[stableID] = preferences
        }
    }

    func setBrightnessMinimum(_ minimum: Double, stableID: String) {
        guard minimum.isFinite else { return }
        _ = save { settings in
            var preferences = settings.monitors[stableID] ?? .init()
            let upper = max(0, preferences.brightnessLimit - 0.01)
            preferences.brightnessMinimum = min(upper, max(0, minimum))
            settings.monitors[stableID] = preferences
        }
    }

    private func save(_ edit: (inout DisplayControlSettings) -> Void) -> Bool {
        guard canEdit, let services else { return false }
        var next = settings
        edit(&next)
        do {
            try services.config.save(next)
            settings = next
            refreshingGeneration = nil
            heldKeyConnections = [:]
            heldBrightnessGroups = [:]
            cancelKeyboardFeedback()
            if isRunning {
                session.cancelPendingCommands()
                gate.replace(session.generation)
                draining = false
                publish()
                refreshReadings()
            }
            saveError = nil
            keyMessage = nil
            blackScreenMessage = nil
            services.refreshSettings()
            return true
        } catch {
            saveError = "Display Control settings could not be saved. Previous preferences remain in use."
            return false
        }
    }

    func recoverKeys() { services?.permissions.openAccessibilitySettings() }

    private func configureKeys() {
        guard isRunning, let services else { return }
        cancelKeyboardRequests()
        services.mediaKeys.unregisterAll()
        keyFailure = nil
        var actions = Set<MediaKeyAction>()
        if settings.brightnessKeys { actions.formUnion([.brightnessUp, .brightnessDown]) }
        if settings.volumeKeys { actions.formUnion([.volumeUp, .volumeDown, .mute]) }
        guard !actions.isEmpty else { return }
        let result = services.mediaKeys.register(actions: actions, handler: { [weak self] key, isRepeat, step in
            self?.handleKey(key, isRepeat: isRepeat, step: step) ?? false
        }, onFailureChange: { [weak self] error in
            if error != nil { self?.cancelKeyboardRequests() }
            self?.keyFailure = error?.localizedDescription
            self?.services?.refreshMenu()
        })
        if case .failure(let error) = result { keyFailure = error.localizedDescription }
    }

    private func handleKey(_ key: MediaKeyAction, isRepeat: Bool, step: Double) -> Bool {
        guard isRunning, !asleep else { return false }
        let control = key.control
        let savedTarget = control == .brightness ? settings.brightnessTarget : settings.volumeTarget
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let pointerConnection = displayID.flatMap { displayConnections[$0] }
        let selected: DisplayControlMonitor?
        if isRepeat {
            // Repeats keep the original reference and group even if the pointer moves.
            let connection: UUID
            if control == .brightness {
                guard let group = heldBrightnessGroups[key], group.generation == session.generation else { return true }
                connection = group.reference
            } else {
                guard let held = heldKeyConnections[key], held.generation == session.generation else { return true }
                connection = held.connection
            }
            selected = session.monitors.first { $0.connection == connection }
        } else {
            heldKeyConnections.removeValue(forKey: key)
            heldBrightnessGroups.removeValue(forKey: key)
            selected = session.target(savedTarget.map(DisplayControlTarget.display) ?? .pointer,
                                      pointerConnection: pointerConnection)
        }
        guard let monitor = selected else {
            if savedTarget != nil {
                keyMessage = "The selected display is disconnected or cannot be identified. No display was changed."
                keyboardFeedback = [:]
                keyboardHUD.show(.init(monitorName: "Selected display", control: control, level: nil,
                                       error: "The display is disconnected or cannot be identified."),
                                 on: screen)
                return true
            }
            return false
        }
        let preferences = settings.monitors[monitor.stableID] ?? .init()
        guard control == .brightness ? preferences.brightnessKeys : preferences.volumeKeys else {
            let restored = restoreBlackScreenForFailedUp(key, reference: monitor.connection)
            if savedTarget != nil {
                keyMessage = "\(monitor.name) is excluded from these keys. No display was changed."
                return true
            }
            return restored
        }
        guard monitor[control].isSupported else {
            let restored = restoreBlackScreenForFailedUp(key, reference: monitor.connection)
            if savedTarget != nil {
                keyMessage = "\(monitor.name) does not support this control on its current connection. No display was changed."
                return true
            }
            return restored
        }
        // A held brightness group keeps its logical level when one member loses readback.
        // Fresh presses and volume still need a confirmed level from their reference.
        if control == .volume || !isRepeat {
            guard monitor[control].level != nil else {
                _ = restoreBlackScreenForFailedUp(key, reference: monitor.connection)
                keyMessage = "\(monitor.name): the current value is unavailable. Retry the display connection."
                showKeyboardFailure("The current value is unavailable. Retry detection.", monitor: monitor, control: control)
                return true
            }
        }
        if !isRepeat, control == .volume { heldKeyConnections[key] = (monitor.connection, session.generation) }
        var acceptedConnections: [UUID] = []
        switch key {
        case .brightnessUp, .brightnessDown:
            let limits = brightnessLimits()
            let minimums = brightnessMinimums()
            var group: DisplayBrightnessGroup
            if isRepeat {
                guard let held = heldBrightnessGroups[key] else { return true }
                group = held
            } else {
                let allowed = Set(session.monitors.filter {
                    (settings.monitors[$0.stableID] ?? .init()).brightnessKeys
                }.map(\.connection))
                guard let selectedGroup = session.brightnessGroup(reference: monitor.connection,
                                                                  synchronized: settings.synchronizeBrightness,
                                                                  allowedConnections: allowed,
                                                                  brightnessLimits: limits,
                                                                  brightnessMinimums: minimums) else {
                    return restoreBlackScreenForFailedUp(key, reference: monitor.connection)
                }
                group = selectedGroup
            }
            acceptedConnections = session.adjustBrightness(&group,
                                                            delta: key == .brightnessUp ? step : -step,
                                                            brightnessLimits: limits,
                                                            brightnessMinimums: minimums,
                                                            blackScreenBelowMinimum: settings.blackScreenBelowMinimum)
            heldBrightnessGroups[key] = group
        case .volumeUp:
            if session.adjust(connection: monitor.connection, control: control, delta: step) {
                acceptedConnections = [monitor.connection]
            }
        case .volumeDown:
            if session.adjust(connection: monitor.connection, control: control, delta: -step) {
                acceptedConnections = [monitor.connection]
            }
        case .mute:
            let current = session.requestedLevel(connection: monitor.connection, control: .volume) ?? 0
            if current > 0 {
                unmuteLevels[monitor.connection] = current
                if session.enqueue(connection: monitor.connection, control: .volume, normalizedValue: 0) {
                    acceptedConnections = [monitor.connection]
                }
            } else if let previous = unmuteLevels[monitor.connection] {
                if session.enqueue(connection: monitor.connection, control: .volume, normalizedValue: previous) {
                    acceptedConnections = [monitor.connection]
                }
            } else {
                keyMessage = "\(monitor.name): press Volume Up to unmute."
                showKeyboardFailure("Press Volume Up to unmute.", monitor: monitor, control: control)
                return true
            }
        }
        if !acceptedConnections.isEmpty {
            keyMessage = nil
            keyboardFeedback = Dictionary(uniqueKeysWithValues: acceptedConnections.map {
                ($0, (control: control, generation: session.generation))
            })
            publish()
            updateKeyboardFeedback(connections: acceptedConnections)
            drain()
        } else if key == .brightnessUp {
            return restoreBlackScreenForFailedUp(key, reference: monitor.connection) || isRepeat
        }
        return !acceptedConnections.isEmpty || (isRepeat && control == .brightness)
    }

    private func brightnessLimits() -> [UUID: Double] {
        session.monitors.reduce(into: [:]) { limits, monitor in
            limits[monitor.connection] = (settings.monitors[monitor.stableID] ?? .init()).brightnessLimit
        }
    }

    private func brightnessMinimums() -> [UUID: Double] {
        session.monitors.reduce(into: [:]) { minimums, monitor in
            minimums[monitor.connection] = (settings.monitors[monitor.stableID] ?? .init()).brightnessMinimum
        }
    }

    /// A failed read must still allow Brightness Up to uncover its original target group.
    private func restoreBlackScreenForFailedUp(_ key: MediaKeyAction, reference: UUID) -> Bool {
        guard key == .brightnessUp else { return false }
        let connections: Set<UUID>
        if let group = [heldBrightnessGroups[.brightnessUp], heldBrightnessGroups[.brightnessDown]]
            .compactMap({ $0 }).first(where: {
            $0.reference == reference && $0.generation == session.generation
        }) {
            connections = Set(group.connections)
        } else if settings.synchronizeBrightness {
            connections = Set(session.monitors.filter {
                $0.brightness.isSupported && (settings.monitors[$0.stableID] ?? .init()).brightnessKeys
            }.map(\.connection))
        } else {
            connections = [reference]
        }
        let covered = session.blackedOutConnections.intersection(connections)
        guard !covered.isEmpty else { return false }
        for connection in covered { session.restoreBrightnessVisibility(connection: connection) }
        cancelKeyboardRequests(preservingBlackScreens: true, force: true)
        return true
    }

    private func synchronizeBlackScreenWindows() {
        let requested = session.blackedOutConnections
        guard !requested.isEmpty else {
            clearBlackScreenWindows()
            return
        }
        guard isRunning, !asleep, settings.brightnessKeys, settings.blackScreenBelowMinimum,
              let services, services.permissions.isAccessibilityTrusted,
              !services.hotkeys.isSuspended, !IsSecureEventInputEnabled() else {
            session.restoreBrightnessVisibility()
            clearBlackScreenWindows()
            blackScreenMessage = "Black screen was cleared because brightness key control is unavailable."
            return
        }
        if blackScreenEscape == nil {
            switch services.hotkeys.register(keyCode: 53, modifiers: 0, action: { [weak self] in
                self?.restoreBrightnessVisibility()
            }) {
            case .success(let token): blackScreenEscape = token
            case .failure:
                session.restoreBrightnessVisibility()
                clearBlackScreenWindows()
                blackScreenMessage = "Black screen is unavailable because its Escape shortcut could not be registered."
                return
            }
        }
        let requestedIDs = Set(displayConnections.compactMap { displayID, connection in
            requested.contains(connection) ? displayID : nil
        })
        let shownIDs = blackScreen.apply(displayIDs: requestedIDs)
        visibleBlackedOutConnections = Set(displayConnections.compactMap { displayID, connection in
            requested.contains(connection) && shownIDs.contains(displayID) ? connection : nil
        })
        let refused = requested.subtracting(visibleBlackedOutConnections)
        if !refused.isEmpty {
            for connection in refused { session.restoreBrightnessVisibility(connection: connection) }
            blackScreenMessage = "A display could not be covered safely. Its black screen was cleared."
        } else {
            blackScreenMessage = nil
        }
        guard !visibleBlackedOutConnections.isEmpty else {
            clearBlackScreenWindows()
            return
        }
        guard blackScreenTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let services = self.services else { return }
                guard self.isRunning, !self.asleep, services.permissions.isAccessibilityTrusted,
                      !services.hotkeys.isSuspended, !IsSecureEventInputEnabled() else {
                    self.restoreBrightnessVisibility()
                    self.blackScreenMessage = "Black screen was cleared because keyboard recovery is unavailable."
                    services.refreshMenu()
                    return
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blackScreenTimer = timer
    }

    private func clearBlackScreenWindows() {
        blackScreen.hideAll()
        visibleBlackedOutConnections = []
        blackScreenTimer?.invalidate()
        blackScreenTimer = nil
        if let token = blackScreenEscape { services?.hotkeys.unregister(token) }
        blackScreenEscape = nil
    }

    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {
        guard blackScreenEscape != nil,
              failures.contains(where: { $0.keyCode == 53 && $0.modifiers == 0 }) else { return }
        restoreBrightnessVisibility()
        blackScreenMessage = "Black screen was cleared because its Escape shortcut could not be restored."
        services?.refreshMenu()
    }

    private func cancelKeyboardRequests(preservingBlackScreens: Bool = false, force: Bool = false) {
        let hadRequests = force || !heldKeyConnections.isEmpty || !heldBrightnessGroups.isEmpty
            || !keyboardFeedback.isEmpty || !session.blackedOutConnections.isEmpty
        heldKeyConnections = [:]
        heldBrightnessGroups = [:]
        cancelKeyboardFeedback()
        guard isRunning, hadRequests else { return }
        session.cancelPendingCommands(preservingBlackScreens: preservingBlackScreens)
        // Uncover immediately, before waiting for a hardware write already in progress.
        synchronizeBlackScreenWindows()
        refreshingGeneration = nil
        gate.replace(session.generation)
        draining = false
        publish()
        refreshReadings()
    }

    private func cancelKeyboardFeedback() {
        keyboardFeedback = [:]
        keyboardHUD.hide(immediately: true)
    }

    private func screen(for connection: UUID) -> NSScreen? {
        guard let displayID = displayConnections.first(where: { $0.value == connection })?.key else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    #if DEBUG
    func reviewScreen(for connection: UUID) -> NSScreen? { screen(for: connection) }
    #endif

    private func showKeyboardFailure(_ error: String, monitor: DisplayControlMonitor, control: DisplayControl) {
        keyboardFeedback = [:]
        keyboardHUD.show(.init(monitorName: monitor.name, control: control, level: nil, error: error),
                         on: screen(for: monitor.connection))
    }

    private func updateKeyboardFeedback(connections: [UUID]) {
        guard isRunning, !asleep, services?.permissions.isAccessibilityTrusted == true,
              !keyboardFeedback.isEmpty else {
            cancelKeyboardFeedback()
            return
        }
        for connection in connections {
            guard let feedback = keyboardFeedback[connection], feedback.generation == session.generation,
                  let monitor = session.monitors.first(where: { $0.connection == connection }) else { continue }
            let status = monitor[feedback.control]
            let requested = session.requestedLevel(connection: connection, control: feedback.control)
            let isPending = status.level != nil && requested != status.level?.normalized
            keyboardHUD.show(.init(monitorName: monitor.name, control: feedback.control, level: status.level,
                                   isPending: isPending, error: status.error,
                                   isBlackedOut: feedback.control == .brightness && isBlackedOut(connection: connection)),
                             on: screen(for: connection))
        }
    }

    var warnings: [ToolWarning] {
        var result = [configError, saveError, keyMessage, blackScreenMessage].compactMap { text in
            text.map { ToolWarning(id: "displayControl", text: $0) }
        }
        if let keyFailure {
            result.append(ToolWarning(id: "displayControl.keys", text: keyFailure,
                                      actionTitle: "Open Accessibility settings", action: { [weak self] in self?.recoverKeys() }))
        }
        return result
    }

    func menuItems() -> [NSMenuItem] {
        let controls = NSMenuItem(title: displayName, action: nil, keyEquivalent: "")
        let view = NSHostingView(rootView: DisplayControlMenuView(tool: self))
        view.frame = NSRect(x: 0, y: 0, width: 320, height: min(540, max(80, view.fittingSize.height)))
        controls.view = view
        return [controls, ToolMenu.item("Detect displays again", symbol: "arrow.clockwise") { [weak self] in self?.rediscover() }]
    }

    func makeQuickPanel() -> AnyView? { AnyView(DisplayControlQuickPanel(tool: self)) }

    func panelWillOpen() { refreshReadings() }

    func makeSettingsPane() -> AnyView {
        AnyView(ScrollView { DisplayControlSettingsPane(tool: self) })
    }

    #if DEBUG
    /// A view snapshot from read-only discovery. It has no config, taps, observers or live transport.
    static func preview(displays: [DisplayTransportMonitor],
                        settings: DisplayControlSettings = .init(),
                        blackedOutConnections: Set<UUID> = []) -> DisplayControlTool {
        let tool = DisplayControlTool()
        tool.settings = settings
        tool.isRunning = true
        tool.session.start()
        tool.session.replaceDisplays(displays.map(\.monitor))
        tool.monitors = tool.session.monitors
        tool.displayConnections = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0.monitor.connection) })
        tool.connectionDescriptions = Dictionary(uniqueKeysWithValues: displays.map { ($0.monitor.connection, $0.connectionDescription) })
        // This state renders recovery controls only. Preview owns no black windows or key hooks.
        tool.visibleBlackedOutConnections = blackedOutConnections.intersection(Set(displays.map { $0.monitor.connection }))
        return tool
    }
    #endif
}
