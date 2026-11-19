import Foundation
@_spi(Support) import MachOKit
import MachOObjCSection
import PrivateHeaderKitExecutableResolution
import PrivateHeaderKitHelperProtocol
#if canImport(ObjectiveC)
import ObjectiveC
import PrivateHeaderKitRawDumpRuntimeObjC
#endif

protocol FileExistenceChecking {
    func fileExists(atPath: String) -> Bool
}

extension FileManager: FileExistenceChecking {}

func runtimeRootPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
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
            try await dumpImage(
                resolveBundleExecutable(url, fileManager: fileManager),
                options: options,
                fileManager: fileManager,
                machOLoader: machOLoader
            )
            continue
        }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
              values.isDirectory == false,
              values.isRegularFile == true
        else { continue }

        try await dumpImage(
            .direct(url),
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
    if isBundleDirectory(resolvedURL) {
        try await dumpImage(
            resolveBundleExecutable(resolvedURL, fileManager: fileManager),
            options: options,
            fileManager: fileManager,
            machOLoader: machOLoader
        )
        return
    }
    try await dumpImage(
        .direct(resolvedURL),
        options: options,
        fileManager: fileManager,
        machOLoader: machOLoader
    )
}

let supportedBundlePathExtensions: Set<String> = [
    "framework", "app", "bundle", "xpc", "appex",
]

func isBundleDirectory(_ url: URL) -> Bool {
    guard supportedBundlePathExtensions.contains(url.pathExtension.lowercased()) else {
        return false
    }

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

func resolveBundleExecutable(
    _ bundleURL: URL,
    fileManager: FileExistenceChecking = FileManager.default,
    bundleExecutableURL: (URL) -> URL? = { Bundle(url: $0)?.executableURL }
) -> ExecutableResolution {
    ExecutableResolution.resolveBundle(
        bundleURL,
        fileExists: fileManager.fileExists(atPath:),
        bundleExecutableURL: bundleExecutableURL
    )
}

private func dumpImage(
    _ executable: ExecutableResolution,
    options: DumpOptions,
    fileManager: FileManager,
    machOLoader: RawMachOLoader
) async throws {
    let imagePath = options.logicalImagePath ?? stripRuntimeRoot(from: executable.loadURL.path)
    let placement = outputPlacement(
        for: executable,
        outputRoot: options.outputDir,
        options: options
    )
    let loadStart = profileNowNanoseconds(enabled: options.profile)
    guard let machO = try machOLoader.load(url: executable.loadURL) else {
        return
    }
    profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "loadMachO", since: loadStart)
    try machO.validateFileBackedChainedFixups()

    if options.verbose {
        print("Dumping: \(placement.identity.url.path)")
    }

    try dumpSymbols(
        machO: machO,
        imagePath: imagePath,
        outputDir: placement.directory,
        options: options
    )

    let objcStart = profileNowNanoseconds(enabled: options.profile)
    try await dumpObjC(
        machO: machO,
        imagePath: imagePath,
        outputDir: placement.directory,
        options: options,
        fileManager: fileManager
    )
    profileLogDuration(enabled: options.profile, imagePath: imagePath, name: "dumpObjC", since: objcStart)

    try await dumpSwift(
        machO: machO,
        imagePath: imagePath,
        outputDir: placement.directory,
        options: options,
        interfaceBuilderFactory: defaultSwiftInterfaceBuilderFactory(
            imagePath: imagePath,
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
