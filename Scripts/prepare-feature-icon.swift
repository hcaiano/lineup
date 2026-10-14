#!/usr/bin/env swift
import AppKit
import CryptoKit
import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
struct Preparation {
    let source: URL
    let directory: URL
    let name: String
    var document: URL { directory.appendingPathComponent(name + ".icon") }
    var image: URL { directory.appendingPathComponent(name + ".png") }
    var record: URL { directory.appendingPathComponent(name + ".json") }
    var nativeRender: URL { directory.appendingPathComponent(name + ".native-mask.png") }
}
let fm = FileManager.default

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

func run(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    try require(process.terminationReason == .exit && process.terminationStatus == 0,
                "\(executable.path) failed with status \(process.terminationStatus): \(output)")
    return output
}

func developerDirectory() throws -> URL {
    let path: String
    if let selected = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
        try require(!selected.isEmpty, "DEVELOPER_DIR is empty")
        path = selected
    } else {
        path = try run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"])
    }
    let selected = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    return selected.pathExtension == "app" ? selected.appendingPathComponent("Contents/Developer") : selected
}

func image(_ data: Data, _ label: String) throws -> CGImage {
    try require(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "\(label): expected a PNG")
    guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else {
        throw Failure("\(label): cannot decode PNG")
    }
    return image
}

func alpha(_ image: CGImage) throws -> [UInt8] {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue),
          let data = context.data else {
        throw Failure("Cannot inspect PNG alpha")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func pixels(_ image: CGImage, size: Int) throws -> [UInt8] {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                      CGBitmapInfo.byteOrder32Big.rawValue),
          let data = context.data else {
        throw Failure("Cannot create an sRGB bitmap")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: size * size * 4))
}

/// Icon Composer 27 bakes lighting and gloss into exported RGB even with glass, specular and
/// shadow disabled.
func composeMasked(source: CGImage, mask: CGImage, to url: URL) throws {
    let size = 1024
    try require(mask.width == size && mask.height == size, "Native render must be 1024 x 1024 px")
    var color = try pixels(source, size: size)
    let alpha = try pixels(mask, size: size)
    for index in 0..<size * size {
        let a = Int(alpha[index * 4 + 3])
        for channel in 0..<3 {
            color[index * 4 + channel] = UInt8((Int(color[index * 4 + channel]) * a + 127) / 255)
        }
        color[index * 4 + 3] = UInt8(a)
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(color) as CFData),
          let output = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: size * 4, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                  CGBitmapInfo.byteOrder32Big.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw Failure("Cannot encode the masked master")
    }
    CGImageDestinationAddImage(destination, output, nil)
    try require(CGImageDestinationFinalize(destination), "Cannot write \(url.path)")
    let written = try pixels(image(Data(contentsOf: url), url.path), size: size)
    try require((0..<size * size).allSatisfy { written[$0 * 4 + 3] == alpha[$0 * 4 + 3] },
                "Masked master alpha differs from the native render")
}

func verifyMaster(_ url: URL) throws {
    let output = try image(Data(contentsOf: url), url.path)
    try require(output.width == 1024 && output.height == 1024, "Native output must be 1024 x 1024 px")
    let values = try alpha(output)
    let size = output.width
    let corners = [0, size - 1, (size - 1) * size, size * size - 1]
    try require(corners.allSatisfy { values[$0] == 0 }, "Native output has no transparent corner cutouts")
    let edges = (size * 3 / 8..<size * 5 / 8).allSatisfy { offset in
        values[offset] == 255 && values[(size - 1) * size + offset] == 255 &&
        values[offset * size] == 255 && values[offset * size + size - 1] == 255
    }
    try require(edges, "Native output has outer padding; opaque tile sides must touch every canvas edge")
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try (data + Data("\n".utf8)).write(to: url, options: .atomic)
}

