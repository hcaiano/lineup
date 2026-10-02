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
        // Pure, testable layout + coordinate math for the Zones tool (the zones.json schema-3
        // model). Was `LineupCore` in 1.x; renamed in 2.0 because Lineup hosts independent tools.
        // No AppKit-only state here so it runs cleanly under `swift run lineup-tests`.
        .target(name: "ZonesCore"),
        // Pure Hyper-key persisted settings (TriggerKey + HyperKeySettings). Split out of
        // CyclerCore so Cycler and Hyperkey are independent tools. No dependencies by design.
        .target(name: "HyperkeyCore"),
        .target(name: "WorldClockCore"),
        // Region geometry, recognition order and cancellation tokens for local text capture.
        .target(name: "TextCaptureCore"),
        .target(name: "DisplayControlCore"),
        .target(name: "DisplayHardware", linkerSettings: [
            .linkedFramework("IOKit"), .linkedFramework("CoreGraphics"),
            .linkedFramework("CoreFoundation"), .linkedFramework("ColorSync"),
        ]),
        // Pure cycle-order math + the legacy ~/.config/cycler/bindings.json model.
        // Depends on HyperkeyCore only to re-export TriggerKey/HyperKeySettings for that
        // legacy file shape (see Sources/CyclerCore/Bindings.swift).
        .target(name: "CyclerCore", dependencies: ["HyperkeyCore"]),
        // Product identity, tool identity, and the unified ~/.config/lineup/config.json
        // envelope + legacy import. Needs all three tool models to do the import.
        .target(name: "AppCore", dependencies: ["ZonesCore", "CyclerCore", "HyperkeyCore", "WorldClockCore"]),
        // Thin executable: AppKit agent shell + the tools. AX window writes,
        // Carbon hotkeys, CGEventTap.
        .executableTarget(
            name: "lineup",
            dependencies: [
                "AppCore",
                "ZonesCore",
                "CyclerCore",
                "HyperkeyCore",
                "WorldClockCore",
                "TextCaptureCore",
                "DisplayControlCore",
                "DisplayHardware",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Per-tool app icons for the Settings sidebar and pane headers. `.copy` (not
            // `.process`) so the folder shape inside lineup_lineup.bundle is predictable.
            // Scripts/build-app.sh must copy that bundle into Contents/Resources, where the
            // app's non-trapping tool-icon loader looks for it.
            resources: [.copy("Resources/ToolIcons"), .copy("Resources/WorldClock")],
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
            dependencies: ["AppCore", "ZonesCore", "CyclerCore", "HyperkeyCore", "WorldClockCore", "TextCaptureCore", "DisplayControlCore"]
        ),
    ]
)
