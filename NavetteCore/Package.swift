// swift-tools-version: 5.10
import PackageDescription

// Logic of Navette, with no SwiftUI or AppKit.
// Static library: no dynamic framework to embed or sign.
let package = Package(
    name: "NavetteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NavetteCore", targets: ["NavetteCore"])
    ],
    targets: [
        .target(name: "NavetteCore"),
        .testTarget(name: "NavetteCoreTests", dependencies: ["NavetteCore"])
    ]
)
