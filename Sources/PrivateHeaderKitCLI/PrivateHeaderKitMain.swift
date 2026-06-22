import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitInstall
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct PrivateHeaderKitMain {
    static func main() async {
        exit(await runPrivateHeaderKitCommand(CommandLine.arguments))
    }
}

enum PrivateHeaderKitCommand: Equatable {
    case help
    case generateHelp
    case interactiveGenerate
    case install([String])
    case generate(PrivateHeaderKitGenerateCommand)
}

struct PrivateHeaderKitGenerationRequest: Sendable {
    let source: PrivateHeaderGeneration.Source
    let output: PrivateHeaderGeneration.Output
    let options: PrivateHeaderGeneration.Options

    var sourceDisplayName: String {
        source.label.displayName
    }

    var sourceDirectoryName: String {
        source.label.directoryName
    }

    var artifactBaseDirectory: URL {
        output.artifactBaseDirectory
    }

    var stateBaseDirectory: URL {
        output.stateBaseDirectory
    }

    var systemRoot: URL? {
        options.systemRoot
    }

    var targetQuery: String? {
        guard case .query(let query) = options.targetRequest else {
            return nil
        }
        return query
    }

    var resumeRequested: Bool? {
        guard case .requireExplicitResume(let resumeRequested) = options.resumeBehavior else {
            return nil
        }
        return resumeRequested
    }

    var startsFresh: Bool {
        guard case .fresh = options.resumeBehavior else {
            return false
        }
        return true
    }

    var hostHelperURL: URL? {
        options.helperURLs?.host
    }

    var simulatorHelperURL: URL? {
        options.helperURLs?.simulator
    }

    var usesHostExecution: Bool {
        guard case .host = options.executionMode else {
            return false
        }
        return true
    }

    var simulatorDeviceUDID: String? {
        guard case .simulator(let deviceUDID, _) = options.executionMode else {
            return nil
        }
        return deviceUDID
    }

    var simulatorRuntimeRoot: String? {
        guard case .simulator(_, let runtimeRoot) = options.executionMode else {
            return nil
        }
        return runtimeRoot
    }

    var usesSharedCache: Bool {
        options.rawDumpingOptions.useSharedCache
    }

    var prefersRuntimeMetadata: Bool {
        options.rawDumpingOptions.preferRuntimeMetadata
    }

    var helperEnvironment: [String: String] {
        options.rawDumpingOptions.helperEnvironment
    }
}

struct PrivateHeaderKitGenerationSummary: Equatable, Sendable {
    let sourceDisplayName: String
    let artifactDirectory: URL
    let manifestURL: URL
    let runRecordURL: URL
    let runID: String
    let generatedTargetCount: Int
    let skippedTargetCount: Int?

    init(
        sourceDisplayName: String,
        artifactDirectory: URL,
        manifestURL: URL,
        runRecordURL: URL,
        runID: String,
        generatedTargetCount: Int,
        skippedTargetCount: Int? = nil
    ) {
        self.sourceDisplayName = sourceDisplayName
        self.artifactDirectory = artifactDirectory
        self.manifestURL = manifestURL
        self.runRecordURL = runRecordURL
        self.runID = runID
        self.generatedTargetCount = generatedTargetCount
        self.skippedTargetCount = skippedTargetCount
    }

    init(result: PrivateHeaderGeneration.Result) {
        self.init(
            sourceDisplayName: result.plan.source.label.displayName,
            artifactDirectory: result.artifactDirectory,
            manifestURL: result.manifestURL,
            runRecordURL: result.runRecordURL,
            runID: result.runID,
            generatedTargetCount: result.generatedTargets.count,
            skippedTargetCount: Self.skippedTargetCount(from: result.runRecordURL)
        )
    }

    private static func skippedTargetCount(from runRecordURL: URL) -> Int? {
        guard
            let data = try? Data(contentsOf: runRecordURL),
            let runRecord = try? JSONDecoder().decode(TargetResultsRecord.self, from: data)
        else {
            return nil
        }
        return runRecord.targetResults.filter { $0.status == "skipped" }.count
    }

    private struct TargetResultsRecord: Decodable {
        let targetResults: [TargetRecord]
    }

    private struct TargetRecord: Decodable {
        let status: String
    }
}

typealias PrivateHeaderKitGenerationRunner = (
    PrivateHeaderKitGenerationRequest
) async throws -> PrivateHeaderKitGenerationSummary

struct PrivateHeaderKitGenerateCommand: Equatable, Sendable {
    enum Platform: String, Sendable {
        case iOS = "iOS"
        case macOS = "macOS"
    }

    let platform: Platform
    let version: String
    let build: String?
    let systemRoot: String?
    let outputBaseDirectory: String
    let targetQuery: String
    let resume: Bool
    let device: String?
    let simulatorHelperPath: String?

    var sourceDisplayName: String {
        sourceLabel(separator: " ")
    }

    var sourceDirectoryName: String {
        sourceLabel(separator: "")
    }

    var artifactDirectory: URL {
        URL(fileURLWithPath: outputBaseDirectory, isDirectory: true)
            .appendingPathComponent(sourceDirectoryName, isDirectory: true)
    }

    var stateDirectory: URL {
        URL(fileURLWithPath: outputBaseDirectory, isDirectory: true)
            .appendingPathComponent(".state", isDirectory: true)
            .appendingPathComponent(sourceDirectoryName, isDirectory: true)
    }

    var manifestPath: String {
        stateDirectory.appendingPathComponent("manifest.json", isDirectory: false).path
    }

