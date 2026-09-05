import Foundation

/// The frozen candidate/action matrix as pure, deterministic policy.
///
/// Roll of accepted roles:
/// - Button, link, checkbox, radio, tab, menu item → `AXPress` only when advertised.
/// - Popup, menu trigger → `AXShowMenu` only when advertised.
/// - Nonsecure editable control → focus only when `.focus` was advertised (the AX adapter
///   advertises `.focus` only when the focused attribute is explicitly settable).
/// - Scroll region → scroll operations, surfaced only in scroll mode by the reducer; the
///   matrix itself is mode-independent.
/// - Generic/page groups, static text, images, unknown or custom roles with no advertised
///   capability → excluded.
///
/// Every candidate requires a fresh PID match, a matching window token, enabled/visible/
/// on-screen state, a valid finite frame, and an advertised capability. Secure fields,
/// disabled, hidden, zero-size, non-finite or off-screen geometry, Lineup-owned windows,
/// other applications' windows, and disconnected-display frames are rejected.
public enum HintEligibility {

    /// Rejection outcomes, in the deterministic order they are checked.
    public enum RejectionReason: Equatable, Sendable, Hashable, Codable, CaseIterable {
        case wrongPID
        case wrongWindow
        case lineupOwned
        case secure
        case disabled
        case notVisible
        case zeroSize
        case offScreen
        case noAdvertisedAction
    }

    public enum Decision: Equatable, Sendable {
        case accept(HintActionKind)
        case reject(RejectionReason)
    }

    /// The action kind a role must advertise to be actionable.
    public static func requiredAction(for role: HintRoleClass) -> HintActionKind? {
        switch role {
        case .button, .link, .checkbox, .radio, .tab, .menuItem: return .press
        case .popup, .menuTrigger: return .showMenu
        case .editable: return .focus
        case .scrollRegion: return .scroll
        case .other: return nil
        }
    }

    /// Evaluate one candidate against the captured context. Mode plays no part here: the
    /// reducer slices single-mode pools out of this mode-independent accepted set.
    public static func assess(
        _ candidate: HintCandidate,
        context: HintTargetContext
    ) -> Decision {
        if candidate.pid != context.pid { return .reject(.wrongPID) }
        // A Candidate must belong to one of the captured windows; PID-level context
        // (empty capture set) imposes no token constraint.
        if !context.windowTokens.isEmpty {
            guard let token = candidate.windowToken, context.windowTokens.contains(token) else {
                return .reject(.wrongWindow)
            }
        }
        if candidate.isOwnedByLineup { return .reject(.lineupOwned) }
        if candidate.isSecure { return .reject(.secure) }
        if !candidate.isEnabled { return .reject(.disabled) }
        if !candidate.isVisible { return .reject(.notVisible) }
        // Geometry is validated before eligibility: non-finite → offScreen,
        // non-positive size → zeroSize (progressive mapping of invalid frames).
        switch HintOverlayGeometry.validity(of: candidate.frame) {
        case .nonFinite: return .reject(.offScreen)
        case .nonPositiveSize: return .reject(.zeroSize)
        case .valid: break
        }
        // Partly on-screen controls are accepted; completely off every display (or flagged
        // off-screen by the adapter) are not. Disconnected displays contribute no screens
        // here, so stranded frames fail closed automatically.
        let onScreen = candidate.isOnScreen
            && HintOverlayGeometry.displayIndex(for: candidate.frame, screens: context.screens) != nil
        if !onScreen { return .reject(.offScreen) }

        guard let required = requiredAction(for: candidate.role) else { return .reject(.noAdvertisedAction) }
        guard candidate.advertisedActions.contains(required) else { return .reject(.noAdvertisedAction) }
        return .accept(required)
    }

    /// One accepted candidate plus its dispatch action and assigned display. Ordering here is
    /// the single deterministic presentation order used for labels, filtering, and invocation.
    public struct HintRankedCandidate: Hashable, Sendable {
        public let candidate: HintCandidate
        public let action: HintActionKind
        public let displayIndex: Int
    }

    /// Deterministic rank: display, then reading order (y, then x), then opaque token.
    public static func isRankedBefore(_ lhs: HintRankedCandidate, _ rhs: HintRankedCandidate) -> Bool {
        let lc = lhs.candidate, rc = rhs.candidate
        if lhs.displayIndex != rhs.displayIndex { return lhs.displayIndex < rhs.displayIndex }
        if lc.frame.minY != rc.frame.minY { return lc.frame.minY < rc.frame.minY }
        if lc.frame.minX != rc.frame.minX { return lc.frame.minX < rc.frame.minX }
        return lc.token.raw < rc.token.raw
    }

