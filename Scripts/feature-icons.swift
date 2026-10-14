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
    let sourceMaster: String?
    let preparationReceipt: String?
}
enum Framing: String, Decodable {
    case reference
    case edgeToEdge = "edge-to-edge"
}
struct PaletteReference: Decodable { let path: String; let sha256: String }
struct Manifest: Decodable {
    let size: Int
    let reference: String
    let referenceSHA256: String
    let style: String?
    let framing: Framing?
    let features: [Feature]
    let paletteReferences: [PaletteReference]?
}
struct PreparationReceipt: Decodable {
    struct Source: Decodable { let sha256: String }
    struct NativeRender: Decodable { let path: String; let sha256: String }
    let mode: String
    let source: Source
    let outputSHA256: String
    let nativeRender: NativeRender
    enum CodingKeys: String, CodingKey {
        case mode, source
        case outputSHA256 = "output-sha256"
        case nativeRender = "native-render"
    }
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var arguments = Array(CommandLine.arguments.dropFirst())
func pathOption(_ name: String) -> URL? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("error: \(name) requires a path\n".utf8))
        exit(1)
    }
    defer { arguments.removeSubrange(index...index + 1) }
    return URL(fileURLWithPath: arguments[index + 1])
}
let manifestURL = pathOption("--manifest") ?? repo.appendingPathComponent("Design/FeatureIcons/manifest.json")
let design = manifestURL.deletingLastPathComponent()
let catalog = pathOption("--catalog") ??
    repo.appendingPathComponent("Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets")
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

