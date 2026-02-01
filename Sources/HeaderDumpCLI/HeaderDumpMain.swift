import Foundation
import MachOKit
import MachOObjCSection
import ObjCDump
import MachOSwiftSection
@_spi(Support) import SwiftInterface
#if canImport(ObjectiveC)
import ObjectiveC
import Darwin
#endif

private struct DumpOptions {
    var outputDir: URL
    var recursive: Bool = false
    var buildOriginalDirs: Bool = false
    var addHeadersFolder: Bool = false
    var skipExisting: Bool = false
    var onlyOneClass: String? = nil
    var useSharedCache: Bool = false
    var verbose: Bool = false
    var useRuntimeFallback: Bool = false
    var logSkippedClasses: Bool = false
}

@main
struct HeaderDumpCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let parsed = parseArguments(args) else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        do {
            try await run(parsed: parsed)
        } catch {
            fputs("classdump-dyld: error: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

private struct ParsedArguments {
    let options: DumpOptions
    let inputPath: String
}

private func parseArguments(_ args: [String]) -> ParsedArguments? {
    var options = DumpOptions(outputDir: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    var inputPath: String? = nil
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--help":
            printUsage()
            exit(EXIT_SUCCESS)
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
        case "-D":
            options.verbose = true
        case "-R":
            options.useRuntimeFallback = true
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
    if !options.useRuntimeFallback {
        options.useRuntimeFallback = shouldUseRuntimeFallback()
    }
    options.logSkippedClasses = shouldLogSkippedClasses()
    return ParsedArguments(options: options, inputPath: inputPath)
}

private func printUsage() {
    let text = """
    Usage: classdump-dyld [<options>] <filename|framework>
           classdump-dyld [<options>] -r <sourcePath>

    Options:
        -o   Output directory
        -r   Recursive search
        -b   Build original directories
        -h   Add Headers folder for bundles
        -s   Skip already found files
        -j   Only dump a single class/protocol name
        -c   Attempt dyld shared cache lookup when file is missing
        -D   Verbose logging
        -R   Prefer Objective-C runtime metadata (auto-enabled in simulator)
    """
    print(text)
}

private func shouldUseRuntimeFallback() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["PH_RUNTIME_ROOT"] != nil || env["SIMCTL_CHILD_PH_RUNTIME_ROOT"] != nil
}

private func shouldLogSkippedClasses() -> Bool {
    ProcessInfo.processInfo.environment["PH_VERBOSE_SKIP"] == "1"
}

private func runtimeRootPath() -> String? {
    let env = ProcessInfo.processInfo.environment
    return env["PH_RUNTIME_ROOT"] ?? env["SIMCTL_CHILD_PH_RUNTIME_ROOT"]
}

private func resolveRuntimeURL(_ url: URL) -> URL {
    guard let runtimeRoot = runtimeRootPath() else { return url }
    let path = url.standardizedFileURL.path
    guard path.hasPrefix("/") else { return url }
    let candidate = URL(fileURLWithPath: runtimeRoot).appendingPathComponent(String(path.dropFirst()))
    if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    return url
}

private func stripRuntimeRoot(from path: String) -> String {
    guard let runtimeRoot = runtimeRootPath() else { return path }
    if path.hasPrefix(runtimeRoot) {
        var trimmed = path.dropFirst(runtimeRoot.count)
        if trimmed.first == "/" {
            trimmed = trimmed.dropFirst()
        }
        return "/" + trimmed
    }
    return path
}

private func run(parsed: ParsedArguments) async throws {
    let options = parsed.options
    let inputPath = parsed.inputPath
    let fileManager = FileManager.default

    if options.recursive {
        try await dumpRecursive(inputPath: inputPath, options: options, fileManager: fileManager)
    } else {
        try await dumpSingle(inputPath: inputPath, options: options, fileManager: fileManager)
    }
}

private func dumpRecursive(inputPath: String, options: DumpOptions, fileManager: FileManager) async throws {
    let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
    let rootURL = resolveRuntimeURL(inputURL)
    guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw NSError(domain: "classdump-dyld", code: 1, userInfo: [NSLocalizedDescriptionKey: "Directory not found: \(inputPath)"])
    }

    while let url = enumerator.nextObject() as? URL {
        if isBundleDirectory(url) {
            enumerator.skipDescendants()
            if let executableURL = resolveBundleExecutableURL(url) {
                let originalPath = stripRuntimeRoot(from: executableURL.path)
                try await dumpImage(executableURL, originalPath: originalPath, options: options, fileManager: fileManager)
            }
            continue
        }

        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
              values.isDirectory == false,
              values.isRegularFile == true
        else { continue }

        let originalPath = stripRuntimeRoot(from: url.path)
        try await dumpImage(url, originalPath: originalPath, options: options, fileManager: fileManager)
    }
}

private func dumpSingle(inputPath: String, options: DumpOptions, fileManager: FileManager) async throws {
    let originalURL = URL(fileURLWithPath: inputPath)
    let resolvedURL = resolveRuntimeURL(originalURL)
    if isBundleDirectory(resolvedURL), let executableURL = resolveBundleExecutableURL(resolvedURL) {
        let originalPath = stripRuntimeRoot(from: executableURL.path)
        try await dumpImage(executableURL, originalPath: originalPath, options: options, fileManager: fileManager)
        return
    }
    let originalPath = stripRuntimeRoot(from: resolvedURL.path)
    try await dumpImage(resolvedURL, originalPath: originalPath, options: options, fileManager: fileManager)
}

private func isBundleDirectory(_ url: URL) -> Bool {
    guard url.hasDirectoryPath else { return false }
    let ext = url.pathExtension.lowercased()
    return ext == "framework" || ext == "app" || ext == "bundle"
}

private func resolveBundleExecutableURL(_ bundleURL: URL) -> URL? {
    if let bundle = Bundle(url: bundleURL), let executableURL = bundle.executableURL {
        return executableURL
    }

    let baseName = bundleURL.deletingPathExtension().lastPathComponent
    let candidates = [
        bundleURL.appendingPathComponent(baseName),
        bundleURL.appendingPathComponent("Versions/Current/\(baseName)"),
        bundleURL.appendingPathComponent("Versions/A/\(baseName)"),
        bundleURL.appendingPathComponent("Versions/B/\(baseName)"),
        bundleURL.appendingPathComponent("Versions/C/\(baseName)")
    ]
    for candidate in candidates {
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func dumpImage(
    _ url: URL,
    originalPath: String,
    options: DumpOptions,
    fileManager: FileManager
) async throws {
    guard let machO = loadMachOFile(url: url, options: options) else {
        return
    }

    let outputDir = writeDirectory(for: originalPath, outputRoot: options.outputDir, options: options)
    if options.verbose {
        print("Dumping: \(originalPath)")
    }

    try dumpObjC(machO: machO, imagePath: originalPath, outputDir: outputDir, options: options, fileManager: fileManager)
    try await dumpSwift(machO: machO, imagePath: originalPath, outputDir: outputDir, options: options, fileManager: fileManager)
}

private func loadMachOFile(url: URL, options: DumpOptions) -> MachOFile? {
    if options.useSharedCache, let cached = loadFromSharedCache(imagePath: url.path) {
        return cached
    }
    do {
        let file = try loadFromFile(url: url)
        switch file {
        case .machO(let machO):
            return isSupported(machO) ? machO : nil
        case .fat(let fat):
            let machOFiles = try fat.machOFiles()
            if let match = machOFiles.first(where: { isSupported($0) }) {
                return match
            }
            return nil
        }
    } catch {
        if options.useSharedCache {
            return loadFromSharedCache(imagePath: url.path)
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

private func loadFromSharedCache(imagePath: String) -> MachOFile? {
    let cachePath = sharedCachePath()
    guard let fullCache = try? FullDyldCache(url: URL(fileURLWithPath: cachePath)) else {
        return nil
    }
    let candidates = normalizedCacheImagePaths(for: imagePath)
    if let match = fullCache.machOFiles().first(where: { candidates.contains($0.imagePath) }) {
        return match
    }
    for candidate in candidates {
        if let match = fullCache.machOFiles().first(where: { $0.imagePath.hasSuffix(candidate) }) {
            return match
        }
    }
    return nil
}

private func normalizedCacheImagePaths(for path: String) -> [String] {
    var results: [String] = [path]

    let env = ProcessInfo.processInfo.environment
    let rootCandidates = [
        env["PH_RUNTIME_ROOT"],
        env["DYLD_ROOT_PATH"],
        env["SIMCTL_CHILD_DYLD_ROOT_PATH"]
    ].compactMap { $0 }

    for runtimeRoot in rootCandidates {
        let trimmedRoot = runtimeRoot.hasSuffix("/") ? String(runtimeRoot.dropLast()) : runtimeRoot
        if path.hasPrefix(trimmedRoot + "/") {
            let suffix = String(path.dropFirst(trimmedRoot.count))
            if !suffix.isEmpty {
                results.append(suffix)
            }
        }
    }

    if let range = path.range(of: "/System/Library/") {
        results.append(String(path[range.lowerBound...]))
    }
    if let range = path.range(of: "/usr/lib/") {
        results.append(String(path[range.lowerBound...]))
    }

    var unique: [String] = []
    for item in results where !unique.contains(item) {
        unique.append(item)
    }
    return unique
}

private func sharedCachePath() -> String {
    let env = ProcessInfo.processInfo.environment
    let rootCandidates = [
        env["PH_RUNTIME_ROOT"],
        env["DYLD_ROOT_PATH"],
        env["SIMCTL_CHILD_DYLD_ROOT_PATH"]
    ].compactMap { $0 }

    for runtimeRoot in rootCandidates {
        let candidate = URL(fileURLWithPath: runtimeRoot)
            .appendingPathComponent("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }

        let arm64Candidate = URL(fileURLWithPath: runtimeRoot)
            .appendingPathComponent("System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64")
        if FileManager.default.fileExists(atPath: arm64Candidate.path) {
            return arm64Candidate.path
        }
    }

    let primary = "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
    if FileManager.default.fileExists(atPath: primary) {
        return primary
    }

    let candidates = [
        "/private/var/db/dyld/dyld_shared_cache_arm64e",
        "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64",
        "/private/var/db/dyld/dyld_shared_cache_arm64"
    ]
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
        return candidate
    }
    return primary
}

private func writeDirectory(for imagePath: String, outputRoot: URL, options: DumpOptions) -> URL {
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

private func normalizePath(_ path: String) -> String {
    var normalized = path
    while normalized.contains("//") {
        normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    return normalized
}

private func dumpObjC(
    machO: MachOFile,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) throws {
    let objc = machO.objc
    var classInfos: [String: ObjCClassInfo] = [:]
    var protocolInfos: [String: ObjCProtocolInfo] = [:]
    var categoryInfos: [String: ObjCCategoryInfo] = [:]

    if let list = objc.classes64 {
        collectClassInfos(list, in: machO, options: options, classInfos: &classInfos)
    }
    if let list = objc.classes32 {
        collectClassInfos(list, in: machO, options: options, classInfos: &classInfos)
    }
    if let list = objc.nonLazyClasses64 {
        collectClassInfos(list, in: machO, options: options, classInfos: &classInfos)
    }
    if let list = objc.nonLazyClasses32 {
        collectClassInfos(list, in: machO, options: options, classInfos: &classInfos)
    }

#if canImport(ObjectiveC)
    if options.useRuntimeFallback {
        let runtimeInfos = runtimeClassInfos(for: imagePath, options: options)
        if options.verbose, !runtimeInfos.isEmpty {
            fputs(
                "classdump-dyld: runtime fallback added \(runtimeInfos.count) classes for \(imagePath)\n",
                stderr
            )
        }
        for info in runtimeInfos {
            if classInfos[info.name] == nil {
                classInfos[info.name] = info
            }
        }
    }
#endif

    var protocolCandidates: [any ObjCProtocolProtocol] = []
    if let list = objc.protocols64 { protocolCandidates.append(contentsOf: list) }
    if let list = objc.protocols32 { protocolCandidates.append(contentsOf: list) }

    for proto in protocolCandidates {
        if let info = proto.info(in: machO) {
            protocolInfos[info.name] = info
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
        if let info = category.info(in: machO) {
            let key = "\(info.className)(\(info.name))"
            categoryInfos[key] = info
        }
    }

    try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

    for info in classInfos.values {
        if let only = options.onlyOneClass, only != info.name { continue }
        let fileURL = outputDir.appendingPathComponent("\(info.name).h")
        try writeIfNeeded(text: info.headerString, to: fileURL, options: options, fileManager: fileManager)
    }

    for info in protocolInfos.values {
        if let only = options.onlyOneClass, only != info.name { continue }
        let fileURL = outputDir.appendingPathComponent("\(info.name).h")
        try writeIfNeeded(text: info.headerString, to: fileURL, options: options, fileManager: fileManager)
    }

    for info in categoryInfos.values {
        if let only = options.onlyOneClass, only != info.className && only != info.name { continue }
        let fileURL = outputDir.appendingPathComponent("\(info.className)+\(info.name).h")
        try writeIfNeeded(text: info.headerString, to: fileURL, options: options, fileManager: fileManager)
    }
}

#if canImport(ObjectiveC)
private func runtimeClassInfos(for imagePath: String, options: DumpOptions) -> [ObjCClassInfo] {
    guard options.useRuntimeFallback else { return [] }
    guard let handle = dlopen(imagePath, RTLD_LAZY) else {
        if options.verbose {
            fputs("classdump-dyld: runtime dlopen failed for \(imagePath)\n", stderr)
        }
        return []
    }
    defer { dlclose(handle) }

    var count: UInt32 = 0
    guard let namesPtr = objc_copyClassNamesForImage(imagePath, &count) else {
        if options.verbose {
            fputs(
                "classdump-dyld: runtime fallback objc_copyClassNamesForImage returned nil for \(imagePath)\n",
                stderr
            )
        }
        return runtimeClassInfosByImageName(imagePath: imagePath, options: options)
    }
    defer { free(namesPtr) }

    if count == 0 {
        if options.verbose {
            fputs(
                "classdump-dyld: runtime fallback objc_copyClassNamesForImage returned 0 classes for \(imagePath)\n",
                stderr
            )
        }
        return runtimeClassInfosByImageName(imagePath: imagePath, options: options)
    }

    let names = UnsafeBufferPointer(start: namesPtr, count: Int(count))
    var infos: [ObjCClassInfo] = []
    infos.reserveCapacity(Int(count))

    for namePtr in names {
        let name = String(cString: namePtr)
        if let only = options.onlyOneClass, only != name { continue }
        if let cls = NSClassFromString(name) ?? (objc_getClass(name) as? AnyClass) {
            infos.append(ObjCClassInfo(cls))
        }
    }
    return infos
}

private func runtimeClassInfosByImageName(
    imagePath: String,
    options: DumpOptions
) -> [ObjCClassInfo] {
    let initialCount = objc_getClassList(nil, 0)
    if initialCount <= 0 { return [] }

    let buffer = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(initialCount))
    defer { buffer.deallocate() }

    let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), initialCount)
    if count <= 0 { return [] }

    let targetPath = normalizedImagePath(stripRuntimeRoot(from: imagePath))
    var infos: [ObjCClassInfo] = []
    infos.reserveCapacity(Int(count))

    for index in 0..<Int(count) {
        guard let cls = buffer[index] else { continue }
        guard let imageNamePtr = class_getImageName(cls) else { continue }
        let imageName = String(cString: imageNamePtr)
        let normalizedImage = normalizedImagePath(stripRuntimeRoot(from: imageName))
        if normalizedImage != targetPath { continue }

        let name = String(cString: class_getName(cls))
        if let only = options.onlyOneClass, only != name { continue }
        infos.append(ObjCClassInfo(cls))
    }

    if options.verbose, !infos.isEmpty {
        fputs(
            "classdump-dyld: runtime fallback class_getImageName matched \(infos.count) classes for \(imagePath)\n",
            stderr
        )
    }
    return infos
}

private func normalizedImagePath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}
#endif

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: MachOFile,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    for cls in classes {
        if let info = cls.info(in: machO) {
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
        "classdump-dyld: skip class \(displayName) (offset=\(cls.offset)) image=\(machO.imagePath) metaImage=\(metaImage) missing=\(missingText)\n",
        stderr
    )
}

private func dumpSwift(
    machO: MachOFile,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) async throws {
    let moduleName = URL(fileURLWithPath: imagePath).lastPathComponent
    let outputURL = outputDir.appendingPathComponent("\(moduleName).swiftinterface")

    if options.skipExisting && fileManager.fileExists(atPath: outputURL.path) {
        return
    }

    let builder = try SwiftInterfaceBuilder(configuration: .init(), in: machO)
    do {
        try await builder.prepare()
        let interface = try await builder.printRoot()
        let text = interface.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try text.write(to: outputURL, atomically: true, encoding: .utf8)
    } catch {
        if options.verbose {
            fputs("Swift interface generation failed for \(imagePath): \(error)\n", stderr)
        }
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
