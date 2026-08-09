// swift-tools-version: 6.0
import PackageDescription

// The agent ships as one signed binary with no runtime to install across the
// fleet. That is the whole argument for Swift over Python here: every API it
// touches is an Apple API, and mlx-swift is maintained by the people who make
// the hardware.
let package = Package(
    name: "DaiAgent",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "dai-agent", targets: ["DaiAgentCLI"]),
        .library(name: "DaiAgent", targets: ["DaiAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.25.0"),
    ],
    targets: [
        // The policy core is deliberately free of MLX and Core ML so it stays
        // testable without hardware. Every policy bug found in the Python agent
        // reproduced from a recorded signal dictionary alone.
        .target(name: "DaiAgent"),
        .executableTarget(
            name: "DaiAgentCLI",
            dependencies: [
                "DaiAgent",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ]
        ),
        .testTarget(name: "DaiAgentTests", dependencies: ["DaiAgent"]),
    ]
)
