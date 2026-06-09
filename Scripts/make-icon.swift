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

// Subtle top sheen (flat, not glossy — kept light per the concept board).
let sheen = CGGradient(colorsSpace: rgb, colors: [
    NSColor.white.withAlphaComponent(0.16).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen,
    start: CGPoint(x: body.midX, y: body.maxY),
    end: CGPoint(x: body.midX, y: body.midY), options: [])

// The mark (concept D): a thick near-white rounded SCREEN OUTLINE split into three columns
// by two dividers; the (wider) center column is softly highlighted. Filled bars + thick
// strokes (no thin lines) so it survives at 16 px.
let padX = body.width * 0.135
let padY = body.height * 0.235
let screen = body.insetBy(dx: padX, dy: padY)
let stroke = screen.height * 0.085
let white = NSColor.white.withAlphaComponent(0.96)
let screenRadius = screen.height * 0.18

// Center column highlight (drawn first, behind the strokes).
let d0 = screen.minX + screen.width * 0.30
let d1 = screen.minX + screen.width * 0.70
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
ctx.clip()
ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
ctx.fill(CGRect(x: d0, y: screen.minY, width: d1 - d0, height: screen.height))
// Two dividers (thick) inside the clip.
ctx.setFillColor(white.cgColor)
for x in [d0, d1] { ctx.fill(CGRect(x: x - stroke / 2, y: screen.minY, width: stroke, height: screen.height)) }
ctx.restoreGState()

// Thick rounded screen outline.
ctx.addPath(CGPath(roundedRect: screen.insetBy(dx: stroke / 2, dy: stroke / 2),
                   cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
ctx.setStrokeColor(white.cgColor)
ctx.setLineWidth(stroke)
ctx.strokePath()

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
