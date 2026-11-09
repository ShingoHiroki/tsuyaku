// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tsuyaku",
    platforms: [.macOS(.v26)],
    dependencies: [
        // 版は固定する（動作を確かめた版）
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "Tsuyaku",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
