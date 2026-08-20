import Foundation
import Dispatch
import MachOKit
@_spi(Core) @_spi(Diagnostics) @testable import MachOObjCSection
import PrivateHeaderKitHelperProtocol
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

private enum FakeRawMachOLoadError: Error, CustomStringConvertible {
    case invalidFixture

    var description: String {
        "invalid fixture"
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
            "--expected-cache-uuid", "11111111-2222-3333-4444-555555555555",
            "-D",
            "-R",
            "--diagnostics-report", "/tmp/report.json",
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
        #expect(parsed?.options.expectedCacheUUID == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(parsed?.options.verbose == true)
        #expect(parsed?.options.useRuntimeFallback == true)
        #expect(parsed?.options.diagnosticsReportURL?.path == "/tmp/report.json")
    }

    @Test func parseArgumentsIgnoresUnknownFlags() {
        let parsed = parseArguments(["-Z", "/tmp/input"], environment: [:])
        #expect(parsed?.inputPath == "/tmp/input")
    }

    @Test func parseArgumentsReturnsNilWithoutInput() {
        let parsed = parseArguments(["-r"], environment: [:])
        #expect(parsed == nil)
    }

    @Test func sharedCacheArgumentsRequireValidExpectedUUID() {
        #expect(parseArguments(["-c", "/tmp/input"], environment: [:]) == nil)
        #expect(
            parseArguments(
                ["-c", "--expected-cache-uuid", "not-a-uuid", "/tmp/input"],
                environment: [:]
            ) == nil
        )
        #expect(
            parseArguments(
                ["--expected-cache-uuid", "11111111-2222-3333-4444-555555555555", "/tmp/input"],
                environment: [:]
            ) == nil
        )
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
struct PrivateHeaderKitRawDumpObjCPolicyTests {
    @Test func headerOwnersUseBoundedDirectProtocolNames() {
        #expect(rawDumpObjCProtocolReadPolicy(for: .class) == .headerDump)
        #expect(rawDumpObjCProtocolReadPolicy(for: .category) == .headerDump)
        assertDirectProtocolNames(rawDumpObjCInfoOptions(for: .class).protocolInfoOptions)
        assertDirectProtocolNames(rawDumpObjCInfoOptions(for: .category).protocolInfoOptions)
    }

    @Test func topLevelProtocolsUseBoundedDirectProtocolNames() {
        #expect(rawDumpObjCProtocolReadPolicy(for: .protocol) == .directProtocolNames)
        assertDirectProtocolNames(rawDumpObjCProtocolInfoOptions(for: .protocol))
    }

    @Test func typedDiagnosticsAreBoundedFormattedAndWrittenThroughTheWireCodec() throws {
#if canImport(Darwin)
        let fixture = try InvalidIdentityProtocolFixture(count: 257)
        let accumulator = RawDumpObjCDiagnosticsAccumulator()
        for objcProtocol in fixture.protocols {
            accumulator.append(contentsOf: objcProtocol.readInfo(in: fixture.machO).diagnostics)
        }
        let report = accumulator.report
        #expect(
            report.diagnostics.count
                == PrivateHeaderKitRawDumpDiagnosticsReport.maximumDiagnosticCount
        )
        #expect(report.omittedDiagnosticCount == 1)
        #expect(report.diagnostics.allSatisfy { $0.owner.hasPrefix("Objective-C protocol") })
        #expect(
            report.diagnostics.allSatisfy {
                $0.degradation.contains("has no stable identity")
            }
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrivateHeaderKitRawDumpDiagnosticTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("diagnostics.json")
        try writeRawDumpDiagnosticsReport(report, to: reportURL)
        let decoded = try JSONDecoder().decode(
            PrivateHeaderKitRawDumpDiagnosticsReport.self,
            from: Data(contentsOf: reportURL)
        )
        #expect(decoded == report)
#endif
    }

    private func assertDirectProtocolNames(_ options: ObjCProtocolInfoOptions) {
        switch options.traversal {
        case .depth(let depth):
            #expect(depth == 1)
        case .recursive:
            Issue.record("raw header dumping must not recursively expand adopted protocols")
        }
        switch options.referencedProtocolInfo {
        case .nameOnly:
            break
        case .full:
            Issue.record("raw header dumping only needs adopted protocol names")
        }
    }
}

#if canImport(Darwin)
private final class InvalidIdentityProtocolFixture {
    let machO: MachOFile
    let protocols: [ObjCProtocol64]
    private let url: URL

