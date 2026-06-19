import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(macOS)

struct InstallOptions {
    var prefix: String?
    var bindir: String?
    var dryRun: Bool
}

struct InstallLayout: Equatable {
    let prefix: URL
    let binDir: URL
    let libexecDir: URL

    var publicCommandURL: URL {
        binDir.appendingPathComponent(InstallConstants.publicCommandName, isDirectory: false)
    }

    var simulatorHelperURL: URL {
        libexecDir.appendingPathComponent(InstallConstants.simulatorHelperInstallName, isDirectory: false)
    }
}

enum InstallConstants {
    static let publicCommandName = "privateheaderkit"
    static let simulatorHelperInstallName = "privateheaderkit-sim-helper"
    static let simulatorHelperBuildProductName = "privateheaderkit-sim-helper"
}

enum InstallError: Error, CustomStringConvertible {
    case message(String)
    case helpRequested

    var description: String {
        switch self {
        case .message(let text):
            return text
        case .helpRequested:
            return "help requested"
        }
    }
}

public func runInstallCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int32 {
    do {
        let options = try parseOptions(args, environment: environment)
        try install(options: options)
        return 0
    } catch InstallError.helpRequested {
        printInstallUsage()
        return 0
    } catch let error as InstallError {
        logError("error: \(error.description)")
        logError("run `privateheaderkit install --help` for usage")
        return 1
    } catch {
        logError("error: \(error)")
        logError("run `privateheaderkit install --help` for usage")
        return 1
    }
}

func printInstallUsage() {
    let text = """
    Usage:
      privateheaderkit install [--bindir path] [--prefix path] [--dry-run]

    Options:
      --bindir path   Install to this directory (overrides --prefix)
      --prefix path   Install to <prefix>/bin and <prefix>/libexec/privateheaderkit (default: ~/.local)
      --dry-run       Print actions without copying files
      -h, --help      Show this help

    Examples:
      swift run -c release privateheaderkit install
      swift run -c release privateheaderkit install --bindir "$HOME/bin"
    """
    print(text)
}

func parseOptions(_ args: [String], environment: [String: String]) throws -> InstallOptions {
    var options = InstallOptions(prefix: nil, bindir: nil, dryRun: false)
    if let envPrefix = environment["PREFIX"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !envPrefix.isEmpty {
        options.prefix = envPrefix
    }
    if let envBindir = environment["BINDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !envBindir.isEmpty {
        options.bindir = envBindir
    }

    var didSetPrefix = false
    var didSetBindir = false

    var index = 1
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--prefix":
            guard index + 1 < args.count else {
                throw InstallError.message("--prefix requires a value")
            }
            let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw InstallError.message("--prefix requires a value")
            }
            options.prefix = value
            didSetPrefix = true
            index += 2
        case "--bindir":
            guard index + 1 < args.count else {
                throw InstallError.message("--bindir requires a value")
            }
            let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw InstallError.message("--bindir requires a value")
            }
            options.bindir = value
            didSetBindir = true
            index += 2
        case "--dry-run":
            options.dryRun = true
            index += 1
        case "-h", "--help":
            throw InstallError.helpRequested
        default:
            throw InstallError.message("unknown option: \(arg)")
        }
    }

    // Treat BINDIR as a default only. If the user explicitly set --prefix, use it unless --bindir was also set.
    if didSetPrefix, !didSetBindir {
        options.bindir = nil
    }
    return options
}

func resolveBinDir(prefix: String?, bindir: String?) -> URL {
    resolveInstallLayout(prefix: prefix, bindir: bindir).binDir
}

func resolveInstallLayout(prefix: String?, bindir: String?) -> InstallLayout {
    let resolvedPrefix = resolveInstallPrefix(prefix: prefix, bindir: bindir)
    let binDir: URL
    if let bindir {
        binDir = URL(fileURLWithPath: PathUtils.expandTilde(bindir), isDirectory: true)
    } else {
        binDir = resolvedPrefix.appendingPathComponent("bin", isDirectory: true)
    }
    let libexecDir = resolvedPrefix
        .appendingPathComponent("libexec", isDirectory: true)
        .appendingPathComponent("privateheaderkit", isDirectory: true)
    return InstallLayout(prefix: resolvedPrefix, binDir: binDir, libexecDir: libexecDir)
}

private func resolveInstallPrefix(prefix: String?, bindir: String?) -> URL {
    if let bindir {
        let binDir = URL(fileURLWithPath: PathUtils.expandTilde(bindir), isDirectory: true)
        return binDir.deletingLastPathComponent()
    }
    let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
    return URL(fileURLWithPath: PathUtils.expandTilde(defaultPrefix), isDirectory: true)
}

private func logError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

