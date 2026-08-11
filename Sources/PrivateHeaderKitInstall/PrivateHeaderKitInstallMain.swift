import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct InstallOptions: Equatable {
    var prefix: String?
    var bindir: String?
    var dryRun: Bool
    var buildConfiguration: BuildConfiguration?
    var releaseDirectory: String?
    var expectedReleaseVersion: String?
    var expectedReleaseCommit: String?
}

struct CreateReleaseManifestOptions: Equatable {
    let artifactDirectory: String
    let version: String
    let commit: String
    let output: String
}

enum InstallerCommand: Equatable {
    case install(InstallOptions)
    case createReleaseManifest(CreateReleaseManifestOptions)
}

enum BuildConfiguration: String, Equatable {
    case debug
    case release

    var swiftBuildValue: String { rawValue }
}

enum InstallError: Error, CustomStringConvertible {
    case message(String)
    case helpRequested

    var description: String {
        switch self {
        case .message(let text):
            text
        case .helpRequested:
            "help requested"
        }
    }
}

#if os(macOS)

package func runInstallCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int32 {
    do {
        let command = try parseInstallerCommand(args, environment: environment)
        let runner = ProcessRunner()
        let inspector = LiveReleaseArtifactInspector(
            runner: runner,
            fileManager: .default
        )
        switch command {
        case .install(let options):
            try runInstall(
                options: options,
                currentExecutableURL: Bundle.main.executableURL,
                currentDirectoryURL: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true
                ),
                environment: environment,
                runner: runner,
                fileManager: .default,
                inspectArtifact: inspector.inspect,
                outputLogger: { print($0) }
            )
        case .createReleaseManifest(let options):
            try createReleaseManifest(
                options: options,
                fileManager: .default,
                inspectArtifact: inspector.inspect
            )
        }
        return 0
    } catch InstallError.helpRequested {
        printInstallUsage()
        return 0
    } catch let error as InstallError {
        logInstallError("error: \(error.description)")
        logInstallError("run `privateheaderkit-install --help` for usage")
        return 1
    } catch {
        logInstallError("error: \(error)")
        logInstallError("run `privateheaderkit-install --help` for usage")
        return 1
    }
}

func printInstallUsage() {
    print(
        """
        Usage:
          privateheaderkit-install [--prefix path] [--bindir path] [--configuration debug|release] [--dry-run]

        Options:
          --prefix path       Install to <prefix>/bin and <prefix>/libexec/privateheaderkit
                              (default: ~/.local)
          --bindir path       Install the stable command symlink in this directory;
                              the prefix is its parent directory
          --configuration     Build source artifacts with debug or release (default: release)
          --dry-run           Print the version-cohort layout without building or changing files
          -h, --help          Show this help

        Source install:
          swift run -c release privateheaderkit-install

        Release install is performed by the version-baked install.sh asset.
        """
    )
}

func parseInstallerCommand(
    _ args: [String],
    environment: [String: String]
) throws -> InstallerCommand {
    if args.dropFirst().contains("--create-release-manifest") {
        return .createReleaseManifest(
            try parseCreateReleaseManifestOptions(args)
        )
    }
    return .install(try parseOptions(args, environment: environment))
}

func parseOptions(
    _ args: [String],
    environment: [String: String]
) throws -> InstallOptions {
    var options = InstallOptions(
        prefix: nonEmpty(environment["PREFIX"]),
        bindir: nonEmpty(environment["BINDIR"]),
        dryRun: false,
        buildConfiguration: nil,
        releaseDirectory: nil,
        expectedReleaseVersion: nil,
        expectedReleaseCommit: nil
    )
    var didSetBindir = false
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--prefix":
            options.prefix = try requiredValue(after: args[index], in: args, index: &index)
            if !didSetBindir {
                options.bindir = nil
            }
        case "--bindir":
            options.bindir = try requiredValue(after: args[index], in: args, index: &index)
            didSetBindir = true
        case "--configuration":
            let rawValue = try requiredValue(after: args[index], in: args, index: &index)
            guard let configuration = BuildConfiguration(rawValue: rawValue) else {
                throw InstallError.message(
                    "--configuration must be `debug` or `release`"
                )
            }
            options.buildConfiguration = configuration
        case "--release-dir":
            options.releaseDirectory = try requiredValue(
                after: args[index],
                in: args,
                index: &index
            )
        case "--expected-version":
            options.expectedReleaseVersion = try requiredValue(
                after: args[index],
                in: args,
                index: &index
            )
        case "--expected-commit":
            options.expectedReleaseCommit = try requiredValue(
                after: args[index],
                in: args,
                index: &index
            )
        case "--dry-run":
            options.dryRun = true
        case "-h", "--help":
            throw InstallError.helpRequested
        default:
            throw InstallError.message("unknown option: \(args[index])")
        }
        index += 1
    }
    if options.releaseDirectory != nil {
        guard options.expectedReleaseVersion != nil,
              options.expectedReleaseCommit != nil
        else {
            throw InstallError.message(
                "prebuilt release installation requires its baked version and commit binding"
            )
        }
    } else if options.expectedReleaseVersion != nil
        || options.expectedReleaseCommit != nil
    {
        throw InstallError.message(
            "release version and commit binding require --release-dir"
        )
    }
    return options
}

