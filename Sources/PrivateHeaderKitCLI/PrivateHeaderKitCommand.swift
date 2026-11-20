import ArgumentParser
import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let legacyPrivateHeaderKitCommandNames: Set<String> = [
    "privateheaderkit-dump",
    "headerdump",
    "headerdump-sim",
]

enum PrivateHeaderKitCLIError: Error, Equatable, CustomStringConvertible {
    case legacyCommand(String)
    case missingSimulatorResolution

    var description: String {
        switch self {
        case .legacyCommand(let command):
            "\(command) is no longer a user-facing command; use privateheaderkit instead"
        case .missingSimulatorResolution:
            "simulator generation requires a resolved runtime and device"
        }
    }
}

struct PrivateHeaderKitGenerateCommand: Equatable, Sendable {
    enum Platform: String, CaseIterable, Sendable {
        case iOS = "iOS"
        case watchOS = "watchOS"
        case macOS = "macOS"

        var corePlatform: PrivateHeaderGeneration.Source.Platform {
            switch self {
            case .iOS: .iOS
            case .watchOS: .watchOS
            case .macOS: .macOS
            }
        }

        var simulatorPlatform: SimulatorPlatform? {
            switch self {
            case .iOS: .iOS
            case .watchOS: .watchOS
            case .macOS: nil
            }
        }

        init(simulatorPlatform: SimulatorPlatform) {
            switch simulatorPlatform {
            case .iOS:
                self = .iOS
            case .watchOS:
                self = .watchOS
            }
        }
    }

    let platform: Platform
    let version: String
    let build: String?
    let systemRoot: String?
    let outputBaseDirectory: String
    let targetQuery: String
    let continuationMode: PrivateHeaderKitContinuationMode?
    let device: String?
    let simulatorHelperPath: String?
    var preferRuntimeMetadata = false

    var executionOptions: PrivateHeaderGeneration.ExecutionOptions {
        switch continuationMode {
        case .resume: .init(continuation: .resume)
        case .fresh: .init(continuation: .restart)
        case nil: .init()
        }
    }
}

struct PrivateHeaderKitSimulatorResolution: Equatable, Sendable {
    let runtimeVersion: String
    let runtimeBuild: String
    let runtimeIdentifier: String
    let resolvedRuntimeRoot: String
    let metadataIsSeed: Bool
    let deviceName: String
    let deviceUDID: String
    let deviceOwnership: SimulatorDeviceOwnership

    init(
        runtimeVersion: String,
        runtimeBuild: String,
        runtimeIdentifier: String,
        resolvedRuntimeRoot: String,
        metadataIsSeed: Bool,
        deviceName: String,
        deviceUDID: String,
        deviceOwnership: SimulatorDeviceOwnership = .borrowed
    ) {
        self.runtimeVersion = runtimeVersion
        self.runtimeBuild = runtimeBuild
        self.runtimeIdentifier = runtimeIdentifier
        self.resolvedRuntimeRoot = resolvedRuntimeRoot
        self.metadataIsSeed = metadataIsSeed
        self.deviceName = deviceName
        self.deviceUDID = deviceUDID
        self.deviceOwnership = deviceOwnership
    }

    init(runtime: RuntimeInfo, metadataIsSeed: Bool, resolvedDevice: ResolvedSimulatorDevice) {
        self.init(
            runtimeVersion: runtime.version,
            runtimeBuild: runtime.build,
            runtimeIdentifier: runtime.identifier,
            resolvedRuntimeRoot: runtime.runtimeRoot,
            metadataIsSeed: metadataIsSeed,
            deviceName: resolvedDevice.device.name,
            deviceUDID: resolvedDevice.device.udid,
            deviceOwnership: resolvedDevice.ownership
        )
    }
}

typealias PrivateHeaderKitOutputLogger = @Sendable (String) -> Void

struct PrivateHeaderKitCommandOutcome: Equatable, Sendable {
    let exitCode: Int32
    let runStatus: PrivateHeaderGeneration.RunStatus?
    var failureSummary: String? = nil
}

/// The helper executables a generation uses and, when the CLI runs from a package checkout,
/// the builds that produce them.
struct PrivateHeaderKitHelperPlan: Sendable {
    let helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs
    fileprivate let buildInvocations: [PrivateHeaderKitHelperBuildInvocation]

}

