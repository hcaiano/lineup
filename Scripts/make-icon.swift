#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation

// Mechanical export only. Generate and refine artwork with imagegen.
struct Candidate: Decodable {
    let id: String, name: String, master: String, subject: String
}
struct Manifest: Decodable {
    let reference: String, referenceSHA256: String, selected: String
    let candidates: [Candidate]
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let design = repo.appendingPathComponent("Design/AppIcon")
let iconset = repo.appendingPathComponent("Icon/AppIcon.iconset")
let catalog = repo.appendingPathComponent("Icon/AppIcon.xcassets")
let appiconset = catalog.appendingPathComponent("AppIcon.appiconset")
let fm = FileManager.default
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}
func pixels(_ url: URL) throws -> CGImage {
    guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)), let image = rep.cgImage else {
        throw Failure("Cannot decode PNG: \(url.path)")
    }
    return image
}
func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
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
        if bytes[pixel * 4 + 3] == 0 { transparent += 1 }
        if bytes[pixel * 4 + 3] >= 250 { opaque += 1 }
    }
    try require(transparent > width * height / 10, "\(label): missing transparent surround")
    try require(opaque > width * height / 3, "\(label): missing opaque tile or motif")
    for pixel in [0, width - 1, (height - 1) * width, height * width - 1] {
        try require(bytes[pixel * 4 + 3] == 0, "\(label): corners must be transparent")
    }
}
func resized(_ image: CGImage, _ size: Int) throws -> CGImage {
    let context = try bitmap(size, size)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let result = context.makeImage() else { throw Failure("Cannot resize PNG") }
    return result
}
func pngData(_ image: CGImage) throws -> Data {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw Failure("Cannot encode PNG")
    }
    return data
}
func writePNG(_ image: CGImage, _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData(image).write(to: url, options: .atomic)
}
func filename(_ points: Int, _ scale: Int) -> String {
    "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
}
func imagesMetadata() -> [[String: String]] {
    slots.map { ["filename": filename($0.points, $0.scale), "idiom": "mac",
        "size": "\($0.points)x\($0.points)", "scale": "\($0.scale)x"] }
}
func export(_ image: CGImage) throws {
    try writePNG(resized(image, 1024), repo.appendingPathComponent("Icon/icon-1024.png"))
    for slot in slots {
        let output = try resized(image, slot.points * slot.scale)
        try writePNG(output, iconset.appendingPathComponent(filename(slot.points, slot.scale)))
        try writePNG(output, appiconset.appendingPathComponent(filename(slot.points, slot.scale)))
    }
    let info: [String: Any] = ["info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        .write(to: catalog.appendingPathComponent("Contents.json"), options: .atomic)
    let metadata: [String: Any] = ["images": imagesMetadata(), "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        .write(to: appiconset.appendingPathComponent("Contents.json"), options: .atomic)
    try verify(image)
}
func verify(_ source: CGImage) throws {
    func check(_ url: URL, _ size: Int) throws {
        let image = try pixels(url)
        try require(image.width == size && image.height == size, "Incorrect dimensions: \(url.path)")
        try checkAlpha(image, url.lastPathComponent)
        let expected = try pngData(resized(source, size))
        try require(Data(contentsOf: url) == expected, "Export differs from the selected master: \(url.path)")
    }
    try check(repo.appendingPathComponent("Icon/icon-1024.png"), 1024)
    for slot in slots {
        try check(iconset.appendingPathComponent(filename(slot.points, slot.scale)), slot.points * slot.scale)
        try check(appiconset.appendingPathComponent(filename(slot.points, slot.scale)), slot.points * slot.scale)
    }
    let object = try JSONSerialization.jsonObject(with:
        Data(contentsOf: appiconset.appendingPathComponent("Contents.json")))
    guard let json = object as? [String: Any], let images = json["images"] as? [[String: String]] else {
        throw Failure("Invalid macOS appiconset metadata")
    }
    try require(images == imagesMetadata(), "AppIcon requires all ten macOS size/scale entries")
    print("Verified selected 1024 px PNG and ten macOS slots in iconset and appiconset; sRGB, alpha and master consistency.")
}
func preview(_ manifest: Manifest) throws {
    let width = 1200, height = 1140
    let context = try bitmap(width, height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ dark: Bool) {
        (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: dark ? NSColor.white : NSColor.black,
        ])
    }
    for dark in [false, true] {
        let origin: CGFloat = dark ? 340 : 740
        (dark ? NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1) :
            NSColor(srgbRed: 0.965, green: 0.969, blue: 0.98, alpha: 1)).setFill()
        NSRect(x: 0, y: origin, width: CGFloat(width), height: 400).fill()
        text(dark ? "Lineup / enamel / dark" : "Lineup / enamel / light", 26, origin + 364, 20, dark)
        for (index, candidate) in manifest.candidates.enumerated() {
            let x = CGFloat(index * 400) + (CGFloat(width) - CGFloat(manifest.candidates.count * 400)) / 2
            guard let image = NSImage(contentsOf: design.appendingPathComponent(candidate.master)) else {
                throw Failure("Cannot preview \(candidate.id)")
            }
            image.draw(in: NSRect(x: x + 112, y: origin + 180, width: 176, height: 176),
                from: .zero, operation: .sourceOver, fraction: 1)
            text(candidate.name, x + 120, origin + 157, 15, dark)
            var sampleX = x + 42
            for size in [16, 32, 64, 128] {
                // Render actual pixel sizes, without a UI scale factor.
                image.draw(in: NSRect(x: sampleX, y: origin + 22, width: CGFloat(size), height: CGFloat(size)),
                    from: .zero, operation: .sourceOver, fraction: 1)
                text("\(size)", sampleX, origin + 8, 10, dark)
                sampleX += CGFloat(size + 24)
            }
        }
    }
    NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 340).fill()
    text("Lineup + features / enamel-v1", 26, 295, 20, false)
    guard let app = NSImage(contentsOf: repo.appendingPathComponent("Icon/icon-1024.png")) else {
        throw Failure("Export the selected app icon first")
    }
    app.draw(in: NSRect(x: 30, y: 99, width: 176, height: 176), from: .zero, operation: .sourceOver, fraction: 1)
    text("Lineup", 92, 76, 16, false)
    let object = try JSONSerialization.jsonObject(with:
        Data(contentsOf: repo.appendingPathComponent("Design/FeatureIcons/manifest.json")))
    guard let featureManifest = object as? [String: Any],
          let features = featureManifest["features"] as? [[String: String]] else {
        throw Failure("Cannot read the feature family")
    }
    for (index, feature) in features.enumerated() {
        guard let asset = feature["asset"], let name = feature["name"] else {
            throw Failure("Missing feature metadata")
        }
        let url = repo.appendingPathComponent("Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets/\(asset).imageset/\(asset)@3x.png")
        guard let image = NSImage(contentsOf: url) else { throw Failure("Cannot preview \(asset)") }
        let x = CGFloat(245 + index * 132)
        image.draw(in: NSRect(x: x, y: 132, width: 100, height: 100), from: .zero, operation: .sourceOver, fraction: 1)
        text(name, x + 5, 108, 12, false)
    }
    try writePNG(context.makeImage()!, design.appendingPathComponent("preview.png"))
    print("Saved Design/AppIcon/preview.png with 16/32/64/128 px samples and the feature family.")
}

