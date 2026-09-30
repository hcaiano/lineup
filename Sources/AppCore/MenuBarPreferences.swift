import Foundation
import CoreFoundation

/// The macOS 27 tracked-app preference is a binary plist containing alternating
/// encoded dictionary keys and values. Bundle owners and executable-tracked trays can be
/// changed selectively; unrecognized location variants remain untouched. An OS schema
/// change must stop writes, not reset the preference.
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
            let id: String
            if let bundle = key["bundle"] as? [String: Any], let owner = bundle["_0"] as? String {
                id = owner
            } else if let binary = key["adhocBinary"] as? [String: Any],
                      let encodedURL = binary["_0"] as? [String: Any], encodedURL.count == 1,
                      let relative = encodedURL["relative"] as? String,
                      let url = URL(string: relative), url.isFileURL, url.path.hasPrefix("/"),
                      url.host == nil || url.host == "" || url.host == "localhost" {
                id = url.absoluteString
            } else { continue }
            guard !id.isEmpty, indices[id] == nil,
                  let flag = record["isAllowed"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID(),
                  let location = record["location"] as? NSDictionary,
                  location.isEqual(to: key) else { throw Failure.unsupportedFormat }
            indices[id] = index + 1
            allowed[id] = flag.boolValue
        }
    }

    public func changesToRestore(original: [String: Bool]) -> [String: Bool] {
        original.filter { $0.value && allowed[$0.key] == false && !$0.key.hasPrefix("com.apple.") }
    }

    public mutating func setAllowed(_ values: [String: Bool]) throws {
        // System controls are outside this tool's authority, even if a caller supplies one.
        guard !values.contains(where: { id, allowed in
            !allowed && (id.hasPrefix("com.apple.")
                || URL(string: id).map { $0.isFileURL && $0.standardizedFileURL.path.hasPrefix("/System/") } == true)
        }) else { throw Failure.unsupportedFormat }
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

/// Written by earlier versions before changing macOS. Launch and the recovery process
/// use it, so apps hidden by a killed earlier version are shown again.
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
