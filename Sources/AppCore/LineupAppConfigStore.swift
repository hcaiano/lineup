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
/// All tools mutate through this one object (`update`/`setSettings`), so a save of one
/// section can never drop a sibling's — there is no second, stale envelope anywhere.
public final class LineupAppConfigStore {
    public final class ToolChangeObservation {
        fileprivate let id = UUID()
        private weak var store: LineupAppConfigStore?

        fileprivate init(store: LineupAppConfigStore) {
            self.store = store
        }

        public func cancel() {
            store?.removeToolChangeObserver(id)
            store = nil
        }

        deinit { cancel() }
    }

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
    private var toolChangeObservers: [UUID: (Set<ToolID>) -> Void] = [:]
    private let toolChangeObserverLock = NSLock()

    /// Blocked whenever the on-disk file was rejected, so a later save cannot clobber it.
    public var canWrite: Bool { state == .ok }

    public var blockedMessage: String? {
        switch state {
        case .ok:
            return nil
        case .unreadable:
            return "Settings couldn’t be read. Your file was left untouched, so changes won’t be saved."
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
        // A mutation that changes nothing writes nothing. Without this, everything that "saves
        // the current state" — a display change while an import is deferred, a status refresh —
        // rewrites the file all tools share for no reason.
        guard copy != config else { return }
        let changedTools = Set(ToolID.all.filter { copy.section(for: $0) != config.section(for: $0) })
        try write(copy)
        config = copy
        publishToolChanges(changedTools)
    }

    /// Observe successful tool-section writes. A failed or no-op write publishes nothing.
    /// The caller retains the returned token for as long as it wants updates.
    public func observeToolChanges(_ observer: @escaping (Set<ToolID>) -> Void) -> ToolChangeObservation {
        let token = ToolChangeObservation(store: self)
        toolChangeObserverLock.lock()
        toolChangeObservers[token.id] = observer
        toolChangeObserverLock.unlock()
        return token
    }

    private func removeToolChangeObserver(_ id: UUID) {
        toolChangeObserverLock.lock()
        toolChangeObservers[id] = nil
        toolChangeObserverLock.unlock()
    }

    private func publishToolChanges(_ changedTools: Set<ToolID>) {
        guard !changedTools.isEmpty else { return }
        toolChangeObserverLock.lock()
        let observers = Array(toolChangeObservers.values)
        toolChangeObserverLock.unlock()
        for observer in observers { observer(changedTools) }
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
        // `try?` here would treat "the file is unreadable" (bad permissions, an I/O error — the
        // very cases a reset is reached from) as "there is no file", and the fresh write below
        // would destroy bytes that were never preserved. Only a genuinely ABSENT file skips
        // preservation; a read that fails aborts the reset.
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)        // throws -> abort reset (no clobber)
            let rejected = url.deletingPathExtension().appendingPathExtension("rejected-\(now).json")
            try data.write(to: rejected, options: .atomic) // throws -> abort reset (no clobber)
        }
        let fresh = LineupAppConfig()
        let changedTools = Set(ToolID.all.filter { fresh.section(for: $0) != config.section(for: $0) })
        try write(fresh)
        config = fresh
        state = .ok
        publishToolChanges(changedTools)
    }
}
