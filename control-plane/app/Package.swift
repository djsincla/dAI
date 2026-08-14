// swift-tools-version: 6.0
import PackageDescription

/// The control plane's status app.
///
/// Its own package rather than a target in the agent's: that one depends on MLX,
/// which is several hundred megabytes of Metal kernels for a machine that may
/// never run a model. The control plane is one machine an operator attends to,
/// and this is the thing they look at when they want to know whether it is up.
///
/// Split into a library and a shell because the interesting parts - what
/// launchctl said, what /healthz answered, what the metrics mean - are worth
/// testing, and none of them need a window to run.
let package = Package(
    name: "DaiControlStatus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dai-control-status", targets: ["DaiControlStatusApp"]),
        .library(name: "DaiControlStatusCore", targets: ["DaiControlStatusCore"]),
    ],
    targets: [
        .target(name: "DaiControlStatusCore"),
        .executableTarget(name: "DaiControlStatusApp", dependencies: ["DaiControlStatusCore"]),
        .testTarget(name: "DaiControlStatusTests", dependencies: ["DaiControlStatusCore"]),
    ]
)
