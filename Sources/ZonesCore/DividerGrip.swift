import CoreGraphics
import Foundation

/// The divider grip, shown to people as the handle on the line between two zones. It appears only
/// after the pointer pauses on a line while the drag bind is held, and never sits under that
/// pointer, so a click or window drag at that point still reaches the window below.
public enum DividerGrip {
    public static let length: CGFloat = 48
    public static let thickness: CGFloat = 28
    public static let clearance: CGFloat = 32
    public static let endInset: CGFloat = 14
    public static let keepDistance: CGFloat = 120
    public static let dragThreshold: CGFloat = 3
    public static let segmentThickness: CGFloat = 6
    public static let segmentInset: CGFloat = 4

    /// The line under `pointer`. Near a T-junction the line the pointer is closest to wins, and the
    /// nested line wins a tie. Comparing lengths would pick the wrong line on an ultrawide display,
    /// where a nested row can be longer than the root column is tall.
    public static func handle(at pointer: CGPoint, in handles: [Layout.DividerHandle]) -> Layout.DividerHandle? {
        func distance(_ handle: Layout.DividerHandle) -> CGFloat {
            handle.axis == .vertical ? abs(pointer.x - handle.line.midX) : abs(pointer.y - handle.line.midY)
        }
        return handles.filter { $0.line.contains(pointer) }.min {
            distance($0) != distance($1) ? distance($0) < distance($1) : $0.path.count > $1.path.count
        }
    }

    /// Grip rect for `handle` revealed at `pointer`, on the side with more room, or nil when
    /// neither side of the pointer fits.
    public static func rect(for handle: Layout.DividerHandle, pointer: CGPoint) -> CGRect? {
        let vertical = handle.axis == .vertical
        let along = vertical ? pointer.y : pointer.x
        let start = vertical ? handle.container.minY : handle.container.minX
        let end = vertical ? handle.container.maxY : handle.container.maxX
        let lo = start + endInset + length / 2
        let hi = end - endInset - length / 2
        guard lo <= hi else { return nil }
        let offset = length / 2 + clearance
        let sides = hi - along >= along - lo ? [along + offset, along - offset] : [along - offset, along + offset]
        guard let center = sides.first(where: { $0 >= lo && $0 <= hi }) else { return nil }
        return vertical
            ? CGRect(x: handle.line.midX - thickness / 2, y: center - length / 2, width: thickness, height: length)
            : CGRect(x: center - length / 2, y: handle.line.midY - thickness / 2, width: length, height: thickness)
    }

    /// The painted line shown with the grip: the whole segment this divider moves, so a nested
    /// line or a line with no windows beside it is visible.
    public static func segment(for handle: Layout.DividerHandle) -> CGRect {
        handle.axis == .vertical
            ? CGRect(x: handle.line.midX - segmentThickness / 2, y: handle.container.minY + segmentInset,
                     width: segmentThickness, height: max(0, handle.container.height - segmentInset * 2))
            : CGRect(x: handle.container.minX + segmentInset, y: handle.line.midY - segmentThickness / 2,
                     width: max(0, handle.container.width - segmentInset * 2), height: segmentThickness)
    }

    /// True while the current grip should stay put for this pointer sample.
    public static func keeps(_ grip: CGRect, handle: Layout.DividerHandle, pointer: CGPoint) -> Bool {
        if grip.insetBy(dx: -8, dy: -8).contains(pointer) { return true }
        let distance = handle.axis == .vertical ? abs(pointer.y - grip.midY) : abs(pointer.x - grip.midX)
        return handle.line.contains(pointer) && distance <= keepDistance
    }

    public enum Phase: Equatable { case revealed, armed, pressed(CGPoint), dragging, pinned }

    public enum Input: Equatable {
        case pointer(inside: Bool)
        case press(CGPoint, bindHeld: Bool)
        case drag(CGPoint, bindHeld: Bool)
        case release(bindHeld: Bool)
        case bindUp
        case nudge(Int)
        case confirm
        case escape
        case outsidePress
        case resignedKey
        case invalidated
    }

    public enum Effect: Equatable { case none, arm, disarm, begin, preview(CGPoint), pin, nudge(Int), commit, cancel }

