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
        // Model loading, tokenisers and generation. mlx-swift itself is the
        // array framework; the LLM layer lives here.
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", from: "2.29.1"),
    ],
    targets: [
        // Presence, policy and the control plane client stay free of model
        // runtimes so they remain testable without hardware: every policy bug
        // found in the Python agent reproduced from a recorded signal struct.
        .target(name: "DaiAgent"),
        // The runtimes and the worker loop, which need MLX and Core ML.
        .target(
            name: "DaiWorker",
            dependencies: [
                "DaiAgent",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(
            name: "DaiAgentCLI",
            dependencies: ["DaiAgent", "DaiWorker"]
        ),
        .testTarget(name: "DaiAgentTests", dependencies: ["DaiAgent"]),
    ]
)
