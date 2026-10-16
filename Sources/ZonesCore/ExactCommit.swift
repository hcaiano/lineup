import CoreGraphics

public struct FrameEffect<Window> {
    public let window: Window
    public let before: CGRect
    public let after: CGRect
    public let placement: AppZonePlacement?

    public init(window: Window, before: CGRect, after: CGRect, placement: AppZonePlacement? = nil) {
        self.window = window
        self.before = before
        self.after = after
        self.placement = placement
    }
}

public enum ExactCommit {
    /// Why a batch that had started moving windows was put back.
    public enum Rollback<Window> {
        case refused(Window)
        case changed
        case notSaved
    }

    public enum Outcome<Window> {
        case committed
        /// Stale before any write; nothing moved.
        case rejected
        /// Something moved, and every attempted frame was confirmed restored.
        case rolledBack(Rollback<Window>)
        case recovery([FrameEffect<Window>])

        public var isCommitted: Bool { if case .committed = self { return true }; return false }
    }

    public static func apply<Window>(_ effects: [FrameEffect<Window>],
                                      validate: () -> Bool,
                                      read: (Window) -> CGRect?,
                                      eligible: (Window) -> Bool,
                                      write: (Window, CGRect) -> Bool,
                                      persist: () throws -> Void) -> Outcome<Window> {
        guard validate(), effects.allSatisfy({ effect in
            eligible(effect.window) && read(effect.window).map {
                SnapRecords<Window>.matches($0, effect.before, originTolerance: 1, sizeTolerance: 1)
            } == true
        }) else { return .rejected }
        var attempted: [FrameEffect<Window>] = []
        for effect in effects {
            guard validate(), eligible(effect.window), let current = read(effect.window),
                  SnapRecords<Window>.matches(current, effect.before, originTolerance: 1, sizeTolerance: 1)
            else { return compensate(attempted, cause: .changed, read: read, write: write) }
            attempted.append(effect)
            guard write(effect.window, effect.after), let actual = read(effect.window),
                  SnapRecords<Window>.matches(actual, effect.after, originTolerance: 1, sizeTolerance: 1)
            else { return compensate(attempted, cause: .refused(effect.window), read: read, write: write) }
        }
        guard validate() else { return compensate(attempted, cause: .changed, read: read, write: write) }
        if let moved = effects.first(where: { effect in
            read(effect.window).map {
                SnapRecords<Window>.matches($0, effect.after, originTolerance: 1, sizeTolerance: 1)
            } != true
        }) { return compensate(attempted, cause: .refused(moved.window), read: read, write: write) }
        do { try persist() }
        catch { return compensate(attempted, cause: .notSaved, read: read, write: write) }
        return .committed
    }

    /// Restores in reverse order. An effect leaves the receipt when its frame is confirmed, or
    /// when `isGone` proves its window no longer exists. Unknown native state stays retained.
    public static func restore<Window>(_ receipt: [FrameEffect<Window>],
                                        read: (Window) -> CGRect?,
                                        write: (Window, CGRect) -> Bool,
                                        isGone: (Window) -> Bool) -> [FrameEffect<Window>] {
        var remaining: [FrameEffect<Window>] = []
        for effect in receipt.reversed() {
            if let current = read(effect.window),
               SnapRecords<Window>.matches(current, effect.before, originTolerance: 1, sizeTolerance: 1) {
                continue
            }
            let written = write(effect.window, effect.before)
            if written, let actual = read(effect.window),
               SnapRecords<Window>.matches(actual, effect.before, originTolerance: 1, sizeTolerance: 1) {
                continue
            }
            if !isGone(effect.window) { remaining.append(effect) }
        }
        return remaining.reversed()
    }

    private static func compensate<Window>(_ attempted: [FrameEffect<Window>], cause: Rollback<Window>,
                                            read: (Window) -> CGRect?,
                                            write: (Window, CGRect) -> Bool) -> Outcome<Window> {
        let remaining = restore(attempted, read: read, write: write, isGone: { _ in false })
        return remaining.isEmpty ? .rolledBack(cause) : .recovery(remaining)
    }
}
