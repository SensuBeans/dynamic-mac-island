// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notchbook",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Notchbook",
            path: "Sources/Notchbook"
        )
    ]
)
