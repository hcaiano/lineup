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
    let out = ColumnConfig.clampPixelDividers([3413, 1707], pixelsWide: 5120, minColumn: 40)
    eq(CGFloat(out[0]), 1707, "clamp: keeps valid divider 0")
    eq(CGFloat(out[1]), 3413, "clamp: keeps valid divider 1")
}

do { // clampPixelDividers: zero-width columns get pushed apart, stay in range
    let out = ColumnConfig.clampPixelDividers([0, 0], pixelsWide: 5120, minColumn: 40)
    check(out[0] >= 40, "clamp: left column >= minColumn")
    check(out[1] - out[0] >= 40, "clamp: center column >= minColumn")
    check(5120 - out[1] >= 40, "clamp: right column >= minColumn")
}

do { // clampPixelDividers: out-of-range divider clamped inside the screen
    let out = ColumnConfig.clampPixelDividers([9999, 1000], pixelsWide: 5120, minColumn: 40)
    check(out.allSatisfy { $0 >= 0 && $0 <= 5120 }, "clamp: within screen bounds")
    check(out[0] <= out[1], "clamp: sorted")
}

// ---- Report ----
if failures == 0 {
    print("ok — \(checks) checks passed")
    exit(0)
} else {
    FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
    exit(1)
}
