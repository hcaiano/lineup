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

// Diagonal blue gradient (brand blue).
let bg = CGGradient(colorsSpace: rgb, colors: [
    NSColor(srgbRed: 0.25, green: 0.53, blue: 0.99, alpha: 1).cgColor, // bright blue  #408AFC
    NSColor(srgbRed: 0.09, green: 0.29, blue: 0.84, alpha: 1).cgColor, // deep blue    #174AD6
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg,
    start: CGPoint(x: body.minX, y: body.maxY),
    end: CGPoint(x: body.maxX, y: body.minY), options: [])

// Glass sheen across the top (drawn under the screen so dividers stay crisp).
let sheen = CGGradient(colorsSpace: rgb, colors: [
    NSColor.white.withAlphaComponent(0.30).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen,
    start: CGPoint(x: body.midX, y: body.maxY),
    end: CGPoint(x: body.midX, y: body.midY + body.height * 0.06), options: [])

// The mark: three near-white columns (the lineup motif, same as the menu-bar logo). Solid
// fills with the center brightest, so the mark survives at 16 px. Unequal widths echo the
// ultrawide split.
let padX = body.width * 0.13
let padY = body.height * 0.245
let inner = body.insetBy(dx: padX, dy: padY)
let gap = inner.width * 0.045
let usable = inner.width - gap * 2
let widths = [0.30, 0.40, 0.30].map { $0 * usable }
let alphas: [CGFloat] = [0.82, 1.0, 0.82] // center brightest
let colRadius = inner.height * 0.10

ctx.saveGState()
var x = inner.minX
for (w, a) in zip(widths, alphas) {
    let bar = CGRect(x: x, y: inner.minY, width: w, height: inner.height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: colRadius, cornerHeight: colRadius, transform: nil))
    ctx.setFillColor(NSColor.white.withAlphaComponent(a).cgColor)
    ctx.fillPath()
    x += w + gap
}
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
