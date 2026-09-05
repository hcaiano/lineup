import Foundation

/// Opaque reference to one AX element held in a session-scoped token repository owned by
/// `HintAXService`. HintsCore never touches `AXUIElement`; adapters mint these tokens.
/// Tokens are GENERATION-BOUND: they can be reused or re-minted after a rescan, so they
/// are never usable as a cross-generation restoration key.
public struct HintTargetToken: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public var description: String { "HintTargetToken(\(raw.count) bytes)" }
}

/// Adapter-proven continuity identity for a control ACROSS rescans. The adapter asserts
/// (on its own evidence) that two captured elements are the same underlying control;
/// HintsCore treats this as an opaque key and derives nothing from it — never geometry,
/// label, AX text, window membership, or a target token raw value. Tokens are re-minted
/// per scan generation and MUST NOT carry continuity identity themselves.
public struct HintContinuityID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public var description: String { "HintContinuityID(\(raw.count) bytes)" }
}

/// The only operations Hints supports, matching the frozen candidate/action matrix.
/// There are deliberately no pointer/click/synthesis kinds: the allowlist is empty and no
/// dormant abstraction is built for it.
public enum HintActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case press
    case showMenu
    case focus
    case scroll
}

/// Classified role of an AX element, mapped by the AX adapter from role/subrole strings.
public enum HintRoleClass: String, Codable, CaseIterable, Hashable, Sendable {
    case button
    case link
    case checkbox
    case radio
    case tab
    case menuItem
    case popup
    case menuTrigger
    case editable
    case scrollRegion
    case other
}

/// One discoverable control, reduced to pure data by the AX adapter. Accessible
/// title/label/description are carried for selection/search only — there is no `description`
/// conformance or logging path that could emit user content.
public struct HintCandidate: Hashable, Codable, Sendable {
    public let token: HintTargetToken
    public let pid: Int32
    /// Opaque captured session-root membership token: identifies which participating
    /// root/window the candidate belongs to, matched against `HintTargetContext.windowTokens`.
    /// HintsCore never interprets the token's contents — only membership matters.
    public let windowToken: String?
    public let role: HintRoleClass
    public let subrole: String?
    /// Actions the element advertises right now. `.focus` is advertised only when the
    /// focused attribute is explicitly settable (the matrix's focus precondition).
    public let advertisedActions: Set<HintActionKind>
    public let title: String?
    public let label: String?
    public let descriptiveText: String?
    public let frame: HintRect
    public let isEnabled: Bool
    public let isVisible: Bool
    public let isOnScreen: Bool
    public let isSecure: Bool
    /// `true` for elements inside Lineup-owned windows; always rejected.
    public let isOwnedByLineup: Bool
    /// Proven AX ancestry: tokens of the candidate's ancestor chain (nearest ancestors
    /// first), supplied later by traversal. Empty means ancestry was unavailable, in which
    /// case ancestors are never deduped away. Non-empty ancestry is the ONLY basis for
    /// parent-child overlap dedupe — geometry alone proves nothing.
    public let ancestorTokens: [HintTargetToken]
    /// OPTIONAL adapter-proven continuity identity, stable across scan generations when
    /// present. Absent means the adapter has no such proof: selection restoration must
    /// treat the candidate as unlabeled by continuity (never an implicit fallback).
    public let continuity: HintContinuityID?

    public init(
        token: HintTargetToken,
        pid: Int32,
        windowToken: String? = nil,
        role: HintRoleClass,
        subrole: String? = nil,
        advertisedActions: Set<HintActionKind>,
        title: String? = nil,
        label: String? = nil,
        descriptiveText: String? = nil,
        frame: HintRect,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        isOnScreen: Bool = true,
        isSecure: Bool = false,
        isOwnedByLineup: Bool = false,
        ancestorTokens: [HintTargetToken] = [],
        continuity: HintContinuityID? = nil
    ) {
        self.token = token
        self.pid = pid
        self.windowToken = windowToken
        self.role = role
        self.subrole = subrole
        self.advertisedActions = advertisedActions
        self.title = title
        self.label = label
        self.descriptiveText = descriptiveText
        self.frame = frame
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.isOnScreen = isOnScreen
        self.isSecure = isSecure
        self.isOwnedByLineup = isOwnedByLineup
        self.ancestorTokens = ancestorTokens
        self.continuity = continuity
    }
}

