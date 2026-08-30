import Foundation

/// Recovery data written before Tiles changes a window.  It contains only a
/// conservative matching fingerprint and frame ownership data; it does not
/// contain `WindowToken`, workspace membership, stack order, or raw titles.
public struct RecoveryRecord: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var pid: Int32
    public var role: String
    public var subrole: String
    public var titleDigest: String
    public var ordinalAmongExactPeers: Int
    public var adoptionFrame: CGRect
    public var lastAppliedFrame: CGRect?
    public var stageIntent: Bool

    public init(bundleIdentifier: String,
                pid: Int32,
                role: String,
                subrole: String,
                titleDigest: String,
                ordinalAmongExactPeers: Int,
                adoptionFrame: CGRect,
                lastAppliedFrame: CGRect? = nil,
                stageIntent: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.titleDigest = titleDigest
        self.ordinalAmongExactPeers = ordinalAmongExactPeers
        self.adoptionFrame = adoptionFrame
        self.lastAppliedFrame = lastAppliedFrame
        self.stageIntent = stageIntent
    }

    /// A stable key for replacing an intent in a journal.  It deliberately
    /// excludes frame values, which can change after a confirmed placement.
    public var identityKey: String {
        [bundleIdentifier, String(pid), role, subrole, titleDigest,
         String(ordinalAmongExactPeers)].joined(separator: "\u{1F}")
    }
}

public struct RecoveryCandidate: Equatable, Sendable {
    public var bundleIdentifier: String
    public var pid: Int32
    public var role: String
    public var subrole: String
    public var titleDigest: String
    public var ordinalAmongExactPeers: Int
    public var frame: CGRect

    public init(bundleIdentifier: String,
                pid: Int32,
                role: String,
                subrole: String,
                titleDigest: String,
                ordinalAmongExactPeers: Int,
                frame: CGRect) {
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.titleDigest = titleDigest
        self.ordinalAmongExactPeers = ordinalAmongExactPeers
        self.frame = frame
    }
}

public enum RecoveryMatch: Equatable, Sendable {
    case none
    case unique(Int)
    case ambiguous([Int])

    public var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}

public enum RecoveryJournalError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidSchema(Int)
    case duplicateIdentity
    case malformed
}

/// The on-disk document envelope.  This is recovery state only; live Tiles
/// membership remains in `TilesSession` and is intentionally not Codable.
public struct RecoveryJournal: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    public private(set) var records: [RecoveryRecord]

    public init(schemaVersion: Int = RecoveryJournal.currentSchema,
                records: [RecoveryRecord] = []) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, records }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The schema is checked before the records are decoded so a future
        // document reports its schema rather than a decoding failure.
        let schema = try container.decode(Int.self, forKey: .schemaVersion)
        try Self.validateSchema(schema)
        self.schemaVersion = schema
        self.records = try container.decode([RecoveryRecord].self, forKey: .records)
        try Self.validateIdentities(records)
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(records, forKey: .records)
    }

    private static func validateSchema(_ version: Int) throws {
        guard version == currentSchema else {
            if version > currentSchema { throw RecoveryJournalError.unsupportedSchema(version) }
            throw RecoveryJournalError.invalidSchema(version)
        }
    }

    private static func validateIdentities(_ records: [RecoveryRecord]) throws {
        guard Set(records.map(\.identityKey)).count == records.count else {
            throw RecoveryJournalError.duplicateIdentity
        }
    }

    public func validate() throws {
        try Self.validateSchema(schemaVersion)
        try Self.validateIdentities(records)
    }

    public func adding(_ record: RecoveryRecord) -> RecoveryJournal {
        var copy = self
        copy.records.removeAll { $0.identityKey == record.identityKey }
        copy.records.append(record)
        return copy
    }

    public func removing(identityKey: String) -> RecoveryJournal {
        var copy = self
        copy.records.removeAll { $0.identityKey == identityKey }
        return copy
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> RecoveryJournal {
        try JSONDecoder().decode(RecoveryJournal.self, from: data)
    }
}

public enum RecoveryModel {
    /// Compare all strong fingerprint fields and require the current frame to
    /// remain compatible with the frame Tiles owned.  Exact matches are
    /// intentionally conservative; a moved window must be surfaced instead
    /// of being mutated by an ambiguous recovery.
    private static func matchingIndices(
        record: RecoveryRecord,
        candidates: [RecoveryCandidate],
        tolerance: CGFloat = 4
    ) -> [Int] {
        candidates.indices.filter { index in
            let candidate = candidates[index]
            guard candidate.bundleIdentifier == record.bundleIdentifier,
                  candidate.pid == record.pid,
                  candidate.role == record.role,
                  candidate.subrole == record.subrole,
                  candidate.titleDigest == record.titleDigest,
                  candidate.ordinalAmongExactPeers == record.ordinalAmongExactPeers
            else { return false }
            let expected = record.lastAppliedFrame ?? record.adoptionFrame
            return compatibleFrame(candidate.frame, with: expected, tolerance: tolerance)
        }
    }

    public static func match(
        record: RecoveryRecord,
        candidates: [RecoveryCandidate],
        tolerance: CGFloat = 4
    ) -> RecoveryMatch {
        let matches = matchingIndices(record: record, candidates: candidates, tolerance: tolerance)
        switch matches.count {
        case 0: return .none
        case 1: return .unique(matches[0])
        default: return .ambiguous(matches)
        }
    }

    public static func compatibleFrame(
        _ current: CGRect,
        with expected: CGRect,
        tolerance: CGFloat = 4
    ) -> Bool {
        abs(current.minX - expected.minX) <= tolerance &&
            abs(current.minY - expected.minY) <= tolerance &&
            abs(current.width - expected.width) <= tolerance &&
            abs(current.height - expected.height) <= tolerance
    }
}
