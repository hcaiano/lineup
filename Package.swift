// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lineup",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, testable layout + coordinate math. No AppKit-only state here so it
        // runs cleanly under `swift test`.
        .target(name: "LineupCore"),
        // Thin executable: AppKit agent, AX window writes, Carbon hotkeys.
        .executableTarget(
            name: "lineup",
            dependencies: ["LineupCore"]
        ),
        // Dependency-free test runner so the suite runs under Command Line Tools
        // (no full Xcode / XCTest needed). Run: `swift run lineup-tests`.
        .executableTarget(
            name: "lineup-tests",
            dependencies: ["LineupCore"]
        ),
    ]
)