    private func sourceLabel(separator: String) -> String {
        let baseName = "\(platform.rawValue)\(separator)\(version)"
        if let build {
            let buildSeparator = separator.isEmpty ? "" : " "
            return "\(baseName)\(buildSeparator)(\(build))"
        }
        return baseName
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

typealias PrivateHeaderKitSimulatorResolver = (
    PrivateHeaderKitGenerateCommand
) throws -> PrivateHeaderKitSimulatorResolution

typealias PrivateHeaderKitInputReader = () -> String?
typealias PrivateHeaderKitInteractiveScreenClearer = () -> Void

struct PrivateHeaderKitInteractiveSource: Equatable, Sendable {
    let platform: PrivateHeaderKitGenerateCommand.Platform
    let version: String
    let build: String?
    let systemRoot: String?

    var displayName: String {
        let baseName = "\(platform.rawValue) \(version)"
        if let build, !build.isEmpty {
            return "\(baseName) (\(build))"
        }
        return baseName
    }
}

private enum PrivateHeaderKitInteractiveTargetMode: Equatable {
    case all
    case specific
}

private enum PrivateHeaderKitInteractiveAction: Equatable {
    case continuePrevious
    case restart
}

private enum PrivateHeaderKitInteractiveStep {
    case source
    case targetMode
    case targetInput
}

private enum PrivateHeaderKitInteractiveNavigation: Error {
    case back
}

typealias PrivateHeaderKitInteractiveSourceProvider = () throws -> [PrivateHeaderKitInteractiveSource]

private let legacyPublicCommandNames: Set<String> = [
    "privateheaderkit-dump",
    "headerdump",
    "headerdump-sim",
]

enum PrivateHeaderKitCLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case legacyCommand(String)
    case unknownOption(String)
    case duplicateOption(String)
    case missingRequiredOption(String)
    case missingValue(String)
    case unexpectedValue(String)
    case unexpectedArgument(String)
    case invalidPlatform(String)
    case emptyOptionValue(String)
    case invalidSourceComponent(option: String, value: String)
    case invalidTargetQuery(String)
    case missingSimulatorResolution

    var description: String {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .legacyCommand(let command):
            return "\(command) is no longer a user-facing command; use privateheaderkit instead"
        case .unknownOption(let option):
            return "unknown option: \(option)"
        case .duplicateOption(let option):
            return "duplicate option: \(option)"
        case .missingRequiredOption(let option):
            return "missing required option: \(option)"
        case .missingValue(let option):
            return "missing value for option: \(option)"
        case .unexpectedValue(let option):
            return "unexpected value for flag: \(option)"
        case .unexpectedArgument(let argument):
            return "unexpected argument: \(argument)"
        case .invalidPlatform(let value):
            return "invalid platform: \(value); expected iOS or macOS"
        case .emptyOptionValue(let option):
            return "empty value for option: \(option)"
        case .invalidSourceComponent(let option, let value):
            return "\(option) is not safe as a source label path component: \(value)"
        case .invalidTargetQuery(let value):
            return "target query must be a comma-separated list without empty entries: \(value)"
        case .missingSimulatorResolution:
            return "iOS generation requires a resolved simulator runtime and device"
        }
    }
}

func runPrivateHeaderKitCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentExecutableURL: URL? = Bundle.main.executableURL,
    generationRunner: @escaping PrivateHeaderKitGenerationRunner = runPrivateHeaderGeneration,
    simulatorResolver: @escaping PrivateHeaderKitSimulatorResolver = resolvePrivateHeaderKitSimulator,
    interactiveSourceProvider: @escaping PrivateHeaderKitInteractiveSourceProvider =
        discoverPrivateHeaderKitInteractiveSources,
    interactiveOutputBaseDirectoryProvider: @escaping () -> String = defaultInteractiveOutputBaseDirectory,
    interactiveScreenClearer: @escaping PrivateHeaderKitInteractiveScreenClearer = clearInteractiveScreen,
    inputReader: @escaping PrivateHeaderKitInputReader = readInteractiveLine,
    outputLogger: (String) -> Void = logCLIOutput,
    errorLogger: (String) -> Void = logCLIError
) async -> Int32 {
    do {
        switch try parsePrivateHeaderKitCommand(args) {
        case .help:
            printPrivateHeaderKitUsage()
            return 0
        case .generateHelp:
            printPrivateHeaderKitGenerateUsage()
            return 0
        case .interactiveGenerate:
            return await runPrivateHeaderKitInteractiveGenerate(
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                generationRunner: generationRunner,
                simulatorResolver: simulatorResolver,
                sourceProvider: interactiveSourceProvider,
                outputBaseDirectoryProvider: interactiveOutputBaseDirectoryProvider,
                screenClearer: interactiveScreenClearer,
                inputReader: inputReader,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
        case .install(let installArgs):
            return runInstallCommand(installArgs, environment: environment)
        case .generate(let command):
            return await runPrivateHeaderKitGenerateCommand(
                command,
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                generationRunner: generationRunner,
                simulatorResolver: simulatorResolver,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
        }
    } catch let error as PrivateHeaderKitCLIError {
        errorLogger("error: \(error.description)")
        errorLogger("run `privateheaderkit --help` for usage")
        return 1
    } catch {
        errorLogger("error: \(error)")
        errorLogger("run `privateheaderkit --help` for usage")
        return 1
    }
}

private func runPrivateHeaderKitInteractiveGenerate(
    invokedProgramName: String,
    currentExecutableURL: URL?,
    generationRunner: PrivateHeaderKitGenerationRunner,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    sourceProvider: PrivateHeaderKitInteractiveSourceProvider,
    outputBaseDirectoryProvider: () -> String,
    screenClearer: @escaping PrivateHeaderKitInteractiveScreenClearer,
    inputReader: PrivateHeaderKitInputReader,
    outputLogger: (String) -> Void,
    errorLogger: (String) -> Void
) async -> Int32 {
    do {
        let sources = try sourceProvider()
        guard !sources.isEmpty else {
            errorLogger("error: no available generation sources found")
            return 2
        }

        let outputBaseDirectory = outputBaseDirectoryProvider()
        var step = PrivateHeaderKitInteractiveStep.source
        var source: PrivateHeaderKitInteractiveSource?

        while true {
            switch step {
            case .source:
                renderInteractiveSourceScreen(
                    sources: sources,
                    screenClearer: screenClearer,
                    outputLogger: outputLogger
                )
                do {
                    source = try promptIndexedSelection(
                        prompt: "Select source:",
                        values: sources,
                        inputReader: inputReader,
                        outputLogger: outputLogger
                    )
                    step = .targetMode
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    outputLogger("Cancelled.")
                    return 1
                }

            case .targetMode:
                guard let selectedSource = source else {
                    step = .source
                    continue
                }
                renderInteractiveTargetModeScreen(
                    source: selectedSource,
                    screenClearer: screenClearer,
                    outputLogger: outputLogger
                )
                let selectedTargetMode: PrivateHeaderKitInteractiveTargetMode
                do {
                    selectedTargetMode = try promptIndexedSelection(
                        prompt: "Select targets:",
                        values: [
                            PrivateHeaderKitInteractiveTargetMode.all,
                            PrivateHeaderKitInteractiveTargetMode.specific,
                        ],
                        inputReader: inputReader,
                        outputLogger: outputLogger
                    )
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    step = .source
                    continue
                }

                switch selectedTargetMode {
                case .all:
                    do {
                        return try await runPrivateHeaderKitInteractiveSelection(
                            source: selectedSource,
                            outputBaseDirectory: outputBaseDirectory,
                            targetQuery: "all",
                            invokedProgramName: invokedProgramName,
                            currentExecutableURL: currentExecutableURL,
                            generationRunner: generationRunner,
                            simulatorResolver: simulatorResolver,
                            screenClearer: screenClearer,
                            inputReader: inputReader,
                            outputLogger: outputLogger,
                            errorLogger: errorLogger
                        )
                    } catch PrivateHeaderKitInteractiveNavigation.back {
                        step = .targetMode
                        continue
                    }
                case .specific:
                    step = .targetInput
                }

            case .targetInput:
                guard let selectedSource = source else {
                    step = .source
                    continue
                }
                renderInteractiveTargetInputScreen(
                    source: selectedSource,
                    screenClearer: screenClearer,
                    outputLogger: outputLogger
                )
                let targetQuery: String
                do {
                    targetQuery = try promptRequiredValue(
                        prompt: "Targets:",
                        inputReader: inputReader,
                        outputLogger: outputLogger
                    )
                    try validateTargetQuery(targetQuery)
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    step = .targetMode
                    continue
                }

                do {
                    return try await runPrivateHeaderKitInteractiveSelection(
                        source: selectedSource,
                        outputBaseDirectory: outputBaseDirectory,
                        targetQuery: targetQuery,
                        invokedProgramName: invokedProgramName,
                        currentExecutableURL: currentExecutableURL,
                        generationRunner: generationRunner,
                        simulatorResolver: simulatorResolver,
                        screenClearer: screenClearer,
                        inputReader: inputReader,
                        outputLogger: outputLogger,
                        errorLogger: errorLogger
                    )
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    step = .targetInput
                    continue
                }
            }
        }
    } catch PrivateHeaderKitInteractiveNavigation.back {
        outputLogger("Cancelled.")
        return 1
    } catch let error as PrivateHeaderKitCLIError {
        errorLogger("error: \(error.description)")
        return 1
    } catch {
        errorLogger("error: \(error)")
        return 1
    }
}

private func runPrivateHeaderKitInteractiveSelection(
    source: PrivateHeaderKitInteractiveSource,
    outputBaseDirectory: String,
    targetQuery: String,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    generationRunner: PrivateHeaderKitGenerationRunner,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    screenClearer: @escaping PrivateHeaderKitInteractiveScreenClearer,
    inputReader: PrivateHeaderKitInputReader,
    outputLogger: (String) -> Void,
    errorLogger: (String) -> Void
) async throws -> Int32 {
    do {
        let command = PrivateHeaderKitGenerateCommand(
            platform: source.platform,
            version: source.version,
            build: source.build,
            systemRoot: source.systemRoot,
            outputBaseDirectory: outputBaseDirectory,
            targetQuery: targetQuery,
            resume: false,
            device: nil,
            simulatorHelperPath: nil
        )
        let resumeDecision = try interactiveResumeDecision(
            for: command,
            invokedProgramName: invokedProgramName,
            currentExecutableURL: currentExecutableURL,
            simulatorResolver: simulatorResolver,
            screenClearer: screenClearer,
            inputReader: inputReader,
            outputLogger: outputLogger
        )

        return await runPrivateHeaderKitGenerateCommand(
            command,
            invokedProgramName: invokedProgramName,
            currentExecutableURL: currentExecutableURL,
            generationRunner: generationRunner,
            simulatorResolver: simulatorResolver,
            preResolvedSimulatorResolution: resumeDecision.simulatorResolution,
            resumeBehaviorOverride: resumeDecision.resumeBehavior,
            resultScreenClearer: screenClearer,
            outputLogger: outputLogger,
            errorLogger: errorLogger
        )
    } catch PrivateHeaderKitInteractiveNavigation.back {
        throw PrivateHeaderKitInteractiveNavigation.back
    } catch let error as PrivateHeaderKitCLIError {
        errorLogger("error: \(error.description)")
        return 1
    } catch {
        errorLogger("error: \(error)")
        return 1
    }
}

private func defaultInteractiveOutputBaseDirectory() -> String {
    PathUtils.expandTilde("~/PrivateHeaderKit")
}

private func renderInteractiveSourceScreen(
    sources: [PrivateHeaderKitInteractiveSource],
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: (String) -> Void
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("Generate private headers from an installed runtime or this Mac.")
    outputLogger("")
    outputLogger("Step 1 of 3: Source")
    outputLogger("Choose where PrivateHeaderKit reads system binaries from.")
    outputLogger("iOS sources are Simulator runtimes. macOS is this Mac's system.")
    outputLogger("")
    outputLogger("Available sources:")
    renderInteractiveSourceSection(
        title: "iOS Simulator Runtimes",
        sources: sources,
        platform: .iOS,
        outputLogger: outputLogger
    )
    renderInteractiveSourceSection(
        title: "macOS",
        sources: sources,
        platform: .macOS,
        outputLogger: outputLogger
    )
}

private func renderInteractiveSourceSection(
    title: String,
    sources: [PrivateHeaderKitInteractiveSource],
    platform: PrivateHeaderKitGenerateCommand.Platform,
    outputLogger: (String) -> Void
) {
    let indexedSources = sources.enumerated().filter { $0.element.platform == platform }
    guard !indexedSources.isEmpty else {
        return
    }
    outputLogger("  \(title)")
    for (offset, source) in indexedSources {
        outputLogger("    [\(offset + 1)] \(source.displayName)")
    }
    outputLogger("")
}

private func renderInteractiveTargetModeScreen(
    source: PrivateHeaderKitInteractiveSource,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: (String) -> Void
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 2 of 3: Targets")
    outputLogger("Source: \(source.displayName)")
    outputLogger("")
    outputLogger("  [1] All targets")
    outputLogger("      Generate every discoverable target.")
    outputLogger("  [2] Specific targets")
    outputLogger("      Enter target names separated by commas.")
}

private func renderInteractiveTargetInputScreen(
    source: PrivateHeaderKitInteractiveSource,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: (String) -> Void
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 2 of 3: Specific targets")
    outputLogger("Source: \(source.displayName)")
    outputLogger("")
    outputLogger("Enter targets separated by commas.")
    outputLogger("Examples:")
    outputLogger("  SwiftUI,UIKit")
    outputLogger("  SpringBoardServices")
    outputLogger("  /System/Library/PrivateFrameworks/SpringBoardServices.framework")
    outputLogger("  /usr/lib/libobjc.A.dylib")
    outputLogger("")
}

private func renderInteractiveResumeScreen(
    source: PrivateHeaderKitGenerateCommand,
    summary: PrivateHeaderGeneration.ResumeSummary,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: (String) -> Void
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 3 of 3: Continue or restart")
    outputLogger("An unfinished run was found.")
    outputLogger("")
    outputLogger("Source: \(source.sourceDisplayName)")
    outputLogger("Targets: \(source.targetQuery)")
    outputLogger("Remaining: \(summary.counts.unfinished) of \(summary.counts.total)")
    if let latestRunID = summary.latestRunID {
        outputLogger("Previous run: \(latestRunID)")
    }
    outputLogger("")
    outputLogger("  [1] Continue")
    outputLogger("  [2] Restart")
}

private func interactiveResumeDecision(
    for command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    inputReader: PrivateHeaderKitInputReader,
    outputLogger: (String) -> Void
) throws -> PrivateHeaderKitInteractiveResumeDecision {
    guard FileManager.default.fileExists(atPath: command.manifestPath) else {
        return PrivateHeaderKitInteractiveResumeDecision(
            resumeBehavior: .fresh,
            simulatorResolution: nil
        )
    }

    let publicExecutableURL = privateHeaderKitExecutableURL(
        currentExecutableURL: currentExecutableURL,
        fallbackProgramName: invokedProgramName
    )
    let hostHelperExecutableURL = defaultRawDumpHelperURL(publicExecutableURL: publicExecutableURL)
    let simulatorResolution: PrivateHeaderKitSimulatorResolution?
    if command.platform == .iOS {
        simulatorResolution = try simulatorResolver(command)
    } else {
        simulatorResolution = nil
    }
    let request = try makePrivateHeaderGenerationRequest(
        from: command,
        hostHelperExecutableURL: hostHelperExecutableURL,
        simulatorResolution: simulatorResolution,
        resumeBehaviorOverride: .requireExplicitResume(resumeRequested: false)
    )
    guard let summary = try PrivateHeaderGeneration.availableResumeSummary(
        source: request.source,
        output: request.output,
        options: request.options
    ) else {
        return PrivateHeaderKitInteractiveResumeDecision(
            resumeBehavior: .fresh,
            simulatorResolution: simulatorResolution
        )
    }

    renderInteractiveResumeScreen(
        source: command,
        summary: summary,
        screenClearer: screenClearer,
        outputLogger: outputLogger
    )
    let action = try promptIndexedSelection(
        prompt: "Select action:",
        values: [
            PrivateHeaderKitInteractiveAction.continuePrevious,
            PrivateHeaderKitInteractiveAction.restart,
        ],
        inputReader: inputReader,
        outputLogger: outputLogger
    )
    return PrivateHeaderKitInteractiveResumeDecision(
        resumeBehavior: action == .continuePrevious ? .resume : .fresh,
        simulatorResolution: simulatorResolution
    )
}

private struct PrivateHeaderKitInteractiveResumeDecision {
    let resumeBehavior: PrivateHeaderGeneration.ResumeBehavior
    let simulatorResolution: PrivateHeaderKitSimulatorResolution?
}

private struct PrivateHeaderKitGenerationResultScreen {
    let title: String
    let sourceDisplayName: String
    let targetQuery: String
    let counts: Counts
    let artifactDirectory: URL
    let stateDirectory: URL
    let manifestURL: URL
    let runRecordURL: URL
    let runID: String
    let failedTargets: [FailedTarget]

    struct Counts: Equatable {
        let generated: Int
        let partial: Int
        let failed: Int
        let skipped: Int
    }

    struct FailedTarget: Equatable {
        let displayName: String
        let summaryLines: [String]
    }
}

private func runPrivateHeaderKitGenerateCommand(
    _ command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    generationRunner: PrivateHeaderKitGenerationRunner,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    preResolvedSimulatorResolution: PrivateHeaderKitSimulatorResolution? = nil,
    resumeBehaviorOverride: PrivateHeaderGeneration.ResumeBehavior? = nil,
    resultScreenClearer: PrivateHeaderKitInteractiveScreenClearer? = nil,
    outputLogger: (String) -> Void,
    errorLogger: (String) -> Void
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
        let hostHelperExecutableURL = defaultRawDumpHelperURL(publicExecutableURL: publicExecutableURL)
        let simulatorResolution: PrivateHeaderKitSimulatorResolution?
        if command.platform == .iOS {
            simulatorResolution = try preResolvedSimulatorResolution ?? simulatorResolver(command)
            if let simulatorResolution {
                logPrivateHeaderKitSimulatorSelection(
                    simulatorResolution,
                    command: command,
                    outputLogger: outputLogger
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
        let summary = try await generationRunner(request)
        resultScreenClearer?()
        renderPrivateHeaderGenerationResultScreen(
            successResultScreen(command: command, summary: summary),
            outputLogger: outputLogger
        )
        return 0
    } catch let error as PrivateHeaderGeneration.GenerationError {
        if case .runFailed(let runID, let failedTargetIDs) = error {
            resultScreenClearer?()
            renderPrivateHeaderGenerationResultScreen(
                failedResultScreen(
                    command: command,
                    runID: runID,
                    failedTargetIDs: failedTargetIDs
                ),
                outputLogger: errorLogger
            )
        } else {
            errorLogger("error: \(error.description)")
        }
        if case .resumeRequired = error {
            errorLogger("rerun with `--resume` to continue the unfinished generation state")
        }
        return 2
    } catch {
        errorLogger("error: \(error)")
        return 2
    }
}

private func successResultScreen(
    command: PrivateHeaderKitGenerateCommand,
    summary: PrivateHeaderKitGenerationSummary
) -> PrivateHeaderKitGenerationResultScreen {
    PrivateHeaderKitGenerationResultScreen(
        title: "Generation completed",
        sourceDisplayName: summary.sourceDisplayName,
        targetQuery: formattedTargetQuery(command.targetQuery),
        counts: PrivateHeaderKitGenerationResultScreen.Counts(
            generated: summary.generatedTargetCount,
            partial: 0,
            failed: 0,
            skipped: summary.skippedTargetCount ?? 0
        ),
        artifactDirectory: summary.artifactDirectory,
        stateDirectory: summary.manifestURL.deletingLastPathComponent(),
        manifestURL: summary.manifestURL,
        runRecordURL: summary.runRecordURL,
        runID: summary.runID,
        failedTargets: []
    )
}

private func failedResultScreen(
    command: PrivateHeaderKitGenerateCommand,
    runID: String,
    failedTargetIDs: [String]
) -> PrivateHeaderKitGenerationResultScreen {
    let manifestURL = URL(fileURLWithPath: command.manifestPath, isDirectory: false)
    let runRecordURL = command.stateDirectory
        .appendingPathComponent("runs/\(runID)/run.json", isDirectory: false)
    let manifest = readGenerationManifest(at: manifestURL)
    let runRecord = readGenerationRunRecord(at: runRecordURL)

    return PrivateHeaderKitGenerationResultScreen(
        title: "Generation completed with failures",
        sourceDisplayName: command.sourceDisplayName,
        targetQuery: formattedTargetQuery(command.targetQuery),
        counts: runRecord.map(resultCounts(from:))
            ?? manifest.map(resultCounts(from:))
            ?? PrivateHeaderKitGenerationResultScreen.Counts(
                generated: 0,
                partial: 0,
                failed: failedTargetIDs.count,
                skipped: 0
            ),
        artifactDirectory: command.artifactDirectory,
        stateDirectory: command.stateDirectory,
        manifestURL: manifestURL,
        runRecordURL: runRecordURL,
        runID: runID,
        failedTargets: failedTargets(failedTargetIDs, manifest: manifest)
    )
}

private func readGenerationManifest(at url: URL) -> PrivateHeaderGeneration.Manifest? {
    guard let data = try? Data(contentsOf: url) else {
        return nil
    }
    return try? PrivateHeaderGeneration.StateJSON.decode(
        PrivateHeaderGeneration.Manifest.self,
        from: data
    )
}

private func readGenerationRunRecord(at url: URL) -> PrivateHeaderGeneration.RunRecord? {
    guard let data = try? Data(contentsOf: url) else {
        return nil
    }
    return try? PrivateHeaderGeneration.StateJSON.decode(
        PrivateHeaderGeneration.RunRecord.self,
        from: data
    )
}

private func resultCounts(
    from runRecord: PrivateHeaderGeneration.RunRecord
) -> PrivateHeaderKitGenerationResultScreen.Counts {
    var generated = 0
    var partial = 0
    var failed = 0
    var skipped = 0

    for target in runRecord.targetResults {
        switch target.status {
        case .completed:
            generated += 1
        case .partial:
            partial += 1
        case .failed, .interrupted, .commitFailed:
            failed += 1
        case .skipped:
            skipped += 1
        case .pending, .running:
            break
        }
    }

    return PrivateHeaderKitGenerationResultScreen.Counts(
        generated: generated,
        partial: partial,
        failed: failed,
        skipped: skipped
    )
}

private func resultCounts(
    from manifest: PrivateHeaderGeneration.Manifest
) -> PrivateHeaderKitGenerationResultScreen.Counts {
    var generated = 0
    var partial = 0
    var failed = 0

    for target in manifest.targets {
        switch target.status {
        case .completed:
            generated += 1
        case .partial:
            partial += 1
        case .failed, .interrupted, .commitFailed, .stale:
            failed += 1
        }
    }

    return PrivateHeaderKitGenerationResultScreen.Counts(
        generated: generated,
        partial: partial,
        failed: failed,
        skipped: 0
    )
}

private func failedTargets(
    _ failedTargetIDs: [String],
    manifest: PrivateHeaderGeneration.Manifest?
) -> [PrivateHeaderKitGenerationResultScreen.FailedTarget] {
    var targetsByID: [String: PrivateHeaderGeneration.TargetRecord] = [:]
    for target in manifest?.targets ?? [] {
        targetsByID[target.id] = target
    }

    return failedTargetIDs.prefix(20).map { targetID in
        guard let target = targetsByID[targetID] else {
            return PrivateHeaderKitGenerationResultScreen.FailedTarget(
                displayName: targetID,
                summaryLines: ["no failure summary recorded"]
            )
        }
        return PrivateHeaderKitGenerationResultScreen.FailedTarget(
            displayName: target.displayName,
            summaryLines: failureSummaryLines(from: target.failureSummary)
        )
    }
}

private func renderPrivateHeaderGenerationResultScreen(
    _ screen: PrivateHeaderKitGenerationResultScreen,
    outputLogger: (String) -> Void
) {
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger(screen.title)
    outputLogger("")
    outputLogger("Source")
    outputLogger("  \(screen.sourceDisplayName)")
    outputLogger("")
    outputLogger("Targets")
    outputLogger("  \(screen.targetQuery)")
    outputLogger("")
    outputLogger("Result")
    outputLogger(formatResultMetric("Generated", screen.counts.generated))
    if screen.counts.partial > 0 {
        outputLogger(formatResultMetric("Partial", screen.counts.partial))
    }
    outputLogger(formatResultMetric("Failed", screen.counts.failed))
    outputLogger(formatResultMetric("Skipped", screen.counts.skipped))

    if !screen.failedTargets.isEmpty {
        outputLogger("")
        outputLogger("Failed targets")
        for (index, target) in screen.failedTargets.enumerated() {
            outputLogger("  [\(index + 1)] \(target.displayName)")
            for line in target.summaryLines {
                outputLogger("      \(line)")
            }
            if index < screen.failedTargets.count - 1 {
                outputLogger("")
            }
        }
    }

    outputLogger("")
    outputLogger("Output")
    outputLogger(formatResultField("Headers", screen.artifactDirectory.path))
    outputLogger(formatResultField("State", screen.stateDirectory.path))
    outputLogger("")
    outputLogger("Run")
    outputLogger(formatResultField("ID", shortenedRunID(screen.runID)))
    outputLogger(formatResultField(
        "Manifest",
        relativePath(screen.manifestURL, from: screen.artifactDirectory)
    ))
    outputLogger(formatResultField(
        "Record",
        relativePath(screen.runRecordURL, from: screen.artifactDirectory)
    ))
}

private func formatResultMetric(_ label: String, _ value: Int) -> String {
    formatResultField(label, "\(value)")
}

private func formatResultField(_ label: String, _ value: String) -> String {
    "  \(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(value)"
}

private func formattedTargetQuery(_ query: String) -> String {
    query == "all"
        ? "All targets"
        : query
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
}

private func relativePath(_ url: URL, from artifactDirectory: URL) -> String {
    let outputBaseDirectory = artifactDirectory.deletingLastPathComponent()
    let outputPath = outputBaseDirectory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(outputPath + "/") else {
        return path
    }
    return String(path.dropFirst(outputPath.count + 1))
}

private func shortenedRunID(_ runID: String) -> String {
    let maxLength = 36
    guard runID.count > maxLength else {
        return runID
    }
    return String(runID.prefix(maxLength - 1)) + "..."
}

private func runPrivateHeaderGeneration(
    request: PrivateHeaderKitGenerationRequest
) async throws -> PrivateHeaderKitGenerationSummary {
    let result = try await PrivateHeaderGeneration.generatePrivateHeaders(
        source: request.source,
        output: request.output,
        options: request.options
    )
    return PrivateHeaderKitGenerationSummary(result: result)
}

private func makePrivateHeaderGenerationRequest(
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
    let outputBaseDirectory = URL(
        fileURLWithPath: command.outputBaseDirectory,
        isDirectory: true
    )
    let systemRoot = try effectiveSystemRootURL(from: command, simulatorResolution: simulatorResolution)
    let output = PrivateHeaderGeneration.Output(baseDirectory: outputBaseDirectory)
    let helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
        host: hostHelperExecutableURL,
        simulator: simulatorHelperURL(
            from: command,
            hostHelperExecutableURL: hostHelperExecutableURL
        )
    )
    let executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode = try {
        switch command.platform {
        case .macOS:
            return .host
        case .iOS:
            guard let simulatorResolution else {
                throw PrivateHeaderKitCLIError.missingSimulatorResolution
            }
            return .simulator(
                deviceUDID: simulatorResolution.deviceUDID,
                runtimeRoot: systemRoot.path
            )
        }
    }()
    let helperEnvironment = [
        "PH_RUNTIME_ROOT": systemRoot.path,
    ]
    let options = PrivateHeaderGeneration.Options(
        targetRequest: .query(command.targetQuery),
        systemRoot: systemRoot,
        helperURLs: helperURLs,
        executionMode: executionMode,
        rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
            useSharedCache: true,
            preferRuntimeMetadata: true,
            helperEnvironment: helperEnvironment
        ),
        resumeBehavior: resumeBehaviorOverride ?? .requireExplicitResume(resumeRequested: command.resume),
        outputBaseDirectory: outputBaseDirectory
    )

    return PrivateHeaderKitGenerationRequest(
        source: source,
        output: output,
        options: options
    )
}

private func effectiveSystemRootURL(
    from command: PrivateHeaderKitGenerateCommand,
    simulatorResolution: PrivateHeaderKitSimulatorResolution?
) throws -> URL {
    if let systemRoot = command.systemRoot {
        return URL(fileURLWithPath: systemRoot, isDirectory: true)
    }

    switch command.platform {
    case .macOS:
        throw PrivateHeaderKitCLIError.missingRequiredOption("--system-root")
    case .iOS:
        guard let simulatorResolution else {
            throw PrivateHeaderKitCLIError.missingSimulatorResolution
        }
        return URL(fileURLWithPath: simulatorResolution.resolvedRuntimeRoot, isDirectory: true)
    }
}

private func simulatorHelperURL(
    from command: PrivateHeaderKitGenerateCommand,
    hostHelperExecutableURL: URL
) -> URL {
    if let simulatorHelperPath = command.simulatorHelperPath {
        return URL(fileURLWithPath: PathUtils.expandTilde(simulatorHelperPath), isDirectory: false)
    }
    return defaultSimulatorHelperURL(hostExecutableURL: hostHelperExecutableURL)
}

func defaultSimulatorHelperURL(hostExecutableURL: URL) -> URL {
    let directory = hostExecutableURL.deletingLastPathComponent()
    if directory.lastPathComponent == "privateheaderkit",
       directory.deletingLastPathComponent().lastPathComponent == "libexec" {
        return directory.appendingPathComponent("privateheaderkit-sim-helper", isDirectory: false)
    }
    if let swiftPMHelperURL = swiftPMBuildSimulatorHelperURL(
        hostBuildExecutableURL: hostExecutableURL,
        simulatorTriple: defaultSwiftPMIOSSimulatorTriple()
    ) {
        return swiftPMHelperURL
    }
    return directory
        .deletingLastPathComponent()
        .appendingPathComponent("libexec/privateheaderkit/privateheaderkit-sim-helper", isDirectory: false)
}

func defaultRawDumpHelperURL(publicExecutableURL: URL) -> URL {
    let binDir = publicExecutableURL.deletingLastPathComponent()
    if swiftPMBuildProductLayout(for: publicExecutableURL) != nil {
        return binDir.appendingPathComponent("privateheaderkit-raw-helper", isDirectory: false)
    }
    return binDir
        .deletingLastPathComponent()
        .appendingPathComponent("libexec/privateheaderkit/privateheaderkit-raw-helper", isDirectory: false)
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

    let rawHelperURL = defaultRawDumpHelperURL(publicExecutableURL: publicExecutableURL)
    _ = try runner.runCapture(
        [
            "swift",
            "build",
            "-c",
            layout.configuration,
            "--product",
            "privateheaderkit-raw-helper",
        ],
        env: nil,
        cwd: layout.repoRoot
    )

    guard includeSimulatorHelper,
          swiftPMBuildSimulatorHelperURL(
              hostBuildExecutableURL: rawHelperURL,
              simulatorTriple: simulatorTriple
          ) != nil
    else {
        return
    }

    let sdkPath = try runner.runCapture(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
        env: nil,
        cwd: nil
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try runner.runCapture(
        [
            "swift",
            "build",
            "-c",
            layout.configuration,
            "--sdk",
            sdkPath,
            "--triple",
            simulatorTriple,
            "--product",
            "privateheaderkit-sim-helper",
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

    var repoRoot: URL {
        buildRoot.deletingLastPathComponent()
    }
}

private func swiftPMBuildProductLayout(for executableURL: URL) -> SwiftPMBuildProductLayout? {
    let directory = executableURL.deletingLastPathComponent()
    let components = directory.pathComponents
    guard let buildIndex = components.lastIndex(of: ".build") else {
        return nil
    }
    let trailingComponents = Array(components.dropFirst(buildIndex + 1))
    let configuration: String
    switch trailingComponents.count {
    case 1 where isSwiftPMBuildConfiguration(trailingComponents[0]):
        configuration = trailingComponents[0]
    case 2 where isSwiftPMBuildConfiguration(trailingComponents[1]):
        configuration = trailingComponents[1]
    default:
        return nil
    }
    let buildRoot = URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(buildIndex + 1))))
    return SwiftPMBuildProductLayout(buildRoot: buildRoot, configuration: configuration)
}

private func isSwiftPMBuildConfiguration(_ component: String) -> Bool {
    component == "debug" || component == "release"
}

private func defaultSwiftPMIOSSimulatorTriple() -> String {
    "\(defaultSwiftPMIOSSimulatorArchitecture())-apple-ios-simulator"
}

private func defaultSwiftPMIOSSimulatorArchitecture() -> String {
    if currentHostSupportsNativeArm64Simulator() {
        return "arm64"
    }
    #if arch(x86_64)
    return "x86_64"
    #else
    return "arm64"
    #endif
}

private func currentHostSupportsNativeArm64Simulator() -> Bool {
    #if canImport(Darwin)
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
    return result == 0 && value != 0
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
    var sources: [PrivateHeaderKitInteractiveSource] = []

    if let runtimes = try? Simctl.listRuntimes(runner: runner) {
        sources += runtimes.map { runtime in
            PrivateHeaderKitInteractiveSource(
                platform: .iOS,
                version: runtime.version,
                build: runtime.build.isEmpty ? nil : runtime.build,
                systemRoot: nil
            )
        }
    }

    if let macOSSource = try? currentMacOSInteractiveSource(runner: runner) {
        sources.append(macOSSource)
    }

    return sources
}

private func currentMacOSInteractiveSource(
    runner: CommandRunning
) throws -> PrivateHeaderKitInteractiveSource {
    let version = try runner
        .runCapture(["/usr/bin/sw_vers", "-productVersion"], env: nil, cwd: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let build = try runner
        .runCapture(["/usr/bin/sw_vers", "-buildVersion"], env: nil, cwd: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !version.isEmpty else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--version")
    }

    return PrivateHeaderKitInteractiveSource(
        platform: .macOS,
        version: version,
        build: build.isEmpty ? nil : build,
        systemRoot: "/"
    )
}

private func privateHeaderKitExecutableURL(
    currentExecutableURL: URL?,
    fallbackProgramName: String
) -> URL {
    if let currentExecutableURL {
        return currentExecutableURL
    }
    return URL(fileURLWithPath: fallbackProgramName, isDirectory: false)
}

private func logPrivateHeaderKitSimulatorSelection(
    _ resolution: PrivateHeaderKitSimulatorResolution,
    command: PrivateHeaderKitGenerateCommand,
    outputLogger: (String) -> Void
) {
    outputLogger("selected simulator: \(resolution.deviceName) (\(resolution.deviceUDID))")
    if let systemRoot = command.systemRoot,
       URL(fileURLWithPath: systemRoot, isDirectory: true).standardizedFileURL.path
        != URL(fileURLWithPath: resolution.resolvedRuntimeRoot, isDirectory: true).standardizedFileURL.path {
        outputLogger("using explicit system root: \(systemRoot)")
        outputLogger("resolved runtime root: \(resolution.resolvedRuntimeRoot)")
    }
}

private func failureSummaryLines(from summary: String?) -> [String] {
    guard let summary else {
        return ["no failure summary recorded"]
    }
    let lines = summary
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if lines.count <= 5 {
        return lines.isEmpty ? ["no failure summary recorded"] : lines
    }
    return Array(lines.prefix(5)) + ["..."]
}

func parsePrivateHeaderKitCommand(_ args: [String]) throws -> PrivateHeaderKitCommand {
    let programName = args.first ?? "privateheaderkit"
    let remaining = Array(args.dropFirst())

    let invokedName = URL(fileURLWithPath: programName).lastPathComponent
    if legacyPublicCommandNames.contains(invokedName) {
        throw PrivateHeaderKitCLIError.legacyCommand(invokedName)
    }

    guard let command = remaining.first else {
        return .interactiveGenerate
    }

    switch command {
    case "-h", "--help", "help":
        return .help
    case "install":
        let installArgs = ["\(programName) install"] + Array(remaining.dropFirst())
        return .install(installArgs)
    case "generate":
        let generateArgs = Array(remaining.dropFirst())
        return generateArgs.isEmpty
            ? .interactiveGenerate
            : try parsePrivateHeaderKitGenerateCommand(generateArgs)
    case let command where legacyPublicCommandNames.contains(command):
        throw PrivateHeaderKitCLIError.legacyCommand(command)
    case let option where option.hasPrefix("--"):
        return try parsePrivateHeaderKitGenerateCommand(remaining)
    default:
        throw PrivateHeaderKitCLIError.unknownCommand(command)
    }
}

private func parsePrivateHeaderKitGenerateCommand(_ args: [String]) throws -> PrivateHeaderKitCommand {
    if args.isEmpty || args == ["-h"] || args == ["--help"] || args == ["help"] {
        return .generateHelp
    }

    var platform: PrivateHeaderKitGenerateCommand.Platform?
    var version: String?
    var build: String?
    var systemRoot: String?
    var outputBaseDirectory: String?
    var targetQuery: String?
    var device: String?
    var simulatorHelperPath: String?
    var resume = false
    var seenOptions: Set<String> = []

    var index = 0
    while index < args.count {
        let argument = args[index]

        if argument == "-h" || argument == "--help" {
            return .generateHelp
        }

        guard argument.hasPrefix("--") else {
            throw PrivateHeaderKitCLIError.unexpectedArgument(argument)
        }

        let parsedOption = splitLongOption(argument)
        let option = parsedOption.name
        let inlineValue = parsedOption.value

        switch option {
        case "--platform":
            try markOptionSeen(option, in: &seenOptions)
            let value = try readOptionValue(
                option: option,
                inlineValue: inlineValue,
                args: args,
                index: &index
            )
            guard let parsedPlatform = PrivateHeaderKitGenerateCommand.Platform(rawValue: value) else {
                throw PrivateHeaderKitCLIError.invalidPlatform(value)
            }
            platform = parsedPlatform
        case "--version":
            try markOptionSeen(option, in: &seenOptions)
            let value = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
            try validateSourcePathComponent(value, option: option)
            version = value
        case "--build":
            try markOptionSeen(option, in: &seenOptions)
            let value = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
            try validateSourcePathComponent(value, option: option)
            build = value
        case "--system-root":
            try markOptionSeen(option, in: &seenOptions)
            systemRoot = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
        case "--out":
            try markOptionSeen(option, in: &seenOptions)
            outputBaseDirectory = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
        case "--target":
            try markOptionSeen(option, in: &seenOptions)
            let value = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
            try validateTargetQuery(value)
            targetQuery = value
        case "--device":
            try markOptionSeen(option, in: &seenOptions)
            device = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
        case "--sim-helper":
            try markOptionSeen(option, in: &seenOptions)
            simulatorHelperPath = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
        case "--resume":
            try markOptionSeen(option, in: &seenOptions)
            if inlineValue != nil {
                throw PrivateHeaderKitCLIError.unexpectedValue(option)
            }
            resume = true
            index += 1
        default:
            throw PrivateHeaderKitCLIError.unknownOption(option)
        }
    }

    guard let platform else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--platform")
    }
    guard let version else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--version")
    }
    if platform == .macOS, systemRoot == nil {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--system-root")
    }
    guard let outputBaseDirectory else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--out")
    }
    guard let targetQuery else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--target")
    }

    return .generate(
        PrivateHeaderKitGenerateCommand(
            platform: platform,
            version: version,
            build: build,
            systemRoot: systemRoot,
            outputBaseDirectory: outputBaseDirectory,
            targetQuery: targetQuery,
            resume: resume,
            device: device,
            simulatorHelperPath: simulatorHelperPath
        )
    )
}

