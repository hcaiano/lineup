import CryptoKit
import Foundation

func runFeatureIconContractTests() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("lineup-feature-icon-contract-\(UUID())")
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let master = directory.appendingPathComponent("zones.png")
    try fm.copyItem(at: URL(fileURLWithPath:
        "Sources/lineup/Resources/ToolIcons/FeatureIcons.xcassets/feature-zones.imageset/feature-zones@3x.png"),
                    to: master)
    let referenceSHA256 = SHA256.hash(data: try Data(contentsOf: master)).map { String(format: "%02x", $0) }.joined()

    func export(_ name: String, style: String, framing: String?) throws -> (status: Int32, error: String, catalog: URL) {
        var json: [String: Any] = [
            "size": 72, "style": style, "reference": "zones.png", "referenceSHA256": referenceSHA256,
            "features": [["id": "zones", "name": "Zones", "asset": "feature-zones", "color": "2F6BFF",
                          "subject": "Fixture", "master": "zones.png"]],
        ]
        json["framing"] = framing
        let manifest = directory.appendingPathComponent(name + ".json")
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        let catalog = directory.appendingPathComponent(name + ".xcassets")
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "Scripts/feature-icons.swift", "--manifest", manifest.path,
                             "--catalog", catalog.path, "export"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, error, catalog)
    }

    let edge = try export("edge", style: "restrained-v1", framing: "edge-to-edge")
    check(edge.status == 0 &&
          fm.fileExists(atPath: edge.catalog.appendingPathComponent("feature-zones.imageset/Contents.json").path),
          "restrained-v1 exports edge-to-edge art: \(edge.error)")

    for (name, framing) in [("missing", nil), ("reference", "reference")] as [(String, String?)] {
        let result = try export(name, style: "restrained-v1", framing: framing)
        check(result.status != 0 && result.error.contains("restrained-v1 requires edge-to-edge framing"),
              "restrained-v1 rejects \(name) framing: \(result.error)")
        check(!fm.fileExists(atPath: result.catalog.path), "restrained-v1 with \(name) framing writes no catalog")
    }

    let archived = try export("archived", style: "enamel-v1", framing: nil)
    check(archived.status != 0 && !archived.error.contains("restrained-v1") &&
          archived.error.contains("missing transparent surround"),
          "Archived styles keep their reference framing checks: \(archived.error)")
}
