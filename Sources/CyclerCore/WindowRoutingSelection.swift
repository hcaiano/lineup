import Foundation

/// The pure part of Cycler's Tiles-aware window choice. AppKit supplies stable window IDs and
/// live routing classifications; this selector decides which candidate indices remain eligible.
package enum WindowRoutingDisposition: Equatable, Sendable {
    case currentContext
    case unmanaged
    case inactiveWorkspace(workspace: Int, focusEpoch: UInt64)
    case unavailable(message: String)
}

package struct WindowRoutingCandidate: Equatable, Sendable {
    package var windowID: UInt32
    package var isMinimized: Bool
    package var disposition: WindowRoutingDisposition

    package init(windowID: UInt32, isMinimized: Bool,
                 disposition: WindowRoutingDisposition) {
        self.windowID = windowID
        self.isMinimized = isMinimized
        self.disposition = disposition
    }
}

package struct WindowRoutingSelection: Equatable, Sendable {
    package var indices: [Int]
    package var hasCurrentCandidates: Bool
    package var unavailableMessage: String?
}

package enum WindowRoutingSelector {
    /// Visible current-context windows win. If none exist, one current minimized window wins by
    /// stable ID. Otherwise, one inactive-workspace window wins by recent Tiles focus then ID.
    package static func select(_ candidates: [WindowRoutingCandidate]) -> WindowRoutingSelection {
        var currentVisible: [Int] = []
        var currentMinimized: [Int] = []
        var inactive: [(index: Int, focusEpoch: UInt64, windowID: UInt32)] = []
        var unavailableMessage: String?

        for (index, candidate) in candidates.enumerated() {
            switch candidate.disposition {
            case .currentContext, .unmanaged:
                if candidate.isMinimized { currentMinimized.append(index) }
                else { currentVisible.append(index) }
            case .inactiveWorkspace(_, let focusEpoch):
                inactive.append((index, focusEpoch, candidate.windowID))
            case .unavailable(let message):
                if unavailableMessage == nil { unavailableMessage = message }
            }
        }

        if !currentVisible.isEmpty {
            return WindowRoutingSelection(indices: currentVisible,
                                          hasCurrentCandidates: true,
                                          unavailableMessage: unavailableMessage)
        }
        if let minimized = currentMinimized.min(by: {
            candidates[$0].windowID < candidates[$1].windowID
        }) {
            return WindowRoutingSelection(indices: [minimized],
                                          hasCurrentCandidates: true,
                                          unavailableMessage: unavailableMessage)
        }
        let fallback = inactive.min { lhs, rhs in
            if lhs.focusEpoch != rhs.focusEpoch { return lhs.focusEpoch > rhs.focusEpoch }
            return lhs.windowID < rhs.windowID
        }
        return WindowRoutingSelection(indices: fallback.map { [$0.index] } ?? [],
                                      hasCurrentCandidates: false,
                                      unavailableMessage: unavailableMessage)
    }
}