func repositoryRoot(from executableURL: URL) -> URL? {
    var current = executableURL
    while current.path != "/" {
        if current.lastPathComponent == ".build" {
            return current.deletingLastPathComponent()
        }
        current.deleteLastPathComponent()
    }
    return nil
}

func looksLikePrivateHeaderKitRepo(_ repoRoot: URL, fileManager: FileManager) -> Bool {
    // Avoid accidentally treating some other Swift package as this repository.
    let markers = [
        repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCore/PrivateHeaderGeneration.swift"),
        repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCLI/PrivateHeaderKitMain.swift"),
    ]
    return markers.allSatisfy { fileManager.fileExists(atPath: $0.path) }
}

func buildProducts(_ products: [String], in directory: URL, runner: CommandRunning) throws {
    for product in products {
        try runner.runSimple(["swift", "build", "-c", "release", "--product", product], env: nil, cwd: directory)
    }
}

func currentProcessArchitectureName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

func defaultSimulatorHelperTriple(
    processArchitecture: String = currentProcessArchitectureName()
) throws -> String {
    switch processArchitecture {
    case "arm64", "x86_64":
        "\(processArchitecture)-apple-ios-simulator"
    default:
        throw InstallError.message("unsupported host architecture for iOS simulator helper: \(processArchitecture)")
    }
}

func buildSimulatorHelper(
    in directory: URL,
    runner: CommandRunning,
    simulatorHelperTriple: String? = nil
) throws {
    let sdkPath = try resolveSimulatorSDKPath(runner: runner)
    try buildSimulatorHelper(
        in: directory,
        sdkPath: sdkPath,
        runner: runner,
        simulatorHelperTriple: simulatorHelperTriple
    )
}

func buildSimulatorHelper(
    in directory: URL,
    sdkPath: String,
    runner: CommandRunning,
    simulatorHelperTriple: String? = nil
) throws {
    let triple: String
    if let simulatorHelperTriple {
        triple = simulatorHelperTriple
    } else {
        triple = try defaultSimulatorHelperTriple()
    }
    try runner.runSimple(
        [
            "swift",
            "build",
            "-c",
            "release",
            "--sdk",
            sdkPath,
            "--triple",
            triple,
            "--product",
            InstallConstants.simulatorHelperBuildProductName,
        ],
        env: nil,
        cwd: directory
    )
}

func resolveSimulatorSDKPath(runner: CommandRunning) throws -> String {
    let output = try runner.runCapture(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
        env: nil,
        cwd: nil
    )
    let path = output
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .reversed()
        .first(where: { !$0.isEmpty }) ?? ""
    guard !path.isEmpty else {
        throw InstallError.message("failed to resolve iPhone Simulator SDK path")
    }
    return path
}

