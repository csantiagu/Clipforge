// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipforge",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: probing, command building, naming, estimates. No UI.
        .target(name: "ClipforgeCore"),
        // SwiftUI app.
        .executableTarget(name: "Clipforge", dependencies: ["ClipforgeCore"]),
        .testTarget(name: "ClipforgeCoreTests", dependencies: ["ClipforgeCore"]),
    ]
)