    init(count: Int) throws {
        let fileSize = 0x20_000
        let vmAddress: UInt64 = 0x1_0000_0000
        let nameBaseOffset = 0x1_000
        let nameStride = 0x40
        var data = Data(count: fileSize)

        var header = mach_header_64()
        header.magic = UInt32(MH_MAGIC_64)
        header.cputype = CPU_TYPE_ARM64
        header.cpusubtype = CPU_SUBTYPE_ARM64_ALL
        header.filetype = UInt32(MH_DYLIB)
        header.ncmds = 1
        header.sizeofcmds = UInt32(MemoryLayout<segment_command_64>.size)
        data.storeValue(header, at: 0)

        var segment = segment_command_64()
        segment.cmd = UInt32(LC_SEGMENT_64)
        segment.cmdsize = UInt32(MemoryLayout<segment_command_64>.size)
        segment.vmaddr = vmAddress
        segment.vmsize = UInt64(fileSize)
        segment.filesize = UInt64(fileSize)
        segment.maxprot = VM_PROT_READ
        segment.initprot = VM_PROT_READ
        data.storeValue(segment, at: MemoryLayout<mach_header_64>.size)

        var protocols: [ObjCProtocol64] = []
        protocols.reserveCapacity(count)
        for index in 0..<count {
            let nameOffset = nameBaseOffset + index * nameStride
            data.storeCString("P\(String(format: "%03d", index))", at: nameOffset)
            let layout = ObjCProtocol64.Layout(
                isa: 0,
                mangledName: vmAddress + UInt64(nameOffset),
                protocols: 0,
                instanceMethods: 0,
                classMethods: 0,
                optionalInstanceMethods: 0,
                optionalClassMethods: 0,
                instanceProperties: 0,
                size: UInt32(MemoryLayout<ObjCProtocol64.Layout>.size),
                flags: 0,
                _extendedMethodTypes: 0,
                _demangledName: 0,
                _classProperties: 0
            )
            protocols.append(ObjCProtocol64(layout: layout, offset: -(index + 1)))
        }

        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrivateHeaderKitInvalidIdentityProtocol-\(UUID().uuidString)"
        )
        try data.write(to: url)
        machO = try MachOFile(url: url)
        self.protocols = protocols
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension Data {
    mutating func storeValue<Value>(_ value: Value, at offset: Int) {
        Swift.withUnsafeBytes(of: value) { bytes in
            replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
    }

    mutating func storeCString(_ value: String, at offset: Int) {
        let bytes = Array(value.utf8) + [0]
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
#endif

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
        #expect(paths.contains("/System/Library/Frameworks/Foo.framework/Versions/A/Foo"))
        #expect(paths.contains("/Runtime/System/Library/Frameworks/Foo.framework/Versions/Current/Foo"))
        #expect(paths.contains("/Runtime/System/Library/Frameworks/Foo.framework/Versions/A/Foo"))
        #expect(Set(paths).count == paths.count)

        let nestedPaths = normalizedCacheImagePaths(
            for: "/Runtime/System/Library/Frameworks/Foo.framework/XPCServices/Foo.xpc/Foo",
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )
        #expect(
            nestedPaths.contains(
                "/System/Library/Frameworks/Foo.framework/XPCServices/Foo.xpc/Foo"
            )
        )
        #expect(
            !nestedPaths.contains(
                "/System/Library/Frameworks/Foo.framework/Versions/A/Foo"
            )
        )

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

    @Test func loadedRuntimeImageIdentityMatchesCacheOnlyRootedIdentity() {
        let logicalPath = "/System/Library/Frameworks/Foo.framework/Foo"
        let runtimePath = "/Runtime/System/Library/Frameworks/Foo.framework/Foo"

        let matched = matchingLoadedRuntimeImageIdentity(
            for: logicalPath,
            loadedImageNames: [
                "/Runtime/System/Library/Frameworks/Other.framework/Other",
                runtimePath,
            ],
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )

        #expect(matched?.path == runtimePath)
    }

    @Test func loadedRuntimeImageIdentityMatchesVersionedFrameworkIdentity() {
        let runtimePath = "/Runtime/System/Library/Frameworks/Foo.framework/Versions/A/Foo"

        let matched = matchingLoadedRuntimeImageIdentity(
            for: "/System/Library/Frameworks/Foo.framework/Foo",
            loadedImageNames: [runtimePath],
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )

        #expect(matched?.path == runtimePath)
    }

    @Test func loadedRuntimeImageIdentityDoesNotPromoteNestedChildToParent() {
        let childPath = "/System/Library/Frameworks/Foo.framework/XPCServices/Child.xpc/Child"
        let loadedChildPath = "/Runtime" + childPath

        #expect(
            matchingLoadedRuntimeImageIdentity(
                for: childPath,
                loadedImageNames: [
                    "/Runtime/System/Library/Frameworks/Foo.framework/Foo",
                    loadedChildPath,
                ],
                environment: ["PH_RUNTIME_ROOT": "/Runtime"]
            )?.path == loadedChildPath
        )
        #expect(
            matchingLoadedRuntimeImageIdentity(
                for: childPath,
                loadedImageNames: [
                    "/Runtime/System/Library/Frameworks/Foo.framework/Foo"
                ],
                environment: ["PH_RUNTIME_ROOT": "/Runtime"]
            ) == nil
        )
    }

    @Test func loadedRuntimeImageIdentityRejectsAmbiguousRuntimeIdentities() {
        let logicalPath = "/System/Library/Frameworks/Foo.framework/Foo"

        let matched = matchingLoadedRuntimeImageIdentity(
            for: logicalPath,
            loadedImageNames: [
                "/Runtime/System/Library/Frameworks/Foo.framework/Foo",
                logicalPath,
            ],
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )

        #expect(matched == nil)
    }

    @Test func loadedRuntimeImageIdentityRequiresTheActiveRuntimeRootBoundary() {
        let logicalPath = "/System/Library/Frameworks/Foo.framework/Foo"

        #expect(
            matchingLoadedRuntimeImageIdentity(
                for: logicalPath,
                loadedImageNames: [
                    "/Runtime2/System/Library/Frameworks/Foo.framework/Foo",
                    "/tmp/payload/System/Library/Frameworks/Foo.framework/Foo",
                ],
                environment: ["PH_RUNTIME_ROOT": "/Runtime"]
            ) == nil
        )
    }

    @Test func loadedRuntimeImageIdentityDeduplicatesIdenticalInventoryNames() {
        let runtimePath = "/Runtime/System/Library/Frameworks/Foo.framework/Foo"

        let matched = matchingLoadedRuntimeImageIdentity(
            for: "/System/Library/Frameworks/Foo.framework/Foo",
            loadedImageNames: [runtimePath, runtimePath],
            environment: ["PH_RUNTIME_ROOT": "/Runtime"]
        )

        #expect(matched?.path == runtimePath)
    }

    @Test func loadedRuntimeImageIdentityAcceptsLexicalAndResolvedRuntimeRoots() throws {
        let dirs = try makeTemporaryTestDirectories()
        defer { try? FileManager.default.removeItem(at: dirs.root) }
        let canonicalRoot = dirs.root.appendingPathComponent("CanonicalRuntime", isDirectory: true)
        let aliasRoot = dirs.root.appendingPathComponent("RuntimeAlias", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: canonicalRoot
        )
        let logicalPath = "/System/Library/Frameworks/Foo.framework/Foo"

        let lexicalMatch = matchingLoadedRuntimeImageIdentity(
            for: logicalPath,
            loadedImageNames: [aliasRoot.path + logicalPath],
            environment: ["PH_RUNTIME_ROOT": aliasRoot.path]
        )
        let resolvedMatch = matchingLoadedRuntimeImageIdentity(
            for: logicalPath,
            loadedImageNames: [canonicalRoot.path + logicalPath],
            environment: ["PH_RUNTIME_ROOT": aliasRoot.path]
        )

        #expect(lexicalMatch?.path == aliasRoot.path + logicalPath)
        #expect(resolvedMatch?.path == canonicalRoot.path + logicalPath)
    }

    @Test func runtimeRootedImageIdentityRejectsLogicalAndForeignLoadPaths() {
        let logicalPath = "/System/Library/Frameworks/Foo.framework/Foo"
        let onDiskPath = "/Runtime" + logicalPath
        let onDiskFiles = FakeFileManager(existing: [onDiskPath])
        let onDiskIdentity = runtimeRootedImageIdentity(
            loadPath: onDiskPath,
            environment: ["PH_RUNTIME_ROOT": "/Runtime"],
            fileManager: onDiskFiles
        )

        #expect(onDiskIdentity?.path == onDiskPath)
        #expect(
            runtimeRootedImageIdentity(
                loadPath: logicalPath,
                environment: ["PH_RUNTIME_ROOT": "/Runtime"],
                fileManager: onDiskFiles
            ) == nil
        )
        #expect(
            runtimeRootedImageIdentity(
                loadPath: logicalPath,
                environment: ["PH_RUNTIME_ROOT": "/"],
                fileManager: FakeFileManager(existing: [logicalPath])
            )?.path == logicalPath
        )
        #expect(
            runtimeRootedImageIdentity(
                loadPath: "/Runtime2" + logicalPath,
                environment: ["PH_RUNTIME_ROOT": "/Runtime"],
                fileManager: FakeFileManager(existing: ["/Runtime2" + logicalPath])
            ) == nil
        )
    }
    #endif

}

