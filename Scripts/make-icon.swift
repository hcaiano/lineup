import AppKit

// Renders the Lineup app icon at 1024×1024 (gradient-glass squircle with three columns,
// center gently highlighted) and writes a PNG. Usage: swift make-icon.swift out.png
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let S: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()

ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// Rounded-square ("squircle"-ish) body, centered with margin, Apple-ish corner radius.
let margin: CGFloat = 92
let body = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = body.width * 0.2237
let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow for depth.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16),
              blur: 48, color: NSColor.black.withAlphaComponent(0.33).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Clip to the squircle and paint everything inside.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Vertical brand-blue gradient (bright azure at top, deep blue at the base) — the concept-1
// look. Kept in the brand-blue family so the icon reads as the same product as the menu bar
// and website accent.
let bg = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.157, green: 0.604, blue: 0.988, alpha: 1).cgColor, // bright azure #289AFC
    NSColor(srgbRed: 0.004, green: 0.447, blue: 0.988, alpha: 1).cgColor, // deep blue    #0172FC
] as CFArray, locations: [0, 1])!
func paintBody() {
    ctx.drawLinearGradient(bg,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY), options: [])
}
paintBody()

// Subtle top sheen (flat, not glossy — kept light per the concept board).
let sheen = CGGradient(colorsSpace: rgb, colors: [
    NSColor.white.withAlphaComponent(0.16).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen,
    start: CGPoint(x: body.midX, y: body.maxY),
    end: CGPoint(x: body.midX, y: body.midY), options: [])

// The mark (concept-1): a white rounded "screen" framing three rounded zones — one tall pane
// on the left, and a right column split into two stacked cells. The top-right cell is softly
// highlighted (lighter azure) to read as the "active" zone. The left and bottom-right cells
// are the body gradient showing through, so they sit on the same blue surface as the icon.
// All-rounded filled cells (no thin lines) so the motif survives at 16 px.
let screen = CGRect(x: body.minX + body.width * 0.129,
                    y: body.minY + body.height * 0.181,
                    width: body.width * 0.742,
                    height: body.height * 0.638)
let gutter = body.width * 0.043           // white gap: frame border == gutter between cells
let screenRadius = screen.height * 0.135
let cellRadius = gutter * 0.95
func rrect(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// White screen panel.
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(rrect(screen, screenRadius))
ctx.fillPath()

// Cell rects, inset from the panel by one gutter on every side and split by gutters.
let content = screen.insetBy(dx: gutter, dy: gutter)
let colW = (content.width - gutter) / 2     // equal left pane / right column
let rowH = (content.height - gutter) / 2     // equal top / bottom right cells
let leftCell = CGRect(x: content.minX, y: content.minY, width: colW, height: content.height)
let rightX = content.minX + colW + gutter
let bottomRight = CGRect(x: rightX, y: content.minY, width: colW, height: rowH)
let topRight = CGRect(x: rightX, y: content.minY + rowH + gutter, width: colW, height: rowH)

// Left pane + bottom-right cell: the body gradient showing through (clip, then repaint it).
ctx.saveGState()
ctx.addPath(rrect(leftCell, cellRadius))
ctx.addPath(rrect(bottomRight, cellRadius))
ctx.clip()
paintBody()
ctx.restoreGState()

// Top-right highlight cell: a lighter azure, with a faint top-down sheen of its own.
let hi = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.690, green: 0.831, blue: 0.992, alpha: 1).cgColor, // #B0D4FD
    NSColor(srgbRed: 0.596, green: 0.769, blue: 0.988, alpha: 1).cgColor, // #98C4FC
] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(rrect(topRight, cellRadius))
ctx.clip()
ctx.drawLinearGradient(hi,
    start: CGPoint(x: topRight.midX, y: topRight.maxY),
    end: CGPoint(x: topRight.midX, y: topRight.minY), options: [])
ctx.restoreGState()

// Subtle inner edge for crispness.
ctx.addPath(squircle)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
