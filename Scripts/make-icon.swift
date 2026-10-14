#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation

struct Candidate: Decodable {
    let id: String, name: String, subject: String, master: String
    let nativeDocument: String?, reference: String?, referenceSHA256: String?
}
struct Manifest: Decodable {
    let selected: String
    let candidates: [Candidate]
}
struct Tool: Codable, Equatable {
    let name: String, version: String, arguments: [String]
}
struct Receipt: Codable {
    let document: String, sourceSHA256: String, minimumSystemVersion: String
    let renderer: Tool, compiler: Tool
    let outputs: [String: String]
    let rendererArguments: [String: [String]]
}
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let design = repo.appendingPathComponent("Design/AppIcon")
let receiptURL = design.appendingPathComponent("receipt.json")
let fm = FileManager.default
let renditions = ["Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"]
let renderPaths = ["Default": "Design/AppIcon/masters/lineup-native.png",
                   "Default-26": "Design/AppIcon/renders/Default-26.png"]
    .merging(renditions.dropFirst().map { ($0, "Design/AppIcon/renders/\($0).png") }) { $1 }
let icnsPath = "Resources/AppIcon.icns", compiled1024Path = "Icon/icon-1024.png"

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func temporaryDirectory() throws -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("lineup-app-icon-\(UUID().uuidString)")
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try require(process.terminationStatus == 0,
        "\((executable as NSString).lastPathComponent) failed (\(process.terminationStatus)): \(text)")
    return text
}