@Suite
struct PrivateHeaderKitRawDumpSharedCacheTests {
    @Test func cacheLookupSelectsTheExactLightweightDescriptor() throws {
        let headers = UnsafeMutablePointer<mach_header>.allocate(capacity: 2)
        headers.initialize(
            repeating: mach_header(
                magic: 0,
                cputype: 0,
                cpusubtype: 0,
                filetype: 0,
                ncmds: 0,
                sizeofcmds: 0,
                flags: 0
            ),
            count: 2
        )
        defer {
            headers.deinitialize(count: 2)
            headers.deallocate()
        }
        let firstHeader = UnsafePointer(headers)
        let secondHeader = UnsafePointer(headers.advanced(by: 1))
        let uuid = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let access = DyldSharedCacheAccess(
            cacheUUID: uuid,
            images: [
                LoadedDyldCacheImage(
                    logicalPath: "/usr/lib/libz.dylib",
                    headerPointer: firstHeader
                ),
                LoadedDyldCacheImage(
                    logicalPath: "/usr/lib/libexact.dylib",
                    headerPointer: secondHeader
                ),
                LoadedDyldCacheImage(
                    logicalPath: "/usr/lib/libexact.dylib",
                    headerPointer: firstHeader
                ),
            ]
        )

        let inventory = try makeSharedCacheInventory(access: access)
        #expect(inventory.imagePaths == [
            "/usr/lib/libexact.dylib",
            "/usr/lib/libz.dylib",
        ])
        #expect(access.image(matching: ["libexact.dylib"]) == nil)

        let matched = try #require(
            access.image(matching: ["/usr/lib/libexact.dylib"])
        )
        #expect(matched.headerPointer == secondHeader)
        #expect(matched.machO.ptr == UnsafeRawPointer(secondHeader))
    }

    @Test func loadedImageAddressValidationUsesCheckedSlideArithmetic() throws {
        let path = "/usr/lib/libinvalid.dylib"

        #expect(throws: DyldSharedCacheAccessError.invalidImageAddress(path: path)) {
            _ = try validatedLoadedImageHeaderPointer(
                address: UInt64.max,
                slide: 0,
                logicalPath: path
            )
        }
        #expect(throws: DyldSharedCacheAccessError.invalidImageAddress(path: path)) {
            _ = try validatedLoadedImageHeaderPointer(
                address: UInt64(Int.max),
                slide: 1,
                logicalPath: path
            )
        }
        #expect(throws: DyldSharedCacheAccessError.invalidImageAddress(path: path)) {
            _ = try validatedLoadedImageHeaderPointer(
                address: 0,
                slide: 0,
                logicalPath: path
            )
        }

        let negativelySlidPointer = try validatedLoadedImageHeaderPointer(
            address: 0x2000,
            slide: -0x100,
            logicalPath: "/usr/lib/libvalid.dylib"
        )
        #expect(Int(bitPattern: negativelySlidPointer) == 0x1F00)
    }

    @Test func expectedCacheUUIDMismatchIsTyped() throws {
        let expected = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let actual = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))

        #expect(throws: DyldSharedCacheAccessError.expectedUUIDMismatch(expected: expected, actual: actual)) {
            try validateExpectedCacheUUID(expected, actual: actual)
        }
        try validateExpectedCacheUUID(nil, actual: actual)
        try validateExpectedCacheUUID(actual, actual: actual)
    }

    @Test func loaderRejectsSharedCacheWithoutExpectedUUID() {
        var options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        options.useSharedCache = true

        #expect(throws: DyldSharedCacheAccessError.missingExpectedUUID) {
            _ = try RawMachOLoader(
                options: options,
                environment: [:],
                sharedCacheFactory: { _ in
                    Issue.record("shared-cache factory must not run without an expected UUID")
                    throw DyldSharedCacheAccessError.unavailable
                }
            )
        }
    }

    @Test func cacheMissAndDiskFailureSurfaceTypedContext() throws {
        let cacheUUID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        var options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        options.useSharedCache = true
        options.expectedCacheUUID = cacheUUID
        let loader = try RawMachOLoader(
            options: options,
            environment: [:],
            sharedCacheFactory: { _ in
                DyldSharedCacheAccess(cacheUUID: cacheUUID, images: [])
            },
            diskLoader: { _ in
                throw FakeRawMachOLoadError.invalidFixture
            }
        )
        let inputURL = URL(fileURLWithPath: "/usr/lib/libMissing.dylib")

        #expect(
            throws: RawMachOLoadError.sharedCacheMissAndDiskLoadFailed(
                inputPath: inputURL.path,
                cacheUUID: cacheUUID,
                normalizedCandidates: [inputURL.path],
                diskError: "invalid fixture"
            )
        ) {
            _ = try loader.load(url: inputURL)
        }
    }

    @Test func diskParseFailureSurfacesWithoutSharedCache() throws {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let loader = try RawMachOLoader(
            options: options,
            environment: [:],
            diskLoader: { _ in
                throw FakeRawMachOLoadError.invalidFixture
            }
        )
        let inputURL = URL(fileURLWithPath: "/tmp/invalid-mach-o")

        #expect(
            throws: RawMachOLoadError.diskLoadFailed(
                inputPath: inputURL.path,
                diskError: "invalid fixture"
            )
        ) {
            _ = try loader.load(url: inputURL)
        }
    }

    @Test func unsupportedCPUIsTheOnlyIntentionalDiskNilResult() throws {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let loader = try RawMachOLoader(
            options: options,
            environment: [:],
            diskLoader: { _ in nil }
        )

        #expect(try loader.load(url: URL(fileURLWithPath: "/tmp/unsupported-mach-o")) == nil)
    }

    @Test func loadedCacheEnvironmentRequiresTheRunningSimulatorRuntime() {
        #expect(throws: DyldSharedCacheAccessError.missingSimulatorRuntimeRoot) {
            try validateLoadedCacheEnvironment(["SIMULATOR_ROOT": "/Runtime"])
        }
        #expect(
            throws: DyldSharedCacheAccessError.simulatorRuntimeRootMismatch(
                expected: "/Runtime",
                actual: "/OtherRuntime"
            )
        ) {
            try validateLoadedCacheEnvironment([
                "SIMULATOR_ROOT": "/Runtime",
                "PH_RUNTIME_ROOT": "/OtherRuntime",
            ])
        }
        #expect(throws: DyldSharedCacheAccessError.unsupportedHostRuntimeRoot("/Runtime")) {
            try validateLoadedCacheEnvironment(["PH_RUNTIME_ROOT": "/Runtime"])
        }
    }

    @Test func loadedCacheEnvironmentAcceptsCurrentHostAndSimulatorRoots() throws {
        try validateLoadedCacheEnvironment([:])
        try validateLoadedCacheEnvironment(["PH_RUNTIME_ROOT": "/"])
        try validateLoadedCacheEnvironment([
            "SIMULATOR_ROOT": "/Runtime/./",
            "PH_RUNTIME_ROOT": "/Runtime",
        ])
    }

    @Test func loadedCacheEnvironmentAcceptsSymlinkAliasForSameRuntime() throws {
        let dirs = try makeTemporaryTestDirectories()
        let runtimeRoot = dirs.root.appendingPathComponent("CanonicalRuntime", isDirectory: true)
        let runtimeAlias = dirs.root.appendingPathComponent("RuntimeAlias", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: runtimeAlias.path,
            withDestinationPath: runtimeRoot.path
        )

        try validateLoadedCacheEnvironment([
            "SIMULATOR_ROOT": runtimeRoot.path,
            "PH_RUNTIME_ROOT": runtimeAlias.path,
        ])
    }

    @Test func inventoryRejectsCustomHostRootBeforeOpeningLoadedCache() {
        #expect(throws: DyldSharedCacheAccessError.unsupportedHostRuntimeRoot("/Runtime")) {
            _ = try makeSharedCacheInventory(environment: ["PH_RUNTIME_ROOT": "/Runtime"])
        }
    }

    @Test func inventoryEncodingMatchesHelperWireSchema() throws {
        let uuid = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let data = try encodeSharedCacheInventory(
            try PrivateHeaderKitSharedCacheInventory(
                cacheUUID: uuid,
                imagePaths: ["/usr/lib/libobjc.A.dylib"]
            )
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["cacheUUID"] as? String == uuid.uuidString)
        #expect(object["imagePaths"] as? [String] == ["/usr/lib/libobjc.A.dylib"])
    }
}