private func splitLongOption(_ argument: String) -> (name: String, value: String?) {
    guard let separator = argument.firstIndex(of: "=") else {
        return (argument, nil)
    }
    let name = String(argument[..<separator])
    let value = String(argument[argument.index(after: separator)...])
    return (name, value)
}

private func markOptionSeen(_ option: String, in seenOptions: inout Set<String>) throws {
    guard seenOptions.insert(option).inserted else {
        throw PrivateHeaderKitCLIError.duplicateOption(option)
    }
}

private func readOptionValue(
    option: String,
    inlineValue: String?,
    args: [String],
    index: inout Int
) throws -> String {
    if let inlineValue {
        index += 1
        return inlineValue
    }

    let valueIndex = index + 1
    guard valueIndex < args.count else {
        throw PrivateHeaderKitCLIError.missingValue(option)
    }
    guard !args[valueIndex].hasPrefix("--") else {
        throw PrivateHeaderKitCLIError.missingValue(option)
    }
    index += 2
    return args[valueIndex]
}

private func nonEmptyOptionValue(_ value: String, option: String) throws -> String {
    guard !value.isEmpty else {
        throw PrivateHeaderKitCLIError.emptyOptionValue(option)
    }
    return value
}

private func validateSourcePathComponent(_ value: String, option: String) throws {
    guard value != ".", value != "..", !value.contains("/"), !value.contains("\0") else {
        throw PrivateHeaderKitCLIError.invalidSourceComponent(option: option, value: value)
    }
}

