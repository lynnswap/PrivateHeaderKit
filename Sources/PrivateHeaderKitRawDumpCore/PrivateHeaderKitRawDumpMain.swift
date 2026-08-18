import Foundation
import Dispatch
import MachOKit
@_spi(Diagnostics) import MachOObjCSection
import MachOSwiftSection
import ObjCDump
import PrivateHeaderKitExecutableResolution
import PrivateHeaderKitHelperProtocol
import SwiftDeclaration
import SwiftDeclarationRendering
import SwiftInterface
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(ObjectiveC)
import ObjectiveC
import PrivateHeaderKitRawDumpRuntimeObjC
#endif

protocol FileExistenceChecking {
    func fileExists(atPath: String) -> Bool
}

extension FileManager: FileExistenceChecking {}

protocol SwiftInterfaceBuilding {
    func prepare() async throws
    func printRoot() async throws -> String
}

protocol SwiftInterfaceBuildingFactory {
    func makeBuilder(machO: MachOFile) throws -> SwiftInterfaceBuilding
    func makeBuilder(machO: MachOImage) throws -> SwiftInterfaceBuilding
}

struct DefaultSwiftInterfaceBuilderFactory: SwiftInterfaceBuildingFactory {
    let configuration: SwiftInterfaceBuilderConfiguration
    let eventHandlers: [SwiftIndexEvents.Handler]

    init(
        configuration: SwiftInterfaceBuilderConfiguration = .init(),
        eventHandlers: [SwiftIndexEvents.Handler] = []
    ) {
        self.configuration = configuration
        self.eventHandlers = eventHandlers
    }

    func makeBuilder(machO: MachOFile) throws -> SwiftInterfaceBuilding {
        try SwiftInterfaceBuilderAdapter(
            machO: machO,
            configuration: configuration,
            eventHandlers: eventHandlers
        )
    }

    func makeBuilder(machO: MachOImage) throws -> SwiftInterfaceBuilding {
        try SwiftInterfaceBuilderAdapter(
            machO: machO,
            configuration: configuration,
            eventHandlers: eventHandlers
        )
    }
}

struct SwiftInterfaceBuilderAdapter<MachO: FieldLayoutRenderable>: SwiftInterfaceBuilding {
    private let builder: SwiftInterfaceBuilder<MachO>

    init(
        machO: MachO,
        configuration: SwiftInterfaceBuilderConfiguration = .init(),
        eventHandlers: [SwiftIndexEvents.Handler] = []
    ) throws {
        self.builder = try SwiftInterfaceBuilder(configuration: configuration, eventHandlers: eventHandlers, in: machO)
    }

    func prepare() async throws {
        try await builder.prepare()
    }

    func printRoot() async throws -> String {
        try await builder.printRoot().string
    }
}

struct DumpOptions {
    var outputDir: URL
    var recursive: Bool = false
    var buildOriginalDirs: Bool = false
    var addHeadersFolder: Bool = false
    var skipExisting: Bool = false
    var onlyOneClass: String? = nil
    var useSharedCache: Bool = false
    var expectedCacheUUID: UUID? = nil
    var verbose: Bool = false
    var useRuntimeFallback: Bool = false
    var logSkippedClasses: Bool = false
    var profile: Bool = false
    var logSwiftEvents: Bool = false
    var diagnosticsReportURL: URL?
    let objcDiagnostics = RawDumpObjCDiagnosticsAccumulator()
}

public struct PrivateHeaderKitRawDumpCLI {
    public static func main() async {
        await main(arguments: Array(CommandLine.arguments.dropFirst()))
    }

