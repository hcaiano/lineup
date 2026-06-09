import CoreGraphics
import Foundation
import LineupCore

// Minimal, dependency-free assertion harness so the suite runs under Command Line
// Tools (XCTest needs full Xcode). Exits non-zero if any check fails.

var failures = 0
var checks = 0

func check(_ cond: Bool, _ name: String) {
    checks += 1
    if !cond {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
    }
}

func eq(_ a: CGFloat, _ b: CGFloat, _ name: String, accuracy: CGFloat = 0.001) {
    check(abs(a - b) <= accuracy, "\(name) (got \(a), want \(b))")
}

func outcomeConfig(_ o: LoadOutcome) -> LineupConfig? {
    switch o { case .loaded(let c), .migrated(let c), .fresh(let c): return c; case .deferred: return nil }
}
func isMigrated(_ o: LoadOutcome) -> Bool { if case .migrated = o { return true }; return false }
func isFresh(_ o: LoadOutcome) -> Bool { if case .fresh = o { return true }; return false }

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

do { // columnRect(containingX:) picks the block under the cursor (shift-drag snapping)
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

// ---- Report ----
if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
