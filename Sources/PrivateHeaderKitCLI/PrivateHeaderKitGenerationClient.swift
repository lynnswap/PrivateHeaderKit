import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

struct PrivateHeaderKitGenerationRequest: Sendable {
    let source: PrivateHeaderGeneration.Source
    let output: PrivateHeaderGeneration.Output
    let options: PrivateHeaderGeneration.Options
}

struct PrivateHeaderKitPreparedGeneration: Sendable {
    enum Summary: Equatable, Sendable {
        case noUnfinishedRun
        case unfinished(PrivateHeaderGeneration.ResumeSummary)
        case incompatibleResume(reason: String)
        case legacyMigration(PrivateHeaderGeneration.LegacyMigrationRequirement)
    }

    typealias LoadSummary = @Sendable () async throws -> Summary
    typealias Run = @Sendable (
        PrivateHeaderGeneration.ResumeBehavior,
        @escaping PrivateHeaderGeneration.GenerationExecutor.ProgressReporter
    ) async throws -> PrivateHeaderGeneration.Result

    let summary: LoadSummary
    let run: Run
}

struct PrivateHeaderKitGenerationClient: Sendable {
    typealias Prepare = @Sendable (
        PrivateHeaderKitGenerationRequest
    ) async throws -> PrivateHeaderKitPreparedGeneration

    let prepare: Prepare

    static let live = live(processRunner: ProcessRunner())

    static func live(processRunner: any CommandRunning) -> PrivateHeaderKitGenerationClient {
        PrivateHeaderKitGenerationClient(
            prepare: { request in
                try await preparePrivateHeaderGeneration(
                    request: request,
                    processRunner: processRunner
                )
            }
        )
    }
}

private func preparePrivateHeaderGeneration(
    request: PrivateHeaderKitGenerationRequest,
    processRunner: any CommandRunning
) async throws -> PrivateHeaderKitPreparedGeneration {
    let executor = PrivateHeaderGeneration.GenerationExecutor(
        rawDumpRunner: { invocation in
            try await runPrivateHeaderKitRawDump(
                invocation,
                processRunner: processRunner
            )
        },
        sharedCacheInventoryRunner: { invocation in
            try await capturePrivateHeaderKitSharedCacheInventory(
                invocation,
                processRunner: processRunner
            )
        }
    )
    let plan = PrivateHeaderGeneration.makePlan(
        source: request.source,
        output: request.output,
        options: request.options
    )
    let preparedPlan = try await executor.prepare(plan)
    return PrivateHeaderKitPreparedGeneration(
        summary: {
            do {
                guard let summary = try await executor.availableResumeSummary(
                    for: preparedPlan
                ) else {
                    return .noUnfinishedRun
                }
                return .unfinished(summary)
            } catch let error as PrivateHeaderGeneration.GenerationError {
                switch error {
                case .incompatibleResume(let reason):
                    return .incompatibleResume(reason: reason)
                case .legacyMigrationRequiresFresh(let requirement):
                    return .legacyMigration(requirement)
                default:
                    throw error
                }
            }
        },
        run: { resumeBehavior, progressReporter in
            try await executor.run(
                preparedPlan.withResumeBehavior(resumeBehavior),
                progressReporter: progressReporter
            )
        }
    )
}

private func runPrivateHeaderKitRawDump(
    _ invocation: PrivateHeaderGeneration.RawDumping.Invocation,
    processRunner: any CommandRunning
) async throws -> PrivateHeaderGeneration.RawDumping.Result {
    let processResult = try await processRunner.runStreaming(
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
}

private func capturePrivateHeaderKitSharedCacheInventory(
    _ invocation: PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation,
    processRunner: any CommandRunning
) async throws -> Data {
    let output = try await processRunner.runCapture(
        invocation.command,
        env: invocation.environment,
        cwd: nil
    )
    return Data(output.utf8)
}
