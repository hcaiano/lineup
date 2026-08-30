import ApplicationServices
import CoreGraphics
import Foundation
import ZonesCore

// Zones (window layout) checks — the original Lineup 1.x suite, verbatim, wrapped in a
// function. `throws` mirrors the old top-level behaviour: a decoding failure aborted the
// whole run; now main.swift catches it and records one failed check.

func outcomeConfig(_ o: LoadOutcome) -> LineupConfig? {
    switch o { case .loaded(let c), .migrated(let c), .fresh(let c): return c; case .deferred: return nil }
}
func isMigrated(_ o: LoadOutcome) -> Bool { if case .migrated = o { return true }; return false }
func isFresh(_ o: LoadOutcome) -> Bool { if case .fresh = o { return true }; return false }

func runZonesTests() throws {
    // ---- Coordinate flip ----
    let primaryMaxY: CGFloat = 1440

    do {
        let cocoa = CGRect(x: 100, y: 200, width: 800, height: 600)
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY)
        let back = Coord.cocoaRect(fromAX: ax, primaryMaxY: primaryMaxY)
        check(back == cocoa, "AX flip round-trips")
    }
    do {
        let cocoa = CGRect(x: 0, y: 0, width: 800, height: 600)
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY)
        eq(ax.origin.y, 840, "AX flip y (1440 - 600)")
    }
    do {
        let cocoa = CGRect(x: 0, y: 0, width: 100, height: 1440)
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY)
        eq(ax.origin.y, 0, "full-height window AX y is 0")
    }
    do { // multi-monitor: a window on a display stacked ABOVE the primary has its top above the
         // primary's top, so AX y goes NEGATIVE. Round-trip + positive-only absolute tests can't catch
         // a sign/anchor bug here; assert the absolute values in BOTH directions for the negative case.
         // A 900-tall secondary above the 1440-tall primary -> that display's Cocoa y is in [1440, 2340].
        let cocoa = CGRect(x: 100, y: 1500, width: 800, height: 600) // top edge (maxY) = 2100
        let ax = Coord.axRect(fromCocoa: cocoa, primaryMaxY: primaryMaxY)
        eq(ax.origin.y, -660, "AX flip: above-primary window -> negative AX y (1440 - 2100)")
        eq(ax.origin.x, 100, "AX flip: x unchanged across displays")
        // cocoaRect with an INDEPENDENT negative-AX input (not just the round-trip of the above).
        let backY = Coord.cocoaRect(fromAX: CGRect(x: 50, y: -660, width: 800, height: 600), primaryMaxY: primaryMaxY).origin.y
        eq(backY, 1500, "AX->Cocoa: negative AX y maps back above the primary (Cocoa y 1500)")
    }
    do {
        var p = CGPoint(x: 12, y: 34)
        let pointValue = AXValueCreate(.cgPoint, &p)!
        check(AXExtract.point(pointValue) == p, "AXExtract.point reads cgPoint")
        check(AXExtract.size(pointValue) == nil, "AXExtract.size rejects cgPoint")

        var s = CGSize(width: 56, height: 78)
        let sizeValue = AXValueCreate(.cgSize, &s)!
        check(AXExtract.size(sizeValue) == s, "AXExtract.size reads cgSize")
        check(AXExtract.point(sizeValue) == nil, "AXExtract.point rejects cgSize")
        check(AXExtract.point("not an AXValue" as CFString) == nil, "AXExtract.point rejects non-AXValue")
        check(AXExtract.size(nil) == nil, "AXExtract.size rejects nil")
    }

    // ---- Screen picker ----
    do {
        let primary = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let secondary = CGRect(x: 5120, y: 0, width: 1920, height: 1080)
        let win = CGRect(x: 5000, y: 100, width: 800, height: 600)
        check(ScreenPicker.bestScreenIndex(forWindow: win, screens: [primary, secondary]) == 1,
              "picker: max intersection -> secondary")
    }
    do {
        let primary = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        let leftSecondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let win = CGRect(x: -3000, y: 400, width: 200, height: 200)
        check(ScreenPicker.bestScreenIndex(forWindow: win, screens: [primary, leftSecondary]) == 1,
              "picker: negative-origin no-overlap -> nearest")
    }

    // ---- Fixed placement (non-resizable / size-refusing windows) ----
    do {
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1000) // screen visible frame
        // Window smaller than the zone: dead-centered in the zone.
        let zone = CGRect(x: 100, y: 0, width: 800, height: 1000)
        let small = FixedPlacement.center(size: CGSize(width: 400, height: 300), in: zone, boundedBy: bounds)
        check(small == CGRect(x: 300, y: 350, width: 400, height: 300), "fixed: small window centers in zone")
        // Window wider than an edge zone: centering would push it past the screen edge;
        // it clamps back fully on-screen instead.
        let leftEdge = CGRect(x: 0, y: 0, width: 300, height: 1000)
        let wide = FixedPlacement.center(size: CGSize(width: 600, height: 400), in: leftEdge, boundedBy: bounds)
        eq(wide.minX, 0, "fixed: too-wide window clamps to the screen edge")
        check(wide.maxX <= bounds.maxX, "fixed: clamped window stays on-screen")
        // Right edge clamps the other way.
        let rightEdge = CGRect(x: 1700, y: 0, width: 300, height: 1000)
        let wideR = FixedPlacement.center(size: CGSize(width: 600, height: 400), in: rightEdge, boundedBy: bounds)
        eq(wideR.maxX, 2000, "fixed: right-edge zone clamps to the right screen edge")
        // Window larger than the screen itself: overflow centers (symmetric spill).
        let huge = FixedPlacement.center(size: CGSize(width: 2400, height: 400), in: zone, boundedBy: bounds)
        eq(huge.midX, 1000, "fixed: larger-than-screen centers its overflow")
        // Size is never altered — this is a position-only placement.
        check(huge.width == 2400 && huge.height == 400, "fixed: size passes through untouched")
    }

    // ---- Unsnap restore (drag a snapped window away -> pre-snap size under the cursor) ----
    do {
        let snapped = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let pre = CGSize(width: 800, height: 600)
        // Cursor in the middle of the title bar: restored frame centers under it, top edge kept.
        let mid = UnsnapRestore.frame(preSize: pre, current: snapped, cursor: CGPoint(x: 1000, y: 980))
        eq(mid.midX, 1000, "unsnap: centered grab stays centered")
        eq(mid.maxY, 1000, "unsnap: top edge stays put")
        check(mid.size == pre, "unsnap: pre-snap size returns exactly")
        // Grab near the left edge: the cursor keeps its proportional spot (10% across).
        let left = UnsnapRestore.frame(preSize: pre, current: snapped, cursor: CGPoint(x: 200, y: 980))
        eq(left.minX, 120, "unsnap: proportional grab (10% across -> 10% of new width)")
        check(left.contains(CGPoint(x: 200, y: 980)), "unsnap: cursor stays inside the window")
        // Grab at the far right edge: cursor lands on the restored frame's right edge.
        let right = UnsnapRestore.frame(preSize: pre, current: snapped, cursor: CGPoint(x: 2000, y: 980))
        eq(right.maxX, 2000, "unsnap: edge grab keeps cursor on the edge")
        // Degenerate zero-width current frame: falls back to centering, no NaN.
        let degen = UnsnapRestore.frame(preSize: pre, current: CGRect(x: 50, y: 0, width: 0, height: 100),
                                        cursor: CGPoint(x: 50, y: 90))
        eq(degen.midX, 50, "unsnap: zero-width current centers on cursor")
    }

    // ---- Columns (divider model) ----
    let frame = CGRect(x: 0, y: 0, width: 5120, height: 1440)
    let visible = CGRect(x: 0, y: 0, width: 5120, height: 1392)
    let px = 5120

    func col(_ cfg: ColumnConfig, _ id: String) -> CGRect {
        cfg.rect(for: id, frame: frame, visibleFrame: visible, pixelsWide: px)!
    }

    do { // default equal thirds
        let cfg = ColumnConfig.default
        let l = col(cfg, "left"), c = col(cfg, "center"), r = col(cfg, "right")
        eq(l.minX, 0, "thirds: left.minX")
        eq(l.width, 5120.0 / 3.0, "thirds: left.width")
        eq(r.maxX, 5120, "thirds: right.maxX")
        eq(l.maxX, c.minX, "thirds: GLUED L|C")
        eq(c.maxX, r.minX, "thirds: GLUED C|R")
        eq(l.height, 1392, "thirds: height uses visibleFrame")
    }

    do { // THE KEY PROPERTY: move one divider, neighbours adapt, still glued, no gaps
        let cfg = ColumnConfig(
            dividers: [Boundary(0.25, .fraction), Boundary(0.60, .fraction)],
            halfDivider: Boundary(0.5, .fraction))
        let l = col(cfg, "left"), c = col(cfg, "center"), r = col(cfg, "right")
        eq(l.width, 0.25 * 5120, "custom: left width follows divider 0")
        eq(c.width, (0.60 - 0.25) * 5120, "custom: center width = gap between dividers")
        eq(r.width, (1.0 - 0.60) * 5120, "custom: right width follows divider 1")
        eq(l.maxX, c.minX, "custom: GLUED L|C (no gap)")
        eq(c.maxX, r.minX, "custom: GLUED C|R (no gap)")
        eq(l.width + c.width + r.width, 5120, "custom: widths sum to full screen")
    }

    do { // seams in physical pixels (the real use case)
        let cfg = ColumnConfig(
            dividers: [Boundary(1707, .pixels), Boundary(3413, .pixels)],
            halfDivider: Boundary(2560, .pixels))
        let l = col(cfg, "left"), c = col(cfg, "center"), r = col(cfg, "right")
        eq(l.maxX, 1707, "pixels: left edge lands on seam 1707")
        eq(c.minX, 1707, "pixels: center starts at seam 1707 (glued)")
        eq(c.maxX, 3413, "pixels: center ends on seam 3413")
        eq(r.minX, 3413, "pixels: right starts at seam 3413 (glued)")
    }

    do { // .pixels resolution guards a degenerate display reporting 0 pixels wide: pixelsTotal<=0
         // falls back to scale 1 (no divide-by-zero / inf) instead of breaking the resolver.
         // Reachable: ScreenIdentity reads CGDisplayPixelsWide without a >0 floor.
        let b = Boundary(1133, .pixels)
        let f = CGRect(x: 0, y: 0, width: 1440, height: 900)
        eq(b.distance(alongLength: f.width, pixelsTotal: 0), 1133, "Boundary .pixels: pixelsTotal=0 -> scale 1 (no divide-by-zero)")
        check(b.x(in: f, pixelsWide: 0).isFinite, "Boundary .pixels: x with pixelsWide=0 is finite")
        eq(b.x(in: f, pixelsWide: 0), 1133, "Boundary .pixels: x with pixelsWide=0 anchors the value at frame.minX")
        eq(b.distance(alongLength: 1440, pixelsTotal: 2880), 566.5, "Boundary .pixels: normal scale still applies (1133px @2880 -> 566.5pt @1440)")
    }

    do { // halves + full
        let cfg = ColumnConfig.default
        let lh = col(cfg, "leftHalf"), rh = col(cfg, "rightHalf"), full = col(cfg, "full")
        eq(lh.maxX, 2560, "halves: left.maxX")
        eq(rh.minX, 2560, "halves: GLUED at middle")
        eq(rh.maxX, 5120, "halves: right.maxX")
        eq(full.width, 5120, "full: width")
        eq(full.height, 1392, "full: respects Dock")
    }

    do { // secondary display offset: columns anchored to display, not 0
        let f = CGRect(x: 5120, y: 0, width: 1920, height: 1080)
        let cfg = ColumnConfig.default
        let l = cfg.rect(for: "left", frame: f, visibleFrame: f, pixelsWide: 1920)!
        eq(l.minX, 5120, "secondary: left anchored to display minX")
        eq(l.width, 1920.0 / 3.0, "secondary: left width")
    }

    do { // unsorted dividers still tile correctly
        let cfg = ColumnConfig(
            dividers: [Boundary(0.7, .fraction), Boundary(0.3, .fraction)],
            halfDivider: Boundary(0.5, .fraction))
        let l = col(cfg, "left"), r = col(cfg, "right")
        eq(l.maxX, 0.3 * 5120, "unsorted: left uses smaller divider")
        eq(r.minX, 0.7 * 5120, "unsorted: right uses larger divider")
    }

    do { // config JSON round-trips
        let data = try JSONEncoder().encode(ColumnConfig.default)
        let decoded = try JSONDecoder().decode(ColumnConfig.self, from: data)
        check(decoded == ColumnConfig.default, "config JSON round-trips")
    }

    do { // fromPixels builds a sorted pixel-unit config
        let cfg = ColumnConfig.fromPixels(dividers: [3413, 1707], halfPixels: 2560)
        check(cfg.dividers.count == 2 && cfg.dividers[0].unit == .pixels, "fromPixels: pixel units")
        eq(CGFloat(cfg.dividers[0].value), 1707, "fromPixels: sorted ascending")
        eq(CGFloat(cfg.dividers[1].value), 3413, "fromPixels: sorted ascending 2")
        eq(CGFloat(cfg.halfDivider.value), 2560, "fromPixels: half")
    }

    do { // clampPixelDividers: in-range values pass through, sorted
        let out = Layout.clampPixelDividers([3413, 1707], pixelsWide: 5120, minColumn: 40)
        eq(CGFloat(out[0]), 1707, "clamp: keeps valid divider 0")
        eq(CGFloat(out[1]), 3413, "clamp: keeps valid divider 1")
    }

    do { // clampPixelDividers: zero-width columns get pushed apart, stay in range
        let out = Layout.clampPixelDividers([0, 0], pixelsWide: 5120, minColumn: 40)
        check(out[0] >= 40, "clamp: left column >= minColumn")
        check(out[1] - out[0] >= 40, "clamp: center column >= minColumn")
        check(5120 - out[1] >= 40, "clamp: right column >= minColumn")
    }

    do { // clampPixelDividers: out-of-range divider clamped inside the screen
        let out = Layout.clampPixelDividers([9999, 1000], pixelsWide: 5120, minColumn: 40)
        check(out.allSatisfy { $0 >= 0 && $0 <= 5120 }, "clamp: within screen bounds")
        check(out[0] <= out[1], "clamp: sorted")
    }

    do { // columnRect(containingX:) picks the block under the cursor (modifier-drag snapping)
        let cfg = ColumnConfig.fromPixels(dividers: [1133, 2865], halfPixels: 2560)
        func hit(_ x: CGFloat) -> CGRect { cfg.columnRect(containingX: x, frame: frame, visibleFrame: visible, pixelsWide: px)! }
        eq(hit(500).maxX, 1133, "cursor in left col -> left block")
        eq(hit(2000).minX, 1133, "cursor in center col -> center block (left edge)")
        eq(hit(2000).maxX, 2865, "cursor in center col -> center block (right edge)")
        eq(hit(4000).minX, 2865, "cursor in right col -> right block")
        check(hit(1133).width > 0, "cursor on a divider still resolves a column")
        eq(hit(-50).maxX, 1133, "cursor left of screen -> left block")
        eq(hit(9999).minX, 2865, "cursor right of screen -> right block")
    }

    // ---- P1: recursive zone tree ----
    do { // single leaf = full screen
        let z = Layout.zones(.leaf, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(z.count == 1, "leaf: one zone")
        eq(z[0].width, 5120, "leaf: full width")
        eq(z[0].height, 1392, "leaf: usable height")
    }

    do { // vertical thirds via tree, left→right order, gapless
        let z = Layout.zones(.thirds, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(z.count == 3, "thirds: 3 zones")
        eq(z[0].minX, 0, "thirds[0] leftmost")
        eq(z[0].maxX, z[1].minX, "thirds glued 0|1")
        eq(z[2].maxX, 5120, "thirds[2] rightmost")
    }

    do { // root pixel columns at his seams
        let root = Node.columns([Boundary(1133, .pixels), Boundary(2865, .pixels)])
        let z = Layout.zones(root, frame: frame, visibleFrame: visible, pixelsWide: px)
        eq(z[0].maxX, 1133, "seam columns: zone 0 ends on 1133")
        eq(z[1].minX, 1133, "seam columns: zone 1 starts on 1133")
        eq(z[1].maxX, 2865, "seam columns: zone 1 ends on 2865")
    }

    do { // HIS EXAMPLE: left half full-height; right half split top/bottom
        let root = Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [
            .leaf,
            .split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf]),
        ])
        let z = Layout.zones(root, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(z.count == 3, "nested: 3 zones (Left, Right-Top, Right-Bottom)")
        // Zone 0 = Left, full height, left half
        eq(z[0].minX, 0, "nested Left minX"); eq(z[0].maxX, 2560, "nested Left maxX")
        eq(z[0].height, 1392, "nested Left full height")
        // Semantic order: Zone 1 = Right-TOP (higher y), Zone 2 = Right-Bottom
        eq(z[1].minX, 2560, "nested Right-Top minX")
        eq(z[1].maxX, 5120, "nested Right-Top maxX")
        check(z[1].minY > z[2].minY, "nested: Zone 1 is the TOP row (top-to-bottom order)")
        eq(z[1].height, 1392 / 2, "nested Right-Top half height")
        eq(z[2].height, 1392 / 2, "nested Right-Bottom half height")
        eq(z[1].maxY, visible.maxY, "nested Right-Top touches top")
        eq(z[2].minY, visible.minY, "nested Right-Bottom touches bottom")
    }

    do { // zoneIndex(at:) and out-of-range zoneRect
        let root = Node.thirds
        let i = Layout.zoneIndex(at: CGPoint(x: 4000, y: 700), root: root, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(i == 2, "zoneIndex: point in right third -> index 2")
        check(Layout.zoneRect(index: 5, root: root, frame: frame, visibleFrame: visible, pixelsWide: px) == nil,
              "zoneRect: out-of-range index -> nil (disabled binding)")
    }

    do { // Node JSON round-trips (nested)
        let root = Node.split(axis: .vertical, dividers: [Boundary(1133, .pixels)], children: [
            .leaf, .split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf]),
        ])
        let data = try JSONEncoder().encode(root)
        let back = try JSONDecoder().decode(Node.self, from: data)
        check(back == root, "Node JSON round-trips (nested split)")
    }

    // ---- P1: per-screen config + migration ----
    let wide = ScreenInfo(key: "uuid-wide", label: "Wide Display", pixelsWide: 5120, pixelsHigh: 1440, keyIsStable: true)
    let mbp = ScreenInfo(key: "uuid-MBP", label: "Built-in", pixelsWide: 3456, pixelsHigh: 2234, keyIsStable: true)

    do { // per-screen lookup + default fallback
        var cfg = LineupConfig()
        cfg = cfg.setting(layout: .thirds, for: wide, now: nil)
        cfg = cfg.setting(layout: .halves, for: mbp, now: nil)
        check(Layout.zones(cfg.layout(forKey: "uuid-wide"), frame: frame, visibleFrame: visible, pixelsWide: px).count == 3, "per-screen: wide -> thirds")
        check(Layout.zones(cfg.layout(forKey: "uuid-MBP"), frame: frame, visibleFrame: visible, pixelsWide: px).count == 2, "per-screen: MBP -> halves")
        check(Layout.zones(cfg.layout(forKey: "uuid-UNKNOWN"), frame: frame, visibleFrame: visible, pixelsWide: px).count == 2, "per-screen: unknown -> default halves")
    }

    do { // out-of-range Zone-N across screens: Zone 3 exists on wide, not on MBP
        var cfg = LineupConfig()
        cfg = cfg.setting(layout: .thirds, for: wide, now: nil)
        cfg = cfg.setting(layout: .halves, for: mbp, now: nil)
        let wideZ3 = Layout.zoneRect(index: 2, root: cfg.layout(forKey: "uuid-wide"), frame: frame, visibleFrame: visible, pixelsWide: px)
        let mbpZ3 = Layout.zoneRect(index: 2, root: cfg.layout(forKey: "uuid-MBP"), frame: frame, visibleFrame: visible, pixelsWide: px)
        check(wideZ3 != nil, "Zone 3 available on wide (3 zones)")
        check(mbpZ3 == nil, "Zone 3 unavailable on MBP (2 zones) -> binding disables itself")
    }

    do { // migration from legacy ColumnConfig -> schema 3 onto current screen
        let legacy = ColumnConfig.fromPixels(dividers: [1133, 2865], halfPixels: 2560)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-mig-\(checks).json")
        try? FileManager.default.removeItem(at: tmp)
        try legacy.write(to: tmp)
        var backedUp = false
        let outcome = try LineupConfig.loadOrMigrate(from: tmp, now: "T", backup: { _ in backedUp = true }, resolveLegacyTarget: { _ in wide })
        check(isMigrated(outcome), "migration: legacy detected")
        check(backedUp, "migration: backup taken before write")
        let cfg = outcomeConfig(outcome)!
        check(cfg.schemaVersion == 3, "migration: schema bumped to 3")
        let z = Layout.zones(cfg.layout(forKey: wide.key), frame: frame, visibleFrame: visible, pixelsWide: px)
        eq(z[0].maxX, 1133, "migration: seams preserved (1133)")
        eq(z[1].maxX, 2865, "migration: seams preserved (2865)")
        try? FileManager.default.removeItem(at: tmp)
    }

    do { // schema-3 file loads without migration; absent file = fresh config
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-v3-\(checks).json")
        try? FileManager.default.removeItem(at: tmp)
        try LineupConfig().setting(layout: .thirds, for: wide, now: nil).write(to: tmp)
        let outcome = try LineupConfig.loadOrMigrate(from: tmp, now: "T", backup: { _ in }, resolveLegacyTarget: { _ in wide })
        check(!isMigrated(outcome), "schema-3 file: no migration")
        check(outcomeConfig(outcome)!.screens["uuid-wide"] != nil, "schema-3 file: wide layout present")
        try? FileManager.default.removeItem(at: tmp)
        let absent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-absent-\(checks).json")
        try? FileManager.default.removeItem(at: absent)
        let absentOutcome = try LineupConfig.loadOrMigrate(from: absent, now: "T", backup: { _ in }, resolveLegacyTarget: { _ in wide })
        check(isFresh(absentOutcome), "absent file: outcome is .fresh (writable)")
        check(outcomeConfig(absentOutcome)!.screens.isEmpty, "absent file: fresh empty config")
    }

    do { // fallback screen key composition (never resolution-only)
        let k = ScreenKey.fallback(vendor: 1552, model: 42, serial: 7, width: 5120, height: 1440, name: "wide")
        check(k.hasPrefix("fallback:"), "fallback key prefixed")
        check(k.contains("1552:42:7"), "fallback key includes vendor:model:serial")
        let k2 = ScreenKey.fallback(vendor: 1552, model: 42, serial: 0, width: 5120, height: 1440, name: "wide", tieBreaker: "unit3")
        check(k2.hasSuffix(":unit3"), "fallback key appends tie-breaker")
        check(k != k2, "tie-breaker disambiguates identical fallback displays")
    }

    do { // fallback-key aliases: a new salted key still reads a layout saved under an old key
        let base = (vendor: 0, model: 0, serial: 0, width: 1920, height: 1080, name: "Virtual")
        let salted = ScreenKey.fallback(vendor: base.vendor, model: base.model, serial: base.serial,
                                        width: base.width, height: base.height, name: base.name,
                                        tieBreaker: "unit:3")                 // current key (unit only, no transient display id)
        let bareUnit = ScreenKey.fallback(vendor: base.vendor, model: base.model, serial: base.serial,
                                          width: base.width, height: base.height, name: base.name,
                                          tieBreaker: "3")                     // old bare-unit key
        let unsalted = ScreenKey.fallback(vendor: base.vendor, model: base.model, serial: base.serial,
                                          width: base.width, height: base.height, name: base.name)  // oldest
        check(ScreenKey.fallbackAliases(for: salted) == [bareUnit, unsalted],
              "aliases: salted key derives [bare-unit, unsalted] older forms")

        // A layout saved under the old bare-unit key is read through the new salted key.
        let old = ScreenInfo(key: bareUnit, label: base.name, pixelsWide: base.width, pixelsHigh: base.height, keyIsStable: false)
        let cfg = LineupConfig().setting(layout: .thirds, for: old, now: nil)
        check(Layout.zones(cfg.layout(forKey: salted), frame: frame, visibleFrame: visible, pixelsWide: px).count == 3,
              "alias read-through: new key resolves the old key's saved layout")

        // A direct entry under the new key wins over any alias.
        let both = cfg.setting(layout: .halves, for: ScreenInfo(key: salted, label: base.name, pixelsWide: base.width, pixelsHigh: base.height, keyIsStable: false), now: nil)
        check(Layout.zones(both.layout(forKey: salted), frame: frame, visibleFrame: visible, pixelsWide: px).count == 2,
              "direct key wins over alias")

        // A frame-salted key (no display id) aliases down to the unsalted composite.
        let framed = ScreenKey.fallback(vendor: base.vendor, model: base.model, serial: base.serial,
                                        width: base.width, height: base.height, name: base.name, tieBreaker: "frame:100,200")
        check(ScreenKey.fallbackAliases(for: framed) == [unsalted], "aliases: frame-salted key derives the unsalted form")
        check(ScreenKey.fallbackAliases(for: "uuid-stable-key").isEmpty, "aliases: non-fallback (UUID) keys have none")
    }

    // ---- P1 review fixes: validation ----
    func expectThrow(_ name: String, _ body: () throws -> Void) {
        checks += 1
        do { try body(); failures += 1; FileHandle.standardError.write(Data("FAIL: \(name) (no throw)\n".utf8)) }
        catch { /* expected */ }
    }
    func expectNoThrow(_ name: String, _ body: () throws -> Void) {
        checks += 1
        do { try body() } catch { failures += 1; FileHandle.standardError.write(Data("FAIL: \(name) (threw \(error))\n".utf8)) }
    }

    expectNoThrow("valid: root vertical pixels ok") {
        try Node.columns([Boundary(1133, .pixels), Boundary(2865, .pixels)]).validate()
    }
    expectNoThrow("valid: nested fraction tree (his example)") {
        try Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [
            .leaf, .split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf]),
        ]).validate()
    }
    expectThrow("invalid: too few dividers") {
        try Node.split(axis: .vertical, dividers: [], children: [.leaf, .leaf]).validate()
    }
    expectThrow("invalid: too many dividers") {
        try Node.split(axis: .vertical, dividers: [Boundary(0.3, .fraction), Boundary(0.6, .fraction)], children: [.leaf, .leaf]).validate()
    }
    expectThrow("invalid: single-child split") {
        try Node.split(axis: .vertical, dividers: [], children: [.leaf]).validate()
    }
    expectThrow("invalid: nested vertical pixels") {
        try Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [
            .leaf, .split(axis: .vertical, dividers: [Boundary(100, .pixels)], children: [.leaf, .leaf]),
        ]).validate()
    }
    expectThrow("invalid: horizontal pixels") {
        try Node.split(axis: .horizontal, dividers: [Boundary(100, .pixels)], children: [.leaf, .leaf]).validate()
    }
    expectThrow("invalid: horizontal points") {
        try Node.split(axis: .horizontal, dividers: [Boundary(100, .points)], children: [.leaf, .leaf]).validate()
    }
    expectThrow("invalid: root horizontal pixels (only root VERTICAL may use absolutes)") {
        try Node.split(axis: .horizontal, dividers: [Boundary(100, .pixels)], children: [.leaf, .leaf]).validate()
    }

    do { // present-but-corrupt config throws (no clobber); absent stays fresh
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-corrupt-\(checks).json")
        try "{ not valid json at all ".write(to: tmp, atomically: true, encoding: .utf8)
        expectThrow("corrupt present config throws (no data loss)") {
            _ = try LineupConfig.loadOrMigrate(from: tmp, now: "T", backup: { _ in }, resolveLegacyTarget: { _ in wide })
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    do { // a pathologically DEEP config (valid JSON, absurd nesting) is rejected as unreadable, not
         // crashed-on or clobbered. The decode/validate/resolve path recurses on the tree; Foundation's
         // JSONDecoder caps nesting depth and throws a DecodingError far below any stack-overflow depth,
         // so loadOrMigrate surfaces it like any unreadable file and the saved file is preserved. Guards
         // the loader's no-crash/no-clobber contract for this adversarial input class (distinct from the
         // syntactically-invalid case above).
        var deep = "{\"type\":\"leaf\"}"
        for _ in 0..<1000 { // 1000 >> Foundation's ~512 nesting cap, << any overflow depth
            deep = "{\"type\":\"split\",\"axis\":\"vertical\",\"dividers\":[{\"value\":0.5,\"unit\":\"fraction\"}],\"children\":[\(deep),{\"type\":\"leaf\"}]}"
        }
        let json = "{\"schemaVersion\":3,\"screens\":{},\"defaultLayout\":\(deep)}"
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-deep-\(checks).json")
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        expectThrow("pathologically deep config is rejected (no crash, no clobber)") {
            _ = try LineupConfig.loadOrMigrate(from: tmp, now: "T", backup: { _ in }, resolveLegacyTarget: { _ in wide })
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    do { // write() validates: invalid layout throws and never creates/overwrites the file
        var bad = LineupConfig()
        bad.defaultLayout = .split(axis: .vertical, dividers: [], children: [.leaf]) // single-child = invalid
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-badwrite-\(checks).json")
        try? FileManager.default.removeItem(at: tmp)
        expectThrow("write(invalid) throws before touching disk") { try bad.write(to: tmp) }
        check(!FileManager.default.fileExists(atPath: tmp.path), "write(invalid) created no file (no clobber)")
    }

    do { // a future schema-4 file (v3-shaped) is rejected, not loaded lossily
        var future = LineupConfig().setting(layout: .halves, for: wide, now: nil)
        future.schemaVersion = 4
        // bypass write()'s schema-agnostic encode by encoding directly
        let enc = JSONEncoder()
        let data = try enc.encode(future)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-v4-\(checks).json")
        try data.write(to: tmp)
        expectThrow("future schema (v4) throws unsupportedSchema, not loaded") {
            _ = try LineupConfig.loadOrMigrate(from: tmp, now: "T", backup: { _ in }, resolveLegacyTarget: { _ in wide })
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // ---- P2 review: migration display inference + defer ----
    do { // inferred width from the pixel half-divider; nil when not pixels
        check(LineupConfig.inferredLegacyWidth(ColumnConfig.fromPixels(dividers: [1133, 2865], halfPixels: 2560)) == 5120,
              "inferredLegacyWidth: halfDivider*2 = 5120")
        check(LineupConfig.inferredLegacyWidth(ColumnConfig(dividers: [Boundary(0.5, .fraction)], halfDivider: Boundary(0.5, .fraction))) == nil,
              "inferredLegacyWidth: non-pixel half -> nil")
    }

    do { // defer migration when the target display isn't connected (resolveLegacyTarget=nil)
        let legacy = ColumnConfig.fromPixels(dividers: [1133, 2865], halfPixels: 2560)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-defer-\(checks).json")
        try? FileManager.default.removeItem(at: tmp)
        try legacy.write(to: tmp)
        var backedUp = false
        let outcome = try LineupConfig.loadOrMigrate(
            from: tmp, now: "T",
            backup: { _ in backedUp = true },
            resolveLegacyTarget: { _ in nil }) // wide display disconnected -> defer
        // DISTINCT from absent-fresh: deferral is its own outcome so the runtime can block writes.
        check(outcome == .deferred, "defer: outcome is .deferred (distinct from .fresh)")
        check(!isFresh(outcome), "defer: not .fresh (so writes get blocked, unlike a real fresh config)")
        check(outcomeConfig(outcome) == nil, "defer: carries no config (runtime runs defaults)")
        check(!backedUp, "defer: no backup taken (legacy file untouched)")
        // legacy file is still intact on disk
        let still = try JSONDecoder().decode(ColumnConfig.self, from: try Data(contentsOf: tmp))
        eq(CGFloat(still.dividers[0].value), 1133, "defer: legacy file preserved (1133)")
        try? FileManager.default.removeItem(at: tmp)
    }

    do { // backup failure aborts migration (closure throws -> loadOrMigrate throws, no write)
        let legacy = ColumnConfig.fromPixels(dividers: [1133, 2865], halfPixels: 2560)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lineup-bkpfail-\(checks).json")
        try? FileManager.default.removeItem(at: tmp)
        try legacy.write(to: tmp)
        struct BackupFailed: Error {}
        expectThrow("backup failure aborts migration (no clobber)") {
            _ = try LineupConfig.loadOrMigrate(from: tmp, now: "T",
                backup: { _ in throw BackupFailed() },
                resolveLegacyTarget: { _ in wide })
        }
        let still = try JSONDecoder().decode(ColumnConfig.self, from: try Data(contentsOf: tmp))
        eq(CGFloat(still.dividers[1].value), 2865, "backup fail: legacy file preserved (2865)")
        try? FileManager.default.removeItem(at: tmp)
    }

    // ---- P2: quick actions honor per-screen root columns ----
    do {
        let wideLayout = Node.columns([Boundary(1133, .pixels), Boundary(2865, .pixels)])
        func qa(_ id: String, _ root: Node) -> CGRect { QuickAction.rect(id, root: root, frame: frame, visibleFrame: visible, pixelsWide: px)! }
        // With a 3-column layout, left/center/right land on the seam columns
        eq(qa("left", wideLayout).maxX, 1133, "quick left -> root column 0 (seam)")
        eq(qa("right", wideLayout).minX, 2865, "quick right -> root column 2 (seam)")
        eq(qa("center", wideLayout).minX, 1133, "quick center -> middle column left edge")
        eq(qa("center", wideLayout).maxX, 2865, "quick center -> middle column right edge")
        eq(qa("full", wideLayout).width, 5120, "quick full -> whole screen")
        eq(qa("leftHalf", wideLayout).maxX, 2560, "quick leftHalf -> screen half")
        eq(qa("rightHalf", wideLayout).minX, 2560, "quick rightHalf -> screen half")
        // With a bare leaf (no columns), left/right fall back to halves
        eq(qa("left", .leaf).maxX, 2560, "quick left (leaf) -> left half fallback")
        eq(qa("right", .leaf).minX, 2560, "quick right (leaf) -> right half fallback")
        // rootColumns nil for non-vertical-split roots
        check(Layout.rootColumns(.leaf, frame: frame, visibleFrame: visible, pixelsWide: px) == nil, "rootColumns: leaf -> nil")
        check(Layout.rootColumns(wideLayout, frame: frame, visibleFrame: visible, pixelsWide: px)?.count == 3, "rootColumns: 3 columns")

        // NESTED layout (left column + right region split in two = 3 leaf zones, but the ROOT
        // split has only 2 columns). Quick "right" must hit the RIGHTMOST LEAF (zone 3), not the
        // wide root column that contains zones 2+3. This was the "Hyper+Right went to ~2/3 of the
        // screen" bug.
        let nested = Node.split(axis: .vertical, dividers: [Boundary(1394, .pixels)],
                                children: [.leaf,
                                           Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)],
                                                      children: [.leaf, .leaf])])
        check(Layout.leafColumns(nested, frame: frame, visibleFrame: visible, pixelsWide: px).count == 3, "leafColumns: nested -> 3 zones")
        eq(qa("right", nested).minX, 3257, "quick right -> rightmost LEAF zone (not root column)", accuracy: 2)
        eq(qa("left", nested).maxX, 1394, "quick left -> leftmost leaf (seam)")
        eq(qa("center", nested).minX, 1394, "quick center -> middle leaf left edge")
        eq(qa("center", nested).maxX, 3257, "quick center -> middle leaf right edge", accuracy: 2)
        // Cycle first step for "right" also targets the rightmost leaf.
        let rsteps = Cycle.steps(.right, root: nested, frame: frame, visibleFrame: visible, pixelsWide: px)
        eq(rsteps.first!.minX, 3257, "cycle right step 0 -> rightmost leaf zone", accuracy: 2)
    }

    // ---- P3: layout editor tree mutations ----
    do { // node(at:) / replacingNode addressing
        let root = Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [
            .leaf, .split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf]),
        ])
        check(root.node(at: []) == root, "node(at: []) == root")
        check(root.node(at: [0]) == .leaf, "node(at: [0]) == left leaf")
        if case .split(.horizontal, _, _)? = root.node(at: [1]) { check(true, "node(at: [1]) == right split") }
        else { check(false, "node(at: [1]) == right split") }
        check(root.node(at: [9]) == nil, "node(at: invalid) == nil")
        let replaced = root.replacingNode(at: [0], with: .leaf)
        check(replaced == root, "replacingNode same value -> equal")
    }

    do { // split a leaf -> two equal children; non-leaf is a no-op
        let twoCol = LayoutEdit.split(.leaf, at: [], axis: .vertical)
        check(Layout.zones(twoCol, frame: frame, visibleFrame: visible, pixelsWide: px).count == 2, "split leaf vertical -> 2 zones")
        try twoCol.validate()
        // split the right zone into rows -> his example shape
        let nested = LayoutEdit.split(twoCol, at: [1], axis: .horizontal)
        let z = Layout.zones(nested, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(z.count == 3, "split [1] horizontal -> 3 zones (left + right top/bottom)")
        try nested.validate()
        // splitting a non-leaf path is a no-op
        check(LayoutEdit.split(nested, at: [], axis: .vertical) == nested, "split non-leaf -> no-op")
    }

    do { // merge collapses the parent split back to a leaf
        let nested = LayoutEdit.split(LayoutEdit.split(.leaf, at: [], axis: .vertical), at: [1], axis: .horizontal)
        // merge a leaf inside the right split -> right becomes a single leaf again (2 zones)
        let merged = LayoutEdit.merge(nested, at: [1, 0])
        check(Layout.zones(merged, frame: frame, visibleFrame: visible, pixelsWide: px).count == 2, "merge inner -> back to 2 zones")
        try merged.validate()
        // merge at root collapses everything to one zone
        let allMerged = LayoutEdit.merge(merged, at: [])
        check(Layout.zones(allMerged, frame: frame, visibleFrame: visible, pixelsWide: px).count == 1, "merge root -> 1 zone")
        check(allMerged == .leaf, "merge root -> leaf")
    }

    do { // leaves(withPaths) + dividerHandles for the editor canvas (his example)
        let nested = LayoutEdit.split(LayoutEdit.split(.leaf, at: [], axis: .vertical), at: [1], axis: .horizontal)
        let container = Layout.rootContainer(frame: frame, visibleFrame: visible)
        let lv = Layout.leaves(nested, container: container, pixelsWide: px)
        check(lv.count == 3, "leaves: 3 (paths + rects)")
        check(lv[0].path == [0], "leaves[0] path = [0] (Left)")
        check(lv[1].path == [1, 0], "leaves[1] path = [1,0] (Right-Top)")
        check(lv[2].path == [1, 1], "leaves[2] path = [1,1] (Right-Bottom)")
        check(lv[1].rect.minY > lv[2].rect.minY, "leaves: Right-Top above Right-Bottom")
        let handles = Layout.dividerHandles(nested, container: container, pixelsWide: px)
        check(handles.count == 2, "dividerHandles: 2 (root column + right row)")
        check(handles.contains { $0.path == [] && $0.axis == .vertical }, "handle: root vertical divider")
        check(handles.contains { $0.path == [1] && $0.axis == .horizontal }, "handle: nested horizontal divider")
    }

    do { // setDivider: root vertical keeps pixels (seams); nested keeps fractions
        let twoCol = Node.columns([Boundary(2560, .pixels)])
        let moved = LayoutEdit.setDivider(twoCol, at: [], index: 0, fraction: 1133.0 / 5120.0, rootPixelsWide: 5120)
        if case let .split(_, dividers, _) = moved {
            check(dividers[0].unit == .pixels, "setDivider root vertical -> pixels (seam precision kept)")
            eq(CGFloat(dividers[0].value), 1133, "setDivider root -> 1133px", accuracy: 1)
        } else { check(false, "setDivider root -> split") }
        try moved.validate()
        // nested split divider stays fraction
        let nested = LayoutEdit.split(twoCol, at: [1], axis: .horizontal)
        let nestedMoved = LayoutEdit.setDivider(nested, at: [1], index: 0, fraction: 0.3, rootPixelsWide: 5120)
        if case let .split(_, _, children) = nestedMoved, case let .split(_, d, _) = children[1] {
            check(d[0].unit == .fraction, "setDivider nested -> fraction")
            eq(CGFloat(d[0].value), 0.3, "setDivider nested -> 0.3")
        } else { check(false, "setDivider nested structure") }
        try nestedMoved.validate()

        // 3+ children: dragging one divider PAST its neighbor must not reorder the stored array
        // (else sorted visual handles desync from stored indices -> handles jump, wrong boundary
        // resizes). The dragged divider stays strictly below the next one.
        let threeCol = Node.columns([Boundary(1700, .pixels), Boundary(3400, .pixels)]) // 3 columns
        let crossed = LayoutEdit.setDivider(threeCol, at: [], index: 0, fraction: 4000.0 / 5120.0, rootPixelsWide: 5120)
        if case let .split(_, d, _) = crossed {
            check(d[0].value < d[1].value, "setDivider keeps dividers ordered when dragged past neighbor")
            check(d[1].value == 3400, "setDivider leaves the untouched neighbor in place")
        } else { check(false, "setDivider 3-col structure") }
        try crossed.validate()
        // Nested fractional 3-way: dragging index 1 below index 0 clamps above it, stays ordered.
        let threeFrac = Node.split(axis: .horizontal, dividers: [Boundary(0.33, .fraction), Boundary(0.66, .fraction)],
                                   children: [.leaf, .leaf, .leaf])
        let pinched = LayoutEdit.setDivider(threeFrac, at: [], index: 1, fraction: 0.1, rootPixelsWide: 5120)
        if case let .split(_, d, _) = pinched {
            check(d[1].value > d[0].value, "setDivider nested keeps order when dragged below lower neighbor")
        } else { check(false, "setDivider nested 3-way structure") }
        try pinched.validate()

        // A root vertical split may legally carry a `.points` neighbor (hand-authored config).
        // With containerLength supplied, clamping must keep the dragged divider ordered against it.
        let withPoints = Node.split(axis: .vertical,
                                    dividers: [Boundary(2560, .points), Boundary(3400, .pixels)],
                                    children: [.leaf, .leaf, .leaf]) // container is 5120 pt wide here
        let clampedPts = LayoutEdit.setDivider(withPoints, at: [], index: 1, fraction: 0.1,
                                               rootPixelsWide: 5120, containerLength: 5120)
        if case let .split(_, d, _) = clampedPts {
            // dividers[0] is 2560 pt = fraction 0.5; the dragged divider stays above it.
            check(d[1].value > 2560, "setDivider clamps above a .points neighbor when containerLength given")
        } else { check(false, "setDivider .points-neighbor structure") }
        try clampedPts.validate()
    }

    // ---- setDivider keeps EVERY other line fixed (nested splits don't rescale) ----
    do {
        // The editor's split nests, so "3 columns" is really [col1 | (col2 col3)]. Dragging the
        // OUTER divider must keep col3 (and the col2|col3 line) exactly where they are — only the
        // two zones the dragged line touches may resize.
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let visible = frame
        func cols(_ n: Node) -> [CGRect] { Layout.zones(n, frame: frame, visibleFrame: visible, pixelsWide: 1000) }

        // Build [col1 | (col2 col3)] by splitting the right column of a 2-col layout.
        let twoCol = Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf])
        let nestedRight = LayoutEdit.split(twoCol, at: [1], axis: .vertical)
        let before = cols(nestedRight)
        eq(before[0].width, 500, "nested-right: col1 starts at 500")
        eq(before[1].width, 250, "nested-right: col2 starts at 250")
        eq(before[2].width, 250, "nested-right: col3 starts at 250")
        eq(before[2].minX, 750, "nested-right: col2|col3 line starts at 750")

        // Drag the OUTER (root) divider right: 0.5 -> 0.6.
        let dragged = LayoutEdit.setDivider(nestedRight, at: [], index: 0, fraction: 0.6, rootPixelsWide: 1000)
        let after = cols(dragged)
        eq(after[0].width, 600, "nested-right: col1 grows to 600")
        eq(after[2].width, 250, "nested-right: col3 stays 250 (untouched line fixed)")
        eq(after[2].minX, 750, "nested-right: col2|col3 line stays at 750")
        eq(after[1].width, 150, "nested-right: col2 absorbs the change -> 150")
        try dragged.validate()

        // Symmetric: [(col1 col2) | col3], drag the root divider LEFT -> col1 fixed.
        let nestedLeft = LayoutEdit.split(twoCol, at: [0], axis: .vertical)
        let bl = cols(nestedLeft)
        eq(bl[0].width, 250, "nested-left: col1 starts at 250")
        let draggedL = LayoutEdit.setDivider(nestedLeft, at: [], index: 0, fraction: 0.4, rootPixelsWide: 1000)
        let al = cols(draggedL)
        eq(al[0].width, 250, "nested-left: col1 stays 250 (untouched line fixed)")
        eq(al[0].maxX, 250, "nested-left: col1|col2 line stays at 250")
        eq(al[1].width, 150, "nested-left: col2 absorbs -> 150")
        eq(al[2].width, 600, "nested-left: col3 grows to 600")
        try draggedL.validate()

        // The dragged divider can't be pushed past a nested line: dragging the root divider far
        // right stops just left of the col2|col3 line (750), never crossing it.
        let pushed = LayoutEdit.setDivider(nestedRight, at: [], index: 0, fraction: 0.95, rootPixelsWide: 1000)
        let ap = cols(pushed)
        eq(ap[2].minX, 750, "nested-right: outer divider clamps at the inner line, col3 still fixed")
        eq(ap[2].width, 250, "nested-right: col3 still 250 after over-drag")
        check(ap[1].width >= 1, "nested-right: col2 never collapses")
        try pushed.validate()

        // Symmetric for rows: [(row1 row2) / row3] stacked, drag the outer horizontal divider.
        let twoRow = Node.split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)], children: [.leaf, .leaf])
        let nestedTop = LayoutEdit.split(twoRow, at: [0], axis: .horizontal)
        let draggedRow = LayoutEdit.setDivider(nestedTop, at: [], index: 0, fraction: 0.4, rootPixelsWide: 1000)
        let rr = cols(draggedRow) // semantic order top->bottom
        eq(rr[0].height, 250, "nested rows: row1 height stays 250 (untouched line fixed)")
        try draggedRow.validate()

        // The inner line is anchored against the REALIZED (rounded-to-pixel) outer position, not
        // the requested fraction. Drag the root divider to 0.6004 (rounds to 600px @1000px wide):
        // the resolver places the outer line at 600 and the inner line must still resolve to 750.
        let subpixel = LayoutEdit.setDivider(nestedRight, at: [], index: 0, fraction: 0.6004, rootPixelsWide: 1000)
        let asp = cols(subpixel)
        eq(asp[0].maxX, 600, "subpixel: outer line lands on the rounded pixel (600)")
        eq(asp[2].minX, 750, "subpixel: inner line stays EXACT against the rounded outer (no drift)")
        eq(asp[2].width, 250, "subpixel: col3 stays 250 exactly")
        try subpixel.validate()

        // Malformed (arity-broken) split: more dividers than children-1. setDivider must be a
        // no-op, not trap on the children[index+1] access.
        let malformed = Node.split(axis: .vertical, dividers: [Boundary(0.3, .fraction), Boundary(0.6, .fraction)],
                                   children: [.leaf, .leaf]) // 2 dividers, only 2 children (needs 3)
        check(LayoutEdit.setDivider(malformed, at: [], index: 1, fraction: 0.5, rootPixelsWide: 1000) == malformed,
              "malformed split: setDivider is a no-op, no trap")

        // Regression: a FLAT 3-column split is unchanged by the new logic (no nested lines).
        let flat = Node.columns([Boundary(1.0 / 3.0, .fraction), Boundary(2.0 / 3.0, .fraction)])
        let flatDragged = LayoutEdit.setDivider(flat, at: [], index: 0, fraction: 0.5, rootPixelsWide: 1000)
        let fa = cols(flatDragged)
        eq(fa[2].minX, Layout.zones(flat, frame: frame, visibleFrame: visible, pixelsWide: 1000)[2].minX,
           "flat 3-col: untouched divider stays put")
        try flatDragged.validate()
    }

    do { // toggleParentAxis: change only the closest split and keep valid units
        let pixelRoot = Node.split(axis: .vertical,
                                   dividers: [Boundary(2560, .pixels)],
                                   children: [.leaf, .leaf])
        let horizontal = LayoutEdit.toggleParentAxis(
            pixelRoot, at: [1], rootPixelsWide: 5120, rootPointsWide: 5120)
        if case let .split(axis, dividers, children) = horizontal {
            check(axis == .horizontal, "toggle: root pixels -> horizontal")
            check(dividers == [Boundary(0.5, .fraction)], "toggle: pixels -> fraction")
            check(children == [.leaf, .leaf], "toggle: child order is preserved")
        } else {
            check(false, "toggle: root pixels returns a split")
        }
        try horizontal.validate()

        let verticalAgain = LayoutEdit.toggleParentAxis(
            horizontal, at: [1], rootPixelsWide: 5120, rootPointsWide: 5120)
        if case let .split(axis, dividers, _) = verticalAgain {
            check(axis == .vertical, "toggle: horizontal -> vertical")
            check(dividers == [Boundary(2560, .pixels)], "toggle: fraction -> root pixels")
        } else {
            check(false, "toggle: horizontal returns a split")
        }
        try verticalAgain.validate()

        let pointRoot = Node.split(axis: .vertical,
                                   dividers: [Boundary(400, .points)],
                                   children: [.leaf, .leaf])
        let pointHorizontal = LayoutEdit.toggleParentAxis(
            pointRoot, at: [0], rootPixelsWide: 2000, rootPointsWide: 1000)
        if case let .split(axis, dividers, _) = pointHorizontal {
            check(axis == .horizontal, "toggle: root points -> horizontal")
            check(dividers == [Boundary(0.4, .fraction)], "toggle: points -> fraction")
        } else {
            check(false, "toggle: root points returns a split")
        }
        try pointHorizontal.validate()

        let nestedRoot = Node.split(axis: .vertical,
                                    dividers: [Boundary(0.6, .fraction)],
                                    children: [
                                        .leaf,
                                        .split(axis: .vertical,
                                               dividers: [Boundary(0.5, .fraction)],
                                               children: [.leaf, .leaf]),
                                    ])
        let nestedHorizontal = LayoutEdit.toggleParentAxis(
            nestedRoot, at: [1, 0], rootPixelsWide: 2000, rootPointsWide: 2000)
        if case let .split(rootAxis, rootDividers, children) = nestedHorizontal,
           case let .split(innerAxis, innerDividers, innerChildren) = children[1] {
            check(rootAxis == .vertical && rootDividers == [Boundary(0.6, .fraction)],
                  "toggle: nested leaves keep the root split unchanged")
            check(innerAxis == .horizontal && innerDividers == [Boundary(0.5, .fraction)],
                  "toggle: nested split changes axis and keeps fractions")
            check(innerChildren == [.leaf, .leaf], "toggle: nested child order is preserved")
        } else {
            check(false, "toggle: nested split returns the expected tree")
        }
        check(Layout.leaves(nestedHorizontal,
                           container: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                           pixelsWide: 2000).count == 3,
              "toggle: nested leaf count is preserved")
        try nestedHorizontal.validate()

        // Invalid paths, a root leaf, and malformed/invalid geometry must be no-ops.
        check(LayoutEdit.toggleParentAxis(pixelRoot, at: [9], rootPixelsWide: 5120,
                                          rootPointsWide: 5120) == pixelRoot,
              "toggle: invalid leaf path is a no-op")
        check(LayoutEdit.toggleParentAxis(.leaf, at: [], rootPixelsWide: 5120,
                                          rootPointsWide: 5120) == .leaf,
              "toggle: root leaf is a no-op")
        let bad = Node.split(axis: .vertical, dividers: [Boundary(Double.nan, .pixels)],
                             children: [.leaf, .leaf])
        let badResult = LayoutEdit.toggleParentAxis(bad, at: [0], rootPixelsWide: 5120,
                                                    rootPointsWide: 5120)
        if case let .split(_, dividers, _) = badResult {
            check(dividers[0].value.isNaN, "toggle: invalid geometry is a no-op")
        } else {
            check(false, "toggle: invalid geometry keeps the original tree")
        }
    }

    // ---- P4: shortcuts model ----
    do {
        var sc = Shortcuts()
        sc = sc.setting(action: "left", keyCode: 123, modifiers: 0x1B00)   // Hyper+Left
        sc = sc.setting(action: ZoneAction.id(2), keyCode: 19, modifiers: 0x1B00) // Hyper+2 -> Zone 2
        check(sc.binding(for: "left")?.keyCode == 123, "shortcut: left bound")
        check(sc.binding(for: "zone:2")?.keyCode == 19, "shortcut: zone:2 bound")
        // setting replaces, not duplicates
        sc = sc.setting(action: "left", keyCode: 124, modifiers: 0x1B00)
        check(sc.bindings.filter { $0.action == "left" }.count == 1, "shortcut: setting replaces")
        check(sc.binding(for: "left")?.keyCode == 124, "shortcut: left rebound to 124")
        // conflict detection
        sc = sc.setting(action: "right", keyCode: 124, modifiers: 0x1B00) // same combo as left
        check(sc.conflicts(keyCode: 124, modifiers: 0x1B00, excluding: "right") == ["left"], "shortcut: conflict detected")
        check(sc.conflicts(keyCode: 999, modifiers: 0, excluding: "right").isEmpty, "shortcut: no false conflict")
        // removing
        sc = sc.removing(action: "left")
        check(sc.binding(for: "left") == nil, "shortcut: removed -> unassigned")
    }

    do { // zone action id <-> index
        check(ZoneAction.id(3) == "zone:3", "zone id")
        check(ZoneAction.zeroBasedIndex(from: "zone:3") == 2, "zone parse -> 0-based 2")
        check(ZoneAction.zeroBasedIndex(from: "left") == nil, "non-zone action -> nil")
        check(ZoneAction.zeroBasedIndex(from: "zone:0") == nil, "zone:0 invalid -> nil")
    }

    do { // drag-snap modifier masks normalize and match exactly
        check(DragSnapModifierMask.normalized(nil) == DragSnapModifierMask.shift, "drag modifier: nil defaults to Shift")
        check(DragSnapModifierMask.normalized(DragSnapModifierMask.option) == DragSnapModifierMask.option,
              "drag modifier: known value passes through")
        check(DragSnapModifierMask.normalized(0xDEAD) == DragSnapModifierMask.shift,
              "drag modifier: unknown value falls back to Shift")
        check(DragSnapModifierMask.matches(active: DragSnapModifierMask.shift, required: DragSnapModifierMask.shift),
              "drag modifier: exact Shift matches")
        check(!DragSnapModifierMask.matches(active: DragSnapModifierMask.shift, required: DragSnapModifierMask.shift | DragSnapModifierMask.option),
              "drag modifier: missing required Option fails")
        check(!DragSnapModifierMask.matches(active: DragSnapModifierMask.shift | DragSnapModifierMask.option, required: DragSnapModifierMask.shift),
              "drag modifier: extra active Option fails exact match")
        check(DragSnapModifierMask.matches(active: DragSnapModifierMask.hyper, required: DragSnapModifierMask.hyper),
              "drag modifier: Hyper matches exactly")
    }

    do { // drag-snap trigger supports modifier-only and key-combo binds
        let modifierOnly = DragSnapTrigger(keyCode: nil, modifiers: DragSnapModifierMask.option)
        check(modifierOnly.matches(activeKeyDown: false, activeModifiers: DragSnapModifierMask.option),
              "drag trigger: modifier-only bind matches without a key")
        check(!modifierOnly.matches(activeKeyDown: false, activeModifiers: DragSnapModifierMask.option | DragSnapModifierMask.shift),
              "drag trigger: modifier-only bind rejects extra modifier")

        let keyCombo = DragSnapTrigger(keyCode: 2, modifiers: DragSnapModifierMask.option) // D on ANSI keyboards
        check(keyCombo.matches(activeKeyDown: true, activeModifiers: DragSnapModifierMask.option),
              "drag trigger: key combo matches with key down")
        check(!keyCombo.matches(activeKeyDown: false, activeModifiers: DragSnapModifierMask.option),
              "drag trigger: key combo rejects missing key")
        check(!keyCombo.matches(activeKeyDown: true, activeModifiers: DragSnapModifierMask.option | DragSnapModifierMask.shift),
              "drag trigger: key combo rejects extra modifier")
        let bareKey = DragSnapTrigger(keyCode: 2, modifiers: 0)
        check(bareKey.modifiers == 0, "drag trigger: bare key keeps empty modifiers")
        check(bareKey.matches(activeKeyDown: true, activeModifiers: 0),
              "drag trigger: bare key matches with no modifiers")
        check(!bareKey.matches(activeKeyDown: true, activeModifiers: DragSnapModifierMask.shift),
              "drag trigger: bare key rejects extra Shift")
        check(DragSnapTrigger(keyCode: nil, modifiers: 0x4000).modifiers == DragSnapModifierMask.shift,
              "drag trigger: invalid modifier-only bind falls back to Shift")
    }

    do { // drag-snap arms only for actual window movement, not in-app drags or resizes
        let start = CGRect(x: 100, y: 200, width: 800, height: 600)
        check(DragSnapWindowMotion.classify(start: start, current: start) == .stationary,
              "drag window motion: unchanged frame stays stationary")
        check(DragSnapWindowMotion.classify(start: start, current: start.offsetBy(dx: 6, dy: 0)) == .moved,
              "drag window motion: origin move with stable size arms")
        check(DragSnapWindowMotion.classify(start: start, current: start.offsetBy(dx: 3, dy: 4)) == .stationary,
              "drag window motion: jitter at threshold stays stationary")
        check(DragSnapWindowMotion.classify(
            start: start,
            current: CGRect(x: 100, y: 200, width: 808, height: 600)) == .resized,
              "drag window motion: size change is a resize")
        check(DragSnapWindowMotion.classify(
            start: start,
            current: CGRect(x: 94, y: 200, width: 806, height: 600)) == .resized,
              "drag window motion: edge resize with origin change is still a resize")
        check(DragSnapWindowMotion.isLikelyWindowMoveStart(
            point: CGPoint(x: 500, y: 770), windowFrame: start),
              "drag window motion: titlebar/top band can arm when AX frame is stale")
        check(!DragSnapWindowMotion.isLikelyWindowMoveStart(
            point: CGPoint(x: 500, y: 500), windowFrame: start),
              "drag window motion: content area does not arm from cursor movement alone")
        check(!DragSnapWindowMotion.isLikelyWindowMoveStart(
            point: CGPoint(x: 500, y: 742), windowFrame: start),
              "drag window motion: top content sliver below chrome band does not arm")
        check(!DragSnapWindowMotion.isLikelyWindowMoveStart(
            point: CGPoint(x: 500, y: 798), windowFrame: start),
              "drag window motion: top resize edge does not count as move band")
        check(!DragSnapWindowMotion.isLikelyWindowMoveStart(
            point: CGPoint(x: 102, y: 770), windowFrame: start),
              "drag window motion: side resize edge does not count as move band")
    }

    do { // shortcuts are optional + backward compatible in LineupConfig
        var cfg = LineupConfig().setting(layout: .thirds, for: wide, now: nil)
        check(cfg.shortcuts == nil, "config: shortcuts absent by default")
        cfg.shortcuts = Shortcuts().setting(action: "full", keyCode: 126, modifiers: 0x1B00)
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(LineupConfig.self, from: data)
        check(back.shortcuts?.binding(for: "full")?.keyCode == 126, "config: shortcuts round-trip")
        // a schema-3 doc without the shortcuts key still decodes (absent -> nil)
        let noShortcuts = LineupConfig().setting(layout: .halves, for: wide, now: nil)
        let d2 = try JSONEncoder().encode(noShortcuts)
        check((try JSONDecoder().decode(LineupConfig.self, from: d2)).shortcuts == nil, "config: missing shortcuts decodes to nil")
    }

    do { // dragSnapEnabled is optional + backward compatible (same pattern as shortcuts)
        var cfg = LineupConfig()
        check(cfg.dragSnapEnabled == nil, "config: dragSnapEnabled absent by default (nil = on)")
        check(cfg.dragSnapModifiers == nil, "config: dragSnapModifiers absent by default (nil = Shift)")
        check(cfg.dragSnapKeyCode == nil, "config: dragSnapKeyCode absent by default (nil = modifier-only)")
        // setting() preserves the flag while updating a screen's layout
        cfg.dragSnapEnabled = false
        cfg.dragSnapModifiers = DragSnapModifierMask.option
        cfg.dragSnapKeyCode = 2
        let carried = cfg.setting(layout: .thirds, for: wide, now: nil)
        check(carried.dragSnapEnabled == false, "config: setting(layout:) preserves dragSnapEnabled")
        check(carried.dragSnapModifiers == DragSnapModifierMask.option, "config: setting(layout:) preserves dragSnapModifiers")
        check(carried.dragSnapKeyCode == 2, "config: setting(layout:) preserves dragSnapKeyCode")
        // false round-trips intact (an explicit opt-out must survive a write/read cycle)
        let back = try JSONDecoder().decode(LineupConfig.self, from: try JSONEncoder().encode(carried))
        check(back.dragSnapEnabled == false, "config: dragSnapEnabled=false round-trips")
        check(back.dragSnapModifiers == DragSnapModifierMask.option, "config: dragSnapModifiers round-trips")
        check(back.dragSnapKeyCode == 2, "config: dragSnapKeyCode round-trips")
        // a schema-3 doc without the key decodes to nil, which the app reads as the default (on)
        let d2 = try JSONEncoder().encode(LineupConfig())
        let decoded = try JSONDecoder().decode(LineupConfig.self, from: d2)
        check(decoded.dragSnapEnabled == nil, "config: missing dragSnapEnabled decodes to nil")
        check(decoded.dragSnapModifiers == nil, "config: missing dragSnapModifiers decodes to nil")
        check(decoded.dragSnapKeyCode == nil, "config: missing dragSnapKeyCode decodes to nil")
        check((decoded.dragSnapEnabled ?? true) == true, "config: nil dragSnapEnabled defaults to on")
    }

    // ---- Drag target: whole zone vs half vs quarter (5% hot bands on every edge) ----
    do {
        let zone = CGRect(x: 100, y: 0, width: 1000, height: 1000) // Cocoa: +y up
        func t(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            DragTarget.rect(zone: zone, cursor: CGPoint(x: x, y: y))
        }
        // Middle: the whole zone, untouched (the common case). Bands are 5% -> 50pt here.
        check(t(600, 500) == zone, "drag target: middle -> whole zone")
        check(t(600, 51) == zone, "drag target: just above bottom band -> whole zone")
        check(t(600, 949) == zone, "drag target: just below top band -> whole zone")
        check(t(151, 500) == zone, "drag target: just right of left band -> whole zone")
        check(t(1049, 500) == zone, "drag target: just left of right band -> whole zone")
        // Top/bottom 5% bands -> that vertical half.
        eq(t(600, 975).minY, 500, "drag target: top band -> top half (minY = midY)")
        eq(t(600, 975).height, 500, "drag target: top half height")
        eq(t(600, 950).minY, 500, "drag target: band boundary inclusive (top)")
        eq(t(600, 25).minY, 0, "drag target: bottom band -> bottom half")
        eq(t(600, 25).maxY, 500, "drag target: bottom half ends at midY")
        eq(t(600, 50).maxY, 500, "drag target: band boundary inclusive (bottom)")
        check(t(600, 975).minX == zone.minX && t(600, 975).width == zone.width,
              "drag target: vertical half keeps zone x/width")
        // Left/right 5% bands -> that horizontal half.
        eq(t(125, 500).minX, 100, "drag target: left band -> left half")
        eq(t(125, 500).width, 500, "drag target: left half width")
        eq(t(1075, 500).minX, 600, "drag target: right band -> right half (minX = midX)")
        eq(t(1075, 500).maxX, 1100, "drag target: right half ends at maxX")
        check(t(125, 500).minY == zone.minY && t(125, 500).height == zone.height,
              "drag target: horizontal half keeps zone y/height")
        // Corners (two bands at once) -> that quarter.
        let topLeft = t(125, 975)
        check(topLeft == CGRect(x: 100, y: 500, width: 500, height: 500), "drag target: top-left corner -> top-left quarter")
        let bottomRight = t(1075, 25)
        check(bottomRight == CGRect(x: 600, y: 0, width: 500, height: 500), "drag target: bottom-right corner -> bottom-right quarter")
        let topRight = t(1075, 975)
        check(topRight == CGRect(x: 600, y: 500, width: 500, height: 500), "drag target: top-right corner -> top-right quarter")
        let bottomLeft = t(125, 25)
        check(bottomLeft == CGRect(x: 100, y: 0, width: 500, height: 500), "drag target: bottom-left corner -> bottom-left quarter")
        // Left/right band boundaries are inclusive too.
        eq(t(150, 500).minX, 100, "drag target: band boundary inclusive (left)")
        eq(t(1050, 500).minX, 600, "drag target: band boundary inclusive (right)")
        // Band clamps: an absurd band fraction can never exceed half the zone. At the clamp
        // every interior point sits in one band per axis (top/left win the midline ties), so
        // the cursor just right of center lands in the top-LEFT quarter.
        let clamped = DragTarget.rect(zone: zone, cursor: CGPoint(x: 600, y: 501), edgeBand: 5)
        check(clamped == CGRect(x: 100, y: 500, width: 500, height: 500),
              "drag target: band clamped to 0.5 -> top-left quarter at midline (top/left win ties)")
        // A zero band disables the feature entirely — every inside point is the whole zone.
        check(DragTarget.rect(zone: zone, cursor: CGPoint(x: 600, y: 999), edgeBand: 0) == zone,
              "drag target: zero band -> whole zone everywhere")
        // Small zones: the band floors at 24pt so it stays hittable. A 200pt-tall half-zone
        // would get a 10pt band at 5%; the floor lifts it to 24pt (still capped at half).
        let short = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let topOfShort = DragTarget.rect(zone: short, cursor: CGPoint(x: 500, y: 180))
        eq(topOfShort.minY, 100, "drag target: short zone floored band (24pt) -> its top half")
        check(DragTarget.rect(zone: short, cursor: CGPoint(x: 500, y: 170)) == short,
              "drag target: short zone below floored band -> whole zone")
        let tiny = CGRect(x: 0, y: 0, width: 1000, height: 30) // floor capped at half the zone
        eq(DragTarget.rect(zone: tiny, cursor: CGPoint(x: 500, y: 20)).minY, 15,
           "drag target: tiny zone band capped at half -> top half")
        // Degenerate zero-size zones: contains() is false on empty rects -> whole zone, no NaN.
        let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
        check(DragTarget.rect(zone: empty, cursor: .zero) == empty, "drag target: empty zone -> itself")
        // Cursor OUTSIDE the zone (nearest-zone fallback: menu bar above, past an edge) must
        // target the WHOLE zone — never a half via the band math on out-of-zone coordinates.
        check(t(600, 1050) == zone, "drag target: cursor above zone (menu bar) -> whole zone")
        check(t(600, -50) == zone, "drag target: cursor below zone -> whole zone")
        let outside = DragTarget.rect(zone: zone, cursor: CGPoint(x: 5000, y: 975))
        check(outside == zone, "drag target: cursor beside zone -> whole zone (no top band)")
    }

    // ---- Divider snap guides (editor drag magnetism) ----
    do {
        // Full-range divider (only one in its split): all common fractions + no "=" (mid = ½ dedupes).
        let full = DividerSnap.guides()
        check(full.count == 5, "guides: lone divider -> 5 common fractions, midpoint dedupes into ½")
        check(full.contains(where: { $0.label == "½" }), "guides: includes ½")
        check(!full.contains(where: { $0.label == "=" }), "guides: 0..1 midpoint folds into ½")

        // 3-column case: dragging divider 0 with the other divider at exactly 2/3 — guides stay
        // within reach, and the equal-zones midpoint (1/3) folds into the ⅓ guide.
        let d0 = DividerSnap.guides(neighborLower: 0, neighborUpper: 2.0 / 3.0)
        check(d0.contains(where: { $0.label == "⅓" }), "guides: ⅓ reachable below a 2/3 neighbor")
        check(!d0.contains(where: { $0.label == "¾" }), "guides: ¾ dropped (beyond the neighbor)")
        check(!d0.contains(where: { $0.label == "⅔" }), "guides: ⅔ dropped (== neighbor)")
        check(!d0.contains(where: { $0.label == "=" }), "guides: equal-zones midpoint folds into ⅓")

        // Asymmetric neighbors produce a real "=" guide at their midpoint.
        let equalized = DividerSnap.guides(neighborLower: 0.2, neighborUpper: 0.9)
        check(equalized.contains(where: { $0.label == "=" && abs($0.fraction - 0.55) < 0.0001 }),
              "guides: '=' at the neighbor midpoint (0.55)")

        // apply(): inside the threshold locks on; outside passes through untouched.
        let g = DividerSnap.guides()
        let locked = DividerSnap.apply(0.336, guides: g, threshold: 0.005)
        check(locked.guide?.label == "⅓", "snap: 0.336 within 0.005 of ⅓ -> locks")
        eq(CGFloat(locked.fraction), CGFloat(1.0 / 3.0), "snap: locked fraction is exactly ⅓")
        let free = DividerSnap.apply(0.30, guides: g, threshold: 0.005)
        check(free.guide == nil, "snap: 0.30 outside every threshold -> free")
        eq(CGFloat(free.fraction), 0.30, "snap: free drag passes through untouched")
        // Nearest guide wins between two close candidates.
        let near = DividerSnap.apply(0.49, guides: g, threshold: 0.05)
        check(near.guide?.label == "½", "snap: nearest guide wins (0.49 -> ½, not ⅓)")
        // No guides (reachable when neighbours sit so close every common fraction + midpoint is
        // excluded): the proposal passes straight through, no lock.
        let noGuides = DividerSnap.apply(0.42, guides: [], threshold: 0.05)
        eq(CGFloat(noGuides.fraction), 0.42, "snap: no guides -> proposal unchanged")
        check(noGuides.guide == nil, "snap: no guides -> no lock")
    }

    // ---- P5: left/right cycling ----
    do { // step 0 honors the seam column; later steps are fractions; dedup
        let wideLayout = Node.columns([Boundary(1133, .pixels), Boundary(2865, .pixels)])
        let left = Cycle.steps(.left, root: wideLayout, frame: frame, visibleFrame: visible, pixelsWide: px)
        eq(left[0].maxX, 1133, "cycle left step0 = seam column (1133)")
        eq(left[1].maxX, 2560, "cycle left step1 = 1/2")
        eq(left[2].maxX, 5120.0 / 3.0, "cycle left step2 = 1/3")
        eq(left[3].maxX, 2.0 / 3.0 * 5120, "cycle left step3 = 2/3")
        let right = Cycle.steps(.right, root: wideLayout, frame: frame, visibleFrame: visible, pixelsWide: px)
        eq(right[0].minX, 2865, "cycle right step0 = seam column (2865)")
        eq(right[1].minX, 2560, "cycle right step1 = 1/2")
        // halves layout: step0 == step1 -> deduped
        let halvesSteps = Cycle.steps(.left, root: .halves, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(halvesSteps.count == 3, "cycle: halves layout dedups step0==1/2 (4 -> 3)")
        eq(halvesSteps[0].maxX, 2560, "cycle halves step0 = 1/2")
        // thirds layout: step0 (left third) == the 1/3 step -> NON-adjacent dedupe (4 -> 3 unique)
        let thirdsSteps = Cycle.steps(.left, root: .thirds, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(thirdsSteps.count == 3, "cycle: thirds dedups non-adjacent 1/3 repeat (4 -> 3)")
        let widths = Set(thirdsSteps.map { Int(($0.width).rounded()) })
        check(widths.count == 3, "cycle: thirds steps are all unique widths")
        eq(thirdsSteps[0].maxX, 5120.0 / 3.0, "cycle thirds step0 = left third")

        // CENTER cycling: step 0 is the layout's middle zone, then centered 1/2, 1/3, 2/3.
        let center = Cycle.steps(.center, root: wideLayout, frame: frame, visibleFrame: visible, pixelsWide: px)
        eq(center[0].minX, 1133, "cycle center step0 = middle zone left edge (seam)")
        eq(center[0].maxX, 2865, "cycle center step0 = middle zone right edge (seam)")
        eq(center[1].minX, 1280, "cycle center step1 = centered half left")
        eq(center[1].maxX, 3840, "cycle center step1 = centered half right")
        eq(center[2].minX, 5120.0 / 3.0, "cycle center step2 = centered third left")
        eq(center[3].minX, 5120.0 / 6.0, "cycle center step3 = centered two-thirds left")
        // fraction steps (1+) are symmetric around the screen midline; step 0 honors the
        // layout's own middle zone, which may sit off-center (seam columns aren't symmetric).
        for (i, r) in center.enumerated() where i > 0 {
            eq(r.midX, 2560, "cycle center step\(i) stays centered", accuracy: 1)
        }
        // single-zone layout: step 0 falls back to the centered half (then dedups)
        let centerLeaf = Cycle.steps(.center, root: .leaf, frame: frame, visibleFrame: visible, pixelsWide: px)
        check(centerLeaf.count == 3, "cycle center on leaf: fallback dedups (4 -> 3)")
        eq(centerLeaf[0].minX, 1280, "cycle center leaf step0 = centered half")

        // left column + right stacked: the two right leaves share a minX, so an x-sort is
        // ambiguous. Center step 0 must be the SEMANTIC middle — zones order [L, R-top, R-bottom]
        // -> index 1 = right-TOP — deterministically, not whichever equal-key sort emits.
        let stacked = Node.split(axis: .vertical, dividers: [Boundary(0.5, .fraction)],
                                 children: [.leaf,
                                            Node.split(axis: .horizontal, dividers: [Boundary(0.5, .fraction)],
                                                       children: [.leaf, .leaf])])
        let cSteps = Cycle.steps(.center, root: stacked, frame: frame, visibleFrame: visible, pixelsWide: px)
        let zonesOrdered = Layout.zones(stacked, container: Layout.rootContainer(frame: frame, visibleFrame: visible), pixelsWide: px)
        eq(cSteps[0].minX, zonesOrdered[1].minX, "cycle center step0 = semantic middle x (right column)")
        eq(cSteps[0].minY, zonesOrdered[1].minY, "cycle center step0 picks the TOP of the stacked pair")
        eq(cSteps[0].height, zonesOrdered[1].height, "cycle center step0 height = the stacked zone, not the column")
    }

    do { // continuation predicate
        let steps = 4
        let rect0 = CGRect(x: 0, y: 0, width: 1133, height: 1392)
        // no prior -> step 0
        check(Cycle.nextStep(action: "left", now: 100, screenKey: "wide", focusedFrame: rect0, prev: nil, stepCount: steps) == 0, "cycle: no prev -> 0")
        let prev = CycleState(action: "left", stepIndex: 0, lastTime: 100, screenKey: "wide", lastRect: rect0)
        // same key, in time, same screen, window still at lastRect -> advance
        check(Cycle.nextStep(action: "left", now: 101, screenKey: "wide", focusedFrame: rect0, prev: prev, stepCount: steps) == 1, "cycle: continuation -> advance")
        // timed out -> reset
        check(Cycle.nextStep(action: "left", now: 103, screenKey: "wide", focusedFrame: rect0, prev: prev, stepCount: steps) == 0, "cycle: timeout -> reset")
        // different screen -> reset
        check(Cycle.nextStep(action: "left", now: 101, screenKey: "MBP", focusedFrame: rect0, prev: prev, stepCount: steps) == 0, "cycle: screen change -> reset")
        // window moved (frame != lastRect) -> reset
        let moved = CGRect(x: 50, y: 0, width: 1133, height: 1392)
        check(Cycle.nextStep(action: "left", now: 101, screenKey: "wide", focusedFrame: moved, prev: prev, stepCount: steps) == 0, "cycle: window moved -> reset")
        // wraps at end
        let prevLast = CycleState(action: "left", stepIndex: 3, lastTime: 100, screenKey: "wide", lastRect: rect0)
        check(Cycle.nextStep(action: "left", now: 101, screenKey: "wide", focusedFrame: rect0, prev: prevLast, stepCount: steps) == 0, "cycle: wraps to 0")
        // clock stepped backward (now < lastTime) -> reset, never advance
        check(Cycle.nextStep(action: "left", now: 99, screenKey: "wide", focusedFrame: rect0, prev: prev, stepCount: steps) == 0, "cycle: negative clock delta -> reset")
    }

    // ---- SemVer ----
    do {
        check(SemVer.isNewer("1.2.0", than: "1.1.9"), "semver: 1.2.0 > 1.1.9")
        check(!SemVer.isNewer("v1.0.0", than: "1.0.0"), "semver: v1.0.0 == 1.0.0 is not newer")
        check(SemVer.isNewer("1.0.1", than: "1.0.0"), "semver: 1.0.1 > 1.0.0")
        check(!SemVer.isNewer("not-a-version", than: "1.0.0"), "semver: malformed candidate -> false")
        check(!SemVer.isNewer("1.0.1", than: "not-a-version"), "semver: malformed current -> false")
    }

    do { // Pin the Info.plist invariants that anchor permission persistence + agent behavior. The TCC
         // (Accessibility) grant keys on the code-signing designated requirement, which embeds the
         // bundle id — change CFBundleIdentifier and every user must re-grant on the next update (the
         // exact pain stable signing prevents). LSUIElement keeps Lineup a menu-bar agent (no Dock
         // icon). Min-OS must match Package.swift's .macOS(.v13). Version strings are intentionally NOT
         // pinned here (they change every release). #filePath -> repo root -> Resources/Info.plist.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            check(false, "Info.plist parses as a dictionary"); fatalError("unreachable")
        }
        check(plist["CFBundleIdentifier"] as? String == "com.caiano.lineup", "Info.plist: bundle id stable (TCC/Accessibility designated-requirement anchor)")
        check(plist["LSUIElement"] as? Bool == true, "Info.plist: LSUIElement true (menu-bar agent, no Dock icon)")
        check(plist["CFBundleExecutable"] as? String == "lineup", "Info.plist: executable name matches the SPM product 'lineup'")
        check(plist["LSMinimumSystemVersion"] as? String == "13.0", "Info.plist: min macOS 13.0 (matches Package.swift .macOS(.v13))")
    }

    do { // The bundle id is the TCC / designated-requirement anchor and lives in THREE places: the
         // plist (above) plus the codesign --identifier in BOTH signing scripts. If they drift, a
         // signed build's identifier won't match the plist -> DR mismatch -> Accessibility re-grant on
         // update (the exact pain stable signing prevents). Pin 3-way consistency, anchored on the
         // plist. Read-only file parse: touches no signing identity or keychain.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistData = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plistID = (try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String
        func bundleIDInScript(_ rel: String) -> String? {
            guard let s = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else { return nil }
            for raw in s.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("BUNDLE_ID=") else { continue } // a fixed `BUNDLE_ID="..."` assignment
                return String(line.dropFirst("BUNDLE_ID=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return nil
        }
        check(plistID == "com.caiano.lineup", "bundle-id consistency: plist anchor resolved")
        check(bundleIDInScript("Scripts/build-app.sh") == plistID, "bundle-id consistency: build-app.sh codesign --identifier matches the plist")
        check(bundleIDInScript("Scripts/setup-signing.sh") == plistID, "bundle-id consistency: setup-signing.sh matches the plist (stable designated requirement)")
    }

    try runZonesToolTests()
}

// MARK: - The Zones TOOL (phase 4)
//
// The app target is an executable and isn't linked into this runner, so the tool's lifecycle
// invariants are asserted by scanning its source. That is the same technique AppSuite uses for
// the shell's single-owner rules, and it is aimed at exactly the things a future edit could
// silently drop: the five resources `stop()` has to give back, the write-then-assign ordering
// that keeps a failed save from corrupting live state, and the routing of hotkeys and the
// recording suspension through the shell's scopes instead of the singletons.

private let zonesToolPath = "Sources/lineup/Tools/Zones/ZonesTool.swift"
private let zonesPanePath = "Sources/lineup/Tools/Zones/ZonesSettingsPane.swift"

private func zonesFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// The body of a method, from its `func` line to the matching 4-space-indented closing brace.
private func zonesFuncBody(_ name: String, in text: String) -> String? {
    guard let start = text.range(of: "func \(name)") else { return nil }
    let rest = text[start.upperBound...]
    guard let end = rest.range(of: "\n    }") else { return nil }
    return String(rest[..<end.lowerBound])
}

private func runZonesToolTests() throws {
    // ---- File layout ----
    let toolText = zonesFile(zonesToolPath)
    let paneText = zonesFile(zonesPanePath)
    check(toolText != nil, "Tools/Zones/ZonesTool.swift exists")
    check(paneText != nil, "Tools/Zones/ZonesSettingsPane.swift exists")
    check(!FileManager.default.fileExists(atPath: "Sources/lineup/Tools/Zones/ZonesSettingsLegacy.swift"),
          "the parked 1.x Settings window is deleted now that the Zones pane exists")
    for moved in ["DragSnap", "LayoutEditorOverlay", "ScreenIdentity", "WindowMover"] {
        check(FileManager.default.fileExists(atPath: "Sources/lineup/Tools/Zones/\(moved).swift"),
              "\(moved).swift lives under Tools/Zones")
        check(!FileManager.default.fileExists(atPath: "Sources/lineup/\(moved).swift"),
              "\(moved).swift no longer sits at the app-target root")
    }

    guard let tool = toolText, let pane = paneText else { return }
    let dragSnap = zonesFile("Sources/lineup/Tools/Zones/DragSnap.swift") ?? ""
    let editor = zonesFile("Sources/lineup/Tools/Zones/LayoutEditorOverlay.swift") ?? ""
    let mover = zonesFile("Sources/lineup/Tools/Zones/WindowMover.swift") ?? ""
    let identity = zonesFile("Sources/lineup/Tools/Zones/ScreenIdentity.swift") ?? ""

    // ---- @MainActor pass (the merge's isolation contract) ----
    check(dragSnap.contains("@MainActor\nfinal class DragSnapController"), "DragSnapController is @MainActor")
    check(dragSnap.contains("MainActor.assumeIsolated"),
          "the drag monitor and linger timer state their main-actor isolation")
    check(dragSnap.contains("let target = DragTarget.rect(zone: zone, cursor: NSEvent.mouseLocation)") &&
          !dragSnap.contains("normalizesPlacement"),
          "Tiles observation keeps Zones half/quarter drag targets")
    check(dragSnap.contains("if let zone = lastZoneAddress, zone.frame == rect") &&
          dragSnap.contains("target = .zone(screenKey: zone.screenKey") &&
          dragSnap.contains("target = .freeform(frame: placement.frame)"),
          "drag release reports whole leaves as zones and edge targets as freeform")
    check(editor.contains("@MainActor\nfinal class LayoutEditorOverlayController"),
          "LayoutEditorOverlayController is @MainActor")
    check(editor.contains("@MainActor\nfinal class EditorWindow"), "EditorWindow is @MainActor")
    check(mover.contains("@MainActor\nfinal class SnapMemory"), "SnapMemory is @MainActor")
    check(mover.contains("@MainActor\nenum WindowMover"), "WindowMover is @MainActor")
    check(identity.contains("@MainActor\nenum ScreenIdentity"), "ScreenIdentity is @MainActor")

    // ---- The two new teardown affordances ----
    check(mover.contains("func reset()"), "SnapMemory gains reset() so stop() can drop retained AXUIElements")
    check(editor.contains("func forceClose()"), "the layout editor gains forceClose()")
    if let forceClose = zonesFuncBody("forceClose()", in: editor) {
        check(!forceClose.contains("commit("),
              "forceClose() dismisses WITHOUT committing an unconfirmed draft")
    } else {
        check(false, "forceClose() body is readable")
    }

    // ---- stop() releases every resource start() acquired ----
    if let stop = zonesFuncBody("stop()", in: tool) {
        check(stop.contains("hotkeys.unregisterAll()"), "stop() unregisters the tool's hotkeys")
        check(stop.contains("hotkeyTokens.removeAll()"), "stop() drops the hotkey tokens")
        check(stop.contains("dragSnap.stop()"), "stop() removes the global mouse monitor and linger timer")
        check(stop.contains("editorOverlay?.forceClose()") && stop.contains("editorOverlay = nil"),
              "stop() force-closes the layout editor windows")
        check(stop.contains("removeObserver(screenObserver)") && stop.contains("self.screenObserver = nil"),
              "stop() removes the screen-parameters observer")
        check(stop.contains("SnapMemory.shared.reset()"), "stop() drops the remembered windows")
        check(stop.contains("cycleState = nil"), "stop() clears the in-progress cycle")
        check(stop.contains("isRunning = false"), "stop() marks the tool stopped")
    } else {
        check(false, "ZonesTool.stop() body is readable")
    }
    check(tool.contains("screenObserver = NotificationCenter.default.addObserver"),
          "start() is the only place the screen observer is installed")

    // ---- Fresh versus stored legacy shortcut defaults ----
    check(tool.contains("if let stored = config.shortcuts { return stored }")
            && tool.contains("return usingDefaults\n            ? ShortcutKit.zonesDefaults(includeShift: hyperkeyIncludesShift())")
            && tool.contains(": ShortcutKit.defaults"),
          "a missing section uses adaptive defaults while stored shortcuts=nil keeps full Hyper")
    check(tool.contains("func hyperkeyModeDidChange()")
            && tool.contains("reloadConfig()")
            && tool.contains("if isRunning { registerHotkeys() }")
            && !tool.contains("registry.restart"),
          "Zones reloads an atomically adapted preset and re-registers hotkeys without restarting")

    // ---- Persistence: write FIRST, assign only on success, and always behind canWrite ----
    for persist in ["applyLayouts", "applyShortcuts", "persistDragSnapEnabled", "applyDragSnapTrigger"] {
        guard let body = zonesFuncBody("\(persist)(", in: tool) else {
            check(false, "\(persist) body is readable")
            continue
        }
        check(body.contains("guard canWrite"), "\(persist) is gated on canWrite")
        let save = body.range(of: "try services.config.save(updated)")
        let assign = body.range(of: "config = updated")
        check(save != nil && assign != nil && save!.lowerBound < assign!.lowerBound,
              "\(persist) writes through the config scope BEFORE assigning live state")
    }
    for persist in ["applyLayouts", "persistDragSnapEnabled", "applyDragSnapTrigger"] {
        if let body = zonesFuncBody("\(persist)(", in: tool) {
            check(body.contains("materializeFreshShortcutsIfNeeded(in: &updated)"),
                  "\(persist) materializes fresh adaptive shortcuts before its first non-shortcut write")
        }
    }
    check(tool.contains("fresh.shortcuts = ShortcutKit.zonesDefaults(includeShift: hyperkeyIncludesShift())"),
          "Zones reset persists the current adaptive shortcut preset")
    check(!tool.contains("config.write(to:"),
          "the tool never writes zones.json itself — the store owns the file")

    // ---- Hotkeys go through the tool's scope, never the singleton ----
    check(!tool.contains("HotkeyManager.shared") && !pane.contains("HotkeyManager.shared"),
          "Zones never reaches for HotkeyManager.shared (that is what makes stop() safe)")
    check(tool.contains("UInt32(binding.modifiers)"),
          "the Int->UInt32 modifier conversion happens at the registration boundary")
    check(tool.contains("case .failure(let failure)") && tool.contains("failure.displayReason"),
          "a refused registration is recorded with its reason instead of being silently dropped")

    // ---- Registration + tool contract ----
    let shell = zonesFile("Sources/lineup/App/AppShell.swift") ?? ""
    check(shell.contains("registry.register(ZonesTool(")
            && shell.contains("placementCenter: placementCenter")
            && shell.contains("layoutMutationCenter: layoutMutationCenter"),
          "AppShell registers Zones with the shared mutation boundaries")
    check(tool.contains("let defaultEnabled = true"), "Zones is on by default (1.x's incumbent behaviour)")
    check(tool.contains("let requiredPermissions: Set<Permission> = [.accessibility]"),
          "Zones declares its Accessibility requirement")
    check(tool.contains("ScreenPicker.bestScreenIndex(") &&
          tool.contains("forWindow: placement.frame") &&
          tool.contains("screens.map(\\.frame)") &&
          !tool.contains("NSScreen.screens.first(where: { $0.frame.intersects(placement.frame) })"),
          "zone shortcut placement uses the display with greatest overlap")
    check(mover.contains("onPlacement: ((ConfirmedWindowPlacement) -> Void)? = nil") &&
          mover.contains("if let placement = confirmedPlacement(of: window, expected: landed)") &&
          mover.contains("onPlacement?(placement)"),
          "cycle placement callbacks receive a confirmed moved window and frame")
    check(tool.contains("performCycle(.left, now: now)") &&
          tool.contains("performCycle(.right, now: now)") &&
          tool.contains("performCycle(.center, now: now)") &&
          tool.contains("window: placement.window") &&
          tool.contains("target: .freeform(frame: placement.frame)"),
          "cyclic Zones actions publish confirmed freeform placements")

    // ---- Menu + warnings ----
    check(tool.contains("ToolMenu.item(\"Edit Layout…\""), "the menu contributes Edit Layout…")
    check(tool.contains("-drag to snap") && tool.contains("drag.state = isDragSnapOn ? .on : .off"),
          "the menu contributes the drag-to-snap toggle with its live state")
    check(tool.contains("actionTitle: \"Retry shortcuts\""), "blocked shortcuts offer a retry")
    check(tool.contains("actionTitle: \"Reset Zones settings…\""), "an unreadable section offers a reset")

    // ---- Section-level config discipline ----
    check(tool.contains("loaded.schemaVersion <= LineupConfig.currentSchema"),
          "a section written by a newer Lineup is refused rather than silently rewritten")
    check(tool.contains("try loaded.validate()"), "a section with an invalid layout is refused")
    do {
        // Why the gate above is needed: unlike loadOrMigrate, plain decoding does NOT police the
        // schema, so a downgraded user's newer section would otherwise load and be written back.
        let newer = LineupConfig(schemaVersion: LineupConfig.currentSchema + 1)
        let round = try JSONDecoder().decode(LineupConfig.self, from: JSONEncoder().encode(newer))
        check(round.schemaVersion == LineupConfig.currentSchema + 1,
              "a newer-schema config decodes fine on its own, so the tool must gate it")
    }

    // ---- Settings pane: shared components, one recorder, no direct suspension ----
    for component in ["RecorderButton(", "CircleClearButton(", "SettingsSectionView(",
                      "SettingsRow(", "SettingsMetrics.contentWidth"] {
        check(pane.contains(component), "the Zones pane uses the shared \(component.replacingOccurrences(of: "(", with: ""))")
    }
    check(pane.contains("@StateObject private var recorder: ShortcutRecorder"),
          "the pane owns exactly one ShortcutRecorder")
    check(pane.contains("options: .combo") && pane.contains("options: .comboOrModifiers"),
          "shortcut rows capture combos; the drag bind also accepts modifiers on their own")
    check(pane.contains("case .clear"), "Delete is handled through the recorder's .clear capture")
    if let start = pane.range(of: ".onDisappear {") {
        check(pane[start.lowerBound...].prefix(120).contains("recorder.cancel()"),
              "leaving the pane cancels any capture, so the registry is never left suspended")
    } else {
        check(false, "the Zones pane cancels its capture on disappear")
    }

    // ---- A28: the drag bind accepts a BARE key (1.x allowed F5-drag) ----
    let recorder = zonesFile("Sources/lineup/Settings/Components/ShortcutRecorder.swift") ?? ""
    check(recorder.contains("var allowsBareKey = false"),
          "a modifier-less key is refused unless the field opts in")
    check(recorder.contains("static let combo = Options()"),
          "shortcut rows keep the default (no bare key): a modifier-less global hotkey would "
            + "swallow the key everywhere")
    check(recorder.contains("static let comboOrModifiers = Options(allowsModifierOnly: true, allowsBareKey: true)"),
          "the drag bind is the one preset that accepts a bare key")
    check(recorder.contains("ShortcutCaptureRules.intent(") && recorder.contains("allowsBareKey: options.allowsBareKey"),
          "the recorder decides through the shared, tested capture rules")

    // ---- B22: clearing a row ends the capture rather than leaving the registry suspended ----
    if let start = pane.range(of: "func clearShortcut(") {
        check(pane[start.lowerBound...].prefix(400).contains("cancelRecording?()"),
              "clearing a Zones shortcut cancels any live capture")
    } else {
        check(false, "ZonesSettingsModel implements clearShortcut")
    }

    // ---- A30: the cross-tool conflict source is the persisted one, not the live registry ----
    check(pane.contains("boundCombos.conflictOwner(keyCode: keyCode, modifiers: modifiers,"),
          "the Zones pane answers cross-tool conflicts from ToolCombo.conflictOwner")
    check(!pane.contains("foreignOwner"),
          "the running-tools-only conflict lookup is gone from the Zones pane")
    if let start = pane.range(of: "private func record(") {
        check(pane[start.lowerBound...].prefix(300).contains("model.prepareForRecording()"),
              "the conflict snapshot is taken when a capture starts, not per keystroke")
    } else {
        check(false, "the Zones pane owns record(_:)")
    }
    check(tool.contains("func persistedCombos()") && tool.contains("services.config.load(LineupConfig.self)"),
          "Zones reports its persisted combos from the config store, so a stopped Zones still owns them")
}
