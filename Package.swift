// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrivateHeaderKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "classdump-dyld", targets: ["HeaderDumpCLI"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/MachOKit.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOObjCSection.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/lynnswap/MachOSwiftSection.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/MxIris-Reverse-Engineering/swift-objc-dump.git",
            branch: "main"
        ),
    ],
    targets: [
        .executableTarget(
            name: "HeaderDumpCLI",
            dependencies: [
                .product(name: "MachOKit", package: "MachOKit"),
                .product(name: "MachOObjCSection", package: "MachOObjCSection"),
                .product(name: "ObjCDump", package: "swift-objc-dump"),
                .product(name: "MachOSwiftSection", package: "MachOSwiftSection"),
                .product(name: "SwiftInterface", package: "MachOSwiftSection"),
            ],
            path: "Sources/HeaderDumpCLI"
        ),
    ]
)