@Suite
struct PrivateHeaderKitRawDumpBundlePathTests {
    @Test func writeDirectoryBuildsDeclaredBundleAndImagePaths() {
        let outputRoot = URL(fileURLWithPath: "/tmp/out")
        var options = DumpOptions(outputDir: outputRoot)
        options.buildOriginalDirs = true
        options.addHeadersFolder = true

        let result = writeDirectory(
            for: .bundle(
                URL(
                    fileURLWithPath: "/System/Library/Frameworks/Foo.framework",
                    isDirectory: true
                )
            ),
            outputRoot: outputRoot,
            options: options
        )
        #expect(result.path == "/tmp/out/System/Library/Frameworks/Foo.framework/Headers")

        options.addHeadersFolder = false
        let resultNoHeaders = writeDirectory(
            for: .image(URL(fileURLWithPath: "/usr/lib/libobjc.A.dylib")),
            outputRoot: outputRoot,
            options: options
        )
        #expect(resultNoHeaders.path == "/tmp/out/usr/lib/libobjc.A.dylib")
    }

    @Test func writeDirectoryOnlyInfersAnImmediateBundleParentForDirectImages() {
        let outputRoot = URL(fileURLWithPath: "/tmp/out")
        var options = DumpOptions(outputDir: outputRoot)
        options.buildOriginalDirs = true
        options.addHeadersFolder = true
        let cases = [
            (
                "/System/Library/Frameworks/Foo.framework/Foo",
                "/tmp/out/System/Library/Frameworks/Foo.framework/Headers"
            ),
            (
                "/System/Library/Frameworks/CreateML.framework/Versions/A/CreateML",
                "/tmp/out/System/Library/Frameworks/CreateML.framework/Versions/A/CreateML"
            ),
            (
                "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                "/tmp/out/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
            ),
            (
                "/tmp/Version.1/Tool",
                "/tmp/out/tmp/Version.1/Tool"
            ),
        ]

        for (imagePath, expectedPath) in cases {
            let result = writeDirectory(
                for: .image(URL(fileURLWithPath: imagePath)),
                outputRoot: outputRoot,
                options: options
            )
            #expect(result.path == expectedPath)
        }
    }