func checkAlpha(_ image: CGImage, _ framing: Framing, _ label: String) throws {
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
    if framing == .reference {
        try require(transparent > width * height / 10, "\(label): missing transparent surround")
    }
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

func opaqueBounds(_ image: CGImage) throws -> CGRect {
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
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func opaqueFrame(_ image: CGImage) throws -> CGRect {
    let bounds = try opaqueBounds(image)
    let width = CGFloat(image.width), height = CGFloat(image.height)
    return CGRect(x: bounds.minX / width, y: bounds.minY / height,
                  width: bounds.width / width, height: bounds.height / height)
}

func checkFraming(_ image: CGImage, _ framing: Framing, against reference: CGRect, _ label: String,
                  exported: Bool = false) throws {
    if framing == .edgeToEdge {
        let bounds = try opaqueBounds(image)
        try require(bounds.minX <= 1 && bounds.minY <= 1 &&
                    bounds.maxX >= CGFloat(image.width - 1) && bounds.maxY >= CGFloat(image.height - 1),
                    "\(label): visible tile must reach all four canvas edges within one pixel; refine the artwork before export")
        let context = try bitmap(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        func opaque(_ x: Int, _ y: Int) -> Bool {
            bytes[(y * image.width + x) * 4 + 3] >= 240
        }
        let verticalEdges = (image.height * 3 / 8..<image.height * 5 / 8).allSatisfy { y in
            (opaque(0, y) || opaque(1, y)) &&
            (opaque(image.width - 1, y) || opaque(image.width - 2, y))
        }
        let horizontalEdges = (image.width * 3 / 8..<image.width * 5 / 8).allSatisfy { x in
            (opaque(x, 0) || opaque(x, 1)) &&
            (opaque(x, image.height - 1) || opaque(x, image.height - 2))
        }
        try require(verticalEdges && horizontalEdges,
                    "\(label): visible tile must continuously reach the center of every canvas edge; detached pixels cannot substitute for tile framing")
        return
    }
    let frame = try opaqueFrame(image)
    // Small exports have one pixel of rounding error; masters must match within 1% of canvas.
    let tolerance: CGFloat = 0.01 + (exported ? 1 / CGFloat(min(image.width, image.height)) : 0)
    try require(abs(frame.width - reference.width) <= tolerance &&
                abs(frame.height - reference.height) <= tolerance &&
                abs(frame.midX - reference.midX) <= tolerance &&
                abs(frame.midY - reference.midY) <= tolerance,
                "\(label): visible tile size or center differs from the style reference; refine the artwork before export")
}

func resized(_ image: CGImage, to size: Int) throws -> CGImage {
    let context = try bitmap(size, size)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage() else { throw Failure("Cannot resize image") }
    return result
}

func filename(_ feature: Feature, _ scale: Int) -> String {
    feature.asset + (scale == 1 ? "" : "@\(scale)x") + ".png"
}

func checkProvenance(_ feature: Feature, required: Bool) throws {
    if !required && feature.sourceMaster == nil && feature.preparationReceipt == nil { return }
    guard let source = feature.sourceMaster, let record = feature.preparationReceipt else {
        throw Failure("\(feature.id): sourceMaster and preparationReceipt are required")
    }
    for path in [source, record] {
        try require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."),
                    "\(feature.id): provenance paths must be inside Design/FeatureIcons")
    }
    let receiptURL = design.appendingPathComponent(record)
    let receipt = try JSONDecoder().decode(PreparationReceipt.self, from: Data(contentsOf: receiptURL))
    try require(receipt.mode == "native-alpha-mask", "\(feature.id): preparation must use source RGB and native alpha only")
    let maskName = URL(fileURLWithPath: receipt.nativeRender.path).lastPathComponent
    let mask = receiptURL.deletingLastPathComponent().appendingPathComponent(maskName)
    for (url, expected, label) in [(design.appendingPathComponent(source), receipt.source.sha256, "source"),
                                  (design.appendingPathComponent(feature.master), receipt.outputSHA256, "master"),
                                  (mask, receipt.nativeRender.sha256, "native mask")] {
        let actual = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        try require(actual == expected, "\(feature.id): \(label) differs from its preparation receipt")
    }
}

func checkExportPixels(_ image: CGImage, master: CGImage, _ label: String) throws {
    let expected = try resized(master, to: image.width)
    let actualContext = try bitmap(image.width, image.height)
    let expectedContext = try bitmap(image.width, image.height)
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    actualContext.draw(image, in: rect)
    expectedContext.draw(expected, in: rect)
    let actual = actualContext.data!.assumingMemoryBound(to: UInt8.self)
    let reference = expectedContext.data!.assumingMemoryBound(to: UInt8.self)
    try require((0..<image.width * image.height * 4).allSatisfy { abs(Int(actual[$0]) - Int(reference[$0])) <= 2 },
                "\(label): pixels differ from the selected master; re-export the feature catalog")
}

func export(_ manifest: Manifest) throws {
    let framing = manifest.framing ?? .reference
    let reference = try opaqueFrame(pixels(design.appendingPathComponent(manifest.reference)))
    // Validate every master before updating any derived files.
    let sources = try manifest.features.map { feature -> (Feature, CGImage) in
        try checkProvenance(feature, required: manifest.style == "restrained-v1")
        let image = try pixels(design.appendingPathComponent(feature.master))
        try require(image.width == image.height && image.width >= manifest.size * 3,
                    "\(feature.id): master must be square and at least \(manifest.size * 3) px")
        try checkAlpha(image, framing, feature.id)
        try checkFraming(image, framing, against: reference, feature.id)
        return (feature, image)
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
    let framing = manifest.framing ?? .reference
    let referenceImage = try pixels(design.appendingPathComponent(manifest.reference))
    let reference = try opaqueFrame(referenceImage)
    var count = 0
    for feature in manifest.features {
        try checkProvenance(feature, required: manifest.style == "restrained-v1")
        let master = try pixels(design.appendingPathComponent(feature.master))
        try checkAlpha(master, framing, feature.id)
        try checkFraming(master, framing, against: reference, feature.id)
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
            try checkAlpha(image, framing, expected)
            try checkExportPixels(image, master: master, expected)
            let scaledReference = try opaqueFrame(resized(referenceImage, to: manifest.size * scale))
            try checkFraming(image, framing, against: scaledReference, expected, exported: true)
            count += 1
        }
    }
    print("Verified \(manifest.features.count) imagesets, \(count) PNGs at \(manifest.size), \(manifest.size * 2), \(manifest.size * 3) px; real alpha, original color and \(framing.rawValue) tile framing.")
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
        text("Lineup / \(manifest.style ?? "features") / \(dark ? "dark" : "light")", 32, origin + CGFloat(panelHeight) - 40, 22, foreground)
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
        from: Data(contentsOf: manifestURL))
    try require(manifest.size == 72, "Feature imagesets require the shared 72 pt logical size")
    try require(!manifest.features.isEmpty, "The feature manifest must not be empty")
    try require(manifest.style != "restrained-v1" || manifest.framing == .edgeToEdge,
                "restrained-v1 requires edge-to-edge framing; every feature icon must fill the same canvas without outer padding")
    try require(!manifest.reference.hasPrefix("/") && !manifest.reference.split(separator: "/").contains(".."),
                "Reference must be inside Design/FeatureIcons")
    let referenceData = try Data(contentsOf: design.appendingPathComponent(manifest.reference))
    let referenceHash = SHA256.hash(data: referenceData).map { String(format: "%02x", $0) }.joined()
    try require(referenceHash == manifest.referenceSHA256,
                "Style reference differs from its recorded hash; restore the selected reference or version an intentional style change")
    for reference in manifest.paletteReferences ?? [] {
        try require(!reference.path.hasPrefix("/") && !reference.path.split(separator: "/").contains(".."),
                    "Palette reference must be inside Design/FeatureIcons")
        let data = try Data(contentsOf: design.appendingPathComponent(reference.path))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try require(hash == reference.sha256, "Palette reference differs from its recorded hash: \(reference.path)")
    }
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
    switch arguments.first {
    case "export": try export(manifest)
    case "verify": try verify(manifest)
    case "preview": try verify(manifest); try preview(manifest)
    case "prompt":
        guard arguments.count == 2,
              let feature = manifest.features.first(where: { $0.id == arguments[1] }) else {
            throw Failure("Use prompt <ToolID>. Known IDs: " + manifest.features.map(\.id).joined(separator: ", "))
        }
        let template = try String(contentsOf: design.appendingPathComponent("prompt-template.txt"), encoding: .utf8)
        print(template.replacingOccurrences(of: "{{color}}", with: feature.color)
                      .replacingOccurrences(of: "{{subject}}", with: feature.subject))
    default:
        throw Failure("Usage: swift Scripts/feature-icons.swift [--manifest <path>] [--catalog <path>] prompt <ToolID> | export | verify | preview")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
