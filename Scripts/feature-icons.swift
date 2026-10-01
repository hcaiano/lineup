#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation

// Mechanical PNG export only. Generate and edit artwork with imagegen before using this tool.
struct Feature: Decodable {
    let id: String
    let name: String
    let asset: String
    let color: String
    let subject: String
    let master: String
}
struct Manifest: Decodable {
    let size: Int
    let normalizeFraming: Bool?
    let reference: String
    let referenceSHA256: String
    let features: [Feature]
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let design = repo.appendingPathComponent("Design/FeatureIcons")
let catalog = repo.appendingPathComponent("Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets")
let fm = FileManager.default

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

func pixels(_ url: URL) throws -> CGImage {
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
          let image = rep.cgImage else { throw Failure("Cannot decode PNG: \(url.path)") }
    return image
}

func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw Failure("Cannot allocate sRGB RGBA bitmap")
    }
    return context
}

func checkAlpha(_ image: CGImage, _ label: String) throws {
    let width = image.width, height = image.height
    let context = try bitmap(width, height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var transparent = 0, opaque = 0
    for pixel in 0..<(width * height) {
        let alpha = bytes[pixel * 4 + 3]
        if alpha == 0 { transparent += 1 }
        if alpha >= 250 { opaque += 1 }
    }
    try require(transparent > width * height / 10, "\(label): missing transparent surround")
    try require(opaque > width * height / 3, "\(label): missing opaque tile or motif")
    for pixel in [0, width - 1, (height - 1) * width, height * width - 1] {
        try require(bytes[pixel * 4 + 3] == 0, "\(label): corners must be fully transparent")
    }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("Cannot encode PNG: \(url.path)")
    }
    try data.write(to: url, options: .atomic)
}

// Ignore near-transparent generation fragments when comparing the visible tile footprint.
func opaqueFrame(_ image: CGImage) throws -> CGRect {
    let width = image.width, height = image.height
    let context = try bitmap(width, height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where bytes[(y * width + x) * 4 + 3] >= 240 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    try require(maxX >= minX && maxY >= minY, "No opaque tile to compare")
    return CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                  width: CGFloat(maxX - minX + 1) / CGFloat(width),
                  height: CGFloat(maxY - minY + 1) / CGFloat(height))
}

func checkFraming(_ image: CGImage, against reference: CGRect, _ label: String, exported: Bool = false) throws {
    let frame = try opaqueFrame(image)
    // Small exports have one pixel of rounding error; masters must match within 1% of canvas.
    let tolerance: CGFloat = 0.01 + (exported ? 1 / CGFloat(min(image.width, image.height)) : 0)
    try require(abs(frame.width - reference.width) <= tolerance &&
                abs(frame.height - reference.height) <= tolerance &&
                abs(frame.midX - reference.midX) <= tolerance &&
                abs(frame.midY - reference.midY) <= tolerance,
                "\(label): visible tile size or center differs from the enamel reference; refine the artwork before export")
}

func resized(_ image: CGImage, to size: Int) throws -> CGImage {
    let context = try bitmap(size, size)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage() else { throw Failure("Cannot resize image") }
    return result
}

// Keep generated masters intact. Opt-in exports align their visible tile to the family reference.
func framed(_ image: CGImage, reference: CGRect, normalize: Bool) throws -> CGImage {
    guard normalize else { return image }
    let source = try opaqueFrame(image)
    try require(source.width >= 0.6 && source.height >= 0.6 &&
                source.width <= 0.9 && source.height <= 0.9 &&
                abs(source.width / source.height - 1) <= 0.1,
                "Master framing is too different for mechanical normalization; refine the artwork")
    let width = CGFloat(image.width), height = CGFloat(image.height)
    let scaleX = reference.width / source.width
    let scaleY = reference.height / source.height
    let destination = CGRect(x: (reference.minX - source.minX * scaleX) * width,
                             y: (reference.minY - source.minY * scaleY) * height,
                             width: width * scaleX, height: height * scaleY)
    let context = try bitmap(image.width, image.height)
    context.interpolationQuality = .high
    context.draw(image, in: destination)
    guard let result = context.makeImage() else { throw Failure("Cannot normalize tile framing") }
    try checkFraming(result, against: reference, "Normalized master")
    return result
}