func prepare(_ job: Preparation) throws {
    let sourceData = try Data(contentsOf: job.source)
    let sourceImage = try image(sourceData, job.source.path)
    try require(sourceImage.width == sourceImage.height && sourceImage.width >= 216,
                "Source must be square and at least 216 px")
    try require(alpha(sourceImage).allSatisfy { $0 == 255 }, "Source must be fully opaque and unmasked")
    for target in [job.document, job.image, job.record, job.nativeRender] {
        try require(!fm.fileExists(atPath: target.path), "Output already exists: \(target.path)")
    }
    let developer = try developerDirectory()
    let tool = developer.deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
    try require(fm.isExecutableFile(atPath: tool.path),
                "Icon Composer ictool is missing from the selected developer directory: \(developer.path)")
    let version = try run(tool, ["--version"])
    let rendered = job.nativeRender
    let arguments = [job.document.path, "--export-image", "--output-file", rendered.path,
                     "--platform", "macOS", "--rendition", "Default", "--width", "1024",
                     "--height", "1024", "--scale", "1"]
    let document: [String: Any] = [
        "fill": ["solid": "extended-srgb:0.00000,0.00000,0.00000,1.00000"],
        "groups": [[
            "blend-mode": "normal", "hidden": false,
            "layers": [["fill": "automatic", "glass": false, "hidden": false,
                        "image-name": "source.svg", "name": job.name, "opacity": 1]],
            "lighting": "individual", "shadow": ["kind": "neutral", "opacity": 0],
            "specular": false, "translucency": ["enabled": false, "value": 0.5]
        ]],
        "supported-platforms": ["squares": ["macOS"]]
    ]
    let assets = job.document.appendingPathComponent("Assets")
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    try sourceData.write(to: assets.appendingPathComponent("source.png"), options: .atomic)
    let layer = """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
         width="1024" height="1024" viewBox="0 0 1024 1024">
      <image x="0.0" y="0.0" width="1024.0" height="1024.0" xlink:href="data:image/png;base64,\(sourceData.base64EncodedString())"/>
    </svg>
    """
    try Data(layer.utf8).write(to: assets.appendingPathComponent("source.svg"), options: .atomic)
    try writeJSON(document, to: job.document.appendingPathComponent("icon.json"))
    let diagnostics = try run(tool, arguments)
    try verifyMaster(rendered)
    let renderData = try Data(contentsOf: rendered)
    try composeMasked(source: sourceImage, mask: image(renderData, rendered.path), to: job.image)
    try verifyMaster(job.image)
    let receipt: [String: Any] = [
        "source": ["path": job.source.path, "sha256": sha256(sourceData),
                   "width": sourceImage.width, "height": sourceImage.height],
        "tool": ["path": tool.path, "version": version, "developer-directory": developer.path],
        "arguments": arguments, "settings": document, "diagnostics": diagnostics,
        "source-layout": ["kind": "full-frame SVG image", "width": 1024, "height": 1024],
        "document": job.document.path, "output": job.image.path,
        "output-sha256": try sha256(Data(contentsOf: job.image)),
        "mode": "native-alpha-mask",
        "native-render": ["path": rendered.path, "sha256": sha256(renderData), "use": "alpha only"],
        "composition": ["color": "source resampled to 1024 px in sRGB with high-quality interpolation",
                        "alpha": "native render alpha, unchanged", "pixel-format": "premultiplied RGBA",
                        "output-color-space": "sRGB"]
    ]
    try writeJSON(receipt, to: job.record)
    print("Prepared \(job.document.path)")
    print("Kept raw native render for its corner alpha: \(rendered.path)")
    print("Verified native 1024 x 1024 px alpha master with no outer padding: \(job.image.path)")
    print("Recorded source SHA-256, native tool version and settings: \(job.record.path)")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let usage = "Usage: swift Scripts/prepare-feature-icon.swift <source-png> <output-directory> <name>"
    if arguments == ["--help"] {
        print(usage)
        print("Default requires a fully opaque square source. Icon Composer renders <name>.native-mask.png; the master keeps the source color in sRGB and takes only that render's corner alpha.")
        exit(0)
    }
    try require(arguments.count == 3 && !arguments.contains(where: { $0.hasPrefix("--") }), usage)
    let name = arguments[2]
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    try require(!name.isEmpty && name.unicodeScalars.allSatisfy { allowed.contains($0) },
                "Name must contain only letters, digits, hyphens or underscores")
    try prepare(Preparation(source: URL(fileURLWithPath: arguments[0]).standardizedFileURL,
                            directory: URL(fileURLWithPath: arguments[1]).standardizedFileURL, name: name))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
