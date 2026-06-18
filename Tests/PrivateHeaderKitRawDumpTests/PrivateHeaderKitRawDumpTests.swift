import Foundation
import Testing
#if canImport(PrivateHeaderKitRawDumpRuntimeObjC)
import PrivateHeaderKitRawDumpRuntimeObjC
#endif
@testable import PrivateHeaderKitRawDumpCore
import PrivateHeaderKitTestSupport

#if canImport(Darwin)
import Darwin
#endif

private struct FakeFileManager: FileExistenceChecking {
    let existing: Set<String>

    func fileExists(atPath: String) -> Bool {
        existing.contains(atPath)
    }
}

@Suite
struct PrivateHeaderKitRawDumpArgumentTests {
    @Test func parseArgumentsPopulatesOptions() {
        let args = [
            "-o", "/tmp/out",
            "-r",
            "-b",
            "-h",
            "-s",
            "-j", "OnlyClass",
            "-c",
            "-D",
            "-R",
            "/tmp/input"
        ]

        let parsed = parseArguments(args, environment: [:])

        #expect(parsed != nil)
        #expect(parsed?.inputPath == "/tmp/input")
        #expect(parsed?.options.outputDir.path == "/tmp/out")
        #expect(parsed?.options.recursive == true)
        #expect(parsed?.options.buildOriginalDirs == true)
        #expect(parsed?.options.addHeadersFolder == true)
        #expect(parsed?.options.skipExisting == true)
        #expect(parsed?.options.onlyOneClass == "OnlyClass")
        #expect(parsed?.options.useSharedCache == true)
        #expect(parsed?.options.verbose == true)
        #expect(parsed?.options.useRuntimeFallback == true)
    }

    @Test func parseArgumentsIgnoresUnknownFlags() {
        let parsed = parseArguments(["-Z", "/tmp/input"], environment: [:])
        #expect(parsed?.inputPath == "/tmp/input")
    }

    @Test func parseArgumentsReturnsNilWithoutInput() {
        let parsed = parseArguments(["-r"], environment: [:])
        #expect(parsed == nil)
    }

    @Test func parseArgumentsHelpCallsExit() {
        var exitCode: Int32?
        var didPrint = false
        let parsed = parseArguments(
            ["--help"],
            environment: [:],
            exitHandler: { code in exitCode = code },
            printUsageHandler: { didPrint = true }
        )

        #expect(parsed == nil)
        #expect(exitCode == 0)
        #expect(didPrint == true)
    }
}

@Suite
struct PrivateHeaderKitRawDumpEnvironmentTests {
    @Test func resolvesRuntimeFallbackFromInjectedEnvironment() {
        #expect(shouldUseRuntimeFallback(environment: ["PH_RUNTIME_ROOT": "/tmp/runtime"]) == true)
        #expect(shouldUseRuntimeFallback(environment: ["SIMCTL_CHILD_PH_RUNTIME_ROOT": "/tmp/runtime"]) == true)
        #expect(shouldUseRuntimeFallback(environment: [:]) == false)
    }

    @Test func resolvesLoggingAndProfilingFromInjectedEnvironment() {
        #expect(shouldLogSkippedClasses(environment: ["PH_VERBOSE_SKIP": "1"]) == true)
        #expect(shouldLogSkippedClasses(environment: ["PH_VERBOSE_SKIP": "0"]) == false)
        #expect(shouldProfile(environment: ["PH_PROFILE": "1"]) == true)
        #expect(shouldProfile(environment: ["SIMCTL_CHILD_PH_PROFILE": "1"]) == true)
        #expect(shouldProfile(environment: ["PH_PROFILE": "0"]) == false)
        #expect(shouldLogSwiftEvents(environment: ["PH_SWIFT_EVENTS": "1"]) == true)
        #expect(shouldLogSwiftEvents(environment: ["SIMCTL_CHILD_PH_SWIFT_EVENTS": "1"]) == true)
        #expect(shouldLogSwiftEvents(environment: ["PH_SWIFT_EVENTS": "0"]) == false)
    }
}

