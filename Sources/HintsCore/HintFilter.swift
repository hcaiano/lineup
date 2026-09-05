import Foundation

/// Semantic keyboard input consumed by the session reducer. The Input lane translates
/// panel responder callbacks and committed text into these events; HintsCore owns their
/// meaning. The leading activation modifiers are handled by the separate modifier-release
/// barrier event rather than by modifier flags here.
public enum HintKeyCommand: Hashable, Sendable {
    /// A committed character from the panel (label key or search text).
    case character(Character)
    case backspace
    case escape
    case `return`
    /// The activation-map `/` key: enters accessible-name search.
    case slash
    /// Space: enters scroll-region selection (and returns to labels from scroll mode).
    case space
    case scroll(HintScrollCommand)
    /// Sent once when the physical activation modifiers have all been released.
    case modifierBarrierReleased
}

public enum HintScrollCommand: String, Codable, Hashable, Sendable, CaseIterable {
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case home
    case end
}

/// Incremental label filtering: keep candidates whose label (case-insensitively) starts with
/// the query. Deterministic by construction — the input order is already the canonical rank.
public enum HintFilter {
    /// Indices into `labels` that survive the query, in original order.
    public static func visibleIndices(labels: [String], query: String) -> [Int] {
        let needle = query.lowercased()
        if needle.isEmpty { return Array(labels.indices) }
        var result: [Int] = []
        result.reserveCapacity(labels.count)
        for (index, label) in labels.enumerated() {
            if label.lowercased().hasPrefix(needle) { result.append(index) }
        }
        return result
    }

    /// Full-label selection: the query must equal exactly one label (case-insensitively).
    /// Selection never auto-invokes — Return does. Returns the surviving index.
    public static func fullLabelSelection(labels: [String], query: String) -> Int? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }
        var found: Int?
        var duplicate = false
        for (index, label) in labels.enumerated() {
            if label.lowercased() == needle {
                if found != nil { duplicate = true; break }
                found = index
            }
        }
        return duplicate ? nil : found
    }
}

/// Accessible-name search over title, label, and description metadata from the AX tree.
/// Matching is case-insensitive substring. Result order is deterministic: title matches,
/// then label matches, then description matches; ties keep candidate order.
public enum HintSearch {
    public enum MatchKind: Int, CaseIterable, Sendable, Hashable {
        case title = 0
        case label = 1
        case description = 2
    }

    public static func firstMatch(query: String, in candidate: HintCandidate) -> MatchKind? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return nil }
        for kind in MatchKind.allCases {
            let text: String?
            switch kind {
            case .title: text = candidate.title
            case .label: text = candidate.label
            case .description: text = candidate.descriptiveText
            }
            if let text = text, text.lowercased().contains(needle) { return kind }
        }
        return nil
    }

    /// Indices into `candidates` whose accessible name matches `query`, ordered by match
    /// kind then original order. An empty query returns every index in original order.
    public static func orderedIndices(candidates: [HintCandidate], query: String) -> [Int] {
        if query.isEmpty { return Array(candidates.indices) }
        var buckets: [[Int]] = .init(repeating: [], count: MatchKind.allCases.count)
        for (index, candidate) in candidates.enumerated() {
            if let kind = firstMatch(query: query, in: candidate) {
                buckets[kind.rawValue].append(index)
            }
        }
        return buckets.flatMap { $0 }
    }
}
