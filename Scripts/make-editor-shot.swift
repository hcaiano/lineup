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

// Zones — same fills/strokes as EditorCanvas.draw.
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
}

// Dividers — white bars + readout pills (px for the root vertical, % for the nested one).
func drawDivider(x: CGFloat, text: String) {
    let bar = NSRect(x: x - 2, y: container.minY, width: 4, height: container.height)
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: bar.insetBy(dx: 0, dy: 2), xRadius: 2, yRadius: 2).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor.white]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size(); let pad: CGFloat = 7
    let pillW = sz.width + pad * 2, pillH = sz.height + pad
    let pill = NSRect(x: x - pillW / 2, y: container.maxY - pillH - 16, width: pillW, height: pillH)
    NSColor.black.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
    s.draw(at: NSPoint(x: pill.midX - sz.width / 2, y: pill.midY - sz.height / 2))
}
let split0x = container.minX + container.width * d0frac
let px = Int((d0frac * CGFloat(pxWide)).rounded())
drawDivider(x: split0x, text: "\(px) px")
let rightWhole = NSRect(x: split0x, y: container.minY, width: container.maxX - split0x, height: container.height)
drawDivider(x: rightWhole.minX + rightWhole.width * 0.5, text: "50%")

// Hover controls on the active zone — two split buttons (side-by-side / stacked) + merge,
// rendered as the editor draws them (white rounded chips, blue SF-style glyphs).
let az = zones.first { $0.n == activeN }!.rect
let chip: CGFloat = 64, gap: CGFloat = 18
let cx = az.midX, cy = az.midY
func chipRect(_ x: CGFloat) -> NSRect { NSRect(x: x, y: cy - chip / 2, width: chip, height: chip) }
let leftChip = chipRect(cx - chip - gap / 2)
let rightChip = chipRect(cx + gap / 2)

func drawChip(_ r: NSRect, _ draw: (NSRect) -> Void) {
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).fill()
    draw(r.insetBy(dx: 16, dy: 16))
}
// "Split side by side": a rounded rect divided by a vertical line.
drawChip(leftChip) { g in
    blue.setStroke()
    let p = NSBezierPath(roundedRect: g, xRadius: 4, yRadius: 4); p.lineWidth = 3; p.stroke()
    let v = NSBezierPath(); v.move(to: NSPoint(x: g.midX, y: g.minY)); v.line(to: NSPoint(x: g.midX, y: g.maxY))
    v.lineWidth = 3; v.stroke()
}
// "Split stacked": a rounded rect divided by a horizontal line.
drawChip(rightChip) { g in
    blue.setStroke()
    let p = NSBezierPath(roundedRect: g, xRadius: 4, yRadius: 4); p.lineWidth = 3; p.stroke()
    let h = NSBezierPath(); h.move(to: NSPoint(x: g.minX, y: g.midY)); h.line(to: NSPoint(x: g.maxX, y: g.midY))
    h.lineWidth = 3; h.stroke()
}
// Merge chip below (active zone is nested, so merge is available).
let mergeChip = NSRect(x: cx - 26, y: cy - chip / 2 - 50, width: 52, height: 36)
drawChip(mergeChip) { g in
    blue.setStroke()
    let a = NSBezierPath()
    a.move(to: NSPoint(x: g.minX, y: g.minY)); a.line(to: NSPoint(x: g.midX, y: g.midY)); a.line(to: NSPoint(x: g.minX, y: g.maxY))
    a.move(to: NSPoint(x: g.maxX, y: g.minY)); a.line(to: NSPoint(x: g.midX, y: g.midY)); a.line(to: NSPoint(x: g.maxX, y: g.maxY))
    a.lineWidth = 3; a.stroke()
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

// Top-left: "Editing layout" + display picker.
let topPanel = NSRect(x: 28, y: H - menuBar - 70, width: 540, height: 56)
panel(topPanel)
label("Editing layout", NSPoint(x: topPanel.minX + 20, y: topPanel.midY - 9), size: 16, weight: .semibold)
let pick = NSRect(x: topPanel.minX + 170, y: topPanel.midY - 16, width: 350, height: 32)
NSColor.white.withAlphaComponent(0.14).setFill()
NSBezierPath(roundedRect: pick, xRadius: 7, yRadius: 7).fill()
label("Main Display", NSPoint(x: pick.minX + 12, y: pick.midY - 8), size: 14, weight: .regular)
// chevrons
blue.setStroke()
let ch = NSBezierPath()
let chx = pick.maxX - 20
ch.move(to: NSPoint(x: chx - 5, y: pick.midY + 2)); ch.line(to: NSPoint(x: chx, y: pick.midY + 7)); ch.line(to: NSPoint(x: chx + 5, y: pick.midY + 2))
ch.move(to: NSPoint(x: chx - 5, y: pick.midY - 2)); ch.line(to: NSPoint(x: chx, y: pick.midY - 7)); ch.line(to: NSPoint(x: chx + 5, y: pick.midY - 2))
ch.lineWidth = 2; ch.stroke()

// Top-center hint.
let hintText = "Hover a zone, then split it ▮▮ / ▬▬ or merge.  Drag a divider to resize."
let hintAttr = NSAttributedString(string: hintText, attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor.white])
let hintW = hintAttr.size().width
let hintPanel = NSRect(x: W / 2 - hintW / 2 - 22, y: H - menuBar - 64, width: hintW + 44, height: 44)
panel(hintPanel)
hintAttr.draw(at: NSPoint(x: hintPanel.midX - hintW / 2, y: hintPanel.midY - hintAttr.size().height / 2))

// Bottom-right: Cancel + Done.
let bottom = NSRect(x: W - 360, y: 32, width: 332, height: 62)
panel(bottom)
func button(_ r: NSRect, _ title: String, primary: Bool) {
    (primary ? blue : NSColor.white.withAlphaComponent(0.16)).setFill()
    NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    let a = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white])
    let s = a.size(); a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
}
button(NSRect(x: bottom.minX + 18, y: bottom.midY - 16, width: 130, height: 32), "Cancel", primary: false)
button(NSRect(x: bottom.minX + 166, y: bottom.midY - 16, width: 130, height: 32), "Done", primary: true)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