@Suite
struct PrivateHeaderKitRawDumpPathTests {
    @Test func resolveRuntimeURLUsesInjectedRuntimeRootAndFileManager() {
        let runtimeRoot = "/Runtime"
        let inputPath = "/System/Library/Frameworks/Foo.framework/Foo"
        let candidate = "/Runtime/System/Library/Frameworks/Foo.framework/Foo"
        let fake = FakeFileManager(existing: [candidate])

        let resolved = resolveRuntimeURL(
            URL(fileURLWithPath: inputPath),
            environment: ["PH_RUNTIME_ROOT": runtimeRoot],
            fileManager: fake
        )
        #expect(resolved.path == candidate)

        let unresolved = resolveRuntimeURL(
            URL(fileURLWithPath: "/System/Library/Frameworks/Bar.framework/Bar"),
            environment: ["PH_RUNTIME_ROOT": runtimeRoot],
            fileManager: fake
        )
        #expect(unresolved.path == "/System/Library/Frameworks/Bar.framework/Bar")
    }

    @Test func stripRuntimeRootRemovesInjectedPrefix() {
        let stripped = stripRuntimeRoot(
            from: "/Runtime/System/Library/Frameworks/Foo.framework/Foo",
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )
        #expect(stripped == "/System/Library/Frameworks/Foo.framework/Foo")
    }

    @Test func normalizePathCollapsesSlashes() {
        #expect(normalizePath("/tmp//foo///bar") == "/tmp/foo/bar")
    }

    @Test func normalizedCacheImagePathsIncludesSystemPaths() {
        let paths = normalizedCacheImagePaths(
            for: "/Runtime/System/Library/Frameworks/Foo.framework/Foo",
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )

        #expect(paths.first == "/Runtime/System/Library/Frameworks/Foo.framework/Foo")
        #expect(paths.contains("/System/Library/Frameworks/Foo.framework/Foo"))
        #expect(paths.contains("/Runtime/System/Library/Frameworks/Foo.framework/Versions/Current/Foo"))
        #expect(paths.contains("/Runtime/System/Library/Frameworks/Foo.framework/Versions/A/Foo"))
        #expect(Set(paths).count == paths.count)

        let usrPaths = normalizedCacheImagePaths(
            for: "/Runtime/usr/lib/libobjc.A.dylib",
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )
        #expect(usrPaths.contains("/usr/lib/libobjc.A.dylib"))
    }

    #if canImport(ObjectiveC)
    @Test func runtimeFallbackTargetImagePathsIncludeVersionedCandidates() {
        let targets = runtimeFallbackTargetImagePaths(
            for: "/Runtime/System/Library/Frameworks/Foo.framework/Foo",
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )

        #expect(targets.contains("/System/Library/Frameworks/Foo.framework/Foo"))
        #expect(targets.contains("/System/Library/Frameworks/Foo.framework/Versions/Current/Foo"))
        #expect(targets.contains("/System/Library/Frameworks/Foo.framework/Versions/A/Foo"))
    }
    #endif

    @Test func sharedCachePathUsesInjectedFileManagerAndEnvironment() {
        let simCache = "/Runtime/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64e"
        let fake = FakeFileManager(existing: [simCache])
        let resolved = sharedCachePath(fileManager: fake, environment: ["PH_RUNTIME_ROOT": "/Runtime"])
        #expect(resolved == simCache)

        let empty = FakeFileManager(existing: [])
        let fallback = sharedCachePath(fileManager: empty, environment: [:])
        #expect(fallback == "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e")
    }
}

@Suite
struct PrivateHeaderKitRawDumpBundlePathTests {
    @Test func writeDirectoryBuildsBundlePaths() {
        let outputRoot = URL(fileURLWithPath: "/tmp/out")
        var options = DumpOptions(outputDir: outputRoot)
        options.buildOriginalDirs = true
        options.addHeadersFolder = true

        let result = writeDirectory(
            for: "/System/Library/Frameworks/Foo.framework/Foo",
            outputRoot: outputRoot,
            options: options
        )
        #expect(result.path == "/tmp/out/System/Library/Frameworks/Foo.framework/Headers")

        options.addHeadersFolder = false
        let resultNoHeaders = writeDirectory(
            for: "/usr/lib/libobjc.A.dylib",
            outputRoot: outputRoot,
            options: options
        )
        #expect(resultNoHeaders.path == "/tmp/out/usr/lib/libobjc.A.dylib")
    }

