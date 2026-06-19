// swift-tools-version: 6.2
import PackageDescription

let isSimulatorHelperBuild = Context.environment["PHK_SIMULATOR_HELPER_BUILD"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(
        url: "https://github.com/lynnswap/MachOKit.git",
        from: "0.47.0"
    ),
    .package(
        url: "https://github.com/lynnswap/MachOObjCSection.git",
        revision: "3dbf6a856cbdc856d4d7c1fe6bbf81161e0fbe9c"
    ),
    .package(
        url: "https://github.com/p-x9/swift-objc-dump.git",
        from: "0.8.0"
    ),
]

if !isSimulatorHelperBuild {
    packageDependencies.append(
        .package(
            url: "https://github.com/lynnswap/MachOSwiftSection.git",
            revision: "2fbb1a78e316a2beaf2911488ecda6455e205f84"
        )
    )
}

var rawDumpCoreDependencies: [Target.Dependency] = [
    .target(
        name: "PrivateHeaderKitRawDumpRuntimeObjC",
        condition: .when(platforms: [.macOS, .iOS])
    ),
    .product(name: "MachOKit", package: "MachOKit"),
    .product(name: "MachOObjCSection", package: "MachOObjCSection"),
    .product(name: "ObjCDump", package: "swift-objc-dump"),
]

if !isSimulatorHelperBuild {
    rawDumpCoreDependencies.append(
        .product(
            name: "SwiftInterface",
            package: "MachOSwiftSection",
            condition: .when(platforms: [.macOS])
        )
    )
}

let package = Package(
    name: "PrivateHeaderKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "PrivateHeaderKitCore", targets: ["PrivateHeaderKitCore"]),
        .executable(name: "privateheaderkit", targets: ["PrivateHeaderKitCLI"]),
        .executable(name: "privateheaderkit-sim-helper", targets: ["PrivateHeaderKitSimulatorHelper"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "PrivateHeaderKitRawDumpRuntimeObjC",
            dependencies: [],
            path: "Sources/PrivateHeaderKitRawDumpRuntimeObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "PrivateHeaderKitRawDumpCore",
            dependencies: rawDumpCoreDependencies,
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
                "PrivateHeaderKitRawDumpCore",
                "PrivateHeaderKitCore",
                "PrivateHeaderKitInstall",
                "PrivateHeaderKitTooling",
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
            ]
        ),
    ]
)
