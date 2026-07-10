// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JarvisVoice",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JarvisVoice",
            path: "Sources/JarvisVoice"
        )
    ]
)