    @Test func writeDirectoryReturnsRootWhenDisabled() {
        let outputRoot = URL(fileURLWithPath: "/tmp/out")
        var options = DumpOptions(outputDir: outputRoot)
        options.buildOriginalDirs = false
        let result = writeDirectory(
            for: "/System/Library/Frameworks/Foo.framework/Foo",
            outputRoot: outputRoot,
            options: options
        )
        #expect(result.path == outputRoot.path)
    }

    @Test func isBundleDirectoryChecksExtensions() {
        #expect(isBundleDirectory(URL(fileURLWithPath: "/tmp/Foo.framework", isDirectory: true)) == true)
        #expect(isBundleDirectory(URL(fileURLWithPath: "/tmp/Foo.app", isDirectory: true)) == true)
        #expect(isBundleDirectory(URL(fileURLWithPath: "/tmp/Foo.bundle", isDirectory: true)) == true)
        #expect(isBundleDirectory(URL(fileURLWithPath: "/tmp/Foo.xpc", isDirectory: true)) == true)
        #expect(isBundleDirectory(URL(fileURLWithPath: "/tmp/Foo.appex", isDirectory: true)) == true)
        #expect(isBundleDirectory(URL(fileURLWithPath: "/tmp/Foo.framework", isDirectory: false)) == false)
    }

    @Test func isBundleDirectoryTreatsSymlinkToDirectoryAsBundle() throws {
        let dirs = try makeTemporaryTestDirectories()
        let realBundle = dirs.root.appendingPathComponent("Foo.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: realBundle, withIntermediateDirectories: true)

        let linkPath = dirs.root.appendingPathComponent("Link.framework").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realBundle.path)

        let linkURL = URL(fileURLWithPath: linkPath)
        #expect(linkURL.hasDirectoryPath == false)
        #expect(isBundleDirectory(linkURL) == true)
    }

    @Test func resolveBundleExecutableURLUsesInjectedFileManager() {
        let bundleURL = URL(fileURLWithPath: "/tmp/Foo.framework", isDirectory: true)
        let candidate = bundleURL.appendingPathComponent("Versions/A/Foo")
        let fake = FakeFileManager(existing: [candidate.path])

        let resolved = resolveBundleExecutableURL(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in nil }
        )
        #expect(resolved?.path == candidate.path)

        let explicit = URL(fileURLWithPath: "/tmp/BundleExec")
        let resolvedExplicit = resolveBundleExecutableURL(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in explicit }
        )
        #expect(resolvedExplicit?.path == explicit.path)
    }

    @Test func resolveBundleExecutableURLRebasesBundleExecutableWhenPossible() {
        let bundleURL = URL(fileURLWithPath: "/System/Library/Frameworks/SafariServices.framework", isDirectory: true)
        let resolvedExec = URL(fileURLWithPath: "/System/Cryptexes/OS/System/Library/Frameworks/SafariServices.framework/SafariServices")
        let expectedRebased = bundleURL.appendingPathComponent("SafariServices")
        let fake = FakeFileManager(existing: [expectedRebased.path])

        let result = resolveBundleExecutableURL(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in resolvedExec }
        )
        #expect(result?.path == expectedRebased.path)
    }

    @Test func resolveBundleExecutableURLFallsBackToCanonicalPathForCacheOnlyBundles() {
        let bundleURL = URL(fileURLWithPath: "/tmp/Foo.framework", isDirectory: true)
        let fake = FakeFileManager(existing: [])

        let resolved = resolveBundleExecutableURL(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in nil }
        )

        #expect(resolved?.path == "/tmp/Foo.framework/Foo")
    }

    @Test func resolveBundleExecutableURLResolvesXPCAndAppExtensionCandidates() throws {
        let dirs = try makeTemporaryTestDirectories()

        let xpcURL = dirs.root.appendingPathComponent("Foo.xpc", isDirectory: true)
        try FileManager.default.createDirectory(at: xpcURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: xpcURL.appendingPathComponent("Foo").path, contents: Data())

        let xpcResolved = resolveBundleExecutableURL(
            xpcURL,
            fileManager: FileManager.default,
            bundleExecutableURL: { _ in nil }
        )
        #expect(xpcResolved?.path == xpcURL.appendingPathComponent("Foo").path)

        let appexURL = dirs.root.appendingPathComponent("Bar.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appexURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: appexURL.appendingPathComponent("Bar").path, contents: Data())

        let appexResolved = resolveBundleExecutableURL(
            appexURL,
            fileManager: FileManager.default,
            bundleExecutableURL: { _ in nil }
        )
        #expect(appexResolved?.path == appexURL.appendingPathComponent("Bar").path)
    }
}

