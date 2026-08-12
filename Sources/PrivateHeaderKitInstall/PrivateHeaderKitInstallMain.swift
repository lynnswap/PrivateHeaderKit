import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package struct InstallOptions: Equatable, Sendable {
    package let prefix: String?
    package let bindir: String?
    package let dryRun: Bool
    package let buildConfiguration: BuildConfiguration?
    package let releaseDirectory: String?
    package let expectedReleaseVersion: String?
    package let expectedReleaseCommit: String?

    package init(
        prefix: String?,
        bindir: String?,
        dryRun: Bool,
        buildConfiguration: BuildConfiguration?,
        releaseDirectory: String?,
        expectedReleaseVersion: String?,
        expectedReleaseCommit: String?
    ) {
        self.prefix = prefix
        self.bindir = bindir
        self.dryRun = dryRun
        self.buildConfiguration = buildConfiguration
        self.releaseDirectory = releaseDirectory
        self.expectedReleaseVersion = expectedReleaseVersion
        self.expectedReleaseCommit = expectedReleaseCommit
    }
}

package struct CreateReleaseManifestOptions: Equatable, Sendable {
    package let artifactDirectory: String
    package let version: String
    package let commit: String
    package let output: String

    package init(
        artifactDirectory: String,
        version: String,
        commit: String,
        output: String
    ) {
        self.artifactDirectory = artifactDirectory
        self.version = version
        self.commit = commit
        self.output = output
    }
}

package enum InstallerCommand: Equatable, Sendable {
    case install(InstallOptions)
    case createReleaseManifest(CreateReleaseManifestOptions)
}

package enum BuildConfiguration: String, Equatable, Sendable {
    case debug
    case release

    var swiftBuildValue: String { rawValue }
}

package enum InstallError: Error, CustomStringConvertible, Sendable {
    case message(String)

    package var description: String {
        switch self {
        case .message(let text):
            text
        }
    }
}

#if os(macOS)