    public static func main(arguments args: [String]) async {
        if args == [PrivateHeaderKitHelperCommand.sharedCacheInventory.rawValue] {
            do {
                let data = try encodeSharedCacheInventory(makeSharedCacheInventory())
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                print(payload)
            } catch {
                fputs("privateheaderkit __shared-cache-inventory: error: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

        guard let parsed = parseArguments(args) else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        do {
            try await run(parsed: parsed)
            try writeDiagnosticsReportIfRequested(parsed.options)
        } catch {
            do {
                try writeDiagnosticsReportIfRequested(parsed.options)
            } catch {
                fputs("privateheaderkit __raw-dump: diagnostics report error: \(error)\n", stderr)
            }
            fputs("privateheaderkit __raw-dump: error: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

struct ParsedArguments {
    let options: DumpOptions
    let inputPath: String
}

func parseArguments(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    exitHandler: (Int32) -> Void = { exit($0) },
    printUsageHandler: () -> Void = printUsage
) -> ParsedArguments? {
    var options = DumpOptions(outputDir: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    var inputPath: String? = nil
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--help":
            printUsageHandler()
            exitHandler(EXIT_SUCCESS)
            return nil
        case "-o":
            let nextIndex = index + 1
            guard nextIndex < args.count else { return nil }
            options.outputDir = URL(fileURLWithPath: args[nextIndex])
            index += 1
        case "-r":
            options.recursive = true
        case "-b":
            options.buildOriginalDirs = true
        case "-h":
            options.addHeadersFolder = true
        case "-s":
            options.skipExisting = true
        case "-j":
            let nextIndex = index + 1
            guard nextIndex < args.count else { return nil }
            options.onlyOneClass = args[nextIndex]
            index += 1
        case "-c":
            options.useSharedCache = true
        case "--expected-cache-uuid":
            let nextIndex = index + 1
            guard nextIndex < args.count,
                  let uuid = UUID(uuidString: args[nextIndex])
            else { return nil }
            options.expectedCacheUUID = uuid
            index += 1
        case "-D":
            options.verbose = true
        case "-R":
            options.useRuntimeFallback = true
        case "--diagnostics-report":
            let nextIndex = index + 1
            guard nextIndex < args.count else { return nil }
            options.diagnosticsReportURL = URL(fileURLWithPath: args[nextIndex])
            index += 1
        default:
            if arg.hasPrefix("-") {
                // ignore unknown flags for compatibility
            } else {
                inputPath = arg
            }
        }
        index += 1
    }

    guard let inputPath else { return nil }
    guard options.useSharedCache == (options.expectedCacheUUID != nil) else {
        return nil
    }
    if !options.useRuntimeFallback {
        options.useRuntimeFallback = shouldUseRuntimeFallback(environment: environment)
    }
    options.logSkippedClasses = shouldLogSkippedClasses(environment: environment)
    options.profile = shouldProfile(environment: environment)
    options.logSwiftEvents = shouldLogSwiftEvents(environment: environment)
    return ParsedArguments(options: options, inputPath: inputPath)
}

private func printUsage() {
    let text = """
    Usage: privateheaderkit __raw-dump [<options>] <filename|framework>
           privateheaderkit __raw-dump [<options>] -r <sourcePath>

    Options:
        -o   Output directory
        -r   Recursive search
        -b   Build original directories
        -h   Add Headers folder for bundles
        -s   Skip already found files
        -j   Only dump a single class/protocol name
        -c   Use dyld shared cache when dumping (recommended for simulator runtimes)
        --expected-cache-uuid <uuid>
             Require the helper process to use the expected dyld shared cache
        -D   Verbose logging
        -R   Prefer Objective-C runtime metadata (auto-enabled in simulator)
        --diagnostics-report <path>
             Write the versioned Objective-C metadata diagnostics report
    """
    print(text)
}

private func writeDiagnosticsReportIfRequested(_ options: DumpOptions) throws {
    guard let reportURL = options.diagnosticsReportURL else { return }
    try writeRawDumpDiagnosticsReport(options.objcDiagnostics.report, to: reportURL)
}

func shouldUseRuntimeFallback(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PH_RUNTIME_ROOT"] != nil || environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"] != nil
}

func shouldLogSkippedClasses(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PH_VERBOSE_SKIP"] == "1"
}

func shouldProfile(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PH_PROFILE"] == "1" || environment["SIMCTL_CHILD_PH_PROFILE"] == "1"
}

func shouldLogSwiftEvents(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["PH_SWIFT_EVENTS"] == "1" || environment["SIMCTL_CHILD_PH_SWIFT_EVENTS"] == "1"
}

private func runtimeRootPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    environment["PH_RUNTIME_ROOT"] ?? environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"]
}

func resolveRuntimeURL(
    _ url: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileExistenceChecking = FileManager.default
) -> URL {
    guard let runtimeRoot = runtimeRootPath(environment: environment) else { return url }
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/") else { return url }
    let candidate = URL(fileURLWithPath: runtimeRoot).appendingPathComponent(String(path.dropFirst()))
    if fileManager.fileExists(atPath: candidate.path) {
        return candidate
    }
    return url
}

func stripRuntimeRoot(
    from path: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    guard let runtimeRoot = runtimeRootPath(environment: environment) else { return path }
    if path.hasPrefix(runtimeRoot) {
        var trimmed = path.dropFirst(runtimeRoot.count)
        if trimmed.first == "/" {
            trimmed = trimmed.dropFirst()
        }
        return "/" + trimmed
    }
    return path
}

func run(parsed: ParsedArguments) async throws {
    let options = parsed.options
    let inputPath = parsed.inputPath
    let fileManager = FileManager.default
    let machOLoader = try RawMachOLoader(options: options)

    if options.recursive {
        try await dumpRecursive(
            inputPath: inputPath,
            options: options,
            fileManager: fileManager,
            machOLoader: machOLoader
        )
    } else {
        try await dumpSingle(
            inputPath: inputPath,
            options: options,
            fileManager: fileManager,
            machOLoader: machOLoader
        )
    }
}

private func dumpRecursive(
    inputPath: String,
    options: DumpOptions,
    fileManager: FileManager,
    machOLoader: RawMachOLoader
) async throws {
    let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
    let rootURL = resolveRuntimeURL(inputURL)
    guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw NSError(domain: "privateheaderkit.raw-dump", code: 1, userInfo: [NSLocalizedDescriptionKey: "Directory not found: \(inputPath)"])
    }

    while let url = enumerator.nextObject() as? URL {
        if isBundleDirectory(url) {
            enumerator.skipDescendants()
            if let executableURL = resolveBundleExecutableURL(url, fileManager: fileManager) {
                let originalPath = stripRuntimeRoot(from: executableURL.path)
                try await dumpImage(
                    executableURL,
                    originalPath: originalPath,
                    options: options,
                    fileManager: fileManager,
                    machOLoader: machOLoader
                )
            }
            continue
        }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
              values.isDirectory == false,
              values.isRegularFile == true
        else { continue }

        let originalPath = stripRuntimeRoot(from: url.path)
        try await dumpImage(
            url,
            originalPath: originalPath,
            options: options,
            fileManager: fileManager,
            machOLoader: machOLoader
        )
    }
}

private func dumpSingle(
    inputPath: String,
    options: DumpOptions,
    fileManager: FileManager,
    machOLoader: RawMachOLoader
) async throws {
    let originalURL = URL(fileURLWithPath: inputPath)
    let resolvedURL = resolveRuntimeURL(originalURL)
    if isBundleDirectory(resolvedURL), let executableURL = resolveBundleExecutableURL(resolvedURL, fileManager: fileManager) {
        let originalPath = stripRuntimeRoot(from: executableURL.path)
        try await dumpImage(
            executableURL,
            originalPath: originalPath,
            options: options,
            fileManager: fileManager,
            machOLoader: machOLoader
        )
        return
    }
    let originalPath = stripRuntimeRoot(from: resolvedURL.path)
    try await dumpImage(
        resolvedURL,
        originalPath: originalPath,
        options: options,
        fileManager: fileManager,
        machOLoader: machOLoader
    )
}

func isBundleDirectory(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    guard ext == "framework" || ext == "app" || ext == "bundle" || ext == "xpc" || ext == "appex" else { return false }

    // `URL.hasDirectoryPath` is unreliable for symlink-to-directory bundles (e.g. Cryptex-backed
    // system frameworks inside simulator runtimes). Fall back to a filesystem check so we can
    // still treat them as bundles and resolve the executable.
    if url.hasDirectoryPath {
        return true
    }

    var isDir = ObjCBool(false)
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
        return isDir.boolValue
    }
    return false
}

func resolveBundleExecutableURL(
    _ bundleURL: URL,
    fileManager: FileExistenceChecking = FileManager.default,
    bundleExecutableURL: (URL) -> URL? = { Bundle(url: $0)?.executableURL }
) -> URL? {
    ExecutableResolution.resolveBundleExecutableURL(
        bundleURL,
        fileExists: fileManager.fileExists(atPath:),
        bundleExecutableURL: bundleExecutableURL
    )
}

private func dumpImage(
    _ url: URL,
    originalPath: String,
    options: DumpOptions,
    fileManager: FileManager,
    machOLoader: RawMachOLoader
) async throws {
    let loadStart = profileNowNanoseconds(enabled: options.profile)
    guard let machO = try machOLoader.load(url: url) else {
        return
    }
    profileLogDuration(enabled: options.profile, imagePath: originalPath, name: "loadMachO", since: loadStart)

    let outputDir = writeDirectory(for: originalPath, outputRoot: options.outputDir, options: options)
    if options.verbose {
        print("Dumping: \(originalPath)")
    }

    let objcStart = profileNowNanoseconds(enabled: options.profile)
    try await dumpObjC(
        machO: machO,
        imagePath: originalPath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
    profileLogDuration(enabled: options.profile, imagePath: originalPath, name: "dumpObjC", since: objcStart)

    try await dumpSwift(
        machO: machO,
        imagePath: originalPath,
        outputDir: outputDir,
        options: options,
        interfaceBuilderFactory: defaultSwiftInterfaceBuilderFactory(
            imagePath: originalPath,
            options: options
        ),
        fileManager: fileManager
    )
}

private func defaultSwiftInterfaceBuilderFactory(
    imagePath: String,
    options: DumpOptions
) -> SwiftInterfaceBuildingFactory {
    if options.logSwiftEvents {
        let moduleName = URL(fileURLWithPath: imagePath).lastPathComponent
        return DefaultSwiftInterfaceBuilderFactory(
            eventHandlers: [SwiftInterfaceTimingHandler(label: moduleName)]
        )
    }
    return DefaultSwiftInterfaceBuilderFactory()
}

enum RawMachO {
    case file(MachOFile)
    case loaded(MachOImage)
}

enum RawMachOLoadError: Error, Equatable, CustomStringConvertible, Sendable {
    case sharedCacheMissAndDiskLoadFailed(
        inputPath: String,
        cacheUUID: UUID,
        normalizedCandidates: [String],
        diskError: String
    )
    case diskLoadFailed(inputPath: String, diskError: String)

    var description: String {
        switch self {
        case .sharedCacheMissAndDiskLoadFailed(
            let inputPath,
            let cacheUUID,
            let normalizedCandidates,
            let diskError
        ):
            "raw Mach-O target was absent from shared cache and could not be loaded from disk: input=\(inputPath) cacheUUID=\(cacheUUID.uuidString.lowercased()) candidates=\(normalizedCandidates.joined(separator: ",")) diskError=\(diskError)"
        case .diskLoadFailed(let inputPath, let diskError):
            "raw Mach-O target could not be loaded from disk: input=\(inputPath) diskError=\(diskError)"
        }
    }
}

struct RawMachOLoader {
    private let sharedCache: DyldSharedCacheAccess?
    private let environment: [String: String]
    private let diskLoader: (URL) throws -> RawMachO?

    init(
        options: DumpOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sharedCacheFactory: (UUID?) throws -> DyldSharedCacheAccess = DyldSharedCacheAccess.current,
        diskLoader: @escaping (URL) throws -> RawMachO? = loadSupportedDiskMachO
    ) throws {
        self.environment = environment
        self.diskLoader = diskLoader
        if options.useSharedCache {
            guard let expectedCacheUUID = options.expectedCacheUUID else {
                throw DyldSharedCacheAccessError.missingExpectedUUID
            }
            try validateLoadedCacheEnvironment(environment)
            self.sharedCache = try sharedCacheFactory(expectedCacheUUID)
        } else {
            self.sharedCache = nil
        }
    }

    func load(url: URL) throws -> RawMachO? {
        if let sharedCache {
            let candidates = normalizedCacheImagePaths(
                for: url.path,
                environment: environment
            )
            if let loaded = sharedCache.image(matching: candidates) {
                return .loaded(loaded.machO)
            }

            do {
                return try diskLoader(url)
            } catch {
                throw RawMachOLoadError.sharedCacheMissAndDiskLoadFailed(
                    inputPath: url.path,
                    cacheUUID: sharedCache.cacheUUID,
                    normalizedCandidates: candidates,
                    diskError: String(describing: error)
                )
            }
        }

        do {
            return try diskLoader(url)
        } catch {
            throw RawMachOLoadError.diskLoadFailed(
                inputPath: url.path,
                diskError: String(describing: error)
            )
        }
    }
}

private func loadSupportedDiskMachO(url: URL) throws -> RawMachO? {
    let file = try loadFromFile(url: url)
    switch file {
    case .machO(let machO):
        return isSupported(machO) ? .file(machO) : nil
    case .fat(let fat):
        let machOFiles = try fat.machOFiles()
        if let match = machOFiles.first(where: { isSupported($0) }) {
            return .file(match)
        }
        return nil
    }
}

private func isSupported(_ machO: MachOFile) -> Bool {
    switch machO.header.cpuType {
    case .arm64, .x86_64:
        return true
    default:
        return false
    }
}

func normalizedCacheImagePaths(
    for path: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    ExecutableResolution.normalizedCacheImagePaths(
        for: path,
        environment: environment
    )
}

func writeDirectory(for imagePath: String, outputRoot: URL, options: DumpOptions) -> URL {
    guard options.buildOriginalDirs else { return outputRoot }

    let imageURL = URL(fileURLWithPath: imagePath)
    let parentURL = imageURL.deletingLastPathComponent()
    let isBundle = parentURL.lastPathComponent.contains(".")
    let targetPath = isBundle ? parentURL.path : imageURL.path
    var fullPath = outputRoot.path + targetPath
    if isBundle && options.addHeadersFolder {
        fullPath += "/Headers"
    }
    fullPath = normalizePath(fullPath)
    return URL(fileURLWithPath: fullPath)
}

func normalizePath(_ path: String) -> String {
    var normalized = path
    while normalized.contains("//") {
        normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    return normalized
}

private let maxPathComponentBytes = 255
private let truncatedNameHashLength = 16
private let caseInsensitiveFileNameLocale = Locale(identifier: "en_US_POSIX")

enum ObjCHeaderSymbolKind: String, Comparable {
    case `class` = "class"
    case `protocol` = "protocol"
    case category = "category"

    private var sortOrder: Int {
        switch self {
        case .class:
            return 0
        case .protocol:
            return 1
        case .category:
            return 2
        }
    }

    static func < (lhs: ObjCHeaderSymbolKind, rhs: ObjCHeaderSymbolKind) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct ObjCHeaderEntry: Equatable {
    let symbolKind: ObjCHeaderSymbolKind
    let rawIdentity: String
    let displayBaseName: String
    let headerString: String
}

struct ResolvedObjCHeaderEntry: Equatable {
    let symbolKind: ObjCHeaderSymbolKind
    let rawIdentity: String
    let displayBaseName: String
    let headerString: String
    let fileName: String
    let hadNameCollision: Bool
}

func isSaneObjCTypeName(_ name: String) -> Bool {
    if name.isEmpty { return false }
    for scalar in name.unicodeScalars {
        // U+FFFD is a strong signal we decoded invalid UTF-8 from runtime metadata.
        if scalar.value == 0xFFFD { return false }
        // Control characters (including \t, \n, form feed, etc) make both filenames and headers unreadable.
        if scalar.properties.generalCategory == .control { return false }
    }
    return true
}

private func safeFileName(baseName: String, suffix: String = "", extension ext: String) -> String {
    let normalizedExt = ext.isEmpty ? "" : (ext.hasPrefix(".") ? ext : ".\(ext)")
    let maxBaseBytes = max(0, maxPathComponentBytes - suffix.utf8.count - normalizedExt.utf8.count)
    let normalizedBase: String
    if baseName.utf8.count <= maxBaseBytes {
        normalizedBase = baseName
    } else {
        let hash = stableHashHex(baseName)
        let truncationSuffix = "~\(hash)"
        let maxPrefixBytes = max(0, maxBaseBytes - truncationSuffix.utf8.count)
        let prefix = truncateToByteCount(baseName, maxBytes: maxPrefixBytes)
        normalizedBase = prefix + truncationSuffix
    }
    return normalizedBase + suffix + normalizedExt
}

private func truncateToByteCount(_ value: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    if value.utf8.count <= maxBytes {
        return value
    }
    var used = 0
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
        let size = scalar.utf8.count
        if used + size > maxBytes {
            break
        }
        scalars.append(scalar)
        used += size
    }
    return String(scalars)
}

private func stableHashHex(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    let hex = String(hash, radix: 16)
    if hex.count >= truncatedNameHashLength {
        return hex
    }
    return String(repeating: "0", count: truncatedNameHashLength - hex.count) + hex
}

private func withSilencedStdout<T>(_ enabled: Bool, _ body: () async throws -> T) async rethrows -> T {
    guard enabled else { return try await body() }
    let stdoutFD = fileno(stdout)
    let saved = dup(stdoutFD)
    if saved == -1 {
        return try await body()
    }
    let devNull = open("/dev/null", O_WRONLY)
    if devNull == -1 {
        close(saved)
        return try await body()
    }
    fflush(stdout)
    dup2(devNull, stdoutFD)
    close(devNull)
    defer {
        fflush(stdout)
        dup2(saved, stdoutFD)
        close(saved)
    }
    return try await body()
}

@inline(__always)
private func profileNowNanoseconds(enabled: Bool) -> UInt64 {
    guard enabled else { return 0 }
    return DispatchTime.now().uptimeNanoseconds
}

private func profileLogDuration(
    enabled: Bool,
    imagePath: String,
    name: String,
    since start: UInt64
) {
    guard enabled, start != 0 else { return }
    let end = DispatchTime.now().uptimeNanoseconds
    let delta = end &- start
    let seconds = Double(delta) / 1_000_000_000.0
    // Intentionally stderr so `withSilencedStdout` doesn't hide it.
    let secondsText = String(format: "%.3fs", seconds)
    fputs("privateheaderkit __raw-dump: profile \(name) \(secondsText) \(imagePath)\n", stderr)
}

private final class SwiftInterfaceTimingHandler: SwiftIndexEvents.Handler {
    private struct OpKey: Hashable {
        let phase: SwiftIndexEvents.Phase
        let operation: SwiftIndexEvents.PhaseOperation
    }

    private let label: String
    private let startNanos: UInt64
    private let lock = NSLock()
    private var phaseStart: [SwiftIndexEvents.Phase: [UInt64]] = [:]
    private var opStart: [OpKey: UInt64] = [:]
    private var extractionSectionStart: [SwiftIndexEvents.Section: UInt64] = [:]

    init(label: String) {
        self.label = label
        self.startNanos = DispatchTime.now().uptimeNanoseconds
    }

    func handle(event: SwiftIndexEvents.Payload) {
        switch event {
        case .phaseTransition(let phase, let state):
            handlePhaseTransition(phase: phase, state: state)
        case .extractionStarted(section: let section):
            handleExtractionStarted(section: section)
        case .extractionCompleted(result: let result):
            handleExtractionCompleted(result: result)
        case .extractionFailed(section: let section, error: let error):
            handleExtractionFailed(section: section, error: error)
        case .phaseOperationStarted(let phase, let operation):
            handleOpStarted(phase: phase, operation: operation)
        case .phaseOperationCompleted(let phase, let operation):
            handleOpCompleted(phase: phase, operation: operation)
        case .phaseOperationFailed(let phase, let operation, let error):
            handleOpFailed(phase: phase, operation: operation, error: error)
        case .moduleCollectionStarted:
            handlePhaseTransition(phase: .moduleCollection, state: .started)
        case .moduleCollectionCompleted(result: _):
            handlePhaseTransition(phase: .moduleCollection, state: .completed)
        default:
            break
        }
    }

    private func handlePhaseTransition(phase: SwiftIndexEvents.Phase, state: SwiftIndexEvents.State) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .started:
            phaseStart[phase, default: []].append(now)
            log(now: now, message: "\(phaseName(phase)) started")
        case .completed:
            let start = popPhaseStart(for: phase) ?? now
            log(now: now, message: "\(phaseName(phase)) completed (\(formatDurationSeconds(now &- start)))")
        case .failed(let error):
            let start = popPhaseStart(for: phase) ?? now
            log(now: now, message: "\(phaseName(phase)) failed (\(formatDurationSeconds(now &- start))): \(String(describing: error))")
        }
    }

    private func popPhaseStart(for phase: SwiftIndexEvents.Phase) -> UInt64? {
        guard var starts = phaseStart[phase], let start = starts.popLast() else {
            return nil
        }
        if starts.isEmpty {
            phaseStart.removeValue(forKey: phase)
        } else {
            phaseStart[phase] = starts
        }
        return start
    }

    private func handleOpStarted(phase: SwiftIndexEvents.Phase, operation: SwiftIndexEvents.PhaseOperation) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = OpKey(phase: phase, operation: operation)
        lock.lock()
        opStart[key] = now
        log(now: now, message: "\(phaseName(phase)).\(operationName(operation)) started")
        lock.unlock()
    }

    private func handleOpCompleted(phase: SwiftIndexEvents.Phase, operation: SwiftIndexEvents.PhaseOperation) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = OpKey(phase: phase, operation: operation)
        lock.lock()
        let start = opStart.removeValue(forKey: key) ?? now
        log(now: now, message: "\(phaseName(phase)).\(operationName(operation)) completed (\(formatDurationSeconds(now &- start)))")
        lock.unlock()
    }

