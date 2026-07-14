// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoniqueBar",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SoniqueBar",
            dependencies: []
        )
    ]
)
