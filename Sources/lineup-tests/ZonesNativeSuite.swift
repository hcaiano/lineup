import Foundation

struct ZonesNativeReceipt: Codable {
    let version: Int
    let invocation: String
    let mode: String
    let endpoint: String
    let passed: Int
    let failed: Int
    let cleanup: Bool
    let completed: [String]
    let gates: [String: String]
    let activationPolicyBefore: String?
    let activationPolicyAccepted: Bool?
    let activationPolicy: String?
    let applicationRunning: Bool?

    static func accepts(_ data: Data?, invocation: String, mode: String) -> Bool {
        guard let data, let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.version == 1, receipt.invocation == invocation, receipt.mode == mode,
              receipt.passed > 0, receipt.failed == 0, receipt.cleanup,
              Set(receipt.completed).count == receipt.completed.count,
              receipt.gates.values.allSatisfy({ !$0.isEmpty }), receipt.gates["firstMouseDelivery"] != nil,
              receipt.endpoint == (receipt.gates.isEmpty ? "completed" : "gated") else { return false }
        let completed = Set(receipt.completed)
        let onScreen = ["views", "controlledCapture", "axOwners", "nativeCapture"]
        guard completed.isDisjoint(with: Set(receipt.gates.keys)),
              completed.contains(["passive": "passiveViews", "offscreen": "offscreenViews"][mode] ?? "views"),
              Set(onScreen).isSubset(of: completed.union(receipt.gates.keys)) else { return false }
        switch mode {
        case "permission-free": return receipt.gates["axOwners"] != nil && receipt.gates["nativeCapture"] != nil
        case "passive":
            return receipt.gates["views"] != nil && receipt.gates["axOwners"] != nil && receipt.gates["nativeCapture"] != nil
        case "offscreen":
            guard let accepted = receipt.activationPolicyAccepted, let before = receipt.activationPolicyBefore else { return false }
            return onScreen.allSatisfy { receipt.gates[$0] != nil } && (accepted || before == "prohibited")
                && receipt.activationPolicy == "prohibited" && receipt.applicationRunning == false
        default: return mode == "granted"
        }
    }
}

