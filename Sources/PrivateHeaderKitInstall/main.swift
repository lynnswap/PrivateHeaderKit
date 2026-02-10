import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)

private struct InstallOptions {
    var prefix: String?
    var bindir: String?
    var dryRun: Bool
}

private enum InstallError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

@main
struct PrivateHeaderKitInstallMain {
    static func main() {
        do {
            let options = try parseOptions(CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
            try install(options: options)
        } catch let error as InstallError {
            logError("error: \(error.description)")
            logError("run with --help for usage")
            exit(1)
        } catch {
            logError("error: \(error)")
            logError("run with --help for usage")
            exit(1)
        }
    }
}

private func printUsage() {
    let text = """
    Usage:
      privateheaderkit-install [--bindir path] [--prefix path] [--dry-run]

    Options:
      --bindir path   Install to this directory (overrides --prefix)
      --prefix path   Install to <prefix>/bin (default: ~/.local)
      --dry-run       Print actions without copying files
      -h, --help      Show this help

    Examples:
      swift run -c release privateheaderkit-install
      swift run -c release privateheaderkit-install --bindir "$HOME/bin"
    """
    print(text)
}

private func parseOptions(_ args: [String], environment: [String: String]) throws -> InstallOptions {
    var options = InstallOptions(prefix: nil, bindir: nil, dryRun: false)
    options.prefix = environment["PREFIX"]
    options.bindir = environment["BINDIR"]

    var index = 1
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--prefix":
            guard index + 1 < args.count else {
                throw InstallError.message("--prefix requires a value")
            }
            options.prefix = args[index + 1]
            index += 2
        case "--bindir":
            guard index + 1 < args.count else {
                throw InstallError.message("--bindir requires a value")
            }
            options.bindir = args[index + 1]
            index += 2
        case "--dry-run":
            options.dryRun = true
            index += 1
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            throw InstallError.message("unknown option: \(arg)")
        }
    }
    return options
}

private func resolveBinDir(prefix: String?, bindir: String?) -> URL {
    if let bindir {
        return URL(fileURLWithPath: PathUtils.expandTilde(bindir), isDirectory: true)
    }
    let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
    let expandedPrefix = PathUtils.expandTilde(defaultPrefix)
    return URL(fileURLWithPath: expandedPrefix, isDirectory: true)
        .appendingPathComponent("bin", isDirectory: true)
}

private func logError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

private func repositoryRoot(from executableURL: URL) -> URL? {
    var current = executableURL
    while current.path != "/" {
        if current.lastPathComponent == ".build" {
            return current.deletingLastPathComponent()
        }
        current.deleteLastPathComponent()
    }
    return nil
}

private func looksLikePrivateHeaderKitRepo(_ repoRoot: URL, fileManager: FileManager) -> Bool {
    // Avoid accidentally treating some other Swift package as this repository.
    let markers = [
        repoRoot.appendingPathComponent("Sources/HeaderDumpCore/HeaderDumpMain.swift"),
        repoRoot.appendingPathComponent("Sources/HeaderDumpCLI/HeaderDumpMain.swift"),
    ]
    return markers.allSatisfy { fileManager.fileExists(atPath: $0.path) }
}

private func buildProducts(_ products: [String], in directory: URL, runner: CommandRunning) throws {
    for product in products {
        try runner.runSimple(["swift", "build", "-c", "release", "--product", product], env: nil, cwd: directory)
    }
}

private func resolveSwiftBinDir(repoRoot: URL, runner: CommandRunning) -> URL? {
    // `swift build --show-bin-path` prints a single path line, but be defensive and pick the last non-empty line.
    guard let output = try? runner.runCapture(["swift", "build", "-c", "release", "--show-bin-path"], env: nil, cwd: repoRoot) else {
        return nil
    }
    let path = output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .reversed()
        .first(where: { !$0.isEmpty }) ?? ""
    guard !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func resolveXcodeScheme(repoRoot: URL, runner: CommandRunning) throws -> String {
    struct ListOutput: Decodable {
        struct Workspace: Decodable {
            let schemes: [String]?
        }
        let workspace: Workspace?
    }

    let output = try runner.runCapture(["xcodebuild", "-list", "-json"], env: nil, cwd: repoRoot)
    // Some Xcode versions can emit extra non-JSON logging. Be defensive and parse the JSON region.
    let jsonText: String
    if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") {
        jsonText = String(output[start...end])
    } else {
        jsonText = output
    }

    let decoded = try JSONDecoder().decode(ListOutput.self, from: Data(jsonText.utf8))
    let schemes = decoded.workspace?.schemes ?? []

    let configuredRaw = ProcessInfo.processInfo.environment["PH_XCODE_SCHEME"]
    let configured = configuredRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let configured, !configured.isEmpty {
        if schemes.isEmpty || schemes.contains(configured) {
            return configured
        }
        logError("warning: PH_XCODE_SCHEME=\(configured) not found; falling back")
    }

    // Prefer a scheme that builds the `headerdump` executable.
    let preferred = ["headerdump", "PrivateHeaderKit-Package", "PrivateHeaderKit"]
    for candidate in preferred where schemes.contains(candidate) {
        return candidate
    }

    if let first = schemes.first {
        logError("warning: could not find preferred scheme; falling back to '\(first)'")
        return first
    }

    throw InstallError.message("no xcodebuild schemes found (run `xcodebuild -list` from the repo root)")
}

