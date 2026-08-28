// swift-tools-version: 6.0
import PackageDescription

// notebookMLX, as a library first.
//
// The app is an Xcode target and cannot run its tests from the command line;
// everything that can be decided without a window lives here instead, so it is
// testable with `swift test` and reviewable without opening Xcode. The same
// split the agent uses, for the same reason.
let package = Package(
    name: "NotebookKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotebookKit", targets: ["NotebookKit"]),
        .executable(name: "notebook-demo", targets: ["notebook-demo"]),
        .executable(name: "NotebookApp", targets: ["NotebookApp"]),
        .executable(name: "notebook-import", targets: ["notebook-import"]),
        .executable(name: "notebook-verify", targets: ["notebook-verify"]),
    ],
    dependencies: [
        // xlsx is a zip of XML, so reading one means unzipping and parsing
        // rather than a format decision. CoreXLSX is MIT, has no dependencies
        // of its own beyond XMLCoder, and is far less code than the two we
        // would otherwise write and own. The alternative was ZIPFoundation
        // plus XMLParser, which is the same work with our name on it.
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.2"),
        // The same vendored copy the agent builds against, by path rather than
        // by version. Two copies of MLXEmbedders at different revisions could
        // pool or normalise differently, and an index built by one would be
        // silently incomparable with a query from the other. One copy is the
        // only way to be sure they agree.
        .package(path: "../agent/vendor/mlx-swift-examples"),
    ],
    targets: [
        .target(name: "NotebookKit", dependencies: [
            .product(name: "CoreXLSX", package: "CoreXLSX"),
            .product(name: "MLXEmbedders", package: "mlx-swift-examples"),
        ]),
        // Writes a notebook so the format can be checked against rag_ask.py.
        .executableTarget(name: "notebook-demo", dependencies: ["NotebookKit"]),
        // The app. Built as an executable and wrapped into a bundle by
        // packaging/make-app.sh, so it runs from the command line during
        // development and becomes a document app in Xcode later.
        .executableTarget(name: "NotebookApp", dependencies: ["NotebookKit"]),
        // Adopts an index that already exists, so work already done is not
        // done again. See Sources/notebook-import/main.swift.
        .executableTarget(name: "notebook-import", dependencies: ["NotebookKit"]),
        // Checks this embedder against the agent's fixture. See its main.swift
        // for why it is a command and not a test.
        .executableTarget(name: "notebook-verify", dependencies: ["NotebookKit"]),
        .testTarget(name: "NotebookKitTests", dependencies: ["NotebookKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