func runZonesNativeReceiptTests() throws {
    let valid = """
    {"version":1,"invocation":"this-run","mode":"granted","endpoint":"gated","passed":12,"failed":0,"cleanup":true,
     "completed":["views","controlledCapture","axOwners","nativeCapture"],"gates":{"firstMouseDelivery":"physical pointer"}}
    """
    check(ZonesNativeReceipt.accepts(Data(valid.utf8), invocation: "this-run", mode: "granted"),
          "native suite accepts a receipt with every group completed for this invocation and permission mode")
    let invalid: [Data?] = [nil, Data("{}".utf8), Data("broken".utf8),
        Data(valid.replacingOccurrences(of: "this-run", with: "old-run").utf8),
        Data(valid.replacingOccurrences(of: "granted", with: "permission-free").utf8),
        Data(valid.replacingOccurrences(of: ",\"nativeCapture\"", with: "").utf8),
        Data(valid.replacingOccurrences(of: "\"failed\":0", with: "\"failed\":1").utf8),
        Data(valid.replacingOccurrences(of: "\"cleanup\":true", with: "\"cleanup\":false").utf8),
        Data(valid.replacingOccurrences(of: "\"endpoint\":\"gated\"", with: "\"endpoint\":\"completed\"").utf8)]
    for (index, data) in invalid.enumerated() {
        check(!ZonesNativeReceipt.accepts(data, invocation: "this-run", mode: "granted"),
              "native suite rejects missing, malformed, stale, wrong-mode or incomplete receipt case \(index)")
    }
    let gated = """
    {"version":1,"invocation":"this-run","mode":"permission-free","endpoint":"gated","passed":12,"failed":0,"cleanup":true,
     "completed":["views"],"gates":{"controlledCapture":"fixture filter unavailable","axOwners":"separate granted run","nativeCapture":"separate granted run","firstMouseDelivery":"physical pointer"}}
    """
    check(ZonesNativeReceipt.accepts(Data(gated.utf8), invocation: "this-run", mode: "permission-free"),
          "permission-free receipt names both granted gates at its intended endpoint")
    check(!ZonesNativeReceipt.accepts(Data(gated.utf8), invocation: "this-run", mode: "granted"),
          "permission-free evidence cannot satisfy a granted invocation")
    let passive = """
    {"version":1,"invocation":"this-run","mode":"passive","endpoint":"gated","passed":12,"failed":0,"cleanup":true,
     "completed":["passiveViews"],"gates":{"views":"key-taking cases skipped","controlledCapture":"fixture filter unavailable","axOwners":"separate granted run","nativeCapture":"separate granted run","firstMouseDelivery":"physical pointer"}}
    """
    check(ZonesNativeReceipt.accepts(Data(passive.utf8), invocation: "this-run", mode: "passive"),
          "a passive receipt gates the full views group and both granted groups")
    check(!ZonesNativeReceipt.accepts(Data(passive.utf8), invocation: "this-run", mode: "permission-free")
            && !ZonesNativeReceipt.accepts(Data(passive.replacingOccurrences(of: "\"mode\":\"passive\"", with: "\"mode\":\"permission-free\"").utf8),
                                           invocation: "this-run", mode: "permission-free")
            && !ZonesNativeReceipt.accepts(Data(gated.replacingOccurrences(of: "permission-free", with: "passive").utf8),
                                           invocation: "this-run", mode: "passive")
            && !ZonesNativeReceipt.accepts(Data(passive.replacingOccurrences(of: "\"views\":\"key-taking cases skipped\",", with: "").utf8),
                                           invocation: "this-run", mode: "passive"),
          "passive and full views evidence never stand in for each other")
    let offscreen = """
    {"version":1,"invocation":"this-run","mode":"offscreen","endpoint":"gated","passed":12,"failed":0,"cleanup":true,
     "completed":["offscreenViews"],"gates":{"views":"no window ordered","controlledCapture":"no capture","axOwners":"no AX","nativeCapture":"no capture","material":"compositor","firstMouseDelivery":"physical pointer"},
     "activationPolicyBefore":"prohibited","activationPolicyAccepted":false,"activationPolicy":"prohibited","applicationRunning":false}
    """
    check(ZonesNativeReceipt.accepts(Data(offscreen.utf8), invocation: "this-run", mode: "offscreen"),
          "an offscreen receipt completes only offscreen drawing and gates every on-screen group")
    check(["granted", "permission-free", "passive"].allSatisfy { mode in
              !ZonesNativeReceipt.accepts(Data(offscreen.replacingOccurrences(of: "\"mode\":\"offscreen\"", with: "\"mode\":\"\(mode)\"").utf8),
                                          invocation: "this-run", mode: mode)
                  && !ZonesNativeReceipt.accepts(Data(offscreen.utf8), invocation: "this-run", mode: mode) },
          "offscreen drawing never stands in for a granted, permission-free or passive invocation")
    check(!ZonesNativeReceipt.accepts(Data(offscreen.replacingOccurrences(of: "\"views\":\"no window ordered\",", with: "").utf8),
                                      invocation: "this-run", mode: "offscreen")
            && !ZonesNativeReceipt.accepts(Data(passive.replacingOccurrences(of: "\"mode\":\"passive\"", with: "\"mode\":\"offscreen\"").utf8),
                                           invocation: "this-run", mode: "offscreen"),
          "an offscreen receipt must gate the full views group and cannot be a relabelled passive run")
    let requested = offscreen.replacingOccurrences(of: "\"activationPolicyBefore\":\"prohibited\",\"activationPolicyAccepted\":false",
                                                   with: "\"activationPolicyBefore\":\"accessory\",\"activationPolicyAccepted\":true")
    check(requested != offscreen && ZonesNativeReceipt.accepts(Data(requested.utf8), invocation: "this-run", mode: "offscreen"),
          "an offscreen receipt may reach .prohibited through an accepted request")
    let unobserved = [
        offscreen.replacingOccurrences(of: "\"activationPolicyBefore\":\"prohibited\",\"activationPolicyAccepted\":false,\"activationPolicy\":\"prohibited\",\"applicationRunning\":false",
                                       with: "\"activationPolicySet\":true"),
        offscreen.replacingOccurrences(of: "\"activationPolicyBefore\":\"prohibited\",", with: ""),
        offscreen.replacingOccurrences(of: "\"activationPolicyAccepted\":false,", with: ""),
        offscreen.replacingOccurrences(of: "\"activationPolicyBefore\":\"prohibited\"", with: "\"activationPolicyBefore\":\"accessory\""),
        offscreen.replacingOccurrences(of: "\"activationPolicy\":\"prohibited\"", with: "\"activationPolicy\":\"accessory\""),
        offscreen.replacingOccurrences(of: "\"activationPolicy\":\"prohibited\"", with: "\"activationPolicy\":\"prohibited then regular\""),
        offscreen.replacingOccurrences(of: ",\"applicationRunning\":false", with: ""),
        offscreen.replacingOccurrences(of: "\"applicationRunning\":false", with: "\"applicationRunning\":true"),
    ]
    for (index, receipt) in unobserved.enumerated() {
        check(receipt != offscreen && !ZonesNativeReceipt.accepts(Data(receipt.utf8), invocation: "this-run", mode: "offscreen"),
              "an offscreen receipt needs the observed .prohibited policy and no running application, case \(index)")
    }
    check(!ZonesNativeReceipt.accepts(Data(passive.replacingOccurrences(of: "\"mode\":\"passive\"", with: "\"mode\":\"offscreen\"")
              .replacingOccurrences(of: "\"completed\":[\"passiveViews\"]", with: "\"completed\":[\"offscreenViews\"]").utf8),
                                      invocation: "this-run", mode: "offscreen"),
          "a passive receipt relabelled as offscreen lacks the offscreen observations")
    let firstMouse = [
        ("granted", valid.replacingOccurrences(of: "\"firstMouseDelivery\":\"physical pointer\"", with: "")
            .replacingOccurrences(of: "\"endpoint\":\"gated\"", with: "\"endpoint\":\"completed\"")),
        ("granted", valid.replacingOccurrences(of: "\"firstMouseDelivery\":\"physical pointer\"", with: "")
            .replacingOccurrences(of: "\"endpoint\":\"gated\"", with: "\"endpoint\":\"completed\"")
            .replacingOccurrences(of: "\"nativeCapture\"]", with: "\"nativeCapture\",\"firstMouseDelivery\"]")),
        ("permission-free", gated.replacingOccurrences(of: ",\"firstMouseDelivery\":\"physical pointer\"", with: "")),
        ("passive", passive.replacingOccurrences(of: ",\"firstMouseDelivery\":\"physical pointer\"", with: "")),
        ("offscreen", offscreen.replacingOccurrences(of: ",\"firstMouseDelivery\":\"physical pointer\"", with: "")),
    ]
    for (index, (mode, receipt)) in firstMouse.enumerated() {
        check(!ZonesNativeReceipt.accepts(Data(receipt.utf8), invocation: "this-run", mode: mode),
              "constructed clicks never close physical first-mouse delivery: a \(mode) receipt must gate it, case \(index)")
    }
}

func runZonesNativeTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("lineup-zones-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = root
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    let build = ["swift", "build", "--build-system", "native"]
    let (buildStatus, buildOutput) = try run(xcrun, build + ["--product", "lineup"])
    guard buildStatus == 0 else { check(false, "build production Zones probe owners: \(buildOutput)"); return }
    let (pathStatus, pathOutput) = try run(xcrun, build + ["--show-bin-path"])
    guard pathStatus == 0, let path = pathOutput.split(separator: "\n").last else {
        check(false, "locate production Zones probe objects: \(pathOutput)"); return
    }
    let bin = URL(fileURLWithPath: String(path))
    let objects = try String(contentsOf: bin.appendingPathComponent("lineup.product/Objects.LinkFileList"), encoding: .utf8)
        .split(separator: "\n").map(String.init).filter { $0 != bin.appendingPathComponent("lineup.build/main.swift.o").path }
    let executable = temporary.appendingPathComponent("ZonesNativeProbe")
    let (compileStatus, compileOutput) = try run(xcrun, [
        "swiftc", "-parse-as-library", "-I", bin.appendingPathComponent("Modules").path, "-F", bin.path,
        "-Xcc", "-fmodule-map-file=\(bin.appendingPathComponent("DisplayHardware.build/module.modulemap").path)",
        "Scripts/Tests/ZonesNativeProbe.swift",
    ] + objects + [
        "-framework", "Sparkle", "-framework", "IOKit", "-framework", "CoreGraphics",
        "-framework", "CoreFoundation", "-framework", "ColorSync",
        "-Xlinker", "-rpath", "-Xlinker", bin.path, "-o", executable.path,
    ])
    guard compileStatus == 0 else { check(false, "compile Zones production-owner probe: \(compileOutput)"); return }
    let offscreen = CommandLine.arguments.contains("--offscreen")
    let passive = !offscreen && CommandLine.arguments.contains("--passive")
    let permissionFree = passive || (!offscreen && CommandLine.arguments.contains("--permission-free"))
    let mode = offscreen ? "offscreen" : passive ? "passive" : permissionFree ? "permission-free" : "granted"
    let invocation = UUID().uuidString
    let receipt = temporary.appendingPathComponent("terminal-receipt.json")
    let arguments = (offscreen ? ["--offscreen"] : []) + (permissionFree ? ["--permission-free"] : []) + (passive ? ["--passive"] : [])
        + ["--invocation", invocation, "--receipt", receipt.path]
    let (status, output) = try run(executable, arguments)
    print(output, terminator: "")
    print("Zones probe exit status \(status), invocation \(invocation), mode \(mode)")
    let data = try? Data(contentsOf: receipt)
    if let directory = ProcessInfo.processInfo.environment["LINEUP_ZONES_CAPTURE_DIR"], let data {
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("terminal-receipt.json"), options: .atomic)
    }
    check(status == 0 && ZonesNativeReceipt.accepts(data, invocation: invocation, mode: mode),
          "Zones production owners require exit 0 and this invocation's completed or gated terminal receipt")
}
