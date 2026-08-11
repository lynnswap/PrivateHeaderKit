import Foundation

#if os(macOS)
import Darwin
import Dispatch
import Subprocess
#endif

#if os(macOS)
struct ProcessGroupTeardownError: Error, Sendable, CustomStringConvertible {
    let operation: String
    let processGroupID: pid_t
    let errorCode: Int32

    var description: String {
        "\(operation) for process group \(processGroupID) failed (errno \(errorCode))"
    }
}

private enum CapturedCommandStreamResult: Sendable {
    case standardOutputComplete
    case standardErrorComplete([String])
}

struct WaitableProcessGroupLeader: Sendable {
    let processIdentifier: pid_t

    fileprivate init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }
}

private let ownedProcessGroupTeardownSequence: [TeardownStep] = [
    // The leader gets a graceful interval. If it exits first, the lexical ownership
    // boundary below completes teardown for any remaining descendants.
    .gracefulShutDown(
        toProcessGroup: true,
        allowedDurationToNextStep: .seconds(5)
    ),
]

private func processGroupTeardownError(
    operation: String,
    processGroupID: pid_t,
    errorCode: Int32
) -> ProcessGroupTeardownError {
    ProcessGroupTeardownError(
        operation: operation,
        processGroupID: processGroupID,
        errorCode: errorCode
    )
}

private func processGroupHasLiveMember(
    _ processGroupID: pid_t
) throws(ProcessGroupTeardownError) -> Bool {
    var processIDs = [pid_t](repeating: 0, count: 16)

    while true {
        guard processIDs.count <= Int(Int32.max) / MemoryLayout<pid_t>.stride else {
            throw processGroupTeardownError(
                operation: "list members",
                processGroupID: processGroupID,
                errorCode: EOVERFLOW
            )
        }

        errno = 0
        let memberCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listpgrppids(
                processGroupID,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        let listError = errno
        if memberCount == 0 {
            if listError == EINTR {
                continue
            }
            if listError == 0 {
                return false
            }
            throw processGroupTeardownError(
                operation: "list members",
                processGroupID: processGroupID,
                errorCode: listError
            )
        }
        guard memberCount > 0, Int(memberCount) <= processIDs.count else {
            throw processGroupTeardownError(
                operation: "list members",
                processGroupID: processGroupID,
                errorCode: listError == 0 ? EIO : listError
            )
        }
        if Int(memberCount) == processIDs.count {
            guard processIDs.count <= Int(Int32.max) / (2 * MemoryLayout<pid_t>.stride) else {
                throw processGroupTeardownError(
                    operation: "list members",
                    processGroupID: processGroupID,
                    errorCode: EOVERFLOW
                )
            }
            processIDs = [pid_t](repeating: 0, count: processIDs.count * 2)
            continue
        }

        for processID in processIDs.prefix(Int(memberCount)) {
            guard processID > 0 else {
                throw processGroupTeardownError(
                    operation: "list members",
                    processGroupID: processGroupID,
                    errorCode: EIO
                )
            }
            while true {
                var info = proc_bsdshortinfo()
                let expectedSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
                errno = 0
                let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
                    proc_pidinfo(
                        processID,
                        PROC_PIDT_SHORTBSDINFO,
                        0,
                        pointer,
                        expectedSize
                    )
                }
                let infoError = errno
                if actualSize == expectedSize {
                    guard info.pbsi_pgid == UInt32(processGroupID) else { break }
                    if info.pbsi_status != UInt32(SZOMB) {
                        return true
                    }
                    break
                }
                if actualSize <= 0 {
                    if infoError == EINTR {
                        continue
                    }
                    if infoError == ESRCH {
                        break
                    }
                    throw processGroupTeardownError(
                        operation: "inspect member \(processID)",
                        processGroupID: processGroupID,
                        errorCode: infoError == 0 ? EIO : infoError
                    )
                }
                throw processGroupTeardownError(
                    operation: "inspect member \(processID)",
                    processGroupID: processGroupID,
                    errorCode: EIO
                )
            }
        }
        return false
    }
}