    @Test func writeDirectoryReturnsRootWhenDisabled() {
        let outputRoot = URL(fileURLWithPath: "/tmp/out")
        var options = DumpOptions(outputDir: outputRoot)
        options.buildOriginalDirs = false
        let result = writeDirectory(
            for: .bundle(
                URL(
                    fileURLWithPath: "/System/Library/Frameworks/Foo.framework",
                    isDirectory: true
                )
            ),
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

    @Test func resolveBundleExecutableUsesLoadCandidateAndCallerBundleIdentity() {
        let bundleURL = URL(fileURLWithPath: "/tmp/Foo.framework", isDirectory: true)
        let candidate = bundleURL.appendingPathComponent("Versions/A/Foo")
        let fake = FakeFileManager(existing: [candidate.path])

        let resolved = resolveBundleExecutable(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in nil }
        )
        #expect(resolved.loadURL == candidate)
        guard case .bundle(let outputBundleURL) = resolved.outputIdentity else {
            Issue.record("expected bundle output identity")
            return
        }
        #expect(outputBundleURL == bundleURL)

        let explicit = bundleURL.appendingPathComponent("Versions/A/CustomExecutable")
        let resolvedExplicit = resolveBundleExecutable(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in explicit }
        )
        #expect(resolvedExplicit.loadURL == explicit)
        guard case .bundle(let explicitOutputBundleURL) = resolvedExplicit.outputIdentity else {
            Issue.record("expected explicit bundle output identity")
            return
        }
        #expect(explicitOutputBundleURL == bundleURL)
    }