func parseCreateReleaseManifestOptions(
    _ args: [String]
) throws -> CreateReleaseManifestOptions {
    var artifactDirectory: String?
    var version: String?
    var commit: String?
    var output: String?
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--create-release-manifest":
            break
        case "--artifact-dir":
            artifactDirectory = try requiredValue(
                after: args[index],
                in: args,
                index: &index
            )
        case "--version":
            version = try requiredValue(after: args[index], in: args, index: &index)
        case "--commit":
            commit = try requiredValue(after: args[index], in: args, index: &index)
        case "--output":
            output = try requiredValue(after: args[index], in: args, index: &index)
        case "-h", "--help":
            throw InstallError.helpRequested
        default:
            throw InstallError.message(
                "unknown release manifest option: \(args[index])"
            )
        }
        index += 1
    }
    guard let artifactDirectory, let version, let commit, let output else {
        throw InstallError.message(
            "--create-release-manifest requires --artifact-dir, --version, --commit, and --output"
        )
    }
    return CreateReleaseManifestOptions(
        artifactDirectory: artifactDirectory,
        version: version,
        commit: commit,
        output: output
    )
}

func runInstall(
    options: InstallOptions,
    currentExecutableURL: URL?,
    currentDirectoryURL: URL,
    environment: [String: String],
    runner: CommandRunning,
    fileManager: FileManager,
    inspectArtifact: @escaping ReleaseArtifactInspector,
    faultInjector: @escaping InstallFaultInjector = { _ in },
    outputLogger: @escaping (String) -> Void,
    simulatorHelperTriple: String? = nil
) throws {
    let layout = try resolveInstallLayout(
        prefix: options.prefix,
        bindir: options.bindir,
        fileManager: fileManager
    )
    if options.dryRun {
        dryRunInstallMessages(layout: layout).forEach(outputLogger)
        return
    }

    let installer = VersionCohortInstaller(
        layout: layout,
        fileManager: fileManager,
        inspectArtifact: inspectArtifact,
        faultInjector: faultInjector,
        outputLogger: outputLogger
    )
    try installer.withInstallLock {
        let cohort: ReleaseCohort
        if let releaseDirectory = options.releaseDirectory {
            cohort = try ReleaseCohort.read(
                from: URL(
                    fileURLWithPath: PathUtils.expandTilde(releaseDirectory),
                    isDirectory: true
                ),
                fileManager: fileManager
            )
            guard cohort.manifest.version == options.expectedReleaseVersion,
                  cohort.manifest.commit.lowercased()
                    == options.expectedReleaseCommit?.lowercased()
            else {
                throw InstallError.message(
                    "release manifest does not match the version and commit baked into the installer"
                )
            }
        } else {
            guard let repoRoot = resolveRepositoryRoot(
                currentExecutableURL: currentExecutableURL,
                currentDirectoryURL: currentDirectoryURL,
                fileManager: fileManager
            ) else {
                throw InstallError.message(
                    "source installation must run from a PrivateHeaderKit checkout; use the release install.sh for prebuilt artifacts"
                )
            }
            cohort = try buildSourceCohort(
                repoRoot: repoRoot,
                configuration: options.buildConfiguration ?? .release,
                environment: environment,
                runner: runner,
                fileManager: fileManager,
                inspectArtifact: inspectArtifact,
                simulatorHelperTriple: simulatorHelperTriple
            )
        }
        _ = try installer.installLocked(cohort)
    }
}

func createReleaseManifest(
    options: CreateReleaseManifestOptions,
    fileManager: FileManager,
    inspectArtifact: ReleaseArtifactInspector
) throws {
    let artifactDirectory = URL(
        fileURLWithPath: options.artifactDirectory,
        isDirectory: true
    )
    let artifactURLs = Dictionary(
        uniqueKeysWithValues: InstallArtifactName.allCases.map { artifact in
            (
                artifact,
                artifactDirectory.appendingPathComponent(
                    artifact.rawValue,
                    isDirectory: false
                )
            )
        }
    )
    let manifest = try makeReleaseManifest(
        version: options.version,
        commit: options.commit,
        artifactURLs: artifactURLs,
        inspectArtifact: inspectArtifact
    )
    let outputURL = URL(fileURLWithPath: options.output, isDirectory: false)
    try fileManager.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try manifest.encoded().write(to: outputURL, options: [.atomic])
}

