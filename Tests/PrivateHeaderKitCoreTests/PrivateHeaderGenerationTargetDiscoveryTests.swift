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

        try createLoadableBundle("System/Library/Frameworks/UIKit.framework", in: root)
        try createLoadableBundle("System/Library/Frameworks/AVFoundation.framework", in: root)
        try createLoadableBundle("System/Library/PrivateFrameworks/SafariShared.framework", in: root)
        try writeFile("System/Library/Frameworks/NotAFramework.framework", in: root)
        try writeFile("System/Library/PrivateFrameworks/NotPrivateFramework.framework", in: root)
        try createLoadableBundle("System/Library/CoreServices/ControlCenter.app", in: root)
        try createLoadableBundle("System/Library/PreferenceBundles/Foo.bundle", in: root)
        try createDirectory("System/Library/Frameworks/Ignored.bundle", in: root)
        try writeFile("usr/lib/libobjc.A.dylib", in: root)
        try writeFile("usr/lib/libswiftCore.tbd", in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("usr/lib/libswiftCore.dylib"),
            withDestinationURL: root.appendingPathComponent("usr/lib/libobjc.A.dylib")
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(catalog.groups.map(\.selectionCandidate.displayName) == [
            "AVFoundation",
            "UIKit",
            "SafariShared",
            "CoreServices/ControlCenter.app",
            "PreferenceBundles/Foo.bundle",
            "libobjc.A.dylib",
            "libswiftCore.dylib",
        ])
        #expect(catalog.groups.map(\.selectionCandidate.kind) == [
            .framework,
            .framework,
            .privateFramework,
            .systemBundle,
            .systemBundle,
            .usrLibDylib,
            .usrLibDylib,
        ])
        #expect(catalog.groups.compactMap(\.primaryTarget?.artifactRoot.rawValue) == [
            "Frameworks/AVFoundation",
            "Frameworks/UIKit",
            "PrivateFrameworks/SafariShared",
            "SystemLibrary/CoreServices/ControlCenter.app",
            "SystemLibrary/PreferenceBundles/Foo.bundle",
            "usr/lib/libobjc.A.dylib",
            "usr/lib/libswiftCore.dylib",
        ])
        #expect(catalog.groups.compactMap(\.primaryTarget?.inputPath) == [
            root.appendingPathComponent("System/Library/Frameworks/AVFoundation.framework").path,
            root.appendingPathComponent("System/Library/Frameworks/UIKit.framework").path,
            root.appendingPathComponent("System/Library/PrivateFrameworks/SafariShared.framework").path,
            root.appendingPathComponent("System/Library/CoreServices/ControlCenter.app").path,
            root.appendingPathComponent("System/Library/PreferenceBundles/Foo.bundle").path,
            root.appendingPathComponent("usr/lib/libobjc.A.dylib").path,
            root.appendingPathComponent("usr/lib/libswiftCore.dylib").path,
        ])
        #expect(catalog.groups.compactMap(\.primaryTarget?.runtimeInputPath) == [
            "/System/Library/Frameworks/AVFoundation.framework",
            "/System/Library/Frameworks/UIKit.framework",
            "/System/Library/PrivateFrameworks/SafariShared.framework",
            "/System/Library/CoreServices/ControlCenter.app",
            "/System/Library/PreferenceBundles/Foo.bundle",
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/libswiftCore.dylib",
        ])
    }

    @Test func diskBackedFrameworkAndSystemBundlesRemainDiscoverable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try createLoadableBundle("System/Library/Frameworks/Disk.framework", in: root)
        try createLoadableBundle("System/Library/CoreServices/Disk.app", in: root)
        try createLoadableBundle("System/Library/PreferenceBundles/Disk.bundle", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(catalog.groups.map(\.selectionCandidate.displayName) == [
            "Disk",
            "CoreServices/Disk.app",
            "PreferenceBundles/Disk.bundle",
        ])
        #expect(catalog.allExecutionTargets.count == 3)
    }

    @Test func customCFBundleExecutableOnlyAppliesWhenBundleResolvesIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let diskPath = "System/Library/Frameworks/CustomDisk.framework"
        try createDirectory(diskPath, in: root)
        try writeBundleInfo(diskPath, executableName: "ActualExecutable", in: root)
        try writeFile(diskPath + "/ActualExecutable", in: root)

        let admitted = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        #expect(admitted.groups.map(\.selectionCandidate.displayName) == ["CustomDisk"])

        let cacheOnlyPath = "System/Library/Frameworks/CustomCacheOnly.framework"
        try createDirectory(cacheOnlyPath, in: root)
        try writeBundleInfo(cacheOnlyPath, executableName: "ActualExecutable", in: root)
        let cacheOnly = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: [
                "/System/Library/Frameworks/CustomCacheOnly.framework/ActualExecutable"
            ]
        )
        #expect(cacheOnly.groups.map(\.selectionCandidate.displayName) == ["CustomDisk"])

        let fallbackPath = "System/Library/Frameworks/CustomFallback.framework"
        try createDirectory(fallbackPath, in: root)
        try writeBundleInfo(fallbackPath, executableName: "ActualExecutable", in: root)
        try writeFile(fallbackPath + "/CustomFallback", in: root)
        let basenameFallback = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        #expect(basenameFallback.groups.map(\.selectionCandidate.displayName) == [
            "CustomDisk", "CustomFallback",
        ])
    }

    @Test func cacheOnlyFrameworksAcceptOnlyHelperGeneratedVersionAliases() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["Flat", "Versioned", "Future"] {
            try createDirectory("System/Library/Frameworks/\(name).framework", in: root)
        }

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: [
                "/System/Library/Frameworks/Flat.framework/Flat",
                "/System/Library/Frameworks/Versioned.framework/Versions/A/Versioned",
                "/System/Library/Frameworks/Future.framework/Versions/Z9/Future",
            ]
        )

        #expect(catalog.groups.map(\.selectionCandidate.displayName) == ["Flat", "Versioned"])
        #expect(!catalog.groups.contains { $0.selectionCandidate.displayName == "Future" })
        #expect(catalog.groups.allSatisfy { $0.primaryTarget != nil })
        #expect(catalog.groups.map { $0.primaryTarget?.runtimeInputPath } == [
            "/System/Library/Frameworks/Flat.framework",
            "/System/Library/Frameworks/Versioned.framework",
        ])
    }

    @Test func resourceOnlyPublicAndPrivateFrameworksAreExcluded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(
            "System/Library/Frameworks/PublicShell.framework/en.lproj/Localizable.strings",
            in: root
        )
        try writeFile(
            "System/Library/PrivateFrameworks/PrivateShell.framework/Info.plist",
            in: root
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: [
                "/System/Library/Frameworks/PublicShellExtra.framework/PublicShell",
                "/System/Library/Frameworks/PublicShell.framework/Versions/A/Helpers/PublicShell",
                "/System/Library/PrivateFrameworks/Other.framework/PrivateShell",
            ]
        )

        #expect(catalog.groups.isEmpty)
        #expect(catalog.allExecutionTargets.isEmpty)
    }

    @Test func resourceOnlyTopLevelAppsAndBundlesAreExcluded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile("System/Library/CoreServices/Shell.app/Resources/data", in: root)
        try writeFile("System/Library/PreferenceBundles/Shell.bundle/Resources/data", in: root)
        try createLoadableBundle("System/Library/CoreServices/Live.app", in: root)
        try createLoadableBundle("System/Library/PreferenceBundles/Live.bundle", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(catalog.groups.map(\.selectionCandidate.displayName) == [
            "CoreServices/Live.app",
            "PreferenceBundles/Live.bundle",
        ])
    }

    @Test func resourceOnlyNestedExtensionsAndServicesAreExcluded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = "System/Library/Frameworks/Parent.framework"
        try createLoadableBundle(parent, in: root)
        try createLoadableBundle(parent + "/PlugIns/LiveExtension.appex", in: root)
        try createLoadableBundle(parent + "/XPCServices/LiveService.xpc", in: root)
        try writeFile(parent + "/PlugIns/ShellExtension.appex/Resources/data", in: root)
        try writeFile(parent + "/XPCServices/ShellService.xpc/Resources/data", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        let group = try #require(catalog.groups.first)

        #expect(group.primaryTarget?.candidate.displayName == "Parent")
        #expect(group.childTargets.map(\.candidate.displayName) == [
            "Frameworks/Parent.framework/PlugIns/LiveExtension.appex",
            "Frameworks/Parent.framework/XPCServices/LiveService.xpc",
        ])
    }

    @Test func parentCacheImageDoesNotAdmitSameNamedResourceOnlyChild() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = "System/Library/Frameworks/Foo.framework"
        try createDirectory(parent + "/XPCServices/Foo.xpc", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: [
                "/System/Library/Frameworks/Foo.framework/Versions/A/Foo"
            ]
        )
        let group = try #require(catalog.groups.first)

        #expect(group.selectionCandidate.displayName == "Foo")
        #expect(group.primaryTarget?.candidate.identifier == "framework:Foo.framework")
        #expect(group.childTargets.isEmpty)
        #expect(catalog.allExecutionTargets.map(\.candidate.identifier) == [
            "framework:Foo.framework"
        ])
    }

    @Test func loadableNestedChildSurvivesResourceOnlyParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let parent = "System/Library/Frameworks/Shell.framework"
        try createDirectory(parent, in: root)
        try createLoadableBundle(parent + "/XPCServices/LiveService.xpc", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        let group = try #require(catalog.groups.first)

        #expect(group.selectionCandidate.displayName == "Shell")
        #expect(group.primaryTarget == nil)
        #expect(group.childTargets.map(\.candidate.displayName) == [
            "Frameworks/Shell.framework/XPCServices/LiveService.xpc",
        ])
        #expect(catalog.resolver.resolve(try PrivateHeaderGeneration.TargetQuery(commaSeparated: "Shell")) == .selected(.targets([
            group.selectionCandidate
        ])))
        #expect(catalog.allExecutionTargets == group.childTargets)
    }

    @Test func brokenExecutableSymlinkDoesNotAdmitBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent(
            "System/Library/Frameworks/Broken.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bundle.appendingPathComponent("Broken").path,
            withDestinationPath: "Missing"
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        #expect(catalog.groups.isEmpty)
    }

    @Test func contentsMacOSCachePathRequiresBundleResolvedExecutable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try createLoadableBundle(
            "System/Library/CoreServices/Disk.app",
            executableRelativePath: "Contents/MacOS/Disk",
            in: root
        )
        try writeBundleInfo(
            "System/Library/CoreServices/Disk.app",
            executableName: "Disk",
            infoRelativePath: "Contents/Info.plist",
            packageType: "APPL",
            in: root
        )
        try createDirectory("System/Library/CoreServices/Cache.app", in: root)
        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: [
                "/System/Library/CoreServices/Cache.app/Contents/MacOS/Cache"
            ]
        )

        #expect(catalog.groups.map(\.selectionCandidate.displayName) == [
            "CoreServices/Disk.app"
        ])
    }

    @Test func cacheInventoryOrderDuplicatesAndAliasesDoNotChangeCatalog() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDirectory("System/Library/Frameworks/Cache.framework", in: root)

        let aliases = [
            "/System/Library/Frameworks/Cache.framework/Cache",
            "/System/Library/Frameworks/Cache.framework/Versions/A/Cache",
            "/System/Library/Frameworks/Cache.framework/Cache",
        ]
        let first = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: aliases
        )
        let second = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: Array(aliases.reversed())
        )

        #expect(first == second)
        #expect(first.groups.count == 1)
        #expect(first.groups[0].selectionCandidate.aliases == [
            "Cache.framework",
            "Frameworks/Cache.framework",
            "/System/Library/Frameworks/Cache.framework",
        ])
    }

    @Test func preservesDistinctArtifactRootsForSiblingBundleKinds() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/CoreServices/Siri.app", in: root)
        try createLoadableBundle("System/Library/CoreServices/Siri.bundle", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(catalog.groups.map(\.selectionCandidate.identifier) == [
            "system-library:CoreServices/Siri.app",
            "system-library:CoreServices/Siri.bundle",
        ])
        #expect(catalog.groups.compactMap(\.primaryTarget?.artifactRoot.rawValue) == [
            "SystemLibrary/CoreServices/Siri.app",
            "SystemLibrary/CoreServices/Siri.bundle",
        ])
    }

    @Test func keepsSourceMetadataNeededByFutureExecutor() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/Frameworks/UIKit.framework", in: root)
        try createLoadableBundle("System/Library/PrivateFrameworks/SafariShared.framework", in: root)
        try createLoadableBundle("System/Library/PreferenceBundles/Foo.bundle", in: root)
        try writeFile("usr/lib/libobjc.A.dylib", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        let framework = try #require(
            catalog.groups.first { $0.selectionCandidate.displayName == "UIKit" }?.primaryTarget
        )
        guard case .framework(let frameworkSource) = framework.source else {
            Issue.record("expected framework source metadata")
            return
        }
        #expect(frameworkSource.location == .publicFramework)
        #expect(frameworkSource.bundleName == "UIKit.framework")
        #expect(frameworkSource.systemLibraryRelativePath == "Frameworks/UIKit.framework")

        let privateFramework = try #require(
            catalog.groups.first { $0.selectionCandidate.displayName == "SafariShared" }?.primaryTarget
        )
        guard case .framework(let privateFrameworkSource) = privateFramework.source else {
            Issue.record("expected framework source metadata")
            return
        }
        #expect(privateFrameworkSource.location == .privateFramework)
        #expect(privateFrameworkSource.bundleName == "SafariShared.framework")

        let systemBundle = try #require(
            catalog.groups.first {
                $0.selectionCandidate.displayName == "PreferenceBundles/Foo.bundle"
            }?.primaryTarget
        )
        guard case .systemLibraryBundle(let systemBundleSource) = systemBundle.source else {
            Issue.record("expected SystemLibrary source metadata")
            return
        }
        #expect(systemBundleSource.relativePath == "PreferenceBundles/Foo.bundle")
        #expect(systemBundleSource.bundleKind == .bundle)
        #expect(systemBundleSource.role == .topLevel)

        let dylib = try #require(
            catalog.groups.first {
                $0.selectionCandidate.displayName == "libobjc.A.dylib"
            }?.primaryTarget
        )
        guard case .usrLibDylib(let dylibSource) = dylib.source else {
            Issue.record("expected usr/lib source metadata")
            return
        }
        #expect(dylibSource.name == "libobjc.A.dylib")
    }

    @Test func discoversDirectorySymbolicLinksWithLogicalIdentities() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let framework = root.appendingPathComponent(
            "System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework",
            isDirectory: true
        )
        let xpcServices = framework.appendingPathComponent(
            "Versions/A/XPCServices/WebKitHelper.xpc",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: xpcServices, withIntermediateDirectories: true)
        try Data().write(to: framework.appendingPathComponent("Versions/A/WebKit"))
        try Data().write(to: xpcServices.appendingPathComponent("WebKitHelper"))
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Versions/Current").path,
            withDestinationPath: "A"
        )
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("XPCServices").path,
            withDestinationPath: "Versions/Current/XPCServices"
        )
        let frameworkLink = root.appendingPathComponent(
            "System/Library/Frameworks/WebKit.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: frameworkLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: frameworkLink.path,
            withDestinationPath: "../../../System/Cryptexes/OS/System/Library/Frameworks/WebKit.framework"
        )

        let bundle = root.appendingPathComponent(
            "System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphs.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent("CoreGlyphs"))
        let bundleLink = root.appendingPathComponent(
            "System/Library/CoreServices/CoreGlyphs.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: bundleLink.path,
            withDestinationPath: "../PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphs.bundle"
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        let frameworkGroup = try #require(
            catalog.groups.first { $0.selectionCandidate.displayName == "WebKit" }
        )
        let frameworkTarget = try #require(frameworkGroup.primaryTarget)
        let bundleTarget = try #require(
            catalog.groups.first {
                $0.selectionCandidate.displayName == "CoreServices/CoreGlyphs.bundle"
            }?.primaryTarget
        )

        #expect(frameworkTarget.candidate.identifier == "framework:WebKit.framework")
        #expect(frameworkTarget.artifactRoot.rawValue == "Frameworks/WebKit")
        #expect(frameworkTarget.inputPath == frameworkLink.path)
        #expect(frameworkTarget.runtimeInputPath == "/System/Library/Frameworks/WebKit.framework")
        #expect(frameworkGroup.childTargets.map(\.candidate.displayName) == [
            "Frameworks/WebKit.framework/XPCServices/WebKitHelper.xpc",
        ])
        #expect(bundleTarget.candidate.identifier == "system-library:CoreServices/CoreGlyphs.bundle")
        #expect(bundleTarget.artifactRoot.rawValue == "SystemLibrary/CoreServices/CoreGlyphs.bundle")
        #expect(bundleTarget.inputPath == bundleLink.path)
        #expect(bundleTarget.runtimeInputPath == "/System/Library/CoreServices/CoreGlyphs.bundle")
    }

    @Test func unreadableSystemLibrarySubtreeDoesNotAbortDiscovery() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/CoreServices/ControlCenter.app", in: root)
        try createDirectory("System/Library/Protected", in: root)
        let protectedDirectory = root.appendingPathComponent(
            "System/Library/Protected",
            isDirectory: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: protectedDirectory.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: protectedDirectory.path
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)

        #expect(
            catalog.groups.contains {
                $0.selectionCandidate.displayName == "CoreServices/ControlCenter.app"
            }
        )
    }

    @Test func permissionDeniedSystemLibraryEntryMetadataDoesNotAbortDiscovery() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/CoreServices/ControlCenter.app", in: root)
        let protectedName = "Protected-\(UUID().uuidString)"
        try createDirectory("System/Library/\(protectedName)", in: root)
        let fileManager = FailingAttributesFileManager(
            failingLastPathComponent: protectedName
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            fileManager: fileManager
        )

        #expect(
            catalog.groups.contains {
                $0.selectionCandidate.displayName == "CoreServices/ControlCenter.app"
            }
        )
    }

    @Test func nestedChildrenAreDiscoveredButExcludedFromResolverCandidates() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/Frameworks/Foo.framework", in: root)
        try createLoadableBundle(
            "System/Library/Frameworks/Foo.framework/XPCServices/FooHelper.xpc",
            in: root
        )
        try createLoadableBundle(
            "System/Library/Frameworks/Foo.framework/PlugIns/FooExtension.appex",
            in: root
        )
        try createLoadableBundle("System/Library/PreferenceBundles/Prefs.bundle", in: root)
        try createLoadableBundle(
            "System/Library/PreferenceBundles/Prefs.bundle/XPCServices/PrefsHelper.xpc",
            in: root
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(in: root)
        let framework = try #require(
            catalog.groups.first { $0.selectionCandidate.displayName == "Foo" }
        )
        let systemBundle = try #require(
            catalog.groups.first {
                $0.selectionCandidate.displayName == "PreferenceBundles/Prefs.bundle"
            }
        )

        #expect(framework.childTargets.map(\.candidate.displayName) == [
            "Frameworks/Foo.framework/PlugIns/FooExtension.appex",
            "Frameworks/Foo.framework/XPCServices/FooHelper.xpc",
        ])
        #expect(framework.childTargets.map(\.artifactRoot.rawValue) == [
            "Frameworks/Foo/PlugIns/FooExtension.appex",
            "Frameworks/Foo/XPCServices/FooHelper.xpc",
        ])
        #expect(systemBundle.childTargets.map(\.candidate.displayName) == [
            "PreferenceBundles/Prefs.bundle/XPCServices/PrefsHelper.xpc",
        ])
        #expect(systemBundle.childTargets.map(\.artifactRoot.rawValue) == [
            "SystemLibrary/PreferenceBundles/Prefs.bundle/XPCServices/PrefsHelper.xpc",
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

        try createLoadableBundle("System/Library/Frameworks/Foo.framework", in: root)
        try createLoadableBundle(
            "System/Library/Frameworks/Foo.framework/XPCServices/FooHelper.xpc",
            in: root
        )

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            includeNestedChildren: false
        )

        let framework = try #require(
            catalog.groups.first { $0.selectionCandidate.displayName == "Foo" }
        )
        #expect(framework.childTargets.isEmpty)
        #expect(catalog.allExecutionTargets.map(\.candidate.displayName) == ["Foo"])
    }

    @Test func nestedContainerIOFailureIsSurfaced() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/Frameworks/Foo.framework", in: root)
        try createDirectory("System/Library/Frameworks/Foo.framework/PlugIns", in: root)
        let plugInsURL = root.appendingPathComponent(
            "System/Library/Frameworks/Foo.framework/PlugIns",
            isDirectory: true
        )
        let fileManager = FailingContentsFileManager(failingPath: plugInsURL.path)

        do {
            _ = try PrivateHeaderGeneration.TargetDiscovery.discover(
                in: root,
                fileManager: fileManager
            )
            Issue.record("injected nested container I/O failure was swallowed")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(EACCES))
        }
    }

    @Test func resolverUsesDisplayNamesAndExactAliasesWithoutCategoryPartialSelection() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        try createLoadableBundle("System/Library/Frameworks/UIKit.framework", in: root)
        try createLoadableBundle("System/Library/PrivateFrameworks/UIKitServices.framework", in: root)
        try createLoadableBundle("System/Library/CoreServices/ControlCenter.app", in: root)
        try createLoadableBundle("System/Library/PreferenceBundles/Foo.bundle", in: root)
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

        #expect(catalog.groups.isEmpty)
        #expect(catalog.resolverCandidates.isEmpty)
    }

    @Test func discoversDirectUsrLibDylibsFromSharedCacheAndUnionsFilesystemEntries() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try writeFile("usr/lib/libFilesystem.dylib", in: root)
        try writeFile("usr/lib/libBoth.dylib", in: root)

        let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
            in: root,
            sharedCacheImagePaths: [
                "/usr/lib/libCacheOnly.dylib",
                "/usr/lib/libBoth.dylib",
                "/usr/lib/libCacheOnly.dylib",
                "/usr/lib/system/libNested.dylib",
                "/System/Library/Frameworks/Foo.framework/Foo",
                "/usr/lib/libNotDylib.tbd",
            ]
        )
        let dylibs = catalog.allExecutionTargets.filter { $0.candidate.kind == .usrLibDylib }

        #expect(dylibs.map(\.candidate.displayName) == [
            "libBoth.dylib",
            "libCacheOnly.dylib",
            "libFilesystem.dylib",
        ])
        #expect(dylibs.map(\.inputPath) == [
            root.appendingPathComponent("usr/lib/libBoth.dylib").path,
            "/usr/lib/libCacheOnly.dylib",
            root.appendingPathComponent("usr/lib/libFilesystem.dylib").path,
        ])
        #expect(dylibs.map(\.runtimeInputPath) == [
            "/usr/lib/libBoth.dylib",
            "/usr/lib/libCacheOnly.dylib",
            "/usr/lib/libFilesystem.dylib",
        ])
    }
}