    @Test func versionedBundleExecutableLoadsRealPathAndStagesAtCallerBundleRoot() throws {
        let dirs = try makeTemporaryTestDirectories()
        let resolvedBundle = dirs.root.appendingPathComponent(
            "System/Cryptexes/OS/System/Library/Frameworks/SafariServices.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resolvedBundle, withIntermediateDirectories: true)
        let resolvedExec = resolvedBundle.appendingPathComponent("Versions/A/SafariServices")
        try FileManager.default.createDirectory(
            at: resolvedExec.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: resolvedExec)
        let bundleURL = dirs.root.appendingPathComponent(
            "System/Library/Frameworks/SafariServices.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: bundleURL.path,
            withDestinationPath: resolvedBundle.path
        )

        let result = resolveBundleExecutable(
            bundleURL,
            bundleExecutableURL: { _ in resolvedExec }
        )
        #expect(result.loadURL == resolvedExec)
        guard case .bundle(let outputBundleURL) = result.outputIdentity else {
            Issue.record("expected caller bundle output identity")
            return
        }
        #expect(outputBundleURL == bundleURL)
        var options = DumpOptions(outputDir: dirs.outDir)
        options.buildOriginalDirs = true
        options.addHeadersFolder = true
        let placement = outputPlacement(
            for: result,
            outputRoot: dirs.outDir,
            options: options,
            environment: ["PH_RUNTIME_ROOT": dirs.root.path]
        )
        #expect(
            placement.directory.path == dirs.outDir.appendingPathComponent(
                "System/Library/Frameworks/SafariServices.framework/Headers",
                isDirectory: true
            ).path
        )
    }

