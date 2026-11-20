import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTooling

struct GenerationRequest: Sendable {
    let source: PrivateHeaderGeneration.Source
    let output: PrivateHeaderGeneration.Output
    let options: PrivateHeaderGeneration.Options
}

/// How a generation command ended: its exit status and, when a run started, that run's status.
struct GenerationOutcome: Equatable, Sendable {
    let exitCode: Int32
    let runStatus: PrivateHeaderGeneration.RunStatus?
    var failureSummary: String? = nil
}

/// A generation whose targets are resolved and whose helpers run through one process runner.
struct PreparedGeneration: Sendable {
    enum Summary: Equatable, Sendable {
        case noUnfinishedRun
        case unfinished(PrivateHeaderGeneration.ResumeSummary)
        case incompatibleResume(reason: String)
    }

    let request: GenerationRequest
    private let executor: PrivateHeaderGeneration.GenerationExecutor
    private let preparedPlan: PrivateHeaderGeneration.GenerationExecutor.PreparedPlan

    /// Resolves the targets that `request` selects.
    init(
        request: GenerationRequest,
        processRunner: any CommandRunning,
        recoveryReporter: @escaping PrivateHeaderKitOutputLogger
    ) async throws {
        let executor = PrivateHeaderGeneration.GenerationExecutor(
            rawDumpRunner: { invocation in
                try await runPrivateHeaderKitRawDump(
                    invocation,
                    processRunner: processRunner,
                    recoveryReporter: recoveryReporter
                )
            },
            sharedCacheInventoryRunner: { invocation in
                try await capturePrivateHeaderKitSharedCacheInventory(
                    invocation,
                    processRunner: processRunner,
                    recoveryReporter: recoveryReporter
                )
            }
        )
        self.request = request
        self.executor = executor
        preparedPlan = try await executor.prepare(
            PrivateHeaderGeneration.makePlan(
                source: request.source,
                output: request.output,
                options: request.options
            )
        )
    }

    /// The unfinished all-target run that running this generation would continue, if any.
    func summary() async throws -> Summary {
        do {
            guard let summary = try await executor.availableResumeSummary(for: preparedPlan) else {
                return .noUnfinishedRun
            }
            return .unfinished(summary)
        } catch let error as PrivateHeaderGeneration.GenerationError {
            switch error {
            case .incompatibleResume(let reason):
                return .incompatibleResume(reason: reason)
            default:
                throw error
            }
        }
    }

    func run(
        _ continuation: PrivateHeaderGeneration.Continuation,
        progressReporter: @escaping PrivateHeaderGeneration.GenerationExecutor.ProgressReporter
    ) async throws -> PrivateHeaderGeneration.Result {
        try await executor.run(
            preparedPlan.withContinuation(continuation),
            progressReporter: progressReporter
        )
    }

    /// Runs the generation and writes its progress and result to `console`.
    ///
    /// `clearScreen` runs before the result when the wizard shows it on a fresh screen.
    func runReporting(
        to console: Console,
        continuation: PrivateHeaderGeneration.Continuation,
        targetQuery: String,
        clearScreen: (@Sendable () -> Void)? = nil
    ) async throws -> GenerationOutcome {
        do {
            let result = try await run(
                continuation,
                progressReporter: privateHeaderKitProgressReporter(
                    artifactDirectory: request.output.artifactDirectory(for: request.source),
                    outputLogger: console.output,
                    failureLogger: console.error
                )
            )
            clearScreen?()
            renderPrivateHeaderKitRunSummary(
                result.summary,
                sourceDisplayName: result.plan.source.label.displayName,
                targetQuery: targetQuery,
                title: "Generation completed",
                outputLogger: console.output
            )
            return GenerationOutcome(exitCode: 0, runStatus: result.summary.status)
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
                screenClearer: clearScreen,
                outputLogger: console.error
            )
            return GenerationOutcome(
                exitCode: cancellationRequested ? 130 : 2,
                runStatus: runStatus,
                failureSummary: String(describing: error)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            console.error("error: \(error)")
            return GenerationOutcome(
                exitCode: 2,
                runStatus: nil,
                failureSummary: String(describing: error)
            )
        }
    }
}

func runPrivateHeaderKitRawDump(
    _ invocation: PrivateHeaderGeneration.RawDumping.Invocation,
    processRunner: any CommandRunning,
    recoveryReporter: @escaping PrivateHeaderKitOutputLogger = logCLIError
) async throws -> PrivateHeaderGeneration.RawDumping.Result {
    try await PrivateHeaderKitHelperExecution(
        processRunner: processRunner,
        recoveryReporter: recoveryReporter
    ).run(
        executionMode: invocation.executionMode,
        isSuccessful: { $0.succeeded },
        prepareForRetry: {
            let fileManager = FileManager.default
            for url in [
                invocation.stagingOutputDirectory,
                invocation.processHandshakeReportURL,
                invocation.diagnosticsReportURL,
            ] {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    let cocoaError = error as NSError
                    guard cocoaError.domain == NSCocoaErrorDomain,
                          cocoaError.code == CocoaError.Code.fileNoSuchFile.rawValue
                    else { throw error }
                }
            }
            try fileManager.createDirectory(
                at: invocation.stagingOutputDirectory,
                withIntermediateDirectories: true
            )
        },
        operation: {
            try await runPrivateHeaderKitRawDumpAttempt(invocation, processRunner: processRunner)
        }
    )
}