func waitForOwnedProcessGroupLeaderExit(
    _ processIdentifier: pid_t
) async throws(ProcessGroupTeardownError) -> WaitableProcessGroupLeader {
    guard processIdentifier > 0 else {
        throw processGroupTeardownError(
            operation: "wait for leader exit",
            processGroupID: processIdentifier,
            errorCode: EINVAL
        )
    }

    let outcome: Result<WaitableProcessGroupLeader, ProcessGroupTeardownError> =
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                while true {
                    var info = siginfo_t()
                    errno = 0
                    if waitid(
                        P_PID,
                        id_t(processIdentifier),
                        &info,
                        WEXITED | WNOWAIT
                    ) == 0 {
                        guard info.si_pid == processIdentifier else {
                            continuation.resume(returning: .failure(
                                processGroupTeardownError(
                                    operation: "verify waitable leader",
                                    processGroupID: processIdentifier,
                                    errorCode: EIO
                                )
                            ))
                            return
                        }
                        continuation.resume(returning: .success(
                            WaitableProcessGroupLeader(
                                processIdentifier: processIdentifier
                            )
                        ))
                        return
                    }

                    let errorCode = errno
                    if errorCode == EINTR {
                        continue
                    }
                    continuation.resume(returning: .failure(
                        processGroupTeardownError(
                            operation: "wait for leader exit",
                            processGroupID: processIdentifier,
                            errorCode: errorCode == 0 ? EIO : errorCode
                        )
                    ))
                    return
                }
            }
        }
    return try outcome.get()
}

func completeOwnedProcessGroup(
    _ leader: WaitableProcessGroupLeader
) async throws(ProcessGroupTeardownError) {
    let processGroupID = leader.processIdentifier

    // waitid(WNOWAIT) keeps the leader as our waitable child until this body returns to
    // swift-subprocess. That kernel-owned identity prevents this numeric PID/PGID from being
    // recycled while lingering descendants are signaled and observed to terminate.
    while true {
        if Darwin.kill(-processGroupID, SIGKILL) == 0 {
            await Task.yield()
            if try processGroupHasLiveMember(processGroupID) {
                continue
            }
            return
        }
        let errorCode = errno
        switch errorCode {
        case EINTR:
            continue
        case EPERM:
            // Darwin excludes zombies from process-group signal delivery. Recheck after the
            // failed signal to distinguish a completed zombie-only group from a live member that
            // this adapter no longer has permission to terminate.
            if try processGroupHasLiveMember(processGroupID) {
                throw ProcessGroupTeardownError(
                    operation: "send SIGKILL",
                    processGroupID: processGroupID,
                    errorCode: errorCode
                )
            }
            // A zombie has already released its executable resources. Its parent may be outside
            // this process group and may never reap it, so group-object extinction is not an
            // achievable completion contract; no live member is the owned lifecycle boundary.
            return
        case ESRCH:
            return
        default:
            throw ProcessGroupTeardownError(
                operation: "send SIGKILL",
                processGroupID: processGroupID,
                errorCode: errorCode
            )
        }
    }
}

private func withOwnedProcessGroup<
    Success: Sendable,
    Input: InputProtocol,
    Output: OutputProtocol,
    FailureOutput: OutputProtocol
>(
    execution: Execution<Input, Output, FailureOutput>,
    operation: () async throws -> Success
) async throws -> Success {
    let outcome: Result<Success, any Error>
    do {
        outcome = .success(try await operation())
    } catch {
        // A body failure must reach process teardown without first waiting for a leader that
        // may otherwise run indefinitely. Cancellation can start the same teardown concurrently;
        // swift-subprocess shares its process monitor across those idempotent waiters.
        await execution.teardown(using: ownedProcessGroupTeardownSequence)
        outcome = .failure(error)
    }

    let leader = try await waitForOwnedProcessGroupLeaderExit(
        execution.processIdentifier.value
    )
    try await completeOwnedProcessGroup(leader)
    return try outcome.get()
}
#endif

public struct StreamingCommandResult: Equatable, Sendable {
    public let status: Int32
    public let wasKilled: Bool
    public let lastLines: [String]

    public init(status: Int32, wasKilled: Bool, lastLines: [String]) {
        self.status = status
        self.wasKilled = wasKilled
        self.lastLines = lastLines
    }
}

public typealias CommandStandardOutputConsumer = @Sendable (Data) async throws -> Void

