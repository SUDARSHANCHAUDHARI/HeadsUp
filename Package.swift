// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeadsUp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HeadsUp",
            resources: [.copy("Resources/web")]
        )
    ]
)