    /// Preparation output: ranked candidates in presentation order plus the count-only
    /// summary updates the caller folds into its scan summary. Candidate names and code
    /// paths stay out of the summary by construction.
    public struct HintPreparation: Hashable, Sendable {
        public var ranked: [HintRankedCandidate]
        /// Accepted candidates AFTER eligibility AND ancestry dedupe, BEFORE any cap.
        public var acceptedCandidates: Int
        public var candidateCapReached: Bool
    }

    /// Full preparation pipeline, in the frozen order:
    /// eligibility → ancestry-based dedupe → rank → candidate cap. Label allocation happens
    /// downstream and owns the label-capacity truncation signal.
    ///
    /// The dedupe step uses ONLY proven AX ancestry (`ancestorTokens`) and never merges
    /// pools: if either party is a scroll region, both states are kept. Geometry alone never
    /// proves a parent/child relationship, and candidates without ancestry history are never
    /// deduped away.
    public static func prepare(
        _ candidates: [HintCandidate],
        context: HintTargetContext,
        limits: HintScanLimits
    ) -> HintPreparation {
        var accepted: [(candidate: HintCandidate, action: HintActionKind)] = []
        accepted.reserveCapacity(candidates.count)
        for candidate in candidates {
            if case .accept(let action) = assess(candidate, context: context) {
                accepted.append((candidate, action))
            }
        }
        let (deduped, _) = dedupeProvenAncestry(accepted.map(\.candidate))
        let keeps = Set(deduped.map(\.token))
        let actionByToken = Dictionary(
            accepted.filter { keeps.contains($0.candidate.token) }.map { ($0.candidate.token, $0.action) },
            uniquingKeysWith: { first, _ in first }
        )
        var ranked = deduped.map { candidate -> HintRankedCandidate in
            let display = HintOverlayGeometry.displayIndex(for: candidate.frame, screens: context.screens) ?? Int.max
            return HintRankedCandidate(
                candidate: candidate,
                action: actionByToken[candidate.token] ?? requiredAction(for: candidate.role)!,
                displayIndex: display
            )
        }
        ranked.sort(by: HintEligibility.isRankedBefore)
        var candidateCapReached = false
        if ranked.count > limits.maxCandidates {
            ranked.removeLast(ranked.count - limits.maxCandidates)
            candidateCapReached = true
        }
        return HintPreparation(
            ranked: ranked,
            acceptedCandidates: deduped.count,
            candidateCapReached: candidateCapReached
        )
    }

    /// Ancestry-based parent/child dedupe, normal-control pool only. For a pair with proven
    /// ancestry between two NORMAL controls, the more specific descendant wins and the
    /// ancestor is dropped. Pools NEVER cross: if either party is a scroll region, both are
    /// kept (nested scroll regions are always retained). With no proven relationship, or
    /// missing ancestry data, both are kept. Determinism: discovery order decides nothing
    /// but tie stability (first-wins on equal tokens); the sort applied by `prepare` fixes
    /// the presentation order.
    public static func dedupeProvenAncestry(_ candidates: [HintCandidate]) -> (kept: [HintCandidate], removed: Int) {
        var kept: [HintCandidate] = []
        kept.reserveCapacity(candidates.count)
        var removed = 0
        for candidate in candidates {
            var shadowed = false
            var dropCandidates: [Int] = []
            for (keptIndex, existing) in kept.enumerated() {
                if existing.token == candidate.token {
                    // Duplicate tokens: keep the first occurrence.
                    shadowed = true
                    break
                }
                // Pools never cross: a scroll region on either side keeps both entries.
                if existing.role == .scrollRegion || candidate.role == .scrollRegion {
                    continue
                }
                if candidate.ancestorTokens.contains(existing.token) {
                    // `existing` is a proven ancestor of the new candidate.
                    dropCandidates.append(keptIndex)
                } else if existing.ancestorTokens.contains(candidate.token) {
                    // The new candidate is a proven ancestor of a kept descendant.
                    shadowed = true
                    break
                }
            }
            if shadowed {
                removed += 1
                continue
            }
            for index in dropCandidates.sorted(by: >) {
                kept.remove(at: index)
                removed += 1
            }
            kept.append(candidate)
        }
        return (kept, removed)
    }
}
