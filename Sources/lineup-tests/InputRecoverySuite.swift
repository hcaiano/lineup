import Foundation

func runInputRecoveryTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineup-input-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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
    let permissionFree = CommandLine.arguments.contains("--permission-free")
    let names = permissionFree ? ["HyperkeySecureInputProbe", "HyperkeyBlockedWarningProbe", "HyperkeyBlockedAttemptProbe"]
        : ["HyperkeySecureInputProbe", "HyperkeyBlockedWarningProbe", "HyperkeyBlockedAttemptProbe", "KeyboardMappingInventoryProbe", "HyperkeyRuntimeProbe"]
    for name in names {
        let probeOwners: [String]
        switch name {
        case "HyperkeySecureInputProbe": probeOwners = [owners[0]]
        case "HyperkeyBlockedWarningProbe":
            probeOwners = ["Sources/lineup/Tools/Hyperkey/HyperKeyBlockedPill.swift",
                           "Sources/lineup/Tools/Hyperkey/SecureInputDiagnostics.swift",
                           "Sources/lineup/App/HUDMotion.swift"]
        case "HyperkeyBlockedAttemptProbe":
            probeOwners = ["Sources/lineup/Tools/Hyperkey/HyperkeyTool.swift",
                           "Sources/lineup/Tools/Hyperkey/HyperkeyBlockedAttemptObserver.swift",
                           "Sources/lineup/Tools/Hyperkey/HyperKeyBlockedPill.swift",
                           "Sources/lineup/App/HotkeyManager.swift",
                           "Sources/lineup/App/ShortcutKit.swift",
                           "Sources/lineup/App/Tool.swift",
                           "Sources/lineup/App/HUDMotion.swift"]
        default: probeOwners = owners
        }
        let executable = temporary.appendingPathComponent(name)
        let (compileStatus, compileOutput) = try run(xcrun,
            ["swiftc", "-I", modules.path] + probeOwners + ["Scripts/Tests/\(name).swift"]
                + objects + ["-o", executable.path])
        guard compileStatus == 0 else {
            check(false, "compile \(name): \(compileOutput)")
            continue
        }
        let appearances = name == "HyperkeyBlockedWarningProbe" ? ["light", "dark"] : [""]
        for appearance in appearances {
            let environment = appearance.isEmpty ? [:] : ["LINEUP_WARNING_APPEARANCE": appearance]
            let (status, output) = try run(executable, [], environment: environment)
            print(output, terminator: "")
            check(status == 0, "\(name) exercises production input recovery \(appearance)")
        }
    }
}
