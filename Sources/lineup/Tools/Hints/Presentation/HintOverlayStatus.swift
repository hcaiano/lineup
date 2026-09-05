import HintsCore

/// User-visible presentation states owned by the overlay lane. Candidate names and other AX text
/// are deliberately absent; the canvas only receives generated labels and the committed query.
enum HintOverlayStatus: Equatable, Sendable {
    case scanning
    case active
    case noMatches
    case accessibilityBlocked
    case captureUncertain
    case invocationFailed
    case cancelled
}

/// An asynchronous presentation invalidation. Phase 3 maps this small vocabulary to the matching
/// reducer cancellation event; Presentation has already hidden its windows when this fires.
enum HintOverlayInvalidation: Equatable, Sendable {
    case displayTopologyChanged
}

/// Privacy-minimized input for one canvas. Generated hint labels are retained, but accessible
/// names, descriptions, target tokens, and other candidate content never enter the view layer.
struct HintCanvasCandidate: Equatable, Sendable {
    var label: String
    var frame: HintRect
    var isSelected: Bool
}

struct HintCanvasContent: Equatable, Sendable {
    var key: HintSessionKey
    var status: HintOverlayStatus
    var mode: HintKeyboardMode
    var query: String
    var candidates: [HintCanvasCandidate]
    var visibleCount: Int
    var totalCandidates: Int
    var isTruncated: Bool

    var showsCandidates: Bool {
        status == .active
    }
}
