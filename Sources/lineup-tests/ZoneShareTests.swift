import CoreGraphics
import ZonesCore

func runZoneShareTests() {
    let zone = CGRect(x: 0, y: 0, width: 600, height: 900)
    let targets = ShareTarget.targets(in: zone)
    check(targets.map(\.rect) == [CGRect(x: 256, y: 474, width: 40, height: 32),
                                  CGRect(x: 304, y: 474, width: 40, height: 32)],
          "share tiles sit above ordinary center and outside edge bands")
    let point = CGPoint(x: 270, y: 490)
    var entry = ShareEntry()
    let appeared = entry.update(targets: targets, cursor: point)
    let stationary = entry.update(targets: targets, cursor: point)
    _ = entry.update(targets: targets, cursor: CGPoint(x: 200, y: 490))
    let deliberate = entry.update(targets: targets, cursor: point)
    let held = entry.update(targets: targets, cursor: point)
    check(appeared == nil && stationary == nil && deliberate?.axis == .vertical && held?.axis == .vertical,
          "share requires leave and deliberate reentry when target appears under pointer")
    check(entry.update(targets: targets, cursor: CGPoint(x: 300, y: 450)) == nil
            && DragTarget.rect(zone: zone, cursor: CGPoint(x: 300, y: 450)) == zone,
          "ordinary center remains whole after leaving share target")
    check(DragTarget.rect(zone: zone, cursor: CGPoint(x: 10, y: 450)) == CGRect(x: 0, y: 0, width: 300, height: 900)
        && DragTarget.rect(zone: zone, cursor: CGPoint(x: 10, y: 890)) == CGRect(x: 0, y: 450, width: 300, height: 450),
          "share targets preserve edge half and corner quarter")
    check(ShareTarget.targets(in: CGRect(x: 0, y: 0, width: 80, height: 80)).isEmpty,
          "small zone never paints sharing over old bands")
    let screen = AppZonePlacement.Display(key: "display", frame: zone, visibleFrame: zone, pixelsWide: 1200)
    let whole = AppZonePlacement(screenKey: "display", layout: .leaf, zoneIndex: 0,
                                 unitRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    var records = SnapRecords<String>(equal: ==)
    records.recordSnap("incumbent", from: CGRect(x: 20, y: 40, width: 300, height: 300), to: zone, placement: whole)
    let plan = ZoneScene.share(incoming: "incoming", before: CGRect(x: 80, y: 120, width: 250, height: 400),
                               incumbent: records.entries[0], target: targets[0], screen: screen)
    check(plan?.map(\.window) == ["incumbent", "incoming"]
        && plan?.map(\.after) == [CGRect(x: 0, y: 0, width: 300, height: 900), CGRect(x: 300, y: 0, width: 300, height: 900)],
          "sharing moves named incumbent first and incoming last")
    check(plan?.map { $0.placement?.layout } == [.leaf, .leaf]
        && plan?.map { $0.placement?.zoneIndex } == [0, 0], "sharing keeps existing tree and zone number")
    let stacked = ZoneScene.share(incoming: "incoming", before: zone, incumbent: records.entries[0],
                                  target: targets[1], screen: screen)
    check(stacked?.map(\.after) == [CGRect(x: 0, y: 450, width: 600, height: 450), CGRect(x: 0, y: 0, width: 600, height: 450)],
          "stacked target places incoming below")
    records.bind("incumbent", placement: AppZonePlacement(screenKey: "display", layout: .leaf, zoneIndex: 0,
                                                          unitRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
    check(ZoneScene.share(incoming: "incoming", before: zone, incumbent: records.entries[0], target: targets[0], screen: screen) == nil,
          "partial snap cannot silently become whole-leaf incumbent")

    var zoneRecords = SnapRecords<String>(equal: ==)
    zoneRecords.recordSnap("closed", from: zone, to: zone, placement: whole)
    zoneRecords.recordSnap("visible", from: zone, to: zone, placement: whole)
    let current: Set<String> = ["visible"]
    check(ZoneScene.shareIncumbent(zoneRecords.entries, screen: screen, layout: .leaf, zoneIndex: 0,
                                   isCurrent: { current.contains($0.window) })?.window == "visible",
          "a closed, minimized or other-desktop record never makes a visible incumbent ambiguous")
    check(ZoneScene.shareIncumbent(zoneRecords.entries, screen: screen, layout: .leaf, zoneIndex: 0,
                                   isCurrent: { _ in true }) == nil,
          "two current occupants block sharing")
    check(ZoneScene.shareIncumbent(zoneRecords.entries, screen: screen, layout: .leaf, zoneIndex: 0,
                                   isCurrent: { _ in false }) == nil,
          "a zone with only stale records offers no share")
    var partial = SnapRecords<String>(equal: ==)
    partial.recordSnap("half", from: zone, to: CGRect(x: 0, y: 0, width: 300, height: 900),
                       placement: AppZonePlacement(screenKey: "display", layout: .leaf, zoneIndex: 0,
                                                   unitRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
    check(ZoneScene.shareIncumbent(partial.entries, screen: screen, layout: .leaf, zoneIndex: 0, isCurrent: { _ in true }) == nil,
          "a current partial occupant blocks sharing")
    var displaced = SnapRecords<String>(equal: ==)
    displaced.recordSnap("old", from: zone, to: CGRect(x: 0, y: 0, width: 500, height: 900), placement: whole)
    check(ZoneScene.shareIncumbent(displaced.entries, screen: screen, layout: .leaf, zoneIndex: 0, isCurrent: { _ in true }) == nil
            && ZoneScene.share(incoming: "incoming", before: zone, incumbent: displaced.entries[0], target: targets[0], screen: screen) == nil,
          "an incumbent whose applied frame no longer matches its whole leaf cannot share")
}