func filename(_ feature: Feature, _ scale: Int) -> String {
    feature.asset + (scale == 1 ? "" : "@\(scale)x") + ".png"
}

func export(_ manifest: Manifest) throws {
    let reference = try opaqueFrame(pixels(design.appendingPathComponent(manifest.reference)))
    // Validate every master before updating any derived files.
    let sources = try manifest.features.map { feature -> (Feature, CGImage) in
        let image = try pixels(design.appendingPathComponent(feature.master))
        try require(image.width == image.height && image.width >= manifest.size * 3,
                    "\(feature.id): master must be square and at least \(manifest.size * 3) px")
        try checkAlpha(image, feature.id)
        let source = try framed(image, reference: reference, normalize: manifest.normalizeFraming == true)
        try checkFraming(source, against: reference, feature.id)
        return (feature, source)
    }
    try fm.createDirectory(at: catalog, withIntermediateDirectories: true)
    let info: [String: Any] = ["info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        .write(to: catalog.appendingPathComponent("Contents.json"), options: .atomic)
    for (feature, image) in sources {
        let set = catalog.appendingPathComponent(feature.asset + ".imageset")
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        for scale in 1...3 {
            try writePNG(resized(image, to: manifest.size * scale),
                         to: set.appendingPathComponent(filename(feature, scale)))
        }
        let metadata: [String: Any] = [
            "images": (1...3).map { ["filename": filename(feature, $0), "idiom": "universal", "scale": "\($0)x"] },
            "info": ["author": "xcode", "version": 1],
            "properties": ["template-rendering-intent": "original"],
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: set.appendingPathComponent("Contents.json"), options: .atomic)
    }
    try verify(manifest)
}

func verify(_ manifest: Manifest) throws {
    let referenceImage = try pixels(design.appendingPathComponent(manifest.reference))
    let reference = try opaqueFrame(referenceImage)
    var count = 0
    for feature in manifest.features {
        let master = try pixels(design.appendingPathComponent(feature.master))
        let source = try framed(master, reference: reference, normalize: manifest.normalizeFraming == true)
        try checkAlpha(source, feature.id)
        try checkFraming(source, against: reference, feature.id)
        let set = catalog.appendingPathComponent(feature.asset + ".imageset")
        let data = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: String]],
              let properties = json["properties"] as? [String: String] else {
            throw Failure("\(feature.id): invalid imageset metadata")
        }
        try require(images.count == 3 && properties["template-rendering-intent"] == "original",
                    "\(feature.id): require three original-color PNG scales")
        for scale in 1...3 {
            let expected = filename(feature, scale)
            try require(images.contains { $0["scale"] == "\(scale)x" && $0["idiom"] == "universal" && $0["filename"] == expected },
                        "\(feature.id): missing \(scale)x metadata")
            let image = try pixels(set.appendingPathComponent(expected))
            try require(image.width == manifest.size * scale && image.height == manifest.size * scale,
                        "\(expected): incorrect pixel dimensions")
            try checkAlpha(image, expected)
            let scaledReference = try opaqueFrame(resized(referenceImage, to: manifest.size * scale))
            try checkFraming(image, against: scaledReference, expected, exported: true)
            count += 1
        }
    }
    print("Verified \(manifest.features.count) imagesets, \(count) PNGs at \(manifest.size), \(manifest.size * 2), \(manifest.size * 3) px; real alpha, original color and consistent tile framing.")
}

