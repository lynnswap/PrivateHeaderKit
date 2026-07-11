import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

typealias PrivateHeaderKitInteractiveScreenClearer = () -> Void
typealias PrivateHeaderKitInteractiveSourceProvider = () throws -> [PrivateHeaderKitInteractiveSource]

struct PrivateHeaderKitInteractiveSource: Equatable, Sendable {
    let platform: PrivateHeaderKitGenerateCommand.Platform
    let version: String
    let build: String?
    let systemRoot: String?

    var displayName: String {
        let base = "\(platform.rawValue) \(version)"
        return build.map { "\(base) (\($0))" } ?? base
    }
}

private enum PrivateHeaderKitInteractiveNavigation: Error {
    case back
}

private enum PrivateHeaderKitInteractiveTargetMode {
    case all
    case specific
}

private enum PrivateHeaderKitInteractiveAction {
    case continuePrevious
    case restart
}

private enum PrivateHeaderKitLegacyMigrationAction {
    case migrateAndStartFresh
    case back
}

private enum PrivateHeaderKitLegacyMigrationKind {
    case state(path: String)
    case artifacts(path: String)

    var path: String {
        switch self {
        case .state(let path), .artifacts(let path): path
        }
    }
}

func runPrivateHeaderKitInteractiveGenerate(
    invokedProgramName: String,
    currentExecutableURL: URL?,
    generationRunner: PrivateHeaderKitGenerationRunner,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    sourceProvider: PrivateHeaderKitInteractiveSourceProvider,
    outputBaseDirectoryProvider: () -> String,
    screenClearer: @escaping PrivateHeaderKitInteractiveScreenClearer,
    inputReader: @escaping PrivateHeaderKitInputReader,
    inputFinalizer: @escaping PrivateHeaderKitInputFinalizer,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    errorLogger: @escaping PrivateHeaderKitOutputLogger
) async -> Int32 {
    do {
        let sources = try sourceProvider()
        guard !sources.isEmpty else {
            errorLogger("error: no available generation sources found")
            return 2
        }
        while true {
            renderInteractiveSourceScreen(
                sources: sources,
                screenClearer: screenClearer,
                outputLogger: outputLogger
            )
            let source: PrivateHeaderKitInteractiveSource
            do {
                source = try await promptIndexedSelection(
                    prompt: "Select source:",
                    values: sources,
                    inputReader: inputReader,
                    outputLogger: outputLogger
                )
            } catch PrivateHeaderKitInteractiveNavigation.back {
                outputLogger("Cancelled.")
                return 1
            }

            targetSelection: while true {
                renderInteractiveTargetModeScreen(
                    source: source,
                    screenClearer: screenClearer,
                    outputLogger: outputLogger
                )
                let targetMode: PrivateHeaderKitInteractiveTargetMode
                do {
                    targetMode = try await promptIndexedSelection(
                        prompt: "Select targets:",
                        values: [.all, .specific],
                        inputReader: inputReader,
                        outputLogger: outputLogger
                    )
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    break targetSelection
                }

                let targetQuery: String
                switch targetMode {
                case .all:
                    targetQuery = "all"
                case .specific:
                    renderInteractiveTargetInputScreen(
                        source: source,
                        screenClearer: screenClearer,
                        outputLogger: outputLogger
                    )
                    do {
                        targetQuery = try await promptRequiredValue(
                            prompt: "Targets:",
                            inputReader: inputReader,
                            outputLogger: outputLogger
                        )
                        try validatePrivateHeaderKitTargetQuery(targetQuery)
                    } catch PrivateHeaderKitInteractiveNavigation.back {
                        continue targetSelection
                    }
                }

                let command = PrivateHeaderKitGenerateCommand(
                    platform: source.platform,
                    version: source.version,
                    build: source.build,
                    systemRoot: source.systemRoot,
                    outputBaseDirectory: outputBaseDirectoryProvider(),
                    targetQuery: targetQuery,
                    continuationMode: nil,
                    device: nil,
                    simulatorHelperPath: nil
                )
                do {
                    let decision = try await interactiveResumeDecision(
                        for: command,
                        invokedProgramName: invokedProgramName,
                        currentExecutableURL: currentExecutableURL,
                        simulatorResolver: simulatorResolver,
                        screenClearer: screenClearer,
                        inputReader: inputReader,
                        outputLogger: outputLogger
                    )
                    try await inputFinalizer()
                    return await runPrivateHeaderKitGenerateCommand(
                        command,
                        invokedProgramName: invokedProgramName,
                        currentExecutableURL: currentExecutableURL,
                        generationRunner: generationRunner,
                        simulatorResolver: simulatorResolver,
                        preResolvedSimulatorResolution: decision.simulatorResolution,
                        resumeBehaviorOverride: decision.resumeBehavior,
                        resultScreenClearer: screenClearer,
                        outputLogger: outputLogger,
                        errorLogger: errorLogger
                    )
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    continue targetSelection
                }
            }
        }
    } catch is CancellationError {
        outputLogger("Cancelled.")
        return 130
    } catch let error as PrivateHeaderKitCLIError {
        errorLogger("error: \(error.description)")
        return 1
    } catch {
        errorLogger("error: \(error)")
        return 1
    }
}

