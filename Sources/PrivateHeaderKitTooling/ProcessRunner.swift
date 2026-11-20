import Foundation

#if os(macOS)
import Darwin
import Subprocess

/// SIGTERM for the whole process group, then SIGKILL if the leader is still running five seconds
/// later.
private let processGroupTeardownSequence: [TeardownStep] = [
    .gracefulShutDown(
        toProcessGroup: true,
        allowedDurationToNextStep: .seconds(5)
    ),
]

/// Runs `operation`, waits for the process-group leader to exit, and kills what is left of its
/// group.
///
/// swift-subprocess ends its teardown sequence as soon as the leader exits, and runs none when
/// the leader exits by itself. A descendant that ignores SIGTERM or outlives the leader would
/// otherwise keep running after the command returns.
private func terminatingProcessGroup<
    Success,
    Input: InputProtocol,
    Output: OutputProtocol,
    FailureOutput: OutputProtocol
>(
    of execution: Execution<Input, Output, FailureOutput>,
    after operation: () async throws -> Success
) async throws -> Success {
    let outcome: Result<Success, any Error>
    do {
        outcome = .success(try await operation())
    } catch {
        // The leader may run indefinitely, so stop it before waiting for its exit.
        await execution.teardown(using: processGroupTeardownSequence)
        outcome = .failure(error)
    }

    let processGroupID = execution.processIdentifier.value
    // swift-subprocess reaps the leader after this closure returns. Until then the exited leader
    // keeps its PID, so the ID cannot name another process group while this one is signaled.
    if await hasExitedWithoutBeingReaped(processGroupID) {
        // kill(2) succeeds while a member is still exiting and fails with EPERM once only
        // zombies are left in the group.
        while kill(-processGroupID, SIGKILL) == 0 {
            await Task.yield()
        }
    }
    return try outcome.get()
}

private func hasExitedWithoutBeingReaped(_ processIdentifier: pid_t) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            var info = siginfo_t()
            var status: Int32
            repeat {
                status = waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOWAIT)
            } while status != 0 && errno == EINTR
            continuation.resume(returning: status == 0)
        }
    }
}

private func boundedOutput(
    from sequence: SubprocessOutputSequence
) async throws -> BoundedProcessOutput {
    var collector = BoundedProcessOutputCollector()
    // swift-subprocess closes the pipe when the sequence ends, so the loop always runs to the end.
    for try await buffer in sequence {
        collector.consume(buffer.withUnsafeBytes { Array($0) })
    }
    return collector.finish()
}
#endif

/// A terminal-safe, strictly bounded rendering of bytes emitted by a subprocess.
///
/// Termination and empty-output descriptions belong to ``StreamingCommandResult`` and are not
/// represented as subprocess output here.
public struct BoundedProcessOutput: Equatable, Sendable {
    public static let maximumHeadLineCount = 8
    public static let maximumTailLineCount = 8
    public static let maximumRenderedLineByteCount = 1_024
    public static let maximumRenderedLineCount = 17
    public static let maximumRenderedByteCount = 18 * 1_024

    public let lines: [String]
    public let omittedLineCount: UInt
    /// A lower bound in raw source bytes. Terminal-safe rendering can expand one source byte,
    /// so the exact omitted source count is not always recoverable from a bounded rendering.
    public let omittedSourceByteCountLowerBound: UInt

    public init(lines: [String]) {
        var collector = BoundedProcessOutputCollector()
        for line in lines {
            collector.consume(logicalLine: line)
        }
        self = collector.finish()
    }

    public var isEmpty: Bool { lines.isEmpty }

    public var text: String {
        lines.joined(separator: "\n")
    }

