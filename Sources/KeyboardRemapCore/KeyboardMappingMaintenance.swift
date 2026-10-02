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
        guard requested else { return false }
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
