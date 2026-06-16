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

// Diagonal brand-blue gradient (matches the app icon).
let bg = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.25, green: 0.53, blue: 0.99, alpha: 1).cgColor, // #408AFC
    NSColor(srgbRed: 0.09, green: 0.29, blue: 0.84, alpha: 1).cgColor, // #174AD6
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// The mark: a rounded white "screen" split into three columns, center gently highlighted.
let mark = NSRect(x: 96, y: H/2 - 150, width: 360, height: 300)
let stroke: CGFloat = mark.height * 0.075
let white = NSColor.white.withAlphaComponent(0.96)
let radius = mark.height * 0.16
let d0 = mark.minX + mark.width * 0.30
let d1 = mark.minX + mark.width * 0.70
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: mark, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.setFillColor(NSColor.white.withAlphaComponent(0.20).cgColor)
ctx.fill(CGRect(x: d0, y: mark.minY, width: d1 - d0, height: mark.height))
ctx.setFillColor(white.cgColor)
for x in [d0, d1] { ctx.fill(CGRect(x: x - stroke/2, y: mark.minY, width: stroke, height: mark.height)) }
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: mark.insetBy(dx: stroke/2, dy: stroke/2),
                   cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setStrokeColor(white.cgColor); ctx.setLineWidth(stroke); ctx.strokePath()

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