private func validateTargetQuery(_ value: String) throws {
    let entries = value.split(separator: ",", omittingEmptySubsequences: false)
    let hasEmptyEntry = entries.contains { entry in
        String(entry).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !hasEmptyEntry else {
        throw PrivateHeaderKitCLIError.invalidTargetQuery(value)
    }
}

private func promptIndexedSelection<Value>(
    prompt: String,
    values: [Value],
    inputReader: PrivateHeaderKitInputReader,
    outputLogger: (String) -> Void
) throws -> Value {
    while true {
        outputLogger(prompt)
        guard let line = inputReader() else {
            throw PrivateHeaderKitCLIError.missingValue(prompt)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if isInteractiveBackInput(trimmed) {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        guard let number = Int(trimmed), values.indices.contains(number - 1) else {
            outputLogger("Enter a number from 1 to \(values.count).")
            continue
        }
        return values[number - 1]
    }
}

private func promptRequiredValue(
    prompt: String,
    inputReader: PrivateHeaderKitInputReader,
    outputLogger: (String) -> Void,
    expandTilde: Bool = false
) throws -> String {
    while true {
        outputLogger(prompt)
        guard let line = inputReader() else {
            throw PrivateHeaderKitCLIError.missingValue(prompt)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if isInteractiveBackInput(trimmed) {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        guard !trimmed.isEmpty else {
            outputLogger("Enter a value.")
            continue
        }
        return expandTilde ? PathUtils.expandTilde(trimmed) : trimmed
    }
}

private func isInteractiveBackInput(_ value: String) -> Bool {
    value == "\u{001B}"
}

private extension PrivateHeaderKitGenerateCommand.Platform {
    var corePlatform: PrivateHeaderGeneration.Source.Platform {
        switch self {
        case .iOS:
            return .iOS
        case .macOS:
            return .macOS
        }
    }
}

func printPrivateHeaderKitUsage() {
    print(privateHeaderKitUsageText())
}

func printPrivateHeaderKitGenerateUsage() {
    print(privateHeaderKitGenerateUsageText())
}

func privateHeaderKitUsageText() -> String {
    """
    Usage:
      privateheaderkit [options]

    Options:
      --platform <iOS|macOS>  Source platform
      --version <version>     Source OS version
      --out <path>            Output base directory
      --target <query>        Comma-separated target query, for example SwiftUI,UIKit
      -h, --help              Show this help

    Examples:
      privateheaderkit --platform iOS --version 27.0 --build 24A5355q --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
      privateheaderkit --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
    """
}

func privateHeaderKitGenerateUsageText() -> String {
    """
    Usage:
      privateheaderkit --platform <iOS|macOS> --version <version> [--build <build>] [--system-root <path>] --out <path> --target <query> [--device <name-or-udid>] [--sim-helper <path>] [--resume]

    Required Options:
      --platform <iOS|macOS>  Source platform
      --version <version>     Source OS version
      --out <path>            Output base directory
      --target <query>        Comma-separated target query, for example SwiftUI,UIKit

    Optional Options:
      --build <build>         Source build train for labels and state keys
      --system-root <path>    Mounted system root to scan; required for macOS, optional for iOS
      --device <name-or-udid> iOS simulator device to use
      --sim-helper <path>     iOS simulator raw-dump helper path
      --resume                Resume the matching explicit source/output/target run
      -h, --help              Show this help

    Output:
      Headers: <out>/<platform><version>(<build>)/
      State:   <out>/.state/<platform><version>(<build>)/

    Examples:
      privateheaderkit --platform iOS --version 27.0 --build 24A5355q --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
      privateheaderkit --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
    """
}

private func readInteractiveLine() -> String? {
#if canImport(Darwin) || canImport(Glibc)
    guard isatty(STDIN_FILENO) != 0 else {
        return readLine()
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
        return readLine()
    }

    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON)
    raw.c_lflag &= ~tcflag_t(ECHO)
    withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
        bytes[Int(VMIN)] = 1
        bytes[Int(VTIME)] = 0
    }

    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
        return readLine()
    }
    defer {
        var restored = original
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
    }

    var bytes: [UInt8] = []
    while true {
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        guard count == 1 else {
            return nil
        }

        switch byte {
        case 3:
            FileHandle.standardOutput.write(Data("^C\n".utf8))
            var restored = original
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            raise(SIGINT)
            return nil
        case 4 where bytes.isEmpty:
            return nil
        case 10, 13:
            FileHandle.standardOutput.write(Data("\n".utf8))
            return String(decoding: bytes, as: UTF8.self)
        case 27:
            FileHandle.standardOutput.write(Data("\n".utf8))
            return "\u{001B}"
        case 8, 127:
            guard !bytes.isEmpty else {
                continue
            }
            bytes.removeLast()
            FileHandle.standardOutput.write(Data("\u{8} \u{8}".utf8))
        default:
            bytes.append(byte)
            FileHandle.standardOutput.write(Data([byte]))
        }
    }
#else
    return readLine()
#endif
}

private func logCLIError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

private func logCLIOutput(_ message: String) {
    if isInteractivePromptMessage(message) {
        print("\(message) ", terminator: "")
    } else {
        print(message)
    }
    fflush(stdout)
}

private func isInteractivePromptMessage(_ message: String) -> Bool {
    switch message {
    case "Select source:", "Select targets:", "Targets:", "Select action:":
        return true
    default:
        return false
    }
}

private func clearInteractiveScreen() {
#if canImport(Darwin)
    let outputIsTerminal = isatty(STDOUT_FILENO) != 0
#elseif canImport(Glibc)
    let outputIsTerminal = isatty(STDOUT_FILENO) != 0
#else
    let outputIsTerminal = false
#endif
    guard outputIsTerminal else {
        return
    }
    guard ProcessInfo.processInfo.environment["TERM"] != "dumb" else {
        return
    }
    fputs("\u{001B}[2J\u{001B}[H", stdout)
    fflush(stdout)
}
