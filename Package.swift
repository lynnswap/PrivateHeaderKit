// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PrivateHeaderKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .executable(name: "privateheaderkit", targets: ["PrivateHeaderKitCLI"]),
        .executable(name: "privateheaderkit-install", targets: ["PrivateHeaderKitInstallCLI"]),
        .executable(name: "privateheaderkit-raw-helper", targets: ["PrivateHeaderKitRawDumpHelper"]),
        .executable(name: "privateheaderkit-sim-helper", targets: ["PrivateHeaderKitSimulatorHelper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.8.2"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            from: "1.0.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.11.0"
        ),
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            from: "7.11.1"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachOKit.git",
            from: "0.51.101"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOObjCSection.git",
            revision: "e8fdf4edc8f91aa46ef50f85932c1cb7690885af"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/swift-objc-dump.git",
            from: "0.8.100"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOSwiftSection.git",
            revision: "11a75142e0a0965363cff9e897719838dc975319"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/swift-demangling",
            "0.4.5" ..< "0.5.0"
        ),
    ],
    targets: [
        .target(
            name: "PrivateHeaderKitHelperProtocol",
            dependencies: []
        ),
        .target(
            name: "PrivateHeaderKitExecutableResolution",
            dependencies: []
        ),
        .target(
            name: "PrivateHeaderKitRawDumpRuntimeObjC",
            dependencies: [],
            path: "Sources/PrivateHeaderKitRawDumpRuntimeObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PrivateHeaderKitRawDumpCore",
            dependencies: [
                "PrivateHeaderKitHelperProtocol",
                "PrivateHeaderKitExecutableResolution",
                .target(
                    name: "PrivateHeaderKitRawDumpRuntimeObjC",
                    condition: .when(platforms: [.macOS, .iOS, .watchOS])
                ),
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                .product(name: "Demangling", package: "swift-demangling"),
                .product(name: "MachOSwiftSection", package: "MachOSwiftSection"),
                .product(name: "SwiftDeclaration", package: "MachOSwiftSection"),
                .product(name: "SwiftDeclarationRendering", package: "MachOSwiftSection"),
                .product(name: "SwiftInterface", package: "MachOSwiftSection"),
            ],
            path: "Sources/PrivateHeaderKitRawDumpCore"
        ),
        .target(
            name: "PrivateHeaderKitTooling",
            dependencies: [
                .product(
                    name: "Subprocess",
                    package: "swift-subprocess",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .target(
            name: "PrivateHeaderKitCore",
            dependencies: [
                "PrivateHeaderKitHelperProtocol",
                "PrivateHeaderKitExecutableResolution",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
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
                "PrivateHeaderKitHelperProtocol",
                "PrivateHeaderKitTooling",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(
                    name: "UnixSignals",
                    package: "swift-service-lifecycle",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitInstallCLI",
            dependencies: [
                "PrivateHeaderKitInstall",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(
                    name: "UnixSignals",
                    package: "swift-service-lifecycle",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitRawDumpHelper",
            dependencies: [
                "PrivateHeaderKitHelperProtocol",
                "PrivateHeaderKitRawDumpCore",
            ]
        ),
        .executableTarget(
            name: "PrivateHeaderKitSimulatorHelper",
            dependencies: [
                "PrivateHeaderKitHelperProtocol",
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
            name: "PrivateHeaderKitHelperProtocolTests",
            dependencies: [
                "PrivateHeaderKitHelperProtocol",
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitRawDumpTests",
            dependencies: [
                "PrivateHeaderKitHelperProtocol",
                "PrivateHeaderKitRawDumpCore",
                "PrivateHeaderKitTestSupport",
                .target(
                    name: "PrivateHeaderKitRawDumpRuntimeObjC",
                    condition: .when(platforms: [.macOS, .iOS, .watchOS])
                ),
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitCoreTests",
            dependencies: [
                "PrivateHeaderKitCore",
                "PrivateHeaderKitHelperProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
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
                .target(
                    name: "PrivateHeaderKitInstall",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "PrivateHeaderKitTestSupport",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "PrivateHeaderKitInstallCLI",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "PrivateHeaderKitTooling",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "UnixSignals",
                    package: "swift-service-lifecycle",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .testTarget(
            name: "PrivateHeaderKitCLITests",
            dependencies: [
                "PrivateHeaderKitCLI",
                "PrivateHeaderKitCore",
                "PrivateHeaderKitHelperProtocol",
                "PrivateHeaderKitTestSupport",
                "PrivateHeaderKitTooling",
            ]
        ),
    ]
)
