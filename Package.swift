// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrivateHeaderKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "headerdump", targets: ["HeaderDumpCLI"]),
        .executable(name: "privateheaderkit-dump", targets: ["PrivateHeaderKitDump"]),
        .executable(name: "privateheaderkit-install", targets: ["PrivateHeaderKitInstall"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/lynnswap/MachOKit.git",
            from: "0.45.1"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOObjCSection.git",
            from: "0.5.2"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOSwiftSection.git",
            revision: "5d032fd36443dd060d149c79e1beb945b0f4f2f8"
        ),
        .package(
            url: "https://github.com/lynnswap/swift-objc-dump.git",
            from: "0.8.2"
        ),
    ],
    targets: [
        .target(
            name: "HeaderDumpCore",
            dependencies: [
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                .product(name: "MachOSwiftSection", package: "MachOSwiftSection"),
                .product(name: "SwiftInterface", package: "MachOSwiftSection"),
            ],
            path: "Sources/HeaderDumpCore"
        ),
        .target(
            name: "PrivateHeaderKitTooling",
            dependencies: []
        ),
        .executableTarget(
            name: "HeaderDumpCLI",
            dependencies: [
                "HeaderDumpCore",
            ],
            path: "Sources/HeaderDumpCLI"
        ),
        .executableTarget(
            name: "PrivateHeaderKitDump",
            dependencies: [
                "PrivateHeaderKitTooling",
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitInstall",
            dependencies: [
                "PrivateHeaderKitTooling",
            ]
        ),
        .testTarget(
            name: "HeaderDumpCLITests",
            dependencies: [
                "HeaderDumpCore",
                .product(name: "MachOKit", package: "MachOKit"),
            ]
        ),
    ]
)
