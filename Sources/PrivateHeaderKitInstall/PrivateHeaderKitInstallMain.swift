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
      --prefix path   Install to <prefix>/bin (default: ~/.local)
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

func resolveSwiftBinDir(repoRoot: URL, runner: CommandRunning) -> URL? {
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

private func install(options: InstallOptions) throws {
    guard let selfURL = Bundle.main.executableURL else {
        throw InstallError.message("failed to locate installer executable")
    }
    let baseURL = selfURL.deletingLastPathComponent()
    let fileManager = FileManager.default

    let binDir = resolveBinDir(prefix: options.prefix, bindir: options.bindir)

    // The rewrite exposes a single user-facing command. Low-level dump helpers stay internal.
    let installedBinaries = ["privateheaderkit"]

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
        // Always build the installed product when possible, so users get the latest binary after pulling updates.
        do {
            try buildProducts(installedBinaries, in: repoRoot, runner: runner)
        } catch {
            logError("warning: swift build failed: \(error)")
        }
    }

    let hostBinaryDir: URL
    if let repoRoot {
        hostBinaryDir = resolveSwiftBinDir(repoRoot: repoRoot, runner: runner) ?? baseURL
    } else {
        hostBinaryDir = baseURL
    }

    for name in installedBinaries {
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
