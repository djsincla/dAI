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
    ],
    targets: [
        .target(name: "NotebookKit"),
        // Writes a notebook so the format can be checked against rag_ask.py.
        .executableTarget(name: "notebook-demo", dependencies: ["NotebookKit"]),
        // The app. Built as an executable and wrapped into a bundle by
        // packaging/make-app.sh, so it runs from the command line during
        // development and becomes a document app in Xcode later.
        .executableTarget(name: "NotebookApp", dependencies: ["NotebookKit"]),
        .testTarget(name: "NotebookKitTests", dependencies: ["NotebookKit"]),
    ]
)
