import Foundation

public struct StreamingCommandResult {
    public let status: Int32
    public let wasKilled: Bool
    public let lastLines: [String]

    public init(status: Int32, wasKilled: Bool, lastLines: [String]) {
        self.status = status
        self.wasKilled = wasKilled
        self.lastLines = lastLines
    }
}

public protocol CommandRunning {
    func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) throws -> String
    func runSimple(_ command: [String], env: [String: String]?, cwd: URL?) throws
    func runStreaming(_ command: [String], env: [String: String]?, cwd: URL?) throws -> StreamingCommandResult
    func runStreaming(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        streamOutput: Bool,
        onLaunch: ((Int32) -> Void)?,
        onCleanup: ((Int32) -> Void)?
    ) throws -> StreamingCommandResult
}

public extension CommandRunning {
    func runStreaming(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        streamOutput _: Bool,
        onLaunch _: ((Int32) -> Void)?,
        onCleanup _: ((Int32) -> Void)?
    ) throws -> StreamingCommandResult {
        try runStreaming(command, env: env, cwd: cwd)
    }
}

#if os(macOS)
public final class ProcessRunner: CommandRunning {
    public init() {}

    public func runCapture(_ command: [String], env: [String: String]? = nil, cwd: URL? = nil) throws -> String {
        let (status, stdout, stderr) = try runProcessCapture(command, env: env, cwd: cwd)
        if status != 0 {
            throw ToolingError.commandFailed(command: command, status: status, stderr: stderr)
        }
        return stdout
    }

    public func runSimple(_ command: [String], env: [String: String]? = nil, cwd: URL? = nil) throws {
        let result = try runStreaming(command, env: env, cwd: cwd)
        if result.status == 0 { return }
        let stderr = result.lastLines.joined(separator: "\n")
        throw ToolingError.commandFailed(command: command, status: result.status, stderr: stderr)
    }

    public func runStreaming(_ command: [String], env: [String: String]? = nil, cwd: URL? = nil) throws -> StreamingCommandResult {
        try runStreaming(
            command,
            env: env,
            cwd: cwd,
            streamOutput: true,
            onLaunch: nil,
            onCleanup: nil
        )
    }

    public func runStreaming(
        _ command: [String],
        env: [String: String]? = nil,
        cwd: URL? = nil,
        streamOutput: Bool,
        onLaunch: ((Int32) -> Void)?,
        onCleanup: ((Int32) -> Void)?
    ) throws -> StreamingCommandResult {
        try runStreamingSubprocess(
            command,
            env: env,
            cwd: cwd,
            streamOutput: streamOutput,
            onLaunch: { pid in
                gActiveToolingSubprocessPid = pid
                onLaunch?(pid)
            },
            onCleanup: { pid in
                if gActiveToolingSubprocessPid == pid {
                    gActiveToolingSubprocessPid = 0
                }
                onCleanup?(pid)
            }
        )
    }

    private func runProcessCapture(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) throws -> (Int32, String, String) {
        let (process, stdinHandle) = try makeConfiguredProcess(command, env: env, cwd: cwd)
        defer { try? stdinHandle.close() }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReadHandle = stdoutPipe.fileHandleForReading
        let stderrReadHandle = stderrPipe.fileHandleForReading
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try launchConfiguredProcess(process, command: command)
        let pid = process.processIdentifier
        gActiveToolingSubprocessPid = pid
        defer {
            if gActiveToolingSubprocessPid == pid {
                gActiveToolingSubprocessPid = 0
            }
        }
        // Close the parent-side write handles so reads complete at EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        defer {
            try? stdoutReadHandle.close()
            try? stderrReadHandle.close()
        }

        // Drain both pipes concurrently before (and while) waiting for exit, otherwise a large amount
        // of output can fill the pipe buffers and deadlock the child process.
        let group = DispatchGroup()
        final class DataBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Data()

            func set(_ data: Data) {
                lock.lock()
                value = data
                lock.unlock()
            }

            func get() -> Data {
                lock.lock()
                let data = value
                lock.unlock()
                return data
            }
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdoutReadHandle.readDataToEndOfFile())
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrReadHandle.readDataToEndOfFile())
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let stdoutText = String(data: stdoutBox.get(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrBox.get(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdoutText, stderrText)
    }
}
#else
public final class ProcessRunner: CommandRunning {
    public init() {}

    public func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) throws -> String {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }

    public func runSimple(_ command: [String], env: [String: String]?, cwd: URL?) throws {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }

    public func runStreaming(_ command: [String], env: [String: String]?, cwd: URL?) throws -> StreamingCommandResult {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }

    public func runStreaming(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        streamOutput _: Bool,
        onLaunch _: ((Int32) -> Void)?,
        onCleanup _: ((Int32) -> Void)?
    ) throws -> StreamingCommandResult {
        throw ToolingError.unsupported("process execution is not available on this platform")
    }
}
#endif
