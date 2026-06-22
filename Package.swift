// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrivateHeaderKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PrivateHeaderKitCore", targets: ["PrivateHeaderKitCore"]),
        .executable(name: "privateheaderkit", targets: ["PrivateHeaderKitCLI"]),
        .executable(name: "privateheaderkit-raw-helper", targets: ["PrivateHeaderKitRawDumpHelper"]),
        .executable(name: "privateheaderkit-sim-helper", targets: ["PrivateHeaderKitSimulatorHelper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachOKit.git",
            from: "0.46.100"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachOObjCSection.git",
            from: "0.6.100"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/swift-objc-dump.git",
            from: "0.8.100"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection.git",
            revision: "f17bc65b57f372b461fe45687298671c3400909e"
        ),
    ],
    targets: [
        .target(
            name: "PrivateHeaderKitRawDumpRuntimeObjC",
            dependencies: [],
            path: "Sources/PrivateHeaderKitRawDumpRuntimeObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PrivateHeaderKitRawDumpCore",
            dependencies: [
                .target(
                    name: "PrivateHeaderKitRawDumpRuntimeObjC",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                .product(name: "SwiftDeclaration", package: "MachOSwiftSection"),
                .product(name: "SwiftInterface", package: "MachOSwiftSection"),
            ],
            path: "Sources/PrivateHeaderKitRawDumpCore"
        ),
        .target(
            name: "PrivateHeaderKitTooling",
            dependencies: []
        ),
        .target(
            name: "PrivateHeaderKitCore",
            dependencies: []
        ),
        .target(
            name: "PrivateHeaderKitInstall",
            dependencies: [
                "PrivateHeaderKitTooling",
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitCLI",
            dependencies: [
                "PrivateHeaderKitCore",
                "PrivateHeaderKitInstall",
                "PrivateHeaderKitTooling",
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitRawDumpHelper",
            dependencies: [
                "PrivateHeaderKitRawDumpCore",
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitSimulatorHelper",
            dependencies: [
                "PrivateHeaderKitRawDumpCore",
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitToolingTestHelper",
            dependencies: [
                "PrivateHeaderKitTooling",
            ],
            path: "Tests/PrivateHeaderKitToolingTestHelper"
        ),
        .target(
            name: "PrivateHeaderKitTestSupport",
            dependencies: [
                "PrivateHeaderKitTooling",
            ],
            path: "Tests/PrivateHeaderKitTestSupport"
        ),
        .testTarget(
            name: "PrivateHeaderKitRawDumpTests",
            dependencies: [
                "PrivateHeaderKitRawDumpCore",
                "PrivateHeaderKitTestSupport",
                .target(
                    name: "PrivateHeaderKitRawDumpRuntimeObjC",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
                .product(name: "MachOKit", package: "MachOKit"),
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitCoreTests",
            dependencies: [
                "PrivateHeaderKitCore",
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitToolingTests",
            dependencies: [
                "PrivateHeaderKitTooling",
                "PrivateHeaderKitTestSupport",
                .target(
                    name: "PrivateHeaderKitToolingTestHelper",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitInstallTests",
            dependencies: [
                "PrivateHeaderKitInstall",
                "PrivateHeaderKitTestSupport",
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitCLITests",
            dependencies: [
                "PrivateHeaderKitCLI",
                "PrivateHeaderKitTooling",
            ]
        ),
    ]
)
