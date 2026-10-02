import Foundation

/// The scroll axes to reverse.
public struct ScrollAxes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let vertical = ScrollAxes(rawValue: 1 << 0)
    public static let horizontal = ScrollAxes(rawValue: 1 << 1)
}

/// The reversal in force for each device.
public struct ScrollReversal: Equatable, Sendable {
    public var mouse: ScrollAxes
    public var trackpad: ScrollAxes

    public init(mouse: ScrollAxes = [], trackpad: ScrollAxes = []) {
        self.mouse = mouse
        self.trackpad = trackpad
    }

    public var isEmpty: Bool { mouse.isEmpty && trackpad.isEmpty }

    public func axes(for device: ScrollDevice) -> ScrollAxes {
        device == .mouse ? mouse : trackpad
    }
}

/// The scroll and momentum phases of one event, as Core Graphics reports them.
public struct ScrollPhase: Equatable, Sendable {
    public var scroll: Int64
    public var momentum: Int64

    public init(scroll: Int64 = 0, momentum: Int64 = 0) {
        self.scroll = scroll
        self.momentum = momentum
    }

    // `CGScrollPhase` and `CGMomentumScrollPhase` raw values.
    static let began: Int64 = 1
    static let cancelled: Int64 = 8
    static let mayBegin: Int64 = 128
    static let momentumEnd: Int64 = 3

    var startsGesture: Bool { scroll == Self.began || scroll == Self.mayBegin }
    var isPhased: Bool { scroll != 0 || momentum != 0 }
    var endsSequence: Bool { scroll == Self.cancelled || momentum == Self.momentumEnd }
}

/// Where a scroll event came from.
public enum ScrollSource: Equatable, Sendable {
    /// Posted by an app, with no HID event attached.
    case software
    /// A HID event whose sending service cannot be found.
    case unresolved
    /// A HID event from a known service; `nil` when it is neither a mouse nor a trackpad.
    case device(ScrollDevice?)
}

/// Decides which axes of each scroll event to reverse. Owned by the event-tap thread.
///
/// Each event is classified by the HID service that sent it. A gesture and its momentum keep the
/// device that began the gesture, so inertia cannot change direction when one of its HID events
/// has an unresolved sender. Software events never join a gesture and are always left unchanged,
/// as is every other unidentified event.
public struct ScrollFilter: Sendable {
    private var gestureDevice: ScrollDevice?

    public init() {}

    public mutating func axes(source: ScrollSource, phase: ScrollPhase,
                              reversal: ScrollReversal) -> ScrollAxes {
        let device: ScrollDevice?
        switch source {
        case .software:
            return []
        case .device(let sender):
            if phase.startsGesture || (phase.isPhased && sender != nil) { gestureDevice = sender }
            device = sender
        case .unresolved:
            if phase.startsGesture { gestureDevice = nil }
            device = phase.isPhased ? gestureDevice : nil
        }
        if phase.endsSequence { gestureDevice = nil }
        return device.map(reversal.axes(for:)) ?? []
    }
}

/// Every delta a scroll event carries. Reversal changes only the sign, so speed and inertia are
/// preserved.
public struct ScrollDeltas: Equatable, Sendable {
    public var line: (y: Int64, x: Int64)
    public var point: (y: Double, x: Double)
    public var fixed: (y: Double, x: Double)
    /// The attached HID event's values, which WebKit reads instead of the Core Graphics fields.
    public var hid: (y: Double, x: Double)?

    public init(line: (y: Int64, x: Int64), point: (y: Double, x: Double),
                fixed: (y: Double, x: Double), hid: (y: Double, x: Double)? = nil) {
        self.line = line
        self.point = point
        self.fixed = fixed
        self.hid = hid
    }

    public func reversed(_ axes: ScrollAxes) -> ScrollDeltas {
        var out = self
        if axes.contains(.vertical) {
            out.line.y = -line.y
            out.point.y = -point.y
            out.fixed.y = -fixed.y
            out.hid?.y = -(hid?.y ?? 0)
        }
        if axes.contains(.horizontal) {
            out.line.x = -line.x
            out.point.x = -point.x
            out.fixed.x = -fixed.x
            out.hid?.x = -(hid?.x ?? 0)
        }
        return out
    }

    public static func == (a: ScrollDeltas, b: ScrollDeltas) -> Bool {
        a.line == b.line && a.point == b.point && a.fixed == b.fixed
            && a.hid?.y == b.hid?.y && a.hid?.x == b.hid?.x
    }
}