private func buildHeaderdumpSim(repoRoot: URL, runner: CommandRunning) throws -> URL? {
    // If no simulator runtimes exist, skip building the simulator binary.
    let runtimes = (try? Simctl.listRuntimes(runner: runner)) ?? []
    guard let runtime = runtimes.last else {
        logError("warning: no available iOS runtimes found; skipping headerdump-sim build")
        return nil
    }

    var devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
    if devices.isEmpty {
        try Simctl.createDefaultDevice(runtimeId: runtime.identifier, version: runtime.version, runner: runner)
        devices = try Simctl.listDevices(runtimeId: runtime.identifier, runner: runner)
    }
    guard !devices.isEmpty else {
        throw InstallError.message("no simulator device available for headerdump-sim build")
    }

    let device = try Simctl.pickDefaultDevice(devices: devices)
    let scheme = try resolveXcodeScheme(repoRoot: repoRoot, runner: runner)
    let derivedData = repoRoot
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("DerivedDataInstall", isDirectory: true)

    print("Building headerdump for iOS Simulator (xcodebuild)...")
    try runner.runSimple(
        [
            "xcodebuild",
            "-scheme", scheme,
            "-configuration", "Release",
            "-destination", "id=\(device.udid)",
            "-derivedDataPath", derivedData.path,
            "-skipMacroValidation",
            "-skipPackagePluginValidation",
        ],
        env: nil,
        cwd: repoRoot
    )

    let binPath = derivedData
        .appendingPathComponent("Build", isDirectory: true)
        .appendingPathComponent("Products", isDirectory: true)
        .appendingPathComponent("Release-iphonesimulator", isDirectory: true)
        .appendingPathComponent("headerdump", isDirectory: false)

    guard FileManager.default.fileExists(atPath: binPath.path) else {
        throw InstallError.message("headerdump simulator build output not found")
    }
    return binPath
}

private func install(options: InstallOptions) throws {
    guard let selfURL = Bundle.main.executableURL else {
        throw InstallError.message("failed to locate installer executable")
    }
    let baseURL = selfURL.deletingLastPathComponent()
    let fileManager = FileManager.default

    let binDir = resolveBinDir(prefix: options.prefix, bindir: options.bindir)

    // Host products are built by SwiftPM and placed next to the installer under `.build/release`.
    let hostBinaries = ["privateheaderkit-dump", "headerdump"]
    let installedBinaries = hostBinaries + ["headerdump-sim"]

    if options.dryRun {
        print("Would create: \(binDir.path)")
        for name in installedBinaries {
            print("Would install: \(binDir.appendingPathComponent(name).path)")
        }
        return
    }

    try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)

    let runner = ProcessRunner()
    let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let repoRootFromSelf = repositoryRoot(from: selfURL)
    let repoRootFromCwd = PathUtils.findRepositoryRoot(startingAt: cwdURL)
    let repoRoot: URL?
    if let root = repoRootFromSelf, looksLikePrivateHeaderKitRepo(root, fileManager: fileManager) {
        repoRoot = root
    } else if let root = repoRootFromCwd, looksLikePrivateHeaderKitRepo(root, fileManager: fileManager) {
        repoRoot = root
    } else {
        // If invoked from some other package's directory, skip building and install from existing binaries.
        if repoRootFromCwd != nil {
            logError("warning: ignoring Package.swift found in current directory (not PrivateHeaderKit)")
        }
        repoRoot = nil
    }

    if let repoRoot {
        // Always build installed products when possible, so users get the latest binaries after pulling updates.
        do {
            try buildProducts(hostBinaries, in: repoRoot, runner: runner)
        } catch {
            logError("warning: swift build failed: \(error)")
        }
    }

    // Build everything first, then copy, so failures don't leave a partial install.
    let simBinaryURL: URL?
    if let repoRoot {
        do {
            simBinaryURL = try buildHeaderdumpSim(repoRoot: repoRoot, runner: runner)
        } catch {
            // Allow installing host binaries even if xcodebuild/simctl fails.
            logError("warning: failed to build headerdump-sim: \(error)")
            simBinaryURL = nil
        }
    } else {
        logError("warning: repository root not found; skipping headerdump-sim build")
        simBinaryURL = nil
    }

    let hostBinaryDir: URL
    if let repoRoot {
        hostBinaryDir = resolveSwiftBinDir(repoRoot: repoRoot, runner: runner) ?? baseURL
    } else {
        hostBinaryDir = baseURL
    }

    for name in hostBinaries {
        let sourceURL = hostBinaryDir.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw InstallError.message("\(name) not found next to installer (run with `swift run -c release` from the repo root)")
        }
        let destinationURL = binDir.appendingPathComponent(name)
        if sourceURL.resolvingSymlinksInPath().path == destinationURL.resolvingSymlinksInPath().path {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
            print("Already installed \(name) at \(destinationURL.path)")
            continue
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        print("Installed \(name) to \(destinationURL.path)")
    }

    if let simBinaryURL {
        let destinationURL = binDir.appendingPathComponent("headerdump-sim")
        if simBinaryURL.resolvingSymlinksInPath().path == destinationURL.resolvingSymlinksInPath().path {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
            print("Already installed headerdump-sim at \(destinationURL.path)")
            return
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: simBinaryURL, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        print("Installed headerdump-sim to \(destinationURL.path)")
    }
}

#else

@main
struct PrivateHeaderKitInstallMain {
    static func main() {
        fputs("privateheaderkit-install: unsupported on this platform\n", stderr)
        exit(1)
    }
}

#endif
