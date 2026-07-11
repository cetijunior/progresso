// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Progresso",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Progresso",
            dependencies: ["Yams"],
            path: "Sources/Progresso"
        )
    ]
)
