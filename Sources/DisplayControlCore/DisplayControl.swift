import Foundation

public enum DisplayControl: String, CaseIterable, Hashable, Sendable {
    case brightness
    case volume
}

/// A level exists only after a valid hardware read. A successful write alone is not a read.
public struct DisplayControlLevel: Equatable, Sendable {
    public let current: UInt16
    public let maximum: UInt16

    public init?(current: UInt16, maximum: UInt16) {
        guard maximum > 0, current <= maximum else { return nil }
        self.current = current
        self.maximum = maximum
    }

    public var normalized: Double { Double(current) / Double(maximum) }
}

public enum DisplayControlAvailability: Equatable, Sendable {
    case supported
    case unsupported(String)
}

public struct DisplayControlStatus: Equatable, Sendable {
    public var availability: DisplayControlAvailability
    public var level: DisplayControlLevel?
    public var error: String?

    public init(availability: DisplayControlAvailability, level: DisplayControlLevel? = nil,
                error: String? = nil) {
        self.availability = availability
        self.level = availability == .supported ? level : nil
        self.error = error
    }

    public var isSupported: Bool { availability == .supported }
}

public struct DisplayControlMonitor: Equatable, Sendable {
    /// Persisted preferences use this identity, never a transient display number or list index.
    public let stableID: String
    /// The transport must issue a new token whenever it rebuilds a connection.
    public let connection: UUID
    public let name: String
    public var brightness: DisplayControlStatus
    public var volume: DisplayControlStatus

    public init(stableID: String, connection: UUID, name: String,
                brightness: DisplayControlStatus, volume: DisplayControlStatus) {
        self.stableID = stableID
        self.connection = connection
        self.name = name
        self.brightness = brightness
        self.volume = volume
    }

    public subscript(control: DisplayControl) -> DisplayControlStatus {
        get { control == .brightness ? brightness : volume }
        set {
            if control == .brightness { brightness = newValue }
            else { volume = newValue }
        }
    }
}

public enum DisplayControlTarget: Equatable, Sendable {
    case pointer
    case display(String)
}

public struct DisplayControlCommand: Equatable, Sendable {
    public let id: UUID
    public let generation: UUID
    public let connection: UUID
    public let control: DisplayControl
    public let value: UInt16
    public let maximum: UInt16

    public var normalized: Double { Double(value) / Double(maximum) }
}

public enum DisplayControlWriteOutcome: Equatable, Sendable {
    case confirmed(DisplayControlLevel)
    case sent
    case failed(String)
}

/// Deterministic command ownership. The app supplies hardware reads and performs transport work.
/// Every discovery, shutdown and restart invalidates work from the previous connection list.
public struct DisplayControlSession {
    public private(set) var isActive = false
    public private(set) var generation = UUID()
    public private(set) var monitors: [DisplayControlMonitor] = []
    /// Visual blackout is ephemeral. It never substitutes for a confirmed hardware level.
    public private(set) var blackedOutConnections: Set<UUID> = []

