import Foundation

public struct StreamingCommandResult {
    public let status: Int32
    public let wasKilled: Bool
    public let lastLines: [String]
}

public protocol CommandRunning {
    func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) throws -> String
    func runSimple(_ command: [String], env: [String: String]?, cwd: URL?) throws
    func runStreaming(_ command: [String], env: [String: String]?, cwd: URL?) throws -> StreamingCommandResult
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let cwd { process.currentDirectoryURL = cwd }

        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (k, v) in env { environment[k] = v }
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading

        var lastLines: [String] = []
        lastLines.reserveCapacity(8)
        var wasKilled = false

        try process.run()
        // Close the parent-side write handle so the reader reliably receives EOF.
        // (The child process still has its own write end inherited by exec.)
        try? pipe.fileHandleForWriting.close()

        var buffer = ""
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            FileHandle.standardOutput.write(data)

            let chunk = String(decoding: data, as: UTF8.self)
            buffer += chunk
            while let range = buffer.range(of: "\n") {
                let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeSubrange(..<range.upperBound)
                if line.isEmpty { continue }
                lastLines.append(line)
                if lastLines.count > 8 {
                    lastLines.removeFirst(lastLines.count - 8)
                }
                if line.lowercased().contains("killed: 9") {
                    wasKilled = true
                }
            }
        }

        process.waitUntilExit()
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastLines.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            if lastLines.count > 8 {
                lastLines.removeFirst(lastLines.count - 8)
            }
        }
        if process.terminationReason == .uncaughtSignal {
            wasKilled = true
            lastLines.append("Terminated by signal \(process.terminationStatus)")
            if lastLines.count > 8 {
                lastLines.removeFirst(lastLines.count - 8)
            }
        } else if process.terminationStatus != 0, lastLines.isEmpty {
            lastLines.append("Exited with status \(process.terminationStatus)")
        }

        return StreamingCommandResult(status: process.terminationStatus, wasKilled: wasKilled, lastLines: lastLines)
    }

    private func runProcessCapture(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        if let cwd { process.currentDirectoryURL = cwd }

        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (k, v) in env { environment[k] = v }
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Close the parent-side write handles so reads complete at EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
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
}
#endif
