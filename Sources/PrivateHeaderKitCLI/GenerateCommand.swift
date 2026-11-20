import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTooling

/// Generates headers from a macOS system root or a Simulator runtime.
struct GenerateCommand: Sendable {
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

    struct Options: Equatable, Sendable {
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

    let options: Options
    /// The CLI executable, which the helpers are located from.
    let executableURL: URL
    let processRunner: any CommandRunning
    let console: Console

    var simulatorSession: SimulatorSession {
        SimulatorSession(processRunner: processRunner, console: console)
    }

    func run() async throws -> Int32 {
        let outcome = try await simulatorSession.run(for: options) { simulatorResolution in
            do {
                let request = try await makeRequest(simulatorResolution: simulatorResolution)
                do {
                    let preparedGeneration = try await PreparedGeneration(
                        request: request,
                        processRunner: processRunner,
                        recoveryReporter: console.error
                    )
                    return try await preparedGeneration.runReporting(
                        to: console,
                        executionOptions: options.executionOptions,
                        targetQuery: options.targetQuery
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
                        targetQuery: options.targetQuery,
                        screenClearer: nil,
                        outputLogger: console.error
                    )
                    return GenerationOutcome(
                        exitCode: cancellationRequested ? 130 : 2,
                        runStatus: runStatus
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                console.error("error: \(error)")
                return GenerationOutcome(exitCode: 2, runStatus: nil)
            }
        }
        renderPrivateHeaderKitCommandOutcome(
            outcome,
            outputLogger: console.output,
            errorLogger: console.error
        )
        return outcome.exitCode
    }

    /// Describes the generation that the options ask for. Locates the helpers and, in a
    /// package checkout, builds them.
    func makeRequest(simulatorResolution: SimulatorResolution?) async throws -> GenerationRequest {
        let effectiveSource = try Self.effectiveSource(
            for: options,
            simulatorResolution: simulatorResolution
        )
        let helperPlan = try await HelperPlan.resolve(
            executableURL: executableURL,
            simulatorHelperPath: options.simulatorHelperPath,
            simulatorPlatform: options.platform.simulatorPlatform,
            processRunner: processRunner
        )
        try await helperPlan.buildHelpers(using: processRunner)
        return try Self.makeRequest(
            for: options,
            effectiveSource: effectiveSource,
            helperURLs: helperPlan.helperURLs,
            simulatorResolution: simulatorResolution
        )
    }

    static func makeRequest(
        for options: Options,
        helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
        simulatorResolution: SimulatorResolution?
    ) throws -> GenerationRequest {
        try makeRequest(
            for: options,
            effectiveSource: effectiveSource(for: options, simulatorResolution: simulatorResolution),
            helperURLs: helperURLs,
            simulatorResolution: simulatorResolution
        )
    }

    static func validateTargetQuery(_ query: String) throws {
        _ = try PrivateHeaderGeneration.TargetQuery(commaSeparated: query)
    }

    private static func makeRequest(
        for options: Options,
        effectiveSource: EffectiveSource,
        helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
        simulatorResolution: SimulatorResolution?
    ) throws -> GenerationRequest {
        let source = effectiveSource.source
        let output = PrivateHeaderGeneration.Output(
            baseDirectory: URL(fileURLWithPath: options.outputBaseDirectory, isDirectory: true)
        )
        let executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
        if options.platform.simulatorPlatform == nil {
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
            options.targetQuery == "all" ? .allAvailable : .query(options.targetQuery)
        let generationOptions = PrivateHeaderGeneration.Options(
            targetRequest: targetRequest,
            systemRoot: effectiveSource.systemRoot,
            helperURLs: helperURLs,
            executionMode: executionMode,
            rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
                useSharedCache: effectiveSource.useSharedCache,
                preferRuntimeMetadata: options.preferRuntimeMetadata,
                helperEnvironment: ["PH_RUNTIME_ROOT": effectiveSource.systemRoot.path]
            ),
            executionOptions: options.executionOptions,
            producerVersion: PrivateHeaderKitBuildInfo.version
        )
        return GenerationRequest(source: source, output: output, options: generationOptions)
    }

    private static func effectiveSource(
        for options: Options,
        simulatorResolution: SimulatorResolution?
    ) throws -> EffectiveSource {
        if let systemRoot = options.systemRoot {
            let systemRootURL = canonicalDirectoryURL(path: systemRoot)
            let build: String?
            let metadataIsSeed: Bool
            let useSharedCache: Bool
            if options.platform.simulatorPlatform == nil {
                build = options.build
                metadataIsSeed = try RuntimeReleaseMetadata.isSeed(in: systemRootURL, layout: .macOS)
                useSharedCache = systemRootURL.path == "/"
            } else {
                guard let simulatorResolution else {
                    throw PrivateHeaderKitCLIError.missingSimulatorResolution
                }
                let identifiesSelectedRuntime = systemRootURL == canonicalDirectoryURL(
                    path: simulatorResolution.resolvedRuntimeRoot
                )
                build = options.build
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
            return try validatedEffectiveSource(
                options: options,
                build: build,
                systemRoot: systemRootURL,
                metadataIsSeed: metadataIsSeed,
                useSharedCache: useSharedCache
            )
        }
        guard options.platform.simulatorPlatform != nil, let simulatorResolution else {
            throw PrivateHeaderKitCLIError.missingSimulatorResolution
        }
        return try validatedEffectiveSource(
            options: options,
            build: options.build ?? simulatorResolution.runtimeBuild,
            systemRoot: canonicalDirectoryURL(path: simulatorResolution.resolvedRuntimeRoot),
            metadataIsSeed: simulatorResolution.metadataIsSeed,
            useSharedCache: true
        )
    }

    private static func validatedEffectiveSource(
        options: Options,
        build: String?,
        systemRoot: URL,
        metadataIsSeed: Bool,
        useSharedCache: Bool
    ) throws -> EffectiveSource {
        EffectiveSource(
            source: try PrivateHeaderGeneration.Source(
                platform: options.platform.corePlatform,
                version: options.version,
                build: build,
                metadataIsSeed: metadataIsSeed
            ),
            systemRoot: systemRoot,
            useSharedCache: useSharedCache
        )
    }
}

/// The source identity and system root a generation reads, after the release metadata
/// and the resolved Simulator runtime are applied to the options.
private struct EffectiveSource {
    let source: PrivateHeaderGeneration.Source
    let systemRoot: URL
    let useSharedCache: Bool
}

/// The directory at `path` with symbolic links resolved, so that two spellings of one
/// system root compare equal.
func canonicalDirectoryURL(path: String) -> URL {
    URL(fileURLWithPath: path, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
}
