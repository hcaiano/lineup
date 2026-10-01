import AppKit
import Foundation

let fm = FileManager.default
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let fixture = fm.temporaryDirectory.appendingPathComponent("lineup-icon-test-" + UUID().uuidString)
defer { try? fm.removeItem(at: fixture) }

do {
    let scripts = fixture.appendingPathComponent("Scripts")
    let design = fixture.appendingPathComponent("Design/FeatureIcons")
    try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
    try fm.createDirectory(at: design.appendingPathComponent("references"), withIntermediateDirectories: true)
    try fm.copyItem(at: repo.appendingPathComponent("Scripts/feature-icons.swift"),
                    to: scripts.appendingPathComponent("feature-icons.swift"))
    let source = repo.appendingPathComponent("Design/FeatureIcons")
    var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as! [String: Any]
    let reference = manifest["reference"] as! String
    try fm.copyItem(at: source.appendingPathComponent(reference), to: design.appendingPathComponent(reference))
    manifest["normalizeFraming"] = true
    var features: [[String: Any]] = []
    // Both vertical directions exercise real export translation and expose clipping from a Y-origin error.
    for (index, origin) in [CGPoint(x: 170, y: 50), CGPoint(x: 50, y: 170)].enumerated() {
        let context = CGContext(data: nil, width: 1000, height: 1000, bitsPerComponent: 8,
                                bytesPerRow: 4000, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(origin: origin, size: CGSize(width: 780, height: 780)))
        let master = "fixture\(index).png"
        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: design.appendingPathComponent(master))
        features.append(["id": "fixture\(index)", "name": "Fixture", "asset": "feature-fixture\(index)",
                         "color": "3366CC", "subject": "Off-center opaque tile", "master": master])
    }
    manifest["features"] = features
    try JSONSerialization.data(withJSONObject: manifest).write(to: design.appendingPathComponent("manifest.json"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", scripts.appendingPathComponent("feature-icons.swift").path, "export"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "Icon export failed", code: 1) }
    for index in 0...1 {
        let png = fixture.appendingPathComponent("Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets/feature-fixture\(index).imageset/feature-fixture\(index)@3x.png")
        let rep = NSBitmapImageRep(data: try Data(contentsOf: png))!
        var minX = 216, minY = 216, maxX = -1, maxY = -1
        for y in 0..<216 {
            for x in 0..<216 where rep.colorAt(x: x, y: y)!.alphaComponent >= 240.0 / 255 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard abs(minX - 24) <= 2, abs(minY - 24) <= 2,
              abs(maxX - 191) <= 2, abs(maxY - 191) <= 2 else {
            throw NSError(domain: "Exported tile was displaced or clipped", code: 2)
        }
    }
    print("Verified off-center feature exports in both directions.")
} catch {
    FileHandle.standardError.write(Data("Feature icon regression: \(error)\n".utf8))
    exit(1)
}
