import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationTargetDiscoveryTests {
    @Test func discoversTopLevelTargetsFromSystemRootInStableOrder() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createDirectory("System/Library/Frameworks/UIKit.framework", in: root)
        try createDirectory("System/Library/Frameworks/AVFoundation.framework", in: root)
        try createDirectory("System/Library/PrivateFrameworks/SafariShared.framework", in: root)
        try writeFile("System/Library/Frameworks/NotAFramework.framework", in: root)
        try writeFile("System/Library/PrivateFrameworks/NotPrivateFramework.framework", in: root)
        try createDirectory("System/Library/CoreServices/ControlCenter.app", in: root)
        try createDirectory("System/Library/PreferenceBundles/Foo.bundle", in: root)
        try createDirectory("System/Library/Frameworks/Ignored.bundle", in: root)
        try writeFile("usr/lib/libobjc.A.dylib", in: root)
        try writeFile("usr/lib/libswiftCore.tbd", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("usr/lib/libswiftCore.dylib"),
            withDestinationURL: root.appendingPathComponent("usr/lib/libobjc.A.dylib")
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(catalog.targets.map(\.candidate.displayName) == [
            "AVFoundation",
            "UIKit",
            "SafariShared",
            "CoreServices/ControlCenter.app",
            "PreferenceBundles/Foo.bundle",
            "libobjc.A.dylib",
            "libswiftCore.dylib",
        ])
        #expect(catalog.targets.map(\.candidate.kind) == [
            .framework,
            .framework,
            .privateFramework,
            .systemBundle,
            .systemBundle,
            .usrLibDylib,
            .usrLibDylib,
        ])
        #expect(catalog.targets.map(\.artifactRoot.rawValue) == [
            "Frameworks/AVFoundation",
            "Frameworks/UIKit",
            "PrivateFrameworks/SafariShared",
            "SystemLibrary/CoreServices/ControlCenter",
            "SystemLibrary/PreferenceBundles/Foo",
            "usr/lib/libobjc.A.dylib",
            "usr/lib/libswiftCore.dylib",
        ])
        #expect(catalog.targets.map(\.inputPath) == [
            root.appendingPathComponent("System/Library/Frameworks/AVFoundation.framework").path,
            root.appendingPathComponent("System/Library/Frameworks/UIKit.framework").path,
            root.appendingPathComponent("System/Library/PrivateFrameworks/SafariShared.framework").path,
            root.appendingPathComponent("System/Library/CoreServices/ControlCenter.app").path,
            root.appendingPathComponent("System/Library/PreferenceBundles/Foo.bundle").path,
            root.appendingPathComponent("usr/lib/libobjc.A.dylib").path,
            root.appendingPathComponent("usr/lib/libswiftCore.dylib").path,
        ])
        #expect(catalog.targets.map(\.runtimeInputPath) == [
            "/System/Library/Frameworks/AVFoundation.framework",
            "/System/Library/Frameworks/UIKit.framework",
            "/System/Library/PrivateFrameworks/SafariShared.framework",
            "/System/Library/CoreServices/ControlCenter.app",
            "/System/Library/PreferenceBundles/Foo.bundle",
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/libswiftCore.dylib",
        ])
    }

    @Test func keepsSourceMetadataNeededByFutureExecutor() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createDirectory("System/Library/Frameworks/UIKit.framework", in: root)
        try createDirectory("System/Library/PrivateFrameworks/SafariShared.framework", in: root)
        try createDirectory("System/Library/PreferenceBundles/Foo.bundle", in: root)
        try writeFile("usr/lib/libobjc.A.dylib", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        let framework = try #require(catalog.targets.first { $0.candidate.displayName == "UIKit" })
        guard case .framework(let frameworkSource) = framework.source else {
            Issue.record("expected framework source metadata")
            return
        }
        #expect(frameworkSource.location == .publicFramework)
        #expect(frameworkSource.bundleName == "UIKit.framework")
        #expect(frameworkSource.systemLibraryRelativePath == "Frameworks/UIKit.framework")

        let privateFramework = try #require(catalog.targets.first { $0.candidate.displayName == "SafariShared" })
        guard case .framework(let privateFrameworkSource) = privateFramework.source else {
            Issue.record("expected framework source metadata")
            return
        }
        #expect(privateFrameworkSource.location == .privateFramework)
        #expect(privateFrameworkSource.bundleName == "SafariShared.framework")

        let systemBundle = try #require(
            catalog.targets.first { $0.candidate.displayName == "PreferenceBundles/Foo.bundle" }
        )
        guard case .systemLibraryBundle(let systemBundleSource) = systemBundle.source else {
            Issue.record("expected SystemLibrary source metadata")
            return
        }
        #expect(systemBundleSource.relativePath == "PreferenceBundles/Foo.bundle")
        #expect(systemBundleSource.bundleKind == .bundle)
        #expect(systemBundleSource.role == .topLevel)

        let dylib = try #require(catalog.targets.first { $0.candidate.displayName == "libobjc.A.dylib" })
        guard case .usrLibDylib(let dylibSource) = dylib.source else {
            Issue.record("expected usr/lib source metadata")
            return
        }
        #expect(dylibSource.name == "libobjc.A.dylib")
    }

    @Test func nestedChildrenAreDiscoveredButExcludedFromResolverCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createDirectory("System/Library/Frameworks/Foo.framework/XPCServices/FooHelper.xpc", in: root)
        try createDirectory("System/Library/Frameworks/Foo.framework/PlugIns/FooExtension.appex", in: root)
        try createDirectory("System/Library/PreferenceBundles/Prefs.bundle/XPCServices/PrefsHelper.xpc", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        let framework = try #require(catalog.targets.first { $0.candidate.displayName == "Foo" })
        let systemBundle = try #require(
            catalog.targets.first { $0.candidate.displayName == "PreferenceBundles/Prefs.bundle" }
        )

        #expect(framework.childTargets.map(\.candidate.displayName) == [
            "Frameworks/Foo.framework/PlugIns/FooExtension.appex",
            "Frameworks/Foo.framework/XPCServices/FooHelper.xpc",
        ])
        #expect(framework.childTargets.map(\.artifactRoot.rawValue) == [
            "Frameworks/Foo/PlugIns/FooExtension",
            "Frameworks/Foo/XPCServices/FooHelper",
        ])
        #expect(systemBundle.childTargets.map(\.candidate.displayName) == [
            "PreferenceBundles/Prefs.bundle/XPCServices/PrefsHelper.xpc",
        ])
        #expect(systemBundle.childTargets.map(\.artifactRoot.rawValue) == [
            "SystemLibrary/PreferenceBundles/Prefs/XPCServices/PrefsHelper",
        ])
        #expect(catalog.resolverCandidates.map(\.displayName) == [
            "Foo",
            "PreferenceBundles/Prefs.bundle",
        ])

        let query = try PrivateHeaderGeneration.TargetQuery(commaSeparated: "FooHelper")
        #expect(
            catalog.resolver.resolve(query) == .failed(
                [
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "FooHelper",
                        reason: .noMatch
                    ),
                ]
            )
        )
    }

    @Test func nestedDiscoveryCanBeDisabled() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createDirectory("System/Library/Frameworks/Foo.framework/XPCServices/FooHelper.xpc", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            includeNestedChildren: false
        )

        let framework = try #require(catalog.targets.first { $0.candidate.displayName == "Foo" })
        #expect(framework.childTargets.isEmpty)
        #expect(catalog.allTargetsIncludingNestedChildren.map(\.candidate.displayName) == ["Foo"])
    }

    @Test func resolverUsesDisplayNamesAndExactAliasesWithoutCategoryPartialSelection() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createDirectory("System/Library/Frameworks/UIKit.framework", in: root)
        try createDirectory("System/Library/PrivateFrameworks/UIKitServices.framework", in: root)
        try createDirectory("System/Library/CoreServices/ControlCenter.app", in: root)
        try createDirectory("System/Library/PreferenceBundles/Foo.bundle", in: root)
        try writeFile("usr/lib/libobjc.A.dylib", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(
            catalog.resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "UIKit"))
                == .selected(.targets([
                    try PrivateHeaderGeneration.TargetCandidate(
                        identifier: "framework:UIKit.framework",
                        displayName: "UIKit",
                        kind: .framework,
                        aliases: [
                            "UIKit.framework",
                            "Frameworks/UIKit.framework",
                            "/System/Library/Frameworks/UIKit.framework",
                        ]
                    ),
                ]))
        )
        #expect(
            catalog.resolver.resolve(
                try PrivateHeaderGeneration.TargetQuery(commaSeparated: "PreferenceBundles/Foo.bundle")
            ) == .selected(.targets([
                try PrivateHeaderGeneration.TargetCandidate(
                    identifier: "system-library:PreferenceBundles/Foo.bundle",
                    displayName: "PreferenceBundles/Foo.bundle",
                    kind: .systemBundle,
                    aliases: [
                        "/System/Library/PreferenceBundles/Foo.bundle",
                    ]
                ),
            ]))
        )
        #expect(
            catalog.resolver.resolve(
                try PrivateHeaderGeneration.TargetQuery(
                    commaSeparated: "/System/Library/PreferenceBundles/Foo.bundle"
                )
            ) == .selected(.targets([
                try PrivateHeaderGeneration.TargetCandidate(
                    identifier: "system-library:PreferenceBundles/Foo.bundle",
                    displayName: "PreferenceBundles/Foo.bundle",
                    kind: .systemBundle,
                    aliases: [
                        "/System/Library/PreferenceBundles/Foo.bundle",
                    ]
                ),
            ]))
        )
        #expect(
            catalog.resolver.resolve(
                try PrivateHeaderGeneration.TargetQuery(commaSeparated: "usr/lib/libobjc.A.dylib")
            ) == .selected(.targets([
                try PrivateHeaderGeneration.TargetCandidate(
                    identifier: "usr-lib:libobjc.A.dylib",
                    displayName: "libobjc.A.dylib",
                    kind: .usrLibDylib,
                    aliases: [
                        "usr/lib/libobjc.A.dylib",
                    ]
                ),
            ]))
        )
        #expect(
            catalog.resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "Frameworks"))
                == .failed([
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "Frameworks",
                        reason: .noMatch
                    ),
                ])
        )
        #expect(
            catalog.resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "PreferenceBundles"))
                == .failed([
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "PreferenceBundles",
                        reason: .noMatch
                    ),
                ])
        )
        #expect(
            catalog.resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "CoreServices"))
                == .failed([
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "CoreServices",
                        reason: .noMatch
                    ),
                ])
        )
        #expect(
            catalog.resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "usr/lib"))
                == .failed([
                    PrivateHeaderGeneration.TargetResolution.Failure(
                        query: "usr/lib",
                        reason: .noMatch
                    ),
                ])
        )
    }

    @Test func missingOptionalSourceDirectoriesProduceEmptyCatalog() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(catalog.targets.isEmpty)
        #expect(catalog.resolverCandidates.isEmpty)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderGenerationTargetDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func createDirectory(_ relativePath: String, in root: URL) throws {
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(relativePath, isDirectory: true),
        withIntermediateDirectories: true
    )
}

private func writeFile(_ relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: url)
}
