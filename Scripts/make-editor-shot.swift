import AppKit

// Renders a faithful still of the on-screen layout editor for the README — same brand blue,
// zone numbering, divider px/% readouts and hover controls as Sources/lineup/LayoutEditorOverlay.swift,
// drawn over a neutral widescreen frame with zone 2 hovered. This is a documentation mock;
// replace it with a real screenshot from your display anytime. Usage: swift make-editor-shot.swift out.png
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "editor.png"

let W: CGFloat = 1760, H: CGFloat = 1100 // 16:10, a common display aspect
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()

// Brand blue — identical to Sources/lineup/Theme.swift (#2F6BFF).
let blue = NSColor(srgbRed: 0.184, green: 0.420, blue: 1.0, alpha: 1)

// A muted desktop backdrop (we can't show the user's real wallpaper) + the editor's dark wash.
let desk = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.12, green: 0.14, blue: 0.20, alpha: 1).cgColor,
    NSColor(srgbRed: 0.06, green: 0.07, blue: 0.11, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(desk, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
NSColor.black.withAlphaComponent(0.18).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()

// Layout container (leave a margin for a faux menu bar at the very top, like visibleFrame).
let menuBar: CGFloat = 26
let container = NSRect(x: 0, y: 0, width: W, height: H - menuBar)

// A representative shape: a wide left column, then two columns from a nested split —
// 3 leaves total. Divider 0 is a root *vertical* divider (pixel readout); divider 1 is the
// nested vertical split (percent readout). Zone 2 is hovered.
let pxWide = 1760
let d0frac: CGFloat = 0.46          // root divider, ~810 px
let zones: [(n: Int, rect: NSRect)] = {
    let split0 = container.minX + container.width * d0frac
    let left = NSRect(x: container.minX, y: container.minY, width: split0 - container.minX, height: container.height)
    let rightWhole = NSRect(x: split0, y: container.minY, width: container.maxX - split0, height: container.height)
    let split1 = rightWhole.minX + rightWhole.width * 0.5
    let mid = NSRect(x: rightWhole.minX, y: rightWhole.minY, width: split1 - rightWhole.minX, height: rightWhole.height)
    let right = NSRect(x: split1, y: rightWhole.minY, width: rightWhole.maxX - split1, height: rightWhole.height)
    return [(1, left), (2, mid), (3, right)]
}()
let activeN = 2

// Zones — same fills/strokes as EditorCanvas.draw, with the per-zone size readout.
let pxHigh = Int(CGFloat(pxWide) * H / W)
func sizePill(_ z: (n: Int, rect: NSRect), offsetY: CGFloat = 0) {
    // Screen-frame scale on both axes (matches the app: the container is shorter than the
    // screen by the menu bar, so container-height scaling would overstate full-height zones).
    let w = Int((z.rect.width * CGFloat(pxWide) / W).rounded())
    let h = Int((z.rect.height * CGFloat(pxHigh) / H).rounded())
    let s = NSAttributedString(string: "\(w) × \(h) px", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white])
    let sz = s.size(); let pad: CGFloat = 8
    let pill = NSRect(x: z.rect.midX - sz.width / 2 - pad, y: z.rect.midY + offsetY - sz.height / 2 - pad / 2,
                      width: sz.width + pad * 2, height: sz.height + pad)
    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
    s.draw(at: NSPoint(x: pill.midX - sz.width / 2, y: pill.midY - sz.height / 2))
}
for z in zones {
    let r = z.rect.insetBy(dx: 3, dy: 3)
    let active = z.n == activeN
    (active ? blue.withAlphaComponent(0.28) : blue.withAlphaComponent(0.12)).setFill()
    let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10); p.fill()
    (active ? blue : blue.withAlphaComponent(0.5)).setStroke()
    p.lineWidth = active ? 3 : 1.5; p.stroke()
    // Zone number, top-center of the zone.
    let s = NSAttributedString(string: "\(z.n)", attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
    let sz = s.size()
    s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.maxY - sz.height - 16))
    // Size readout in the middle of every zone (below the control bar on the active one).
    sizePill(z, offsetY: active ? -78 : 0)
}

