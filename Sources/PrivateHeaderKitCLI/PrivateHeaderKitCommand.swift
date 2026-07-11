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
            "iOS generation requires a resolved simulator runtime and device"
        }
    }
}

struct PrivateHeaderKitGenerateCommand: Equatable, Sendable {
    enum Platform: String, CaseIterable, Sendable {
        case iOS = "iOS"
        case macOS = "macOS"

        var corePlatform: PrivateHeaderGeneration.Source.Platform {
            switch self {
            case .iOS: .iOS
            case .macOS: .macOS
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

    var sourceDisplayName: String {
        let base = "\(platform.rawValue) \(version)"
        return build.map { "\(base) (\($0))" } ?? base
    }

    var resumeBehavior: PrivateHeaderGeneration.ResumeBehavior {
        switch continuationMode {
        case .resume: .resume
        case .fresh: .fresh
        case nil: .requireExplicitResume(resumeRequested: false)
        }
    }
}

struct PrivateHeaderKitGenerationRequest: Sendable {
    let source: PrivateHeaderGeneration.Source
    let output: PrivateHeaderGeneration.Output
    let options: PrivateHeaderGeneration.Options
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

typealias PrivateHeaderKitGenerationRunner = (
    PrivateHeaderKitGenerationRequest,
    @escaping PrivateHeaderGeneration.GenerationExecutor.ProgressReporter
) async throws -> PrivateHeaderGeneration.Result
typealias PrivateHeaderKitSimulatorResolver = (
    PrivateHeaderKitGenerateCommand
) throws -> PrivateHeaderKitSimulatorResolution
typealias PrivateHeaderKitOutputLogger = @Sendable (String) -> Void

func runPrivateHeaderKitCommand(
    _ args: [String],
    currentExecutableURL: URL? = Bundle.main.executableURL,
    generationRunner: @escaping PrivateHeaderKitGenerationRunner = runPrivateHeaderGeneration,
    simulatorResolver: @escaping PrivateHeaderKitSimulatorResolver = resolvePrivateHeaderKitSimulator,
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
    switch command {
    case .interactiveGenerate:
        exitCode = await runPrivateHeaderKitInteractiveGenerate(
            invokedProgramName: args.first ?? "privateheaderkit",
            currentExecutableURL: currentExecutableURL,
            generationRunner: generationRunner,
            simulatorResolver: simulatorResolver,
            sourceProvider: interactiveSourceProvider,
            outputBaseDirectoryProvider: interactiveOutputBaseDirectoryProvider,
            screenClearer: interactiveScreenClearer,
            inputReader: effectiveInputReader,
            inputFinalizer: inputFinalizer,
            outputLogger: outputLogger,
            errorLogger: errorLogger
        )
    case .generate(let generate):
        exitCode = await runPrivateHeaderKitGenerateCommand(
            generate,
            invokedProgramName: args.first ?? "privateheaderkit",
            currentExecutableURL: currentExecutableURL,
            generationRunner: generationRunner,
            simulatorResolver: simulatorResolver,
            outputLogger: outputLogger,
            errorLogger: errorLogger
        )
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
    generationRunner: PrivateHeaderKitGenerationRunner,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    preResolvedSimulatorResolution: PrivateHeaderKitSimulatorResolution? = nil,
    resumeBehaviorOverride: PrivateHeaderGeneration.ResumeBehavior? = nil,
    resultScreenClearer: PrivateHeaderKitInteractiveScreenClearer? = nil,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    errorLogger: @escaping PrivateHeaderKitOutputLogger
) async -> Int32 {
    do {
        let publicExecutableURL = privateHeaderKitExecutableURL(
            currentExecutableURL: currentExecutableURL,
            fallbackProgramName: invokedProgramName
        )
        try ensureSwiftPMBuildHelpersIfNeeded(
            publicExecutableURL: publicExecutableURL,
            includeSimulatorHelper: command.platform == .iOS && command.simulatorHelperPath == nil
        )
        let hostHelperExecutableURL = defaultRawDumpHelperURL(
            publicExecutableURL: publicExecutableURL
        )
        let simulatorResolution: PrivateHeaderKitSimulatorResolution?
        if command.platform == .iOS {
            simulatorResolution = try preResolvedSimulatorResolution ?? simulatorResolver(command)
            if let simulatorResolution {
                outputLogger(
                    "selected simulator: \(simulatorResolution.deviceName) "
                        + "(\(simulatorResolution.deviceUDID))"
                )
            }
        } else {
            simulatorResolution = nil
        }

        let request = try makePrivateHeaderGenerationRequest(
            from: command,
            hostHelperExecutableURL: hostHelperExecutableURL,
            simulatorResolution: simulatorResolution,
            resumeBehaviorOverride: resumeBehaviorOverride
        )
        let result = try await generationRunner(
            request,
            privateHeaderKitProgressReporter(outputLogger: outputLogger)
        )
        resultScreenClearer?()
        renderPrivateHeaderKitRunSummary(
            result.summary,
            sourceDisplayName: result.plan.source.label.displayName,
            targetQuery: command.targetQuery,
            title: "Generation completed",
            outputLogger: outputLogger
        )
        return 0
    } catch let error as PrivateHeaderGeneration.GenerationError {
        renderPrivateHeaderKitGenerationError(
            error,
            command: command,
            screenClearer: resultScreenClearer,
            outputLogger: errorLogger
        )
        return 2
    } catch {
        errorLogger("error: \(error)")
        return 2
    }
}

func runPrivateHeaderGeneration(
    request: PrivateHeaderKitGenerationRequest,
    progressReporter: @escaping PrivateHeaderGeneration.GenerationExecutor.ProgressReporter
) async throws -> PrivateHeaderGeneration.Result {
    try await PrivateHeaderGeneration.generatePrivateHeaders(
        source: request.source,
        output: request.output,
        options: request.options,
        rawDumpRunner: { invocation in
            let processResult = try ProcessRunner().runStreaming(
                invocation.command,
                env: invocation.environment,
                cwd: nil
            )
            return PrivateHeaderGeneration.RawDumping.Result(
                terminationStatus: processResult.status,
                wasKilled: processResult.wasKilled,
                failureSummary: processResult.lastLines.isEmpty
                    ? nil
                    : processResult.lastLines.joined(separator: "\n")
            )
        },
        progressReporter: progressReporter
    )
}

func makePrivateHeaderGenerationRequest(
    from command: PrivateHeaderKitGenerateCommand,
    hostHelperExecutableURL: URL,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?,
    resumeBehaviorOverride: PrivateHeaderGeneration.ResumeBehavior? = nil
) throws -> PrivateHeaderKitGenerationRequest {
    let source = try PrivateHeaderGeneration.Source(
        platform: command.platform.corePlatform,
        version: command.version,
        build: command.build
    )
    let output = PrivateHeaderGeneration.Output(
        baseDirectory: URL(fileURLWithPath: command.outputBaseDirectory, isDirectory: true)
    )
    let systemRoot = try effectiveSystemRootURL(
        from: command,
        simulatorResolution: simulatorResolution
    )
    let helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
        host: hostHelperExecutableURL,
        simulator: simulatorHelperURL(
            from: command,
            hostHelperExecutableURL: hostHelperExecutableURL
        )
    )
    let executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
    switch command.platform {
    case .macOS:
        executionMode = .host
    case .iOS:
        guard let simulatorResolution else {
            throw PrivateHeaderKitCLIError.missingSimulatorResolution
        }
        executionMode = .simulator(
            deviceUDID: simulatorResolution.deviceUDID,
            runtimeRoot: systemRoot.path
        )
    }
    let targetRequest: PrivateHeaderGeneration.TargetRequest =
        command.targetQuery == "all" ? .allAvailable : .query(command.targetQuery)
    let options = PrivateHeaderGeneration.Options(
        targetRequest: targetRequest,
        systemRoot: systemRoot,
        helperURLs: helperURLs,
        executionMode: executionMode,
        rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
            useSharedCache: true,
            preferRuntimeMetadata: true,
            helperEnvironment: ["PH_RUNTIME_ROOT": systemRoot.path]
        ),
        resumeBehavior: resumeBehaviorOverride ?? command.resumeBehavior
    )
    return PrivateHeaderKitGenerationRequest(source: source, output: output, options: options)
}

private func effectiveSystemRootURL(
    from command: PrivateHeaderKitGenerateCommand,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?
) throws -> URL {
    if let systemRoot = command.systemRoot {
        return URL(fileURLWithPath: systemRoot, isDirectory: true)
    }
    guard command.platform == .iOS, let simulatorResolution else {
        throw PrivateHeaderKitCLIError.missingSimulatorResolution
    }
    return URL(fileURLWithPath: simulatorResolution.resolvedRuntimeRoot, isDirectory: true)
}

private func simulatorHelperURL(
    from command: PrivateHeaderKitGenerateCommand,
    hostHelperExecutableURL: URL
) -> URL {
    if let simulatorHelperPath = command.simulatorHelperPath {
        return URL(
            fileURLWithPath: PathUtils.expandTilde(simulatorHelperPath),
            isDirectory: false
        )
    }
    return defaultSimulatorHelperURL(hostExecutableURL: hostHelperExecutableURL)
}

func defaultRawDumpHelperURL(publicExecutableURL: URL) -> URL {
    if swiftPMBuildProductLayout(for: publicExecutableURL) != nil {
        return publicExecutableURL.deletingLastPathComponent()
            .appendingPathComponent("privateheaderkit-raw-helper", isDirectory: false)
    }
    let cohortExecutable = publicExecutableURL.resolvingSymlinksInPath()
    return cohortExecutable.deletingLastPathComponent()
        .appendingPathComponent("privateheaderkit-raw-helper", isDirectory: false)
}

func defaultSimulatorHelperURL(hostExecutableURL: URL) -> URL {
    if let swiftPMURL = swiftPMBuildSimulatorHelperURL(
        hostBuildExecutableURL: hostExecutableURL,
        simulatorTriple: defaultSwiftPMIOSSimulatorTriple()
    ) {
        return swiftPMURL
    }
    let cohortHelper = hostExecutableURL.resolvingSymlinksInPath()
    return cohortHelper.deletingLastPathComponent()
        .appendingPathComponent("privateheaderkit-sim-helper", isDirectory: false)
}

func ensureSwiftPMBuildHelpersIfNeeded(
    publicExecutableURL: URL,
    includeSimulatorHelper: Bool,
    runner: CommandRunning = ProcessRunner(),
    simulatorTriple: String = defaultSwiftPMIOSSimulatorTriple()
) throws {
    guard let layout = swiftPMBuildProductLayout(for: publicExecutableURL) else {
        return
    }
    _ = try runner.runCapture(
        ["swift", "build", "-c", layout.configuration, "--product", "privateheaderkit-raw-helper"],
        env: nil,
        cwd: layout.repoRoot
    )
    guard includeSimulatorHelper else {
        return
    }
    let sdkPath = try runner.runCapture(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
        env: nil,
        cwd: nil
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try runner.runCapture(
        [
            "swift", "build", "-c", layout.configuration,
            "--sdk", sdkPath, "--triple", simulatorTriple,
            "--product", "privateheaderkit-sim-helper",
        ],
        env: nil,
        cwd: layout.repoRoot
    )
}

func swiftPMBuildSimulatorHelperURL(
    hostBuildExecutableURL: URL,
    simulatorTriple: String
) -> URL? {
    guard let layout = swiftPMBuildProductLayout(for: hostBuildExecutableURL) else {
        return nil
    }
    return layout.buildRoot
        .appendingPathComponent(simulatorTriple, isDirectory: true)
        .appendingPathComponent(layout.configuration, isDirectory: true)
        .appendingPathComponent("privateheaderkit-sim-helper", isDirectory: false)
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
    let configuration: String
    switch trailing.count {
    case 1 where isSwiftPMBuildConfiguration(trailing[0]):
        configuration = trailing[0]
    case 2 where isSwiftPMBuildConfiguration(trailing[1]):
        configuration = trailing[1]
    default:
        return nil
    }
    return SwiftPMBuildProductLayout(
        buildRoot: URL(
            fileURLWithPath: NSString.path(
                withComponents: Array(components.prefix(buildIndex + 1))
            )
        ),
        configuration: configuration
    )
}

private func isSwiftPMBuildConfiguration(_ value: String) -> Bool {
    value == "debug" || value == "release"
}

func defaultSwiftPMIOSSimulatorTriple() -> String {
    "\(defaultSwiftPMIOSSimulatorArchitecture())-apple-ios-simulator"
}

private func defaultSwiftPMIOSSimulatorArchitecture() -> String {
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
) throws -> PrivateHeaderKitSimulatorResolution {
    let runner = ProcessRunner()
    let runtime = try Simctl.findRuntime(
        version: command.version,
        build: command.build,
        runner: runner
    )
    let device = try Simctl.resolveDevice(
        runtime: runtime,
        query: command.device,
        runner: runner
    )
    return PrivateHeaderKitSimulatorResolution(runtime: runtime, device: device)
}

func discoverPrivateHeaderKitInteractiveSources() throws -> [PrivateHeaderKitInteractiveSource] {
    let runner = ProcessRunner()
    var sources = (try? Simctl.listRuntimes(runner: runner))?.map {
        PrivateHeaderKitInteractiveSource(
            platform: .iOS,
            version: $0.version,
            build: $0.build.isEmpty ? nil : $0.build,
            systemRoot: nil
        )
    } ?? []
    if let macOS = try? currentMacOSInteractiveSource(runner: runner) {
        sources.append(macOS)
    }
    return sources
}

private func currentMacOSInteractiveSource(
    runner: CommandRunning
) throws -> PrivateHeaderKitInteractiveSource {
    let version = try runner.runCapture(
        ["/usr/bin/sw_vers", "-productVersion"],
        env: nil,
        cwd: nil
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let build = try runner.runCapture(
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
