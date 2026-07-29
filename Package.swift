// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "notepad-aaf",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "notepad-aaf", targets: ["notepad-aaf"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "notepad-aaf",
            dependencies: []
        )
    ]
)