    private func handleOpFailed(phase: SwiftIndexEvents.Phase, operation: SwiftIndexEvents.PhaseOperation, error: any Error) {
        let now = DispatchTime.now().uptimeNanoseconds
        let key = OpKey(phase: phase, operation: operation)
        lock.lock()
        let start = opStart.removeValue(forKey: key) ?? now
        log(now: now, message: "\(phaseName(phase)).\(operationName(operation)) failed (\(formatDurationSeconds(now &- start))): \(String(describing: error))")
        lock.unlock()
    }

    private func handleExtractionStarted(section: SwiftIndexEvents.Section) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        extractionSectionStart[section] = now
        log(now: now, message: "extraction.\(sectionName(section)) started")
        lock.unlock()
    }

    private func handleExtractionCompleted(result: SwiftIndexEvents.ExtractionResult) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let start = extractionSectionStart.removeValue(forKey: result.section) ?? now
        log(
            now: now,
            message: "extraction.\(sectionName(result.section)) completed (\(formatDurationSeconds(now &- start))) count=\(result.count)"
        )
        lock.unlock()
    }

    private func handleExtractionFailed(section: SwiftIndexEvents.Section, error: any Error) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let start = extractionSectionStart.removeValue(forKey: section) ?? now
        log(
            now: now,
            message: "extraction.\(sectionName(section)) failed (\(formatDurationSeconds(now &- start))): \(String(describing: error))"
        )
        lock.unlock()
    }

    private func log(now: UInt64, message: String) {
        let rel = formatDurationSeconds(now &- startNanos)
        fputs("privateheaderkit __raw-dump: swift-events [\(label)] +\(rel) \(message)\n", stderr)
    }

    private func formatDurationSeconds(_ nanos: UInt64) -> String {
        String(format: "%.3fs", Double(nanos) / 1_000_000_000.0)
    }

    private func phaseName(_ phase: SwiftIndexEvents.Phase) -> String {
        switch phase {
        case .preparation: return "preparation"
        case .extraction: return "extraction"
        case .indexing: return "indexing"
        case .moduleCollection: return "moduleCollection"
        case .build: return "build"
        }
    }

    private func operationName(_ op: SwiftIndexEvents.PhaseOperation) -> String {
        switch op {
        case .typeIndexing: return "typeIndexing"
        case .protocolIndexing: return "protocolIndexing"
        case .conformanceIndexing: return "conformanceIndexing"
        case .extensionIndexing: return "extensionIndexing"
        }
    }

    private func sectionName(_ section: SwiftIndexEvents.Section) -> String {
        switch section {
        case .swiftTypes: return "swiftTypes"
        case .swiftProtocols: return "swiftProtocols"
        case .protocolConformances: return "protocolConformances"
        case .associatedTypes: return "associatedTypes"
        case .symbolIndex: return "symbolIndex"
        }
    }
}

