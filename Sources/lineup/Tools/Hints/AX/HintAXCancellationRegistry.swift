import Foundation

// Lock-protected cancellation registry for the Hints AX lane.
//
// Contract (Phase 2A ruling C): public release/discard/stop operations mark state
// SYNCHRONOUSLY under this lock, before any serial-queue cleanup is enqueued, so an
// in-flight bounded operation observes the mark at its next boundary (before/after every
// AX message, before dequeue, before child expansion, before publishing). The serial
// executor remains the ONLY place element references are mutated or released; this
// registry holds no AX values at all.

final class HintAXCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()

    /// Pending captures discarded (by opaque pending ID).
    private var discardedPending: Set<String> = []
    /// Fully cancelled target generations (exact full key).
    private var cancelledGenerations: Set<HintSessionKey> = []
    /// Fully cancelled sessions (by owner id).
    private var cancelledSessions: Set<UInt64> = []
    /// The SINGLE authoritative active full-key binding per session owner id. Filled at
    /// adoption (generation 0) and advanced EXACTLY by authorized `releaseGeneration`
    /// calls; an authorized session release removes the binding. This is what lets a
    /// synchronous release decide exact ownership while AX work is in flight.
    private var activeKeys: [UInt64: HintSessionKey] = [:]
    /// Permanent stop; a stopped instance can never reopen.
    private var stopped = false

    // MARK: Permanent stop

    /// Stops permanently; the active-key bindings go with the session state (fail closed).
    func markStopped() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        activeKeys.removeAll()
    }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    // MARK: Active full-key binding (synchronous ownership authorization)

    /// Binds `key` as the session owner's active full key. Returns `true` only when the
    /// binding succeeded: a STOPPED registry, an already-cancelled session owner id, an
    /// already-cancelled exact generation, or a CONFLICTING existing binding (a different
    /// key owns this session id) all reject atomically under the lock. Re-binding the SAME
    /// exact key is idempotent and returns `true` so an adoption retry converges. Adoption
    /// MUST guard this result: a `false` binding means the adoption never proceeds to
    /// cancellable validation or publication.
    @discardableResult
    func bindActiveKey(_ key: HintSessionKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { return false }
        if cancelledSessions.contains(key.id) { return false }
        if cancelledGenerations.contains(key) { return false }
        if let existing = activeKeys[key.id] {
            return existing == key // idempotent same-exact-key retry
        }
        activeKeys[key.id] = key
        return true
    }

    func activeKey(for id: UInt64) -> HintSessionKey? {
        lock.lock(); defer { lock.unlock() }
        return stopped ? nil : activeKeys[id]
    }

    /// Authorizes a generation release ONLY when `expected` exactly equals the bound
    /// active key. Under the SAME lock section: marks that exact generation cancelled and
    /// ADVANCES authorization to `expected.nextGeneration` (the next scan's key). A
    /// stale/foreign/future key returns nil and marks NOTHING — no cancellation, no
    /// advancement, no poisoning of a future key.
    func authorizeGenerationRelease(_ expected: HintSessionKey) -> HintSessionKey? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, activeKeys[expected.id] == expected else { return nil }
        cancelledGenerations.insert(expected)
        let next = expected.nextGeneration
        activeKeys[expected.id] = next
        return next
    }

    /// Authorizes a whole-session release ONLY on an exact active full-key match: marks
    /// the owner id cancelled and removes its binding. A stale/foreign/future key returns
    /// false and cancels NOTHING (the owner id and roots stay untouched).
    func authorizeSessionRelease(_ expected: HintSessionKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, activeKeys[expected.id] == expected else { return false }
        cancelledSessions.insert(expected.id)
        activeKeys.removeValue(forKey: expected.id)
        return true
    }

    // MARK: Pending captures

    func discardPending(_ id: HintPendingCaptureID) {
        lock.lock(); defer { lock.unlock() }
        discardedPending.insert(id.raw)
    }

    func isPendingDiscarded(_ id: HintPendingCaptureID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped || discardedPending.contains(id.raw)
    }

    // MARK: Sessions and generations

    /// Marks the whole session cancelled. Every operation for that owner id (any
    /// generation) fails closed afterwards.
    func markSessionCancelled(id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        cancelledSessions.insert(id)
    }

    /// Marks one exact target generation cancelled.
    func markGenerationCancelled(_ key: HintSessionKey) {
        lock.lock(); defer { lock.unlock() }
        cancelledGenerations.insert(key)
    }

    /// A key is live only when it is not stopped, its owner session is not cancelled, and
    /// its EXACT generation is not cancelled.
    func isCancelled(_ key: HintSessionKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
            || cancelledSessions.contains(key.id)
            || cancelledGenerations.contains(key)
    }

    /// A session owner id is live only when it is not stopped and not cancelled.
    func isSessionCancelled(id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped || cancelledSessions.contains(id)
    }
}
