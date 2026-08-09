import Foundation

public enum LineupAppConfigError: Error, Equatable {
    /// The file exists but isn't valid JSON / isn't an envelope. Never overwritten.
    case unreadable
    /// Written by a NEWER Lineup. Run defaults, block writes, leave the file alone.
    case unsupportedSchema(Int)
    /// A save was attempted while writes are blocked.
    case writesBlocked
}

/// The single authoritative in-memory copy of `config.json`.
///
/// Ports Lineup 1.x's proven `zones.json` discipline verbatim:
/// - a read failure NEVER overwrites the user's file; it blocks writes instead
/// - a reset preserves the rejected bytes FIRST and aborts if preservation fails
/// - writes are atomic and stably formatted (`.prettyPrinted, .sortedKeys`)
///
/// All three tools mutate through this one object (`update`/`setSettings`), so a save of one
/// section can never drop a sibling's — there is no second, stale envelope anywhere.
public final class LineupAppConfigStore {
    public enum State: Equatable {
        case ok
        case unreadable
        case unsupportedSchema(Int)
    }

    public enum LoadOutcome: Equatable {
        case loaded          // existing file, read and accepted
        case fresh           // no file yet; defaults in memory, writable
        case failed(State)   // file present but rejected; defaults in memory, writes BLOCKED
    }

    public let url: URL
    public private(set) var config: LineupAppConfig
    public private(set) var state: State = .ok

    /// Blocked whenever the on-disk file was rejected, so a later save cannot clobber it.
    public var canWrite: Bool { state == .ok }

    public var blockedMessage: String? {
        switch state {
        case .ok:
            return nil
        case .unreadable:
            return "Settings couldn’t be read. Your file was left untouched — changes won’t be saved."
        case .unsupportedSchema(let v):
            return "Settings were written by a newer version of Lineup (format \(v)). "
                + "Changes won’t be saved until you update."
        }
    }

    public init(url: URL, config: LineupAppConfig = LineupAppConfig()) {
        self.url = url
        self.config = config
    }

    // MARK: - Load

    @discardableResult
    public func load() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = LineupAppConfig()
            state = .ok
            return .fresh
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LineupAppConfig.self, from: data) else {
            config = LineupAppConfig()
            state = .unreadable
            return .failed(.unreadable)
        }
        if decoded.schemaVersion > LineupAppConfig.currentSchema {
            config = LineupAppConfig()
            state = .unsupportedSchema(decoded.schemaVersion)
            return .failed(.unsupportedSchema(decoded.schemaVersion))
        }
        config = decoded
        state = .ok
        return .loaded
    }

    // MARK: - Write

    /// Mutate the single authoritative envelope and persist it atomically. The in-memory copy
    /// is only updated when the write succeeds, so a failed save never leaves live state
    /// disagreeing with disk.
    public func update(_ body: (inout LineupAppConfig) throws -> Void) throws {
        guard canWrite else { throw LineupAppConfigError.writesBlocked }
        var copy = config
        try body(&copy)
        try write(copy)
        config = copy
    }

    /// Replace one tool's settings blob. Siblings and every `enabled` flag are preserved.
    public func setSettings<T: Encodable>(_ value: T, for id: ToolID) throws {
        try update { try $0.setSettings(value, for: id) }
    }

    public func setEnabled(_ enabled: Bool, for id: ToolID) throws {
        try update { $0.setEnabled(enabled, for: id) }
    }

    public func save() throws {
        guard canWrite else { throw LineupAppConfigError.writesBlocked }
        try write(config)
    }

    private func write(_ value: LineupAppConfig) throws {
        let data = try value.encoded()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Reset

    /// Millisecond-precision stamp so rapid rejected copies don't collide.
    public static func timestamp(_ date: Date = Date()) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    /// User-triggered recovery from `.unreadable` / `.unsupportedSchema`.
    /// Preserves the rejected bytes FIRST; if that fails the reset is aborted and the file is
    /// left exactly as it was, with writes still blocked.
    public func reset(now: Int = LineupAppConfigStore.timestamp()) throws {
        if let data = try? Data(contentsOf: url) {
            let rejected = url.deletingPathExtension().appendingPathExtension("rejected-\(now).json")
            try data.write(to: rejected, options: .atomic) // throws -> abort reset (no clobber)
        }
        let fresh = LineupAppConfig()
        try write(fresh)
        config = fresh
        state = .ok
    }
}
