// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperVoice",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "WhisperVoice", targets: ["WhisperVoice"])
    ],
    targets: [
        .executableTarget(
            name: "WhisperVoice",
            dependencies: [],
            path: "Sources/WhisperVoice"
        )
    ]
)
