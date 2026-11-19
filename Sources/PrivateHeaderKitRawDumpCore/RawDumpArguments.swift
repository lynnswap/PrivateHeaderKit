import Foundation

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
    var processHandshakeID: UUID?
    var processHandshakeReportURL: URL?
    var diagnosticsReportURL: URL?
    var logicalImagePath: String?
    let objcDiagnostics = RawDumpObjCDiagnosticsAccumulator()
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
        case "--image-path":
            let nextIndex = index + 1
            guard nextIndex < args.count, args[nextIndex].hasPrefix("/"), !args[nextIndex].contains("\0") else { return nil }
            options.logicalImagePath = args[nextIndex]
            index += 1
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
        case "--process-handshake-id":
            let nextIndex = index + 1
            guard nextIndex < args.count,
                  let invocationID = UUID(uuidString: args[nextIndex])
            else { return nil }
            options.processHandshakeID = invocationID
            index += 1
        case "--process-handshake-report":
            let nextIndex = index + 1
            guard nextIndex < args.count else { return nil }
            options.processHandshakeReportURL = URL(fileURLWithPath: args[nextIndex])
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
    guard options.logicalImagePath == nil || !options.recursive else { return nil }
    guard options.useSharedCache == (options.expectedCacheUUID != nil) else {
        return nil
    }
    guard (options.processHandshakeID == nil)
            == (options.processHandshakeReportURL == nil)
    else {
        return nil
    }
    options.logSkippedClasses = shouldLogSkippedClasses(environment: environment)
    options.profile = shouldProfile(environment: environment)
    options.logSwiftEvents = shouldLogSwiftEvents(environment: environment)
    return ParsedArguments(options: options, inputPath: inputPath)
}

func printUsage() {
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
        -R   Supplement missing Objective-C classes by loading the target image
        --diagnostics-report <path>
             Write the versioned Objective-C metadata diagnostics report
        --process-handshake-id <uuid>
             Bind the raw-dump invocation to its startup process handshake
        --process-handshake-report <path>
             Write the bounded startup process handshake before target work
    """
    print(text)
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
