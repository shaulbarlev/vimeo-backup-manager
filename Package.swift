// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vbackup",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Contracts"),
        .target(name: "LibraryKit", dependencies: ["Contracts"]),
        .target(name: "DownloadKit", dependencies: ["Contracts"]),
        .executableTarget(name: "VBackupApp", dependencies: ["Contracts", "LibraryKit", "DownloadKit"]),
        .testTarget(name: "ContractsTests", dependencies: ["Contracts"]),
        .testTarget(name: "LibraryKitTests", dependencies: ["LibraryKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
        .testTarget(name: "AppTests", dependencies: ["VBackupApp"]),
    ],
    swiftLanguageModes: [.v5]
)
