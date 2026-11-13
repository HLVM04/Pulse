// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Pulse", targets: ["Pulse"]),
    ],
    targets: [
        // Data sources and the quota pool math. No UI, so it is unit-testable.
        .target(name: "PulseCore"),
        // The menubar app.
        .executableTarget(name: "Pulse", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
    ]
)