func preview(_ manifest: Manifest) throws {
    let columns = 7
    let rows = (manifest.features.count + columns - 1) / columns
    let panelHeight = 330 * rows
    let width = 1260, height = panelHeight * 2
    let context = try bitmap(width, height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color,
        ])
    }
    NSColor(srgbRed: 0.965, green: 0.969, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: height / 2, width: width, height: height / 2).fill()
    NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height / 2).fill()
    for dark in [false, true] {
        let origin: CGFloat = dark ? 0 : CGFloat(panelHeight)
        let foreground: NSColor = dark ? .white : NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
        text(dark ? "Lineup / enamel / dark" : "Lineup / enamel / light", 32, origin + CGFloat(panelHeight) - 40, 22, foreground)
        for (index, feature) in manifest.features.enumerated() {
            let x = CGFloat(35 + (index % columns) * 175)
            let rowOrigin = origin + CGFloat(panelHeight - 330 * (index / columns + 1))
            let url = catalog.appendingPathComponent(feature.asset + ".imageset/" + filename(feature, 3))
            guard let image = NSImage(contentsOf: url) else { throw Failure("Cannot preview \(feature.asset)") }
            image.draw(in: NSRect(x: x + 10, y: rowOrigin + 125, width: 128, height: 128),
                       from: .zero, operation: .sourceOver, fraction: 1)
            text(feature.name, x + 5, rowOrigin + 101, 16, foreground)
            image.draw(in: NSRect(x: x + 10, y: rowOrigin + 19, width: 72, height: 72),
                       from: .zero, operation: .sourceOver, fraction: 1)
            image.draw(in: NSRect(x: x + 112, y: rowOrigin + 52, width: 20, height: 20),
                       from: .zero, operation: .sourceOver, fraction: 1)
            text("72", x + 36, rowOrigin + 6, 10, foreground)
            text("20", x + 115, rowOrigin + 34, 10, foreground)
        }
    }
    try writePNG(context.makeImage()!, to: design.appendingPathComponent("preview.png"))
    print("Saved Design/FeatureIcons/preview.png, including native 20 and 72 px samples.")
}

do {
    let manifest = try JSONDecoder().decode(Manifest.self,
        from: Data(contentsOf: design.appendingPathComponent("manifest.json")))
    try require(manifest.size == 72, "The enamel family requires 72 pt, matching ToolIcon's logical size")
    try require(!manifest.features.isEmpty, "The feature manifest must not be empty")
    try require(!manifest.reference.hasPrefix("/") && !manifest.reference.split(separator: "/").contains(".."),
                "Reference must be inside Design/FeatureIcons")
    let referenceData = try Data(contentsOf: design.appendingPathComponent(manifest.reference))
    let referenceHash = SHA256.hash(data: referenceData).map { String(format: "%02x", $0) }.joined()
    try require(referenceHash == manifest.referenceSHA256,
                "Style reference differs from the selected enamel-v1 reference; recover that reference or version an intentional style change")
    var ids = Set<String>(), assets = Set<String>()
    for feature in manifest.features {
        try require(ids.insert(feature.id).inserted && assets.insert(feature.asset).inserted,
                    "Duplicate feature identity or asset name")
        try require(feature.asset == "feature-" + feature.id &&
                    feature.id.range(of: "^[a-zA-Z][a-zA-Z0-9]*$", options: .regularExpression) != nil,
                    "Asset name must be feature-<stable ToolID>")
        try require(!feature.master.hasPrefix("/") && !feature.master.split(separator: "/").contains(".."),
                    "Master must be inside Design/FeatureIcons")
        try require(feature.color.range(of: "^[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
                    "\(feature.id): color must contain exactly six hex digits")
        try require(!feature.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !feature.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(feature.id): feature name and subject are required")
    }
    switch CommandLine.arguments.dropFirst().first {
    case "export": try export(manifest)
    case "verify": try verify(manifest)
    case "preview": try verify(manifest); try preview(manifest)
    case "prompt":
        guard CommandLine.arguments.count == 3,
              let feature = manifest.features.first(where: { $0.id == CommandLine.arguments[2] }) else {
            throw Failure("Use prompt <ToolID>. Known IDs: " + manifest.features.map(\.id).joined(separator: ", "))
        }
        let template = try String(contentsOf: design.appendingPathComponent("prompt-template.txt"), encoding: .utf8)
        print(template.replacingOccurrences(of: "{{color}}", with: feature.color)
                      .replacingOccurrences(of: "{{subject}}", with: feature.subject))
    default:
        throw Failure("Usage: swift Scripts/feature-icons.swift prompt <ToolID> | export | verify | preview")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
