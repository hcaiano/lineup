import Foundation

func runNightlyAutomationTests() throws {
    // Exercise the real publisher with isolated files and fake external services.
    // Python is already required by the release scripts; no packages are installed.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "-B", "Tests/nightly_automation_test.py"]
    try process.run()
    process.waitUntilExit()
    check(process.terminationStatus == 0, "Nightly publication policy and crash recovery")
}
