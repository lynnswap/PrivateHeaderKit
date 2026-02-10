import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)

private enum ExecMode: String {
    case host
    case simulator
}

private struct DumpArguments {
    var version: String?
    var device: String?
    var outDir: URL?
    var force: Bool = false
    var skipExisting: Bool = false
    var execMode: ExecMode?
    var listRuntimes: Bool = false
    var listDevices: Bool = false
    var runtimeForListDevices: String?
    var json: Bool = false
    var layout: String?
    var frameworks: [String] = []
    var filters: [String] = []
    var sharedCache: Bool = false
    var verbose: Bool = false
}

private struct Context {
    var execMode: ExecMode
    var headerdumpBin: URL
    var version: String
    var runtimeRoot: String
    var runtimeId: String
    var runtimeBuild: String
    var device: DeviceInfo?
    var outDir: URL
    var stageDir: URL
    var skipExisting: Bool
    var useSharedCache: Bool
    var verbose: Bool
    var layout: String
    var categories: [String]
    var frameworkNames: Set<String>
    var frameworkFilters: [String]

    var isSplit: Bool {
        execMode == .simulator || !frameworkNames.isEmpty || !frameworkFilters.isEmpty || skipExisting
    }
}

@main
struct PrivateHeaderKitDumpMain {
    static func main() {
        do {
            try run()
        } catch {
            fputs("privateheaderkit-dump: error: \(error)\n", stderr)
            exit(1)
        }
    }
}

private func printUsage() {
    let text = """
    Usage:
      privateheaderkit-dump [<options>] [<version>]

    Examples:
      privateheaderkit-dump
      privateheaderkit-dump 26.2
      privateheaderkit-dump --list-runtimes
      privateheaderkit-dump --list-devices --runtime 26.0.1

    Options:
      --device <udid|name>        Choose a simulator device
      --out <dir>                Output directory
      --force                    Always dump even if headers already exist
      --skip-existing             Skip frameworks that already exist (useful to override PH_FORCE=1)
      --exec-mode <host|simulator>
      --framework <name>         Dump only the exact framework name (repeatable; .framework optional)
      --filter <substring>       Substring filter for framework names (repeatable)
      --layout <bundle|headers>  Output layout (default: headers)
      --list-runtimes            List available iOS runtimes and exit
      --list-devices             List devices for a runtime and exit (use --runtime)
      --runtime <version>        Runtime version for --list-devices (default: latest)
      --json                     JSON output for list commands
      --shared-cache             Use dyld shared cache when dumping (enabled by default; set PH_SHARED_CACHE=0 to disable)
      -D, --verbose              Enable verbose logging
      -h, --help                 Show this help
    """
    print(text)
}

private func parseArguments(_ args: [String]) throws -> DumpArguments {
    var parsed = DumpArguments()
    var idx = 0
    while idx < args.count {
        let arg = args[idx]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--device":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--device requires a value") }
            parsed.device = args[idx + 1]
            idx += 2
        case "--out":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--out requires a value") }
            parsed.outDir = URL(fileURLWithPath: args[idx + 1])
            idx += 2
        case "--force":
            parsed.force = true
            idx += 1
        case "--skip-existing":
            parsed.skipExisting = true
            idx += 1
        case "--exec-mode":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--exec-mode requires a value") }
            let value = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            parsed.execMode = ExecMode(rawValue: value)
            if parsed.execMode == nil {
                throw ToolingError.invalidArgument("invalid exec mode: \(args[idx + 1])")
            }
            idx += 2
        case "--list-runtimes":
            parsed.listRuntimes = true
            idx += 1
        case "--list-devices":
            parsed.listDevices = true
            idx += 1
        case "--runtime":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--runtime requires a value") }
            parsed.runtimeForListDevices = args[idx + 1]
            idx += 2
        case "--json":
            parsed.json = true
            idx += 1
        case "--layout":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--layout requires a value") }
            parsed.layout = args[idx + 1]
            idx += 2
        case "--framework":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--framework requires a value") }
            parsed.frameworks.append(args[idx + 1])
            idx += 2
        case "--filter":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--filter requires a value") }
            parsed.filters.append(args[idx + 1])
            idx += 2
        case "--shared-cache":
            parsed.sharedCache = true
            idx += 1
        case "-D", "--verbose":
            parsed.verbose = true
            idx += 1
        default:
            if arg.hasPrefix("-") {
                throw ToolingError.invalidArgument("unknown option: \(arg)")
            }
            if parsed.version == nil {
                parsed.version = arg
                idx += 1
            } else {
                throw ToolingError.invalidArgument("unexpected argument: \(arg)")
            }
        }
    }
    return parsed
}

