// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PowerCap",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSystemPower", path: "Sources/CSystemPower"),
        .executableTarget(name: "PowerCap", dependencies: ["CSystemPower"], path: "Sources/PowerCap"),
    ]
)