func developerDirectory() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { return URL(fileURLWithPath: path) }
    return URL(fileURLWithPath: try run("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines))
}
func xcodeRequired(_ detail: String) -> Failure {
    Failure("\(detail). The native app icon needs full Xcode 26 or later; run with " +
        "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.")
}
func ictool() throws -> (path: String, version: String) {
    let path = try developerDirectory().deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool").path
    guard fm.isExecutableFile(atPath: path) else { throw xcodeRequired("Icon Composer's ictool is missing at \(path)") }
    let object = try JSONSerialization.jsonObject(with: Data(try run(path, ["--version"]).utf8))
    guard let info = object as? [String: String], let short = info["short-bundle-version"],
          let build = info["bundle-version"] else { throw Failure("Cannot read the ictool version") }
    return (path, "\(short) (\(build))")
}
func actool() throws -> (path: String, version: String) {
    let developer = try developerDirectory()
    let path = developer.appendingPathComponent("usr/bin/actool").path
    guard fm.isExecutableFile(atPath: path) else { throw xcodeRequired("actool is missing from \(developer.path)") }
    let plist = try PropertyListSerialization.propertyList(from: Data(try run(path, ["--version"]).utf8), format: nil)
    guard let info = (plist as? [String: Any])?["com.apple.actool.version"] as? [String: String],
          let short = info["short-bundle-version"], let build = info["bundle-version"],
          let major = Int(short.split(separator: ".").first ?? "") else {
        throw Failure("Cannot read the actool version")
    }
    guard major >= 26 else { throw xcodeRequired("actool \(short) cannot compile Icon Composer documents") }
    return (path, "\(short) (\(build))")
}

func minimumSystemVersion() throws -> String {
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: repo.appendingPathComponent("Resources/Info.plist")), format: nil)
    guard let version = (plist as? [String: Any])?["LSMinimumSystemVersion"] as? String else {
        throw Failure("Resources/Info.plist has no LSMinimumSystemVersion")
    }
    return version
}
func sourceSHA256(_ document: URL) throws -> String {
    guard let enumerator = fm.enumerator(at: document, includingPropertiesForKeys: [.isRegularFileKey]) else {
        throw Failure("Cannot read \(document.path)")
    }
    var files: [(path: String, hash: String)] = []
    for case let url as URL in enumerator where url.lastPathComponent != ".DS_Store" {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        let relative = String(url.standardizedFileURL.path.dropFirst(document.standardizedFileURL.path.count + 1))
        files.append((relative, sha256(try Data(contentsOf: url))))
    }
    return sha256(Data(files.sorted { $0.path < $1.path }.map { "\($0.hash)  \($0.path)\n" }.joined().utf8))
}
func checkDocument(_ document: URL) throws {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: document.appendingPathComponent("icon.json")))
    guard let icon = object as? [String: Any],
          let squares = (icon["supported-platforms"] as? [String: Any])?["squares"] else {
        throw Failure("\(document.lastPathComponent) has no square platforms")
    }
    try require((squares as? String) == "shared" || (squares as? [String])?.contains("macOS") == true,
        "\(document.lastPathComponent) must support macOS")
    for group in icon["groups"] as? [[String: Any]] ?? [] {
        for layer in group["layers"] as? [[String: Any]] ?? [] {
            guard let image = layer["image-name"] as? String else { continue }
            try require(fm.fileExists(atPath: document.appendingPathComponent("Assets/\(image)").path),
                "\(document.lastPathComponent) is missing Assets/\(image)")
        }
    }
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
func alpha(_ image: CGImage, _ points: [(Int, Int)]) throws -> [UInt8] {
    let context = try bitmap(image.width, image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    return points.map { bytes[($0.1 * image.width + $0.0) * 4 + 3] }
}
func writePNG(_ image: CGImage, _ url: URL) throws {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw Failure("Cannot encode PNG")
    }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
func compiledIcon(_ car: URL, in scratch: URL) throws -> NSImage {
    let resources = scratch.appendingPathComponent("IconCheck.bundle/Contents/Resources")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    try fm.copyItem(at: car, to: resources.appendingPathComponent("Assets.car"))
    let info: [String: String] = ["CFBundleIdentifier": "local.lineup.icon-check", "CFBundlePackageType": "BNDL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    guard let image = Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent())?
        .image(forResource: "AppIcon") else { throw Failure("Compiled Assets.car has no AppIcon image") }
    return image
}

func renderArguments(_ rendition: String, generation: String?, size: Int) -> [String] {
    ["--export-image", "--output-file", "<output>", "--platform", "macOS", "--rendition", rendition,
     "--width", "\(size)", "--height", "\(size)", "--scale", "1"] + (generation.map { ["--design-generation", $0] } ?? [])
}
func render(_ document: URL, _ rendition: String, generation: String? = nil, size: Int = 1024, to output: URL) throws {
    let arguments = renderArguments(rendition, generation: generation, size: size)
        .map { $0 == "<output>" ? output.path : $0 }
    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try run(try ictool().path, [document.path] + arguments)
}
func compileArguments(_ minimum: String) -> [String] {
    ["<AppIcon.icon>", "--compile", "<output>", "--output-format", "human-readable-text", "--errors", "--warnings",
     "--output-partial-info-plist", "<output>/AppIcon-Info.plist", "--app-icon", "AppIcon",
     "--include-all-app-icons", "--enable-on-demand-resources", "NO", "--development-region", "en",
     "--target-device", "mac", "--minimum-deployment-target", minimum, "--platform", "macosx"]
}
/// Compiles a staged copy named AppIcon.icon: actool names the app icon after the document, and the
/// bundle's CFBundleIconFile and the app's NSImage(named: "AppIcon") lookups use that name.
func compile(_ document: URL, into output: URL, minimum: String) throws {
    let tool = try actool()
    let scratch = try temporaryDirectory()
    defer { try? fm.removeItem(at: scratch) }
    let staged = scratch.appendingPathComponent("AppIcon.icon"), result = scratch.appendingPathComponent("out")
    try fm.copyItem(at: document, to: staged)
    try fm.createDirectory(at: result, withIntermediateDirectories: true)
    let arguments = compileArguments(minimum).map {
        $0.replacingOccurrences(of: "<AppIcon.icon>", with: staged.path).replacingOccurrences(of: "<output>", with: result.path)
    }
    let log = try run(tool.path, arguments)
    try require(!log.contains("com.apple.actool.errors"), "actool reported errors: \(log)")
    let plist = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: result.appendingPathComponent("AppIcon-Info.plist")), format: nil) as? [String: String]
    try require(plist?["CFBundleIconName"] == "AppIcon" && plist?["CFBundleIconFile"] == "AppIcon",
        "actool did not declare the AppIcon bundle keys")
    for name in ["Assets.car", "AppIcon.icns", "AppIcon-Info.plist"] {
        let source = result.appendingPathComponent(name), destination = output.appendingPathComponent(name)
        try require(fm.fileExists(atPath: source.path), "actool did not write \(name)")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }
}