private func resolveLayout(_ requested: String?, env: [String: String]) throws -> String {
    let value = (requested ?? env["PH_LAYOUT"] ?? "headers").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard value == "bundle" || value == "headers" else {
        throw ToolingError.message("invalid layout: \(value)")
    }
    return value
}

private func resolveSharedCache(_ args: DumpArguments, env: [String: String]) -> Bool {
    if args.sharedCache { return true }
    if let envValue = env["PH_SHARED_CACHE"] { return envValue == "1" }
    return true
}

private func resolveVerbose(_ args: DumpArguments, env: [String: String]) -> Bool {
    if args.verbose { return true }
    if let envValue = env["PH_VERBOSE"] { return envValue == "1" }
    return false
}

private func resolveSkipExisting(_ args: DumpArguments, env: [String: String]) -> Bool {
    if args.force { return false }
    if args.skipExisting { return true }
    if env["PH_FORCE"] == "1" { return false }
    if let envValue = env["PH_SKIP_EXISTING"] { return envValue == "1" }
    return true
}

private func buildSelection(_ args: DumpArguments) -> (categories: [String], frameworkNames: Set<String>, frameworkFilters: [String]) {
    let categories = ["Frameworks", "PrivateFrameworks"]

    var frameworkNames: Set<String> = []
    for name in args.frameworks {
        let normalized = FileOps.normalizeFrameworkName(name).lowercased()
        frameworkNames.insert(normalized)
    }

    let frameworkFilters = args.filters.map { $0.lowercased() }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return (categories, frameworkNames, frameworkFilters)
}

