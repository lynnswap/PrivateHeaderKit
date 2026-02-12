import Foundation
import Dispatch
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)

enum ExecMode: String {
    case host
    case simulator
}

enum TargetPlatform: String {
    case ios
    case macos
}

enum DumpScope: String {
    case frameworks
    case system
    case all
}

struct DumpArguments {
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
    var platform: TargetPlatform?
    var layout: String?
    var targets: [String] = []
    var frameworks: [String] = []
    var filters: [String] = []
    var sharedCache: Bool = false
    var verbose: Bool = false
    var scope: DumpScope?
    var nested: Bool?
}

private struct MacOSVersionInfo {
    let productVersion: String
    let buildVersion: String
}

private struct Context {
    var platform: TargetPlatform
    var execMode: ExecMode
    var headerdumpBin: URL
    var osVersionLabel: String
    var systemRoot: String
    var runtimeId: String?
    var runtimeBuild: String?
    var macOSBuildVersion: String?
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
    var nestedEnabled: Bool = false

    var isSplit: Bool {
        // macOS host dumps are more reliable/observable per framework than a single recursive run.
        // Also: nested bundle dumping (XPCServices/PlugIns) is implemented via per-bundle invocations.
        platform == .macos
            || execMode == .simulator
            || nestedEnabled
            || !frameworkNames.isEmpty
            || !frameworkFilters.isEmpty
            || skipExisting
    }
}

// Keep this async-signal-safe: store-only + kill(2), no allocations/IO.
nonisolated(unsafe) private var gTerminationSignal: sig_atomic_t = 0
nonisolated(unsafe) private var gActiveDumpSubprocessPid: pid_t = 0

private func terminationSignalHandler(_ sig: Int32) {
    if gTerminationSignal == 0 {
        gTerminationSignal = sig
    }
    let dumpPid = gActiveDumpSubprocessPid
    if dumpPid != 0 { _ = kill(dumpPid, sig) }

    let toolingPid = gActiveToolingSubprocessPid
    if toolingPid != 0, toolingPid != dumpPid { _ = kill(toolingPid, sig) }
}

private func installTerminationSignalHandlers() {
    _ = signal(SIGINT, terminationSignalHandler)
    _ = signal(SIGTERM, terminationSignalHandler)
}

private func terminationExitCode() -> Int32? {
    switch Int32(gTerminationSignal) {
    case SIGINT:
        return 130
    case SIGTERM:
        return 143
    default:
        return nil
    }
}

private func throwIfTerminationRequested() throws {
    if gTerminationSignal != 0 {
        throw ToolingError.message("interrupted")
    }
}

private func defaultOutDir(platform: TargetPlatform, version: String, fallbackRoot: URL) -> URL {
    let platformDir = platform == .ios ? "iOS" : "macOS"
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    if home.path.hasPrefix("/") {
        return home
            .appendingPathComponent("PrivateHeaderKit", isDirectory: true)
            .appendingPathComponent("generated-headers/\(platformDir)", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    // Extremely defensive fallback (shouldn't happen on macOS): keep the old repo-relative behavior.
    return fallbackRoot
        .appendingPathComponent("generated-headers/\(platformDir)", isDirectory: true)
        .appendingPathComponent(version, isDirectory: true)
}

private func normalizedEnvValue(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func runDumpStreaming(
    _ command: [String],
    env: [String: String]? = nil,
    cwd: URL? = nil,
    streamOutput: Bool = true
) throws -> StreamingCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    if let cwd { process.currentDirectoryURL = cwd }

    var environment = ProcessInfo.processInfo.environment
    if let env {
        for (k, v) in env { environment[k] = v }
    }
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let handle = pipe.fileHandleForReading

    var lastLines: [String] = []
    lastLines.reserveCapacity(8)
    var wasKilled = false

    try process.run()
    // Close the parent-side write handle so the reader reliably receives EOF.
    // (The child process still has its own write end inherited by exec.)
    try? pipe.fileHandleForWriting.close()

    let pid = process.processIdentifier
    gActiveDumpSubprocessPid = pid
    defer {
        if gActiveDumpSubprocessPid == pid {
            gActiveDumpSubprocessPid = 0
        }
    }

    var buffer = ""
    while true {
        let data = handle.availableData
        if data.isEmpty { break }
        if streamOutput {
            FileHandle.standardOutput.write(data)
        }

        let chunk = String(decoding: data, as: UTF8.self)
        buffer += chunk
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(..<range.upperBound)
            if line.isEmpty { continue }
            lastLines.append(line)
            if lastLines.count > 8 {
                lastLines.removeFirst(lastLines.count - 8)
            }
            if line.lowercased().contains("killed: 9") {
                wasKilled = true
            }
        }
    }

    process.waitUntilExit()
    if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lastLines.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        if lastLines.count > 8 {
            lastLines.removeFirst(lastLines.count - 8)
        }
    }
    if process.terminationReason == .uncaughtSignal {
        wasKilled = true
        lastLines.append("Terminated by signal \(process.terminationStatus)")
        if lastLines.count > 8 {
            lastLines.removeFirst(lastLines.count - 8)
        }
    } else if process.terminationStatus != 0, lastLines.isEmpty {
        lastLines.append("Exited with status \(process.terminationStatus)")
    }

    return StreamingCommandResult(status: process.terminationStatus, wasKilled: wasKilled, lastLines: lastLines)
}