    private struct Key: Hashable {
        let connection: UUID
        let control: DisplayControl
    }
    /// Firmware may read back above a requested floor. Retain only this floor intent, backed
    /// by its real readback, so a new press can continue below minimum without another write.
    private struct MinimumIntent {
        let value: UInt16
        var reading: DisplayControlLevel?
    }
    private var queued: [Key: DisplayControlCommand] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: DisplayControlCommand] = [:]
    private var deferred: [Key: Double] = [:]
    private var minimumIntents: [UUID: MinimumIntent] = [:]
    /// A preserved shade can outlive an uncertain cancelled write. Its last actual reading is
    /// only a polling comparison baseline; it never fills an unknown monitor status level.
    /// No baseline means the first post-cancellation read must establish one without waking.
    private var blackedOutReadings: [UUID: DisplayControlLevel] = [:]

    public var hasDeferredRequests: Bool { !deferred.isEmpty }

    public init() {}

    public mutating func start() {
        invalidate()
        monitors = []
        isActive = true
    }

    public mutating func stop() {
        isActive = false
        monitors = []
        invalidate()
    }

    public mutating func replaceDisplays(_ displays: [DisplayControlMonitor]) {
        guard isActive else { return }
        invalidate()
        monitors = displays
    }

    /// Routing edits keep display identities but cancel all previously accepted requests.
    /// A write already handed to the transport may have started, so only its control loses the
    /// previous reading. Queued controls retain readings because no command was sent for them.
    public mutating func cancelPendingCommands(preservingBlackScreens: Bool = false) {
        for key in inFlight.keys {
            guard let index = monitorIndex(key.connection) else { continue }
            monitors[index][key.control].level = nil
            if preservingBlackScreens, key.control == .brightness {
                blackedOutReadings.removeValue(forKey: key.connection)
            }
        }
        invalidate(preservingBlackScreens: preservingBlackScreens)
    }

    /// Removing a visual shade needs no hardware write, including during error recovery.
    public mutating func restoreBrightnessVisibility(connection: UUID? = nil) {
        if let connection {
            blackedOutConnections.remove(connection)
            blackedOutReadings.removeValue(forKey: connection)
        } else {
            blackedOutConnections.removeAll()
            blackedOutReadings.removeAll()
        }
    }

    /// A disconnected or ambiguous saved display must not silently control a different screen.
    public func target(_ selection: DisplayControlTarget,
                       pointerConnection: UUID?) -> DisplayControlMonitor? {
        guard isActive else { return nil }
        let matches: [DisplayControlMonitor]
        switch selection {
        case .pointer:
            guard let pointerConnection else { return nil }
            matches = monitors.filter { $0.connection == pointerConnection }
        case .display(let stableID):
            matches = monitors.filter { $0.stableID == stableID }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The app selects the exact pointer or saved reference first. An unreadable or excluded
    /// reference cannot be replaced by a different monitor, even when synchronization is on.
    public func brightnessGroup(reference: UUID, synchronized: Bool,
                                allowedConnections: Set<UUID>,
                                brightnessLimits: [UUID: Double] = [:],
                                brightnessMinimums: [UUID: Double] = [:]) -> DisplayBrightnessGroup? {
        guard isActive, allowedConnections.contains(reference),
              let index = monitorIndex(reference), monitors[index].brightness.isSupported,
              monitors[index].brightness.level != nil,
              let referenceLevel = requestedLevel(connection: reference, control: .brightness)
        else { return nil }
        var logicalLevel: Double
        if synchronized {
            guard let level = DisplayBrightnessMath.logicalLevel(hardwareLevel: referenceLevel,
                                      brightnessLimit: brightnessLimits[reference] ?? 1,
                                      brightnessMinimum: brightnessMinimums[reference] ?? 0) else { return nil }
            logicalLevel = level
        } else { logicalLevel = referenceLevel }
        if blackedOutConnections.contains(reference)
            || minimumIntents[reference]?.reading == monitors[index].brightness.level {
            logicalLevel = 0
        }
        let others = synchronized ? monitors.filter {
            $0.connection != reference && allowedConnections.contains($0.connection)
                && $0.brightness.isSupported && $0.brightness.level != nil
                && monitorIndex($0.connection) != nil
        }.map(\.connection) : []
        return DisplayBrightnessGroup(generation: generation, reference: reference,
                                      connections: [reference] + others,
                                      isSynchronized: synchronized, logicalLevel: logicalLevel)
    }

    /// Every monitor uses the same logical request. Failed or unreadable members are skipped,
    /// while the other members keep working. Calibration never affects single-display mode.
    @discardableResult
    public mutating func adjustBrightness(_ group: inout DisplayBrightnessGroup, delta: Double,
                                          brightnessLimits: [UUID: Double] = [:],
                                          brightnessMinimums: [UUID: Double] = [:],
                                          blackScreenBelowMinimum: Bool = false) -> [UUID] {
        guard isActive, group.generation == generation, delta.isFinite else { return [] }
        let entersBlackout = blackScreenBelowMinimum && delta < 0 && group.logicalLevel == 0
        let logical = min(1, max(0, group.logicalLevel + delta))
        var accepted: [UUID] = []
        for connection in group.connections {
            let hardware: Double
            if group.isSynchronized {
                guard let level = DisplayBrightnessMath.hardwareLevel(logicalLevel: logical,
                                         brightnessLimit: brightnessLimits[connection] ?? 1,
                                         brightnessMinimum: brightnessMinimums[connection] ?? 0) else { continue }
                hardware = level
            } else { hardware = logical }
            if entersBlackout {
                guard let index = monitorIndex(connection), monitors[index].brightness.isSupported,
                      let reading = monitors[index].brightness.level else { continue }
                // Below-minimum input changes only visibility. The monitor may clamp a prior
                // minimum request to a higher real value; do not keep resending that request.
                blackedOutConnections.insert(connection)
                blackedOutReadings[connection] = reading
                accepted.append(connection)
                continue
            }
            if enqueue(connection: connection, control: .brightness, normalizedValue: hardware) {
                if logical > 0 || !blackScreenBelowMinimum {
                    restoreBrightnessVisibility(connection: connection)
                }
                if blackScreenBelowMinimum, logical == 0, let index = monitorIndex(connection),
                   let reading = monitors[index].brightness.level {
                    let key = Key(connection: connection, control: .brightness)
                    let value = UInt16((hardware * Double(reading.maximum)).rounded())
                    minimumIntents[connection] = MinimumIntent(value: value,
                        reading: queued[key] == nil && inFlight[key] == nil ? reading : nil)
                }
                accepted.append(connection)
            }
        }
        if !accepted.isEmpty { group.setLogicalLevel(logical) }
        return accepted
    }

    /// Coalesces slider or repeated-key requests separately for each monitor and control.
    /// Unknown readings cannot supply a range or a starting level for an adjustment.
    @discardableResult
    public mutating func enqueue(connection: UUID, control: DisplayControl,
                                 normalizedValue: Double) -> Bool {
        guard isActive, normalizedValue.isFinite,
              let index = monitorIndex(connection), monitors[index][control].isSupported,
              let level = monitors[index][control].level else { return false }
        let value = UInt16((min(1, max(0, normalizedValue)) * Double(level.maximum)).rounded())
        let key = Key(connection: connection, control: control)
        if control == .brightness { minimumIntents.removeValue(forKey: connection) }
        if inFlight[key]?.value == value || (inFlight[key] == nil && level.current == value) {
            queued.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return true
        }
        guard queued[key]?.value != value else { return true }
        let command = DisplayControlCommand(id: UUID(), generation: generation,
                                            connection: connection, control: control,
                                            value: value, maximum: level.maximum)
        if queued[key] == nil { order.append(key) }
        queued[key] = command
        return true
    }

    /// Manual control can take over while a cancelled write has an unknown outcome. Preserve
    /// its latest absolute intent until a real read supplies the hardware range, without
    /// inventing a current level or replaying an old keyboard command.
    @discardableResult
    public mutating func enqueueAfterReading(connection: UUID, control: DisplayControl,
                                             normalizedValue: Double) -> Bool {
        guard isActive, normalizedValue.isFinite, let index = monitorIndex(connection),
              monitors[index][control].isSupported else { return false }
        let key = Key(connection: connection, control: control)
        if control == .brightness { minimumIntents.removeValue(forKey: connection) }
        if monitors[index][control].level != nil {
            deferred.removeValue(forKey: key)
            return enqueue(connection: connection, control: control, normalizedValue: normalizedValue)
        }
        queued.removeValue(forKey: key)
        order.removeAll { $0 == key }
        deferred[key] = min(1, max(0, normalizedValue))
        return true
    }

    /// Relative keys build on the user's pending request rather than an older confirmed value.
    @discardableResult
    public mutating func adjust(connection: UUID, control: DisplayControl, delta: Double) -> Bool {
        guard delta.isFinite, let value = requestedLevel(connection: connection, control: control)
        else { return false }
        return enqueue(connection: connection, control: control, normalizedValue: value + delta)
    }

    public func requestedLevel(connection: UUID, control: DisplayControl) -> Double? {
        guard isActive, let index = monitorIndex(connection), monitors[index][control].isSupported
        else { return nil }
        let key = Key(connection: connection, control: control)
        return deferred[key] ?? queued[key]?.normalized ?? inFlight[key]?.normalized
            ?? monitors[index][control].level?.normalized
    }

    /// The caller must also check canSend immediately before each operating-system write.
    public mutating func nextCommand() -> DisplayControlCommand? {
        guard isActive,
              let index = order.firstIndex(where: { inFlight[$0] == nil }) else { return nil }
        let key = order.remove(at: index)
        guard let command = queued.removeValue(forKey: key) else { return nil }
        inFlight[key] = command
        return command
    }

    public func canSend(_ command: DisplayControlCommand) -> Bool {
        let key = Key(connection: command.connection, control: command.control)
        guard isActive, command.generation == generation,
              inFlight[key]?.id == command.id,
              let index = monitorIndex(command.connection) else { return false }
        return monitors[index][command.control].isSupported
    }

    @discardableResult
    public mutating func finish(_ command: DisplayControlCommand,
                                outcome: DisplayControlWriteOutcome) -> Bool {
        guard canSend(command), let index = monitorIndex(command.connection) else { return false }
        let key = Key(connection: command.connection, control: command.control)
        inFlight.removeValue(forKey: key)
        switch outcome {
        case .confirmed(let level):
            monitors[index][command.control].level = level
            monitors[index][command.control].error = nil
            if command.control == .brightness, blackedOutConnections.contains(command.connection) {
                blackedOutReadings[command.connection] = level
            }
            if command.control == .brightness, minimumIntents[command.connection]?.value == command.value {
                minimumIntents[command.connection]?.reading = level
            }
        case .sent:
            monitors[index][command.control].level = nil
            monitors[index][command.control].error = nil
            if command.control == .brightness {
                restoreBrightnessVisibility(connection: command.connection)
                minimumIntents.removeValue(forKey: command.connection)
            }
        case .failed(let reason):
            monitors[index][command.control].level = nil
            monitors[index][command.control].error = reason
            queued.removeValue(forKey: key)
            order.removeAll { $0 == key }
            if command.control == .brightness {
                restoreBrightnessVisibility(connection: command.connection)
                minimumIntents.removeValue(forKey: command.connection)
            }
        }
        return true
    }

    @discardableResult
    public mutating func applyReading(_ level: DisplayControlLevel, connection: UUID,
                                      control: DisplayControl, generation: UUID) -> Bool {
        guard isActive, self.generation == generation, let index = monitorIndex(connection)
        else { return false }
        if control == .brightness, let floorReading = minimumIntents[connection]?.reading,
           floorReading != level {
            minimumIntents.removeValue(forKey: connection)
        }
        if control == .brightness, blackedOutConnections.contains(connection) {
            // An unchanged polling read must not wake a black screen every fifteen seconds.
            // A real level change outside the owned write path restores visibility instead.
            if let baseline = blackedOutReadings[connection], baseline != level {
                restoreBrightnessVisibility(connection: connection)
            } else {
                blackedOutReadings[connection] = level
            }
        }
        monitors[index][control] = DisplayControlStatus(availability: .supported, level: level)
        let key = Key(connection: connection, control: control)
        if let requested = deferred.removeValue(forKey: key) {
            _ = enqueue(connection: connection, control: control, normalizedValue: requested)
        }
        return true
    }

    @discardableResult
    public mutating func applyReadFailure(_ reason: String, connection: UUID,
                                          control: DisplayControl, generation: UUID) -> Bool {
        guard isActive, self.generation == generation, let index = monitorIndex(connection)
        else { return false }
        monitors[index][control].level = nil
        monitors[index][control].error = reason
        if control == .brightness {
            restoreBrightnessVisibility(connection: connection)
            minimumIntents.removeValue(forKey: connection)
        }
        let key = Key(connection: connection, control: control)
        deferred.removeValue(forKey: key)
        queued.removeValue(forKey: key)
        order.removeAll { $0 == key }
        inFlight.removeValue(forKey: key)
        return true
    }

    private func monitorIndex(_ connection: UUID) -> Int? {
        let indices = monitors.indices.filter { monitors[$0].connection == connection }
        return indices.count == 1 ? indices[0] : nil
    }

    private mutating func invalidate(preservingBlackScreens: Bool = false) {
        generation = UUID()
        queued = [:]
        order = []
        inFlight = [:]
        deferred = [:]
        minimumIntents = [:]
        if preservingBlackScreens {
            blackedOutConnections = blackedOutConnections.filter {
                guard let index = monitorIndex($0) else { return false }
                return monitors[index].brightness.isSupported
            }
            blackedOutReadings = blackedOutReadings.filter { blackedOutConnections.contains($0.key) }
        } else {
            restoreBrightnessVisibility()
        }
    }
}