private struct PendingObjCHeaderFileName {
    let entry: ObjCHeaderEntry
    let fileName: String
    let collisionKey: String
}

private func caseInsensitiveFileNameKey(_ fileName: String) -> String {
    fileName.folding(options: [.caseInsensitive], locale: caseInsensitiveFileNameLocale)
}

private func collisionSuffix(for entry: ObjCHeaderEntry) -> String {
    "~\(stableHashHex("\(entry.symbolKind.rawValue):\(entry.rawIdentity)"))"
}

func resolveObjCHeaderEntries(_ entries: [ObjCHeaderEntry], options: DumpOptions) -> [ResolvedObjCHeaderEntry] {
    let sortedEntries = entries.sorted { lhs, rhs in
        if lhs.symbolKind != rhs.symbolKind {
            return lhs.symbolKind < rhs.symbolKind
        }
        if lhs.displayBaseName != rhs.displayBaseName {
            return lhs.displayBaseName < rhs.displayBaseName
        }
        if lhs.rawIdentity != rhs.rawIdentity {
            return lhs.rawIdentity < rhs.rawIdentity
        }
        return lhs.headerString < rhs.headerString
    }

    let pending = sortedEntries.map { entry in
        let fileName = safeFileName(baseName: entry.displayBaseName, extension: ".h")
        return PendingObjCHeaderFileName(
            entry: entry,
            fileName: fileName,
            collisionKey: caseInsensitiveFileNameKey(fileName)
        )
    }
    let grouped = Dictionary(grouping: pending, by: \.collisionKey)

    return pending.map { item in
        let hadCollision = (grouped[item.collisionKey]?.count ?? 0) > 1
        let resolvedFileName: String
        if hadCollision {
            resolvedFileName = safeFileName(
                baseName: item.entry.displayBaseName,
                suffix: collisionSuffix(for: item.entry),
                extension: ".h"
            )
            if options.verbose {
                fputs(
                    "privateheaderkit __raw-dump: resolved case-insensitive header name collision \(item.entry.symbolKind.rawValue):\(item.entry.rawIdentity) -> \(resolvedFileName)\n",
                    stderr
                )
            }
        } else {
            resolvedFileName = item.fileName
        }

        return ResolvedObjCHeaderEntry(
            symbolKind: item.entry.symbolKind,
            rawIdentity: item.entry.rawIdentity,
            displayBaseName: item.entry.displayBaseName,
            headerString: item.entry.headerString,
            fileName: resolvedFileName,
            hadNameCollision: hadCollision
        )
    }
}

