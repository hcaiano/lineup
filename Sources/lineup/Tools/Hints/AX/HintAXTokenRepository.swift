import ApplicationServices
import Foundation

// Per-generation target repository for the Hints AX lane.
//
// Contract (Phase 2A ruling A):
//   * Keyed by the FULL session owner identity (`HintSessionKey`, id + generation). No
//     entry is ever addressed by a generation Int alone.
//   * Every entry records the exact full key it was minted under and the proven
//     `HintAXRootID` it descends from, so invocation can re-prove provenance later.
//   * Elements resolve ONLY on the service's serial executor; no AXUIElement leaves the
//     lane. Release paths drop references only.
//   * At most one live target generation per session is enforced outside (service), and
//     `release(fullKey:)` is the serialized completion step that unblocks the next scan.

struct HintAXTargetEntry {
    let element: AXUIElement
    let key: HintSessionKey
    /// The proven session root this target descends from (adoption/promotion path proof).
    let rootID: HintAXRootID
    /// Tokens of the proven ancestor chain at discovery time, nearest ancestor first.
    let ancestorTokens: [HintTargetToken]
}

final class HintAXTokenRepository: @unchecked Sendable {
    private var entries: [String: HintAXTargetEntry] = [:]
    private var tokenOrder: [String] = []

    // MARK: Insertion (serial executor only)

    /// Registers `element` under a freshly minted opaque token bound to the FULL key and
    /// the proven root. Token minting is delegated in full to the injected factory; tokens
    /// are never derived from element identity, text, or geometry and never mint
    /// continuity.
    func insert(
        element: AXUIElement,
        key: HintSessionKey,
        rootID: HintAXRootID,
        ancestorTokens: [HintTargetToken],
        factory: HintTokenFactory
    ) -> HintTargetToken {
        let token = HintTargetToken(factory.mint())
        entries[token.raw] = HintAXTargetEntry(
            element: element, key: key, rootID: rootID, ancestorTokens: ancestorTokens
        )
        tokenOrder.append(token.raw)
        return token
    }

    // MARK: Lookup (serial executor only)

    /// The element behind `token`, but only when the entry's FULL key matches exactly
    /// (owner id AND generation). Unknown, stale, or foreign tokens resolve to nil.
    func element(for token: HintTargetToken, in key: HintSessionKey) -> AXUIElement? {
        guard let entry = entries[token.raw], entry.key == key else { return nil }
        return entry.element
    }

    /// The stored provenance for `token`, when present and owned by the exact full key.
    func provenance(for token: HintTargetToken, in key: HintSessionKey) -> (rootID: HintAXRootID, ancestors: [HintTargetToken])? {
        guard let entry = entries[token.raw], entry.key == key else { return nil }
        return (entry.rootID, entry.ancestorTokens)
    }

    /// Tokens minted under the FULL key, in insertion order.
    func tokens(in key: HintSessionKey) -> [String] {
        tokenOrder.filter { entries[$0]?.key == key }
    }

    /// Whether any entry was minted for the exact full key (a completed live generation).
    func hasGeneration(_ key: HintSessionKey) -> Bool {
        entries.values.contains { $0.key == key }
    }

    var count: Int { entries.count }

    // MARK: Release (serial executor only)

    /// Drops every entry owned by `fullKey` whose token is NOT in `tokens`. Called right
    /// after a scan publication so ONLY the final retained actionable candidate tokens for
    /// that generation remain in the repository (noncandidate/container/overflow entries
    /// are dropped and released with their generation). Entries owned by other keys are
    /// untouched. Idempotent; returns the released count.
    @discardableResult
    func retain(tokens: Set<String>, fullKey: HintSessionKey) -> Int {
        let doomed = entries.filter { $0.value.key == fullKey && !tokens.contains($0.key) }
        guard !doomed.isEmpty else { return 0 }
        for raw in doomed.keys { entries.removeValue(forKey: raw) }
        tokenOrder.removeAll { entries[$0] == nil }
        return doomed.count
    }

    /// Drops every entry minted under the FULL key. Idempotent; returns released count.
    /// This is used as the serialized completion of `releaseGeneration(_:)`.
    @discardableResult
    func release(fullKey: HintSessionKey) -> Int {
        let doomed = entries.filter { $0.value.key == fullKey }
        guard !doomed.isEmpty else { return 0 }
        for raw in doomed.keys { entries.removeValue(forKey: raw) }
        tokenOrder.removeAll { entries[$0] == nil }
        return doomed.count
    }

    /// Drops every entry minted under the session owner id (ALL generations). Idempotent.
    @discardableResult
    func release(sessionId: UInt64) -> Int {
        let doomed = entries.filter { $0.value.key.id == sessionId }
        guard !doomed.isEmpty else { return 0 }
        for raw in doomed.keys { entries.removeValue(forKey: raw) }
        tokenOrder.removeAll { entries[$0] == nil }
        return doomed.count
    }

    /// Drops everything. Used by permanent stop. Idempotent.
    func reset() {
        entries.removeAll()
        tokenOrder.removeAll()
    }
}
