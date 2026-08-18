import ArgumentParser
import Foundation
import PrivateHeaderKitCore
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
    case invalidTargetQuery(String)
    case missingSimulatorResolution

    var description: String {
        switch self {
        case .legacyCommand(let command):
            "\(command) is no longer a user-facing command; use privateheaderkit instead"
        case .invalidTargetQuery(let value):
            "target query must be 'all' or a comma-separated list without empty entries: \(value)"
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

    var resumeBehavior: PrivateHeaderGeneration.ResumeBehavior {
        switch continuationMode {
        case .resume: .resume
        case .fresh: .fresh
        case nil: .requireExplicitResume(resumeRequested: false)
        }
    }
}

struct PrivateHeaderKitSimulatorResolution: Equatable, Sendable {
    let runtimeVersion: String
    let runtimeBuild: String
    let runtimeIdentifier: String
    let resolvedRuntimeRoot: String
    let deviceName: String
    let deviceUDID: String

    init(
        runtimeVersion: String,
        runtimeBuild: String,
        runtimeIdentifier: String,
        resolvedRuntimeRoot: String,
        deviceName: String,
        deviceUDID: String
    ) {
        self.runtimeVersion = runtimeVersion
        self.runtimeBuild = runtimeBuild
        self.runtimeIdentifier = runtimeIdentifier
        self.resolvedRuntimeRoot = resolvedRuntimeRoot
        self.deviceName = deviceName
        self.deviceUDID = deviceUDID
    }

    init(runtime: RuntimeInfo, device: DeviceInfo) {
        self.init(
            runtimeVersion: runtime.version,
            runtimeBuild: runtime.build,
            runtimeIdentifier: runtime.identifier,
            resolvedRuntimeRoot: runtime.runtimeRoot,
            deviceName: device.name,
            deviceUDID: device.udid
        )
    }
}

typealias PrivateHeaderKitSimulatorResolver = @Sendable (
    PrivateHeaderKitGenerateCommand
) async throws -> PrivateHeaderKitSimulatorResolution
typealias PrivateHeaderKitHelperResolver = @Sendable (
    URL,
    String?,
    SimulatorPlatform?
) async throws -> PrivateHeaderKitHelperPlan
typealias PrivateHeaderKitOutputLogger = @Sendable (String) -> Void

struct PrivateHeaderKitHelperPlan: Sendable {
    let helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs
    let toolCompatibilityIdentity: String
    fileprivate let preparation: PrivateHeaderKitHelperPreparation

    init(
        helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
        toolCompatibilityIdentity: String
    ) {
        self.helperURLs = helperURLs
        self.toolCompatibilityIdentity = toolCompatibilityIdentity
        self.preparation = .ready
    }

    fileprivate init(
        helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
        toolCompatibilityIdentity: String,
        preparation: PrivateHeaderKitHelperPreparation
    ) {
        self.helperURLs = helperURLs
        self.toolCompatibilityIdentity = toolCompatibilityIdentity
        self.preparation = preparation
    }
}

private struct PrivateHeaderKitHelperBuildInvocation: Sendable {
    let command: [String]
    let cwd: URL
}

private enum PrivateHeaderKitHelperPreparation: Sendable {
    case ready
    case installed(PrivateHeaderKitInstalledToolValidation)
    case swiftPM(PrivateHeaderKitSwiftPMToolPreparation)
}

private struct PrivateHeaderKitInstalledToolValidation: Sendable {
    let runningExecutableIdentity: String
    let artifacts: [ToolArtifactInput]
    let baseline: ToolArtifactSnapshot
}

private struct PrivateHeaderKitSwiftPMToolPreparation: Sendable {
    let context: SwiftPMToolIdentityContext
    let baseline: SwiftPMToolSnapshot
    let buildInvocations: [PrivateHeaderKitHelperBuildInvocation]
    let preparedArtifacts: [ToolArtifactInput]
}

func runPrivateHeaderKitCommand(
    _ args: [String],
    currentExecutableURL: URL? = Bundle.main.executableURL,
    generationClient: PrivateHeaderKitGenerationClient = .live,
    simulatorResolver: @escaping PrivateHeaderKitSimulatorResolver = resolvePrivateHeaderKitSimulator,
    helperResolver: @escaping PrivateHeaderKitHelperResolver = resolvePrivateHeaderKitHelperURLs,
    interactiveSourceProvider: @escaping PrivateHeaderKitInteractiveSourceProvider =
        discoverPrivateHeaderKitInteractiveSources,
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

    let defaultInputSession: PrivateHeaderKitInputSession? =
        command == .interactiveGenerate && inputReader == nil
            ? PrivateHeaderKitInputSession()
            : nil
    let effectiveInputReader: PrivateHeaderKitInputReader = inputReader ?? {
        try await defaultInputSession?.readLine()
    }
    let inputFinalizer: PrivateHeaderKitInputFinalizer = {
        try await defaultInputSession?.finish()
    }

    let exitCode: Int32
    do {
        switch command {
        case .interactiveGenerate:
            exitCode = try await runPrivateHeaderKitInteractiveGenerate(
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                generationClient: generationClient,
                simulatorResolver: simulatorResolver,
                helperResolver: helperResolver,
                sourceProvider: interactiveSourceProvider,
                outputBaseDirectoryProvider: interactiveOutputBaseDirectoryProvider,
                screenClearer: interactiveScreenClearer,
                inputReader: effectiveInputReader,
                inputFinalizer: inputFinalizer,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
        case .generate(let generate):
            exitCode = try await runPrivateHeaderKitGenerateCommand(
                generate,
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                generationClient: generationClient,
                simulatorResolver: simulatorResolver,
                helperResolver: helperResolver,
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
    generationClient: PrivateHeaderKitGenerationClient,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    helperResolver: PrivateHeaderKitHelperResolver = resolvePrivateHeaderKitHelperURLs,
    resultScreenClearer: PrivateHeaderKitInteractiveScreenClearer? = nil,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    errorLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> Int32 {
    do {
        let request = try await preparePrivateHeaderKitGenerationRequest(
            command,
            invokedProgramName: invokedProgramName,
            currentExecutableURL: currentExecutableURL,
            simulatorResolver: simulatorResolver,
            helperResolver: helperResolver,
            outputLogger: outputLogger
        )
        do {
            let preparedGeneration = try await generationClient.prepare(request)
            return try await runPrivateHeaderKitPreparedGeneration(
                preparedGeneration,
                request: request,
                targetQuery: command.targetQuery,
                resumeBehavior: command.resumeBehavior,
                resultScreenClearer: resultScreenClearer,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
        } catch let error as PrivateHeaderGeneration.GenerationError {
            if Task.isCancelled {
                throw CancellationError()
            }
            renderPrivateHeaderKitGenerationError(
                error,
                sourceDisplayName: request.source.label.displayName,
                targetQuery: command.targetQuery,
                screenClearer: resultScreenClearer,
                outputLogger: errorLogger
            )
            return 2
        }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        errorLogger("error: \(error)")
        return 2
    }
}

func preparePrivateHeaderKitGenerationRequest(
    _ command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    helperResolver: PrivateHeaderKitHelperResolver,
    outputLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> PrivateHeaderKitGenerationRequest {
    let publicExecutableURL = privateHeaderKitExecutableURL(
        currentExecutableURL: currentExecutableURL,
        fallbackProgramName: invokedProgramName
    )
    let helperPlan = try await helperResolver(
        publicExecutableURL,
        command.simulatorHelperPath,
        command.platform.simulatorPlatform
    )
    try await preparePrivateHeaderKitHelpers(helperPlan)
    let simulatorResolution: PrivateHeaderKitSimulatorResolution?
    if command.platform.simulatorPlatform != nil {
        let resolution = try await simulatorResolver(command)
        outputLogger(
            "selected simulator: \(resolution.deviceName) (\(resolution.deviceUDID))"
        )
        simulatorResolution = resolution
    } else {
        simulatorResolution = nil
    }
    return try makePrivateHeaderGenerationRequest(
        from: command,
        helperURLs: helperPlan.helperURLs,
        toolCompatibilityIdentity: helperPlan.toolCompatibilityIdentity,
        simulatorResolution: simulatorResolution
    )
}

func runPrivateHeaderKitPreparedGeneration(
    _ preparedGeneration: PrivateHeaderKitPreparedGeneration,
    request: PrivateHeaderKitGenerationRequest,
    targetQuery: String,
    resumeBehavior: PrivateHeaderGeneration.ResumeBehavior,
    resultScreenClearer: PrivateHeaderKitInteractiveScreenClearer?,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    errorLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> Int32 {
    do {
        let result = try await preparedGeneration.run(
            resumeBehavior,
            privateHeaderKitProgressReporter(
                artifactDirectory: request.output.artifactBaseDirectory.appendingPathComponent(
                    request.source.storageIdentifier,
                    isDirectory: true
                ),
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
        return 0
    } catch let error as PrivateHeaderGeneration.GenerationError {
        if Task.isCancelled {
            throw CancellationError()
        }
        renderPrivateHeaderKitGenerationError(
            error,
            sourceDisplayName: request.source.label.displayName,
            targetQuery: targetQuery,
            screenClearer: resultScreenClearer,
            outputLogger: errorLogger
        )
        return 2
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        errorLogger("error: \(error)")
        return 2
    }
}

func makePrivateHeaderGenerationRequest(
    from command: PrivateHeaderKitGenerateCommand,
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    toolCompatibilityIdentity: String,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?
) throws -> PrivateHeaderKitGenerationRequest {
    let effectiveSource = try effectiveSourceConfiguration(
        from: command,
        simulatorResolution: simulatorResolution
    )
    let source = try PrivateHeaderGeneration.Source(
        platform: command.platform.corePlatform,
        version: command.version,
        build: effectiveSource.build
    )
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
            runtimeRoot: effectiveSource.systemRoot.path
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
            preferRuntimeMetadata: true,
            helperEnvironment: ["PH_RUNTIME_ROOT": effectiveSource.systemRoot.path]
        ),
        resumeBehavior: command.resumeBehavior,
        toolCompatibilityIdentity: toolCompatibilityIdentity
    )
    return PrivateHeaderKitGenerationRequest(source: source, output: output, options: options)
}

private struct EffectiveSourceConfiguration {
    let build: String?
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
        let useSharedCache: Bool
        if command.platform.simulatorPlatform == nil {
            build = command.build
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
            useSharedCache = identifiesSelectedRuntime
        }
        return EffectiveSourceConfiguration(
            build: build,
            systemRoot: systemRootURL,
            useSharedCache: useSharedCache
        )
    }
    guard command.platform.simulatorPlatform != nil, let simulatorResolution else {
        throw PrivateHeaderKitCLIError.missingSimulatorResolution
    }
    return EffectiveSourceConfiguration(
        build: command.build ?? simulatorResolution.runtimeBuild,
        systemRoot: canonicalDirectoryURL(path: simulatorResolution.resolvedRuntimeRoot),
        useSharedCache: true
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

func resolvePrivateHeaderKitHelperURLs(
    publicExecutableURL: URL,
    simulatorHelperPath: String?,
    simulatorPlatform: SimulatorPlatform?
) async throws -> PrivateHeaderKitHelperPlan {
    try await resolvePrivateHeaderKitHelperPlan(
        publicExecutableURL: publicExecutableURL,
        simulatorHelperPath: simulatorHelperPath,
        simulatorPlatform: simulatorPlatform
    )
}

func resolvePrivateHeaderKitHelperPlan(
    publicExecutableURL: URL,
    simulatorHelperPath: String?,
    simulatorPlatform: SimulatorPlatform?,
    runner: CommandRunning = ProcessRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    simulatorArchitecture: String = defaultSwiftPMSimulatorArchitecture()
) async throws -> PrivateHeaderKitHelperPlan {
    let runningExecutableIdentity = try currentProcessExecutableBuildIdentity()
    guard let layout = swiftPMBuildProductLayout(for: publicExecutableURL) else {
        let hostURL = defaultRawDumpHelperURL(publicExecutableURL: publicExecutableURL)
        let simulatorURL = simulatorPlatform.map { platform in
            explicitSimulatorHelperURL(simulatorHelperPath)
                ?? defaultSimulatorHelperURL(hostExecutableURL: hostURL, platform: platform)
        } ?? hostURL
        var artifacts = [
            ToolArtifactInput(role: "host-helper", url: hostURL),
        ]
        if simulatorPlatform != nil {
            artifacts.append(ToolArtifactInput(
                role: "simulator-helper",
                url: simulatorURL
            ))
        }
        let baseline = try captureToolArtifactSnapshot(
            runningExecutableIdentity: runningExecutableIdentity,
            artifacts: artifacts,
            fileManager: .default
        )
        let preparedURLs = try privateHeaderKitPreparedHelperURLs(
            compatibilityIdentity: baseline.compatibilityIdentity
        )
        return PrivateHeaderKitHelperPlan(
            helperURLs: preparedURLs,
            toolCompatibilityIdentity: baseline.compatibilityIdentity,
            preparation: .installed(PrivateHeaderKitInstalledToolValidation(
                runningExecutableIdentity: runningExecutableIdentity,
                artifacts: artifacts,
                baseline: baseline
            ))
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
    let hostBuildInvocation = PrivateHeaderKitHelperBuildInvocation(
        command: hostCommand + ["--product", "privateheaderkit-raw-helper"],
        cwd: layout.repoRoot
    )
    let simulatorURL: URL
    var buildInvocations = [hostBuildInvocation]
    var buildRecipes = [SwiftPMToolBuildRecipe(
        product: "privateheaderkit-raw-helper",
        configuration: layout.configuration,
        destination: .host
    )]
    var externalArtifacts = [ToolArtifactInput]()
    var preparedArtifacts = [
        ToolArtifactInput(role: "host-helper", url: hostURL),
    ]
    let explicitSimulatorURL = simulatorPlatform.flatMap { _ in
        explicitSimulatorHelperURL(simulatorHelperPath)
    }
    if let explicitSimulatorURL {
        simulatorURL = explicitSimulatorURL
        let artifact = ToolArtifactInput(
            role: "simulator-helper",
            url: explicitSimulatorURL
        )
        externalArtifacts.append(artifact)
        preparedArtifacts.append(artifact)
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
        let scratchPath = SwiftPMBuildPaths.simulatorScratchURL(
            repoRoot: layout.repoRoot,
            triple: simulatorTriple
        )
        let simulatorCommand = [
            "swift", "build", "--force-resolved-versions", "-c", layout.configuration,
            "--scratch-path", scratchPath.path,
            "--sdk", sdkPath,
            "--triple", simulatorTriple,
        ]
        let simulatorBinDirectory = try swiftPMBinDirectory(
            from: await runner.runCapture(
                simulatorCommand + ["--show-bin-path"],
                env: nil,
                cwd: layout.repoRoot
            ),
            destination: simulatorPlatform.userFacingSimulatorName
        )
        simulatorURL = simulatorBinDirectory.appendingPathComponent(
            "privateheaderkit-sim-helper",
            isDirectory: false
        )
        buildInvocations.append(PrivateHeaderKitHelperBuildInvocation(
            command: simulatorCommand + ["--product", "privateheaderkit-sim-helper"],
            cwd: layout.repoRoot
        ))
        buildRecipes.append(SwiftPMToolBuildRecipe(
            product: "privateheaderkit-sim-helper",
            configuration: layout.configuration,
            destination: .simulator(
                platform: simulatorPlatform,
                sdkPath: sdkPath,
                triple: simulatorTriple
            )
        ))
        preparedArtifacts.append(ToolArtifactInput(
            role: "simulator-helper",
            url: simulatorURL
        ))
    } else {
        simulatorURL = hostURL
    }
    let identityContext = SwiftPMToolIdentityContext(
        repoRoot: layout.repoRoot,
        runningExecutableIdentity: runningExecutableIdentity,
        builds: buildRecipes,
        externalArtifacts: externalArtifacts,
        buildEnvironment: environment
    )
    let baseline = try await captureSwiftPMToolSnapshot(
        context: identityContext,
        runner: runner,
        fileManager: .default
    )
    let preparedURLs = try privateHeaderKitPreparedHelperURLs(
        compatibilityIdentity: baseline.compatibilityIdentity
    )
    return PrivateHeaderKitHelperPlan(
        helperURLs: preparedURLs,
        toolCompatibilityIdentity: baseline.compatibilityIdentity,
        preparation: .swiftPM(PrivateHeaderKitSwiftPMToolPreparation(
            context: identityContext,
            baseline: baseline,
            buildInvocations: buildInvocations,
            preparedArtifacts: preparedArtifacts
        ))
    )
}

func preparePrivateHeaderKitHelpers(_ plan: PrivateHeaderKitHelperPlan) async throws {
    try await executePrivateHeaderKitHelperBuilds(plan, runner: ProcessRunner())
}

func executePrivateHeaderKitHelperBuilds(
    _ plan: PrivateHeaderKitHelperPlan,
    runner: CommandRunning
) async throws {
    switch plan.preparation {
    case .ready:
        return
    case let .installed(validation):
        let current = try captureToolArtifactSnapshot(
            runningExecutableIdentity: validation.runningExecutableIdentity,
            artifacts: validation.artifacts,
            fileManager: .default
        )
        guard current == validation.baseline else {
            throw ToolingError.message(
                "installed generation helpers changed after resume inspection"
            )
        }
        try materializePrivateHeaderKitHelpers(
            sources: validation.artifacts,
            snapshot: current,
            runningExecutableIdentity: validation.runningExecutableIdentity,
            destinations: plan.helperURLs,
            fileManager: .default
        )
    case let .swiftPM(preparation):
        let beforeBuild = try await captureSwiftPMToolSnapshot(
            context: preparation.context,
            runner: runner,
            fileManager: .default
        )
        guard beforeBuild == preparation.baseline else {
            throw ToolingError.message(
                "SwiftPM helper inputs changed after resume inspection"
            )
        }
        for invocation in preparation.buildInvocations {
            _ = try await runner.runCapture(
                invocation.command,
                env: nil,
                cwd: invocation.cwd
            )
        }
        let afterBuild = try await captureSwiftPMToolSnapshot(
            context: preparation.context,
            runner: runner,
            fileManager: .default
        )
        guard afterBuild == preparation.baseline else {
            throw ToolingError.message(
                "SwiftPM helper inputs changed while building generation helpers"
            )
        }
        let preparedSnapshot = try captureToolArtifactSnapshot(
            runningExecutableIdentity: preparation.context.runningExecutableIdentity,
            artifacts: preparation.preparedArtifacts,
            fileManager: .default
        )
        try materializePrivateHeaderKitHelpers(
            sources: preparation.preparedArtifacts,
            snapshot: preparedSnapshot,
            runningExecutableIdentity: preparation.context.runningExecutableIdentity,
            destinations: plan.helperURLs,
            fileManager: .default
        )
    }
}

private func privateHeaderKitPreparedHelperURLs(
    compatibilityIdentity: String,
    fileManager: FileManager = .default
) throws -> PrivateHeaderGeneration.RawDumping.HelperURLs {
    guard let digest = compatibilityIdentity.split(separator: ":").last.map(String.init),
          digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    else {
        throw ToolingError.message("tool compatibility identity has no content digest")
    }
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("PrivateHeaderKit", isDirectory: true)
        .appendingPathComponent("prepared-tools", isDirectory: true)
        .appendingPathComponent("v1", isDirectory: true)
        .appendingPathComponent(digest, isDirectory: true)
    return PrivateHeaderGeneration.RawDumping.HelperURLs(
        host: directory.appendingPathComponent(
            "privateheaderkit-raw-helper",
            isDirectory: false
        ),
        simulator: directory.appendingPathComponent(
            "privateheaderkit-sim-helper",
            isDirectory: false
        )
    )
}

private func materializePrivateHeaderKitHelpers(
    sources: [ToolArtifactInput],
    snapshot: ToolArtifactSnapshot,
    runningExecutableIdentity: String,
    destinations: PrivateHeaderGeneration.RawDumping.HelperURLs,
    fileManager: FileManager
) throws {
    let destinationByRole = [
        "host-helper": destinations.host,
        "simulator-helper": destinations.simulator,
    ]
    let destinationInputs = try sources.map { source -> ToolArtifactInput in
        guard let destination = destinationByRole[source.role] else {
            throw ToolingError.message("unsupported prepared helper role: \(source.role)")
        }
        return ToolArtifactInput(role: source.role, url: destination)
    }
    let finalDirectory = destinations.host.deletingLastPathComponent()
    guard destinations.simulator.deletingLastPathComponent() == finalDirectory else {
        throw ToolingError.message("prepared helpers must share one content directory")
    }
    if fileManager.fileExists(atPath: finalDirectory.path) {
        try validateMaterializedPrivateHeaderKitHelpers(
            destinationInputs,
            expected: snapshot,
            runningExecutableIdentity: runningExecutableIdentity,
            fileManager: fileManager
        )
        return
    }

    let parent = finalDirectory.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    let stagingDirectory = parent.appendingPathComponent(
        ".\(finalDirectory.lastPathComponent).\(UUID().uuidString).tmp",
        isDirectory: true
    )
    try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
    var stagingExists = true
    defer {
        if stagingExists {
            try? fileManager.removeItem(at: stagingDirectory)
        }
    }
    for source in sources {
        guard let finalURL = destinationByRole[source.role] else {
            throw ToolingError.message("unsupported prepared helper role: \(source.role)")
        }
        let stagingURL = stagingDirectory.appendingPathComponent(
            finalURL.lastPathComponent,
            isDirectory: false
        )
        try fileManager.copyItem(
            at: source.url.resolvingSymlinksInPath(),
            to: stagingURL
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: UInt16(0o555))],
            ofItemAtPath: stagingURL.path
        )
    }
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: UInt16(0o555))],
        ofItemAtPath: stagingDirectory.path
    )
    do {
        try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        stagingExists = false
    } catch {
        guard fileManager.fileExists(atPath: finalDirectory.path) else {
            throw error
        }
    }
    try validateMaterializedPrivateHeaderKitHelpers(
        destinationInputs,
        expected: snapshot,
        runningExecutableIdentity: runningExecutableIdentity,
        fileManager: fileManager
    )
}

private func validateMaterializedPrivateHeaderKitHelpers(
    _ inputs: [ToolArtifactInput],
    expected: ToolArtifactSnapshot,
    runningExecutableIdentity: String,
    fileManager: FileManager
) throws {
    let actual = try captureToolArtifactSnapshot(
        runningExecutableIdentity: runningExecutableIdentity,
        artifacts: inputs,
        fileManager: fileManager
    )
    guard actual == expected else {
        throw ToolingError.message(
            "prepared helper content does not match its compatibility identity"
        )
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

func resolvePrivateHeaderKitSimulator(
    for command: PrivateHeaderKitGenerateCommand
) async throws -> PrivateHeaderKitSimulatorResolution {
    guard let simulatorPlatform = command.platform.simulatorPlatform else {
        throw PrivateHeaderKitCLIError.missingSimulatorResolution
    }
    let runner = ProcessRunner()
    let runtime = try await Simctl.findRuntime(
        platform: simulatorPlatform,
        version: command.version,
        build: command.build,
        runner: runner
    )
    let device = try await Simctl.resolveDevice(
        runtime: runtime,
        query: command.device,
        runner: runner
    )
    return PrivateHeaderKitSimulatorResolution(runtime: runtime, device: device)
}

func discoverPrivateHeaderKitInteractiveSources() async throws
    -> [PrivateHeaderKitInteractiveSource]
{
    try await discoverPrivateHeaderKitInteractiveSources(runner: ProcessRunner())
}

func discoverPrivateHeaderKitInteractiveSources(
    runner: CommandRunning
) async throws -> [PrivateHeaderKitInteractiveSource] {
    var sources = try await (Simctl.listRuntimesIfAvailable(runner: runner) ?? []).map {
        PrivateHeaderKitInteractiveSource(
            platform: .init(simulatorPlatform: $0.platform),
            version: $0.version,
            build: $0.build.isEmpty ? nil : $0.build,
            systemRoot: nil
        )
    }
    sources.append(try await currentMacOSInteractiveSource(runner: runner))
    return sources
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
    return PrivateHeaderKitInteractiveSource(
        platform: .macOS,
        version: version,
        build: build.isEmpty ? nil : build,
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
    if query == "all" {
        return
    }
    let entries = query.split(separator: ",", omittingEmptySubsequences: false)
    guard !entries.isEmpty,
          entries.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else {
        throw PrivateHeaderKitCLIError.invalidTargetQuery(query)
    }
}
