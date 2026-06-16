import AppKit

// Renders the Open Graph / social card for the Lineup site at 1200x630 (brand blue, the
// 3-column "lineup" mark, wordmark + tagline). Usage: swift make-og.swift out.png
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og.png"

let W: CGFloat = 1200, H: CGFloat = 630
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()

// Diagonal brand-blue gradient (matches the app icon's vivid azure).
let bg = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.157, green: 0.604, blue: 0.988, alpha: 1).cgColor, // #289AFC
    NSColor(srgbRed: 0.004, green: 0.447, blue: 0.988, alpha: 1).cgColor, // #0172FC
] as CFArray, locations: [0, 1])!
func paintBG() { ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: []) }
paintBG()

// The mark (matches the app icon): a white rounded "screen" framing a tall left pane and a
// right column split into two stacked cells, the top-right one highlighted lighter azure.
let mark = NSRect(x: 96, y: H/2 - 150, width: 360, height: 300)
let gutter = mark.width * 0.058           // white frame border == gutter between cells
let radius = mark.height * 0.135
let cellRadius = gutter * 0.95
func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}
// White panel.
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(rr(mark, radius)); ctx.fillPath()
// Cells, inset one gutter on every side and split by gutters.
let content = mark.insetBy(dx: gutter, dy: gutter)
let colW = (content.width - gutter) / 2
let rowH = (content.height - gutter) / 2
let leftCell = CGRect(x: content.minX, y: content.minY, width: colW, height: content.height)
let rightX = content.minX + colW + gutter
let bottomRight = CGRect(x: rightX, y: content.minY, width: colW, height: rowH)
let topRight = CGRect(x: rightX, y: content.minY + rowH + gutter, width: colW, height: rowH)
// Left + bottom-right: the card's gradient showing through.
ctx.saveGState()
ctx.addPath(rr(leftCell, cellRadius)); ctx.addPath(rr(bottomRight, cellRadius)); ctx.clip()
paintBG()
ctx.restoreGState()
// Top-right highlight.
let hi = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.690, green: 0.831, blue: 0.992, alpha: 1).cgColor, // #B0D4FD
    NSColor(srgbRed: 0.596, green: 0.769, blue: 0.988, alpha: 1).cgColor, // #98C4FC
] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addPath(rr(topRight, cellRadius)); ctx.clip()
ctx.drawLinearGradient(hi, start: CGPoint(x: topRight.midX, y: topRight.maxY),
                       end: CGPoint(x: topRight.midX, y: topRight.minY), options: [])
ctx.restoreGState()

// Wordmark + tagline to the right of the mark.
let textX = mark.maxX + 80
NSAttributedString(string: "Lineup", attributes: [
    .font: NSFont.systemFont(ofSize: 116, weight: .bold),
    .foregroundColor: NSColor.white]).draw(at: NSPoint(x: textX, y: H/2 + 6))
NSAttributedString(string: "Draw your own window zones on macOS.", attributes: [
    .font: NSFont.systemFont(ofSize: 34, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.92)]).draw(at: NSPoint(x: textX + 4, y: H/2 - 70))

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8)); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