/// Frozen scan budgets (Phase 0 safe defaults; Phase 5 profiling confirms, never loosens).
/// Values are immutable after construction and every constructor clamps each field into
/// `1...HintScanLimits`' frozen maximum, so no stored or constructed value can widen the
/// safety envelope; smaller positive budgets remain selectable for tests and tuning.
public struct HintScanLimits: Hashable, Codable, Sendable {
    /// Per AX messaging-call timeout in milliseconds.
    public let perCallTimeoutMs: Int
    public let maxDepth: Int
    public let maxVisitedNodes: Int
    public let maxCandidates: Int
    /// Wall-clock scan deadline in milliseconds.
    public let wallClockMs: Int

    private static let perCallTimeoutCeiling = 50
    private static let maxDepthCeiling = 40
    private static let maxVisitedNodesCeiling = 4_000
    private static let maxCandidatesCeiling = 1_500
    private static let wallClockCeiling = 750

    public static let standard = HintScanLimits()

    private static func clamped(_ value: Int, within ceiling: Int) -> Int {
        guard value > 0 else { return ceiling }
        return Swift.min(value, ceiling)
    }

    /// Out-of-range inputs clamp: non-positive fields take the frozen maximum, over-large
    /// fields clamp down to it. This constructor cannot loosen safety. Default arguments
    /// must be public-legal literals (a public default expression may not reference a
    /// private symbol), so the frozen ceilings are duplicated here and asserted by the
    /// `.standard` equality checks in the test suite.
    public init(
        perCallTimeoutMs: Int = 50,
        maxDepth: Int = 40,
        maxVisitedNodes: Int = 4_000,
        maxCandidates: Int = 1_500,
        wallClockMs: Int = 750
    ) {
        self.perCallTimeoutMs = HintScanLimits.clamped(perCallTimeoutMs, within: HintScanLimits.perCallTimeoutCeiling)
        self.maxDepth = HintScanLimits.clamped(maxDepth, within: HintScanLimits.maxDepthCeiling)
        self.maxVisitedNodes = HintScanLimits.clamped(maxVisitedNodes, within: HintScanLimits.maxVisitedNodesCeiling)
        self.maxCandidates = HintScanLimits.clamped(maxCandidates, within: HintScanLimits.maxCandidatesCeiling)
        self.wallClockMs = HintScanLimits.clamped(wallClockMs, within: HintScanLimits.wallClockCeiling)
    }

    /// Decoded limits re-clamp so a corrupted or hostile config cannot loosen budgets.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: Int].self)
        self.init(
            perCallTimeoutMs: raw["perCallTimeoutMs"] ?? HintScanLimits.perCallTimeoutCeiling,
            maxDepth: raw["maxDepth"] ?? HintScanLimits.maxDepthCeiling,
            maxVisitedNodes: raw["maxVisitedNodes"] ?? HintScanLimits.maxVisitedNodesCeiling,
            maxCandidates: raw["maxCandidates"] ?? HintScanLimits.maxCandidatesCeiling,
            wallClockMs: raw["wallClockMs"] ?? HintScanLimits.wallClockCeiling
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([
            "perCallTimeoutMs": perCallTimeoutMs,
            "maxDepth": maxDepth,
            "maxVisitedNodes": maxVisitedNodes,
            "maxCandidates": maxCandidates,
            "wallClockMs": wallClockMs,
        ])
    }
}

public enum HintTruncationReason: String, Codable, CaseIterable, Hashable, Sendable {
    case maxDepthReached
    case nodeBudgetExhausted
    case candidateCapReached
    case labelCapacityReached
    case wallClockExceeded
    case perCallTimeoutAborted
}