private struct PrivateHeaderKitHelperBuildInvocation: Sendable {
    let command: [String]
    let cwd: URL
}

func runPrivateHeaderKitCommand(
    _ args: [String],
    currentExecutableURL: URL? = Bundle.main.executableURL,
    processRunner: any CommandRunning = ProcessRunner(),
    interactiveOutputBaseDirectoryProvider: @escaping () -> String =
        defaultInteractiveOutputBaseDirectory,
    interactiveScreenClearer: @escaping PrivateHeaderKitInteractiveScreenClearer =
        clearInteractiveScreen,
    inputReader: PrivateHeaderKitInputReader? = nil,
    outputLogger: @escaping PrivateHeaderKitOutputLogger = logCLIOutput,
    errorLogger: @escaping PrivateHeaderKitOutputLogger = logCLIError
) async -> Int32 {
    let command: PrivateHeaderKitCommand
    do {
        command = try parsePrivateHeaderKitCommand(args)
    } catch let error as PrivateHeaderKitCLIError {
        errorLogger("error: \(error.description)")
        return 1
    } catch {
        let message = PrivateHeaderKitArguments.fullMessage(for: error)
        let exitCode = PrivateHeaderKitArguments.exitCode(for: error).rawValue
        let logger = exitCode == 0 ? outputLogger : errorLogger
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            logger(String(line))
        }
        return exitCode
    }

    let defaultInputSession: PrivateHeaderKitInputSession?
    if case .interactiveGenerate = command, inputReader == nil {
        defaultInputSession = PrivateHeaderKitInputSession()
    } else {
        defaultInputSession = nil
    }
    let effectiveInputReader: PrivateHeaderKitInputReader = inputReader ?? {
        try await defaultInputSession?.readLine()
    }
    let inputFinalizer: PrivateHeaderKitInputFinalizer = {
        try await defaultInputSession?.finish()
    }

    let exitCode: Int32
    do {
        switch command {
        case .decompile(let decompile):
            exitCode = try await runPrivateHeaderKitDecompileCommand(
                decompile, processRunner: processRunner,
                outputLogger: outputLogger, progressReporter: errorLogger
            )
        case .search(let search):
            exitCode = try runPrivateHeaderKitSearchCommand(
                search, outputLogger: outputLogger, errorLogger: errorLogger
            )
        case .interactiveGenerate(let outputBaseDirectory):
            exitCode = try await runPrivateHeaderKitInteractiveGenerate(
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                processRunner: processRunner,
                outputBaseDirectoryProvider: {
                    outputBaseDirectory ?? interactiveOutputBaseDirectoryProvider()
                },
                screenClearer: interactiveScreenClearer,
                inputReader: effectiveInputReader,
                inputFinalizer: inputFinalizer,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
        case .generateSSH(let generate):
            exitCode = try await runPrivateHeaderKitSSHGenerateCommand(
                generate, currentExecutableURL: currentExecutableURL,
                processRunner: processRunner,
                outputLogger: outputLogger, errorLogger: errorLogger
            )
        case .generate(let generate):
            exitCode = try await runPrivateHeaderKitGenerateCommand(
                generate,
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                processRunner: processRunner,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
        }
    } catch is CancellationError {
        exitCode = 130
    } catch {
        errorLogger("error: \(error)")
        exitCode = 2
    }
    do {
        try await inputFinalizer()
    } catch {
        errorLogger("error: unable to restore interactive input: \(error)")
        return exitCode == 0 ? 1 : exitCode
    }
    return exitCode
}

func runPrivateHeaderKitGenerateCommand(
    _ command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    processRunner: any CommandRunning,
    resultScreenClearer: PrivateHeaderKitInteractiveScreenClearer? = nil,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    errorLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> Int32 {
    let outcome = try await withPrivateHeaderKitSimulatorSession(
        command,
        runner: processRunner,
        outputLogger: outputLogger
    ) { simulatorResolution in
        do {
            let request = try await preparePrivateHeaderKitGenerationRequest(
                command,
                invokedProgramName: invokedProgramName,
                currentExecutableURL: currentExecutableURL,
                simulatorResolution: simulatorResolution,
                processRunner: processRunner
            )
            do {
                let preparedGeneration = try await preparePrivateHeaderGeneration(
                    request: request,
                    processRunner: processRunner,
                    recoveryReporter: errorLogger
                )
                return try await runPrivateHeaderKitPreparedGeneration(
                    preparedGeneration,
                    request: request,
                    targetQuery: command.targetQuery,
                    executionOptions: command.executionOptions,
                    resultScreenClearer: resultScreenClearer,
                    outputLogger: outputLogger,
                    errorLogger: errorLogger
                )
            } catch let error as PrivateHeaderGeneration.GenerationError {
                let cancellationRequested = Task.isCancelled
                if cancellationRequested {
                    guard case .runInterrupted = error else {
                        throw CancellationError()
                    }
                }
                let runStatus = renderPrivateHeaderKitGenerationError(
                    error,
                    sourceDisplayName: request.source.label.displayName,
                    targetQuery: command.targetQuery,
                    screenClearer: resultScreenClearer,
                    outputLogger: errorLogger
                )
                return PrivateHeaderKitCommandOutcome(
                    exitCode: cancellationRequested ? 130 : 2,
                    runStatus: runStatus
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            errorLogger("error: \(error)")
            return PrivateHeaderKitCommandOutcome(exitCode: 2, runStatus: nil)
        }
    }
    renderPrivateHeaderKitCommandOutcome(
        outcome,
        outputLogger: outputLogger,
        errorLogger: errorLogger
    )
    return outcome.exitCode
}

func preparePrivateHeaderKitGenerationRequest(
    _ command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?,
    processRunner: any CommandRunning
) async throws -> PrivateHeaderKitGenerationRequest {
    let effectiveSource = try effectiveSourceConfiguration(
        from: command,
        simulatorResolution: simulatorResolution
    )
    let publicExecutableURL = privateHeaderKitExecutableURL(
        currentExecutableURL: currentExecutableURL,
        fallbackProgramName: invokedProgramName
    )
    let helperPlan = try await resolvePrivateHeaderKitHelperPlan(
        publicExecutableURL: publicExecutableURL,
        simulatorHelperPath: command.simulatorHelperPath,
        simulatorPlatform: command.platform.simulatorPlatform,
        runner: processRunner
    )
    try await executePrivateHeaderKitHelperBuilds(helperPlan, runner: processRunner)
    return try makePrivateHeaderGenerationRequest(
        from: command,
        effectiveSource: effectiveSource,
        helperURLs: helperPlan.helperURLs,
        simulatorResolution: simulatorResolution
    )
}

func runPrivateHeaderKitPreparedGeneration(
    _ preparedGeneration: PrivateHeaderKitPreparedGeneration,
    request: PrivateHeaderKitGenerationRequest,
    targetQuery: String,
    executionOptions: PrivateHeaderGeneration.ExecutionOptions,
    resultScreenClearer: PrivateHeaderKitInteractiveScreenClearer?,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    errorLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> PrivateHeaderKitCommandOutcome {
    do {
        let result = try await preparedGeneration.run(
            executionOptions,
            privateHeaderKitProgressReporter(
                artifactDirectory: request.output.artifactDirectory(for: request.source),
                outputLogger: outputLogger,
                failureLogger: errorLogger
            )
        )
        resultScreenClearer?()
        renderPrivateHeaderKitRunSummary(
            result.summary,
            sourceDisplayName: result.plan.source.label.displayName,
            targetQuery: targetQuery,
            title: "Generation completed",
            outputLogger: outputLogger
        )
        return PrivateHeaderKitCommandOutcome(exitCode: 0, runStatus: result.summary.status)
    } catch let error as PrivateHeaderGeneration.GenerationError {
        let cancellationRequested = Task.isCancelled
        if cancellationRequested {
            guard case .runInterrupted = error else {
                throw CancellationError()
            }
        }
        let runStatus = renderPrivateHeaderKitGenerationError(
            error,
            sourceDisplayName: request.source.label.displayName,
            targetQuery: targetQuery,
            screenClearer: resultScreenClearer,
            outputLogger: errorLogger
        )
        return PrivateHeaderKitCommandOutcome(
            exitCode: cancellationRequested ? 130 : 2,
            runStatus: runStatus,
            failureSummary: String(describing: error)
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        errorLogger("error: \(error)")
        return PrivateHeaderKitCommandOutcome(exitCode: 2, runStatus: nil, failureSummary: String(describing: error))
    }
}

func makePrivateHeaderGenerationRequest(
    from command: PrivateHeaderKitGenerateCommand,
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?
) throws -> PrivateHeaderKitGenerationRequest {
    let effectiveSource = try effectiveSourceConfiguration(
        from: command,
        simulatorResolution: simulatorResolution
    )
    return try makePrivateHeaderGenerationRequest(
        from: command,
        effectiveSource: effectiveSource,
        helperURLs: helperURLs,
        simulatorResolution: simulatorResolution
    )
}

private func makePrivateHeaderGenerationRequest(
    from command: PrivateHeaderKitGenerateCommand,
    effectiveSource: EffectiveSourceConfiguration,
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?
) throws -> PrivateHeaderKitGenerationRequest {
    let source = effectiveSource.source
    let output = PrivateHeaderGeneration.Output(
        baseDirectory: URL(fileURLWithPath: command.outputBaseDirectory, isDirectory: true)
    )
    let executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
    if command.platform.simulatorPlatform == nil {
        executionMode = .host
    } else {
        guard let simulatorResolution else {
            throw PrivateHeaderKitCLIError.missingSimulatorResolution
        }
        executionMode = .simulator(
            deviceUDID: simulatorResolution.deviceUDID,
            sourceRuntimeRoot: effectiveSource.systemRoot.path,
            runtime: .init(
                version: simulatorResolution.runtimeVersion,
                build: simulatorResolution.runtimeBuild,
                identifier: simulatorResolution.runtimeIdentifier,
                runtimeRoot: canonicalDirectoryURL(
                    path: simulatorResolution.resolvedRuntimeRoot
                ).path
            )
        )
    }
    let targetRequest: PrivateHeaderGeneration.TargetRequest =
        command.targetQuery == "all" ? .allAvailable : .query(command.targetQuery)
    let options = PrivateHeaderGeneration.Options(
        targetRequest: targetRequest,
        systemRoot: effectiveSource.systemRoot,
        helperURLs: helperURLs,
        executionMode: executionMode,
        rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
            useSharedCache: effectiveSource.useSharedCache,
            preferRuntimeMetadata: command.preferRuntimeMetadata,
            helperEnvironment: ["PH_RUNTIME_ROOT": effectiveSource.systemRoot.path]
        ),
        executionOptions: command.executionOptions,
        producerVersion: PrivateHeaderKitBuildInfo.version
    )
    return PrivateHeaderKitGenerationRequest(source: source, output: output, options: options)
}

private struct EffectiveSourceConfiguration {
    let source: PrivateHeaderGeneration.Source
    let systemRoot: URL
    let useSharedCache: Bool
}

private func effectiveSourceConfiguration(
    from command: PrivateHeaderKitGenerateCommand,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?
) throws -> EffectiveSourceConfiguration {
    if let systemRoot = command.systemRoot {
        let systemRootURL = canonicalDirectoryURL(path: systemRoot)
        let build: String?
        let metadataIsSeed: Bool
        let useSharedCache: Bool
        if command.platform.simulatorPlatform == nil {
            build = command.build
            metadataIsSeed = try RuntimeReleaseMetadata.isSeed(in: systemRootURL, layout: .macOS)
            useSharedCache = systemRootURL.path == "/"
        } else {
            guard let simulatorResolution else {
                throw PrivateHeaderKitCLIError.missingSimulatorResolution
            }
            let identifiesSelectedRuntime = systemRootURL == canonicalDirectoryURL(
                path: simulatorResolution.resolvedRuntimeRoot
            )
            build = command.build
                ?? (identifiesSelectedRuntime ? simulatorResolution.runtimeBuild : nil)
            if identifiesSelectedRuntime {
                metadataIsSeed = simulatorResolution.metadataIsSeed
            } else {
                metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
                    in: systemRootURL,
                    layout: .simulator
                )
            }
            useSharedCache = identifiesSelectedRuntime
        }
        return try validatedEffectiveSourceConfiguration(
            command: command,
            build: build,
            systemRoot: systemRootURL,
            metadataIsSeed: metadataIsSeed,
            useSharedCache: useSharedCache
        )
    }
    guard command.platform.simulatorPlatform != nil, let simulatorResolution else {
        throw PrivateHeaderKitCLIError.missingSimulatorResolution
    }
    return try validatedEffectiveSourceConfiguration(
        command: command,
        build: command.build ?? simulatorResolution.runtimeBuild,
        systemRoot: canonicalDirectoryURL(path: simulatorResolution.resolvedRuntimeRoot),
        metadataIsSeed: simulatorResolution.metadataIsSeed,
        useSharedCache: true
    )
}

private func validatedEffectiveSourceConfiguration(
    command: PrivateHeaderKitGenerateCommand,
    build: String?,
    systemRoot: URL,
    metadataIsSeed: Bool,
    useSharedCache: Bool
) throws -> EffectiveSourceConfiguration {
    EffectiveSourceConfiguration(
        source: try PrivateHeaderGeneration.Source(
            platform: command.platform.corePlatform,
            version: command.version,
            build: build,
            metadataIsSeed: metadataIsSeed
        ),
        systemRoot: systemRoot,
        useSharedCache: useSharedCache
    )
}

private func canonicalDirectoryURL(path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
}

func defaultRawDumpHelperURL(publicExecutableURL: URL) -> URL {
    let cohortExecutable = publicExecutableURL.resolvingSymlinksInPath()
    return cohortExecutable.deletingLastPathComponent()
        .appendingPathComponent("privateheaderkit-raw-helper", isDirectory: false)
}

func defaultSimulatorHelperURL(
    hostExecutableURL: URL,
    platform: SimulatorPlatform
) -> URL {
    let cohortHelper = hostExecutableURL.resolvingSymlinksInPath()
    return cohortHelper.deletingLastPathComponent()
        .appendingPathComponent(
            privateHeaderKitInstalledSimulatorHelperName(for: platform),
            isDirectory: false
        )
}

private func privateHeaderKitInstalledSimulatorHelperName(
    for platform: SimulatorPlatform
) -> String {
    switch platform {
    case .iOS:
        "privateheaderkit-sim-helper"
    case .watchOS:
        "privateheaderkit-watch-sim-helper"
    }
}

/// Locates the helpers beside an installed CLI, or plans their builds when the CLI runs from
/// a package checkout.
///
/// The helpers report the build version compiled into them, and generation rejects a helper
/// whose version differs from the CLI's.
func resolvePrivateHeaderKitHelperPlan(
    publicExecutableURL: URL,
    simulatorHelperPath: String?,
    simulatorPlatform: SimulatorPlatform?,
    runner: CommandRunning,
    simulatorArchitecture: String = defaultSwiftPMSimulatorArchitecture()
) async throws -> PrivateHeaderKitHelperPlan {
    let explicitSimulatorURL = explicitSimulatorHelperURL(simulatorHelperPath)
    if let explicitSimulatorURL, simulatorPlatform != nil {
        try requireExecutableSimulatorHelper(explicitSimulatorURL)
    }
    guard let layout = swiftPMBuildProductLayout(for: publicExecutableURL) else {
        let hostURL = defaultRawDumpHelperURL(publicExecutableURL: publicExecutableURL)
        let simulatorURL = explicitSimulatorURL
            ?? defaultSimulatorHelperURL(
                hostExecutableURL: hostURL,
                platform: simulatorPlatform ?? .iOS
            )
        if simulatorPlatform != nil {
            try requireExecutableSimulatorHelper(simulatorURL)
        }
        return PrivateHeaderKitHelperPlan(
            helperURLs: .init(host: hostURL, simulator: simulatorURL),
            buildInvocations: []
        )
    }

    let hostCommand = [
        "swift", "build", "--force-resolved-versions", "-c", layout.configuration,
    ]
    let hostBinDirectory = try swiftPMBinDirectory(
        from: await runner.runCapture(
            hostCommand + ["--show-bin-path"],
            env: nil,
            cwd: layout.repoRoot
        ),
        destination: "host"
    )
    let hostURL = hostBinDirectory.appendingPathComponent(
        "privateheaderkit-raw-helper",
        isDirectory: false
    )
    var buildInvocations = [
        PrivateHeaderKitHelperBuildInvocation(
            command: hostCommand + ["--product", "privateheaderkit-raw-helper"],
            cwd: layout.repoRoot
        )
    ]

    let simulatorURL: URL
    if let explicitSimulatorURL {
        simulatorURL = explicitSimulatorURL
    } else if let simulatorPlatform {
        let simulatorTriple = simulatorPlatform.swiftPMTriple(
            architecture: simulatorArchitecture
        )
        let sdkPath = try lastNonemptyOutputLine(
            await runner.runCapture(
                ["xcrun", "--sdk", simulatorPlatform.sdkName, "--show-sdk-path"],
                env: nil,
                cwd: nil
            ),
            failureMessage: "failed to resolve \(simulatorPlatform.userFacingSimulatorName) SDK path"
        )
        let simulatorCommand = [
            "swift", "build", "--force-resolved-versions", "-c", layout.configuration,
            "--scratch-path",
            SwiftPMBuildPaths.simulatorScratchURL(
                repoRoot: layout.repoRoot,
                triple: simulatorTriple
            ).path,
            "--sdk", sdkPath,
            "--triple", simulatorTriple,
        ]
        simulatorURL = try swiftPMBinDirectory(
            from: await runner.runCapture(
                simulatorCommand + ["--show-bin-path"],
                env: nil,
                cwd: layout.repoRoot
            ),
            destination: simulatorPlatform.userFacingSimulatorName
        ).appendingPathComponent("privateheaderkit-sim-helper", isDirectory: false)
        buildInvocations.append(
            PrivateHeaderKitHelperBuildInvocation(
                command: simulatorCommand + ["--product", "privateheaderkit-sim-helper"],
                cwd: layout.repoRoot
            )
        )
    } else {
        simulatorURL = defaultSimulatorHelperURL(hostExecutableURL: hostURL, platform: .iOS)
    }
    return PrivateHeaderKitHelperPlan(
        helperURLs: .init(host: hostURL, simulator: simulatorURL),
        buildInvocations: buildInvocations
    )
}

/// A Simulator helper is started through `simctl spawn`, which reports a helper it cannot
/// start as an ordinary nonzero exit. Checking the file first keeps a missing helper from
/// being recorded as one failure per target.
private func requireExecutableSimulatorHelper(_ url: URL) throws {
    guard Which.find(url.path) != nil else {
        throw ToolingError.message(
            "Simulator helper is missing or not an executable file: \(url.path)"
        )
    }
}

func executePrivateHeaderKitHelperBuilds(
    _ plan: PrivateHeaderKitHelperPlan,
    runner: CommandRunning
) async throws {
    for invocation in plan.buildInvocations {
        _ = try await runner.runCapture(invocation.command, env: nil, cwd: invocation.cwd)
    }
}

private struct SwiftPMBuildProductLayout {
    let buildRoot: URL
    let configuration: String

    var repoRoot: URL { buildRoot.deletingLastPathComponent() }
}

private func swiftPMBuildProductLayout(for executableURL: URL) -> SwiftPMBuildProductLayout? {
    let directory = executableURL.deletingLastPathComponent()
    let components = directory.pathComponents
    guard let buildIndex = components.lastIndex(of: ".build") else {
        return nil
    }
    let trailing = Array(components.dropFirst(buildIndex + 1))
    let configuration: String?
    switch trailing.count {
    case 1:
        configuration = swiftPMBuildConfiguration(trailing[0])
    case 2:
        configuration = swiftPMBuildConfiguration(trailing[1])
    case 3 where trailing[0] == "out" && trailing[1] == "Products":
        configuration = swiftPMBuildConfiguration(trailing[2])
    default:
        return nil
    }
    guard let configuration else { return nil }
    return SwiftPMBuildProductLayout(
        buildRoot: URL(
            fileURLWithPath: NSString.path(
                withComponents: Array(components.prefix(buildIndex + 1))
            )
        ),
        configuration: configuration
    )
}

private func swiftPMBuildConfiguration(_ value: String) -> String? {
    switch value.lowercased() {
    case "debug": "debug"
    case "release": "release"
    default: nil
    }
}

private func explicitSimulatorHelperURL(_ path: String?) -> URL? {
    path.map {
        URL(fileURLWithPath: PathUtils.expandTilde($0), isDirectory: false)
    }
}

private func swiftPMBinDirectory(from output: String, destination: String) throws -> URL {
    let path = try lastNonemptyOutputLine(
        output,
        failureMessage: "swift build --show-bin-path returned no path for \(destination)"
    )
    guard NSString(string: path).isAbsolutePath else {
        throw ToolingError.message(
            "swift build --show-bin-path returned a relative path for \(destination): \(path)"
        )
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private func lastNonemptyOutputLine(_ output: String, failureMessage: String) throws -> String {
    guard let line = output
        .split(whereSeparator: \Character.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .last(where: { !$0.isEmpty })
    else {
        throw ToolingError.message(failureMessage)
    }
    return line
}

func defaultSwiftPMSimulatorArchitecture() -> String {
#if arch(x86_64)
    return currentHostSupportsNativeArm64Simulator() ? "arm64" : "x86_64"
#else
    return "arm64"
#endif
}

private func currentHostSupportsNativeArm64Simulator() -> Bool {
#if canImport(Darwin)
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value != 0
#else
    return false
#endif
}

func withPrivateHeaderKitSimulatorSession<Result>(
    _ command: PrivateHeaderKitGenerateCommand,
    runner: any CommandRunning,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    operation: (PrivateHeaderKitSimulatorResolution?) async throws -> Result
) async throws -> Result {
    let resolution: PrivateHeaderKitSimulatorResolution?
    if command.platform.simulatorPlatform == nil {
        resolution = nil
    } else {
        renderPrivateHeaderKitSimulatorPreparation(command, outputLogger: outputLogger)
        let resolved = try await resolvePrivateHeaderKitSimulator(for: command, runner: runner)
        renderPrivateHeaderKitSimulatorReady(
            resolved,
            command: command,
            outputLogger: outputLogger
        )
        resolution = resolved
    }

    let result: Result
    do {
        result = try await operation(resolution)
    } catch {
        let operationError = error
        if let resolution {
            do {
                try await finishPrivateHeaderKitSimulatorSession(
                    resolution,
                    runner: runner,
                    outputLogger: outputLogger
                )
            } catch {
                throw PrivateHeaderKitSimulatorSessionCleanupError(
                    deviceName: resolution.deviceName,
                    deviceUDID: resolution.deviceUDID,
                    operationError: String(describing: operationError),
                    cleanupError: String(describing: error)
                )
            }
        }
        throw operationError
    }
    if let resolution {
        do {
            try await finishPrivateHeaderKitSimulatorSession(
                resolution,
                runner: runner,
                outputLogger: outputLogger
            )
        } catch {
            throw PrivateHeaderKitSimulatorSessionCleanupError(
                deviceName: resolution.deviceName,
                deviceUDID: resolution.deviceUDID,
                operationError: nil,
                cleanupError: String(describing: error)
            )
        }
    }
    return result
}

struct PrivateHeaderKitSimulatorSessionCleanupError: Error, CustomStringConvertible {
    let deviceName: String
    let deviceUDID: String
    let operationError: String?
    let cleanupError: String

    var description: String {
        let device = "\(deviceName) (UDID: \(deviceUDID))"
        guard let operationError else {
            return "simulator cleanup failed for \(device): \(cleanupError)"
        }
        return "simulator cleanup failed for \(device) after \(operationError): \(cleanupError)"
    }
}

private func finishPrivateHeaderKitSimulatorSession(
    _ resolution: PrivateHeaderKitSimulatorResolution,
    runner: any CommandRunning,
    outputLogger: @escaping PrivateHeaderKitOutputLogger
) async throws {
    guard resolution.deviceOwnership == .runOwned else { return }
    // Detached so that a cancelled run still deletes the device it created.
    try await Task.detached {
        try await Simctl.deleteDevice(
            DeviceInfo(
                name: resolution.deviceName,
                udid: resolution.deviceUDID,
                state: "Booted"
            ),
            runner: runner
        )
    }.value
    renderPrivateHeaderKitSimulatorCleanup(outputLogger: outputLogger)
}

func resolvePrivateHeaderKitSimulator(
    for command: PrivateHeaderKitGenerateCommand,
    runner: CommandRunning,
    dedicatedDeviceName: String? = nil
) async throws -> PrivateHeaderKitSimulatorResolution {
    guard let simulatorPlatform = command.platform.simulatorPlatform else {
        throw PrivateHeaderKitCLIError.missingSimulatorResolution
    }
    let runtime = try await Simctl.findRuntime(
        platform: simulatorPlatform,
        version: command.version,
        build: command.build,
        runner: runner
    )
    let metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
        in: canonicalDirectoryURL(path: runtime.runtimeRoot),
        layout: .simulator
    )
    _ = try PrivateHeaderGeneration.Source(
        platform: command.platform.corePlatform,
        version: runtime.version,
        build: runtime.build.isEmpty ? nil : runtime.build,
        metadataIsSeed: metadataIsSeed
    )
    let resolvedDevice = try await Simctl.resolveDevice(
        runtime: runtime,
        query: command.device,
        runner: runner,
        dedicatedDeviceName: dedicatedDeviceName
    )
    return PrivateHeaderKitSimulatorResolution(
        runtime: runtime,
        metadataIsSeed: metadataIsSeed,
        resolvedDevice: resolvedDevice
    )
}

func discoverPrivateHeaderKitInteractiveSources(
    runner: CommandRunning
) async throws -> PrivateHeaderKitSourceDiscovery {
    try Task.checkCancellation()
    var sources: [PrivateHeaderKitInteractiveSource] = []
    var failures: [PrivateHeaderKitSourceDiscovery.Failure] = []
    let runtimes: [RuntimeInfo]
    do {
        runtimes = try await Simctl.listRuntimes(runner: runner)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        failures.append(.init(source: "Simulator runtimes", message: String(describing: error)))
        runtimes = []
    }
    for runtime in runtimes {
        try Task.checkCancellation()
        do {
            let metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
                in: canonicalDirectoryURL(path: runtime.runtimeRoot),
                layout: .simulator
            )
            sources.append(.init(
                platform: .init(simulatorPlatform: runtime.platform),
                version: runtime.version,
                build: runtime.build.isEmpty ? nil : runtime.build,
                metadataIsSeed: metadataIsSeed,
                systemRoot: nil
            ))
        } catch {
            let build = runtime.build.isEmpty ? "" : " (\(runtime.build))"
            failures.append(.init(
                source: "\(runtime.platform.userFacingSourceName) \(runtime.version)\(build)",
                message: String(describing: error)
            ))
        }
    }
    try Task.checkCancellation()
    do {
        sources.append(try await currentMacOSInteractiveSource(runner: runner))
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        failures.append(.init(source: "macOS", message: String(describing: error)))
    }
    try Task.checkCancellation()
    return .init(sources: sources, failures: failures)
}

private func currentMacOSInteractiveSource(
    runner: CommandRunning
) async throws -> PrivateHeaderKitInteractiveSource {
    let version = try await runner.runCapture(
        ["/usr/bin/sw_vers", "-productVersion"],
        env: nil,
        cwd: nil
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let build = try await runner.runCapture(
        ["/usr/bin/sw_vers", "-buildVersion"],
        env: nil,
        cwd: nil
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let metadataIsSeed = try RuntimeReleaseMetadata.isSeed(
        in: URL(fileURLWithPath: "/", isDirectory: true),
        layout: .macOS
    )
    return PrivateHeaderKitInteractiveSource(
        platform: .macOS,
        version: version,
        build: build.isEmpty ? nil : build,
        metadataIsSeed: metadataIsSeed,
        systemRoot: "/"
    )
}

func privateHeaderKitExecutableURL(
    currentExecutableURL: URL?,
    fallbackProgramName: String
) -> URL {
    currentExecutableURL ?? URL(fileURLWithPath: fallbackProgramName, isDirectory: false)
}

func validatePrivateHeaderKitTargetQuery(_ query: String) throws {
    _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: query)
}