package func executeInstallerCommand(
    _ command: InstallerCommand,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async throws {
    let runner = ProcessRunner()
    let inspector = LiveReleaseArtifactInspector(
        runner: runner,
        checkCancellation: { try Task.checkCancellation() }
    )
    switch command {
    case .install(let options):
        try await runInstall(
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
        try await createReleaseManifest(
            options: options,
            fileManager: .default,
            inspectArtifact: inspector.inspect
        )
    }
}

package func resolveInstallOptions(
    cliPrefix: String?,
    cliBindir: String?,
    dryRun: Bool,
    buildConfiguration: BuildConfiguration?,
    releaseDirectory: String?,
    expectedReleaseVersion: String?,
    expectedReleaseCommit: String?,
    environment: [String: String]
) throws -> InstallOptions {
    guard cliPrefix == nil || cliBindir == nil else {
        throw InstallError.message("--prefix and --bindir are mutually exclusive")
    }

    let prefix: String?
    let bindir: String?
    if let cliPrefix {
        prefix = try nonEmptyCLIValue(cliPrefix, option: "--prefix")
        bindir = nil
    } else if let cliBindir {
        prefix = nil
        bindir = try nonEmptyCLIValue(cliBindir, option: "--bindir")
    } else {
        let environmentPrefix = nonEmptyEnvironmentValue(environment["PREFIX"])
        let environmentBindir = nonEmptyEnvironmentValue(environment["BINDIR"])
        guard environmentPrefix == nil || environmentBindir == nil else {
            throw InstallError.message(
                "PREFIX and BINDIR are mutually exclusive when neither --prefix nor --bindir is provided"
            )
        }
        prefix = environmentPrefix
        bindir = environmentBindir
    }

    if releaseDirectory != nil {
        guard expectedReleaseVersion != nil,
              expectedReleaseCommit != nil
        else {
            throw InstallError.message(
                "prebuilt release installation requires its baked version and commit binding"
            )
        }
    } else if expectedReleaseVersion != nil || expectedReleaseCommit != nil {
        throw InstallError.message(
            "release version and commit binding require --release-dir"
        )
    }

    return InstallOptions(
        prefix: prefix,
        bindir: bindir,
        dryRun: dryRun,
        buildConfiguration: buildConfiguration,
        releaseDirectory: releaseDirectory,
        expectedReleaseVersion: expectedReleaseVersion,
        expectedReleaseCommit: expectedReleaseCommit
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
    outputLogger: @escaping @Sendable (String) -> Void,
    simulatorHelperTriple: String? = nil
) async throws {
    try Task.checkCancellation()
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
    let result = try await installer.withInstallLock {
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
            cohort = try await buildSourceCohort(
                repoRoot: repoRoot,
                configuration: options.buildConfiguration ?? .release,
                environment: environment,
                runner: runner,
                fileManager: fileManager,
                inspectArtifact: inspectArtifact,
                simulatorHelperTriple: simulatorHelperTriple
            )
        }
        return try await installer.installLocked(cohort)
    }
    InstallPathGuidance(
        commandDirectory: result.publicCommandURL.deletingLastPathComponent(),
        environment: environment,
        fileManager: fileManager
    ).messages().forEach(outputLogger)
}

func createReleaseManifest(
    options: CreateReleaseManifestOptions,
    fileManager: FileManager,
    inspectArtifact: ReleaseArtifactInspector
) async throws {
    try Task.checkCancellation()
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
    let manifest = try await makeReleaseManifest(
        version: options.version,
        commit: options.commit,
        artifactURLs: artifactURLs,
        inspectArtifact: inspectArtifact
    )
    let outputURL = URL(fileURLWithPath: options.output, isDirectory: false)
    try publishReleaseManifest(
        manifest,
        to: outputURL,
        fileManager: fileManager
    )
}

func publishReleaseManifest(
    _ manifest: ReleaseManifest,
    to outputURL: URL,
    fileManager: FileManager,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
) throws {
    let encoded = try manifest.encoded()
    // This check defines the publication boundary. Once synchronous filesystem mutation begins,
    // the atomic write either commits the complete manifest or leaves the previous file intact.
    try checkCancellation()
    try fileManager.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoded.write(to: outputURL, options: [.atomic])
}

func makeReleaseManifest(
    version: String,
    commit: String,
    artifactURLs: [InstallArtifactName: URL],
    inspectArtifact: ReleaseArtifactInspector
) async throws -> ReleaseManifest {
    try Task.checkCancellation()
    var records: [ReleaseArtifactRecord] = []
    for artifact in InstallArtifactName.allCases {
        guard let url = artifactURLs[artifact] else {
            throw InstallError.message(
                "missing release artifact: \(artifact.rawValue)"
            )
        }
        let inspection = try await inspectArtifact(artifact, url)
        try Task.checkCancellation()
        records.append(ReleaseArtifactRecord(
            name: artifact,
            sha256: inspection.sha256,
            architectures: inspection.architectures.sorted(),
            platform: inspection.platform,
            codeSignaturePolicy: .valid
        ))
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
) async throws -> ReleaseCohort {
    try Task.checkCancellation()
    let sourceBeforeBuild = try await captureSourceSnapshot(
        repoRoot: repoRoot,
        environment: environment,
        runner: runner,
        fileManager: fileManager
    )
    try await buildProducts(
        [
            InstallArtifactName.publicCommand.rawValue,
            InstallArtifactName.rawDumpHelper.rawValue,
        ],
        configuration: configuration,
        in: repoRoot,
        runner: runner
    )
    let simulatorSDKPath = try await resolveSimulatorSDKPath(runner: runner)
    let simulatorTriple = try simulatorHelperTriple ?? defaultSimulatorHelperTriple()
    let simulatorScratchPath = SwiftPMBuildPaths.simulatorScratchURL(
        repoRoot: repoRoot,
        triple: simulatorTriple
    )
    try await buildSimulatorHelper(
        in: repoRoot,
        configuration: configuration,
        scratchPath: simulatorScratchPath,
        sdkPath: simulatorSDKPath,
        runner: runner,
        simulatorHelperTriple: simulatorTriple
    )

    let hostBinDirectory = try await resolveSwiftBinDir(
        repoRoot: repoRoot,
        runner: runner,
        configuration: configuration
    )
    let simulatorBinDirectory = try await resolveSwiftBinDir(
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

    let sourceAfterBuild = try await captureSourceSnapshot(
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
    let manifest = try await makeReleaseManifest(
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
) async throws {
    for product in products {
        try await runner.runSimple(
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
        try Task.checkCancellation()
    }
}

func buildSimulatorHelper(
    in directory: URL,
    configuration: BuildConfiguration,
    scratchPath: URL,
    sdkPath: String,
    runner: CommandRunning,
    simulatorHelperTriple: String
) async throws {
    try await runner.runSimple(
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
    try Task.checkCancellation()
}

func resolveSimulatorSDKPath(runner: CommandRunning) async throws -> String {
    let output = try await runner.runCapture(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
        env: nil,
        cwd: nil
    )
    try Task.checkCancellation()
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
) async throws -> URL {
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
    let output = try await runner.runCapture(command, env: nil, cwd: repoRoot)
    try Task.checkCancellation()
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
    var messages = [
        "Would acquire install lock: \(layout.lockURL.path)",
        "Would stage all three artifacts under: \(layout.versionsDirectory.path)",
        "Would atomically switch: \(layout.currentURL.path)",
        "Would maintain stable command symlink: \(layout.publicCommandURL.path)",
    ]
    messages.append(contentsOf: ObsoletePublicCommand.allCases.map { command in
        "Would remove obsolete command if present: \(layout.url(for: command).path)"
    })
    return messages
}

private func nonEmptyCLIValue(
    _ rawValue: String,
    option: String
) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
        throw InstallError.message("\(option) requires a non-empty value")
    }
    return value
}

private func nonEmptyEnvironmentValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
        return nil
    }
    return value
}

#else

package func executeInstallerCommand(
    _ command: InstallerCommand,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async throws {
    throw InstallError.message("privateheaderkit-install is unsupported on this platform")
}

#endif
