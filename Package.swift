// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "KeepVibe",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "KeepVibe",
            path: "Sources/KeepVibe"
        )
    ]
)
