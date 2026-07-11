import Foundation

#if os(macOS)
import Subprocess
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

public protocol CommandRunning: Sendable {
    func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) async throws -> String
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
        let configuration = try processConfiguration(command, env: env, cwd: cwd)
        do {
            let result = try await Subprocess.run(
                configuration,
                input: .none,
                // Capture is an exact command contract: callers parse complete JSON and build
                // metadata, so truncating at the library default would corrupt successful output.
                output: .bytes(limit: .max),
                error: .bytes(limit: .max)
            )
            // Subprocess completes its configured teardown and output drain before returning,
            // and can therefore return a signal termination result to a cancelled caller.
            // Preserve task cancellation only after that lifecycle cleanup has completed.
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
        } catch let error as SubprocessError {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw mapSubprocessError(error, command: command)
        }
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
        try await runStreaming(
            command,
            env: env,
            cwd: cwd,
            streamOutput: true,
            passthrough: { FileHandle.standardOutput.write($0) }
        )
    }

    func runStreaming(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        streamOutput: Bool,
        passthrough: @escaping @Sendable (Data) -> Void
    ) async throws -> StreamingCommandResult {
        try Task.checkCancellation()
        let configuration = try processConfiguration(command, env: env, cwd: cwd)
        do {
            let result = try await Subprocess.run(
                configuration,
                input: .none,
                output: .sequence,
                error: .combinedWithOutput
            ) { execution in
                var collector = StreamingOutputCollector()
                for try await buffer in execution.standardOutput {
                    let bytes = buffer.withUnsafeBytes { Array($0) }
                    if streamOutput {
                        passthrough(Data(bytes))
                    }
                    collector.consume(bytes)
                }
                collector.finish()
                return collector.lastLines
            }
            // See runCapture: cancellation is checked after Subprocess has awaited teardown
            // and output drain, so callers never outlive a child process or lose cancellation.
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
        } catch let error as SubprocessError {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw mapSubprocessError(error, command: command)
        }
    }

    private func processConfiguration(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) throws -> Configuration {
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
        let executable: Executable = executableValue.contains("/")
            ? .path(.init(executableValue))
            : .name(executableValue)
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: true,
                allowedDurationToNextStep: .seconds(5)
            ),
        ]
        return Configuration(
            executable: executable,
            arguments: Arguments(Array(command.dropFirst())),
            environment: Environment.inherit.updating(environmentUpdates),
            workingDirectory: cwd.map { .init($0.path) },
            platformOptions: platformOptions
        )
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
#else
    public func runCapture(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> String {
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
struct StreamingOutputCollector {
    private var pendingBytes: [UInt8] = []
    private(set) var lastLines: [String] = []

    mutating func consume(_ bytes: [UInt8]) {
        pendingBytes.append(contentsOf: bytes)
        var lineStart = pendingBytes.startIndex
        for index in pendingBytes.indices where pendingBytes[index] == UInt8(ascii: "\n") {
            consumeLine(pendingBytes[lineStart..<index])
            lineStart = pendingBytes.index(after: index)
        }
        if lineStart != pendingBytes.startIndex {
            pendingBytes.removeSubrange(..<lineStart)
        }
    }

    mutating func finish() {
        consumeLine(pendingBytes[...])
        pendingBytes.removeAll(keepingCapacity: false)
    }

    private mutating func consumeLine(_ bytes: ArraySlice<UInt8>) {
        let line = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
