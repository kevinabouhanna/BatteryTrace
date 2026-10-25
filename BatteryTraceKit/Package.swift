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
//   Updates: asks GitHub for the latest release (Foundation only)
//
//   HelperProtocol: what the app and its optional root helper say to each
//   other (PowerSources speaks it). HelperServer: the helper's side, linked
//   only into the helper binary, which the Xcode project builds.
import PackageDescription

let package = Package(
    name: "BatteryTraceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BatteryTraceKit", targets: ["BatteryTraceCore", "HelperProtocol", "PowerSources", "Attribution", "Sampling", "Storage", "Updates"]),
        .library(name: "BatteryTraceHelperKit", targets: ["HelperServer"]),
        .executable(name: "bttrace", targets: ["bttrace"]),
    ],
    targets: [
        .target(name: "BatteryTraceCore"),
        .target(name: "HelperProtocol"),
        .target(name: "HelperServer", dependencies: ["HelperProtocol"]),
        .target(
            name: "PowerSources",
            dependencies: ["BatteryTraceCore", "HelperProtocol"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .target(name: "Attribution", dependencies: ["BatteryTraceCore"]),
        .target(name: "Storage", dependencies: ["BatteryTraceCore", "Attribution"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Updates"),
        .target(name: "Sampling", dependencies: ["BatteryTraceCore", "PowerSources", "Attribution", "HelperProtocol"]),
        .executableTarget(
            name: "bttrace",
            dependencies: ["BatteryTraceCore", "HelperProtocol", "PowerSources", "Attribution", "Sampling", "Storage", "Updates"],
            linkerSettings: [.linkedFramework("Metal")]
        ),
        .testTarget(name: "AttributionTests", dependencies: ["Attribution", "BatteryTraceCore"]),
        .testTarget(name: "SamplingTests", dependencies: ["Sampling", "BatteryTraceCore", "HelperProtocol"]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", "Attribution", "BatteryTraceCore"]),
        .testTarget(name: "PowerSourcesTests", dependencies: ["PowerSources", "BatteryTraceCore"]),
        .testTarget(name: "UpdatesTests", dependencies: ["Updates"]),
        .testTarget(name: "HelperTests", dependencies: ["HelperProtocol", "HelperServer"]),
    ]
)
