// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoniqueBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/mweinbach/kokoro-swift.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "SoniqueBar",
            dependencies: [
                .product(name: "Kokoro", package: "kokoro-swift")
            ]
        )
    ]
)