private func dumpObjC(
    machO: RawMachO,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) async throws {
    var metadata = switch machO {
    case .file(let file):
        collectObjCMetadata(from: file.objc, in: machO, options: options)
    case .loaded(let image):
        collectObjCMetadata(from: image.objc, in: machO, options: options)
    }

#if canImport(ObjectiveC)
    if options.useRuntimeFallback {
        let runtimeInfos = await runtimeClassInfos(
            for: imagePath,
            onlyOneClass: options.onlyOneClass,
            verbose: options.verbose
        )
        if options.verbose, !runtimeInfos.isEmpty {
            fputs(
                "privateheaderkit __raw-dump: runtime fallback added \(runtimeInfos.count) classes for \(imagePath)\n",
                stderr
            )
        }
        metadata.runtimeOriginClassNames = supplementMissingRuntimeClassInfos(
            runtimeInfos,
            into: &metadata.classInfos
        )
    }
#endif

    try writeObjCMetadata(
        metadata,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
}

private struct CollectedObjCMetadata {
    var classInfos: [String: ObjCClassInfo] = [:]
    var protocolInfos: [String: ObjCProtocolInfo] = [:]
    var categoryInfos: [String: ObjCCategoryInfo] = [:]
    var runtimeOriginClassNames: Set<String> = []
}

@discardableResult
func supplementMissingRuntimeClassInfos(
    _ runtimeInfos: [ObjCClassInfo],
    into classInfos: inout [String: ObjCClassInfo]
) -> Set<String> {
    var logicalIdentities = Set(classInfos.values.map {
        logicalClassIdentity(name: $0.name, runtimeOrigin: false)
    })
    var insertedNames: Set<String> = []
    for info in runtimeInfos.sorted(by: { runtimeClassSortKey($0.name) < runtimeClassSortKey($1.name) }) {
        guard classInfos[info.name] == nil else { continue }
        let logicalIdentity = logicalClassIdentity(name: info.name, runtimeOrigin: true)
        guard logicalIdentities.insert(logicalIdentity).inserted else { continue }
        classInfos[info.name] = info
        insertedNames.insert(info.name)
    }
    return insertedNames
}

private func logicalClassIdentity(name: String, runtimeOrigin: Bool) -> String {
    let lookup = runtimeOrigin
        ? SwiftObjCNameResolver.resolveRuntimeOriginClassName(name)
        : SwiftObjCNameResolver.resolve(name)
    if case .resolved(let resolved) = lookup, resolved.kind == .class {
        // Runtime-qualified names have no intrinsic mangling tree. Bridge them to
        // static metadata only through the explicit kind + display projection.
        return "swift-display:class:\(resolved.displayName.utf8.count):\(resolved.displayName)"
    }
    return "objc:\(name)"
}

private func runtimeClassSortKey(_ name: String) -> String {
    let rank: Int
    if case .resolved(let resolved) = SwiftObjCNameResolver.resolve(name),
       resolved.source == .objcRuntimeName {
        rank = 0
    } else if case .resolved = SwiftObjCNameResolver.resolveRuntimeOriginClassName(name) {
        rank = 1
    } else {
        rank = 2
    }
    return "\(rank):\(name)"
}

private func collectObjCMetadata<Section: ObjCSectionRepresentable>(
    from objc: Section,
    in machO: RawMachO,
    options: DumpOptions
) -> CollectedObjCMetadata {
    var metadata = CollectedObjCMetadata()

    if let list = objc.classes64 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }
    if let list = objc.classes32 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }
    if let list = objc.nonLazyClasses64 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }
    if let list = objc.nonLazyClasses32 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }

    var protocolCandidates: [any ObjCProtocolProtocol] = []
    if let list = objc.protocols64 { protocolCandidates.append(contentsOf: list) }
    if let list = objc.protocols32 { protocolCandidates.append(contentsOf: list) }

    for proto in protocolCandidates {
        if let info = protocolInfo(
            proto,
            in: machO,
            diagnostics: options.objcDiagnostics
        ) {
            metadata.protocolInfos[info.name] = info
        }
    }

    var categoryCandidates: [any ObjCCategoryProtocol] = []
    if let list = objc.categories64 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.categories32 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.nonLazyCategories64 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.nonLazyCategories32 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.categories2_64 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.categories2_32 { categoryCandidates.append(contentsOf: list) }

    for category in categoryCandidates {
        if let info = categoryInfo(
            category,
            in: machO,
            diagnostics: options.objcDiagnostics
        ) {
            let key = "\(info.className)(\(info.name))"
            metadata.categoryInfos[key] = info
        }
    }

    return metadata
}

