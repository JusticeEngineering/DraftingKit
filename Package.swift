// swift-tools-version: 6.0
// DraftingKit — 3D triangle meshes → 2D hidden-line-removed vector drawings.

import PackageDescription

let package = Package(
    name: "DraftingKit",
    // Minimum deployment for Apple platforms. SwiftPM platform requirements are
    // package-wide; they do not restrict non-Apple platforms, so DraftingCore
    // still builds unconstrained on Linux (constraint C1).
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DraftingCore", targets: ["DraftingCore"]),
        .library(name: "DraftingModelIO", targets: ["DraftingModelIO"]),
        .library(name: "DraftingGraphics", targets: ["DraftingGraphics"]),
    ],
    targets: [
        // Pure core: Swift standard library ONLY (constraint C1 — no imports
        // beyond stdlib; verified by CI grep). On Linux the stdlib's own
        // math (squareRoot etc.) lowers to libm symbols, so the C math
        // library must be LINKED there — a toolchain dependency, not an API
        // one.
        .target(
            name: "DraftingCore",
            linkerSettings: [
                .linkedLibrary("m", .when(platforms: [.linux]))
            ]
        ),

        // Apple-only targets (implemented in M5; placeholders until then).
        .target(name: "DraftingModelIO", dependencies: ["DraftingCore"]),
        .target(name: "DraftingGraphics", dependencies: ["DraftingCore"]),

        // Manual test harness (macOS GUI; stub main elsewhere):
        //   swift run DraftingDemo
        .executableTarget(
            name: "DraftingDemo",
            dependencies: ["DraftingCore", "DraftingModelIO", "DraftingGraphics"]
        ),

        .testTarget(
            name: "DraftingCoreTests",
            dependencies: ["DraftingCore"],
            resources: [
                .copy("Resources"),
                .copy("Goldens"),
            ]
        ),
        .testTarget(
            name: "DraftingModelIOTests",
            dependencies: ["DraftingModelIO", "DraftingCore"],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "DraftingGraphicsTests",
            dependencies: ["DraftingGraphics", "DraftingCore"]
        ),
    ]
)
