import Foundation

func runAppReopenTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineup-app-reopen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    // Use the packaging build system so the probe shares its object layout and SDK selection.
    let build = ["swift", "build", "--build-system", "native"]
    let (buildStatus, buildOutput) = try run(xcrun, build + ["--product", "lineup"])
    guard buildStatus == 0 else {
        check(false, "build the app for reopen checks: \(buildOutput)")
        return
    }
    let (pathStatus, pathOutput) = try run(xcrun, build + ["--show-bin-path"])
    guard pathStatus == 0, let path = pathOutput.split(separator: "\n").last else {
        check(false, "locate the app build for reopen checks: \(pathOutput)")
        return
    }
    let bin = URL(fileURLWithPath: String(path))
    let linkFile = bin.appendingPathComponent("lineup.product/Objects.LinkFileList")
    // Keep the production owners, excluding only the entry point that starts live services.
    let appMain = bin.appendingPathComponent("lineup.build/main.swift.o").path
    let objects = try String(contentsOf: linkFile, encoding: .utf8)
        .split(separator: "\n").map(String.init).filter { $0 != appMain }
    let executable = temporary.appendingPathComponent("AppReopenProbe")
    let (compileStatus, compileOutput) = try run(xcrun, [
        "swiftc", "-parse-as-library", "-I", bin.appendingPathComponent("Modules").path,
        "-F", bin.path, "-Xcc",
        "-fmodule-map-file=\(bin.appendingPathComponent("DisplayHardware.build/module.modulemap").path)",
        "Scripts/Tests/AppReopenProbe.swift",
    ] + objects + [
        "-framework", "Sparkle", "-framework", "IOKit", "-framework", "CoreGraphics",
        "-framework", "CoreFoundation", "-framework", "ColorSync",
        "-Xlinker", "-rpath", "-Xlinker", bin.path, "-o", executable.path,
    ])
    guard compileStatus == 0 else {
        check(false, "compile the app reopen probe: \(compileOutput)")
        return
    }
    let (status, output) = try run(executable, [])
    print(output, terminator: "")
    check(status == 0, "explicit app reopen opens and restores Settings")
}