public protocol CommandRunning: Sendable {
    func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) async throws -> String
    func runCaptureChunks(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws
    func runSimple(_ command: [String], env: [String: String]?, cwd: URL?) async throws
    func runStreaming(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> StreamingCommandResult
}

public struct ProcessRunner: CommandRunning, Sendable {
    public init() {}

#if os(macOS)
    public func runCapture(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let configurations = try processConfigurations(command, env: env, cwd: cwd)
        var lastRetryableLaunchError: SubprocessError?
        for configuration in configurations {
            try Task.checkCancellation()
            do {
                let result = try await Subprocess.run(
                    configuration,
                    input: .none,
                    // Capture is an exact command contract: callers parse complete JSON and build
                    // metadata, so truncating at the library default would corrupt successful output.
                    output: .bytes(limit: .max),
                    error: .bytes(limit: .max)
                ) { execution in
                    try await withOwnedProcessGroup(execution: execution) {
                    }
                }
                // Preserve cancellation only after the owned process group has no live member.
                try Task.checkCancellation()
                let termination = commandTermination(result.terminationStatus)
                let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
                let standardError = String(decoding: result.standardError, as: UTF8.self)
                guard termination.status == 0, !termination.wasKilled else {
                    throw ToolingError.commandFailed(
                        command: command,
                        status: termination.status,
                        stderr: standardError
                    )
                }
                return standardOutput
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProcessGroupTeardownError {
                throw mapProcessGroupTeardownError(error, command: command)
            } catch let error as SubprocessError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard isRetryableExecutableLaunchError(error) else {
                    throw mapSubprocessError(error, command: command)
                }
                lastRetryableLaunchError = error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        guard let lastRetryableLaunchError else {
            preconditionFailure("process configuration produced no executable candidates")
        }
        throw mapSubprocessError(lastRetryableLaunchError, command: command)
    }

    public func runCaptureChunks(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws {
        try Task.checkCancellation()
        let configurations = try processConfigurations(command, env: env, cwd: cwd)
        var lastRetryableLaunchError: SubprocessError?
        for configuration in configurations {
            try Task.checkCancellation()
            do {
                let result = try await Subprocess.run(
                    configuration,
                    input: .none,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    try await withOwnedProcessGroup(execution: execution) {
                        return try await withThrowingTaskGroup(
                            of: CapturedCommandStreamResult.self
                        ) { group in
                            group.addTask {
                                for try await buffer in execution.standardOutput {
                                    try Task.checkCancellation()
                                    let bytes = buffer.withUnsafeBytes { Array($0) }
                                    if !bytes.isEmpty {
                                        try await consumeStandardOutput(Data(bytes))
                                    }
                                }
                                return .standardOutputComplete
                            }
                            group.addTask {
                                var collector = StreamingOutputCollector()
                                for try await buffer in execution.standardError {
                                    try Task.checkCancellation()
                                    collector.consume(buffer.withUnsafeBytes { Array($0) })
                                }
                                collector.finish()
                                return .standardErrorComplete(collector.lastLines)
                            }

                            var standardErrorLines: [String] = []
                            while let streamResult = try await group.next() {
                                if case .standardErrorComplete(let lines) = streamResult {
                                    standardErrorLines = lines
                                }
                            }
                            return standardErrorLines
                        }
                    }
                }
                try Task.checkCancellation()
                let termination = commandTermination(result.terminationStatus)
                var standardErrorLines = result.closureResult
                if termination.wasKilled {
                    appendLastLine(
                        "Terminated by signal \(termination.status)",
                        to: &standardErrorLines
                    )
                }
                guard termination.status == 0, !termination.wasKilled else {
                    throw ToolingError.commandFailed(
                        command: command,
                        status: termination.status,
                        stderr: standardErrorLines.joined(separator: "\n")
                    )
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProcessGroupTeardownError {
                throw mapProcessGroupTeardownError(error, command: command)
            } catch let error as SubprocessError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard isRetryableExecutableLaunchError(error) else {
                    throw mapSubprocessError(error, command: command)
                }
                lastRetryableLaunchError = error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        guard let lastRetryableLaunchError else {
            preconditionFailure("process configuration produced no executable candidates")
        }
        throw mapSubprocessError(lastRetryableLaunchError, command: command)
    }

    public func runSimple(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws {
        let result = try await runStreaming(command, env: env, cwd: cwd)
        guard result.status == 0, !result.wasKilled else {
            throw ToolingError.commandFailed(
                command: command,
                status: result.status,
                stderr: result.lastLines.joined(separator: "\n")
            )
        }
    }

    public func runStreaming(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil
    ) async throws -> StreamingCommandResult {
        try Task.checkCancellation()
        let outputWriter: CancellableStandardOutputWriter
        do {
            outputWriter = try CancellableStandardOutputWriter()
        } catch let error as StandardOutputWriterError {
            throw ToolingError.processExecutionFailed(
                command: command,
                underlying: error.description
            )
        }

        return try await withTaskCancellationHandler {
            do {
                let result = try await runStreaming(
                    command,
                    env: env,
                    cwd: cwd,
                    streamOutput: true,
                    passthrough: { data in
                        try await outputWriter.write(data)
                    }
                )
                // Every write has completed before this point. Closing with .stop is therefore
                // lossless and also makes the cleanup wait cancellation-safe: there is no
                // graceful-close state that a later cancellation would need to upgrade.
                await outputWriter.finish()
                try Task.checkCancellation()
                return result
            } catch let error as ProcessGroupTeardownError {
                await outputWriter.finish()
                throw mapProcessGroupTeardownError(error, command: command)
            } catch {
                await outputWriter.finish()
                if Task.isCancelled {
                    throw CancellationError()
                }
                if let writerError = error as? StandardOutputWriterError {
                    throw ToolingError.processExecutionFailed(
                        command: command,
                        underlying: writerError.description
                    )
                }
                throw error
            }
        } onCancel: {
            outputWriter.cancel()
        }
    }

    func runStreaming(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        streamOutput: Bool,
        passthrough: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> StreamingCommandResult {
        try Task.checkCancellation()
        let configurations = try processConfigurations(command, env: env, cwd: cwd)
        var lastRetryableLaunchError: SubprocessError?
        for configuration in configurations {
            try Task.checkCancellation()
            do {
                let result = try await Subprocess.run(
                    configuration,
                    input: .none,
                    output: .sequence,
                    error: .combinedWithOutput
                ) { execution in
                    try await withOwnedProcessGroup(execution: execution) {
                        var collector = StreamingOutputCollector()
                        for try await buffer in execution.standardOutput {
                            let bytes = buffer.withUnsafeBytes { Array($0) }
                            if streamOutput {
                                try await passthrough(Data(bytes))
                            }
                            collector.consume(bytes)
                        }
                        collector.finish()
                        return collector.lastLines
                    }
                }
                // See runCapture: cancellation is observed after group completion.
                try Task.checkCancellation()
                let termination = commandTermination(result.terminationStatus)
                var lastLines = result.closureResult
                if termination.wasKilled {
                    appendLastLine(
                        "Terminated by signal \(termination.status)",
                        to: &lastLines
                    )
                } else if termination.status != 0, lastLines.isEmpty {
                    appendLastLine("Exited with status \(termination.status)", to: &lastLines)
                }
                return StreamingCommandResult(
                    status: termination.status,
                    wasKilled: termination.wasKilled,
                    lastLines: lastLines
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProcessGroupTeardownError {
                throw error
            } catch let error as SubprocessError {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard isRetryableExecutableLaunchError(error) else {
                    throw mapSubprocessError(error, command: command)
                }
                lastRetryableLaunchError = error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        guard let lastRetryableLaunchError else {
            preconditionFailure("process configuration produced no executable candidates")
        }
        throw mapSubprocessError(lastRetryableLaunchError, command: command)
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
        platformOptions.teardownSequence = ownedProcessGroupTeardownSequence
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

    private func mapProcessGroupTeardownError(
        _ error: ProcessGroupTeardownError,
        command: [String]
    ) -> ToolingError {
        .processExecutionFailed(
            command: command,
            underlying: error.description
        )
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

    public func runStreaming(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> StreamingCommandResult {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }
#endif
}

#if os(macOS)
private enum StandardOutputWriterError: Error, CustomStringConvertible, Sendable {
    case descriptorDuplicationFailed(Int32)
    case writeFailed(Int32)

    var description: String {
        let operation: String
        let code: Int32
        switch self {
        case .descriptorDuplicationFailed(let errorCode):
            operation = "dup standard output"
            code = errorCode
        case .writeFailed(let errorCode):
            operation = "write standard output"
            code = errorCode
        }
        return "\(operation) failed (errno \(code): \(String(cString: strerror(code))))"
    }
}

private final class DispatchIOCleanupWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var isComplete = false
    private var waiter: CheckedContinuation<Void, Never>?

    func complete() {
        lock.lock()
        precondition(!isComplete, "DispatchIO cleanup completed more than once")
        isComplete = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isComplete {
                lock.unlock()
                continuation.resume()
            } else {
                precondition(waiter == nil, "DispatchIO cleanup supports one waiter")
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

private final class DispatchIOWriteCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() {
        resume(with: .success(()))
    }

    func fail(errorCode: Int32) {
        resume(with: .failure(StandardOutputWriterError.writeFailed(errorCode)))
    }

    private func resume(with result: Result<Void, any Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

final class CancellableStandardOutputWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let channel: DispatchIO
    private let cleanupWaiter: DispatchIOCleanupWaiter
    private let closeLock = NSLock()
    private var isClosed = false

    init(fileDescriptor: Int32 = STDOUT_FILENO) throws {
        let descriptor = dup(fileDescriptor)
        guard descriptor >= 0 else {
            throw StandardOutputWriterError.descriptorDuplicationFailed(errno)
        }

        let queue = DispatchQueue(label: "PrivateHeaderKit.ProcessRunner.stdout")
        let cleanupWaiter = DispatchIOCleanupWaiter()
        self.queue = queue
        self.cleanupWaiter = cleanupWaiter
        self.channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: queue
        ) { _ in
            _ = Darwin.close(descriptor)
            cleanupWaiter.complete()
        }
        channel.setLimit(lowWater: 1)
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try Task.checkCancellation()
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let completion = DispatchIOWriteCompletion(continuation)
                    channel.write(offset: 0, data: dispatchData, queue: queue) {
                        done,
                        _,
                        errorCode in
                        if errorCode != 0 {
                            completion.fail(errorCode: errorCode)
                        } else if done {
                            completion.succeed()
                        }
                    }
                }
            } onCancel: {
                self.stop()
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
    }

    func finish() async {
        stop()
        await cleanupWaiter.wait()
    }

    func cancel() {
        stop()
    }

    private func stop() {
        close(flags: .stop)
    }

    private func close(flags: DispatchIO.CloseFlags) {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        channel.close(flags: flags)
    }
}

struct StreamingOutputCollector {
    static let maximumLineByteCount = 128 * 1024

    private var pendingBytes: [UInt8] = []
    private var discardedPendingByteCount = 0
    private(set) var lastLines: [String] = []

    mutating func consume(_ bytes: [UInt8]) {
        var segmentStart = bytes.startIndex
        for index in bytes.indices where bytes[index] == UInt8(ascii: "\n") {
            appendPending(bytes[segmentStart..<index])
            consumePendingLine()
            segmentStart = bytes.index(after: index)
        }
        if segmentStart != bytes.endIndex {
            appendPending(bytes[segmentStart...])
        }
    }

    mutating func finish() {
        if !pendingBytes.isEmpty || discardedPendingByteCount > 0 {
            consumePendingLine()
        }
        pendingBytes.removeAll(keepingCapacity: false)
    }

    private mutating func appendPending(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }

        let maximumCount = Self.maximumLineByteCount
        if bytes.count >= maximumCount {
            discardedPendingByteCount += pendingBytes.count + bytes.count - maximumCount
            pendingBytes.removeAll(keepingCapacity: true)
            pendingBytes.append(contentsOf: bytes.suffix(maximumCount))
        } else {
            let overflow = max(0, pendingBytes.count + bytes.count - maximumCount)
            if overflow > 0 {
                pendingBytes.removeFirst(overflow)
                discardedPendingByteCount += overflow
            }
            pendingBytes.append(contentsOf: bytes)
        }

        // When the retained suffix begins in the middle of a valid scalar, discard the
        // continuation bytes too. Invalid bytes elsewhere still follow String(decoding:)'s
        // replacement-character contract.
        while discardedPendingByteCount > 0,
              let first = pendingBytes.first,
              first & 0b1100_0000 == 0b1000_0000
        {
            pendingBytes.removeFirst()
            discardedPendingByteCount += 1
        }
    }

    private mutating func consumePendingLine() {
        var line = String(decoding: pendingBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if discardedPendingByteCount > 0 {
            line = "[truncated \(discardedPendingByteCount) bytes] \(line)"
        }
        pendingBytes.removeAll(keepingCapacity: true)
        discardedPendingByteCount = 0
        guard !line.isEmpty else { return }
        appendLastLine(line, to: &lastLines)
    }
}

private func appendLastLine(_ line: String, to lines: inout [String]) {
    lines.append(line)
    if lines.count > 8 {
        lines.removeFirst(lines.count - 8)
    }
}
#endif