private func writeObjCMetadata(
    _ metadata: CollectedObjCMetadata,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) throws {
    let classInfos = metadata.classInfos
    let protocolInfos = metadata.protocolInfos
    let categoryInfos = metadata.categoryInfos

    try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

    var entries: [ObjCHeaderEntry] = []
    entries.reserveCapacity(classInfos.count + protocolInfos.count + categoryInfos.count)

    for info in classInfos.values {
        if let only = options.onlyOneClass, only != info.name { continue }
        if !isSaneObjCTypeName(info.name) {
            if options.verbose {
                fputs("privateheaderkit __raw-dump: skip invalid class name: \(String(reflecting: info.name))\n", stderr)
            }
            continue
        }
        entries.append(
            SwiftObjCHeaderRendering.classEntry(
                info,
                runtimeOrigin: metadata.runtimeOriginClassNames.contains(info.name)
            )
        )
    }

    for info in protocolInfos.values {
        if let only = options.onlyOneClass, only != info.name { continue }
        if !isSaneObjCTypeName(info.name) {
            if options.verbose {
                fputs("privateheaderkit __raw-dump: skip invalid protocol name: \(String(reflecting: info.name))\n", stderr)
            }
            continue
        }
        entries.append(SwiftObjCHeaderRendering.protocolEntry(info))
    }

    for info in categoryInfos.values {
        if let only = options.onlyOneClass, only != info.className && only != info.name { continue }
        if !isSaneObjCTypeName(info.className) || !isSaneObjCTypeName(info.name) {
            if options.verbose {
                fputs(
                    "privateheaderkit __raw-dump: skip invalid category name: class=\(String(reflecting: info.className)) category=\(String(reflecting: info.name))\n",
                    stderr
                )
            }
            continue
        }
        entries.append(SwiftObjCHeaderRendering.categoryEntry(info))
    }

    for entry in resolveObjCHeaderEntries(entries, options: options) {
        let fileURL = outputDir.appendingPathComponent(entry.fileName)
        try writeIfNeeded(text: entry.headerString, to: fileURL, options: options, fileManager: fileManager)
    }
}

#if canImport(ObjectiveC)
private func runtimePropertyInfo(
    from snapshot: PHRuntimeObjCPropertySnapshot
) -> ObjCPropertyInfo {
    ObjCPropertyInfo(
        name: snapshot.name,
        attributesString: snapshot.attributesString,
        isClassProperty: snapshot.isClassProperty
    )
}

private func runtimeMethodInfo(
    from snapshot: PHRuntimeObjCMethodSnapshot
) -> ObjCMethodInfo {
    ObjCMethodInfo(
        name: snapshot.name,
        typeEncoding: snapshot.typeEncoding,
        isClassMethod: snapshot.isClassMethod,
        imp: 0
    )
}

private func runtimeIvarInfo(
    from snapshot: PHRuntimeObjCIvarSnapshot
) -> ObjCIvarInfo {
    ObjCIvarInfo(
        name: snapshot.name,
        typeEncoding: snapshot.typeEncoding,
        offset: Int(snapshot.offset)
    )
}

private func runtimeProtocolInfo(
    from snapshot: PHRuntimeObjCProtocolSnapshot
) -> ObjCProtocolInfo {
    ObjCProtocolInfo(
        name: snapshot.name,
        protocols: snapshot.protocols.map(runtimeProtocolInfo(from:)),
        classProperties: snapshot.classProperties.map(runtimePropertyInfo(from:)),
        properties: snapshot.properties.map(runtimePropertyInfo(from:)),
        classMethods: snapshot.classMethods.map(runtimeMethodInfo(from:)),
        methods: snapshot.methods.map(runtimeMethodInfo(from:)),
        optionalClassProperties: snapshot.optionalClassProperties.map(runtimePropertyInfo(from:)),
        optionalProperties: snapshot.optionalProperties.map(runtimePropertyInfo(from:)),
        optionalClassMethods: snapshot.optionalClassMethods.map(runtimeMethodInfo(from:)),
        optionalMethods: snapshot.optionalMethods.map(runtimeMethodInfo(from:))
    )
}

@MainActor
private func runtimeClassInfo(
    for cls: AnyClass,
    runtimeOriginName: String,
    imagePath: String,
    verbose: Bool
) -> ObjCClassInfo? {
    var failedStage: NSString?
    guard let snapshot = PHRuntimeObjCInspector.snapshot(for: cls, failedStage: &failedStage) else {
        if verbose {
            let stage = (failedStage as String?) ?? "unknown"
            fputs(
                "privateheaderkit __raw-dump: runtime fallback skip class \(runtimeOriginName) image=\(imagePath) stage=\(stage)\n",
                stderr
            )
        }
        return nil
    }

    // The caller-provided runtime-origin spelling owns identity. The primary path
    // uses `objc_copyClassNamesForImage`; its `class_getName` fallback may instead
    // provide a qualified `Module.Type` name on current runtimes.
    return ObjCClassInfo(
        name: runtimeOriginName,
        version: snapshot.version,
        imageName: snapshot.imageName,
        instanceSize: Int(snapshot.instanceSize),
        superClassName: snapshot.superclassObjCRuntimeName,
        protocols: snapshot.protocols.map(runtimeProtocolInfo(from:)),
        ivars: snapshot.ivars.map(runtimeIvarInfo(from:)),
        classProperties: snapshot.classProperties.map(runtimePropertyInfo(from:)),
        properties: snapshot.properties.map(runtimePropertyInfo(from:)),
        classMethods: snapshot.classMethods.map(runtimeMethodInfo(from:)),
        methods: snapshot.methods.map(runtimeMethodInfo(from:))
    )
}

