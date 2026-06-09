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

// Inner "screen": a wide rounded panel (reads as an ultrawide monitor) split into three
// columns — left / center / right — with the center gently highlighted.
let padX = body.width * 0.11
let padY = body.height * 0.255
let inner = body.insetBy(dx: padX, dy: padY)
let innerRadius = inner.height * 0.14
let innerPath = CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(innerPath)
ctx.clip()

// Darken slightly so it reads as a display and the dividers pop.
ctx.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor)
ctx.fill(inner)

let d0 = inner.minX + inner.width * 0.30   // left|center divider
let d1 = inner.minX + inner.width * 0.70   // center|right divider

// Center column highlight.
ctx.setFillColor(NSColor.white.withAlphaComponent(0.20).cgColor)
ctx.fill(CGRect(x: d0, y: inner.minY, width: d1 - d0, height: inner.height))

// Two crisp divider lines with a faint glow.
let lineW: CGFloat = 14
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: NSColor.white.withAlphaComponent(0.6).cgColor)
ctx.setFillColor(NSColor.white.cgColor)
for x in [d0, d1] {
    ctx.fill(CGRect(x: x - lineW / 2, y: inner.minY, width: lineW, height: inner.height))
}
ctx.restoreGState()
ctx.restoreGState() // unclip the screen

// Screen edge.
ctx.addPath(innerPath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()

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
