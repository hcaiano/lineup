import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

func runFeatureIconsTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-feature-icons-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try writeTile(inset: 0, to: directory.appendingPathComponent("edge.png"))
    try writeTile(inset: 28, to: directory.appendingPathComponent("padded.png"))
    try writeTile(inset: 28, edgeFragments: true, to: directory.appendingPathComponent("fragments.png"))
    let referenceSHA256 = SHA256.hash(data: try Data(contentsOf: directory.appendingPathComponent("edge.png")))
        .map { String(format: "%02x", $0) }.joined()

    func manifest(_ name: String, framing: String?, masters: [String], style: String = "fixture") throws -> URL {
        let features = masters.enumerated().map { index, master in
            ["id": "tool\(index)", "name": "Tool \(index)", "asset": "feature-tool\(index)",
             "color": "2F6BFF", "subject": "Fixture", "master": master]
        }
        var json: [String: Any] = ["size": 72, "reference": "edge.png", "referenceSHA256": referenceSHA256,
                                   "style": style, "features": features]
        json["framing"] = framing
        let url = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }
    func export(_ manifest: URL, _ catalog: URL, operation: String = "export") throws -> (status: Int32, error: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "Scripts/feature-icons.swift", "--manifest", manifest.path,
                             "--catalog", catalog.path, operation]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, error)
    }

    let edgeCatalog = directory.appendingPathComponent("edge.xcassets")
    let edge = try export(manifest("edge.json", framing: "edge-to-edge", masters: ["edge.png"]), edgeCatalog)
    check(edge.status == 0, "Edge-to-edge export accepts transparent rounded corners: \(edge.error)")
    for (name, size) in [("feature-tool0.png", 72), ("feature-tool0@2x.png", 144), ("feature-tool0@3x.png", 216)] {
        let url = edgeCatalog.appendingPathComponent("feature-tool0.imageset/" + name)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(image?.width == size && image?.height == size,
              "Edge-to-edge export writes a real \(size)-pixel PNG for \(name)")
    }

    let paddedCatalog = directory.appendingPathComponent("padded.xcassets")
    let padded = try export(manifest("padded.json", framing: "edge-to-edge", masters: ["edge.png", "padded.png"]),
                            paddedCatalog)
    check(padded.status != 0 && padded.error.contains("tool1: visible tile must reach all four canvas edges"),
          "Edge-to-edge export rejects a padded master: \(padded.error)")
    check(!FileManager.default.fileExists(atPath: paddedCatalog.path),
          "A rejected master blocks every catalog write")

    let fragmentsCatalog = directory.appendingPathComponent("fragments.xcassets")
    let fragments = try export(manifest("fragments.json", framing: "edge-to-edge", masters: ["fragments.png"]),
                               fragmentsCatalog)
    check(fragments.status != 0 && fragments.error.contains("visible tile must continuously reach"),
          "Detached edge pixels do not disguise a padded tile: \(fragments.error)")
    check(!FileManager.default.fileExists(atPath: fragmentsCatalog.path),
          "Detached fragments block catalog writes")

    for (name, framing) in [("missing", nil), ("reference", "reference")] as [(String, String?)] {
        let catalog = directory.appendingPathComponent(name + ".xcassets")
        let result = try export(manifest(name + ".json", framing: framing, masters: ["edge.png"], style: "restrained-v1"), catalog)
        check(result.status != 0 && result.error.contains("restrained-v1 requires edge-to-edge framing"),
              "restrained-v1 rejects \(name) framing: \(result.error)")
        check(!FileManager.default.fileExists(atPath: catalog.path),
              "restrained-v1 with \(name) framing writes no catalog")
    }
    let archivedCatalog = directory.appendingPathComponent("archived.xcassets")
    let archived = try export(manifest("archived.json", framing: nil, masters: ["edge.png"], style: "enamel-v1"),
                              archivedCatalog)
    check(archived.status != 0 && !archived.error.contains("restrained-v1") &&
          archived.error.contains("missing transparent surround"),
          "Archived styles keep their reference framing checks: \(archived.error)")

    let shippedCatalog = Process()
    let shippedError = Pipe()
    shippedCatalog.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    shippedCatalog.arguments = ["swift", "Scripts/feature-icons.swift", "verify"]
    shippedCatalog.standardOutput = FileHandle.nullDevice
    shippedCatalog.standardError = shippedError
    try shippedCatalog.run()
    let shippedMessage = String(decoding: shippedError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    shippedCatalog.waitUntilExit()
    check(shippedCatalog.terminationStatus == 0,
          "Shipped feature PNGs and preparation provenance match their selected sources: \(shippedMessage)")

    let fixtureManifest = try manifest("pixels.json", framing: "edge-to-edge", masters: ["edge.png"])
    try writeTile(inset: 0, size: 72, color: [1, 0.2, 0.1],
                  to: edgeCatalog.appendingPathComponent("feature-tool0.imageset/feature-tool0.png"))
    let changedPixels = try export(fixtureManifest, edgeCatalog, operation: "verify")
    check(changedPixels.status != 0 && changedPixels.error.contains("pixels differ from the selected master"),
          "Catalog verification rejects altered RGB with valid framing: \(changedPixels.error)")
    _ = try export(fixtureManifest, edgeCatalog)

    var provenanceManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureManifest)) as! [String: Any]
    var feature = (provenanceManifest["features"] as! [[String: Any]])[0]
    feature["sourceMaster"] = "edge.png"
    feature["preparationReceipt"] = "receipt.json"
    provenanceManifest["features"] = [feature]
    try JSONSerialization.data(withJSONObject: provenanceManifest).write(to: fixtureManifest)
    for label in ["source", "master", "native mask"] {
        let receipt: [String: Any] = [
            "mode": "native-alpha-mask",
            "source": ["sha256": label == "source" ? "stale" : referenceSHA256],
            "output-sha256": label == "master" ? "stale" : referenceSHA256,
            "native-render": ["path": "edge.png", "sha256": label == "native mask" ? "stale" : referenceSHA256],
        ]
        try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent("receipt.json"))
        let result = try export(fixtureManifest, edgeCatalog, operation: "verify")
        check(result.status != 0 && result.error.contains("\(label) differs from its preparation receipt"),
              "Catalog verification rejects a stale \(label) receipt: \(result.error)")
    }

    provenanceManifest["paletteReferences"] = [["path": "edge.png", "sha256": "stale"]]
    try JSONSerialization.data(withJSONObject: provenanceManifest).write(to: fixtureManifest)
    let changedPalette = try export(fixtureManifest, edgeCatalog, operation: "verify")
    check(changedPalette.status != 0 && changedPalette.error.contains("Palette reference differs from its recorded hash"),
          "Catalog verification rejects a changed approved palette reference: \(changedPalette.error)")

    let appIcon = Process()
    let appIconError = Pipe()
    appIcon.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    appIcon.arguments = ["swift", "Scripts/make-icon.swift", "verify"]
    appIcon.standardOutput = FileHandle.nullDevice
    appIcon.standardError = appIconError
    try appIcon.run()
    let appIconMessage = String(decoding: appIconError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    appIcon.waitUntilExit()
    check(appIcon.terminationStatus == 0, "App icon exports match Design/AppIcon/Lineup.icon: \(appIconMessage)")

    try runNativePreparationTests(in: directory)
}

