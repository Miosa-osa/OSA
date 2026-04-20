// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenShare",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenShare",
            path: "Sources/ScreenShare"
        )
    ]
)
