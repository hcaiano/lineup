import Foundation
import CoreFoundation

/// Reads the typed IOKit property, rather than a lossy textual hidutil description.
public enum HIDMappingTable {
    public static let sourceKey = "HIDKeyboardModifierMappingSrc"
    public static let destinationKey = "HIDKeyboardModifierMappingDst"

    public static func parse(_ raw: Any?) throws -> [KeyMapping] {
        guard let raw else { return [] }
        guard let entries = raw as? [Any] else { throw KeyboardMappingError.malformedTable }
        let mappings = try entries.map { entry -> KeyMapping in
            guard let fields = entry as? [String: Any],
                  Set(fields.keys) == Set([sourceKey, destinationKey]),
                  let source = unsignedInteger(fields[sourceKey]),
                  let destination = unsignedInteger(fields[destinationKey]) else {
                throw KeyboardMappingError.malformedTable
            }
            return KeyMapping(source: source, destination: destination)
        }
        try validate(mappings)
        return mappings
    }

    public static func validate(_ mappings: [KeyMapping]) throws {
        var sources = Set<UInt64>()
        for mapping in mappings where !sources.insert(mapping.source).inserted {
            throw KeyboardMappingError.duplicateSource(mapping.source)
        }
    }

    public static func propertyList(_ mappings: [KeyMapping]) -> [[String: UInt64]] {
        mappings.map { [sourceKey: $0.source, destinationKey: $0.destination] }
    }

    private static func unsignedInteger(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let kind = String(cString: number.objCType)
        guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(kind) else {
            return nil
        }
        return UInt64(number.stringValue)
    }
}
