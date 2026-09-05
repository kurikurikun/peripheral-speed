// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PeripheralSpeed",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PeripheralSpeed",
            path: "Sources/PeripheralSpeed"
        )
    ]
)
