// swift-tools-version:6.0
//
// Everything except the AppKit shell lives here, so the sampling layer can be
// built, tested and validated from the command line (`bttrace`) without the UI.
//
// Dependency direction (no cycles, no third-party packages):
//
//   BatteryTraceCore  <- PowerSources  (the only module that touches IOKit,
//                    <- Attribution      libproc or private symbols)
//                    <- Storage (+ Attribution's ledger)
//   Sampling = PowerSources + Attribution, driven by a timer policy
//   bttrace  = Sampling + Storage, headless
import PackageDescription

let package = Package(
    name: "BatteryTraceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BatteryTraceKit", targets: ["BatteryTraceCore", "PowerSources", "Attribution", "Sampling", "Storage"]),
        .executable(name: "bttrace", targets: ["bttrace"]),
    ],
    targets: [
        .target(name: "BatteryTraceCore"),
        .target(
            name: "PowerSources",
            dependencies: ["BatteryTraceCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .target(name: "Attribution", dependencies: ["BatteryTraceCore"]),
        .target(name: "Storage", dependencies: ["BatteryTraceCore", "Attribution"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Sampling", dependencies: ["BatteryTraceCore", "PowerSources", "Attribution"]),
        .executableTarget(
            name: "bttrace",
            dependencies: ["BatteryTraceCore", "PowerSources", "Attribution", "Sampling", "Storage"],
            linkerSettings: [.linkedFramework("Metal")]
        ),
        .testTarget(name: "AttributionTests", dependencies: ["Attribution", "BatteryTraceCore"]),
        .testTarget(name: "SamplingTests", dependencies: ["Sampling", "BatteryTraceCore"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "Attribution", "BatteryTraceCore"]),
        .testTarget(name: "PowerSourcesTests", dependencies: ["PowerSources", "BatteryTraceCore"]),
    ]
)
