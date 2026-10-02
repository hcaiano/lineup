import Foundation

/// Periodic inventory work is shared by both mapping contributors and recovery.
public enum KeyboardMappingMaintenance {
    public static func requiresPolling(started: Bool, readOnly: Bool, rules: [KeyboardRuleSet],
                                       remapEnabled: Bool, hyperkeyRequested: Bool,
                                       legacyClaimRequested: Bool, reconciliationPending: Bool,
                                       recoveryPending: Bool) -> Bool {
        started && !readOnly && (hyperkeyRequested || legacyClaimRequested
            || reconciliationPending || recoveryPending
            || (remapEnabled && rules.contains { !$0.mappings.isEmpty }))
    }
}

/// Coalesces inventory demand while a snapshot is in flight. Request identifiers keep a
/// completed snapshot from an earlier service lifetime from consuming a newer request.
public struct KeyboardMappingRefreshQueue {
    private enum State {
        case idle
        case running(UInt64)
        case queued(UInt64)
    }
    private var state = State.idle
    private var nextID: UInt64 = 0

    public init() {}

    /// Returns an identifier only when the caller should start a new snapshot.
    public mutating func request() -> UInt64? {
        switch state {
        case .idle:
            nextID += 1
            state = .running(nextID)
            return nextID
        case .running(let current):
            state = .queued(current)
            return nil
        case .queued:
            return nil
        }
    }

    /// Returns the identifier of a coalesced follow-up, if one is still required.
    public mutating func complete(_ requestID: UInt64, started: Bool) -> UInt64? {
        switch state {
        case .running(let current):
            guard current == requestID else { return nil }
            state = .idle
            return nil
        case .queued(let current):
            guard current == requestID else { return nil }
            state = .idle
            return started ? request() : nil
        case .idle:
            return nil
        }
    }

    public mutating func stop() { state = .idle }
}

/// Resolves saved hardware selectors without treating an absent device as a conflicting map.
public struct KeyboardRuleSelection: Sendable {
    public private(set) var mappings: [UInt64: [KeyMapping]] = [:]
    public private(set) var deviceErrors: [UInt64: String] = [:]
    public private(set) var status: String?

    public init(rules: [KeyboardRuleSet], devices: [KeyboardDevice]) {
        for rule in rules where !rule.mappings.isEmpty {
            let matching = devices.filter { rule.selector.matches(device: $0) }
            if matching.count > 1 {
                let message = "The selected keyboard matches more than one HID service. Choose a keyboard that can be identified separately."
                status = message
                for device in matching { deviceErrors[device.registryID] = message }
            } else if let device = matching.first {
                mappings[device.registryID, default: []] += rule.mappings
            }
        }
    }
}

/// Retires an explicit legacy ownership claim only after every table has been read and the
/// claim has been durably recorded. It never infers ownership from a pair's shape alone.
/// The acknowledgement belongs to this request; a later claim must be recorded again.
public struct KeyboardLegacyClaimTransfer {
    public init() {}

    public func transfer(requested: Bool, mapping: KeyMapping,
                         registryIDs: [UInt64], journal: KeyboardMappingJournal,
                         read: (UInt64) throws -> [KeyMapping],
                         record: (KeyboardMappingJournal) throws -> Void) throws -> Bool {
        guard requested, !registryIDs.isEmpty else { return false }
        var migrated = journal
        for id in registryIDs {
            if try read(id).contains(mapping) {
                let owned = migrated.mappings(for: id)
                migrated.setMappings(Array(Set(owned + [mapping])).sorted {
                    $0.source == $1.source ? $0.destination < $1.destination : $0.source < $1.source
                }, for: id)
            }
        }
        try record(migrated)
        return true
    }
}
