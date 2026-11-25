// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ExeFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ExeCore"),
        .executableTarget(name: "ExeFlow", dependencies: ["ExeCore"]),
        .executableTarget(name: "exerun", dependencies: ["ExeCore"]),
        .testTarget(name: "ExeCoreTests", dependencies: ["ExeCore"]),
    ]
)