    /// A nil phase means the grip is hidden. A pinned grip survives bind release; a mouse drag does not.
    public static func next(_ phase: Phase, _ input: Input) -> (phase: Phase?, effect: Effect) {
        switch (phase, input) {
        case (_, .escape), (_, .invalidated), (_, .outsidePress):
            return (nil, .cancel)
        case (.revealed, .pointer(inside: true)):
            return (.armed, .arm)
        case (.armed, .pointer(inside: false)):
            return (.revealed, .disarm)
        case (.armed, .press(let point, bindHeld: true)):
            return (.pressed(point), .begin)
        case (.armed, .press(_, bindHeld: false)), (.revealed, .bindUp), (.armed, .bindUp):
            return (nil, .cancel)
        case (.pressed(let origin), .drag(let point, let bindHeld)):
            guard hypot(point.x - origin.x, point.y - origin.y) > dragThreshold else { return (phase, .none) }
            return bindHeld ? (.dragging, .preview(point)) : (nil, .cancel)
        case (.pressed, .release):
            return (.pinned, .pin)
        case (.dragging, .drag(let point, bindHeld: true)):
            return (.dragging, .preview(point))
        case (.dragging, .drag(_, bindHeld: false)), (.dragging, .release(bindHeld: false)), (.dragging, .bindUp):
            return (nil, .cancel)
        case (.dragging, .release(bindHeld: true)):
            return (nil, .commit)
        case (.pinned, .nudge(let delta)):
            return (.pinned, .nudge(delta))
        case (.pinned, .confirm):
            return (nil, .commit)
        case (.pinned, .press(let point, bindHeld: true)):
            return (.pressed(point), .none)
        case (.pinned, .resignedKey):
            return (nil, .cancel)
        default:
            return (phase, .none)
        }
    }
}

/// Rest-to-reveal: a grip appears only after the pointer pauses on one line. Crossing lines on the
/// way somewhere else shows nothing, and how long the bind was held before does not count.
public struct DividerDwell: Equatable {
    public static let delay: TimeInterval = 0.3
    public static let stillness: CGFloat = 8
    /// Input that means the person is doing something else. Key-down is absent on purpose: a held
    /// custom-bind key, or Hyperkey's remapped Caps Lock, repeats key-down without key-up, while a
    /// typed key always ends with key-up.
    public static let interruptions: [CGEventType] = [.keyUp, .flagsChanged, .scrollWheel,
                                                     .leftMouseDown, .rightMouseDown, .otherMouseDown]

    public let screenKey: String
    public let path: [Int]
    public let index: Int
    public let line: CGRect
    public let anchor: CGPoint
    public let start: TimeInterval

    public enum Verdict: Equatable { case reveal, wait(TimeInterval), drop }

    /// The dwell after a pointer sample: unchanged while the pointer stays near its anchor on the
    /// same line, restarted at this sample otherwise, and nil off every line.
    public static func track(_ current: DividerDwell?, handle: Layout.DividerHandle?, screenKey: String,
                             pointer: CGPoint, now: TimeInterval) -> DividerDwell? {
        guard let handle else { return nil }
        if let current, current.rests(on: handle, screenKey: screenKey, pointer: pointer) { return current }
        return DividerDwell(screenKey: screenKey, path: handle.path, index: handle.index, line: handle.line,
                            anchor: pointer, start: now)
    }

    /// Whether this dwell may reveal now. `interruptionAges` holds the age in seconds of the latest
    /// input of each `interruptions` type; every one must predate the dwell. An unreadable or
    /// negative age never counts as resting.
    public func verdict(handle: Layout.DividerHandle?, screenKey: String, pointer: CGPoint,
                        now: TimeInterval, interruptionAges: [TimeInterval]) -> Verdict {
        let elapsed = now - start
        guard let handle, rests(on: handle, screenKey: screenKey, pointer: pointer), elapsed >= 0,
              !interruptionAges.isEmpty,
              interruptionAges.allSatisfy({ $0.isFinite && $0 >= 0 && $0 > elapsed }) else { return .drop }
        // A millisecond of slack absorbs clock rounding; timers never fire meaningfully early.
        return elapsed < Self.delay - 0.001 ? .wait(Self.delay - elapsed) : .reveal
    }

    private func rests(on handle: Layout.DividerHandle, screenKey: String, pointer: CGPoint) -> Bool {
        screenKey == self.screenKey && handle.path == path && handle.index == index && handle.line == line
            && hypot(pointer.x - anchor.x, pointer.y - anchor.y) <= Self.stillness
    }
}
