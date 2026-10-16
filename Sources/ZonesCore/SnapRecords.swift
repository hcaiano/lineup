import CoreGraphics

public struct SnapRecords<Window> {
    public struct MaximizeReceipt {
        public let before: CGRect
        public let applied: CGRect
        public let screenKey: String
    }

    public struct Entry {
        public let window: Window
        public var preFrame: CGRect
        public var snappedTo: CGRect
        public var placement: AppZonePlacement?
        public var maximize: MaximizeReceipt?
    }

    public enum MaximizeAction: Equatable {
        case none
        case maximize(CGRect)
        case returnTo(CGRect)
    }

    public private(set) var entries: [Entry] = []
    private let equal: (Window, Window) -> Bool
    private let capacity: Int

    public init(capacity: Int = 16, equal: @escaping (Window, Window) -> Bool) {
        self.capacity = max(1, capacity)
        self.equal = equal
    }

    public static func matches(_ a: CGRect, _ b: CGRect, originTolerance: CGFloat = 4,
                               sizeTolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= originTolerance && abs(a.minY - b.minY) <= originTolerance
            && abs(a.width - b.width) <= sizeTolerance && abs(a.height - b.height) <= sizeTolerance
    }

    public func entry(_ window: Window) -> Entry? { entries.first { equal($0.window, window) } }

    public mutating func recordSnap(_ window: Window, from: CGRect, to: CGRect,
                                    placement: AppZonePlacement? = nil) {
        let previous = entry(window)
        let pre = previous.flatMap { Self.matches($0.snappedTo, from) ? $0.preFrame : nil } ?? from
        forget(window)
        entries.append(Entry(window: window, preFrame: pre, snappedTo: to,
                             placement: placement?.zoneIndex == nil ? nil : placement, maximize: nil))
        trim()
    }

    public mutating func bind(_ window: Window, placement: AppZonePlacement?) {
        guard let index = entries.firstIndex(where: { equal($0.window, window) }) else { return }
        entries[index].placement = placement?.zoneIndex == nil ? nil : placement
    }

    public func preFrame(_ window: Window, current: CGRect, originTolerance: CGFloat = 4) -> CGRect? {
        guard let entry = entry(window),
              Self.matches(entry.snappedTo, current, originTolerance: originTolerance) else { return nil }
        return entry.preFrame
    }

    public mutating func maximizeAction(_ window: Window, current: CGRect, full: CGRect,
                                        screenKey: String) -> MaximizeAction {
        if let index = entries.firstIndex(where: { equal($0.window, window) }),
           let receipt = entries[index].maximize {
            if receipt.screenKey == screenKey && Self.matches(receipt.applied, current) {
                return .returnTo(receipt.before)
            }
            entries[index].maximize = nil
            entries[index].placement = nil
        }
        return Self.matches(current, full) ? .none : .maximize(full)
    }

    public mutating func recordMaximize(_ window: Window, action: MaximizeAction, from: CGRect,
                                        landed: CGRect, screenKey: String) {
        switch action {
        case .none: return
        case .maximize:
            if entry(window).map({ Self.matches($0.snappedTo, from) }) != true {
                recordSnap(window, from: from, to: landed)
            }
            guard let index = entries.firstIndex(where: { equal($0.window, window) }) else { return }
            entries[index].maximize = MaximizeReceipt(before: from, applied: landed, screenKey: screenKey)
            entries[index].snappedTo = landed
        case .returnTo:
            guard let index = entries.firstIndex(where: { equal($0.window, window) }) else { return }
            entries[index].snappedTo = landed
            if case .returnTo(let destination) = action,
               !Self.matches(landed, destination, originTolerance: 1, sizeTolerance: 1),
               let receipt = entries[index].maximize {
                entries[index].maximize = MaximizeReceipt(before: receipt.before, applied: landed, screenKey: receipt.screenKey)
            } else {
                entries[index].maximize = nil
            }
        }
    }

    public mutating func invalidatePlacements(on screenKeys: Set<String>) {
        for index in entries.indices {
            if let placement = entries[index].placement, screenKeys.contains(placement.screenKey) {
                entries[index].placement = nil
            }
        }
    }

    /// After a divider change on `display`, an unmoved record keeps its slot affinity only when
    /// its applied frame still matches that slot in the new layout.
    public mutating func rebasePlacements(on display: AppZonePlacement.Display, old: Node, new: Node) {
        for index in entries.indices {
            guard let placement = entries[index].placement, placement.screenKey == display.key,
                  placement.layout == old else { continue }
            let rebased = placement.rebased(to: new)
            entries[index].placement = rebased?.rect(on: display).map {
                Self.matches($0, entries[index].snappedTo, originTolerance: 1, sizeTolerance: 1)
            } == true ? rebased : nil
        }
    }

    public mutating func invalidateMaximize() {
        for index in entries.indices { entries[index].maximize = nil }
    }

    public mutating func forget(_ window: Window) { entries.removeAll { equal($0.window, window) } }
    public mutating func removeAll() { entries.removeAll() }
    private mutating func trim() {
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