    fileprivate init(
        lines: [String],
        omittedLineCount: UInt,
        omittedSourceByteCountLowerBound: UInt
    ) {
        precondition(
            lines.count <= Self.maximumRenderedLineCount,
            "BoundedProcessOutputCollector must enforce the rendered line-count bound"
        )
        precondition(
            lines.allSatisfy { $0.utf8.count <= Self.maximumRenderedLineByteCount },
            "BoundedProcessOutputCollector must enforce the per-line rendered byte bound"
        )
        precondition(
            lines.joined(separator: "\n").utf8.count <= Self.maximumRenderedByteCount,
            "BoundedProcessOutputCollector must enforce the total rendered byte bound"
        )
        precondition(
            lines.allSatisfy { terminalSafeProcessOutput($0) == $0 },
            "BoundedProcessOutputCollector must emit terminal-safe text"
        )
        self.lines = lines
        self.omittedLineCount = omittedLineCount
        self.omittedSourceByteCountLowerBound = omittedSourceByteCountLowerBound
    }
}

public struct StreamingCommandResult: Equatable, Sendable {
    public let status: Int32
    public let wasKilled: Bool
    /// Output emitted by the process. Synthetic termination text is available through
    /// ``diagnosticLines`` and ``diagnosticText`` instead.
    public let emittedOutput: BoundedProcessOutput
    public let terminationObservedAtUnixEpochMicroseconds: UInt64?

    public init(
        status: Int32,
        wasKilled: Bool,
        lastLines: [String],
        terminationObservedAtUnixEpochMicroseconds: UInt64? = nil
    ) {
        self.init(
            status: status,
            wasKilled: wasKilled,
            emittedOutput: BoundedProcessOutput(lines: lastLines),
            terminationObservedAtUnixEpochMicroseconds:
                terminationObservedAtUnixEpochMicroseconds
        )
    }

    public init(
        status: Int32,
        wasKilled: Bool,
        emittedOutput: BoundedProcessOutput,
        terminationObservedAtUnixEpochMicroseconds: UInt64? = nil
    ) {
        self.status = status
        self.wasKilled = wasKilled
        self.emittedOutput = emittedOutput
        self.terminationObservedAtUnixEpochMicroseconds =
            terminationObservedAtUnixEpochMicroseconds
    }

    public var diagnosticLines: [String] {
        guard status != 0 || wasKilled else { return emittedOutput.lines }
        var lines = emittedOutput.lines
        if emittedOutput.isEmpty {
            lines.append("No process diagnostic was emitted.")
        }
        if wasKilled {
            lines.append("Terminated by signal \(status)")
        } else {
            lines.append("Exited with status \(status)")
        }
        return lines
    }

    public var diagnosticText: String {
        diagnosticLines.joined(separator: "\n")
    }

    /// Compatibility view preserving the previous synthetic termination rules.
    public var lastLines: [String] {
        var lines = emittedOutput.lines
        if wasKilled {
            lines.append("Terminated by signal \(status)")
        } else if status != 0, emittedOutput.isEmpty {
            lines.append("Exited with status \(status)")
        }
        return lines
    }
}

public typealias CommandStandardOutputConsumer = @Sendable (Data) async throws -> Void

