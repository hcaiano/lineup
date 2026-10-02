import Foundation

public enum KeyboardMappingTransaction {
    /// Journal both old and new pairs before changing macOS. An interruption during a replace
    /// then leaves enough information to remove either exact result on the next launch.
    public static func apply(current: [KeyMapping], owned: [KeyMapping], plan: KeyboardMappingPlan,
                             read: () throws -> [KeyMapping],
                             write: ([KeyMapping]) throws -> Void,
                             record: ([KeyMapping]) throws -> Void) throws {
        try HIDMappingTable.validate(current)
        try HIDMappingTable.validate(plan.table)
        let initial = try read()
        try HIDMappingTable.validate(initial)
        guard Set(initial) == Set(current) else { throw KeyboardMappingError.tableChanged }

        var seen = Set<KeyMapping>()
        let intent = (owned + plan.owned).filter { seen.insert($0).inserted }
        try record(intent)

        // The property has no compare-and-swap operation. Re-read immediately before a write
        // to avoid replacing external changes observed since planning.
        do {
            let latest = try read()
            try HIDMappingTable.validate(latest)
            guard Set(latest) == Set(current) else { throw KeyboardMappingError.tableChanged }
        } catch {
            // No write was attempted. Retire new intent so a later recovery cannot claim an
            // identical pair another tool installed while the journal was being saved.
            try record(owned)
            throw error
        }
        if Set(plan.table) != Set(current) {
            try write(plan.table)
            let applied = try read()
            try HIDMappingTable.validate(applied)
            guard Set(applied) == Set(plan.table) else { throw KeyboardMappingError.verificationFailed }
        }
        try record(plan.owned)
    }
}