private func runPrivateHeaderKitRawDumpAttempt(
    _ invocation: PrivateHeaderGeneration.RawDumping.Invocation,
    processRunner: any CommandRunning
) async throws -> PrivateHeaderGeneration.RawDumping.Result {
    let processResult: StreamingCommandResult
    do {
        if case .ssh = invocation.executionMode {
            processResult = try await runPrivateHeaderKitSSHRawDumpAttempt(
                invocation, processRunner: processRunner
            )
        } else {
            processResult = try await processRunner.runBuffered(
                invocation.command, env: invocation.environment, cwd: nil
            )
        }
    } catch {
        try? FileManager.default.removeItem(at: invocation.processHandshakeReportURL)
        try? FileManager.default.removeItem(at: invocation.diagnosticsReportURL)
        throw error
    }
    guard processResult.status == 0, !processResult.wasKilled else {
        let handshake: RawHelperFailureCapsule.HandshakeObservation
        do {
            handshake = .available(
                try consumeRawDumpProcessHandshake(
                    at: invocation.processHandshakeReportURL,
                    expectedInvocationID: invocation.processHandshakeID
                )
            )
        } catch PrivateHeaderGeneration.RawDumping.ContractError.missingProcessHandshake {
            handshake = .missing
        } catch {
            handshake = .invalid
        }
        try? FileManager.default.removeItem(at: invocation.diagnosticsReportURL)
        let recognizesSimulatorChildTermination: Bool
        if case .simulator = invocation.executionMode {
            recognizesSimulatorChildTermination = true
        } else {
            recognizesSimulatorChildTermination = false
        }
        return PrivateHeaderGeneration.RawDumping.Result(
            terminationStatus: processResult.status,
            wasKilled: processResult.wasKilled,
            failureSummary: RawHelperFailureCapsule(
                processResult: processResult,
                handshake: handshake,
                recognizesSimulatorChildTermination: recognizesSimulatorChildTermination
            ).text
        )
    }

    do {
        _ = try consumeRawDumpProcessHandshake(
            at: invocation.processHandshakeReportURL,
            expectedInvocationID: invocation.processHandshakeID
        )
    } catch {
        try? FileManager.default.removeItem(at: invocation.diagnosticsReportURL)
        throw error
    }
    return PrivateHeaderGeneration.RawDumping.Result(
        terminationStatus: processResult.status,
        wasKilled: processResult.wasKilled,
        failureSummary: nil,
        diagnosticsReport: try consumeRawDumpDiagnosticsReport(at: invocation.diagnosticsReportURL)
    )
}

/// Reads the handshake a helper wrote for this invocation and removes the file.
///
/// A report that cannot be removed stays in the run's staging directory, which is deleted
/// when the run ends.
private func consumeRawDumpProcessHandshake(
    at reportURL: URL,
    expectedInvocationID: UUID
) throws -> PrivateHeaderKitRawDumpProcessHandshake {
    defer { try? FileManager.default.removeItem(at: reportURL) }
    do {
        return try PrivateHeaderKitRawDumpProcessHandshake.decode(
            Data(contentsOf: reportURL),
            expectedInvocationID: expectedInvocationID
        )
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        throw PrivateHeaderGeneration.RawDumping.ContractError.missingProcessHandshake(
            reportURL.path
        )
    } catch {
        throw PrivateHeaderGeneration.RawDumping.ContractError.invalidProcessHandshake(
            path: reportURL.path,
            reason: String(describing: error)
        )
    }
}

/// Reads the diagnostics report a successful helper wrote and removes the file.
private func consumeRawDumpDiagnosticsReport(
    at reportURL: URL
) throws -> PrivateHeaderKitRawDumpDiagnosticsReport {
    defer { try? FileManager.default.removeItem(at: reportURL) }
    do {
        return try JSONDecoder().decode(
            PrivateHeaderKitRawDumpDiagnosticsReport.self,
            from: Data(contentsOf: reportURL)
        )
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        throw PrivateHeaderGeneration.RawDumping.ContractError.missingDiagnosticsReport(
            reportURL.path
        )
    } catch {
        throw PrivateHeaderGeneration.RawDumping.ContractError.invalidDiagnosticsReport(
            path: reportURL.path,
            reason: String(describing: error)
        )
    }
}

func capturePrivateHeaderKitSharedCacheInventory(
    _ invocation: PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation,
    processRunner: any CommandRunning,
    recoveryReporter: @escaping PrivateHeaderKitOutputLogger = logCLIError
) async throws -> Data {
    try await PrivateHeaderKitHelperExecution(
        processRunner: processRunner,
        recoveryReporter: recoveryReporter
    ).run(
        executionMode: invocation.executionMode,
        isSuccessful: { _ in true },
        operation: {
            let output = try await processRunner.runCapture(
                invocation.command,
                env: invocation.environment,
                cwd: nil
            )
            return Data(output.utf8)
        }
    )
}
