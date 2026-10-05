import Foundation

/// One snapshot shared by lifecycle decisions and the scroll callback.
public struct ScrollOptions: Equatable, Sendable {
    public var reversal: ScrollReversal
    public var wheelLines: Int?

    public init(reversal: ScrollReversal = .init(), wheelLines: Int? = nil) {
        self.reversal = reversal
        self.wheelLines = wheelLines
    }

    public var isEmpty: Bool { reversal.isEmpty && wheelLines == nil }

    /// A constant vertical line delta for a physical wheel event, before direction reversal.
    /// Continuous surfaces and phased gestures must retain their precision and momentum.
    public func wheelStep(source: ScrollSource, phase: ScrollPhase,
                          isContinuous: Bool, pointDelta: Double) -> Int64? {
        guard let wheelLines, source == .device(.mouse), !isContinuous,
              !phase.isPhased, pointDelta.isFinite, pointDelta != 0 else { return nil }
        return Int64(min(10, max(1, wheelLines))) * (pointDelta > 0 ? 1 : -1)
    }
}