/// Runs commands to completion.
///
/// A nonzero exit or a terminating signal throws ``ToolingError/commandFailed(command:status:stderr:)``,
/// except from ``runBuffered(_:env:cwd:)``, which returns it.
public protocol CommandRunning: Sendable {
    /// Runs a command that shares the caller's standard input, output, and error.
    func runInteractive(_ command: [String], env: [String: String]?, cwd: URL?) async throws
    /// Runs a command that reads its standard input from `inputFile`.
    func runWithInputFile(_ command: [String], inputFile: URL, env: [String: String]?, cwd: URL?) async throws
    /// Returns everything the command wrote to standard output.
    func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) async throws -> String
    /// Passes the command's standard output to `consumeStandardOutput` as it arrives.
    func runCaptureChunks(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws
    /// Runs a command whose standard output goes to the caller's standard output.
    func runSimple(_ command: [String], env: [String: String]?, cwd: URL?) async throws
    /// Returns the command's termination with a bounded rendering of its standard output and
    /// standard error.
    func runBuffered(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> StreamingCommandResult
}

public extension CommandRunning {
    func runInteractive(_ command: [String], env: [String: String]? = nil, cwd: URL? = nil) async throws {
        throw ToolingError.unsupported("this command runner does not support interactive standard IO")
    }

    func runWithInputFile(
        _ command: [String], inputFile: URL, env: [String: String]? = nil, cwd: URL? = nil
    ) async throws {
        throw ToolingError.unsupported("this command runner does not support binary input")
    }
}

/// Runs each command as the leader of its own session and process group. A run returns or throws
/// only after no process of that group is still running, including when the task is cancelled.
public struct ProcessRunner: CommandRunning, Sendable {
    public init() {}

#if os(macOS)
    public func runInteractive(
        _ command: [String], env: [String: String]? = nil, cwd: URL? = nil
    ) async throws {
        // A cancelled call must not reach the terminal restoration below, which discards
        // unread input.
        try Task.checkCancellation()
        var originalTerminal = termios()
        let hasTerminal = tcgetattr(STDIN_FILENO, &originalTerminal) == 0
        let outcome: Result<Void, any Error>
        do {
            let result = try await launch(command, env: env, cwd: cwd) { configuration in
                try await Subprocess.run(
                    configuration, input: .currentStandardInput,
                    output: .currentStandardOutput, error: .currentStandardError
                ) { execution in
                    try await terminatingProcessGroup(of: execution) {}
                }
            }
            try requireSuccess(
                result.terminationStatus, command: command, standardError: "interactive command failed"
            )
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        if hasTerminal, tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTerminal) != 0 {
            let primary: String
            switch outcome {
            case .success: primary = "interactive command completed"
            case .failure(let error): primary = String(describing: error)
            }
            throw ToolingError.message(primary + "; terminal restoration failed (errno \(errno))")
        }
        try outcome.get()
    }

    public func runWithInputFile(
        _ command: [String], inputFile: URL, env: [String: String]? = nil, cwd: URL? = nil
    ) async throws {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: inputFile)
        defer { try? handle.close() }
        // The child reads this file directly. A rejected remote command can
        // then close stdin without a pipe writer delivering SIGPIPE to us.
        let result = try await launch(command, env: env, cwd: cwd) { configuration in
            try await Subprocess.run(
                configuration,
                input: .fileDescriptor(.init(rawValue: handle.fileDescriptor), closeAfterSpawningProcess: false),
                output: .bytes(limit: .max), error: .bytes(limit: .max)
            ) { execution in
                try await terminatingProcessGroup(of: execution) {}
            }
        }
        try requireSuccess(
            result.terminationStatus, command: command,
            standardError: String(decoding: result.standardError, as: UTF8.self)
        )
    }

    public func runCapture(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws -> String {
        let result = try await launch(command, env: env, cwd: cwd) { configuration in
            try await Subprocess.run(
                configuration,
                input: .none,
                // Callers parse complete JSON and build metadata, so the library's default
                // limit would corrupt successful output.
                output: .bytes(limit: .max),
                error: .bytes(limit: .max)
            ) { execution in
                try await terminatingProcessGroup(of: execution) {}
            }
        }
        try requireSuccess(
            result.terminationStatus, command: command,
            standardError: String(decoding: result.standardError, as: UTF8.self)
        )
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    public func runCaptureChunks(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws {
        let result = try await launch(command, env: env, cwd: cwd) { configuration in
            try await Subprocess.run(
                configuration, input: .none, output: .sequence, error: .sequence
            ) { execution in
                try await terminatingProcessGroup(of: execution) {
                    // A group reports the first failure of either stream while the other is
                    // still open.
                    try await withThrowingTaskGroup(of: BoundedProcessOutput?.self) { group in
                        group.addTask {
                            try await boundedOutput(from: execution.standardError)
                        }
                        group.addTask {
                            // Leaving the loop early would leak the pipe, so a failed or
                            // cancelled consumer stops the child and the rest is discarded.
                            var failure: (any Error)?
                            for try await buffer in execution.standardOutput where failure == nil {
                                do {
                                    try Task.checkCancellation()
                                    try await consumeStandardOutput(buffer.withUnsafeBytes { Data($0) })
                                } catch {
                                    failure = error
                                    await execution.teardown(using: processGroupTeardownSequence)
                                }
                            }
                            if let failure {
                                throw failure
                            }
                            return nil
                        }
                        var standardError = BoundedProcessOutput(lines: [])
                        for try await output in group {
                            standardError = output ?? standardError
                        }
                        return standardError
                    }
                }
            }
        }
        try requireSuccess(
            result.terminationStatus, command: command, diagnosticOutput: result.closureResult
        )
    }

    /// The child writes to the caller's standard output itself, so a stalled reader blocks the
    /// child and never this process.
    public func runSimple(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws {
        let result = try await launch(command, env: env, cwd: cwd) { configuration in
            try await Subprocess.run(
                configuration, input: .none, output: .currentStandardOutput, error: .sequence
            ) { execution in
                try await terminatingProcessGroup(of: execution) {
                    try await boundedOutput(from: execution.standardError)
                }
            }
        }
        try requireSuccess(
            result.terminationStatus, command: command, diagnosticOutput: result.closureResult
        )
    }

    public func runBuffered(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws -> StreamingCommandResult {
        let result = try await launch(command, env: env, cwd: cwd) { configuration in
            try await Subprocess.run(
                configuration, input: .none, output: .sequence, error: .combinedWithOutput
            ) { execution in
                try await terminatingProcessGroup(of: execution) {
                    try await boundedOutput(from: execution.standardOutput)
                }
            }
        }
        let termination = commandTermination(result.terminationStatus)
        return StreamingCommandResult(
            status: termination.status,
            wasKilled: termination.wasKilled,
            emittedOutput: result.closureResult,
            terminationObservedAtUnixEpochMicroseconds: UInt64(
                exactly: (Date().timeIntervalSince1970 * 1_000_000).rounded(.down)
            )
        )
    }

    /// Runs `command` from the first executable candidate that launches, and maps what
    /// swift-subprocess throws to ``ToolingError``.
    private func launch<Value>(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        _ run: (Configuration) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        var launchFailure = ToolingError.processLaunchFailed(command: command, underlying: "no executable candidate")
        for configuration in try processConfigurations(command, env: env, cwd: cwd) {
            try Task.checkCancellation()
            do {
                let value = try await run(configuration)
                // Cancellation terminates the process group; report it once the group is gone.
                try Task.checkCancellation()
                return value
            } catch let error as SubprocessError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                launchFailure = mapSubprocessError(error, command: command)
                guard isRetryableExecutableLaunchError(error) else {
                    throw launchFailure
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        throw launchFailure
    }

    private func processConfigurations(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) throws -> [Configuration] {
        guard let executableValue = command.first, !executableValue.isEmpty else {
            throw ToolingError.invalidArgument("process command must include an executable")
        }
        guard command.allSatisfy({ !$0.contains("\0") }) else {
            throw ToolingError.invalidArgument("process executable and arguments must not contain NUL")
        }
        if let cwd {
            guard cwd.isFileURL else {
                throw ToolingError.invalidArgument("process working directory must be a file URL")
            }
            guard !cwd.path.contains("\0") else {
                throw ToolingError.invalidArgument("process working directory must not contain NUL")
            }
        }
        var environmentUpdates: [Environment.Key: String?] = [:]
        for (key, value) in env ?? [:] {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0") else {
                throw ToolingError.invalidArgument(
                    "process environment keys must be nonempty and contain neither '=' nor NUL"
                )
            }
            guard !value.contains("\0") else {
                throw ToolingError.invalidArgument(
                    "process environment values must not contain NUL"
                )
            }
            guard let environmentKey = Environment.Key(rawValue: key) else {
                throw ToolingError.invalidArgument("invalid process environment key: \(key)")
            }
            environmentUpdates[environmentKey] = value
        }
        let executablePaths: [String]
        if executableValue.contains("/") {
            // Relative paths are resolved by Subprocess after applying the requested cwd.
            executablePaths = [executableValue]
        } else {
            var effectiveEnvironment = ProcessInfo.processInfo.environment
            effectiveEnvironment.merge(env ?? [:]) { _, updated in updated }
            let executableURLs = Which.findAll(
                executableValue,
                environment: effectiveEnvironment,
                currentDirectory: cwd ?? URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true
                )
            )
            guard !executableURLs.isEmpty else {
                throw ToolingError.processLaunchFailed(
                    command: command,
                    underlying: "executable not found in PATH: \(executableValue)"
                )
            }
            // Subprocess's Executable.name also searches the current directory and fallback
            // system paths. Resolve only the caller's exact PATH candidates, then preserve the
            // library's ENOENT/EACCES/ENOTDIR fallback by trying each absolute path in order.
            executablePaths = executableURLs.map(\.path)
        }
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = processGroupTeardownSequence
        return executablePaths.map { executablePath in
            Configuration(
                executable: .path(.init(executablePath)),
                arguments: Arguments(Array(command.dropFirst())),
                environment: Environment.inherit.updating(environmentUpdates),
                workingDirectory: cwd.map { .init($0.path) },
                platformOptions: platformOptions
            )
        }
    }

    private func isRetryableExecutableLaunchError(_ error: SubprocessError) -> Bool {
        guard let errorCode = error.underlyingError?.rawValue else {
            return false
        }
        switch error.code {
        case .executableNotFound:
            // Subprocess collapses its exhausted ENOENT/EACCES/ENOTDIR candidate loop to
            // executableNotFound(ENOENT). With one .path per configuration, no child spawned.
            return errorCode == ENOENT
        case .spawnFailed:
            return [ENOENT, EACCES, ENOTDIR].contains(errorCode)
        default:
            return false
        }
    }

    private func mapSubprocessError(
        _ error: SubprocessError,
        command: [String]
    ) -> ToolingError {
        switch error.code {
        case .spawnFailed, .executableNotFound, .failedToChangeWorkingDirectory:
            return .processLaunchFailed(
                command: command,
                underlying: error.description
            )
        default:
            return .processExecutionFailed(
                command: command,
                underlying: error.description
            )
        }
    }

    private func commandTermination(
        _ status: TerminationStatus
    ) -> (status: Int32, wasKilled: Bool) {
        switch status {
        case .exited(let code):
            (Int32(code), false)
        case .signaled(let signal):
            (Int32(signal), true)
        }
    }

    private func requireSuccess(
        _ terminationStatus: TerminationStatus,
        command: [String],
        standardError: String
    ) throws {
        guard !terminationStatus.isSuccess else { return }
        throw ToolingError.commandFailed(
            command: command,
            status: commandTermination(terminationStatus).status,
            stderr: standardError
        )
    }

    private func requireSuccess(
        _ terminationStatus: TerminationStatus,
        command: [String],
        diagnosticOutput: BoundedProcessOutput
    ) throws {
        let termination = commandTermination(terminationStatus)
        try requireSuccess(
            terminationStatus,
            command: command,
            standardError: StreamingCommandResult(
                status: termination.status,
                wasKilled: termination.wasKilled,
                emittedOutput: diagnosticOutput
            ).lastLines.joined(separator: "\n")
        )
    }
#else
    public func runCapture(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> String {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }

    public func runCaptureChunks(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }

    public func runSimple(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }

    public func runBuffered(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> StreamingCommandResult {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }
#endif
}

struct BoundedProcessOutputCollector {
    private var pendingLine = BoundedProcessLineBytes()
    private var headLines: [BoundedProcessLine] = []
    private var tailLines: [BoundedProcessLine] = []
    private var omittedLineCount: UInt = 0
    private var omittedSourceByteCountLowerBound: UInt = 0
    private var didOmitContent = false
    private var isFinished = false

    mutating func consume(_ bytes: [UInt8]) {
        precondition(
            !isFinished,
            "BoundedProcessOutputCollector owns a single consume-before-finish lifecycle"
        )
        var segmentStart = bytes.startIndex
        for index in bytes.indices where bytes[index] == UInt8(ascii: "\n") {
            pendingLine.append(bytes[segmentStart..<index])
            consumePendingLine()
            segmentStart = bytes.index(after: index)
        }
        if segmentStart != bytes.endIndex {
            pendingLine.append(bytes[segmentStart...])
        }
    }

    mutating func consume(logicalLine: String) {
        consume(Array(logicalLine.utf8))
        consume([UInt8(ascii: "\n")])
    }

    mutating func finish() -> BoundedProcessOutput {
        precondition(
            !isFinished,
            "BoundedProcessOutputCollector owns a single finish transition"
        )
        if !pendingLine.isEmpty {
            consumePendingLine()
        }
        isFinished = true

        var lines = headLines.map(\.text)
        if omittedLineCount > 0 || didOmitContent {
            lines.append(
                "[omitted \(omittedLineCount) lines and at least "
                    + "\(omittedSourceByteCountLowerBound) bytes]"
            )
        }
        lines += tailLines.map(\.text)
        return BoundedProcessOutput(
            lines: lines,
            omittedLineCount: omittedLineCount,
            omittedSourceByteCountLowerBound: omittedSourceByteCountLowerBound
        )
    }

    private mutating func consumePendingLine() {
        let line = pendingLine.finish()
        pendingLine = BoundedProcessLineBytes()
        guard let line else { return }
        append(line)
    }

    private mutating func append(_ line: BoundedProcessLine) {
        didOmitContent = didOmitContent || line.didOmitContent
        omittedSourceByteCountLowerBound = saturatingSum(
            omittedSourceByteCountLowerBound,
            line.omittedSourceByteCountLowerBound
        )
        if headLines.count < BoundedProcessOutput.maximumHeadLineCount {
            headLines.append(line)
            return
        }

        tailLines.append(line)
        guard tailLines.count > BoundedProcessOutput.maximumTailLineCount else { return }
        let omittedLine = tailLines.removeFirst()
        didOmitContent = true
        omittedLineCount = saturatingSum(omittedLineCount, 1)
        omittedSourceByteCountLowerBound = saturatingSum(
            omittedSourceByteCountLowerBound,
            omittedLine.rawSourceByteCountRemainingAfterLowerBound
        )
    }
}

private struct BoundedProcessLineBytes {
    // Terminal escaping can expand one source scalar substantially. Retaining larger raw edges
    // keeps enough source material to fill both rendered halves without retaining the whole line.
    private static let edgeByteCount =
        BoundedProcessOutput.maximumRenderedLineByteCount * 8

    private var head: [UInt8] = []
    private var tail: [UInt8] = []
    private var totalByteCount: UInt = 0
    private var hasPotentialNonWhitespaceContent = false

    var isEmpty: Bool { totalByteCount == 0 }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        totalByteCount = saturatingSum(totalByteCount, UInt(bytes.count))
        if !hasPotentialNonWhitespaceContent,
           bytes.contains(where: { !Self.isASCIIWhitespace($0) })
        {
            hasPotentialNonWhitespaceContent = true
        }

        let headCapacity = max(0, Self.edgeByteCount - head.count)
        let headBytes = bytes.prefix(headCapacity)
        head.append(contentsOf: headBytes)
        let remaining = bytes.dropFirst(headBytes.count)
        guard !remaining.isEmpty else { return }

        if remaining.count >= Self.edgeByteCount {
            tail = Array(remaining.suffix(Self.edgeByteCount))
        } else {
            let overflow = max(0, tail.count + remaining.count - Self.edgeByteCount)
            if overflow > 0 {
                tail.removeFirst(overflow)
            }
            tail.append(contentsOf: remaining)
        }
    }

    mutating func finish() -> BoundedProcessLine? {
        let retainedByteCount = UInt(head.count + tail.count)
        let discardedRawByteCount = saturatingSubtract(totalByteCount, retainedByteCount)
        let headText: String
        let tailText: String
        if discardedRawByteCount == 0 {
            headText = normalizedProcessOutputLine(head + tail)
            tailText = ""
        } else {
            headText = normalizedProcessOutputLine(head)
            tailText = normalizedProcessOutputLine(tail)
        }
        guard hasPotentialNonWhitespaceContent else { return nil }
        guard !headText.isEmpty || !tailText.isEmpty || discardedRawByteCount > 0 else {
            return nil
        }
        return boundedProcessLine(
            head: headText,
            tail: tailText,
            rawSourceByteCount: totalByteCount,
            omittedSourceByteCountLowerBound: discardedRawByteCount
        )
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x09...0x0d, 0x20:
            true
        default:
            false
        }
    }
}

private struct BoundedProcessLine {
    let text: String
    let rawSourceByteCount: UInt
    let omittedSourceByteCountLowerBound: UInt
    let didOmitContent: Bool

    var rawSourceByteCountRemainingAfterLowerBound: UInt {
        saturatingSubtract(rawSourceByteCount, omittedSourceByteCountLowerBound)
    }
}

private func boundedProcessLine(
    head: String,
    tail: String,
    rawSourceByteCount: UInt,
    omittedSourceByteCountLowerBound: UInt
) -> BoundedProcessLine {
    let maximumByteCount = BoundedProcessOutput.maximumRenderedLineByteCount
    let separator = " … "

    if omittedSourceByteCountLowerBound == 0,
       tail.isEmpty,
       head.utf8.count <= maximumByteCount
    {
        return BoundedProcessLine(
            text: head,
            rawSourceByteCount: rawSourceByteCount,
            omittedSourceByteCountLowerBound: 0,
            didOmitContent: false
        )
    }

    let sourceTail = tail.isEmpty ? head : tail
    let contentBudget = maximumByteCount - separator.utf8.count
    let headBudget = contentBudget / 2
    let tailBudget = contentBudget - headBudget
    let retainedHead = prefixFittingUTF8(head, maximumByteCount: headBudget)
    let retainedTail = suffixFittingUTF8(sourceTail, maximumByteCount: tailBudget)
    // Do not infer raw byte counts from terminal-safe UTF-8. Escaping and replacement decoding
    // can expand source bytes, so only raw bytes discarded before normalization contribute to
    // this lower bound.
    return BoundedProcessLine(
        text: retainedHead + separator + retainedTail,
        rawSourceByteCount: rawSourceByteCount,
        omittedSourceByteCountLowerBound: omittedSourceByteCountLowerBound,
        didOmitContent: true
    )
}

private func normalizedProcessOutputLine(_ bytes: [UInt8]) -> String {
    terminalSafeProcessOutput(
        String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

private func terminalSafeProcessOutput(_ value: String) -> String {
    value.unicodeScalars.reduce(into: "") { result, scalar in
        switch scalar.value {
        case 0x09:
            result += #"\t"#
        case 0x0a:
            result += #"\n"#
        case 0x0d:
            result += #"\r"#
        default:
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                result += String(format: #"\u{%04x}"#, scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
    }
}

private func prefixFittingUTF8(_ value: String, maximumByteCount: Int) -> String {
    var result = ""
    var byteCount = 0
    for scalar in value.unicodeScalars {
        let scalarByteCount = scalar.utf8.count
        guard byteCount <= maximumByteCount - scalarByteCount else { break }
        result.unicodeScalars.append(scalar)
        byteCount += scalarByteCount
    }
    return result
}

private func suffixFittingUTF8(_ value: String, maximumByteCount: Int) -> String {
    var scalars: [Unicode.Scalar] = []
    var byteCount = 0
    for scalar in value.unicodeScalars.reversed() {
        let scalarByteCount = scalar.utf8.count
        guard byteCount <= maximumByteCount - scalarByteCount else { break }
        scalars.append(scalar)
        byteCount += scalarByteCount
    }
    var result = ""
    for scalar in scalars.reversed() {
        result.unicodeScalars.append(scalar)
    }
    return result
}

private func saturatingSum(_ lhs: UInt, _ rhs: UInt) -> UInt {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt.max : sum
}

private func saturatingSubtract(_ lhs: UInt, _ rhs: UInt) -> UInt {
    lhs >= rhs ? lhs - rhs : 0
}
