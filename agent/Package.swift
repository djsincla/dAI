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
        // The artist-side app. Separate from the daemon on purpose: it runs in
        // the user's session with no privilege, and can only ask.
        .executable(name: "dai-menubar", targets: ["DaiMenuBar"]),
        .library(name: "DaiAgent", targets: ["DaiAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.25.0"),
        // Model loading, tokenisers and generation. mlx-swift itself is the
        // array framework; the LLM layer lives here.
        .package(path: "vendor/mlx-swift-examples"),
        // URLSession can only present a client certificate as a SecIdentity,
        // which needs the private key as a SecKey. A key held in the Secure
        // Enclave is not one, and cannot be made into one without the keychain
        // entitlement that route was chosen to avoid. NIO's TLS stack accepts a
        // signing callback instead, which is the whole reason for this
        // dependency.
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client", from: "1.21.0"),
    ],
    targets: [
        // Presence, policy and the control plane client stay free of model
        // runtimes so they remain testable without hardware: every policy bug
        // found in the Python agent reproduced from a recorded signal struct.
        .target(
            name: "DaiAgent",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ]
        ),
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
        .executableTarget(name: "DaiMenuBar", dependencies: ["DaiAgent"]),
        .testTarget(name: "DaiAgentTests",
                    dependencies: ["DaiAgent", "DaiWorker",
                                   .product(name: "MLXLLM", package: "mlx-swift-examples")]),
    ]
)
