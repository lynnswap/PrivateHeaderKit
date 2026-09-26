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
            revision: "8d451ca2e9d108f0a2024758b33b25e8faa2adbb"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOObjCSection.git",
            revision: "5576f1e1f53ed88faf4e71c781246f7ec1cd1b24"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/swift-objc-dump.git",
            from: "0.8.100"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOSwiftSection.git",
            revision: "04ff26795fca8efc88fce2bb3d09fa0a947e56bf"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/swift-demangling",
            "0.6.3" ..< "0.7.0"
        ),
    ],
    targets: [
        .target(
            name: "PrivateHeaderKitHelperProtocol",
            dependencies: [],
            plugins: [
                .plugin(name: "PrivateHeaderKitBuildInfoPlugin"),
            ]
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
                "PrivateHeaderKitExecutableResolution",
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
            name: "PrivateHeaderKitBuildInfoTool"
        ),
        .plugin(
            name: "PrivateHeaderKitBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["PrivateHeaderKitBuildInfoTool"]
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
            name: "PrivateHeaderKitBuildInfoToolTests",
            dependencies: [
                "PrivateHeaderKitBuildInfoTool",
            ]
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
                "PrivateHeaderKitExecutableResolution",
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