func resolveSwiftBinDir(
    repoRoot: URL,
    runner: CommandRunning,
    triple: String? = nil,
    sdkPath: String? = nil,
    env: [String: String]? = nil
) -> URL? {
    // `swift build --show-bin-path` prints a single path line, but be defensive and pick the last non-empty line.
    var command = ["swift", "build", "-c", "release"]
    if let sdkPath {
        command += ["--sdk", sdkPath]
    }
    if let triple {
        command += ["--triple", triple]
    }
    command.append("--show-bin-path")
    guard let output = try? runner.runCapture(command, env: env, cwd: repoRoot) else {
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

private func install(options: InstallOptions) throws {
    guard let selfURL = Bundle.main.executableURL else {
        throw InstallError.message("failed to locate installer executable")
    }
    try install(
        options: options,
        selfURL: selfURL,
        currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        runner: ProcessRunner(),
        fileManager: .default,
        outputLogger: { print($0) },
        errorLogger: logError
    )
}

func install(
    options: InstallOptions,
    selfURL: URL,
    currentDirectoryURL: URL,
    runner: CommandRunning,
    fileManager: FileManager,
    outputLogger: (String) -> Void,
    errorLogger: (String) -> Void,
    simulatorHelperTriple: String? = nil
) throws {
    let baseURL = selfURL.deletingLastPathComponent()

    let layout = resolveInstallLayout(prefix: options.prefix, bindir: options.bindir)

    if options.dryRun {
        for line in dryRunInstallMessages(layout: layout) {
            outputLogger(line)
        }
        return
    }

    try fileManager.createDirectory(at: layout.binDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: layout.libexecDir, withIntermediateDirectories: true)

    let repoRootFromSelf = repositoryRoot(from: selfURL)
    let repoRootFromCwd = PathUtils.findRepositoryRoot(startingAt: currentDirectoryURL)
    let repoRoot: URL?
    if let root = repoRootFromSelf, looksLikePrivateHeaderKitRepo(root, fileManager: fileManager) {
        repoRoot = root
    } else if let root = repoRootFromCwd, looksLikePrivateHeaderKitRepo(root, fileManager: fileManager) {
        repoRoot = root
    } else {
        // If invoked from some other package's directory, skip building and install from existing binaries.
        if repoRootFromCwd != nil {
            errorLogger("warning: ignoring Package.swift found in current directory (not PrivateHeaderKit)")
        }
        repoRoot = nil
    }

    var simulatorSDKPath: String?
    let resolvedSimulatorHelperTriple: String?
    if let repoRoot {
        let triple: String
        if let simulatorHelperTriple {
            triple = simulatorHelperTriple
        } else {
            triple = try defaultSimulatorHelperTriple()
        }
        resolvedSimulatorHelperTriple = triple
        // Always build install artifacts when possible, so users get the latest binaries after pulling updates.
        do {
            try buildProducts([InstallConstants.publicCommandName], in: repoRoot, runner: runner)
            let sdkPath = try resolveSimulatorSDKPath(runner: runner)
            simulatorSDKPath = sdkPath
            try buildSimulatorHelper(
                in: repoRoot,
                sdkPath: sdkPath,
                runner: runner,
                simulatorHelperTriple: triple
            )
        } catch {
            errorLogger("warning: swift build failed: \(error)")
        }
    } else {
        resolvedSimulatorHelperTriple = nil
    }

    let hostBinaryDir: URL
    if let repoRoot {
        hostBinaryDir = resolveSwiftBinDir(repoRoot: repoRoot, runner: runner) ?? baseURL
    } else {
        hostBinaryDir = baseURL
    }

    let simulatorHelperSourceURL: URL
    if let repoRoot {
        let sdkPath = simulatorSDKPath ?? (try? resolveSimulatorSDKPath(runner: runner))
        let simulatorBinaryDir = resolveSwiftBinDir(
            repoRoot: repoRoot,
            runner: runner,
            triple: resolvedSimulatorHelperTriple,
            sdkPath: sdkPath
        ) ?? baseURL
        simulatorHelperSourceURL = simulatorBinaryDir.appendingPathComponent(
            InstallConstants.simulatorHelperBuildProductName,
            isDirectory: false
        )
    } else {
        simulatorHelperSourceURL = defaultInstalledSimulatorHelperURL(for: selfURL)
    }

    try installExecutableFile(
        sourceURL: hostBinaryDir.appendingPathComponent(InstallConstants.publicCommandName, isDirectory: false),
        destinationURL: layout.publicCommandURL,
        displayName: InstallConstants.publicCommandName,
        missingMessage: "\(InstallConstants.publicCommandName) not found next to installer (run with `swift run -c release` from the repo root)",
        fileManager: fileManager,
        outputLogger: outputLogger
    )
    try installExecutableFile(
        sourceURL: simulatorHelperSourceURL,
        destinationURL: layout.simulatorHelperURL,
        displayName: InstallConstants.simulatorHelperInstallName,
        missingMessage: "\(InstallConstants.simulatorHelperInstallName) not found (run install from the repo root so SwiftPM can build the iOS simulator helper)",
        fileManager: fileManager,
        outputLogger: outputLogger
    )
}

func dryRunInstallMessages(layout: InstallLayout) -> [String] {
    [
        "Would create: \(layout.binDir.path)",
        "Would create: \(layout.libexecDir.path)",
        "Would install: \(layout.publicCommandURL.path)",
        "Would install internal helper: \(layout.simulatorHelperURL.path)",
    ]
}

func defaultInstalledSimulatorHelperURL(for executableURL: URL) -> URL {
    let binDir = executableURL.deletingLastPathComponent()
    if binDir.lastPathComponent == "bin" {
        return binDir
            .deletingLastPathComponent()
            .appendingPathComponent("libexec/privateheaderkit/privateheaderkit-sim-helper", isDirectory: false)
    }
    return binDir.appendingPathComponent("privateheaderkit-sim-helper", isDirectory: false)
}

private func installExecutableFile(
    sourceURL: URL,
    destinationURL: URL,
    displayName: String,
    missingMessage: String,
    fileManager: FileManager,
    outputLogger: (String) -> Void
) throws {
    guard fileManager.fileExists(atPath: sourceURL.path) else {
        throw InstallError.message(missingMessage)
    }
    if sourceURL.resolvingSymlinksInPath().path == destinationURL.resolvingSymlinksInPath().path {
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        outputLogger("Already installed \(displayName) at \(destinationURL.path)")
        return
    }
    if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
    outputLogger("Installed \(displayName) to \(destinationURL.path)")
}

#else

public func runInstallCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int32 {
    fputs("privateheaderkit install: unsupported on this platform\n", stderr)
    return 1
}

#endif
