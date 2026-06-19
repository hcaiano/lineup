// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lineup",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-updates. Binary XCFramework target; embedded + re-signed by Scripts/build-app.sh.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Pure, testable layout + coordinate math. No AppKit-only state here so it
        // runs cleanly under `swift test`.
        .target(name: "LineupCore"),
        // Thin executable: AppKit agent, AX window writes, Carbon hotkeys.
        .executableTarget(
            name: "lineup",
            dependencies: [
                "LineupCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // The bundled app loads Sparkle.framework from Contents/Frameworks; SwiftPM only
            // adds an rpath into .build, so add the bundle-relative one for the shipped app.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Dependency-free test runner so the suite runs under Command Line Tools
        // (no full Xcode / XCTest needed). Run: `swift run lineup-tests`.
        .executableTarget(
            name: "lineup-tests",
            dependencies: ["LineupCore"]
        ),
    ]
)