    @Test func cacheOnlyRenamedBundleKeepsCallerIdentityWithoutDiskExecutable() throws {
        let dirs = try makeTemporaryTestDirectories()
        let parent = dirs.root.appendingPathComponent(
            "System/Library/PrivateFrameworks",
            isDirectory: true
        )
        let resolvedBundle = parent.appendingPathComponent(
            "SpotlightIndex.framework",
            isDirectory: true
        )
        let bundleURL = parent.appendingPathComponent(
            "MobileSpotlightIndex.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: resolvedBundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bundleURL.path,
            withDestinationPath: resolvedBundle.lastPathComponent
        )
        let resolvedExec = resolvedBundle.appendingPathComponent("SpotlightIndex")
        let fake = FakeFileManager(existing: [])

        let result = resolveBundleExecutable(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in resolvedExec }
        )
        #expect(result.loadURL == resolvedExec)
        #expect(fake.fileExists(atPath: resolvedExec.path) == false)
        #expect(
            normalizedCacheImagePaths(
                for: result.loadURL.path,
                environment: ["PH_RUNTIME_ROOT": dirs.root.path]
            ).contains(
                "/System/Library/PrivateFrameworks/SpotlightIndex.framework/SpotlightIndex"
            )
        )
        guard case .bundle(let outputBundleURL) = result.outputIdentity else {
            Issue.record("expected renamed caller bundle output identity")
            return
        }
        #expect(outputBundleURL == bundleURL)
        var options = DumpOptions(outputDir: dirs.outDir)
        options.buildOriginalDirs = true
        options.addHeadersFolder = true
        let placement = outputPlacement(
            for: result,
            outputRoot: dirs.outDir,
            options: options,
            environment: ["PH_RUNTIME_ROOT": dirs.root.path]
        )
        #expect(
            placement.directory.path == dirs.outDir.appendingPathComponent(
                "System/Library/PrivateFrameworks/MobileSpotlightIndex.framework/Headers",
                isDirectory: true
            ).path
        )
    }

    @Test func resolveBundleExecutableFallsBackToCanonicalLoadPathForCacheOnlyBundles() {
        let bundleURL = URL(fileURLWithPath: "/tmp/Foo.framework", isDirectory: true)
        let fake = FakeFileManager(existing: [])

        let resolved = resolveBundleExecutable(
            bundleURL,
            fileManager: fake,
            bundleExecutableURL: { _ in nil }
        )

        #expect(resolved.loadURL.path == "/tmp/Foo.framework/Foo")
        guard case .bundle(let outputBundleURL) = resolved.outputIdentity else {
            Issue.record("expected fallback bundle output identity")
            return
        }
        #expect(outputBundleURL == bundleURL)
    }

    @Test func resolveBundleExecutableResolvesXPCAndAppExtensionCandidates() throws {
        let dirs = try makeTemporaryTestDirectories()

        let xpcURL = dirs.root.appendingPathComponent("Foo.xpc", isDirectory: true)
        try FileManager.default.createDirectory(at: xpcURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: xpcURL.appendingPathComponent("Foo").path, contents: Data())

        let xpcResolved = resolveBundleExecutable(
            xpcURL,
            fileManager: FileManager.default,
            bundleExecutableURL: { _ in nil }
        )
        #expect(xpcResolved.loadURL == xpcURL.appendingPathComponent("Foo"))
        guard case .bundle(let xpcOutputBundleURL) = xpcResolved.outputIdentity else {
            Issue.record("expected XPC bundle output identity")
            return
        }
        #expect(xpcOutputBundleURL == xpcURL)

        let appexURL = dirs.root.appendingPathComponent("Bar.appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appexURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: appexURL.appendingPathComponent("Bar").path, contents: Data())

        let appexResolved = resolveBundleExecutable(
            appexURL,
            fileManager: FileManager.default,
            bundleExecutableURL: { _ in nil }
        )
        #expect(appexResolved.loadURL == appexURL.appendingPathComponent("Bar"))
        guard case .bundle(let appexOutputBundleURL) = appexResolved.outputIdentity else {
            Issue.record("expected app extension bundle output identity")
            return
        }
        #expect(appexOutputBundleURL == appexURL)
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
            entry(symbolKind: .class, name: "FooHeader", headerString: "@interface FooHeader\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)

        #expect(resolved.count == 1)
        #expect(resolved.first?.fileName == "FooHeader.h")
        #expect(resolved.first?.hadNameCollision == false)
    }

    @Test func resolveObjCHeaderEntriesDisambiguatesCaseOnlyCollisions() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            entry(symbolKind: .class, name: "MTRBaseClusterWakeOnLAN", headerString: "@interface A\n@end\n"),
            entry(symbolKind: .class, name: "MTRBaseClusterWakeOnLan", headerString: "@interface B\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)
        let fileNames = Set(resolved.map(\.fileName))

        #expect(fileNames.count == 2)
        #expect(resolved.allSatisfy { $0.hadNameCollision })
        #expect(resolved.contains { $0.displayBaseName == "MTRBaseClusterWakeOnLAN" && $0.fileName.hasPrefix("MTRBaseClusterWakeOnLAN~") })
        #expect(resolved.contains { $0.displayBaseName == "MTRBaseClusterWakeOnLan" && $0.fileName.hasPrefix("MTRBaseClusterWakeOnLan~") })
    }

    @Test func resolveObjCHeaderEntriesDisambiguatesAcrossSymbolKinds() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            entry(symbolKind: .class, name: "SharedHeaderName", headerString: "@interface SharedHeaderName\n@end\n"),
            entry(symbolKind: .protocol, name: "SharedHeaderName", headerString: "@protocol SharedHeaderName\n@end\n")
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
            entry(symbolKind: .class, name: longBaseName, headerString: "@interface LongHeader\n@end\n"),
            entry(symbolKind: .protocol, name: longBaseName, headerString: "@protocol LongHeader\n@end\n")
        ]

        let resolved = resolveObjCHeaderEntries(entries, options: options)

        #expect(Set(resolved.map(\.fileName)).count == 2)
        #expect(resolved.allSatisfy { $0.fileName.utf8.count <= 255 })
        #expect(resolved.allSatisfy { $0.fileName.hasSuffix(".h") })
    }

    @Test func resolveObjCHeaderEntriesIsStableAcrossRuns() {
        let options = DumpOptions(outputDir: URL(fileURLWithPath: "/tmp/out"))
        let entries = [
            entry(symbolKind: .protocol, name: "SharedHeaderName", headerString: "@protocol SharedHeaderName\n@end\n"),
            entry(symbolKind: .class, name: "MTRBaseClusterWakeOnLan", headerString: "@interface MTRBaseClusterWakeOnLan\n@end\n"),
            entry(symbolKind: .class, name: "MTRBaseClusterWakeOnLAN", headerString: "@interface MTRBaseClusterWakeOnLAN\n@end\n")
        ]

        let first = resolveObjCHeaderEntries(entries, options: options)
        let second = resolveObjCHeaderEntries(Array(entries.reversed()), options: options)

        #expect(first == second)
    }

    private func entry(
        symbolKind: ObjCHeaderSymbolKind,
        name: String,
        headerString: String
    ) -> ObjCHeaderEntry {
        ObjCHeaderEntry(
            symbolKind: symbolKind,
            rawIdentity: name,
            displayBaseName: name,
            headerString: headerString
        )
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

    @Test func dumpSwiftInterfacePropagatesBuildFailure() async throws {
        let dirs = try makeTemporaryTestDirectories()
        let outputDir = dirs.root.appendingPathComponent("out", isDirectory: true)
        let options = DumpOptions(outputDir: outputDir)

        await #expect(throws: FixtureSwiftInterfaceError.self) {
            try await dumpSwiftInterface(
                imagePath: "/tmp/FixtureFailure",
                outputDir: outputDir,
                options: options,
                fileManager: FileManager.default,
                buildInterface: { throw FixtureSwiftInterfaceError.failed }
            )
        }
    }

    private enum FixtureSwiftInterfaceError: Error {
        case failed
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
        #expect(snapshot?.objcRuntimeName == "NSObject")
        #expect(snapshot?.superclassObjCRuntimeName == nil)
    }

    @Test func loadedRuntimeImageLifecycleHopsToMainActorInOrder() async {
        let probe = await RuntimeImageLifecycleProbe()

        let result = await Task.detached {
            await withLoadedRuntimeImage(
                at: "/fixture/Runtime.framework/Runtime",
                open: { path in probe.open(path) },
                close: { handle in probe.close(handle) },
                inspect: { handle in probe.inspect(handle) }
            )
        }.value

        #expect(result == "inspected")
        let observations = await probe.finish()
        #expect(observations.map(\.stage) == ["open", "inspect", "close"])
        #expect(observations.allSatisfy { $0.isMainThread })
        #expect(observations.allSatisfy { $0.isMainQueue })
    }

    @Test @MainActor
    func loadedRuntimeImageLifecycleClosesWhenInspectionThrows() {
        let probe = RuntimeImageLifecycleProbe()

        #expect(throws: RuntimeImageLifecycleError.self) {
            try withLoadedRuntimeImage(
                at: "/fixture/Runtime.framework/Runtime",
                open: { path in probe.open(path) },
                close: { handle in probe.close(handle) },
                inspect: { handle in try probe.inspectThrowing(handle) }
            )
        }

        let observations = probe.finish()
        #expect(observations.map(\.stage) == ["open", "inspect", "close"])
        #expect(observations.allSatisfy { $0.isMainThread })
        #expect(observations.allSatisfy { $0.isMainQueue })
    }
    #endif
}