private struct PrivateHeaderKitInteractiveResumeDecision {
    let resumeBehavior: PrivateHeaderGeneration.ResumeBehavior
    let simulatorResolution: PrivateHeaderKitSimulatorResolution?
}

private func interactiveResumeDecision(
    for command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    simulatorResolver: PrivateHeaderKitSimulatorResolver,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    inputReader: @escaping PrivateHeaderKitInputReader,
    outputLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> PrivateHeaderKitInteractiveResumeDecision {
    let publicExecutableURL = privateHeaderKitExecutableURL(
        currentExecutableURL: currentExecutableURL,
        fallbackProgramName: invokedProgramName
    )
    let hostHelperURL = defaultRawDumpHelperURL(publicExecutableURL: publicExecutableURL)
    let simulatorResolution = command.platform == .iOS ? try simulatorResolver(command) : nil
    let request = try makePrivateHeaderGenerationRequest(
        from: command,
        hostHelperExecutableURL: hostHelperURL,
        simulatorResolution: simulatorResolution,
        resumeBehaviorOverride: .requireExplicitResume(resumeRequested: false)
    )
    let summary: PrivateHeaderGeneration.ResumeSummary?
    do {
        summary = try await PrivateHeaderGeneration.availableResumeSummary(
            source: request.source,
            output: request.output,
            options: request.options
        )
    } catch let error as PrivateHeaderGeneration.GenerationError {
        let legacyKind: PrivateHeaderKitLegacyMigrationKind
        switch error {
        case .legacyStateRequiresFresh(let path):
            legacyKind = .state(path: path)
        case .legacyArtifactsRequireFresh(let path):
            legacyKind = .artifacts(path: path)
        default:
            throw error
        }
        let action = try await promptLegacyMigrationDecision(
            command: command,
            kind: legacyKind,
            backupDirectory: request.output.baseDirectory
                .appendingPathComponent(".privateheaderkit", isDirectory: true)
                .appendingPathComponent(request.source.storageIdentifier, isDirectory: true)
                .appendingPathComponent("legacy-backups", isDirectory: true),
            screenClearer: screenClearer,
            inputReader: inputReader,
            outputLogger: outputLogger
        )
        guard action == .migrateAndStartFresh else {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        return PrivateHeaderKitInteractiveResumeDecision(
            resumeBehavior: .fresh,
            simulatorResolution: simulatorResolution
        )
    }
    guard let summary else {
        return PrivateHeaderKitInteractiveResumeDecision(
            resumeBehavior: .fresh,
            simulatorResolution: simulatorResolution
        )
    }

    renderInteractiveResumeScreen(
        command: command,
        summary: summary,
        screenClearer: screenClearer,
        outputLogger: outputLogger
    )
    let action: PrivateHeaderKitInteractiveAction = try await promptIndexedSelection(
        prompt: "Select action:",
        values: [.continuePrevious, .restart],
        inputReader: inputReader,
        outputLogger: outputLogger
    )
    return PrivateHeaderKitInteractiveResumeDecision(
        resumeBehavior: action == .continuePrevious ? .resume : .fresh,
        simulatorResolution: simulatorResolution
    )
}

private func promptLegacyMigrationDecision(
    command: PrivateHeaderKitGenerateCommand,
    kind: PrivateHeaderKitLegacyMigrationKind,
    backupDirectory: URL,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    inputReader: @escaping PrivateHeaderKitInputReader,
    outputLogger: @escaping PrivateHeaderKitOutputLogger
) async throws -> PrivateHeaderKitLegacyMigrationAction {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 3 of 3: Migrate legacy output")
    outputLogger("Legacy PrivateHeaderKit state or artifacts were found.")
    outputLogger("")
    outputLogger("Source: \(command.sourceDisplayName)")
    outputLogger("Output: \(command.outputBaseDirectory)")
    outputLogger("Detected: \(kind.path)")
    outputLogger("")
    switch kind {
    case .state:
        outputLogger("Legacy state files will remain in place.")
        outputLogger("A new generation.sqlite database will become the source of truth.")
    case .artifacts:
        outputLogger("The existing artifact tree and unknown regular files will be preserved.")
        outputLogger("Artifact backup: \(backupDirectory.path)/")
    }
    outputLogger("")
    outputLogger("  [1] Migrate and start fresh")
    outputLogger("  [2] Back")

    return try await promptIndexedSelection(
        prompt: "Select action:",
        values: [.migrateAndStartFresh, .back],
        inputReader: inputReader,
        outputLogger: outputLogger
    )
}

func defaultInteractiveOutputBaseDirectory() -> String {
    PathUtils.expandTilde("~/PrivateHeaderKit")
}

private func renderInteractiveSourceScreen(
    sources: [PrivateHeaderKitInteractiveSource],
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: PrivateHeaderKitOutputLogger
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("Generate private headers from an installed runtime or this Mac.")
    outputLogger("")
    outputLogger("Step 1 of 3: Source")
    for (index, source) in sources.enumerated() {
        outputLogger("  [\(index + 1)] \(source.displayName)")
    }
    outputLogger("")
    outputLogger("Press Escape to cancel.")
}

private func renderInteractiveTargetModeScreen(
    source: PrivateHeaderKitInteractiveSource,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: PrivateHeaderKitOutputLogger
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 2 of 3: Targets")
    outputLogger("Source: \(source.displayName)")
    outputLogger("")
    outputLogger("  [1] All targets")
    outputLogger("  [2] Specific targets")
    outputLogger("")
    outputLogger("Press Escape to go back.")
}

private func renderInteractiveTargetInputScreen(
    source: PrivateHeaderKitInteractiveSource,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: PrivateHeaderKitOutputLogger
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 2 of 3: Specific targets")
    outputLogger("Source: \(source.displayName)")
    outputLogger("Enter comma-separated target names, or press Escape to go back.")
}

private func renderInteractiveResumeScreen(
    command: PrivateHeaderKitGenerateCommand,
    summary: PrivateHeaderGeneration.ResumeSummary,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer,
    outputLogger: PrivateHeaderKitOutputLogger
) {
    screenClearer()
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger("Step 3 of 3: Continue or restart")
    outputLogger("Source: \(command.sourceDisplayName)")
    outputLogger("Remaining: \(summary.counts.unfinished) of \(summary.counts.total)")
    outputLogger("Previous run: \(summary.latestRunID.rawValue)")
    outputLogger("")
    outputLogger("  [1] Continue")
    outputLogger("  [2] Restart")
}

private func promptIndexedSelection<Value>(
    prompt: String,
    values: [Value],
    inputReader: @escaping PrivateHeaderKitInputReader,
    outputLogger: PrivateHeaderKitOutputLogger
) async throws -> Value {
    while true {
        outputLogger(prompt)
        guard let input = try await inputReader() else {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        if input == "\u{001B}" {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        guard let index = Int(input), values.indices.contains(index - 1) else {
            outputLogger("Enter a number from 1 through \(values.count).")
            continue
        }
        return values[index - 1]
    }
}

private func promptRequiredValue(
    prompt: String,
    inputReader: @escaping PrivateHeaderKitInputReader,
    outputLogger: PrivateHeaderKitOutputLogger
) async throws -> String {
    while true {
        outputLogger(prompt)
        guard let input = try await inputReader() else {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        if input == "\u{001B}" {
            throw PrivateHeaderKitInteractiveNavigation.back
        }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            return value
        }
        outputLogger("Enter at least one target.")
    }
}

func clearInteractiveScreen() {
#if canImport(Darwin) || canImport(Glibc)
    guard isatty(STDOUT_FILENO) != 0 else { return }
#endif
    FileHandle.standardOutput.write(Data("\u{001B}[2J\u{001B}[H".utf8))
}