@Suite
struct PrivateHeaderKitRawDumpObjCHeaderNameTests {
    @Test func isSaneObjCTypeNameRejectsReplacementAndControl() {
        #expect(isSaneObjCTypeName("ASAuthorization") == true)
        #expect(isSaneObjCTypeName("") == false)
        #expect(isSaneObjCTypeName("Bad\u{000C}") == false)
        #expect(isSaneObjCTypeName("\u{FFFD}") == false)
    }

    @Test func resolveObjCHeaderEntriesLeavesNonCollidingNamesUnchanged() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            ObjCHeaderEntry(symbolKind: .class, baseName: "FooHeader", headerString: "@interface FooHeader\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)

        #expect(resolved.count == 1)
        #expect(resolved.first?.fileName == "FooHeader.h")
        #expect(resolved.first?.hadNameCollision == false)
    }

    @Test func resolveObjCHeaderEntriesDisambiguatesCaseOnlyCollisions() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            ObjCHeaderEntry(symbolKind: .class, baseName: "MTRBaseClusterWakeOnLAN", headerString: "@interface A\n@end\n"),
            ObjCHeaderEntry(symbolKind: .class, baseName: "MTRBaseClusterWakeOnLan", headerString: "@interface B\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)
        let fileNames = Set(resolved.map(\.fileName))

        #expect(fileNames.count == 2)
        #expect(resolved.allSatisfy { $0.hadNameCollision })
        #expect(resolved.contains { $0.baseName == "MTRBaseClusterWakeOnLAN" && $0.fileName.hasPrefix("MTRBaseClusterWakeOnLAN~") })
        #expect(resolved.contains { $0.baseName == "MTRBaseClusterWakeOnLan" && $0.fileName.hasPrefix("MTRBaseClusterWakeOnLan~") })
    }

    @Test func resolveObjCHeaderEntriesDisambiguatesAcrossSymbolKinds() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            ObjCHeaderEntry(symbolKind: .class, baseName: "SharedHeaderName", headerString: "@interface SharedHeaderName\n@end\n"),
            ObjCHeaderEntry(symbolKind: .protocol, baseName: "SharedHeaderName", headerString: "@protocol SharedHeaderName\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)
        let fileNames = Set(resolved.map(\.fileName))

        #expect(fileNames.count == 2)
        #expect(resolved.allSatisfy { $0.hadNameCollision })
        #expect(resolved.contains { $0.symbolKind == .class && $0.fileName.hasPrefix("SharedHeaderName~") })
        #expect(resolved.contains { $0.symbolKind == .protocol && $0.fileName.hasPrefix("SharedHeaderName~") })
    }

    @Test func resolveObjCHeaderEntriesKeepsCollisionSuffixWithinPathLimit() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let longBaseName = String(repeating: "VeryLongHeaderName", count: 20)
        let entries = [
            ObjCHeaderEntry(symbolKind: .class, baseName: longBaseName, headerString: "@interface LongHeader\n@end\n"),
            ObjCHeaderEntry(symbolKind: .protocol, baseName: longBaseName, headerString: "@protocol LongHeader\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)

        #expect(Set(resolved.map(\.fileName)).count == 2)
        #expect(resolved.allSatisfy { $0.fileName.utf8.count <= 255 })
        #expect(resolved.allSatisfy { $0.fileName.hasSuffix(".h") })
    }

    @Test func resolveObjCHeaderEntriesIsStableAcrossRuns() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            ObjCHeaderEntry(symbolKind: .protocol, baseName: "SharedHeaderName", headerString: "@protocol SharedHeaderName\n@end\n"),
            ObjCHeaderEntry(symbolKind: .class, baseName: "MTRBaseClusterWakeOnLan", headerString: "@interface MTRBaseClusterWakeOnLan\n@end\n"),
            ObjCHeaderEntry(symbolKind: .class, baseName: "MTRBaseClusterWakeOnLAN", headerString: "@interface MTRBaseClusterWakeOnLAN\n@end\n")
        ]