do {
    let manifest = try JSONDecoder().decode(Manifest.self, from:
        Data(contentsOf: design.appendingPathComponent("manifest.json")))
    try require(manifest.reference == "../FeatureIcons/references/enamel-v1.png", "Use the versioned enamel-v1 reference")
    let reference = try Data(contentsOf: design.appendingPathComponent(manifest.reference))
    let hash = SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
    try require(hash == manifest.referenceSHA256, "The versioned style reference changed")
    var ids = Set<String>()
    for candidate in manifest.candidates {
        try require(ids.insert(candidate.id).inserted &&
            candidate.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil, "Candidate IDs must be unique slugs")
        let sharedZonesMaster = candidate.id == "zones" && candidate.master == "../FeatureIcons/masters/zones.png"
        try require(!candidate.master.hasPrefix("/") &&
            (!candidate.master.split(separator: "/").contains("..") || sharedZonesMaster),
            "Master must be inside Design/AppIcon or use the shared Zones master")
        try require(!candidate.subject.isEmpty && !candidate.name.isEmpty, "Name and subject are required")
    }
    guard let selected = manifest.candidates.first(where: { $0.id == manifest.selected }) else {
        throw Failure("The selected logo must name a candidate")
    }
    let command = CommandLine.arguments.dropFirst().first ?? "export"
    if command == "prompt" {
        let template = try String(contentsOf: design.appendingPathComponent("prompt-template.txt"), encoding: .utf8)
        print(template.replacingOccurrences(of: "{{subject}}", with: selected.subject))
    } else {
        let image = try pixels(design.appendingPathComponent(selected.master))
        try require(image.width == image.height && image.width >= 1024, "Master must be square and at least 1024 px")
        try checkAlpha(image, selected.id)
        switch command {
        case "export": try export(image)
        case "verify": try verify(image)
        case "preview": try verify(image); try preview(manifest)
        default:
            // Preserve the previous script's single-PNG output argument.
            try require(command.hasSuffix(".png"), "Usage: swift Scripts/make-icon.swift [export|verify|preview|prompt|output.png]")
            try writePNG(resized(image, 1024), URL(fileURLWithPath: command))
        }
    }
} catch {
    fputs("App icon: \(error)\n", stderr)
    exit(1)
}
