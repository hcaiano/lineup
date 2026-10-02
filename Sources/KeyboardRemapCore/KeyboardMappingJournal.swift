import Foundation

public struct KeyboardMappingJournalEntry: Codable, Equatable, Sendable {
    public let registryID: UInt64
    public var mappings: [KeyMapping]

    public init(registryID: UInt64, mappings: [KeyMapping]) {
        self.registryID = registryID
        self.mappings = mappings
    }
}

/// A service ID can be reused after reboot. The native owner only replays entries from the
/// same boot session, records intent before each write, and verifies the table after it.
public struct KeyboardMappingJournal: Codable, Equatable, Sendable {
    public let version: Int
    public let bootSession: String
    public var entries: [KeyboardMappingJournalEntry]

    public init(bootSession: String, entries: [KeyboardMappingJournalEntry] = []) {
        version = 1
        self.bootSession = bootSession
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, bootSession, entries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw KeyboardMappingError.unsupportedJournalVersion(version) }
        bootSession = try container.decode(String.self, forKey: .bootSession)
        entries = try container.decode([KeyboardMappingJournalEntry].self, forKey: .entries)
        guard !bootSession.isEmpty else { throw KeyboardMappingError.malformedJournal }
        var serviceIDs = Set<UInt64>()
        for entry in entries {
            guard entry.registryID != 0, serviceIDs.insert(entry.registryID).inserted else {
                throw KeyboardMappingError.malformedJournal
            }
            // A pending replacement can claim both old and new destinations for one source.
            // Cleanup still removes only the exact alternative present in the current table.
            guard Set(entry.mappings).count == entry.mappings.count else {
                throw KeyboardMappingError.malformedJournal
            }
        }
    }

    public func mappings(for registryID: UInt64) -> [KeyMapping] {
        entries.first { $0.registryID == registryID }?.mappings ?? []
    }

    public mutating func setMappings(_ mappings: [KeyMapping], for registryID: UInt64) {
        entries.removeAll { $0.registryID == registryID }
        if !mappings.isEmpty {
            entries.append(KeyboardMappingJournalEntry(registryID: registryID, mappings: mappings))
        }
    }
}