        let first = resolveObjCHeaderEntries(entries, options: options)
        let second = resolveObjCHeaderEntries(Array(entries.reversed()), options: options)

        #expect(first == second)
    }
}

@Suite
struct PrivateHeaderKitRawDumpSwiftInterfaceTests {
    @Test func shouldSkipSwiftInterfaceUsesInjectedFileExistence() {
        let outputDir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let outputPath = outputDir.appendingPathComponent("FixtureSkip.swiftinterface").path
        let fake = FakeFileManager(existing: [outputPath])

        var options = DumpOptions(outputDir: outputDir)
        options.skipExisting = true

        #expect(shouldSkipSwiftInterface(
            imagePath: "/tmp/FixtureSkip",
            outputDir: outputDir,
            options: options,
            fileManager: fake
        ) == true)

        options.skipExisting = false
        #expect(shouldSkipSwiftInterface(
            imagePath: "/tmp/FixtureSkip",
            outputDir: outputDir,
            options: options,
            fileManager: fake
        ) == false)
    }

    @Test func dumpSwiftInterfaceSkipsExistingFileWithoutBuilding() async throws {
        let dirs = try makeTemporaryTestDirectories()
        let outputDir = dirs.root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("FixtureSkip.swiftinterface")
        try "sentinel".write(to: outputURL, atomically: true, encoding: .utf8)

        var options = DumpOptions(outputDir: outputDir)
        options.skipExisting = true
        var buildCount = 0

        try await dumpSwiftInterface(
            imagePath: "/tmp/FixtureSkip",
            outputDir: outputDir,
            options: options,
            fileManager: FileManager.default,
            buildInterface: {
                buildCount += 1
                return "public struct Foo {}"
            }
        )

        #expect(buildCount == 0)
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "sentinel")
    }

    @Test func dumpSwiftInterfaceSkipsEmptyOutput() async throws {
        let dirs = try makeTemporaryTestDirectories()
        let outputDir = dirs.root.appendingPathComponent("out", isDirectory: true)
        var options = DumpOptions(outputDir: outputDir)
        options.skipExisting = false

        try await dumpSwiftInterface(
            imagePath: "/tmp/FixtureEmpty",
            outputDir: outputDir,
            options: options,
            fileManager: FileManager.default,
            buildInterface: { " \n" }
        )

        let outputURL = outputDir.appendingPathComponent("FixtureEmpty.swiftinterface")
        #expect(FileManager.default.fileExists(atPath: outputURL.path) == false)
    }

    @Test func dumpSwiftInterfaceWritesOutput() async throws {
        let dirs = try makeTemporaryTestDirectories()
        let outputDir = dirs.root.appendingPathComponent("out", isDirectory: true)
        let options = DumpOptions(outputDir: outputDir)

        try await dumpSwiftInterface(
            imagePath: "/tmp/FixtureWrite",
            outputDir: outputDir,
            options: options,
            fileManager: FileManager.default,
            buildInterface: { "public struct Foo {}" }
        )

        let outputURL = outputDir.appendingPathComponent("FixtureWrite.swiftinterface")
        #expect(FileManager.default.fileExists(atPath: outputURL.path) == true)
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "public struct Foo {}")
    }
}

@Suite
struct PrivateHeaderKitRawDumpRuntimeInspectorTests {
    #if canImport(ObjectiveC) && canImport(PrivateHeaderKitRawDumpRuntimeObjC)
    @Test func runtimeInspectorBuildsNSObjectSnapshot() {
        var failedStage: NSString?
        let snapshot = PHRuntimeObjCInspector.snapshot(for: NSObject.self, failedStage: &failedStage)
        #expect(snapshot != nil)
        #expect(failedStage == nil)
        #expect(snapshot?.name == "NSObject")
    }
    #endif
}
