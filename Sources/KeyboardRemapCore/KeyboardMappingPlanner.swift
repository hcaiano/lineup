import Foundation

public enum KeyboardMappingError: Error, Equatable, LocalizedError {
    case malformedTable
    case duplicateSource(UInt64)
    case sourceConflict(source: UInt64, existingDestination: UInt64, requestedDestination: UInt64)
    case hyperkeyConflict(UInt64)
    case tableChanged
    case verificationFailed
    case malformedJournal
    case unsupportedJournalVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .malformedTable:
            return "The keyboard mapping table could not be read safely. No mappings were changed."
        case .duplicateSource(let source):
            return "The keyboard mapping table contains more than one rule for \(Self.keyName(source))."
        case .sourceConflict(let source, _, _):
            return "Another tool already remaps \(Self.keyName(source)). Remove that conflicting rule and retry."
        case .hyperkeyConflict(let source):
            return "A mapping for \(Self.keyName(source)) conflicts with Hyperkey's Caps Lock to F18 route."
        case .tableChanged:
            return "Another tool changed the keyboard mapping table. Retry after its changes finish."
        case .verificationFailed:
            return "macOS did not keep the requested keyboard mappings. Retry to recover."
        case .malformedJournal:
            return "Saved keyboard mapping ownership could not be read safely. No mappings were changed."
        case .unsupportedJournalVersion:
            return "A newer Lineup version saved keyboard mapping ownership. Update Lineup to recover it safely."
        }
    }

    private static func keyName(_ usage: UInt64) -> String {
        PhysicalKey.key(for: usage)?.name ?? "HID 0x\(String(usage, radix: 16))"
    }
}

public struct KeyboardMappingPlan: Equatable, Sendable {
    public let table: [KeyMapping]
    /// Only pairs installed by this owner. An identical pre-existing pair is borrowed.
    public let owned: [KeyMapping]

    public init(table: [KeyMapping], owned: [KeyMapping]) {
        self.table = table
        self.owned = owned
    }
}

public struct KeyboardMappingResolution: Equatable, Sendable {
    public let plan: KeyboardMappingPlan
    public let hyperkeyError: KeyboardMappingError?
    public let remapError: KeyboardMappingError?

    public init(plan: KeyboardMappingPlan, hyperkeyError: KeyboardMappingError?,
                remapError: KeyboardMappingError?) {
        self.plan = plan
        self.hyperkeyError = hyperkeyError
        self.remapError = remapError
    }
}

public enum KeyboardMappingPlanner {
    /// A conflict belongs to the tool that cannot apply its rules. Keep the other tool's
    /// contribution, preferring Hyperkey's reserved route when desired rules contradict it.
    public static func resolve(current: [KeyMapping], owned: [KeyMapping],
                               hyperkey: KeyMapping?, remappings: [KeyMapping]) throws -> KeyboardMappingResolution {
        do {
            let combined = try plan(current: current, owned: owned, hyperkey: hyperkey, remappings: remappings)
            return KeyboardMappingResolution(plan: combined, hyperkeyError: nil, remapError: nil)
        } catch let combinedError as KeyboardMappingError {
            guard let hyperkey else {
                let cleanup = try plan(current: current, owned: owned, hyperkey: nil, remappings: [])
                return KeyboardMappingResolution(plan: cleanup, hyperkeyError: nil, remapError: combinedError)
            }
            do {
                let hyperOnly = try plan(current: current, owned: owned, hyperkey: hyperkey, remappings: [])
                return KeyboardMappingResolution(plan: hyperOnly, hyperkeyError: nil, remapError: combinedError)
            } catch let hyperkeyError as KeyboardMappingError {
                do {
                    let remapOnly = try plan(current: current, owned: owned, hyperkey: nil, remappings: remappings)
                    return KeyboardMappingResolution(plan: remapOnly, hyperkeyError: hyperkeyError, remapError: nil)
                } catch let remapError as KeyboardMappingError {
                    let cleanup = try plan(current: current, owned: owned, hyperkey: nil, remappings: [])
                    return KeyboardMappingResolution(plan: cleanup, hyperkeyError: hyperkeyError, remapError: remapError)
                }
            }
        }
    }

    /// Remove only exact previously installed pairs, then merge both tools into one table.
    /// If an external writer changed an owned destination, its replacement stays external.
    public static func plan(current: [KeyMapping], owned: [KeyMapping],
                            hyperkey: KeyMapping?, remappings: [KeyMapping]) throws -> KeyboardMappingPlan {
        try HIDMappingTable.validate(current)
        try HIDMappingTable.validate(remappings)
        let previous = Set(owned)
        var table = current.filter { !previous.contains($0) }
        var newOwned: [KeyMapping] = []

        if let hyperkey {
            let f18 = PhysicalKey.f18.hidUsage
            // F18 is the event tap's private route while Caps Lock Hyperkey is active.
            // Another source targeting it would also activate Hyperkey, and mapping it away
            // prevents Hyperkey from seeing the synthetic key at all.
            for mapping in table + remappings where mapping != hyperkey {
                if mapping.source == f18 || mapping.destination == f18 {
                    throw KeyboardMappingError.hyperkeyConflict(mapping.source)
                }
            }
            if remappings.contains(where: { $0.source == hyperkey.source }) {
                throw KeyboardMappingError.hyperkeyConflict(hyperkey.source)
            }
        }

        for mapping in (hyperkey.map { [$0] } ?? []) + remappings {
            if let external = table.first(where: { $0.source == mapping.source }) {
                guard external.destination == mapping.destination else {
                    throw KeyboardMappingError.sourceConflict(
                        source: mapping.source,
                        existingDestination: external.destination,
                        requestedDestination: mapping.destination)
                }
                continue
            }
            table.append(mapping)
            newOwned.append(mapping)
        }
        return KeyboardMappingPlan(table: table, owned: newOwned)
    }
}