@MainActor
func withLoadedRuntimeImage<Result: Sendable>(
    at path: String,
    open: @MainActor @Sendable (String) -> UnsafeMutableRawPointer? = {
        dlopen($0, RTLD_LAZY)
    },
    close: @MainActor @Sendable (UnsafeMutableRawPointer) -> Void = {
        _ = dlclose($0)
    },
    inspect: @MainActor @Sendable (UnsafeMutableRawPointer) throws -> Result
) rethrows -> Result? {
    guard let handle = open(path) else { return nil }
    defer { close(handle) }
    return try inspect(handle)
}

@MainActor
private func runtimeClassInfos(
    for imagePath: String,
    onlyOneClass: String?,
    verbose: Bool
) -> [ObjCClassInfo] {
    let targetPaths = runtimeFallbackTargetImagePaths(for: imagePath)
    let resolvedPath = resolveRuntimeURL(URL(fileURLWithPath: imagePath)).path
    guard let infos = withLoadedRuntimeImage(
        at: resolvedPath,
        inspect: { _ in
            var count: UInt32 = 0
            guard let namesPtr = objc_copyClassNamesForImage(resolvedPath, &count) else {
                if verbose {
                    fputs(
                        "privateheaderkit __raw-dump: runtime fallback objc_copyClassNamesForImage returned nil for \(resolvedPath)\n",
                        stderr
                    )
                }
                return runtimeClassInfosByImageName(
                    targetPaths: targetPaths,
                    imagePath: imagePath,
                    onlyOneClass: onlyOneClass,
                    verbose: verbose
                )
            }
            defer { free(namesPtr) }

            if count == 0 {
                if verbose {
                    fputs(
                        "privateheaderkit __raw-dump: runtime fallback objc_copyClassNamesForImage returned 0 classes for \(resolvedPath)\n",
                        stderr
                    )
                }
                return runtimeClassInfosByImageName(
                    targetPaths: targetPaths,
                    imagePath: imagePath,
                    onlyOneClass: onlyOneClass,
                    verbose: verbose
                )
            }

            let names = UnsafeBufferPointer(start: namesPtr, count: Int(count))
            var infos: [ObjCClassInfo] = []
            infos.reserveCapacity(Int(count))

            for namePtr in names {
                let name = String(cString: namePtr)
                if let onlyOneClass, onlyOneClass != name { continue }
                if let cls = NSClassFromString(name) ?? (objc_getClass(name) as? AnyClass) {
                    if let info = runtimeClassInfo(
                        for: cls,
                        runtimeOriginName: name,
                        imagePath: imagePath,
                        verbose: verbose
                    ) {
                        infos.append(info)
                    }
                }
            }
            if infos.isEmpty {
                return runtimeClassInfosByImageName(
                    targetPaths: targetPaths,
                    imagePath: imagePath,
                    onlyOneClass: onlyOneClass,
                    verbose: verbose
                )
            }
            return infos
        }
    ) else {
        if verbose {
            fputs("privateheaderkit __raw-dump: runtime dlopen failed for \(resolvedPath)\n", stderr)
        }
        return []
    }
    return infos
}

@MainActor
private func runtimeClassInfosByImageName(
    targetPaths: Set<String>,
    imagePath: String,
    onlyOneClass: String?,
    verbose: Bool
) -> [ObjCClassInfo] {
    let initialCount = objc_getClassList(nil, 0)
    if initialCount <= 0 { return [] }

    let buffer = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(initialCount))
    defer { buffer.deallocate() }

    let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), initialCount)
    if count <= 0 { return [] }
    let cappedCount = min(count, initialCount)

    var infos: [ObjCClassInfo] = []
    infos.reserveCapacity(Int(cappedCount))

    for index in 0..<Int(cappedCount) {
        guard let cls = buffer[index] else { continue }
        guard let imageNamePtr = class_getImageName(cls) else { continue }
        let imageName = String(cString: imageNamePtr)
        let normalizedImage = normalizedImagePath(stripRuntimeRoot(from: imageName))
        if !targetPaths.contains(normalizedImage) { continue }

        let name = String(cString: class_getName(cls))
        if let onlyOneClass, onlyOneClass != name { continue }
        if let info = runtimeClassInfo(
            for: cls,
            runtimeOriginName: name,
            imagePath: imagePath,
            verbose: verbose
        ) {
            infos.append(info)
        }
    }

    if verbose, !infos.isEmpty {
        fputs(
            "privateheaderkit __raw-dump: runtime fallback class_getImageName matched \(infos.count) classes for \(imagePath)\n",
            stderr
        )
    }
    return infos
}

func runtimeFallbackTargetImagePaths(
    for imagePath: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Set<String> {
    Set(
        normalizedCacheImagePaths(for: imagePath, environment: environment).map {
            normalizedImagePath(stripRuntimeRoot(from: $0, environment: environment))
        }
    )
}

private func normalizedImagePath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}
#endif

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: RawMachO,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    switch machO {
    case .file(let file):
        collectClassInfos(classes, in: file, options: options, classInfos: &classInfos)
    case .loaded(let image):
        collectClassInfos(classes, in: image, options: options, classInfos: &classInfos)
    }
}

private func protocolInfo(
    _ proto: any ObjCProtocolProtocol,
    in machO: RawMachO,
    diagnostics: RawDumpObjCDiagnosticsAccumulator
) -> ObjCProtocolInfo? {
    let options = rawDumpObjCProtocolInfoOptions(for: .protocol)
    switch machO {
    case .file(let file):
        let result = proto.readInfo(in: file, options: options)
        diagnostics.append(contentsOf: result.diagnostics)
        return result.value
    case .loaded(let image):
        let result = proto.readInfo(in: image, options: options)
        diagnostics.append(contentsOf: result.diagnostics)
        return result.value
    }
}

