import CoreGraphics
import ZonesCore

func runSnapRecordsTests() {
    let original = CGRect(x: 100, y: 80, width: 600, height: 400)
    let zone = CGRect(x: 0, y: 0, width: 500, height: 900)
    let full = CGRect(x: 0, y: 0, width: 1000, height: 900)
    var records = SnapRecords<String>(capacity: 2, equal: ==)
    records.recordSnap("one", from: original, to: zone)
    let maximize = records.maximizeAction("one", current: zone, full: full, screenKey: "display")
    check(maximize == .maximize(full), "maximize targets full usable frame")
    records.recordMaximize("one", action: maximize, from: zone, landed: full, screenKey: "display")
    check(records.preFrame("one", current: full) == original, "maximize preserves first-snap Restore history")
    check(records.maximizeAction("one", current: full, full: full, screenKey: "display") == .returnTo(zone),
          "second full command returns immediately preceding frame")
    check(records.maximizeAction("one", current: full, full: full, screenKey: "display") == .returnTo(zone),
          "uncommitted return remains retryable")
    let partial = zone.offsetBy(dx: 30, dy: 0)
    records.recordMaximize("one", action: .returnTo(zone), from: full, landed: partial, screenKey: "display")
    check(records.maximizeAction("one", current: partial, full: full, screenKey: "display") == .returnTo(zone),
          "a known partial return keeps the original return destination retryable")
    check(records.preFrame("one", current: partial) == original,
          "a known partial return preserves first-snap Restore history")
    records.recordMaximize("one", action: .returnTo(zone), from: full, landed: zone, screenKey: "display")
    check(records.preFrame("one", current: zone) == original, "return keeps original Restore")
    records.recordMaximize("one", action: .maximize(full), from: zone, landed: full, screenKey: "display")
    records.recordSnap("one", from: full, to: zone)
    check(records.maximizeAction("one", current: zone, full: full, screenKey: "display") == .maximize(full),
          "ordinary snap ends maximize return")
    records.recordMaximize("one", action: .maximize(full), from: zone, landed: full, screenKey: "display")
    check(records.maximizeAction("one", current: full, full: full, screenKey: "other") == .none,
          "changed display invalidates return and already-full is no-op")
    check(records.maximizeAction("new", current: full, full: full, screenKey: "display") == .none,
          "already-full without receipt does nothing")
    let moved = CGRect(x: 120, y: 140, width: 610, height: 420)
    records.recordMaximize("one", action: .maximize(full), from: zone, landed: full, screenKey: "display")
    check(records.maximizeAction("one", current: moved, full: full, screenKey: "display") == .maximize(full),
          "external movement starts new maximize")
    records.recordSnap("two", from: original, to: zone)
    records.recordSnap("three", from: original, to: zone)
    check(records.entries.map(\.window) == ["two", "three"], "bounded history evicts oldest window")
    records.recordSnap("two", from: moved, to: full)
    check(records.preFrame("two", current: full) == moved, "external placement reseeds original history")
    records.removeAll()
    records.recordSnap("fresh", from: original, to: zone)
    check(records.entries.map(\.window) == ["fresh"], "reset releases old window history")
}
