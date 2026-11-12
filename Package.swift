// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskInventory",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DiskInventoryCore", targets: ["DiskInventoryCore"]),
        .executable(name: "DiskInventoryApp", targets: ["DiskInventoryApp"])
    ],
    targets: [
        .target(
            name: "DiskInventoryCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "DiskInventoryApp",
            dependencies: ["DiskInventoryCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "DiskInventoryCoreTests",
            dependencies: ["DiskInventoryCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