private func categoryInfo(
    _ category: any ObjCCategoryProtocol,
    in machO: RawMachO,
    diagnostics: RawDumpObjCDiagnosticsAccumulator
) -> ObjCCategoryInfo? {
    let options = rawDumpObjCInfoOptions(for: .category)
    switch machO {
    case .file(let file):
        let result = category.readInfo(in: file, options: options)
        diagnostics.append(contentsOf: result.diagnostics)
        return result.value
    case .loaded(let image):
        let result = category.readInfo(in: image, options: options)
        diagnostics.append(contentsOf: result.diagnostics)
        return result.value
    }
}

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: MachOFile,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    let readOptions = rawDumpObjCInfoOptions(for: .class)
    for cls in classes {
        let result = cls.readInfo(in: machO, options: readOptions)
        options.objcDiagnostics.append(contentsOf: result.diagnostics)
        options.objcDiagnostics.append(contentsOf: result.memberListDiagnostics)
        if let info = result.value {
            classInfos[info.name] = info
        } else if options.verbose && options.logSkippedClasses {
            logClassInfoFailure(cls, in: machO)
        }
    }
}

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: MachOImage,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    let readOptions = rawDumpObjCInfoOptions(for: .class)
    for cls in classes {
        let result = cls.readInfo(in: machO, options: readOptions)
        options.objcDiagnostics.append(contentsOf: result.diagnostics)
        options.objcDiagnostics.append(contentsOf: result.memberListDiagnostics)
        if let info = result.value {
            classInfos[info.name] = info
        } else if options.verbose && options.logSkippedClasses {
            logClassInfoFailure(cls, in: machO)
        }
    }
}

private func logClassInfoFailure<T: ObjCClassProtocol>(
    _ cls: T,
    in machO: MachOFile
) {
    let data = cls.classROData(in: machO)
    let meta = cls.metaClass(in: machO)
    let metaData = meta.flatMap { $0.1.classROData(in: $0.0) }
    let name = data?.name(in: machO)
    var missing: [String] = []
    if data == nil { missing.append("classROData") }
    if meta == nil { missing.append("metaClass") }
    if metaData == nil { missing.append("metaClassROData") }
    if name == nil { missing.append("name") }
    let missingText = missing.isEmpty ? "unknown" : missing.joined(separator: ",")
    let displayName = name ?? "<unknown>"
    let metaImage = meta?.0.imagePath ?? "<nil>"
    fputs(
        "privateheaderkit __raw-dump: skip class \(displayName) (offset=\(cls.offset)) image=\(machO.imagePath) metaImage=\(metaImage) missing=\(missingText)\n",
        stderr
    )
}

private func logClassInfoFailure<T: ObjCClassProtocol>(
    _ cls: T,
    in machO: MachOImage
) {
    let data = cls.classROData(in: machO)
    let meta = cls.metaClass(in: machO)
    let metaData = meta.flatMap { $0.1.classROData(in: $0.0) }
    let name = data?.name(in: machO)
    var missing: [String] = []
    if data == nil { missing.append("classROData") }
    if meta == nil { missing.append("metaClass") }
    if metaData == nil { missing.append("metaClassROData") }
    if name == nil { missing.append("name") }
    let missingText = missing.isEmpty ? "unknown" : missing.joined(separator: ",")
    let displayName = name ?? "<unknown>"
    let imagePath = machO.path ?? "<unknown>"
    let metaImage = meta?.0.path ?? "<nil>"
    fputs(
        "privateheaderkit __raw-dump: skip class \(displayName) (offset=\(cls.offset)) image=\(imagePath) metaImage=\(metaImage) missing=\(missingText)\n",
        stderr
    )
}

private func dumpSwift(
    machO: RawMachO,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    interfaceBuilderFactory: SwiftInterfaceBuildingFactory,
    fileManager: FileManager
) async throws {
    switch machO {
    case .file(let file):
        try await dumpSwift(
            machO: file,
            imagePath: imagePath,
            outputDir: outputDir,
            options: options,
            interfaceBuilderFactory: interfaceBuilderFactory,
            fileManager: fileManager
        )
    case .loaded(let image):
        try await dumpSwift(
            machO: image,
            imagePath: imagePath,
            outputDir: outputDir,
            options: options,
            interfaceBuilderFactory: interfaceBuilderFactory,
            fileManager: fileManager
        )
    }
}

func dumpSwift(
    machO: MachOFile,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    interfaceBuilderFactory: SwiftInterfaceBuildingFactory = DefaultSwiftInterfaceBuilderFactory(),
    fileManager: FileManager
) async throws {
    if shouldSkipSwiftInterface(imagePath: imagePath, outputDir: outputDir, options: options, fileManager: fileManager) {
        return
    }
    let builder = try interfaceBuilderFactory.makeBuilder(machO: machO)
    try await dumpSwift(
        builder: builder,
        imagePath: imagePath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
}

func dumpSwift(
    machO: MachOImage,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    interfaceBuilderFactory: SwiftInterfaceBuildingFactory = DefaultSwiftInterfaceBuilderFactory(),
    fileManager: FileManager
) async throws {
    if shouldSkipSwiftInterface(imagePath: imagePath, outputDir: outputDir, options: options, fileManager: fileManager) {
        return
    }
    let builder = try interfaceBuilderFactory.makeBuilder(machO: machO)
    try await dumpSwift(
        builder: builder,
        imagePath: imagePath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
}

private func dumpSwift(
    builder: SwiftInterfaceBuilding,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) async throws {
    try await dumpSwiftInterface(
        imagePath: imagePath,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager,
        buildInterface: {
            let prepareStart = profileNowNanoseconds(enabled: options.profile)
            try await builder.prepare()
            profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpSwift.prepare", since: prepareStart)

            let printStart = profileNowNanoseconds(enabled: options.profile)
            let text = try await builder.printRoot()
            profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpSwift.printRoot", since: printStart)
            return text
        }
    )
}

func swiftInterfaceOutputURL(imagePath: String, outputDir: URL) -> URL {
    let moduleName = URL(fileURLWithPath: imagePath).lastPathComponent
    return outputDir.appendingPathComponent("\(moduleName).swiftinterface")
}

func shouldSkipSwiftInterface(
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileExistenceChecking
) -> Bool {
    options.skipExisting && fileManager.fileExists(atPath: swiftInterfaceOutputURL(imagePath: imagePath, outputDir: outputDir).path)
}

func dumpSwiftInterface(
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager,
    buildInterface: () async throws -> String
) async throws {
    let outputURL = swiftInterfaceOutputURL(imagePath: imagePath, outputDir: outputDir)

    if shouldSkipSwiftInterface(imagePath: imagePath, outputDir: outputDir, options: options, fileManager: fileManager) {
        return
    }

    do {
        let text = try await withSilencedStdout(!options.verbose) {
            try await buildInterface()
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let writeStart = profileNowNanoseconds(enabled: options.profile)
        try text.write(to: outputURL, atomically: true, encoding: .utf8)
        profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpSwift.writeFile", since: writeStart)
    } catch {
        if options.verbose {
            fputs("Swift interface generation failed for \(imagePath): \(error)\n", stderr)
        }
        throw error
    }
}

private func writeIfNeeded(
    text: String,
    to url: URL,
    options: DumpOptions,
    fileManager: FileManager
) throws {
    if options.skipExisting && fileManager.fileExists(atPath: url.path) {
        return
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
}
