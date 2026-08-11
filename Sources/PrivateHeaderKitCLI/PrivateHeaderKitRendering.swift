import Dispatch
import Foundation
import PrivateHeaderKitCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func privateHeaderKitProgressReporter(
    artifactDirectory: URL,
    outputLogger: @escaping PrivateHeaderKitOutputLogger,
    failureLogger: @escaping PrivateHeaderKitOutputLogger
) -> PrivateHeaderGeneration.GenerationExecutor.ProgressReporter {
    let renderer = PrivateHeaderKitProgressOutputLogger(
        outputLogger: outputLogger,
        failureLogger: failureLogger,
        artifactDirectory: artifactDirectory,
        inlineProgressEnabled: stdoutSupportsInlineProgress()
    )
    return { event in
        renderer.report(event)
    }
}

final class PrivateHeaderKitProgressOutputLogger: @unchecked Sendable {
    private struct ActiveTarget {
        let index: Int
        let total: Int
        let displayName: String
    }

    private let outputLogger: PrivateHeaderKitOutputLogger
    private let failureLogger: PrivateHeaderKitOutputLogger
    private let artifactDirectory: URL
    private let inlineProgressEnabled: Bool
    private let inlineWriter: @Sendable (String) -> Void
    private let startsTimer: Bool
    private let inlineColumnCount: Int
    private let indicators = [".", "..", "..."]
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var activeTarget: ActiveTarget?
    private var indicatorIndex = 0
    private var renderedLength = 0
    private var cursorHidden = false

    init(
        outputLogger: @escaping PrivateHeaderKitOutputLogger,
        failureLogger: @escaping PrivateHeaderKitOutputLogger,
        artifactDirectory: URL,
        inlineProgressEnabled: Bool,
        inlineWriter: @escaping @Sendable (String) -> Void = writePrivateHeaderKitInlineOutput,
        startsTimer: Bool = true,
        inlineColumnCount: Int = privateHeaderKitTerminalColumnCount()
    ) {
        self.outputLogger = outputLogger
        self.failureLogger = failureLogger
        self.artifactDirectory = artifactDirectory
        self.inlineProgressEnabled = inlineProgressEnabled
        self.inlineWriter = inlineWriter
        self.startsTimer = startsTimer
        self.inlineColumnCount = max(1, inlineColumnCount)
    }

    deinit {
        stopProgressRendering(clearLine: true)
    }

    func report(_ event: PrivateHeaderGeneration.ProgressEvent) {
        switch event {
        case .runStarted(let runID, let totalTargetCount):
            outputLogger(
                "Generation \(shortenedRunID(runID.rawValue)): \(totalTargetCount) targets → "
                    + artifactDirectory.path
            )
        case .targetStarted(let index, let total, let displayName):
            startTarget(index: index, total: total, displayName: displayName)
        case .targetFinished(
            let index,
            let total,
            let displayName,
            let status,
            let failureSummary
        ):
            finishTarget(
                index: index,
                total: total,
                displayName: displayName,
                status: status,
                failureSummary: failureSummary
            )
        case .warning(let warning):
            writePersistentLine(
                "warning [\(warning.kind)] \(warning.relativePath): "
                    + concisePrivateHeaderKitDiagnostic(warning.message),
                logger: failureLogger
            )
        case .runFinished:
            stopProgressRendering(clearLine: true)
        }
    }

    func advanceIndicatorForTesting() {
        advanceIndicator()
    }

    private func startTarget(index: Int, total: Int, displayName: String) {
        guard inlineProgressEnabled else { return }

        lock.lock()
        stopTimerLocked()
        activeTarget = ActiveTarget(index: index, total: total, displayName: displayName)
        indicatorIndex = 0
        hideCursorLocked()
        renderIndicatorLocked()
        if startsTimer {
            startTimerLocked()
        }
        lock.unlock()
    }

    private func finishTarget(
        index: Int,
        total: Int,
        displayName: String,
        status: PrivateHeaderGeneration.RunTargetStatus,
        failureSummary: String?
    ) {
        let target = ActiveTarget(index: index, total: total, displayName: displayName)
        let shouldPersist = status != .completed && status != .skipped

        if inlineProgressEnabled {
            lock.lock()
            stopTimerLocked()
            activeTarget = nil
            writeInlineLineLocked(
                inlineTargetLine(target, suffix: status.rawValue),
                terminator: shouldPersist ? "\n" : ""
            )
            lock.unlock()
        } else if shouldPersist {
            failureLogger("\(targetPrefix(target)) \(status.rawValue)")
        }

        if shouldPersist, let failureSummary {
            failureLogger("  " + concisePrivateHeaderKitDiagnostic(failureSummary))
        }
    }

    private func writePersistentLine(
        _ line: String,
        logger: PrivateHeaderKitOutputLogger
    ) {
        if inlineProgressEnabled {
            lock.lock()
            stopTimerLocked()
            if renderedLength > 0 {
                writeInlineLineLocked("", terminator: "\n")
            }
            activeTarget = nil
            lock.unlock()
        }
        logger(line)
    }

    private func stopProgressRendering(clearLine: Bool) {
        guard inlineProgressEnabled else { return }
        lock.lock()
        stopTimerLocked()
        activeTarget = nil
        if clearLine, renderedLength > 0 {
            clearInlineLineLocked()
        }
        showCursorLocked()
        lock.unlock()
    }