@main
struct PrivateHeaderKitDumpMain {
    static func main() {
        installTerminationSignalHandlers()
        do {
            try run()
        } catch {
            if let code = terminationExitCode() {
                exit(code)
            } else {
                fputs("privateheaderkit-dump: error: \(error)\n", stderr)
                exit(1)
            }
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
      privateheaderkit-dump 26.2 --target SafariShared
      privateheaderkit-dump 26.2 --target PreferenceBundles/Foo.bundle
      privateheaderkit-dump 26.2 --target @all --no-nested
      privateheaderkit-dump --platform macos --target AppKit
      privateheaderkit-dump --list-runtimes
      privateheaderkit-dump --list-devices --runtime 26.0.1

    Options:
      --platform <ios|macos>    Target platform (default: ios; can also use PH_PLATFORM)
      --device <udid|name>        Choose a simulator device
      --out <dir>                Output directory
      --force                    Always dump even if headers already exist
      --skip-existing             Skip frameworks that already exist (useful to override PH_FORCE=1)
      --exec-mode <host|simulator>
      --target <value>           Select dump target (repeatable, additive)
                                - If omitted: dumps all frameworks (@frameworks)
                                - If present: dumps ONLY the selected targets
                                Presets: @frameworks | @system | @all
                                Framework: SafariShared
                                SystemLibrary item: PreferenceBundles/Foo.bundle
                                usr/lib dylib: /usr/lib/libobjc.A.dylib
      --no-nested               Disable nested bundle dumping (default: enabled)
      --layout <bundle|headers>  Output layout (default: headers)
      --list-runtimes            List available iOS runtimes and exit
      --list-devices             List devices for a runtime and exit (use --runtime)
      --runtime <version>        Runtime version for --list-devices (default: latest)
      --json                     JSON output for list commands
      --shared-cache             Use dyld shared cache when dumping (enabled by default; set PH_SHARED_CACHE=0 to disable)
      -D, --verbose              Enable verbose logging
      -h, --help                 Show this help

    Legacy options:
      --framework <name>         Dump only the exact framework name (repeatable; .framework optional)
      --filter <substring>       Substring filter for framework names (repeatable)
      --scope <frameworks|system|all>
                                Dump scope (default: frameworks)
      --nested                  Enable nested bundle dumping (default: enabled)
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
        case "--platform":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--platform requires a value") }
            let value = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let platform = TargetPlatform(rawValue: value) else {
                throw ToolingError.invalidArgument("invalid platform: \(args[idx + 1])")
            }
            parsed.platform = platform
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
        case "--target":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--target requires a value") }
            parsed.targets.append(args[idx + 1])
            idx += 2
        case "--framework":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--framework requires a value") }
            parsed.frameworks.append(args[idx + 1])
            idx += 2
        case "--filter":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--filter requires a value") }
            parsed.filters.append(args[idx + 1])
            idx += 2
        case "--scope":
            guard idx + 1 < args.count else { throw ToolingError.invalidArgument("--scope requires a value") }
            let value = args[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let scope = DumpScope(rawValue: value) else {
                throw ToolingError.invalidArgument("invalid scope: \(args[idx + 1])")
            }
            parsed.scope = scope
            idx += 2
        case "--nested":
            parsed.nested = true
            idx += 1
        case "--no-nested":
            parsed.nested = false
            idx += 1
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

private func resolvePlatform(_ args: DumpArguments, env: [String: String]) throws -> TargetPlatform {
    if let platform = args.platform {
        return platform
    }
    if let envPlatform = normalizedEnvValue(env["PH_PLATFORM"])?.lowercased() {
        guard let platform = TargetPlatform(rawValue: envPlatform) else {
            throw ToolingError.invalidArgument("invalid PH_PLATFORM: \(envPlatform)")
        }
        return platform
    }
    return .ios
}

private func resolveRequestedExecMode(_ args: DumpArguments, env: [String: String]) throws -> ExecMode? {
    if let execMode = args.execMode {
        return execMode
    }
    if let envMode = normalizedEnvValue(env["PH_EXEC_MODE"])?.lowercased() {
        guard let execMode = ExecMode(rawValue: envMode) else {
            throw ToolingError.invalidArgument("invalid PH_EXEC_MODE: \(envMode)")
        }
        return execMode
    }
    return nil
}

private func validatePlatformArguments(args: DumpArguments, platform: TargetPlatform, requestedExecMode: ExecMode?) throws {
    guard platform == .macos else { return }

    if args.version != nil {
        throw ToolingError.invalidArgument("version argument is not supported for --platform macos")
    }
    if args.listRuntimes || args.listDevices || args.runtimeForListDevices != nil {
        throw ToolingError.invalidArgument("--list-runtimes / --list-devices / --runtime are iOS-only options")
    }
    if args.device != nil {
        throw ToolingError.invalidArgument("--device is an iOS-only option")
    }
    if requestedExecMode == .simulator {
        throw ToolingError.invalidArgument("--exec-mode simulator is not supported for --platform macos")
    }
}

private func swVersValue(_ args: [String], runner: CommandRunning) throws -> String {
    let output = try runner.runCapture(args, env: nil, cwd: nil)
    guard let value = normalizedEnvValue(output) else {
        throw ToolingError.message("failed to read value from: \(args.joined(separator: " "))")
    }
    return value
}

private func readMacOSVersionInfo(runner: CommandRunning) throws -> MacOSVersionInfo {
    let productVersion = try swVersValue(["sw_vers", "-productVersion"], runner: runner)
    let buildVersion = try swVersValue(["sw_vers", "-buildVersion"], runner: runner)
    return MacOSVersionInfo(productVersion: productVersion, buildVersion: buildVersion)
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

internal struct DumpSelection {
    var categories: [String]
    var frameworkNames: Set<String>
    var frameworkFilters: [String]
    var dumpAllFrameworks: Bool
    var dumpAllSystemLibraryExtras: Bool
    var systemLibraryItems: [String]
    var dumpAllUsrLibDylibs: Bool
    var usrLibDylibs: [String]
}

internal func resolveNestedEnabled(_ args: DumpArguments) -> Bool {
    // Nested bundles are now enabled by default to make targeted dumps (e.g. a single framework)
    // produce XPCServices/PlugIns outputs without requiring extra flags.
    args.nested ?? true
}

private let systemBundleTargetExtensions: Set<String> = ["app", "bundle", "xpc", "appex"]

private func normalizeFrameworkTargetName(_ name: String) -> String {
    FileOps.normalizeFrameworkName(name).lowercased()
}

private func normalizeSystemLibraryRelativeTarget(_ value: String) throws -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("/System/Library/") {
        normalized = String(normalized.dropFirst("/System/Library/".count))
    } else if normalized.hasPrefix("System/Library/") {
        normalized = String(normalized.dropFirst("System/Library/".count))
    } else if normalized.hasPrefix("/") {
        throw ToolingError.invalidArgument("SystemLibrary target must be a /System/Library relative path: \(value)")
    }

    normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalized.isEmpty else {
        throw ToolingError.invalidArgument("SystemLibrary target is empty: \(value)")
    }

    if normalized.hasPrefix("Frameworks/") || normalized.hasPrefix("PrivateFrameworks/") {
        throw ToolingError.invalidArgument("SystemLibrary target must not be under Frameworks/PrivateFrameworks: \(value) (use --target <FrameworkName> instead)")
    }

    let parts = normalized.split(separator: "/").map(String.init)
    if parts.contains(".") || parts.contains("..") {
        throw ToolingError.invalidArgument("SystemLibrary target must not contain '.' or '..' path components: \(value)")
    }

    let ext = URL(fileURLWithPath: normalized).pathExtension.lowercased()
    guard systemBundleTargetExtensions.contains(ext) else {
        throw ToolingError.invalidArgument("SystemLibrary target must be .app/.bundle/.xpc/.appex: \(value)")
    }

    return normalized
}

private func normalizeUsrLibTargetName(_ value: String) throws -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("/usr/lib/") {
        normalized = String(normalized.dropFirst("/usr/lib/".count))
    } else if normalized.hasPrefix("usr/lib/") {
        normalized = String(normalized.dropFirst("usr/lib/".count))
    } else if normalized.hasPrefix("/") {
        throw ToolingError.invalidArgument("usr/lib target must be under /usr/lib: \(value)")
    }

    normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalized.isEmpty else {
        throw ToolingError.invalidArgument("usr/lib target is empty: \(value)")
    }
    guard !normalized.contains("/") else {
        throw ToolingError.invalidArgument("usr/lib target must be /usr/lib/<name>.dylib (subdirectories are not supported): \(value)")
    }
    guard normalized.lowercased().hasSuffix(".dylib") else {
        throw ToolingError.invalidArgument("usr/lib target must end with .dylib: \(value)")
    }
    return normalized
}

private func extractFrameworkNameFromTargetPath(_ value: String) -> String? {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("/System/Library/") {
        normalized = String(normalized.dropFirst("/System/Library/".count))
    } else if normalized.hasPrefix("System/Library/") {
        normalized = String(normalized.dropFirst("System/Library/".count))
    }

    let parts = normalized.split(separator: "/").map(String.init)
    for (idx, part) in parts.enumerated() {
        if (part == "Frameworks" || part == "PrivateFrameworks"),
           idx + 1 < parts.count,
           parts[idx + 1].hasSuffix(".framework")
        {
            return parts[idx + 1]
        }
    }
    return nil
}

private func appendUnique(_ items: inout [String], _ value: String, seen: inout Set<String>) {
    if seen.contains(value) { return }
    seen.insert(value)
    items.append(value)
}

internal func buildDumpSelection(_ args: DumpArguments) throws -> DumpSelection {
    var hadExplicitSelection = false
    var wantsFrameworks = false
    var dumpAllFrameworks = false

    // Legacy framework selection still works, but `--target` is preferred.
    var frameworkNames: Set<String> = []
    if !args.frameworks.isEmpty {
        hadExplicitSelection = true
        wantsFrameworks = true
        for name in args.frameworks {
            frameworkNames.insert(normalizeFrameworkTargetName(name))
        }
    }

    let frameworkFilters = args.filters
        .map { $0.lowercased() }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if !frameworkFilters.isEmpty {
        hadExplicitSelection = true
        wantsFrameworks = true
    }

    var dumpAllSystemLibraryExtras = false
    var systemLibraryItems: [String] = []
    var systemLibrarySeen: Set<String> = []

    var dumpAllUsrLibDylibs = false
    var usrLibDylibs: [String] = []
    var usrLibSeen: Set<String> = []

    if let scope = args.scope {
        hadExplicitSelection = true
        switch scope {
        case .frameworks:
            wantsFrameworks = true
        case .system:
            wantsFrameworks = true
            dumpAllSystemLibraryExtras = true
        case .all:
            wantsFrameworks = true
            dumpAllSystemLibraryExtras = true
            dumpAllUsrLibDylibs = true
        }
    }

    if !args.targets.isEmpty {
        hadExplicitSelection = true
    }

    for raw in args.targets {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ToolingError.invalidArgument("--target requires a non-empty value") }

        if value.hasPrefix("@") {
            switch value.lowercased() {
            case "@frameworks":
                wantsFrameworks = true
                dumpAllFrameworks = true
            case "@system":
                wantsFrameworks = true
                dumpAllFrameworks = true
                dumpAllSystemLibraryExtras = true
            case "@all":
                wantsFrameworks = true
                dumpAllFrameworks = true
                dumpAllSystemLibraryExtras = true
                dumpAllUsrLibDylibs = true
            default:
                throw ToolingError.invalidArgument("invalid preset target: \(value) (use @frameworks, @system, or @all)")
            }
            continue
        }

        if let frameworkName = extractFrameworkNameFromTargetPath(value) {
            wantsFrameworks = true
            frameworkNames.insert(normalizeFrameworkTargetName(frameworkName))
            continue
        }

        let ext = URL(fileURLWithPath: value).pathExtension.lowercased()
        if ext == "dylib" || value.hasPrefix("/usr/lib/") || value.hasPrefix("usr/lib/") {
            let name = try normalizeUsrLibTargetName(value)
            appendUnique(&usrLibDylibs, name, seen: &usrLibSeen)
            continue
        }

        if systemBundleTargetExtensions.contains(ext)
            || value.contains("/")
            || value.hasPrefix("/System/Library/")
            || value.hasPrefix("System/Library/")
        {
            let rel = try normalizeSystemLibraryRelativeTarget(value)
            appendUnique(&systemLibraryItems, rel, seen: &systemLibrarySeen)
            continue
        }

        // Default: treat as a framework name.
        wantsFrameworks = true
        frameworkNames.insert(normalizeFrameworkTargetName(value))
    }

    if !hadExplicitSelection {
        // Backward compatible default: dump all frameworks when nothing is explicitly selected.
        wantsFrameworks = true
        dumpAllFrameworks = true
    }

    if !wantsFrameworks,
       !dumpAllSystemLibraryExtras,
       systemLibraryItems.isEmpty,
       !dumpAllUsrLibDylibs,
       usrLibDylibs.isEmpty
    {
        throw ToolingError.invalidArgument("no dump targets specified")
    }

    // When a preset includes frameworks (e.g. @frameworks/@system/@all), treat it as "dump all"
    // rather than narrowing to explicitly named frameworks.
    if dumpAllFrameworks {
        frameworkNames = []
    }

    let categories = wantsFrameworks ? ["Frameworks", "PrivateFrameworks"] : []
    return DumpSelection(
        categories: categories,
        frameworkNames: frameworkNames,
        frameworkFilters: frameworkFilters,
        dumpAllFrameworks: dumpAllFrameworks,
        dumpAllSystemLibraryExtras: dumpAllSystemLibraryExtras,
        systemLibraryItems: systemLibraryItems,
        dumpAllUsrLibDylibs: dumpAllUsrLibDylibs,
        usrLibDylibs: usrLibDylibs
    )
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

private func looksLikePrivateHeaderKitRepo(_ repoRoot: URL, fileManager: FileManager) -> Bool {
    // Avoid accidentally treating some other Swift package as this repository.
    let markers = [
        repoRoot.appendingPathComponent("Sources/HeaderDumpCore/HeaderDumpMain.swift"),
        repoRoot.appendingPathComponent("Sources/HeaderDumpCLI/HeaderDumpMain.swift"),
    ]
    return markers.allSatisfy { fileManager.fileExists(atPath: $0.path) }
}

private func resolveExecMode(
    platform: TargetPlatform,
    requested: ExecMode?,
    headerdumpHost: URL?,
    headerdumpSim: URL?,
    runner: CommandRunning
) -> ExecMode {
    if platform == .macos {
        return .host
    }
    if let requested { return requested }
    if let _ = headerdumpSim, (try? Simctl.listRuntimes(runner: runner))?.isEmpty == false {
        return .simulator
    }
    if headerdumpHost != nil { return .host }
    if headerdumpSim != nil { return .simulator }
    return .host
}

private func shouldFallbackToHost(_ error: Error) -> Bool {
    // Prefer structured detection for ToolingError to avoid brittle string matching.
    if let toolingError = error as? ToolingError {
        switch toolingError {
        case .commandFailed(let command, _, let stderr):
            let cmd = command.joined(separator: " ").lowercased()
            if cmd.contains("simctl") {
                // If the runtime itself is missing, host fallback won't help.
                let message = (cmd + "\n" + stderr).lowercased()
                if message.contains("no available ios runtimes found") { return false }
                if message.contains("ios runtime not found or unavailable") { return false }
                return true
            }
        default:
            break
        }
    }

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
    hostHeaderdumpBin: URL?,
    headerdumpBin: URL,
    execMode: ExecMode,
    requestedExecMode: ExecMode?,
    args: DumpArguments,
    allowMacOSSelection: Bool,
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
    let macOSSelectionIndex = allowMacOSSelection ? runtimes.count + 1 : nil
    print("Available targets:")
    for (idx, r) in runtimes.enumerated() {
        print("  [\(idx + 1)] iOS \(r.version) (\(r.build))")
    }
    if let macOSSelectionIndex {
        print("  [\(macOSSelectionIndex)] macOS")
    }
    let defaultLabel: String
    if runtimes.isEmpty {
        if allowMacOSSelection {
            defaultLabel = "macOS"
        } else {
            throw ToolingError.message("no iOS runtimes available")
        }
    } else {
        defaultLabel = "latest iOS"
    }
    print("Select target (Enter for \(defaultLabel)): ", terminator: "")
    let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    try throwIfTerminationRequested()

    enum InteractiveTarget {
        case ios(RuntimeInfo)
        case macos
    }

    let target: InteractiveTarget
    if choice.isEmpty {
        if let runtime = runtimes.last {
            target = .ios(runtime)
        } else if allowMacOSSelection {
            target = .macos
        } else {
            throw ToolingError.message("no iOS runtimes available")
        }
    } else if let idx = Int(choice), idx > 0, idx <= runtimes.count {
        target = .ios(runtimes[idx - 1])
    } else if allowMacOSSelection, let idx = Int(choice), idx == macOSSelectionIndex {
        target = .macos
    } else if allowMacOSSelection, choice == "macos" {
        target = .macos
    } else {
        throw ToolingError.message("invalid selection")
    }

    if case .macos = target {
        try validatePlatformArguments(args: args, platform: .macos, requestedExecMode: requestedExecMode)
        guard let hostHeaderdumpBin else {
            throw ToolingError.message("headerdump not found (run `swift run -c release privateheaderkit-install` first)")
        }
        return try macOSSetup(
            rootDir: rootDir,
            headerdumpBin: hostHeaderdumpBin,
            args: args,
            categories: categories,
            frameworkNames: frameworkNames,
            frameworkFilters: frameworkFilters,
            layout: layout,
            useSharedCache: useSharedCache,
            verbose: verbose,
            runner: runner
        )
    }

    guard case let .ios(runtime) = target else {
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

    let env = ProcessInfo.processInfo.environment
    let defaultOut = defaultOutDir(platform: .ios, version: runtime.version, fallbackRoot: rootDir)
    let envOutDir = normalizedEnvValue(env["PH_OUT_DIR"])
    let outDir = args.outDir
        ?? envOutDir.map { URL(fileURLWithPath: $0) }
        ?? defaultOut
    let stageDir = FileOps.buildStageDir(outDir: outDir)
    let skipExisting = resolveSkipExisting(args, env: env)

    if let device {
        print("Using device: \(device.name) (\(device.state))")
    }
    print("Output directory: \(outDir.path)")

    return Context(
        platform: .ios,
        execMode: execMode,
        headerdumpBin: headerdumpBin.resolvingSymlinksInPath(),
        osVersionLabel: runtime.version,
        systemRoot: runtime.runtimeRoot,
        runtimeId: runtime.identifier,
        runtimeBuild: runtime.build,
        macOSBuildVersion: nil,
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

    let env = ProcessInfo.processInfo.environment
    let defaultOut = defaultOutDir(platform: .ios, version: version, fallbackRoot: rootDir)
    let envOutDir = normalizedEnvValue(env["PH_OUT_DIR"])
    let outDir = args.outDir
        ?? envOutDir.map { URL(fileURLWithPath: $0) }
        ?? defaultOut
    let stageDir = FileOps.buildStageDir(outDir: outDir)
    let skipExisting = resolveSkipExisting(args, env: env)

    return Context(
        platform: .ios,
        execMode: execMode,
        headerdumpBin: headerdumpBin.resolvingSymlinksInPath(),
        osVersionLabel: version,
        systemRoot: runtime.runtimeRoot,
        runtimeId: runtime.identifier,
        runtimeBuild: runtime.build,
        macOSBuildVersion: nil,
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

private func macOSSetup(
    rootDir: URL,
    headerdumpBin: URL,
    args: DumpArguments,
    categories: [String],
    frameworkNames: Set<String>,
    frameworkFilters: [String],
    layout: String,
    useSharedCache: Bool,
    verbose: Bool,
    runner: CommandRunning
) throws -> Context {
    let macOSVersion = try readMacOSVersionInfo(runner: runner)
    let env = ProcessInfo.processInfo.environment
    let defaultOut = defaultOutDir(platform: .macos, version: macOSVersion.productVersion, fallbackRoot: rootDir)
    let envOutDir = normalizedEnvValue(env["PH_OUT_DIR"])
    let outDir = args.outDir
        ?? envOutDir.map { URL(fileURLWithPath: $0) }
        ?? defaultOut
    let stageDir = FileOps.buildStageDir(outDir: outDir)
    let skipExisting = resolveSkipExisting(args, env: env)

    print("Using host macOS \(macOSVersion.productVersion) (\(macOSVersion.buildVersion))")
    print("Output directory: \(outDir.path)")

    return Context(
        platform: .macos,
        execMode: .host,
        headerdumpBin: headerdumpBin.resolvingSymlinksInPath(),
        osVersionLabel: macOSVersion.productVersion,
        systemRoot: "/",
        runtimeId: nil,
        runtimeBuild: nil,
        macOSBuildVersion: macOSVersion.buildVersion,
        device: nil,
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
    let runStart = DispatchTime.now().uptimeNanoseconds
    let runner = ProcessRunner()
    let env = ProcessInfo.processInfo.environment
    let fileManager = FileManager.default

    let args = Array(CommandLine.arguments.dropFirst())
    let parsed = try parseArguments(args)
    try throwIfTerminationRequested()
    let hasExplicitPlatform = parsed.platform != nil || normalizedEnvValue(env["PH_PLATFORM"]) != nil
    let platform = try resolvePlatform(parsed, env: env)
    let requestedExecMode = try resolveRequestedExecMode(parsed, env: env)
    try validatePlatformArguments(args: parsed, platform: platform, requestedExecMode: requestedExecMode)

    if parsed.listRuntimes {
        try listRuntimesCommand(jsonOutput: parsed.json, runner: runner)
        return
    }
    if parsed.listDevices {
        try listDevicesCommand(version: parsed.runtimeForListDevices, jsonOutput: parsed.json, runner: runner)
        return
    }

    let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let repoRootFromCwd = PathUtils.findRepositoryRoot(startingAt: cwdURL)
    let repoRoot: URL?
    if let root = repoRootFromCwd, looksLikePrivateHeaderKitRepo(root, fileManager: fileManager) {
        repoRoot = root
    } else {
        repoRoot = nil
    }
    let rootDir = repoRoot ?? cwdURL

    let binaries = resolveHeaderdumpBinaries(rootDir: repoRoot, env: env)
    let autoExecMode = requestedExecMode == nil
    var execMode = resolveExecMode(
        platform: platform,
        requested: requestedExecMode,
        headerdumpHost: binaries.host,
        headerdumpSim: binaries.sim,
        runner: runner
    )

    let selection = try buildDumpSelection(parsed)
    let layout = try resolveLayout(parsed.layout, env: env)
    let useSharedCache = resolveSharedCache(parsed, env: env)
    let verbose = resolveVerbose(parsed, env: env)
    let nestedEnabled = resolveNestedEnabled(parsed)

    func setupContext(_ mode: ExecMode) throws -> Context {
        if platform == .macos {
            guard let host = binaries.host else {
                throw ToolingError.message("headerdump not found (run `swift run -c release privateheaderkit-install` first)")
            }
            return try macOSSetup(
                rootDir: rootDir,
                headerdumpBin: host,
                args: parsed,
                categories: selection.categories,
                frameworkNames: selection.frameworkNames,
                frameworkFilters: selection.frameworkFilters,
                layout: layout,
                useSharedCache: useSharedCache,
                verbose: verbose,
                runner: runner
            )
        }

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
                hostHeaderdumpBin: binaries.host,
                headerdumpBin: headerdumpBin,
                execMode: mode,
                requestedExecMode: requestedExecMode,
                args: parsed,
                allowMacOSSelection: !hasExplicitPlatform && requestedExecMode != .simulator,
                categories: selection.categories,
                frameworkNames: selection.frameworkNames,
                frameworkFilters: selection.frameworkFilters,
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
            categories: selection.categories,
            frameworkNames: selection.frameworkNames,
            frameworkFilters: selection.frameworkFilters,
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
        if platform == .ios, autoExecMode, execMode == .simulator, shouldFallbackToHost(error), binaries.host != nil {
            fputs("Simulator unavailable; falling back to host: \(error)\n", stderr)
            execMode = .host
            ctx = try setupContext(execMode)
        } else {
            throw error
        }
    }

    if ctx.execMode == .simulator {
        guard var device = ctx.device else { throw ToolingError.message("no simulator device available") }
        do {
            try Simctl.ensureDeviceBooted(&device, runner: runner, force: false)
            ctx.device = device
        } catch {
            if platform == .ios, autoExecMode, execMode == .simulator, binaries.host != nil {
                fputs("Simulator unavailable; falling back to host: \(error)\n", stderr)
                execMode = .host
                ctx = try setupContext(execMode)
            } else {
                throw error
            }
        }
    }

    ctx.nestedEnabled = nestedEnabled

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

    if selection.dumpAllSystemLibraryExtras || !selection.systemLibraryItems.isEmpty {
        try FileOps.resetStageDir(ctx.stageDir)
        let items = selection.dumpAllSystemLibraryExtras
            ? (try listSystemLibraryExtras(ctx: ctx))
            : selection.systemLibraryItems
        _ = try dumpSystemLibraryItems(ctx: ctx, items: items, runner: runner)
    }
    if selection.dumpAllUsrLibDylibs || !selection.usrLibDylibs.isEmpty {
        try FileOps.resetStageDir(ctx.stageDir)
        let dylibs = selection.dumpAllUsrLibDylibs
            ? (try listUsrLibDylibs(ctx: ctx))
            : selection.usrLibDylibs
        _ = try dumpUsrLibDylibItems(ctx: ctx, dylibs: dylibs, runner: runner)
    }

    try writeMetadata(ctx: ctx, runner: runner)
    let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds &- runStart) / 1_000_000_000.0
    let elapsedText = String(format: "%.1f", elapsedSeconds)
    let platformLabel = ctx.platform == .ios ? "iOS" : "macOS"
    print("Done (\(platformLabel)): \(ctx.outDir.path) (elapsed: \(elapsedText)s)")
}

private func listFrameworks(category: String, ctx: Context) throws -> [String] {
    let dirURL = URL(fileURLWithPath: ctx.systemRoot, isDirectory: true)
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

private func fileManagerIsDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
    var isDir = ObjCBool(false)
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

private let normalizedBundleExtensions: Set<String> = ["app", "bundle", "xpc", "appex"]

private func normalizedBundleDirURLIfNeeded(_ url: URL) -> URL {
    let ext = url.pathExtension.lowercased()
    if normalizedBundleExtensions.contains(ext) {
        return url.deletingPathExtension()
    }
    return url
}

private func normalizeNestedXPCAndPlugIns(in bundleDir: URL, overwrite: Bool) throws {
    let fm = FileManager.default
    let xpcDir = bundleDir.appendingPathComponent("XPCServices", isDirectory: true)
    try FileOps.normalizeBundleDirs(in: xpcDir, allowedExtensions: ["xpc"], overwrite: overwrite, fileManager: fm)

    let plugInsDir = bundleDir.appendingPathComponent("PlugIns", isDirectory: true)
    try FileOps.normalizeBundleDirs(in: plugInsDir, allowedExtensions: ["appex"], overwrite: overwrite, fileManager: fm)
}

private func denormalizeNestedXPCAndPlugIns(in bundleDir: URL, overwrite: Bool) throws {
    let fm = FileManager.default
    let xpcDir = bundleDir.appendingPathComponent("XPCServices", isDirectory: true)
    try FileOps.denormalizeBundleDirs(in: xpcDir, bundleExtension: "xpc", overwrite: overwrite, fileManager: fm)

    let plugInsDir = bundleDir.appendingPathComponent("PlugIns", isDirectory: true)
    try FileOps.denormalizeBundleDirs(in: plugInsDir, bundleExtension: "appex", overwrite: overwrite, fileManager: fm)
}

private func directoryContainsHeaderArtifacts(_ dir: URL, fileManager: FileManager = .default) -> Bool {
    guard fileManagerIsDirectory(dir, fileManager: fileManager) else { return false }
    guard let entries = try? fileManager.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return false
    }

    for entry in entries {
        guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let ext = entry.pathExtension.lowercased()
        if ext == "h" || ext == "swiftinterface" {
            return true
        }
    }
    return false
}

private func bundleOutputHasHeaderArtifacts(_ bundleDir: URL, fileManager: FileManager = .default) -> Bool {
    directoryContainsHeaderArtifacts(bundleDir.appendingPathComponent("Headers", isDirectory: true), fileManager: fileManager)
}

private func dylibOutputHasHeaderArtifacts(_ dylibDir: URL, fileManager: FileManager = .default) -> Bool {
    directoryContainsHeaderArtifacts(dylibDir, fileManager: fileManager)
}

private func appendingRelativePath(_ base: URL, _ relativePath: String, isDirectory: Bool = true) -> URL {
    var url = base
    let parts = relativePath.split(separator: "/").map(String.init)
    for (idx, part) in parts.enumerated() {
        let isLast = idx == parts.count - 1
        url.appendPathComponent(part, isDirectory: isLast ? isDirectory : true)
    }
    return url
}

private func listNestedBundles(ctx: Context, systemLibraryRelativeBundlePath: String) throws -> [String] {
    let fileManager = FileManager.default
    let systemLibraryURL = URL(fileURLWithPath: ctx.systemRoot, isDirectory: true)
        .appendingPathComponent("System/Library", isDirectory: true)
    let bundleURL = appendingRelativePath(systemLibraryURL, systemLibraryRelativeBundlePath, isDirectory: true)

    guard fileManagerIsDirectory(bundleURL, fileManager: fileManager) else { return [] }

    var results: [String] = []

    let xpcDir = bundleURL.appendingPathComponent("XPCServices", isDirectory: true)
    if fileManagerIsDirectory(xpcDir, fileManager: fileManager),
       let entries = try? fileManager.contentsOfDirectory(at: xpcDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    {
        for entry in entries where entry.lastPathComponent.hasSuffix(".xpc") {
            results.append(systemLibraryRelativeBundlePath + "/XPCServices/" + entry.lastPathComponent)
        }
    }

    let plugInsDir = bundleURL.appendingPathComponent("PlugIns", isDirectory: true)
    if fileManagerIsDirectory(plugInsDir, fileManager: fileManager),
       let entries = try? fileManager.contentsOfDirectory(at: plugInsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    {
        for entry in entries where entry.lastPathComponent.hasSuffix(".appex") {
            results.append(systemLibraryRelativeBundlePath + "/PlugIns/" + entry.lastPathComponent)
        }
    }

    results.sort()
    return results
}

private func listSystemLibraryExtras(ctx: Context) throws -> [String] {
    let fileManager = FileManager.default
    let systemLibraryURL = URL(fileURLWithPath: ctx.systemRoot, isDirectory: true)
        .appendingPathComponent("System/Library", isDirectory: true)
    guard fileManagerIsDirectory(systemLibraryURL, fileManager: fileManager) else {
        throw ToolingError.message("failed to read \(systemLibraryURL.path)")
    }

    let frameworksDir = systemLibraryURL.appendingPathComponent("Frameworks", isDirectory: true)
    let privateFrameworksDir = systemLibraryURL.appendingPathComponent("PrivateFrameworks", isDirectory: true)

    guard let enumerator = fileManager.enumerator(
        at: systemLibraryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ToolingError.message("failed to enumerate \(systemLibraryURL.path)")
    }

    var results: [String] = []
    while let url = enumerator.nextObject() as? URL {
        try throwIfTerminationRequested()
        guard fileManagerIsDirectory(url, fileManager: fileManager) else { continue }

        if url.path == frameworksDir.path || url.path == privateFrameworksDir.path {
            enumerator.skipDescendants()
            continue
        }

        let ext = url.pathExtension.lowercased()
        guard ext == "app" || ext == "bundle" || ext == "xpc" || ext == "appex" else {
            continue
        }

        let basePath = systemLibraryURL.path.hasSuffix("/") ? systemLibraryURL.path : (systemLibraryURL.path + "/")
        guard url.path.hasPrefix(basePath) else { continue }
        let relative = String(url.path.dropFirst(basePath.count))
        if !relative.isEmpty {
            results.append(relative)
        }
        enumerator.skipDescendants()
    }

    results.sort()
    return results
}

private func listUsrLibDylibs(ctx: Context) throws -> [String] {
    let fileManager = FileManager.default
    let usrLibURL = URL(fileURLWithPath: ctx.systemRoot, isDirectory: true)
        .appendingPathComponent("usr", isDirectory: true)
        .appendingPathComponent("lib", isDirectory: true)
    guard fileManagerIsDirectory(usrLibURL, fileManager: fileManager) else {
        throw ToolingError.message("failed to read \(usrLibURL.path)")
    }

    let entries = try fileManager.contentsOfDirectory(at: usrLibURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    var dylibs: [String] = []
    for entry in entries {
        guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        guard entry.pathExtension.lowercased() == "dylib" else { continue }
        dylibs.append(entry.lastPathComponent)
    }
    dylibs.sort()
    return dylibs
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
        let ext = url.pathExtension.lowercased()
        if ext != "h" && ext != "swiftinterface" { continue }
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
    try throwIfTerminationRequested()
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
    try throwIfTerminationRequested()
    let frameworks = try listFrameworks(category: category, ctx: ctx)
    if frameworks.isEmpty {
        print("Skipping \(category): no frameworks found under /System/Library/\(category)")
        return false
    }

    let total = frameworks.count
    var failures: [String] = []
    let inlineProgress = canInlineFrameworkProgress(ctx: ctx)

    var existing: Set<String> = []
    if ctx.skipExisting {
        existing = existingFrameworksInCategory(ctx: ctx, category: category, frameworks: Set(frameworks))
    }

    for (idx, item) in frameworks.enumerated() {
        try throwIfTerminationRequested()
        if ctx.skipExisting, existing.contains(item) {
            if ctx.layout == "headers" {
                let baseName = item.hasSuffix(".framework") ? String(item.dropLast(".framework".count)) : item
                let dest = ctx.outDir
                    .appendingPathComponent(category, isDirectory: true)
                    .appendingPathComponent(baseName, isDirectory: true)
                try? normalizeNestedXPCAndPlugIns(in: dest, overwrite: false)
            }
            print("Skipping existing: \(category) (\(idx + 1)/\(total)) \(item)")
            continue
        }

        let progressText = "Dumping: \(category) (\(idx + 1)/\(total)) \(item)"
        if inlineProgress {
            renderInlineProgressStart(progressText)
        } else {
            print(progressText)
        }

        let frameworkStart = DispatchTime.now().uptimeNanoseconds
        let path = "\(category)/\(item)"
        let result = try runHeaderdump(category: path, ctx: ctx, runner: runner, streamOutput: !inlineProgress)
        let frameworkElapsedText = formatElapsedSeconds(since: frameworkStart)
        if result.wasKilled || result.status != 0 {
            if inlineProgress {
                renderInlineProgressEnd("Failed: \(category) (\(idx + 1)/\(total)) \(item) (elapsed: \(frameworkElapsedText)s)")
            }
            reportLastLines(result.lastLines)
            failures.append(path)
            if !inlineProgress {
                print("Failed: \(category) (\(idx + 1)/\(total)) \(item) (elapsed: \(frameworkElapsedText)s)")
            }
        } else {
            if ctx.nestedEnabled {
                let parentBundle = path
                let nestedBundles = try listNestedBundles(
                    ctx: ctx,
                    systemLibraryRelativeBundlePath: parentBundle
                )
                for nested in nestedBundles {
                    let nestedResult = try runHeaderdump(category: nested, ctx: ctx, runner: runner, streamOutput: !inlineProgress)
                    if nestedResult.wasKilled || nestedResult.status != 0 {
                        reportLastLines(nestedResult.lastLines)
                        failures.append(nested)
                    }
                }
            }

            try relocateFrameworkOutput(ctx: ctx, category: category, frameworkName: item)
            if ctx.layout == "headers" {
                try normalizeFrameworkDir(ctx: ctx, category: category, frameworkName: item, overwrite: !ctx.skipExisting)
                let baseName = item.hasSuffix(".framework") ? String(item.dropLast(".framework".count)) : item
                let dest = ctx.outDir
                    .appendingPathComponent(category, isDirectory: true)
                    .appendingPathComponent(baseName, isDirectory: true)
                try normalizeNestedXPCAndPlugIns(in: dest, overwrite: !ctx.skipExisting)
            }
            if inlineProgress {
                renderInlineProgressEnd("\(progressText) (elapsed: \(frameworkElapsedText)s)")
            } else {
                print("Completed: \(category) (\(idx + 1)/\(total)) \(item) (elapsed: \(frameworkElapsedText)s)")
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

private func dumpSystemLibraryItems(ctx: Context, items: [String], runner: CommandRunning) throws -> Bool {
    try throwIfTerminationRequested()
    print("Dumping: SystemLibrary")

    if items.isEmpty {
        print("Skipping SystemLibrary: no items selected")
        return false
    }

    let total = items.count
    var failures: [String] = []
    let inlineProgress = canInlineFrameworkProgress(ctx: ctx)
    let fileManager = FileManager.default

    let outBase = ctx.outDir.appendingPathComponent("SystemLibrary", isDirectory: true)
    let normalizeBundles = (ctx.layout == "headers")

    for (idx, relPath) in items.enumerated() {
        try throwIfTerminationRequested()

        let dest = appendingRelativePath(outBase, relPath, isDirectory: true)
        let normalizedDest = normalizedBundleDirURLIfNeeded(dest)
        if ctx.skipExisting,
           (bundleOutputHasHeaderArtifacts(dest, fileManager: fileManager) || bundleOutputHasHeaderArtifacts(normalizedDest, fileManager: fileManager))
        {
            // Best-effort: keep existing outputs consistent with the requested layout even when skipping.
            //
            // In particular, switching from `--layout headers` to `--layout bundle` should not require a re-dump:
            // rename `Foo` -> `Foo.bundle` (and similarly for nested XPC/appex bundles) when possible.
            var existingDir: URL?
            if fileManager.fileExists(atPath: dest.path) {
                existingDir = dest
            } else if fileManager.fileExists(atPath: normalizedDest.path) {
                existingDir = normalizedDest
            }

            if var bundleDir = existingDir {
                if normalizeBundles {
                    bundleDir = (try? FileOps.normalizeBundleDir(
                        bundleDir,
                        allowedExtensions: normalizedBundleExtensions,
                        overwrite: false,
                        fileManager: fileManager
                    )) ?? bundleDir
                    try? normalizeNestedXPCAndPlugIns(in: bundleDir, overwrite: false)
                } else {
                    let ext = dest.pathExtension
                    bundleDir = (try? FileOps.denormalizeBundleDir(
                        bundleDir,
                        bundleExtension: ext,
                        overwrite: false,
                        fileManager: fileManager
                    )) ?? bundleDir
                    try? denormalizeNestedXPCAndPlugIns(in: bundleDir, overwrite: false)
                }
            }
            print("Skipping existing: SystemLibrary (\(idx + 1)/\(total)) \(relPath)")
            continue
        }

        let progressText = "Dumping: SystemLibrary (\(idx + 1)/\(total)) \(relPath)"
        if inlineProgress {
            renderInlineProgressStart(progressText)
        } else {
            print(progressText)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let result = try runHeaderdump(category: relPath, ctx: ctx, runner: runner, streamOutput: !inlineProgress)
        let elapsedText = formatElapsedSeconds(since: start)
        if result.wasKilled || result.status != 0 {
            if inlineProgress {
                renderInlineProgressEnd("Failed: SystemLibrary (\(idx + 1)/\(total)) \(relPath) (elapsed: \(elapsedText)s)")
            }
            reportLastLines(result.lastLines)
            failures.append("SystemLibrary/\(relPath)")
            if !inlineProgress {
                print("Failed: SystemLibrary (\(idx + 1)/\(total)) \(relPath) (elapsed: \(elapsedText)s)")
            }
            continue
        }

        if ctx.nestedEnabled {
            let nestedBundles = try listNestedBundles(ctx: ctx, systemLibraryRelativeBundlePath: relPath)
            for nested in nestedBundles {
                let nestedResult = try runHeaderdump(category: nested, ctx: ctx, runner: runner, streamOutput: !inlineProgress)
                if nestedResult.wasKilled || nestedResult.status != 0 {
                    reportLastLines(nestedResult.lastLines)
                    failures.append("SystemLibrary/\(nested)")
                }
            }
        }

        try relocateSystemLibraryItemOutput(ctx: ctx, systemLibraryRelativePath: relPath, destBaseDir: outBase)

        if normalizeBundles {
            var bundleDir = dest
            bundleDir = try FileOps.normalizeBundleDir(
                bundleDir,
                allowedExtensions: normalizedBundleExtensions,
                overwrite: !ctx.skipExisting,
                fileManager: fileManager
            )
            try normalizeNestedXPCAndPlugIns(in: bundleDir, overwrite: !ctx.skipExisting)
        }

        if inlineProgress {
            renderInlineProgressEnd("\(progressText) (elapsed: \(elapsedText)s)")
        } else {
            print("Completed: SystemLibrary (\(idx + 1)/\(total)) \(relPath) (elapsed: \(elapsedText)s)")
        }
    }

    if !failures.isEmpty {
        let summary = "headerdump failed for \(failures.count) items under SystemLibrary"
        fputs(summary + "\n", stderr)
        try writeFailures(ctx: ctx, summary: summary, failures: failures)
        return true
    }
    return false
}

private func dumpUsrLibDylibItems(ctx: Context, dylibs: [String], runner: CommandRunning) throws -> Bool {
    try throwIfTerminationRequested()
    print("Dumping: usr/lib")

    if dylibs.isEmpty {
        print("Skipping usr/lib: no items selected")
        return false
    }

    let total = dylibs.count
    var failures: [String] = []
    let inlineProgress = canInlineFrameworkProgress(ctx: ctx)
    let fileManager = FileManager.default

    let outBase = ctx.outDir
        .appendingPathComponent("usr", isDirectory: true)
        .appendingPathComponent("lib", isDirectory: true)

    for (idx, name) in dylibs.enumerated() {
        try throwIfTerminationRequested()

        let dest = outBase.appendingPathComponent(name, isDirectory: true)
        if ctx.skipExisting, dylibOutputHasHeaderArtifacts(dest, fileManager: fileManager) {
            print("Skipping existing: usr/lib (\(idx + 1)/\(total)) \(name)")
            continue
        }

        let progressText = "Dumping: usr/lib (\(idx + 1)/\(total)) \(name)"
        if inlineProgress {
            renderInlineProgressStart(progressText)
        } else {
            print(progressText)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let inputPath: String
        switch ctx.execMode {
        case .simulator:
            inputPath = "/usr/lib/\(name)"
        case .host:
            inputPath = URL(fileURLWithPath: ctx.systemRoot, isDirectory: true)
                .appendingPathComponent("usr", isDirectory: true)
                .appendingPathComponent("lib", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
        }

        let result = try runHeaderdumpPath(path: inputPath, ctx: ctx, runner: runner, streamOutput: !inlineProgress)
        let elapsedText = formatElapsedSeconds(since: start)
        if result.wasKilled || result.status != 0 {
            if inlineProgress {
                renderInlineProgressEnd("Failed: usr/lib (\(idx + 1)/\(total)) \(name) (elapsed: \(elapsedText)s)")
            }
            reportLastLines(result.lastLines)
            failures.append("usr/lib/\(name)")
            if !inlineProgress {
                print("Failed: usr/lib (\(idx + 1)/\(total)) \(name) (elapsed: \(elapsedText)s)")
            }
            continue
        }

        try relocateUsrLibOutput(ctx: ctx, dylibName: name)

        if inlineProgress {
            renderInlineProgressEnd("\(progressText) (elapsed: \(elapsedText)s)")
        } else {
            print("Completed: usr/lib (\(idx + 1)/\(total)) \(name) (elapsed: \(elapsedText)s)")
        }
    }

    if !failures.isEmpty {
        let summary = "headerdump failed for \(failures.count) items under usr/lib"
        fputs(summary + "\n", stderr)
        try writeFailures(ctx: ctx, summary: summary, failures: failures)
        return true
    }
    return false
}

private func relocateSystemLibraryItemOutput(ctx: Context, systemLibraryRelativePath: String, destBaseDir: URL) throws {
    let fileManager = FileManager.default
    var src: URL?
    for base in FileOps.stageSystemLibraryRoots(stageDir: ctx.stageDir, runtimeRoot: ctx.systemRoot) {
        let candidate = appendingRelativePath(base, systemLibraryRelativePath, isDirectory: true)
        if fileManager.fileExists(atPath: candidate.path), !FileOps.isSymlink(candidate) {
            src = candidate
            break
        }
    }
    guard let src else { return }

    let dest = appendingRelativePath(destBaseDir, systemLibraryRelativePath, isDirectory: true)
    try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

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

private func relocateUsrLibOutput(ctx: Context, dylibName: String) throws {
    let fileManager = FileManager.default
    var src: URL?
    for base in FileOps.stageUsrLibRoots(stageDir: ctx.stageDir, runtimeRoot: ctx.systemRoot) {
        let candidate = base.appendingPathComponent(dylibName, isDirectory: true)
        if fileManager.fileExists(atPath: candidate.path), !FileOps.isSymlink(candidate) {
            src = candidate
            break
        }
    }
    guard let src else { return }

    let destDir = ctx.outDir
        .appendingPathComponent("usr", isDirectory: true)
        .appendingPathComponent("lib", isDirectory: true)
    try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
    let dest = destDir.appendingPathComponent(dylibName, isDirectory: true)

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

private func relocateFrameworkOutput(ctx: Context, category: String, frameworkName: String) throws {
    let fileManager = FileManager.default
    var src: URL?
    for base in FileOps.stageSystemLibraryRoots(stageDir: ctx.stageDir, runtimeRoot: ctx.systemRoot) {
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

    for base in FileOps.stageSystemLibraryRoots(stageDir: ctx.stageDir, runtimeRoot: ctx.systemRoot) {
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
    try runHeaderdump(category: category, ctx: ctx, runner: runner, streamOutput: true)
}

private func runHeaderdump(
    category: String,
    ctx: Context,
    runner: CommandRunning,
    streamOutput: Bool
) throws -> StreamingCommandResult {
    switch ctx.execMode {
    case .host:
        return try runHeaderdumpHost(category: category, ctx: ctx, runner: runner, streamOutput: streamOutput)
    case .simulator:
        return try runHeaderdumpSimulator(category: category, ctx: ctx, runner: runner, streamOutput: streamOutput)
    }
}

private func runHeaderdumpHost(
    category: String,
    ctx: Context,
    runner: CommandRunning,
    streamOutput: Bool
) throws -> StreamingCommandResult {
    let sourcePath = URL(fileURLWithPath: ctx.systemRoot, isDirectory: true)
        .appendingPathComponent("System/Library", isDirectory: true)
        .appendingPathComponent(category, isDirectory: false)
        .path
    let ext = URL(fileURLWithPath: category).pathExtension
    let isRecursive = !category.contains("/") && ext.isEmpty

    var cmd = [ctx.headerdumpBin.path, "-o", ctx.stageDir.path]
    if isRecursive {
        cmd += ["-r", sourcePath]
    } else {
        cmd.append(sourcePath)
    }
    cmd += ["-b", "-h"]
    if ctx.verbose { cmd.append("-D") }
    if ctx.skipExisting { cmd.append("-s") }
    if ctx.platform == .macos { cmd.append("-R") }

    var env: [String: String]? = nil
    if ctx.useSharedCache {
        cmd.append("-c")
        if ctx.platform == .ios {
            env = ["SIMCTL_CHILD_DYLD_ROOT_PATH": ctx.systemRoot]
        }
    }
    let result = try runDumpStreaming(cmd, env: env, cwd: nil, streamOutput: streamOutput)
    try throwIfTerminationRequested()
    return result
}

private func shouldRetrySimulatorBoot(_ lastLines: [String]) -> Bool {
    for line in lastLines {
        let lowered = line.lowercased()
        if lowered.contains("device is not booted") { return true }
        if lowered.contains("bad or unknown session") { return true }
    }
    return false
}

private func runHeaderdumpSimulator(
    category: String,
    ctx: Context,
    runner: CommandRunning,
    streamOutput: Bool
) throws -> StreamingCommandResult {
    guard var device = ctx.device else { throw ToolingError.message("no simulator device available") }
    let sourcePath = "/System/Library/\(category)"
    let ext = URL(fileURLWithPath: category).pathExtension
    let isRecursive = !category.contains("/") && ext.isEmpty

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

    var env: [String: String] = [
        "SIMCTL_CHILD_PH_RUNTIME_ROOT": ctx.systemRoot,
        "SIMCTL_CHILD_DYLD_ROOT_PATH": ctx.systemRoot,
    ]
    // `simctl spawn` only forwards environment variables to the child when they are prefixed with
    // `SIMCTL_CHILD_`. Map the unprefixed host env vars to the child-prefixed versions so users
    // can just set `PH_PROFILE=1` / `PH_SWIFT_EVENTS=1` when running `privateheaderkit-dump`.
    let parentEnv = ProcessInfo.processInfo.environment
    if parentEnv["SIMCTL_CHILD_PH_PROFILE"] == nil, parentEnv["PH_PROFILE"] == "1" {
        env["SIMCTL_CHILD_PH_PROFILE"] = "1"
    }
    if parentEnv["SIMCTL_CHILD_PH_SWIFT_EVENTS"] == nil, parentEnv["PH_SWIFT_EVENTS"] == "1" {
        env["SIMCTL_CHILD_PH_SWIFT_EVENTS"] = "1"
    }
    if parentEnv["SIMCTL_CHILD_PH_SYMBOL_PROFILE"] == nil, parentEnv["PH_SYMBOL_PROFILE"] == "1" {
        env["SIMCTL_CHILD_PH_SYMBOL_PROFILE"] = "1"
    }

    var result = try runDumpStreaming(cmd, env: env, cwd: nil, streamOutput: streamOutput)
    try throwIfTerminationRequested()
    if result.status != 0, shouldRetrySimulatorBoot(result.lastLines) {
        try Simctl.ensureDeviceBooted(&device, runner: runner, force: true)
        result = try runDumpStreaming(cmd, env: env, cwd: nil, streamOutput: streamOutput)
        try throwIfTerminationRequested()
    }
    return result
}

private func runHeaderdumpPath(
    path: String,
    ctx: Context,
    runner: CommandRunning,
    streamOutput: Bool
) throws -> StreamingCommandResult {
    switch ctx.execMode {
    case .host:
        return try runHeaderdumpPathHost(path: path, ctx: ctx, runner: runner, streamOutput: streamOutput)
    case .simulator:
        return try runHeaderdumpPathSimulator(path: path, ctx: ctx, runner: runner, streamOutput: streamOutput)
    }
}

private func runHeaderdumpPathHost(
    path: String,
    ctx: Context,
    runner: CommandRunning,
    streamOutput: Bool
) throws -> StreamingCommandResult {
    var cmd = [ctx.headerdumpBin.path, "-o", ctx.stageDir.path, path]
    cmd += ["-b", "-h"]
    if ctx.verbose { cmd.append("-D") }
    if ctx.skipExisting { cmd.append("-s") }
    if ctx.platform == .macos { cmd.append("-R") }

    var env: [String: String]? = nil
    if ctx.useSharedCache {
        cmd.append("-c")
        if ctx.platform == .ios {
            env = ["SIMCTL_CHILD_DYLD_ROOT_PATH": ctx.systemRoot]
        }
    }

    let result = try runDumpStreaming(cmd, env: env, cwd: nil, streamOutput: streamOutput)
    try throwIfTerminationRequested()
    return result
}

private func runHeaderdumpPathSimulator(
    path: String,
    ctx: Context,
    runner: CommandRunning,
    streamOutput: Bool
) throws -> StreamingCommandResult {
    guard var device = ctx.device else { throw ToolingError.message("no simulator device available") }

    var cmd = ["xcrun", "simctl", "spawn", device.udid, ctx.headerdumpBin.path, "-o", ctx.stageDir.path, path]
    cmd += ["-b", "-h"]
    if ctx.verbose { cmd.append("-D") }
    if ctx.skipExisting { cmd.append("-s") }
    if ctx.useSharedCache { cmd.append("-c") }

    var env: [String: String] = [
        "SIMCTL_CHILD_PH_RUNTIME_ROOT": ctx.systemRoot,
        "SIMCTL_CHILD_DYLD_ROOT_PATH": ctx.systemRoot,
    ]
    let parentEnv = ProcessInfo.processInfo.environment
    if parentEnv["SIMCTL_CHILD_PH_PROFILE"] == nil, parentEnv["PH_PROFILE"] == "1" {
        env["SIMCTL_CHILD_PH_PROFILE"] = "1"
    }
    if parentEnv["SIMCTL_CHILD_PH_SWIFT_EVENTS"] == nil, parentEnv["PH_SWIFT_EVENTS"] == "1" {
        env["SIMCTL_CHILD_PH_SWIFT_EVENTS"] = "1"
    }
    if parentEnv["SIMCTL_CHILD_PH_SYMBOL_PROFILE"] == nil, parentEnv["PH_SYMBOL_PROFILE"] == "1" {
        env["SIMCTL_CHILD_PH_SYMBOL_PROFILE"] = "1"
    }

    var result = try runDumpStreaming(cmd, env: env, cwd: nil, streamOutput: streamOutput)
    try throwIfTerminationRequested()
    if result.status != 0, shouldRetrySimulatorBoot(result.lastLines) {
        try Simctl.ensureDeviceBooted(&device, runner: runner, force: true)
        result = try runDumpStreaming(cmd, env: env, cwd: nil, streamOutput: streamOutput)
        try throwIfTerminationRequested()
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

private func formatElapsedSeconds(since startNanos: UInt64) -> String {
    let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000_000.0
    return String(format: "%.1f", elapsedSeconds)
}

private func canInlineFrameworkProgress(ctx: Context) -> Bool {
    guard isatty(STDOUT_FILENO) != 0 else { return false }
    guard !ctx.verbose else { return false }
    let env = ProcessInfo.processInfo.environment
    if env["PH_PROFILE"] == "1" || env["SIMCTL_CHILD_PH_PROFILE"] == "1" { return false }
    if env["PH_SWIFT_EVENTS"] == "1" || env["SIMCTL_CHILD_PH_SWIFT_EVENTS"] == "1" { return false }
    if env["PH_SYMBOL_PROFILE"] == "1" || env["SIMCTL_CHILD_PH_SYMBOL_PROFILE"] == "1" { return false }
    return true
}

private func renderInlineProgressStart(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

private func renderInlineProgressEnd(_ text: String) {
    let line = "\r\u{001B}[2K\(text)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
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

    let metadata: String
    switch ctx.platform {
    case .ios:
        metadata = """
        Generated: \(generatedAt)
        Platform: iOS
        RuntimeRoot: \(ctx.systemRoot)
        RuntimeIdentifier: \(ctx.runtimeId ?? "unknown")
        RuntimeBuild: \(ctx.runtimeBuild ?? "unknown")
        iOS: \(ctx.osVersionLabel)
        HeadersPath: \(ctx.outDir.path)
        Layout: \(ctx.layout)
        HeaderCount: \(headerCount)
        Xcode: \(xcodeInfo)
        Notes: headerdump output; targets under /System/Library and /usr/lib (optional); -b -h \(skip)
        """
    case .macos:
        metadata = """
        Generated: \(generatedAt)
        Platform: macOS
        SourceRoot: \(ctx.systemRoot)
        macOS: \(ctx.osVersionLabel)
        BuildVersion: \(ctx.macOSBuildVersion ?? "unknown")
        HeadersPath: \(ctx.outDir.path)
        Layout: \(ctx.layout)
        HeaderCount: \(headerCount)
        Xcode: \(xcodeInfo)
        Notes: headerdump output; targets under /System/Library and /usr/lib (optional); -b -h \(skip)
        """
    }

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
        exit(1)
    }
}

#endif