func makeReleaseManifest(
    version: String,
    commit: String,
    artifactURLs: [InstallArtifactName: URL],
    inspectArtifact: ReleaseArtifactInspector
) throws -> ReleaseManifest {
    let records = try InstallArtifactName.allCases.map { artifact in
        guard let url = artifactURLs[artifact] else {
            throw InstallError.message(
                "missing release artifact: \(artifact.rawValue)"
            )
        }
        let inspection = try inspectArtifact(artifact, url)
        return ReleaseArtifactRecord(
            name: artifact,
            sha256: inspection.sha256,
            architectures: inspection.architectures.sorted(),
            platform: inspection.platform,
            codeSignaturePolicy: .valid
        )
    }
    return try ReleaseManifest(
        version: version,
        commit: commit,
        artifacts: records
    )
}

func buildSourceCohort(
    repoRoot: URL,
    configuration: BuildConfiguration,
    environment: [String: String],
    runner: CommandRunning,
    fileManager: FileManager,
    inspectArtifact: ReleaseArtifactInspector,
    simulatorHelperTriple: String? = nil
) throws -> ReleaseCohort {
    let sourceBeforeBuild = try captureSourceSnapshot(
        repoRoot: repoRoot,
        environment: environment,
        runner: runner,
        fileManager: fileManager
    )
    try buildProducts(
        [
            InstallArtifactName.publicCommand.rawValue,
            InstallArtifactName.rawDumpHelper.rawValue,
        ],
        configuration: configuration,
        in: repoRoot,
        runner: runner
    )
    let simulatorSDKPath = try resolveSimulatorSDKPath(runner: runner)
    let simulatorTriple = try simulatorHelperTriple ?? defaultSimulatorHelperTriple()
    let simulatorScratchPath = SwiftPMBuildPaths.simulatorScratchURL(
        repoRoot: repoRoot,
        triple: simulatorTriple
    )
    try buildSimulatorHelper(
        in: repoRoot,
        configuration: configuration,
        scratchPath: simulatorScratchPath,
        sdkPath: simulatorSDKPath,
        runner: runner,
        simulatorHelperTriple: simulatorTriple
    )

    let hostBinDirectory = try resolveSwiftBinDir(
        repoRoot: repoRoot,
        runner: runner,
        configuration: configuration
    )
    let simulatorBinDirectory = try resolveSwiftBinDir(
        repoRoot: repoRoot,
        runner: runner,
        configuration: configuration,
        scratchPath: simulatorScratchPath,
        triple: simulatorTriple,
        sdkPath: simulatorSDKPath
    )
    let artifactURLs: [InstallArtifactName: URL] = [
        .publicCommand: hostBinDirectory.appendingPathComponent(
            InstallArtifactName.publicCommand.rawValue,
            isDirectory: false
        ),
        .rawDumpHelper: hostBinDirectory.appendingPathComponent(
            InstallArtifactName.rawDumpHelper.rawValue,
            isDirectory: false
        ),
        .simulatorHelper: simulatorBinDirectory.appendingPathComponent(
            InstallArtifactName.simulatorHelper.rawValue,
            isDirectory: false
        ),
    ]
    for (artifact, url) in artifactURLs {
        guard fileManager.fileExists(atPath: url.path) else {
            throw InstallError.message(
                "built artifact is missing: \(artifact.rawValue) at \(url.path)"
            )
        }
    }

    let sourceAfterBuild = try captureSourceSnapshot(
        repoRoot: repoRoot,
        environment: environment,
        runner: runner,
        fileManager: fileManager
    )
    guard sourceAfterBuild == sourceBeforeBuild else {
        throw InstallError.message(
            "source checkout changed while building the install cohort; refusing mixed-source artifacts"
        )
    }
    let manifest = try makeReleaseManifest(
        version: sourceBeforeBuild.effectiveVersion,
        commit: sourceBeforeBuild.effectiveCommit,
        artifactURLs: artifactURLs,
        inspectArtifact: inspectArtifact
    )
    return try ReleaseCohort(
        manifest: manifest,
        artifactURLs: artifactURLs
    )
}

func buildProducts(
    _ products: [String],
    configuration: BuildConfiguration,
    in directory: URL,
    runner: CommandRunning
) throws {
    for product in products {
        try runner.runSimple(
            [
                "swift",
                "build",
                "-c",
                configuration.swiftBuildValue,
                "--product",
                product,
            ],
            env: nil,
            cwd: directory
        )
    }
}