#if canImport(ObjectiveC) && canImport(PrivateHeaderKitRawDumpRuntimeObjC)
private struct RuntimeImageLifecycleObservation: Equatable, Sendable {
    let stage: String
    let isMainThread: Bool
    let isMainQueue: Bool
}

private enum RuntimeImageLifecycleError: Error {
    case expected
}

@MainActor
private final class RuntimeImageLifecycleProbe {
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let handle = UnsafeMutableRawPointer(bitPattern: 0x1)!
    private var observations: [RuntimeImageLifecycleObservation] = []

    init() {
        DispatchQueue.main.setSpecific(key: queueKey, value: 1)
    }

    func open(_ path: String) -> UnsafeMutableRawPointer? {
        #expect(path == "/fixture/Runtime.framework/Runtime")
        record("open")
        return handle
    }

    func inspect(_ handle: UnsafeMutableRawPointer) -> String {
        #expect(handle == self.handle)
        record("inspect")
        return "inspected"
    }

    func inspectThrowing(_ handle: UnsafeMutableRawPointer) throws -> String {
        #expect(handle == self.handle)
        record("inspect")
        throw RuntimeImageLifecycleError.expected
    }

    func close(_ handle: UnsafeMutableRawPointer) {
        #expect(handle == self.handle)
        record("close")
    }

    func finish() -> [RuntimeImageLifecycleObservation] {
        DispatchQueue.main.setSpecific(key: queueKey, value: nil)
        return observations
    }

    private func record(_ stage: String) {
        MainActor.preconditionIsolated()
        observations.append(
            RuntimeImageLifecycleObservation(
                stage: stage,
                isMainThread: Thread.isMainThread,
                isMainQueue: DispatchQueue.getSpecific(key: queueKey) == 1
            )
        )
    }
}
#endif
