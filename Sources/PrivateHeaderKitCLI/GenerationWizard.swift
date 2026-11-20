import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

typealias PrivateHeaderKitInteractiveScreenClearer = () -> Void

enum PrivateHeaderKitInteractiveNavigation: Error {
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

private enum PrivateHeaderKitIncompatibleResumeAction {
    case restart
    case back
}

/// The interactive flow: asks for a source and targets, then generates.
struct GenerationWizard: Sendable {
    /// The `--out` value, or the default location when the wizard started without one. Read
    /// once the source and targets are chosen.
    let outputBaseDirectory: @Sendable () -> String
    /// The CLI executable, which the helpers are located from.
    let executableURL: URL
    let processRunner: any CommandRunning
    let console: Console
    let readLine: PrivateHeaderKitInputReader
    /// Hands the terminal back before generation starts writing progress.
    let finishInput: PrivateHeaderKitInputFinalizer
    let clearScreen: @Sendable () -> Void

    func run() async throws -> Int32 {
        do {
            let discovery = try await SourceDiscovery.discover(using: processRunner)
            let sources = discovery.sources
            guard !sources.isEmpty else {
                for failure in discovery.failures { console.error("error: \(failure.description)") }
                console.error("error: no available generation sources found")
                return 2
            }
            while true {
                renderSourceScreen(sources: sources, failures: discovery.failures)
                let source: SourceDiscovery.Source
                do {
                    source = try await promptIndexedSelection(
                        prompt: "Select source:",
                        values: sources
                    )
                } catch PrivateHeaderKitInteractiveNavigation.back {
                    console.output("Cancelled.")
                    return 1
                }

                targetSelection: while true {
                    renderTargetModeScreen(source: source)
                    let targetMode: PrivateHeaderKitInteractiveTargetMode
                    do {
                        targetMode = try await promptIndexedSelection(
                            prompt: "Select targets:",
                            values: [.all, .specific]
                        )
                    } catch PrivateHeaderKitInteractiveNavigation.back {
                        break targetSelection
                    }

                    let targetQuery: String
                    switch targetMode {
                    case .all:
                        targetQuery = "all"
                    case .specific:
                        renderTargetInputScreen(source: source)
                        do {
                            targetQuery = try await promptTargetQuery(prompt: "Targets:")
                        } catch PrivateHeaderKitInteractiveNavigation.back {
                            continue targetSelection
                        }
                    }

                    let generate = GenerateCommand(
                        options: .init(
                            platform: source.platform,
                            version: source.version,
                            build: source.build,
                            systemRoot: source.systemRoot,
                            outputBaseDirectory: outputBaseDirectory(),
                            targetQuery: targetQuery,
                            continuationMode: nil,
                            device: nil,
                            simulatorHelperPath: nil
                        ),
                        executableURL: executableURL,
                        processRunner: processRunner,
                        console: console
                    )
                    do {
                        let outcome = try await generate.simulatorSession.run(
                            for: generate.options
                        ) { simulatorResolution in
                            var request = try await generate.makeRequest(
                                simulatorResolution: simulatorResolution
                            )
                            var query = targetQuery
                            while true {
                                let preparedGeneration: PreparedGeneration
                                do {
                                    preparedGeneration = try await PreparedGeneration(
                                        request: request,
                                        processRunner: processRunner,
                                        recoveryReporter: console.error
                                    )
                                } catch let error as PrivateHeaderGeneration.GenerationError {
                                    guard case .unresolvedTargetQuery = error else { throw error }
                                    console.error("error: \(error.description)")
                                    query = try await promptTargetQuery(prompt: "Targets:")
                                    var options = request.options
                                    options.targetRequest = query == "all" ? .allAvailable : .query(query)
                                    request = GenerationRequest(
                                        source: request.source, output: request.output, options: options
                                    )
                                    continue
                                }
                                let executionOptions = try await promptExecutionOptions(
                                    for: preparedGeneration
                                )
                                try await finishInput()
                                return try await preparedGeneration.runReporting(
                                    to: console,
                                    executionOptions: executionOptions,
                                    targetQuery: query,
                                    clearScreen: clearScreen
                                )
                            }
                        }
                        renderPrivateHeaderKitCommandOutcome(
                            outcome,
                            outputLogger: console.output,
                            errorLogger: console.error
                        )
                        return outcome.exitCode
                    } catch PrivateHeaderKitInteractiveNavigation.back {
                        continue targetSelection
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SimulatorSession.CleanupError {
            console.error("error: \(error)")
            return 2
        } catch let error as PrivateHeaderKitCLIError {
            console.error("error: \(error.description)")
            return 1
        } catch {
            console.error("error: \(error)")
            return 1
        }
    }

    /// Asks whether to continue or restart when an all-target run is unfinished.
    private func promptExecutionOptions(
        for preparedGeneration: PreparedGeneration
    ) async throws -> PrivateHeaderGeneration.ExecutionOptions {
        let request = preparedGeneration.request
        let summary = try await preparedGeneration.summary()
        switch summary {
        case .incompatibleResume(let reason):
            renderIncompatibleResumeScreen(
                sourceDisplayName: request.source.label.displayName,
                reason: reason
            )
            let action: PrivateHeaderKitIncompatibleResumeAction = try await promptIndexedSelection(
                prompt: "Select action:",
                values: [.restart, .back]
            )
            guard action == .restart else {
                throw PrivateHeaderKitInteractiveNavigation.back
            }
            return .init(continuation: .restart)
        case .noUnfinishedRun:
            return request.options.executionOptions
        case .unfinished(let resumeSummary):
            renderResumeScreen(
                sourceDisplayName: request.source.label.displayName,
                summary: resumeSummary
            )
            let action: PrivateHeaderKitInteractiveAction = try await promptIndexedSelection(
                prompt: "Select action:",
                values: [.continuePrevious, .restart]
            )
            return .init(continuation: action == .continuePrevious ? .resume : .restart)
        }
    }

    private func renderSourceScreen(
        sources: [SourceDiscovery.Source],
        failures: [SourceDiscovery.Failure]
    ) {
        let outputLogger = console.output
        clearScreen()
        outputLogger("PrivateHeaderKit")
        outputLogger("Generate private headers from an installed runtime or this Mac.")
        outputLogger("")
        outputLogger("Step 1 of 3: Source")
        var previousPlatform: GenerateCommand.Platform?
        for (index, source) in sources.enumerated() {
            if source.platform != previousPlatform {
                outputLogger("")
                outputLogger(source.platform.rawValue)
                previousPlatform = source.platform
            }
            outputLogger("  [\(index + 1)] \(source.versionAndBuildDisplayName)")
        }
        if !failures.isEmpty {
            outputLogger("")
            outputLogger("Unavailable sources")
            for failure in failures { outputLogger("  \(failure.description)") }
        }
        outputLogger("")
        outputLogger("Press Escape to cancel.")
    }

    private func renderTargetModeScreen(source: SourceDiscovery.Source) {
        let outputLogger = console.output
        clearScreen()
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

    private func renderTargetInputScreen(source: SourceDiscovery.Source) {
        let outputLogger = console.output
        clearScreen()
        outputLogger("PrivateHeaderKit")
        outputLogger("")
        outputLogger("Step 2 of 3: Specific targets")
        outputLogger("Source: \(source.displayName)")
        outputLogger("Enter comma-separated target names, or press Escape to go back.")
    }

    private func renderResumeScreen(
        sourceDisplayName: String,
        summary: PrivateHeaderGeneration.ResumeSummary
    ) {
        let outputLogger = console.output
        clearScreen()
        outputLogger("PrivateHeaderKit")
        outputLogger("")
        outputLogger("Step 3 of 3: Continue or restart")
        outputLogger("Source: \(sourceDisplayName)")
        outputLogger("Remaining: \(summary.counts.unfinished) of \(summary.counts.total)")
        outputLogger("Previous run: \(summary.latestRunID.rawValue)")
        outputLogger("")
        outputLogger("  [1] Continue")
        outputLogger("  [2] Restart")
    }

    private func renderIncompatibleResumeScreen(
        sourceDisplayName: String,
        reason: String
    ) {
        let outputLogger = console.output
        clearScreen()
        outputLogger("PrivateHeaderKit")
        outputLogger("")
        outputLogger("Step 3 of 3: Restart required")
        outputLogger("Source: \(sourceDisplayName)")
        outputLogger("The previous run cannot be resumed: \(reason)")
        outputLogger("")
        outputLogger("  [1] Restart")
        outputLogger("  [2] Back")
    }

    private func promptIndexedSelection<Value>(
        prompt: String,
        values: [Value]
    ) async throws -> Value {
        while true {
            console.output(prompt)
            guard let input = try await readLine() else {
                throw PrivateHeaderKitInteractiveNavigation.back
            }
            if input == "\u{001B}" {
                throw PrivateHeaderKitInteractiveNavigation.back
            }
            guard let index = Int(input), values.indices.contains(index - 1) else {
                console.output("Enter a number from 1 through \(values.count).")
                continue
            }
            return values[index - 1]
        }
    }

    private func promptTargetQuery(prompt: String) async throws -> String {
        while true {
            console.output(prompt)
            guard let input = try await readLine() else {
                throw PrivateHeaderKitInteractiveNavigation.back
            }
            if input == "\u{001B}" {
                throw PrivateHeaderKitInteractiveNavigation.back
            }
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                console.output("Enter at least one target.")
                continue
            }
            do {
                try GenerateCommand.validateTargetQuery(value)
                return value
            } catch let error as PrivateHeaderGeneration.ValidationError {
                console.error("error: \(error.description)")
            }
        }
    }
}

func defaultInteractiveOutputBaseDirectory() -> String {
    PathUtils.expandTilde("~/PrivateHeaderKit")
}

func clearInteractiveScreen() {
#if canImport(Darwin) || canImport(Glibc)
    guard isatty(STDOUT_FILENO) != 0 else { return }
#endif
    FileHandle.standardOutput.write(Data("\u{001B}[2J\u{001B}[H".utf8))
}