// Dividers — white bars with grip pills (sizes live in the zones, not on the dividers).
func drawDivider(x: CGFloat) {
    let bar = NSRect(x: x - 2, y: container.minY, width: 4, height: container.height)
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: bar.insetBy(dx: 0, dy: 2), xRadius: 2, yRadius: 2).fill()
    let grip = NSRect(x: x - 8, y: container.midY - 22, width: 16, height: 44)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: grip, xRadius: 8, yRadius: 8).fill()
    blue.setStroke()
    let gp = NSBezierPath(roundedRect: grip.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
    gp.lineWidth = 1.5; gp.stroke()
    blue.withAlphaComponent(0.8).setFill()
    for k in -1...1 {
        NSBezierPath(ovalIn: NSRect(x: grip.midX - 1.6, y: grip.midY + CGFloat(k) * 8 - 1.6, width: 3.2, height: 3.2)).fill()
    }
}
let split0x = container.minX + container.width * d0frac
drawDivider(x: split0x)
let rightWhole = NSRect(x: split0x, y: container.minY, width: container.maxX - split0x, height: container.height)
drawDivider(x: rightWhole.minX + rightWhole.width * 0.5)

// Hover controls on the active zone — ONE dark HUD bar: Split | Stack | Merge, white glyphs
// that show the result, matching the overlay's other chrome.
let az = zones.first { $0.n == activeN }!.rect
let segW: CGFloat = 86, segH: CGFloat = 58, barPad: CGFloat = 6
let barW = 3 * segW + 2 * barPad, barH = segH + 2 * barPad
let bar = NSRect(x: az.midX - barW / 2, y: az.midY - barH / 2, width: barW, height: barH)
NSColor.black.withAlphaComponent(0.72).setFill()
NSBezierPath(roundedRect: bar, xRadius: 14, yRadius: 14).fill()
func segment(_ i: Int, _ title: String, hovered: Bool = false, draw: (NSRect, NSBezierPath) -> Void) {
    let seg = NSRect(x: bar.minX + barPad + CGFloat(i) * segW, y: bar.minY + barPad, width: segW, height: segH)
    if hovered {
        blue.setFill()
        NSBezierPath(roundedRect: seg.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
    let g = NSRect(x: seg.midX - 15, y: seg.midY - 4, width: 30, height: 22)
    NSColor.white.setStroke()
    let outline = NSBezierPath(roundedRect: g, xRadius: 4, yRadius: 4); outline.lineWidth = 2; outline.stroke()
    let line = NSBezierPath(); draw(g, line); line.lineWidth = 2; line.stroke()
    let s = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
    let sz = s.size()
    s.draw(at: NSPoint(x: seg.midX - sz.width / 2, y: seg.minY + 6))
}
segment(0, "Split", hovered: true) { g, l in
    l.move(to: NSPoint(x: g.midX, y: g.minY + 2)); l.line(to: NSPoint(x: g.midX, y: g.maxY - 2))
}
segment(1, "Stack") { g, l in
    l.move(to: NSPoint(x: g.minX + 2, y: g.midY)); l.line(to: NSPoint(x: g.maxX - 2, y: g.midY))
}
segment(2, "Merge") { g, l in
    l.move(to: NSPoint(x: g.midX, y: g.minY + 3)); l.line(to: NSPoint(x: g.midX, y: g.maxY - 3))
    l.setLineDash([2, 3], count: 2, phase: 0)
}

// Chrome panels — dark rounded panels matching `panel(_:)`.
func panel(_ r: NSRect) {
    NSColor.black.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
}
func label(_ text: String, _ at: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor = .white) {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        .draw(at: at)
}

// Top-center hint (the editor opens on every display showing its own layout; no picker).
let hintText = "Hover a zone to split or merge it.  Drag a handle to resize."
let hintAttr = NSAttributedString(string: hintText, attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor.white])
let hintW = hintAttr.size().width
let hintPanel = NSRect(x: W / 2 - hintW / 2 - 22, y: H - menuBar - 64, width: hintW + 44, height: 44)
panel(hintPanel)
hintAttr.draw(at: NSPoint(x: hintPanel.midX - hintW / 2, y: hintPanel.midY - hintAttr.size().height / 2))

// Bottom-CENTER: Cancel + Save.
let bottom = NSRect(x: W / 2 - 150, y: 32, width: 300, height: 60)
panel(bottom)
func button(_ r: NSRect, _ title: String, primary: Bool) {
    (primary ? blue : NSColor.white.withAlphaComponent(0.16)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    let a = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
    let s = a.size(); a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
}
button(NSRect(x: bottom.minX + 18, y: bottom.midY - 14, width: 120, height: 28), "Cancel", primary: false)
button(NSRect(x: bottom.minX + 162, y: bottom.midY - 14, width: 120, height: 28), "Save", primary: true)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
