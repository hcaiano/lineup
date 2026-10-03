import Foundation

/// Opt-in native checks compile the real app owners; the default suite stays permission-free.
func runInputRecoveryTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineup-input-recovery-\(UUID().uuidString)", isDirectory: true)
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
    let (pathStatus, pathOutput) = try run(xcrun, ["swift", "build", "--show-bin-path"])
    guard pathStatus == 0, let path = pathOutput.split(separator: "\n").last else {
        check(false, "locate compiled core modules for native input checks: \(pathOutput)")
        return
    }
    let bin = URL(fileURLWithPath: String(path))
    let moduleNames = ["AppCore", "HyperkeyCore", "KeyboardRemapCore", "ZonesCore",
                       "CyclerCore", "WorldClockCore", "ScrollCore"]
    let modules = FileManager.default.fileExists(atPath: bin.appendingPathComponent("Modules").path)
        ? bin.appendingPathComponent("Modules") : bin
    let objects = try moduleNames.flatMap { name -> [String] in
        let merged = bin.appendingPathComponent("\(name).o")
        if FileManager.default.fileExists(atPath: merged.path) { return [merged.path] }
        return try FileManager.default.contentsOfDirectory(
            at: bin.appendingPathComponent("\(name).build"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "o" }.map(\.path).sorted()
    }
    let owners = [
        "Sources/lineup/Tools/Hyperkey/HyperKeyController.swift",
        "Sources/lineup/App/KeyboardMappingService.swift",
        "Sources/lineup/App/SingleInstance.swift",
        "Sources/lineup/Tools/Hyperkey/CapsLockHandoff.swift",
    ]
    for name in ["KeyboardMappingInventoryProbe", "HyperkeyRuntimeProbe"] {
        let executable = temporary.appendingPathComponent(name)
        let (compileStatus, compileOutput) = try run(xcrun,
            ["swiftc", "-I", modules.path] + owners + ["Scripts/Tests/\(name).swift"]
                + objects + ["-o", executable.path])
        guard compileStatus == 0 else {
            check(false, "compile \(name): \(compileOutput)")
            continue
        }
        let (status, output) = try run(executable, [])
        print(output, terminator: "")
        check(status == 0, "\(name) exercises production input recovery")
    }
}