private func selfExecutableURL(env: [String: String]) -> URL? {
    let arg0 = CommandLine.arguments.first ?? ""
    if arg0.contains("/") {
        let url = URL(fileURLWithPath: arg0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return url.standardizedFileURL
    }
    return Which.find(arg0, environment: env)
}

private func resolveHeaderdumpBinaries(rootDir: URL?, env: [String: String]) -> (host: URL?, sim: URL?) {
    let fileManager = FileManager.default
    let preferredDir = selfExecutableURL(env: env)?.deletingLastPathComponent()

    func preferSibling(_ name: String) -> URL? {
        if let preferredDir {
            let candidate = preferredDir.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return Which.find(name, environment: env)
    }

    let host = preferSibling("headerdump")
    let sim = preferSibling("headerdump-sim")
    return (host, sim)
}

private func resolveExecMode(_ requested: ExecMode?, headerdumpHost: URL?, headerdumpSim: URL?, runner: CommandRunning) -> ExecMode {
    if let requested { return requested }
    if let _ = headerdumpSim, (try? Simctl.listRuntimes(runner: runner))?.isEmpty == false {
        return .simulator
    }
    if headerdumpHost != nil { return .host }
    if headerdumpSim != nil { return .simulator }
    return .host
}

private func shouldFallbackToHost(_ error: Error) -> Bool {
    let message = String(describing: error).lowercased()
    if message.contains("no available ios runtimes found") { return false }
    if message.contains("ios runtime not found or unavailable") { return false }
    let tokens = [
        "no simulator device available",
        "no simulator device found",
        "failed to create simulator device",
        "failed to boot simulator",
        "failed to wait for simulator boot",
        "bad or unknown session",
        "device is not booted",
        "headerdump-sim not found",
    ]
    return tokens.contains(where: { message.contains($0) })
}

private func listRuntimesCommand(jsonOutput: Bool, runner: CommandRunning) throws {
    let runtimes = try Simctl.listRuntimes(runner: runner)
    if jsonOutput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(runtimes)
        print(String(decoding: data, as: UTF8.self))
        return
    }
    print("Available iOS runtimes:")
    for (idx, runtime) in runtimes.enumerated() {
        print("  [\(idx + 1)] iOS \(runtime.version) (\(runtime.build))")
        print("      \(runtime.identifier)")
        print("      \(runtime.runtimeRoot)")
    }
}

private func listDevicesCommand(version: String?, jsonOutput: Bool, runner: CommandRunning) throws {
    let runtime = try (version.map { try Simctl.findRuntime(version: $0, runner: runner) } ?? Simctl.latestRuntime(runner: runner))
    let devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
    if jsonOutput {
        struct Payload: Encodable {
            struct RuntimePayload: Encodable {
                let version: String
                let build: String
                let identifier: String
                let runtimeRoot: String
            }
            struct DevicePayload: Encodable {
                let name: String
                let udid: String
                let state: String
            }
            let runtime: RuntimePayload
            let devices: [DevicePayload]
        }
        let payload = Payload(
            runtime: .init(version: runtime.version, build: runtime.build, identifier: runtime.identifier, runtimeRoot: runtime.runtimeRoot),
            devices: devices.map { .init(name: $0.name, udid: $0.udid, state: $0.state) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        print(String(decoding: data, as: UTF8.self))
        return
    }

    print("Devices for iOS \(runtime.version) (\(runtime.build)):")
    print("  \(runtime.identifier)")
    for (idx, device) in devices.enumerated() {
        print("  [\(idx + 1)] \(device.name) (\(device.state))")
        print("      \(device.udid)")
    }
}

private func printDevices(_ devices: [DeviceInfo]) {
    print("Devices:")
    for (idx, d) in devices.enumerated() {
        print("  [\(idx + 1)] \(d.name) (\(d.state))")
    }
}

private func interactiveSetup(
    rootDir: URL,
    headerdumpBin: URL,
    execMode: ExecMode,
    args: DumpArguments,
    categories: [String],
    frameworkNames: Set<String>,
    frameworkFilters: [String],
    layout: String,
    useSharedCache: Bool,
    verbose: Bool,
    runner: CommandRunning
) throws -> Context {
    print("Interactive mode")
    let runtimes = try Simctl.listRuntimes(runner: runner)
    guard !runtimes.isEmpty else { throw ToolingError.message("no available iOS runtimes found") }

    print("Available iOS runtimes:")
    for (idx, r) in runtimes.enumerated() {
        print("  [\(idx + 1)] iOS \(r.version) (\(r.build))")
    }
    let defaultIndex = runtimes.count
    print("Select runtime (Enter for latest): ", terminator: "")
    let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let runtime: RuntimeInfo
    if choice.isEmpty {
        runtime = runtimes[defaultIndex - 1]
    } else if let idx = Int(choice), idx > 0, idx <= runtimes.count {
        runtime = runtimes[idx - 1]
    } else {
        throw ToolingError.message("invalid selection")
    }

    var device: DeviceInfo?
    if execMode == .simulator {
        var devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
        if devices.isEmpty {
            print("No devices available for runtime: \(runtime.identifier)")
            try Simctl.createDefaultDevice(runtimeId: runtime.identifier, version: runtime.version, runner: runner)
            devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
            if devices.isEmpty {
                throw ToolingError.message("failed to create simulator device for runtime: \(runtime.identifier)")
            }
        }
        printDevices(devices)
        if let query = args.device, !query.isEmpty {
            guard let match = Simctl.matchDevice(devices: devices, query: query) else {
                throw ToolingError.message("no simulator device found for runtime: \(runtime.identifier)")
            }
            device = match
        } else {
            device = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        }
    }

    let defaultOut = rootDir.appendingPathComponent("generated-headers/iOS", isDirectory: true).appendingPathComponent(runtime.version, isDirectory: true)
    let env = ProcessInfo.processInfo.environment
    let outDir = args.outDir ?? (env["PH_OUT_DIR"].map { URL(fileURLWithPath: $0) }) ?? defaultOut
    let stageDir = FileOps.buildStageDir(outDir: outDir)
    let skipExisting = resolveSkipExisting(args, env: env)

    if let device {
        print("Using device: \(device.name) (\(device.state))")
    }
    print("Output directory: \(outDir.path)")

    return Context(
        execMode: execMode,
        headerdumpBin: headerdumpBin.resolvingSymlinksInPath(),
        version: runtime.version,
        runtimeRoot: runtime.runtimeRoot,
        runtimeId: runtime.identifier,
        runtimeBuild: runtime.build,
        device: device,
        outDir: outDir.resolvingSymlinksInPath(),
        stageDir: stageDir.resolvingSymlinksInPath(),
        skipExisting: skipExisting,
        useSharedCache: useSharedCache,
        verbose: verbose,
        layout: layout,
        categories: categories,
        frameworkNames: frameworkNames,
        frameworkFilters: frameworkFilters
    )
}

private func nonInteractiveSetup(
    rootDir: URL,
    headerdumpBin: URL,
    execMode: ExecMode,
    args: DumpArguments,
    categories: [String],
    frameworkNames: Set<String>,
    frameworkFilters: [String],
    layout: String,
    useSharedCache: Bool,
    verbose: Bool,
    runner: CommandRunning
) throws -> Context {
    guard let version = args.version, !version.isEmpty else {
        throw ToolingError.invalidArgument("missing version")
    }
    let runtime = try Simctl.findRuntime(version: version, runner: runner)

    var device: DeviceInfo?
    if execMode == .simulator {
        var devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
        if devices.isEmpty {
            try Simctl.createDefaultDevice(runtimeId: runtime.identifier, version: runtime.version, runner: runner)
            devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
        }
        if devices.isEmpty {
            throw ToolingError.message("no simulator device found for runtime: \(runtime.identifier)")
        }
        if let query = args.device, !query.isEmpty {
            guard let match = Simctl.matchDevice(devices: devices, query: query) else {
                throw ToolingError.message("no simulator device found for runtime: \(runtime.identifier)")
            }
            device = match
        } else {
            device = try Simctl.resolveDefaultDevice(runtime: runtime, devices: devices, runner: runner)
        }
    }

    let outDir = args.outDir ?? rootDir.appendingPathComponent("generated-headers/iOS", isDirectory: true).appendingPathComponent(version, isDirectory: true)
    let stageDir = FileOps.buildStageDir(outDir: outDir)
    let env = ProcessInfo.processInfo.environment
    let skipExisting = resolveSkipExisting(args, env: env)

    return Context(
        execMode: execMode,
        headerdumpBin: headerdumpBin.resolvingSymlinksInPath(),
        version: version,
        runtimeRoot: runtime.runtimeRoot,
        runtimeId: runtime.identifier,
        runtimeBuild: runtime.build,
        device: device,
        outDir: outDir.resolvingSymlinksInPath(),
        stageDir: stageDir.resolvingSymlinksInPath(),
        skipExisting: skipExisting,
        useSharedCache: useSharedCache,
        verbose: verbose,
        layout: layout,
        categories: categories,
        frameworkNames: frameworkNames,
        frameworkFilters: frameworkFilters
    )
}

private func prepareOutputLayout(ctx: Context) throws {
    for category in ctx.categories {
        let categoryDir = ctx.outDir.appendingPathComponent(category, isDirectory: true)
        if ctx.layout == "headers" {
            try FileOps.normalizeFrameworkDirs(in: categoryDir, overwrite: false)
        } else {
            try FileOps.denormalizeFrameworkDirs(in: categoryDir)
        }
    }
}

private func run() throws {
    let runner = ProcessRunner()
    let env = ProcessInfo.processInfo.environment

    let args = Array(CommandLine.arguments.dropFirst())
    let parsed = try parseArguments(args)

    if parsed.listRuntimes {
        try listRuntimesCommand(jsonOutput: parsed.json, runner: runner)
        return
    }
    if parsed.listDevices {
        try listDevicesCommand(version: parsed.runtimeForListDevices, jsonOutput: parsed.json, runner: runner)
        return
    }

    let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let repoRoot = PathUtils.findRepositoryRoot(startingAt: cwdURL)
    if repoRoot == nil, parsed.outDir == nil {
        throw ToolingError.message("repository root not found (Package.swift missing); run from the repo root or pass --out")
    }
    let rootDir = repoRoot ?? cwdURL

    let binaries = resolveHeaderdumpBinaries(rootDir: repoRoot, env: env)
    let requestedExecMode = parsed.execMode ?? ExecMode(rawValue: (env["PH_EXEC_MODE"] ?? "").lowercased())
    let autoExecMode = requestedExecMode == nil
    var execMode = resolveExecMode(requestedExecMode, headerdumpHost: binaries.host, headerdumpSim: binaries.sim, runner: runner)

    let (categories, frameworkNames, frameworkFilters) = buildSelection(parsed)
    let layout = try resolveLayout(parsed.layout, env: env)
    let useSharedCache = resolveSharedCache(parsed, env: env)
    let verbose = resolveVerbose(parsed, env: env)

    func setupContext(_ mode: ExecMode) throws -> Context {
        let headerdumpBin: URL
        switch mode {
        case .host:
            guard let host = binaries.host else {
                throw ToolingError.message("headerdump not found (run `swift run -c release privateheaderkit-install` first)")
            }
            headerdumpBin = host
        case .simulator:
            guard let sim = binaries.sim else {
                throw ToolingError.message("headerdump-sim not found (run `swift run -c release privateheaderkit-install` first)")
            }
            headerdumpBin = sim
        }

        if parsed.version == nil {
            return try interactiveSetup(
                rootDir: rootDir,
                headerdumpBin: headerdumpBin,
                execMode: mode,
                args: parsed,
                categories: categories,
                frameworkNames: frameworkNames,
                frameworkFilters: frameworkFilters,
                layout: layout,
                useSharedCache: useSharedCache,
                verbose: verbose,
                runner: runner
            )
        }
        return try nonInteractiveSetup(
            rootDir: rootDir,
            headerdumpBin: headerdumpBin,
            execMode: mode,
            args: parsed,
            categories: categories,
            frameworkNames: frameworkNames,
            frameworkFilters: frameworkFilters,
            layout: layout,
            useSharedCache: useSharedCache,
            verbose: verbose,
            runner: runner
        )
    }

    var ctx: Context
    do {
        ctx = try setupContext(execMode)
    } catch {
        if autoExecMode, execMode == .simulator, shouldFallbackToHost(error), binaries.host != nil {
            fputs("Simulator unavailable; falling back to host: \(error)\n", stderr)
            execMode = .host
            ctx = try setupContext(execMode)
        } else {
            throw error
        }
    }

    if ctx.execMode == .simulator {
        guard var device = ctx.device else { throw ToolingError.message("no simulator device available") }
        try Simctl.ensureDeviceBooted(&device, runner: runner, force: false)
        ctx.device = device
    }

    try PathUtils.ensureDirectory(ctx.outDir)
    let lock = try OutputLock(outDir: ctx.outDir)
    defer { lock.unlock(removeFile: true) }
    defer { PathUtils.removeIfExists(ctx.stageDir) }

    try prepareOutputLayout(ctx: ctx)

    for category in ctx.categories {
        try FileOps.resetStageDir(ctx.stageDir)
        let hadFailures = try dumpCategory(category: category, ctx: ctx, runner: runner)
        try finalizeCategoryOutput(category: category, ctx: ctx, hadFailures: hadFailures)
    }

    try writeMetadata(ctx: ctx, runner: runner)
    print("Done: \(ctx.outDir.path)")
}

private func listFrameworks(category: String, ctx: Context) throws -> [String] {
    let dirURL = URL(fileURLWithPath: ctx.runtimeRoot, isDirectory: true)
        .appendingPathComponent("System/Library", isDirectory: true)
        .appendingPathComponent(category, isDirectory: true)
    guard FileOps.isDirectory(dirURL) else {
        throw ToolingError.message("failed to read \(dirURL.path)")
    }
    let items = try FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil, options: [])
    var frameworks = items.map(\.lastPathComponent).filter { $0.hasSuffix(".framework") }
    frameworks.sort()
    frameworks = filterFrameworks(frameworks, ctx: ctx)
    return frameworks
}

private func filterFrameworks(_ frameworks: [String], ctx: Context) -> [String] {
    var filtered = frameworks
    if !ctx.frameworkNames.isEmpty {
        filtered = filtered.filter { ctx.frameworkNames.contains($0.lowercased()) }
    }
    if !ctx.frameworkFilters.isEmpty {
        filtered = filtered.filter { name in
            let lowered = name.lowercased()
            return ctx.frameworkFilters.contains(where: { lowered.contains($0) })
        }
    }
    return filtered
}

private func existingFrameworksInCategory(ctx: Context, category: String, frameworks: Set<String>) -> Set<String> {
    let categoryDir = ctx.outDir.appendingPathComponent(category, isDirectory: true)
    guard FileOps.isDirectory(categoryDir) else { return [] }

    let basePath = categoryDir.path
    var existing: Set<String> = []
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(at: categoryDir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
        return []
    }

    for case let url as URL in enumerator {
        if FileOps.isDirectory(url), url.lastPathComponent.hasPrefix(".tmp") {
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension != "h" { continue }
        guard url.path.hasPrefix(basePath + "/") else { continue }
        let rel = url.path.dropFirst(basePath.count + 1)
        guard let top = rel.split(separator: "/").first else { continue }
        let topName = String(top)
        let frameworkName = (ctx.layout == "headers") ? FileOps.normalizeFrameworkName(topName) : topName
        if frameworks.contains(frameworkName) {
            existing.insert(frameworkName)
        }
    }
    return existing
}

private func dumpCategory(category: String, ctx: Context, runner: CommandRunning) throws -> Bool {
    print("Dumping: \(category)")
    if ctx.isSplit {
        return try dumpCategorySplit(category: category, ctx: ctx, runner: runner)
    }

    let result = try runHeaderdump(category: category, ctx: ctx, runner: runner)
    if result.wasKilled {
        print("Retrying per-framework to avoid simulator kill.")
        try FileOps.resetStageDir(ctx.stageDir)
        return try dumpCategorySplit(category: category, ctx: ctx, runner: runner)
    }
    if result.status != 0 {
        reportLastLines(result.lastLines)
        throw ToolingError.message("headerdump failed for \(category)")
    }
    return false
}

private func dumpCategorySplit(category: String, ctx: Context, runner: CommandRunning) throws -> Bool {
    let frameworks = try listFrameworks(category: category, ctx: ctx)
    if frameworks.isEmpty {
        print("Skipping \(category): no frameworks found under /System/Library/\(category)")
        return false
    }

    let total = frameworks.count
    var failures: [String] = []

    var existing: Set<String> = []
    if ctx.skipExisting {
        existing = existingFrameworksInCategory(ctx: ctx, category: category, frameworks: Set(frameworks))
    }

    for (idx, item) in frameworks.enumerated() {
        if ctx.skipExisting, existing.contains(item) {
            print("Skipping existing: \(category) (\(idx + 1)/\(total)) \(item)")
            continue
        }
        print("Dumping: \(category) (\(idx + 1)/\(total)) \(item)")
        let path = "\(category)/\(item)"
        let result = try runHeaderdump(category: path, ctx: ctx, runner: runner)
        if result.wasKilled || result.status != 0 {
            reportLastLines(result.lastLines)
            failures.append(path)
        } else {
            try relocateFrameworkOutput(ctx: ctx, category: category, frameworkName: item)
            if ctx.layout == "headers" {
                try normalizeFrameworkDir(ctx: ctx, category: category, frameworkName: item, overwrite: !ctx.skipExisting)
            }
        }
    }

    if !failures.isEmpty {
        let summary = "headerdump failed for \(failures.count) items under \(category)"
        fputs(summary + "\n", stderr)
        try writeFailures(ctx: ctx, summary: summary, failures: failures)
        return true
    }
    return false
}

private func relocateFrameworkOutput(ctx: Context, category: String, frameworkName: String) throws {
    let fileManager = FileManager.default
    var src: URL?
    for base in FileOps.stageSystemLibraryRoots(stageDir: ctx.stageDir, runtimeRoot: ctx.runtimeRoot) {
        let candidate = base.appendingPathComponent(category, isDirectory: true).appendingPathComponent(frameworkName, isDirectory: true)
        if fileManager.fileExists(atPath: candidate.path), !FileOps.isSymlink(candidate) {
            src = candidate
            break
        }
    }
    guard let src else { return }

    let destDir = ctx.outDir.appendingPathComponent(category, isDirectory: true)
    try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
    let dest = destDir.appendingPathComponent(frameworkName, isDirectory: true)

    if fileManager.fileExists(atPath: dest.path) {
        let overwrite = !ctx.skipExisting
        if overwrite {
            try FileOps.moveReplace(src: src, dest: dest, fileManager: fileManager)
        } else {
            try FileOps.mergeDirectories(src: src, dest: dest, fileManager: fileManager)
            FileOps.tryRemoveEmpty(src, fileManager: fileManager)
        }
    } else {
        try fileManager.moveItem(at: src, to: dest)
    }
}

private func relocateFrameworksInCategory(ctx: Context, category: String) throws {
    let fileManager = FileManager.default
    let destDir = ctx.outDir.appendingPathComponent(category, isDirectory: true)
    try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
    let overwrite = !ctx.skipExisting

    for base in FileOps.stageSystemLibraryRoots(stageDir: ctx.stageDir, runtimeRoot: ctx.runtimeRoot) {
        let srcDir = base.appendingPathComponent(category, isDirectory: true)
        if !FileOps.isDirectory(srcDir) || FileOps.isSymlink(srcDir) { continue }
        let entries = try fileManager.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        for entry in entries {
            if FileOps.isSymlink(entry) { continue }
            let dest = destDir.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
            if fileManager.fileExists(atPath: dest.path) {
                if overwrite {
                    try FileOps.moveReplace(src: entry, dest: dest, fileManager: fileManager)
                } else {
                    if FileOps.isDirectory(entry) {
                        try FileOps.mergeDirectories(src: entry, dest: dest, fileManager: fileManager)
                        FileOps.tryRemoveEmpty(entry, fileManager: fileManager)
                    } else {
                        try? fileManager.removeItem(at: entry)
                    }
                }
            } else {
                try fileManager.moveItem(at: entry, to: dest)
            }
        }
    }
}

private func normalizeFrameworkDir(ctx: Context, category: String, frameworkName: String, overwrite: Bool) throws {
    guard frameworkName.hasSuffix(".framework") else { return }
    let base = ctx.outDir.appendingPathComponent(category, isDirectory: true)
    guard FileOps.isDirectory(base) else { return }

    let entry = base.appendingPathComponent(frameworkName, isDirectory: true)
    if FileOps.isSymlink(entry) || !FileOps.isDirectory(entry) { return }

    let targetName = String(frameworkName.dropLast(".framework".count))
    let target = base.appendingPathComponent(targetName, isDirectory: true)
    let fm = FileManager.default

    if fm.fileExists(atPath: target.path), FileOps.isSymlink(target) {
        try? fm.removeItem(at: target)
    }
    if fm.fileExists(atPath: target.path) {
        if overwrite {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: entry, to: target)
        } else {
            try FileOps.mergeDirectories(src: entry, dest: target, fileManager: fm)
            FileOps.tryRemoveEmpty(entry, fileManager: fm)
        }
    } else {
        try fm.moveItem(at: entry, to: target)
    }
}

private func finalizeCategoryOutput(category: String, ctx: Context, hadFailures: Bool) throws {
    if !hadFailures {
        try relocateFrameworksInCategory(ctx: ctx, category: category)
    }
    if ctx.layout == "headers" {
        let categoryDir = ctx.outDir.appendingPathComponent(category, isDirectory: true)
        try FileOps.normalizeFrameworkDirs(in: categoryDir, overwrite: !ctx.skipExisting)
    }
}

private func runHeaderdump(category: String, ctx: Context, runner: CommandRunning) throws -> StreamingCommandResult {
    switch ctx.execMode {
    case .host:
        return try runHeaderdumpHost(category: category, ctx: ctx, runner: runner)
    case .simulator:
        return try runHeaderdumpSimulator(category: category, ctx: ctx, runner: runner)
    }
}

private func runHeaderdumpHost(category: String, ctx: Context, runner: CommandRunning) throws -> StreamingCommandResult {
    let sourcePath = URL(fileURLWithPath: ctx.runtimeRoot, isDirectory: true)
        .appendingPathComponent("System/Library", isDirectory: true)
        .appendingPathComponent(category, isDirectory: false)
        .path
    let isRecursive = !category.contains("/")

    var cmd = [ctx.headerdumpBin.path, "-o", ctx.stageDir.path]
    if isRecursive {
        cmd += ["-r", sourcePath]
    } else {
        cmd.append(sourcePath)
    }
    cmd += ["-b", "-h"]
    if ctx.verbose { cmd.append("-D") }
    if ctx.skipExisting { cmd.append("-s") }

    var env: [String: String]? = nil
    if ctx.useSharedCache {
        cmd.append("-c")
        env = ["SIMCTL_CHILD_DYLD_ROOT_PATH": ctx.runtimeRoot]
    }
    return try runner.runStreaming(cmd, env: env, cwd: nil)
}

private func shouldRetrySimulatorBoot(_ lastLines: [String]) -> Bool {
    for line in lastLines {
        let lowered = line.lowercased()
        if lowered.contains("device is not booted") { return true }
        if lowered.contains("bad or unknown session") { return true }
    }
    return false
}

private func runHeaderdumpSimulator(category: String, ctx: Context, runner: CommandRunning) throws -> StreamingCommandResult {
    guard var device = ctx.device else { throw ToolingError.message("no simulator device available") }
    let sourcePath = "/System/Library/\(category)"
    let isRecursive = !category.contains("/")

    var cmd = ["xcrun", "simctl", "spawn", device.udid, ctx.headerdumpBin.path, "-o", ctx.stageDir.path]
    if isRecursive {
        cmd += ["-r", sourcePath]
    } else {
        cmd.append(sourcePath)
    }
    cmd += ["-b", "-h"]
    if ctx.verbose { cmd.append("-D") }
    if ctx.skipExisting { cmd.append("-s") }
    if ctx.useSharedCache { cmd.append("-c") }

    let env: [String: String] = [
        "SIMCTL_CHILD_PH_RUNTIME_ROOT": ctx.runtimeRoot,
        "SIMCTL_CHILD_DYLD_ROOT_PATH": ctx.runtimeRoot,
    ]

    var result = try runner.runStreaming(cmd, env: env, cwd: nil)
    if result.status != 0, shouldRetrySimulatorBoot(result.lastLines) {
        try Simctl.ensureDeviceBooted(&device, runner: runner, force: true)
        result = try runner.runStreaming(cmd, env: env, cwd: nil)
    }
    return result
}

private func reportLastLines(_ lines: [String]) {
    guard !lines.isEmpty else { return }
    fputs("--- last output ---\n", stderr)
    for line in lines {
        fputs(line + "\n", stderr)
    }
}

private func writeFailures(ctx: Context, summary: String, failures: [String]) throws {
    let path = ctx.outDir.appendingPathComponent("_failures.txt")
    let text = ([summary + ":"] + failures.map { "  - \($0)" }).joined(separator: "\n") + "\n"
    if let handle = try? FileHandle(forWritingTo: path) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try text.write(to: path, atomically: true, encoding: .utf8)
    }
}

private func writeMetadata(ctx: Context, runner: CommandRunning) throws {
    let headerCount = countHeaders(in: ctx.outDir)
    let xcodeInfo: String
    if let output = try? runner.runCapture(["xcodebuild", "-version"], env: nil, cwd: nil) {
        xcodeInfo = output.split(separator: "\n").joined(separator: " ")
    } else {
        xcodeInfo = "unknown"
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    let generatedAt = formatter.string(from: Date())
    let skip = ctx.skipExisting ? "-s" : ""

    let metadata = """
    Generated: \(generatedAt)
    RuntimeRoot: \(ctx.runtimeRoot)
    RuntimeIdentifier: \(ctx.runtimeId)
    RuntimeBuild: \(ctx.runtimeBuild)
    iOS: \(ctx.version)
    HeadersPath: \(ctx.outDir.path)
    Layout: \(ctx.layout)
    HeaderCount: \(headerCount)
    Xcode: \(xcodeInfo)
    Notes: headerdump output; /System/Library/{Frameworks,PrivateFrameworks}; -b -h \(skip)
    """

    let path = ctx.outDir.appendingPathComponent("_metadata.txt")
    try metadata.write(to: path, atomically: true, encoding: .utf8)
}

private func countHeaders(in dir: URL) -> Int {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
        return 0
    }

    var count = 0
    for case let url as URL in enumerator {
        if FileOps.isDirectory(url), url.lastPathComponent.hasPrefix(".tmp") {
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension == "h" {
            count += 1
        }
    }
    return count
}

#else

@main
struct PrivateHeaderKitDumpMain {
    static func main() {
        fputs("privateheaderkit-dump: unsupported on this platform\n", stderr)
    }
}

#endif
