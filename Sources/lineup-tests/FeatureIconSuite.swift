import Foundation

func runFeatureIconTests() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "Tests/feature_icon_framing.swift"]
    try process.run()
    process.waitUntilExit()
    check(process.terminationStatus == 0, "Off-center feature icon exports stay centered and unclipped")
}