func selectedDocument(_ manifest: Manifest) throws -> (Candidate, URL) {
    var ids = Set<String>()
    for candidate in manifest.candidates {
        try require(ids.insert(candidate.id).inserted &&
            candidate.id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
            "Candidate IDs must be unique slugs")
        try require(!candidate.subject.isEmpty && !candidate.name.isEmpty, "Name and subject are required")
    }
    guard let selected = manifest.candidates.first(where: { $0.id == manifest.selected }) else {
        throw Failure("The selected logo must name a candidate")
    }
    guard let name = selected.nativeDocument, name.hasSuffix(".icon"), !name.contains("/") else {
        throw Failure("The selected logo must name an Icon Composer document inside Design/AppIcon")
    }
    try require(selected.master == renderPaths["Default"]!.replacingOccurrences(of: "Design/AppIcon/", with: ""),
        "The selected master must be the native Default render")
    if let reference = selected.reference {
        let url = design.appendingPathComponent(reference)
        try require(fm.fileExists(atPath: url.path), "The approved reference moved: \(reference)")
        try require(sha256(try Data(contentsOf: url)) == selected.referenceSHA256, "The approved reference changed: \(reference)")
    }
    let document = design.appendingPathComponent(name)
    try checkDocument(document)
    return (selected, document)
}
func recordedRenderArguments() -> [String: [String]] {
    Dictionary(uniqueKeysWithValues: renderPaths.map { name, path in
        (path, ["<document>"] + renderArguments(name == "Default-26" ? "Default" : name,
                                             generation: name == "Default-26" ? "26" : nil, size: 1024))
    })
}
func export(_ document: URL) throws {
    let renderer = try ictool(), compiler = try actool(), minimum = try minimumSystemVersion()
    try render(document, "Default", to: repo.appendingPathComponent(renderPaths["Default"]!))
    try render(document, "Default", generation: "26", to: repo.appendingPathComponent(renderPaths["Default-26"]!))
    for rendition in renditions.dropFirst() {
        try render(document, rendition, to: repo.appendingPathComponent(renderPaths[rendition]!))
    }
    let scratch = try temporaryDirectory()
    defer { try? fm.removeItem(at: scratch) }
    try compile(document, into: scratch, minimum: minimum)
    let icns = repo.appendingPathComponent(icnsPath)
    if fm.fileExists(atPath: icns.path) { try fm.removeItem(at: icns) }
    try fm.copyItem(at: scratch.appendingPathComponent("AppIcon.icns"), to: icns)
    let image = try compiledIcon(scratch.appendingPathComponent("Assets.car"), in: scratch)
    guard let rep = image.representations.first(where: { $0.pixelsWide == 1024 }),
          let largest = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw Failure("Compiled Assets.car has no 1024 px AppIcon rendition")
    }
    try writePNG(largest, repo.appendingPathComponent(compiled1024Path))

    var outputs: [String: String] = [:]
    for path in Array(renderPaths.values) + [icnsPath, compiled1024Path] {
        outputs[path] = sha256(try Data(contentsOf: repo.appendingPathComponent(path)))
    }
    let receipt = Receipt(
        document: "Design/AppIcon/\(document.lastPathComponent)", sourceSHA256: try sourceSHA256(document),
        minimumSystemVersion: minimum,
        renderer: Tool(name: "ictool", version: renderer.version,
            arguments: ["<document>"] + renderArguments("<rendition>", generation: nil, size: 1024)),
        compiler: Tool(name: "actool", version: compiler.version, arguments: compileArguments(minimum)),
        outputs: outputs, rendererArguments: recordedRenderArguments())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (encoder.encode(receipt) + Data("\n".utf8)).write(to: receiptURL, options: .atomic)
    try verify(document)
}
@discardableResult
func verify(_ document: URL) throws -> Receipt {
    guard let data = try? Data(contentsOf: receiptURL) else { throw Failure("Missing receipt; run ./Scripts/make-icns.sh") }
    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
    try require(receipt.rendererArguments == recordedRenderArguments(), "Native rendition arguments differ from the receipt")
    try require(receipt.document == "Design/AppIcon/\(document.lastPathComponent)", "The receipt names another document")
    try require(receipt.sourceSHA256 == (try sourceSHA256(document)),
        "\(document.lastPathComponent) changed since the last export; run ./Scripts/make-icns.sh")
    try require(receipt.minimumSystemVersion == (try minimumSystemVersion()),
        "LSMinimumSystemVersion changed since the last export; run ./Scripts/make-icns.sh")
    try require(Set(receipt.outputs.keys) == Set(Array(renderPaths.values) + [icnsPath, compiled1024Path]),
        "The receipt does not list every native output")
    for (path, hash) in receipt.outputs {
        guard let data = try? Data(contentsOf: repo.appendingPathComponent(path)) else { throw Failure("Missing \(path)") }
        try require(sha256(data) == hash, "\(path) differs from the recorded native output; run ./Scripts/make-icns.sh")
    }
    let master = try pixels(repo.appendingPathComponent(renderPaths["Default"]!))
    try require(master.width == 1024 && master.height == 1024, "The native render must be 1024 px")
    try require(try alpha(master, [(0, 0), (512, 1), (512, 512)]) == [0, 255, 255],
        "The native render must be the edge-to-edge masked shape")
    let compiled = try pixels(repo.appendingPathComponent(compiled1024Path))
    try require(compiled.width == 1024 && compiled.height == 1024, "\(compiled1024Path) must be 1024 px")
    try require(try alpha(compiled, [(0, 0), (512, 30), (512, 512)]) == [0, 0, 255],
        "\(compiled1024Path) must keep the compiler's macOS grid margin")
    let icns = NSImage(contentsOf: repo.appendingPathComponent(icnsPath))
    try require(icns?.representations.contains { $0.pixelsWide == 16 } == true, "\(icnsPath) has no 16 px representation")
    print("Verified \(document.lastPathComponent) source hash and \(receipt.outputs.count) native outputs " +
        "(ictool \(receipt.renderer.version), actool \(receipt.compiler.version)).")
    return receipt
}
func compileForBundle(_ document: URL, into output: URL) throws {
    let receipt = try verify(document)
    try compile(document, into: output, minimum: receipt.minimumSystemVersion)
    let fresh = try Data(contentsOf: output.appendingPathComponent("AppIcon.icns"))
    let version = try actool().version
    if version == receipt.compiler.version {
        // actool's ICNS is byte-stable; its Assets.car embeds fresh rendition identifiers.
        try require(sha256(fresh) == receipt.outputs[icnsPath],
            "actool produced a different ICNS from the recorded export; run ./Scripts/make-icns.sh")
    } else {
        print("note: actool \(version) differs from the export's \(receipt.compiler.version); bundling its fresh output.")
    }
    print("Compiled \(document.lastPathComponent) into \(output.path): Assets.car, AppIcon.icns, AppIcon-Info.plist.")
}
func preview(_ document: URL) throws {
    try verify(document)
    let object = try JSONSerialization.jsonObject(with:
        Data(contentsOf: repo.appendingPathComponent("Design/FeatureIcons/manifest.json")))
    guard let featureManifest = object as? [String: Any],
          let features = featureManifest["features"] as? [[String: String]] else {
        throw Failure("Cannot read the feature family")
    }
    let scratch = try temporaryDirectory()
    defer { try? fm.removeItem(at: scratch) }
    let sizes = [16, 32, 64, 128]
    var nativeSmall: [Int: NSImage] = [:]
    for size in sizes {
        let url = scratch.appendingPathComponent("default-\(size).png")
        try render(document, "Default", size: size, to: url)
        nativeSmall[size] = NSImage(contentsOf: url)
    }
    guard let icns = NSImage(contentsOf: repo.appendingPathComponent(icnsPath)),
          let compiled = NSImage(contentsOf: repo.appendingPathComponent(compiled1024Path)) else {
        throw Failure("Cannot read the compiled outputs")
    }
    let variants = ["Default"] + ["Default-26"] + renditions.dropFirst()
    let width = max(1400, 275 + features.count * 132), height = 1240
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
    func draw(_ image: NSImage, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
        image.draw(in: NSRect(x: x, y: y, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    }
    for dark in [false, true] {
        let origin: CGFloat = dark ? 340 : 790
        (dark ? NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1) :
            NSColor(srgbRed: 0.965, green: 0.969, blue: 0.98, alpha: 1)).setFill()
        NSRect(x: 0, y: origin, width: CGFloat(width), height: 450).fill()
        text("Lineup.icon / ictool \(dark ? "dark" : "light") surface", 26, origin + 414, 20, dark)
        for (index, variant) in variants.enumerated() {
            guard let image = NSImage(contentsOf: repo.appendingPathComponent(renderPaths[variant]!)) else {
                throw Failure("Cannot preview \(variant)")
            }
            let x = CGFloat(26 + index * 190)
            draw(image, x, origin + 220, 170)
            text(variant, x, origin + 196, 13, dark)
        }
        text("ictool Default", 26, origin + 150, 13, dark)
        text("actool ICNS (macOS 13-25)", 640, origin + 150, 13, dark)
        var x: CGFloat = 26
        for size in sizes {
            draw(nativeSmall[size]!, x, origin + 16, CGFloat(size)); text("\(size)", x, origin + 2, 10, dark)
            x += CGFloat(size + 24)
        }
        x = 640
        for size in sizes {
            draw(icns, x, origin + 16, CGFloat(size)); text("\(size)", x, origin + 2, 10, dark)
            x += CGFloat(size + 24)
        }
    }
    NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: 340).fill()
    text("Lineup (compiled) + features / \(featureManifest["style"] as? String ?? "")", 26, 295, 20, false)
    draw(compiled, 30, 99, 176)
    text("Lineup", 92, 76, 16, false)
    for (index, feature) in features.enumerated() {
        guard let asset = feature["asset"], let name = feature["name"] else { throw Failure("Missing feature metadata") }
        let url = repo.appendingPathComponent(
            "Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets/\(asset).imageset/\(asset)@3x.png")
        guard let image = NSImage(contentsOf: url) else { throw Failure("Cannot preview \(asset)") }
        let x = CGFloat(245 + index * 132)
        draw(image, x, 132, 100)
        text(name, x + 5, 108, 12, false)
    }
    try writePNG(context.makeImage()!, design.appendingPathComponent("preview.png"))
    print("Saved Design/AppIcon/preview.png with native renditions, actual 16/32/64/128 px samples and the feature family.")
}

do {
    let manifest = try JSONDecoder().decode(Manifest.self, from:
        Data(contentsOf: design.appendingPathComponent("manifest.json")))
    let (_, document) = try selectedDocument(manifest)
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first ?? "export" {
    case "export": try export(document)
    case "verify": try verify(document)
    case "preview": try preview(document)
    case "compile" where arguments.count == 2:
        try compileForBundle(document, into: URL(fileURLWithPath: arguments[1]))
    default:
        throw Failure("Usage: swift Scripts/make-icon.swift [export|verify|preview|compile <output-directory>]")
    }
} catch {
    fputs("App icon: \(error)\n", stderr)
    exit(1)
}
