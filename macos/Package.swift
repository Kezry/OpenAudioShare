// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioShareMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AudioShare", targets: ["AudioShareMac"]),
        .library(name: "AudioShareCore", targets: ["AudioShareCore"]),
    ],
    targets: [
        .target(
            name: "AudioShareCore",
            path: "Sources/AudioShareCore"
        ),
        .executableTarget(
            name: "AudioShareMac",
            dependencies: ["AudioShareCore"],
            path: "Sources/AudioShareMac"
        ),
        .executableTarget(
            name: "AudioShareChecks",
            dependencies: ["AudioShareCore"],
            path: "Sources/AudioShareChecks"
        ),
    ]
)
