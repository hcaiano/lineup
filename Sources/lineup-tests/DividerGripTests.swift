import CoreGraphics
import Foundation
import ZonesCore

func runDividerGripTests() {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 800)
    func handles(_ root: Node, _ box: CGRect = container) -> [Layout.DividerHandle] {
        Layout.dividerHandles(root, container: box, pixelsWide: Int(box.width) * 2, thickness: 24)
    }
    let rows = Node.split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf])
    let stacked = handles(rows)[0]
    let titleBar = CGPoint(x: 300, y: 396)
    check(DividerGrip.rect(for: stacked, pointer: titleBar) == CGRect(x: 332, y: 386, width: 48, height: 28),
          "a grip revealed over a title bar sits 32 points along the divider, clear of the pointer")

    let grip = DividerGrip.rect(for: stacked, pointer: titleBar)!
    check(DividerGrip.keeps(grip, handle: stacked, pointer: CGPoint(x: 330, y: 396))
            && !grip.contains(CGPoint(x: 330, y: 396)) && grip.contains(CGPoint(x: 340, y: 396)),
          "the grip stays put while the pointer approaches it along the divider")
    check(!DividerGrip.keeps(grip, handle: stacked, pointer: CGPoint(x: 500, y: 396)),
          "moving 144 points along the divider leaves the grip's keep region")
    check(!DividerGrip.keeps(grip, handle: stacked, pointer: CGPoint(x: 300, y: 450)), "leaving the divider band leaves it too")
    check(DividerGrip.segment(for: stacked) == CGRect(x: 4, y: 397, width: 992, height: 6),
          "the painted line spans its whole divider, inset four points from each end")

    let tee = Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [rows, .leaf])
    let teeHandles = handles(tee)
    let inner = teeHandles.first { $0.path == [0] }!
    let nearJunction = CGPoint(x: 494, y: 400)
    check(DividerGrip.handle(at: nearJunction, in: teeHandles).map { $0.path == [0] && $0.axis == .horizontal } == true
            && DividerGrip.handle(at: CGPoint(x: 499, y: 410), in: teeHandles).map { $0.path == [] } == true
            && DividerGrip.handle(at: CGPoint(x: 494, y: 600), in: teeHandles).map { $0.path == [] } == true
            && DividerGrip.handle(at: CGPoint(x: 300, y: 600), in: teeHandles) == nil,
          "at a T-junction the line nearest the pointer wins; elsewhere only a containing line counts")
    let wide = handles(tee, CGRect(x: 0, y: 0, width: 5120, height: 1410))
    check(DividerGrip.handle(at: CGPoint(x: 2554, y: 707), in: wide).map { $0.path == [0] } == true
            && DividerGrip.handle(at: CGPoint(x: 2559, y: 704), in: wide).map { $0.path == [0] } == true,
          "on an ultrawide display a long nested row still wins where the pointer is on it, and wins a tie")
    let innerGrip = DividerGrip.rect(for: inner, pointer: nearJunction)
    check(innerGrip == CGRect(x: 414, y: 386, width: 48, height: 28) && innerGrip.map { !$0.contains(nearJunction) } == true
            && innerGrip.map { 500 - $0.maxX >= 14 } == true,
          "a nested grip near a T-junction stays inside its column, clear of the root divider")
    check(DividerGrip.segment(for: inner) == CGRect(x: 4, y: 397, width: 492, height: 6),
          "a nested line paints only its own column")

    func short(_ height: CGFloat) -> Layout.DividerHandle {
        let fraction = Double((container.height - height) / container.height)
        let root = Node.split(axis: .horizontal, dividers: [Boundary(fraction, .fraction)], children: [.leaf, .halves])
        return handles(root).first { $0.path == [1] }!
    }
    let eighty = short(80)
    check(stride(from: 0, through: 80, by: 1).allSatisfy {
        DividerGrip.rect(for: eighty, pointer: CGPoint(x: 500, y: $0)) == nil
    }, "an 80 point divider never shows a grip")
    let hundredTwenty = short(120)
    let placed = stride(from: CGFloat(0), through: 120, by: 1).map { y -> (CGFloat, CGRect?) in
        (y, DividerGrip.rect(for: hundredTwenty, pointer: CGPoint(x: 500, y: y)))
    }
    check(placed.allSatisfy { y, rect in (rect != nil) == (y <= 26 || y >= 94) }
            && placed.allSatisfy { y, rect in rect.map { !$0.contains(CGPoint(x: 500, y: y)) } ?? true },
          "a 120 point divider shows a grip only within 26 points of either end, never under the pointer")

    let negative = CGRect(x: -1280, y: -200, width: 1280, height: 800)
    let left = handles(.halves, negative)[0]
    let leftGrip = DividerGrip.rect(for: left, pointer: CGPoint(x: -640, y: 100))
    check(leftGrip == CGRect(x: -654, y: 132, width: 28, height: 48) && leftGrip.map { negative.contains($0) } == true,
          "a negative-origin display keeps the grip inside its divider container")

    func run(_ inputs: [DividerGrip.Input], from phase: DividerGrip.Phase = .revealed)
        -> (DividerGrip.Phase?, [DividerGrip.Effect]) {
        var current: DividerGrip.Phase? = phase
        var effects: [DividerGrip.Effect] = []
        for input in inputs {
            guard let phase = current else { break }
            let step = DividerGrip.next(phase, input)
            current = step.phase
            effects.append(step.effect)
        }
        return (current, effects)
    }
    let origin = CGPoint(x: 460, y: 400)
    let moved = CGPoint(x: 500, y: 400)
    let drag = run([.pointer(inside: true), .press(origin, bindHeld: true), .drag(moved, bindHeld: true), .release(bindHeld: true)])
    check(drag.0 == nil && drag.1 == [.arm, .begin, .preview(moved), .commit],
          "entering, pressing, dragging and releasing with the bind commits once")
    check(run([.press(origin, bindHeld: true)]) == (.revealed, [.none]), "a press cannot reach a revealed grip")
    check(run([.pointer(inside: true), .press(origin, bindHeld: false)]) == (nil, [.arm, .cancel]),
          "a press just after the bind lifted cancels without a session")
    check(run([.pointer(inside: true), .pointer(inside: false)]) == (.revealed, [.arm, .disarm]),
          "leaving an armed grip makes it click-through again")
    let pin = run([.pointer(inside: true), .press(origin, bindHeld: true), .drag(CGPoint(x: 462, y: 401), bindHeld: true),
                   .bindUp, .release(bindHeld: false), .bindUp, .nudge(1), .nudge(10), .confirm])
    check(pin.0 == nil && pin.1 == [.arm, .begin, .none, .none, .pin, .none, .nudge(1), .nudge(10), .commit],
          "a stationary click pins even when the bind lifts before mouse-up, then arrows and Return work without it")
    check(run([.press(origin, bindHeld: true), .drag(moved, bindHeld: true), .bindUp], from: .armed) == (nil, [.begin, .preview(moved), .cancel]),
          "releasing the bind during a mouse drag cancels it")
    check(run([.press(origin, bindHeld: true), .drag(moved, bindHeld: false)], from: .armed) == (nil, [.begin, .cancel]),
          "a drag that begins after the bind lifted cancels")
    for ending in [DividerGrip.Input.escape, .outsidePress, .resignedKey, .invalidated] {
        check(run([ending], from: .pinned) == (nil, [.cancel]), "a pinned grip cancels on \(ending)")
    }
    check(run([.press(origin, bindHeld: false), .press(origin, bindHeld: true), .release(bindHeld: false)], from: .pinned)
            == (.pinned, [.none, .none, .pin]),
          "pressing a pinned grip without the bind does nothing; with it, the session continues")
    check(run([.confirm, .nudge(1)], from: .armed) == (.armed, [.none, .none]), "keyboard input needs a pinned grip")

    let column = handles(.halves)[0]
    let rest = CGPoint(x: 502, y: 300)
    let calm: TimeInterval = 600
    func track(_ current: DividerDwell?, _ point: CGPoint, at time: TimeInterval,
               on handle: Layout.DividerHandle? = column, screen: String = "a") -> DividerDwell? {
        DividerDwell.track(current, handle: handle, screenKey: screen, pointer: point, now: time)
    }
    let dwell = track(nil, rest, at: 10)!
    check(dwell.screenKey == "a" && dwell.path == [] && dwell.index == 0 && dwell.line == column.line
            && dwell.anchor == rest && dwell.start == 10,
          "a pause starts at the first sample on a line")
    check(track(nil, CGPoint(x: 300, y: 300), at: 10, on: nil) == nil && track(dwell, CGPoint(x: 300, y: 300), at: 10.1, on: nil) == nil,
          "a sample off every line starts or keeps nothing")
    check(track(dwell, CGPoint(x: 505, y: 306), at: 10.2) == dwell, "jitter within eight points keeps the pause")
    check(track(dwell, CGPoint(x: 502, y: 320), at: 10.2)?.start == 10.2 && track(dwell, CGPoint(x: 502, y: 320), at: 10.2)?.anchor.y == 320,
          "moving twenty points along the line restarts the pause")
    check(track(dwell, rest, at: 10.2, screen: "b")?.start == 10.2, "the same point on another display restarts the pause")
    var remaining: TimeInterval?
    if case .wait(let time) = dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.1, interruptionAges: [calm, calm]) {
        remaining = time
    }
    check(remaining.map { abs($0 - 0.2) < 1e-9 } == true, "an early fire waits for the rest of the delay")
    check(dwell.verdict(handle: column, screenKey: "a", pointer: CGPoint(x: 503, y: 302), now: 10.3, interruptionAges: [calm, calm]) == .reveal,
          "resting three tenths of a second reveals")
    check(dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, 0.2]) == .drop
            && dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [0.3, calm]) == .drop
            && dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [0.31, calm]) == .reveal,
          "input during the pause drops it; input just before the pause does not")
    check(dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, .nan, calm]) == .drop
            && dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, .infinity]) == .drop
            && dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, -1]) == .drop
            && dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: []) == .drop
            && dwell.verdict(handle: column, screenKey: "a", pointer: rest, now: 9.9, interruptionAges: [calm, calm]) == .drop,
          "any unreadable, negative or missing input age, or a clock before the pause, never reveals")
    check(dwell.verdict(handle: column, screenKey: "a", pointer: CGPoint(x: 502, y: 310), now: 10.3, interruptionAges: [calm, calm]) == .drop
            && dwell.verdict(handle: nil, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, calm]) == .drop
            && dwell.verdict(handle: column, screenKey: "b", pointer: rest, now: 10.3, interruptionAges: [calm, calm]) == .drop,
          "a pointer that moved off its anchor, off the line or to another display drops the pause")
    let shifted = handles(Node.split(axis: .vertical, dividers: [Boundary(0.6, .fraction)], children: [.leaf, .leaf]))[0]
    check(dwell.verdict(handle: shifted, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, calm]) == .drop
            && dwell.verdict(handle: inner, screenKey: "a", pointer: rest, now: 10.3, interruptionAges: [calm, calm]) == .drop,
          "a changed layout or a different line drops the pause")
}
