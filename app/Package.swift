// swift-tools-version:5.10
import PackageDescription

// The face: a small native macOS panel that floats over the chart and talks
// to the Sayso bridge on 127.0.0.1. No dependencies beyond the OS.
let package = Package(
    name: "SaysoFace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SaysoFace", path: "Sources/SaysoFace"),
        .testTarget(name: "SaysoFaceTests", dependencies: ["SaysoFace"], path: "Tests/SaysoFaceTests")
    ]
)
