import Foundation
import PrivateHeaderKitCore

func privateHeaderKitProgressReporter(
    outputLogger: @escaping PrivateHeaderKitOutputLogger
) -> PrivateHeaderGeneration.GenerationExecutor.ProgressReporter {
    { event in
        switch event {
        case .runStarted(let runID, let totalTargetCount):
            outputLogger("Generation started: \(shortenedRunID(runID.rawValue))")
            outputLogger("Targets: \(totalTargetCount)")
        case .targetStarted(let index, let total, let displayName):
            outputLogger("[\(index)/\(total)] \(displayName)")
        case .targetFinished(_, _, _, let status):
            outputLogger("  \(status.rawValue)")
        case .warning(let warning):
            outputLogger(
                "warning [\(warning.kind)] \(warning.relativePath): \(warning.message)"
            )
        case .runFinished(let summary):
            outputLogger("Generation finished: \(summary.status.rawValue)")
        }
    }
}

func renderPrivateHeaderKitGenerationError(
    _ error: PrivateHeaderGeneration.GenerationError,
    sourceDisplayName: String,
    targetQuery: String,
    screenClearer: PrivateHeaderKitInteractiveScreenClearer?,
    outputLogger: PrivateHeaderKitOutputLogger
) {
    switch error {
    case .runFailed(let failure):
        screenClearer?()
        renderPrivateHeaderKitRunSummary(
            failure.summary,
            sourceDisplayName: sourceDisplayName,
            targetQuery: targetQuery,
            title: "Generation completed with failures",
            failedTargetIDs: failure.failedTargetIDs,
            outputLogger: outputLogger
        )
    case .runInterrupted(let interruption):
        renderPrivateHeaderKitRunSummary(
            interruption.summary,
            sourceDisplayName: sourceDisplayName,
            targetQuery: targetQuery,
            title: "Generation interrupted",
            outputLogger: outputLogger
        )
    case .infrastructureFailed(let failure):
        screenClearer?()
        renderPrivateHeaderKitRunSummary(
            failure.summary,
            sourceDisplayName: sourceDisplayName,
            targetQuery: targetQuery,
            title: "Generation stopped",
            infrastructureMessage: failure.message,
            outputLogger: outputLogger
        )
    case .resumeRequired:
        outputLogger("error: \(error.description)")
        outputLogger("rerun with `--resume` to continue or `--fresh` to restart")
    default:
        outputLogger("error: \(error.description)")
    }
}

func renderPrivateHeaderKitRunSummary(
    _ summary: PrivateHeaderGeneration.RunSummary,
    sourceDisplayName: String,
    targetQuery: String,
    title: String,
    failedTargetIDs: [String] = [],
    infrastructureMessage: String? = nil,
    outputLogger: PrivateHeaderKitOutputLogger
) {
    outputLogger("PrivateHeaderKit")
    outputLogger("")
    outputLogger(title)
    outputLogger("")
    outputLogger(formatResultField("Source", sourceDisplayName))
    outputLogger(formatResultField("Targets", formattedTargetQuery(targetQuery)))
    outputLogger(formatResultField("Status", summary.status.rawValue))
    outputLogger("")
    outputLogger("Result")
    outputLogger(formatResultMetric("Total", summary.targetCounts.total))
    outputLogger(formatResultMetric("Generated", summary.targetCounts.completed))
    outputLogger(formatResultMetric("Skipped", summary.targetCounts.skipped))
    if summary.targetCounts.partial > 0 {
        outputLogger(formatResultMetric("Partial", summary.targetCounts.partial))
    }
    if summary.targetCounts.failed > 0 {
        outputLogger(formatResultMetric("Failed", summary.targetCounts.failed))
    }
    if summary.targetCounts.interrupted > 0 {
        outputLogger(formatResultMetric("Interrupted", summary.targetCounts.interrupted))
    }
    if summary.targetCounts.pending + summary.targetCounts.running > 0 {
        outputLogger(formatResultMetric("Unfinished", summary.targetCounts.pending + summary.targetCounts.running))
    }

    if let infrastructureMessage {
        outputLogger("")
        outputLogger("Infrastructure failure")
        outputLogger("  \(infrastructureMessage)")
    }
    if !failedTargetIDs.isEmpty {
        outputLogger("")
        outputLogger("Failed targets")
        for targetID in failedTargetIDs.prefix(20) {
            outputLogger("  \(targetID)")
        }
    }
    if !summary.warnings.isEmpty {
        outputLogger("")
        outputLogger("Warnings")
        for warning in summary.warnings.prefix(20) {
            outputLogger("  [\(warning.kind)] \(warning.relativePath): \(warning.message)")
        }
    }

    outputLogger("")
    outputLogger("Output")
    outputLogger(formatResultField("Headers", summary.artifactDirectory.path))
    outputLogger(formatResultField("State", summary.stateDatabaseURL.path))
    outputLogger(formatResultField("Run", shortenedRunID(summary.runID.rawValue)))
}

private func formatResultMetric(_ label: String, _ value: Int) -> String {
    formatResultField(label, "\(value)")
}

private func formatResultField(_ label: String, _ value: String) -> String {
    let padded = label.count < 10
        ? label.padding(toLength: 10, withPad: " ", startingAt: 0)
        : label
    return "  \(padded) \(value)"
}

private func formattedTargetQuery(_ query: String) -> String {
    guard query != "all" else {
        return "All targets"
    }
    return query
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: ", ")
}

private func shortenedRunID(_ runID: String) -> String {
    let maximumLength = 36
    guard runID.count > maximumLength else {
        return runID
    }
    return String(runID.prefix(maximumLength - 1)) + "…"
}

func logCLIError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func logCLIOutput(_ message: String) {
    let interactivePrompts: Set<String> = [
        "Select source:",
        "Select targets:",
        "Targets:",
        "Select action:",
    ]
    let terminator = interactivePrompts.contains(message) ? " " : "\n"
    FileHandle.standardOutput.write(Data((message + terminator).utf8))
}