/// Count-only scan diagnostics, deliberately separate from any candidate payload. Summaries
/// never contain control names, text values, queries, or any user content: only counts,
/// timings-shaped counters, and truncation reasons — sufficient for status UI.
public struct HintScanSummary: Hashable, Codable, Sendable {
    public var visitedNodes: Int
    public var deepestDepth: Int
    /// Candidates the scanner discovered in total, before policy.
    public var discoveredCandidates: Int
    /// Candidates surviving eligibility and dedupe, before any cap or label capacity cut.
    public var acceptedCandidates: Int
    /// Candidates retained for presentation after the candidate cap and label allocation.
    public var retainedCandidates: Int
    public var truncationReasons: Set<HintTruncationReason>

    public init(
        visitedNodes: Int = 0,
        deepestDepth: Int = 0,
        discoveredCandidates: Int = 0,
        acceptedCandidates: Int = 0,
        retainedCandidates: Int = 0,
        truncationReasons: Set<HintTruncationReason> = []
    ) {
        self.visitedNodes = visitedNodes
        self.deepestDepth = deepestDepth
        self.discoveredCandidates = discoveredCandidates
        self.acceptedCandidates = acceptedCandidates
        self.retainedCandidates = retainedCandidates
        self.truncationReasons = truncationReasons
    }

    public var isTruncated: Bool { !truncationReasons.isEmpty }
}

/// Pure scan output: raw scanner output candidates (highest-ranked NOT yet guaranteed —
/// ranking happens in preparation) and the count-only summary.
public struct HintScanResult: Hashable, Codable, Sendable {
    public var candidates: [HintCandidate]
    public var summary: HintScanSummary

    public init(candidates: [HintCandidate], summary: HintScanSummary = HintScanSummary()) {
        self.candidates = candidates
        self.summary = summary
    }
}

/// One scan request: a session key (id + generation), the captured target context, and the
/// budgets to enforce. Emitted as an effect after activation and after rescans.
public struct HintScanPlan: Hashable, Codable, Sendable {
    public var key: HintSessionKey
    public var context: HintTargetContext
    public var limits: HintScanLimits

    public init(key: HintSessionKey, context: HintTargetContext, limits: HintScanLimits) {
        self.key = key
        self.context = context
        self.limits = limits
    }
}

/// Identity of one Hints session lifetime: a monotonically increasing session id plus the
/// scan generation within it. Every asynchronous result must carry its key so stale results
/// are discarded.
public struct HintSessionKey: Hashable, Codable, Sendable {
    public var id: UInt64
    public var generation: Int

    public init(id: UInt64, generation: Int) {
        self.id = id
        self.generation = generation
    }

    public var nextGeneration: HintSessionKey {
        HintSessionKey(id: id, generation: generation + 1)
    }
}

/// Frontmost application context captured before any UI shows. The captured windows are
/// collected as a set of opaque root/window tokens: a candidate must carry one of them
/// when the set is nonempty, while an empty set allows PID-level context (candidate tokens
/// unconstrained). Candidates keep a singular `windowToken` because each belongs to exactly
/// one captured root/window.
public struct HintTargetContext: Hashable, Codable, Sendable {
    public var pid: Int32
    /// Captured participating window tokens (primary window, sheets/popovers presented on
    /// it, etc.). Empty means "PID-level context": no token constraint is enforced.
    public var windowTokens: Set<String>
    /// Participating display bounds in global coordinates, in the caller's stable order.
    public var screens: [HintRect]

    public init(pid: Int32, windowTokens: Set<String> = [], screens: [HintRect]) {
        self.pid = pid
        self.windowTokens = windowTokens
        self.screens = screens
    }
}

/// The action a candidate runs when invoked, resolved at acceptance time.
public struct HintLabelledCandidate: Hashable, Codable, Sendable {
    /// Stable index of the candidate inside the prepared, ranked list.
    public let index: Int
    public let candidate: HintCandidate
    public let label: String
    public let action: HintActionKind

    public init(index: Int, candidate: HintCandidate, label: String, action: HintActionKind) {
        self.index = index
        self.candidate = candidate
        self.label = label
        self.action = action
    }
}