func buildSimulatorHelper(
    in directory: URL,
    configuration: BuildConfiguration,
    scratchPath: URL,
    sdkPath: String,
    runner: CommandRunning,
    simulatorHelperTriple: String
) throws {
    try runner.runSimple(
        [
            "swift",
            "build",
            "-c",
            configuration.swiftBuildValue,
            "--scratch-path",
            scratchPath.path,
            "--sdk",
            sdkPath,
            "--triple",
            simulatorHelperTriple,
            "--product",
            InstallArtifactName.simulatorHelper.rawValue,
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
    guard let path = output
        .split(whereSeparator: \Character.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .last(where: { !$0.isEmpty })
    else {
        throw InstallError.message("failed to resolve iPhone Simulator SDK path")
    }
    return path
}

func resolveSwiftBinDir(
    repoRoot: URL,
    runner: CommandRunning,
    configuration: BuildConfiguration,
    scratchPath: URL? = nil,
    triple: String? = nil,
    sdkPath: String? = nil
) throws -> URL {
    var command = ["swift", "build", "-c", configuration.swiftBuildValue]
    if let scratchPath {
        command += ["--scratch-path", scratchPath.path]
    }
    if let sdkPath {
        command += ["--sdk", sdkPath]
    }
    if let triple {
        command += ["--triple", triple]
    }
    command.append("--show-bin-path")
    let output = try runner.runCapture(command, env: nil, cwd: repoRoot)
    guard let path = output
        .split(whereSeparator: \Character.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .last(where: { !$0.isEmpty })
    else {
        throw InstallError.message(
            "swift build --show-bin-path returned no path for \(triple ?? "host")"
        )
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func repositoryRoot(from executableURL: URL) -> URL? {
    var current = executableURL.standardizedFileURL
    while current.path != "/" {
        if current.lastPathComponent == ".build" {
            return current.deletingLastPathComponent()
        }
        current.deleteLastPathComponent()
    }
    return nil
}

func resolveRepositoryRoot(
    currentExecutableURL: URL?,
    currentDirectoryURL: URL,
    fileManager: FileManager
) -> URL? {
    let candidates = [
        currentExecutableURL.flatMap(repositoryRoot(from:)),
        PathUtils.findRepositoryRoot(startingAt: currentDirectoryURL),
    ].compactMap { $0 }
    return candidates.first(where: {
        looksLikePrivateHeaderKitRepo($0, fileManager: fileManager)
    })
}

func looksLikePrivateHeaderKitRepo(
    _ repoRoot: URL,
    fileManager: FileManager
) -> Bool {
    [
        repoRoot.appendingPathComponent("Package.swift", isDirectory: false),
        repoRoot.appendingPathComponent(
            "Sources/PrivateHeaderKitCore/PrivateHeaderGeneration.swift",
            isDirectory: false
        ),
        repoRoot.appendingPathComponent(
            "Sources/PrivateHeaderKitCLI/PrivateHeaderKitMain.swift",
            isDirectory: false
        ),
    ].allSatisfy { fileManager.fileExists(atPath: $0.path) }
}

func currentExecutableArchitectureName() -> String {
#if arch(arm64)
    "arm64"
#elseif arch(x86_64)
    "x86_64"
#else
    "unknown"
#endif
}

func hostSupportsNativeArm64() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        && value != 0
}

func nativeHostSimulatorArchitecture(
    executableArchitecture: String,
    supportsNativeArm64: Bool
) throws -> String {
    if supportsNativeArm64 {
        return "arm64"
    }
    switch executableArchitecture {
    case "arm64", "x86_64":
        return executableArchitecture
    default:
        throw InstallError.message(
            "unsupported host architecture for iOS simulator helper: \(executableArchitecture)"
        )
    }
}

func defaultSimulatorHelperTriple(
    executableArchitecture: String = currentExecutableArchitectureName(),
    supportsNativeArm64: Bool = hostSupportsNativeArm64()
) throws -> String {
    let architecture = try nativeHostSimulatorArchitecture(
        executableArchitecture: executableArchitecture,
        supportsNativeArm64: supportsNativeArm64
    )
    return "\(architecture)-apple-ios-simulator"
}

func dryRunInstallMessages(layout: InstallLayout) -> [String] {
    [
        "Would acquire install lock: \(layout.lockURL.path)",
        "Would stage all three artifacts under: \(layout.versionsDirectory.path)",
        "Would atomically switch: \(layout.currentURL.path)",
        "Would maintain stable command symlink: \(layout.publicCommandURL.path)",
    ]
}

private func requiredValue(
    after option: String,
    in args: [String],
    index: inout Int
) throws -> String {
    guard index + 1 < args.count else {
        throw InstallError.message("\(option) requires a value")
    }
    let value = args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        throw InstallError.message("\(option) requires a non-empty value")
    }
    index += 1
    return value
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
        return nil
    }
    return value
}

private func logInstallError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

#else

package func runInstallCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int32 {
    fputs("privateheaderkit-install: unsupported on this platform\n", stderr)
    return 1
}

#endif