private final class FailingContentsFileManager: FileManager, @unchecked Sendable {
    private let failingPath: String

    init(failingPath: String) {
        self.failingPath = URL(fileURLWithPath: failingPath).resolvingSymlinksInPath().path
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.resolvingSymlinksInPath().path == failingPath {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
}

private final class FailingAttributesFileManager: FileManager, @unchecked Sendable {
    private let failingLastPathComponent: String

    init(failingLastPathComponent: String) {
        self.failingLastPathComponent = failingLastPathComponent
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if URL(fileURLWithPath: path).lastPathComponent == failingLastPathComponent {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        return try super.attributesOfItem(atPath: path)
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

private func createLoadableBundle(
    _ relativePath: String,
    executableName: String? = nil,
    executableRelativePath: String? = nil,
    in root: URL
) throws {
    let bundleURL = root.appendingPathComponent(relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let name = executableName ?? bundleURL.deletingPathExtension().lastPathComponent
    let executablePath = executableRelativePath ?? name
    try writeFile(relativePath + "/" + executablePath, in: root)
}

private func writeBundleInfo(
    _ relativeBundlePath: String,
    executableName: String,
    infoRelativePath: String = "Info.plist",
    packageType: String = "FMWK",
    in root: URL
) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": "com.example.\(relativeBundlePath.replacingOccurrences(of: "/", with: "."))",
            "CFBundlePackageType": packageType,
        ],
        format: .xml,
        options: 0
    )
    let infoURL = root.appendingPathComponent(
        relativeBundlePath + "/" + infoRelativePath,
        isDirectory: false
    )
    try FileManager.default.createDirectory(
        at: infoURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: infoURL)
}

private func writeFile(_ relativePath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: url)
}
