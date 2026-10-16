import CoreGraphics
import ZonesCore

func runZoneEffectsTests() {
    let before = CGRect(x: 100, y: 80, width: 300, height: 250)
    let after = CGRect(x: 0, y: 0, width: 500, height: 900)
    let effects = (1...3).map { FrameEffect(window: $0, before: before, after: after) }
    enum SaveError: Error { case refused }
    for failure in 0...4 {
        var frames = [1: before, 2: before, 3: before]
        var writes: [Int] = []
        var saves = 0
        let outcome = ExactCommit.apply(effects, validate: { true }, read: { frames[$0] }, eligible: { _ in true },
            write: { window, target in
                writes.append(window)
                frames[window] = target
                return !(target == after && window == failure)
            }, persist: { saves += 1; if failure == 4 { throw SaveError.refused } })
        if failure == 0 {
            if case .committed = outcome { check(true, "exact batch succeeds") }
            else { check(false, "exact batch succeeds") }
            check(frames == [1: after, 2: after, 3: after] && writes == [1, 2, 3] && saves == 1,
                  "success applies every displayed frame before one save")
        } else {
            switch (failure, outcome) {
            case (1...3, .rolledBack(.refused(let window))):
                check(window == failure, "write refusal names the refusing window")
            case (4, .rolledBack(.notSaved)):
                check(true, "failed save is reported as not saved")
            default:
                check(false, "failure \(failure) compensated with its cause, got \(outcome)")
            }
            let expectedWrites = failure == 1 ? [1, 1] : failure == 2 ? [1, 2, 2, 1] : [1, 2, 3, 3, 2, 1]
            check(frames == [1: before, 2: before, 3: before] && writes == expectedWrites,
                  "first/middle/last/save failure reverses all partial writes")
            check(saves == (failure == 4 ? 1 : 0), "write failure never persists")
        }
    }
    var frames = [1: before, 2: before, 3: before]
    var rollbackBlocked = true
    let failed = ExactCommit.apply(effects, validate: { true }, read: { frames[$0] }, eligible: { _ in true },
        write: { window, target in
            if target == before && rollbackBlocked { return false }
            frames[window] = target
            return window != 2 || target == before
        }, persist: {})
    if case .recovery(let receipt) = failed {
        check(receipt.map(\.window) == [1, 2], "incomplete rollback retains exactly touched windows")
        rollbackBlocked = false
        let remaining = ExactCommit.restore(receipt, read: { frames[$0] }, write: { frames[$0] = $1; return true },
                                            isGone: { _ in false })
        check(remaining.isEmpty && frames == [1: before, 2: before, 3: before], "retry restores original frames")
    } else { check(false, "incomplete rollback retains receipt") }
    var writes = 0
    frames[2] = after
    let stale = ExactCommit.apply(effects, validate: { true }, read: { frames[$0] }, eligible: { _ in true },
                                 write: { _, _ in writes += 1; return true }, persist: {})
    if case .rejected = stale {
        check(writes == 0 && frames[2] == after, "stale participant rejects before any native write")
    } else { check(false, "stale participant rejects") }

    let screen = AppZonePlacement.Display(key: "display", frame: CGRect(x: -1000, y: 0, width: 1000, height: 900),
                                          visibleFrame: CGRect(x: -1000, y: 0, width: 1000, height: 900), pixelsWide: 2000)
    let old = Node.halves
    let new = LayoutEdit.setDivider(old, at: [], index: 0, fraction: 0.6, rootPixelsWide: 2000)
    var records = SnapRecords<String>(equal: ==)
    let placement = AppZonePlacement(screenKey: "display", layout: old, zoneIndex: 0,
                                    unitRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    records.recordSnap("upper", from: before, to: CGRect(x: -1000, y: 450, width: 500, height: 450), placement: placement)
    records.recordSnap("centered", from: before, to: before)
    let plan = ZoneScene.divider(records: records, screen: screen, old: old, new: new)
    check(plan.map(\.window) == ["upper"] && plan.first?.after == CGRect(x: -1000, y: 450, width: 600, height: 450),
          "divider reflows only exact occupants with same leaf affinity")
    check(plan.first?.placement?.layout == new && plan.first?.placement?.unitRect == CGRect(x: 0, y: 0.5, width: 1, height: 0.5),
          "divider rebase preserves shared relative position")
    let three = Node.columns([Boundary(0.25, .fraction), Boundary(0.75, .fraction)])
    let edited = LayoutEdit.setDivider(three, at: [], index: 0, fraction: 0.3, rootPixelsWide: 2000)
    var neighbors = SnapRecords<String>(equal: ==)
    neighbors.recordSnap("left", from: before, to: CGRect(x: -1000, y: 0, width: 250, height: 900),
        placement: AppZonePlacement(screenKey: "display", layout: three, zoneIndex: 0,
                                    unitRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    neighbors.recordSnap("unrelated", from: before, to: CGRect(x: -250, y: 0, width: 250, height: 900),
        placement: AppZonePlacement(screenKey: "display", layout: three, zoneIndex: 2,
                                    unitRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
    let neighborsPlan = ZoneScene.divider(records: neighbors, screen: screen, old: three, new: edited)
    check(neighborsPlan.map(\.window) == ["left"] && neighborsPlan.first?.after == CGRect(x: -1000, y: 0, width: 300, height: 900),
          "divider never writes an unrelated unchanged leaf")
    neighbors.invalidatePlacements(on: ["display"])
    check(ZoneScene.divider(records: neighbors, screen: screen, old: three, new: edited).isEmpty,
          "editor invalidation prevents old leaf affinity resurrecting after topology is recreated")
    records.rebasePlacements(on: screen, old: old, new: new)
    let next = LayoutEdit.setDivider(new, at: [], index: 0, fraction: 0.7, rootPixelsWide: 2000)
    let nextPlan = ZoneScene.divider(records: records, screen: screen, old: new, new: next)
    check(nextPlan.isEmpty, "rebased affinity cannot reflow a window whose applied frame still belongs to old geometry")
    if let effect = plan.first {
        records.recordSnap(effect.window, from: effect.before, to: effect.after, placement: effect.placement)
    }
    let committedNext = ZoneScene.divider(records: records, screen: screen, old: new, new: next)
    check(committedNext.first?.after == CGRect(x: -1000, y: 450, width: 700, height: 450),
          "committed shared half follows repeated divider edits")
    check(placement.rebased(to: .thirds) == nil && placement.rebased(to: new)?.rect(on: screen) == CGRect(x: -1000, y: 450, width: 600, height: 450),
          "same topology rebase refuses reused leaf after structural edit")

    var moving = [1: before, 2: before]
    let changed = ExactCommit.apply(Array(effects.prefix(2)), validate: { true }, read: { moving[$0] }, eligible: { _ in true },
        write: { window, target in
            moving[window] = target
            if window == 1 && target == after { moving[2] = CGRect(x: 5, y: 5, width: 50, height: 50) }
            return true
        }, persist: {})
    if case .rolledBack(.changed) = changed { check(moving[1] == before, "a participant changed mid-batch is put back as changed") }
    else { check(false, "a participant changed mid-batch is put back as changed, got \(changed)") }

    var survivors = [1: after, 2: after, 3: after]
    let receipt = effects.map { FrameEffect(window: $0.window, before: before, after: after) }
    let unresolved = ExactCommit.restore(receipt, read: { $0 == 2 ? nil : survivors[$0] },
        write: { window, target in
            guard window != 2 else { return false }
            survivors[window] = target
            return window != 3
        }, isGone: { $0 == 2 })
    check(unresolved.map(\.window) == [3] && survivors[1] == before,
          "retry drops only a definitively gone window, keeps an unresolved one, and restores the rest")
    let unknown = ExactCommit.restore(receipt, read: { _ in nil }, write: { _, _ in false }, isGone: { _ in false })
    check(unknown.map(\.window) == [1, 2, 3], "unreadable windows of unknown state stay in the receipt")

    var hidden = SnapRecords<String>(equal: ==)
    let columns = AppZonePlacement(screenKey: "display", layout: three, zoneIndex: 0, unitRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    let right = AppZonePlacement(screenKey: "display", layout: three, zoneIndex: 2, unitRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    hidden.recordSnap("offDesktop", from: before, to: CGRect(x: -1000, y: 0, width: 250, height: 900), placement: columns)
    hidden.recordSnap("unchanged", from: before, to: CGRect(x: -250, y: 0, width: 250, height: 900), placement: right)
    hidden.rebasePlacements(on: screen, old: three, new: edited)
    check(hidden.entry("offDesktop")?.placement == nil && hidden.entry("offDesktop")?.preFrame == before,
          "an unmoved hidden window loses stale slot affinity but keeps Restore history")
    check(hidden.entry("unchanged")?.placement?.layout == edited, "an unchanged leaf keeps its affinity in the new layout")
}
