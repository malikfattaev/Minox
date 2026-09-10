// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Minox",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Minox", targets: ["Minox"])
    ],
    targets: [
        .executableTarget(
            name: "Minox",
            path: "Minox",
            resources: [.process("Resources")]
        )
    ]
)
