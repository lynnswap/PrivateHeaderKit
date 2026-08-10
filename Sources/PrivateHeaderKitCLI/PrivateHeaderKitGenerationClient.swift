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
        case legacyState(path: String)
        case legacyArtifacts(path: String)
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

    static let live = PrivateHeaderKitGenerationClient(
        prepare: preparePrivateHeaderGeneration
    )
}

private func preparePrivateHeaderGeneration(
    request: PrivateHeaderKitGenerationRequest
) async throws -> PrivateHeaderKitPreparedGeneration {
    let executor = PrivateHeaderGeneration.GenerationExecutor(
        rawDumpRunner: runPrivateHeaderKitRawDump,
        sharedCacheInventoryRunner: capturePrivateHeaderKitSharedCacheInventory
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
                case .legacyStateRequiresFresh(let path):
                    return .legacyState(path: path)
                case .legacyArtifactsRequireFresh(let path):
                    return .legacyArtifacts(path: path)
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
    invocation: PrivateHeaderGeneration.RawDumping.Invocation
) async throws -> PrivateHeaderGeneration.RawDumping.Result {
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
}

private func capturePrivateHeaderKitSharedCacheInventory(
    invocation: PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation
) async throws -> Data {
    let output = try ProcessRunner().runCapture(
        invocation.command,
        env: invocation.environment,
        cwd: nil
    )
    return Data(output.utf8)
}
