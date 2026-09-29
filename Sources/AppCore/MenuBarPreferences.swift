import Foundation
import CoreFoundation

/// The macOS 27 tracked-app preference is a binary plist containing alternating
/// encoded dictionary keys and values. Preserve records and location variants
/// we do not own; an OS schema change must stop writes, not reset the preference.
public struct MenuBarPreferences {
    private var entries: [Any]
    public private(set) var allowed: [String: Bool] = [:]
    private var indices: [String: Int] = [:]

    public enum Failure: Error, LocalizedError {
        case unsupportedFormat, missingApplication(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "macOS menu bar settings have an unsupported format. No settings were changed."
            case .missingApplication: return "An app is no longer registered in the menu bar. Refresh the items and try again."
            }
        }
    }

    public init(data: Data) throws {
        guard let entries = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
              entries.count.isMultiple(of: 2) else { throw Failure.unsupportedFormat }
        self.entries = entries
        for index in stride(from: 0, to: entries.count, by: 2) {
            guard let key = entries[index] as? [String: Any],
                  let record = entries[index + 1] as? [String: Any] else { throw Failure.unsupportedFormat }
            // Other location kinds are retained, but are never editable by this tool.
            guard let bundle = key["bundle"] as? [String: Any],
                  let id = bundle["_0"] as? String else { continue }
            guard !id.isEmpty, indices[id] == nil,
                  let flag = record["isAllowed"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID(),
                  let location = record["location"] as? NSDictionary,
                  location.isEqual(to: key) else { throw Failure.unsupportedFormat }
            indices[id] = index + 1
            allowed[id] = flag.boolValue
        }
    }

    public static func isOrganizable(_ owner: String, excluding: Set<String>) -> Bool {
        !owner.isEmpty && !owner.hasPrefix("com.apple.") && !excluding.contains(owner)
    }

    public func originalsToHide(selected: Set<String>, excluding: Set<String>) -> [String: Bool] {
        allowed.filter { $0.value && selected.contains($0.key) && Self.isOrganizable($0.key, excluding: excluding) }
    }

    public func changesToRestore(original: [String: Bool]) -> [String: Bool] {
        original.filter { $0.value && allowed[$0.key] == false && !$0.key.hasPrefix("com.apple.") }
    }

    public mutating func setAllowed(_ values: [String: Bool]) throws {
        for id in values.keys where indices[id] == nil { throw Failure.missingApplication(id) }
        for (id, value) in values {
            let index = indices[id]!
            var record = entries[index] as! [String: Any]
            record["isAllowed"] = value
            entries[index] = record
            allowed[id] = value
        }
    }

    public func encoded() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }
}

/// Written before changing macOS. Both normal teardown and the separate recovery
/// process use this record, so a killed parent cannot strand its hidden apps.
public struct MenuBarRecoveryRecord: Codable {
    public let session: UUID
    public let bookmark: Data
    public let original: [String: Bool]

    public init(session: UUID, bookmark: Data, original: [String: Bool]) {
        self.session = session
        self.bookmark = bookmark
        self.original = original
    }
}