    private func startTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.advanceIndicator()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func advanceIndicator() {
        lock.lock()
        defer { lock.unlock() }
        guard activeTarget != nil else { return }
        indicatorIndex = (indicatorIndex + 1) % indicators.count
        renderIndicatorLocked()
    }

    private func renderIndicatorLocked() {
        guard let activeTarget else { return }
        writeInlineLineLocked(
            inlineTargetLine(activeTarget, suffix: indicators[indicatorIndex]),
            terminator: ""
        )
    }

    private func targetPrefix(_ target: ActiveTarget) -> String {
        "[\(target.index)/\(target.total)] \(singleLinePrivateHeaderKitText(target.displayName))"
    }

    private func inlineTargetLine(_ target: ActiveTarget, suffix: String) -> String {
        let prefix = "[\(target.index)/\(target.total)] "
        let suffix = " \(suffix)"
        let availableNameWidth = max(
            1,
            inlineColumnCount - privateHeaderKitTerminalWidth(prefix)
                - privateHeaderKitTerminalWidth(suffix)
        )
        return prefix
            + privateHeaderKitTerminalSuffix(
                singleLinePrivateHeaderKitText(target.displayName),
                fitting: availableNameWidth
            )
            + suffix
    }

    private func writeInlineLineLocked(_ line: String, terminator: String) {
        let lineWidth = privateHeaderKitTerminalWidth(line)
        let padding = max(0, renderedLength - lineWidth)
        inlineWriter("\r\(line)\(String(repeating: " ", count: padding))\(terminator)")
        renderedLength = terminator.isEmpty ? lineWidth : 0
    }

    private func clearInlineLineLocked() {
        inlineWriter("\r\(String(repeating: " ", count: renderedLength))\r")
        renderedLength = 0
    }

    private func hideCursorLocked() {
        guard !cursorHidden else { return }
        inlineWriter("\u{001B}[?25l")
        cursorHidden = true
    }

    private func showCursorLocked() {
        guard cursorHidden else { return }
        inlineWriter("\u{001B}[?25h")
        cursorHidden = false
    }
}

private func stdoutSupportsInlineProgress() -> Bool {
    guard isatty(STDOUT_FILENO) != 0 else { return false }
    return ProcessInfo.processInfo.environment["TERM"] != "dumb"
}

private func privateHeaderKitTerminalColumnCount() -> Int {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
        return 80
    }
    return Int(size.ws_col)
}

private func singleLinePrivateHeaderKitText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func privateHeaderKitTerminalWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(into: 0) { width, scalar in
        width += scalar.isASCII ? 1 : 2
    }
}

private func privateHeaderKitTerminalSuffix(_ text: String, fitting maximumWidth: Int) -> String {
    guard privateHeaderKitTerminalWidth(text) > maximumWidth else { return text }
    guard maximumWidth > 1 else { return "…" }

    var suffix: [Character] = []
    var width = privateHeaderKitTerminalWidth("…")
    for character in text.reversed() {
        let characterWidth = privateHeaderKitTerminalWidth(String(character))
        guard width + characterWidth <= maximumWidth else { break }
        suffix.append(character)
        width += characterWidth
    }
    return "…" + String(suffix.reversed())
}

private func writePrivateHeaderKitInlineOutput(_ output: String) {
    FileHandle.standardOutput.write(Data(output.utf8))
}

func concisePrivateHeaderKitDiagnostic(_ message: String) -> String {
    let lines =
        message
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let preferred =
        lines.last(where: { $0.localizedCaseInsensitiveContains("error:") })
        ?? lines.last
        ?? message.trimmingCharacters(in: .whitespacesAndNewlines)
    let sanitized = singleLinePrivateHeaderKitText(preferred)
    let maximumLength = 500
    guard sanitized.count > maximumLength else { return sanitized }
    return String(sanitized.prefix(maximumLength - 1)) + "…"
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
        outputLogger(
            formatResultMetric(
                "Unfinished", summary.targetCounts.pending + summary.targetCounts.running))
    }

    if let infrastructureMessage {
        outputLogger("")
        outputLogger("Infrastructure failure")
        outputLogger("  \(concisePrivateHeaderKitDiagnostic(infrastructureMessage))")
    }
    if !summary.targetFailures.isEmpty {
        outputLogger("")
        outputLogger("Failed targets")
        for failure in summary.targetFailures.prefix(20) {
            outputLogger("  \(failure.displayName) (\(failure.status.rawValue))")
            if let message = failure.message {
                outputLogger("    \(concisePrivateHeaderKitDiagnostic(message))")
            }
        }
    } else if !failedTargetIDs.isEmpty {
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
            outputLogger(
                "  [\(warning.kind)] \(warning.relativePath): "
                    + concisePrivateHeaderKitDiagnostic(warning.message)
            )
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
    let padded =
        label.count < 10
        ? label.padding(toLength: 10, withPad: " ", startingAt: 0)
        : label
    return "  \(padded) \(value)"
}

private func formattedTargetQuery(_ query: String) -> String {
    guard query != "all" else {
        return "All targets"
    }
    return
        query
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