private func runNativePreparationTests(in directory: URL) throws {
    let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? "/Applications/Xcode.app/Contents/Developer"
    let ictool = URL(fileURLWithPath: developer).deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
    guard FileManager.default.isExecutableFile(atPath: ictool.path) else {
        print("FeatureIconsSuite: Icon Composer ictool unavailable; skipped native preparation checks")
        return
    }
    let color: [Int] = [20, 70, 130]
    let source = directory.appendingPathComponent("uniform.png")
    try writeUniform(color, to: source)
    func prepare(_ output: URL) throws -> (status: Int32, error: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "Scripts/prepare-feature-icon.swift", source.path, output.path, "uniform"]
        process.environment = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": developer]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, error)
    }

    let blocked = directory.appendingPathComponent("blocked")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    try Data().write(to: blocked.appendingPathComponent("uniform.native-mask.png"))
    let refused = try prepare(blocked)
    check(refused.status != 0 && refused.error.contains("Output already exists") &&
          !FileManager.default.fileExists(atPath: blocked.appendingPathComponent("uniform.icon").path),
          "Native preparation refuses an existing raw render before writing: \(refused.error)")

    let output = directory.appendingPathComponent("prepared")
    let prepared = try prepare(output)
    check(prepared.status == 0, "Native preparation succeeds with Icon Composer: \(prepared.error)")
    guard prepared.status == 0 else { return }
    let master = output.appendingPathComponent("uniform.png")
    let raw = output.appendingPathComponent("uniform.native-mask.png")
    check(try Data(contentsOf: output.appendingPathComponent("uniform.icon/Assets/source.png")) ==
          Data(contentsOf: source), "The native document embeds the original source bytes")

    let size = 1024
    guard let final = rgba(master), final.width == size, final.height == size else {
        check(false, "Native preparation writes a decodable 1024 px master")
        return
    }
    let mask = rgba(raw)
    check(mask?.width == size && mask?.height == size && (0..<size * size).allSatisfy {
        final.pixels[$0 * 4 + 3] == mask?.pixels[$0 * 4 + 3]
    }, "Prepared master keeps the raw native render's alpha unchanged")
    check([0, size - 1, (size - 1) * size, size * size - 1].allSatisfy { final.pixels[$0 * 4 + 3] == 0 },
          "Prepared master keeps transparent native corners")

    func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(final.pixels[(y * size + x) * 4 + $0]) } }
    var edgePixels: [(String, [Int])] = []
    for depth in [0, 1, 2, 4, 8, 32] {
        for offset in stride(from: size * 3 / 8, to: size * 5 / 8, by: 16) {
            edgePixels += [("top", pixel(offset, depth)), ("bottom", pixel(offset, size - 1 - depth)),
                           ("left", pixel(depth, offset)), ("right", pixel(size - 1 - depth, offset))]
        }
    }
    let wrongEdges = edgePixels.filter { _, p in p[3] != 255 || zip(p, color).contains { abs($0 - $1) > 2 } }
    check(wrongEdges.isEmpty, "Opaque tile sides keep source RGB \(color); got \(wrongEdges.prefix(4))")

    var worst = 0, worstIndex = 0, opaque = 0
    for index in 0..<size * size {
        let a = Int(final.pixels[index * 4 + 3])
        if a == 255 { opaque += 1 }
        for channel in 0..<3 {
            let deviation = abs(Int(final.pixels[index * 4 + channel]) - (color[channel] * a + 127) / 255)
            if deviation > worst { worst = deviation; worstIndex = index }
        }
    }
    check(worst <= 2, "Prepared master is source color times native alpha; worst deviation \(worst) at " +
          "(\(worstIndex % size), \(worstIndex / size)) = \(pixel(worstIndex % size, worstIndex / size))")
    check(opaque > size * size * 9 / 10, "The opaque tile covers the full canvas body (\(opaque) px)")

    let receipt = try JSONSerialization.jsonObject(
        with: Data(contentsOf: output.appendingPathComponent("uniform.json"))) as? [String: Any]
    let render = receipt?["native-render"] as? [String: Any]
    let hashes = try [master, raw, source].map { FileManager.default.fileExists(atPath: $0.path) ?
        sha256(try Data(contentsOf: $0)) : "missing" }
    check(receipt?["mode"] as? String == "native-alpha-mask" &&
          receipt?["output-sha256"] as? String == hashes[0] && render?["sha256"] as? String == hashes[1] &&
          (receipt?["source"] as? [String: Any])?["sha256"] as? String == hashes[2],
          "Preparation receipt labels mask-only mode and hashes the source, raw render and master")
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func rgba(_ url: URL) -> (width: Int, height: Int, pixels: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue),
          let data = context.data else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    return (image.width, image.height, Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4)))
}

private func writeUniform(_ color: [Int], to url: URL) throws {
    let size = 256
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.setFillColor(red: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                         blue: CGFloat(color[2]) / 255, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private func writeTile(inset: CGFloat, edgeFragments: Bool = false, size: Int = 256,
                       color: [CGFloat] = [0.18, 0.42, 1], to url: URL) throws {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let tile = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
    let radius = tile.width * 0.22
    context.setFillColor(red: color[0], green: color[1], blue: color[2], alpha: 1)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
    if edgeFragments {
        for point in [CGPoint(x: 0, y: 128), CGPoint(x: 255, y: 128),
                      CGPoint(x: 128, y: 0), CGPoint(x: 128, y: 255)] {
            context.fill(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
        }
    }
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
