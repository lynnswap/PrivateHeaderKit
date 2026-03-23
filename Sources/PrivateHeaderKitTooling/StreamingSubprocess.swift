import Dispatch
import Foundation

#if os(macOS)
private final class StreamingOutputCollector: @unchecked Sendable {
    private let maxLastLines = 8
    private let streamOutput: Bool
    private let passthrough: @Sendable (Data) -> Void

    private var buffer = ""
    private var lastLines: [String] = []
    private var wasKilled = false

    init(streamOutput: Bool, passthrough: @escaping @Sendable (Data) -> Void) {
        self.streamOutput = streamOutput
        self.passthrough = passthrough
    }

    func consume(_ data: Data) {
        if streamOutput {
            passthrough(data)
        }

        buffer += String(decoding: data, as: UTF8.self)
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(..<range.upperBound)
            if !line.isEmpty {
                appendLastLine(line)
            }
        }
    }

    func finish() {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            appendLastLine(remainder)
        }
        buffer = ""
    }

    func makeResult(status: Int32, terminationReason: Process.TerminationReason) -> StreamingCommandResult {
        var lastLines = self.lastLines
        var wasKilled = self.wasKilled

        if terminationReason == .uncaughtSignal {
            wasKilled = true
            lastLines.append("Terminated by signal \(status)")
            if lastLines.count > maxLastLines {
                lastLines.removeFirst(lastLines.count - maxLastLines)
            }
        } else if status != 0, lastLines.isEmpty {
            lastLines.append("Exited with status \(status)")
        }

        return StreamingCommandResult(status: status, wasKilled: wasKilled, lastLines: lastLines)
    }

    private func appendLastLine(_ line: String) {
        lastLines.append(line)
        if lastLines.count > maxLastLines {
            lastLines.removeFirst(lastLines.count - maxLastLines)
        }
        if line.lowercased().contains("killed: 9") {
            wasKilled = true
        }
    }
}

internal func makeConfiguredProcess(
    _ command: [String],
    env: [String: String]?,
    cwd: URL?
) throws -> (Process, FileHandle) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    if let cwd {
        process.currentDirectoryURL = cwd
    }

    var environment = ProcessInfo.processInfo.environment
    if let env {
        for (key, value) in env {
            environment[key] = value
        }
    }
    process.environment = environment

    guard let stdinHandle = FileHandle(forReadingAtPath: "/dev/null") else {
        throw ToolingError.message("failed to open /dev/null for subprocess stdin")
    }
    process.standardInput = stdinHandle

    return (process, stdinHandle)
}

internal func launchConfiguredProcess(_ process: Process, command: [String]) throws {
    do {
        try process.run()
    } catch {
        throw ToolingError.processLaunchFailed(command: command, underlying: String(describing: error))
    }
}

internal func runStreamingSubprocess(
    _ command: [String],
    env: [String: String]? = nil,
    cwd: URL? = nil,
    streamOutput: Bool = true,
    onLaunch: ((Int32) -> Void)? = nil,
    onCleanup: ((Int32) -> Void)? = nil,
    passthrough: @escaping @Sendable (Data) -> Void
) throws -> StreamingCommandResult {
    let (process, stdinHandle) = try makeConfiguredProcess(command, env: env, cwd: cwd)
    defer { try? stdinHandle.close() }

    let outputPipe = Pipe()
    let outputReadHandle = outputPipe.fileHandleForReading
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    try launchConfiguredProcess(process, command: command)

    let pid = process.processIdentifier
    onLaunch?(pid)
    defer { onCleanup?(pid) }

    try? outputPipe.fileHandleForWriting.close()
    defer {
        try? outputReadHandle.close()
    }

    let collector = StreamingOutputCollector(streamOutput: streamOutput, passthrough: passthrough)
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        while true {
            let data = outputReadHandle.availableData
            if data.isEmpty {
                collector.finish()
                group.leave()
                return
            }
            collector.consume(data)
        }
    }

    process.waitUntilExit()
    group.wait()

    return collector.makeResult(status: process.terminationStatus, terminationReason: process.terminationReason)
}

public func runStreamingSubprocess(
    _ command: [String],
    env: [String: String]? = nil,
    cwd: URL? = nil,
    streamOutput: Bool = true,
    onLaunch: ((Int32) -> Void)? = nil,
    onCleanup: ((Int32) -> Void)? = nil
) throws -> StreamingCommandResult {
    try runStreamingSubprocess(
        command,
        env: env,
        cwd: cwd,
        streamOutput: streamOutput,
        onLaunch: onLaunch,
        onCleanup: onCleanup,
        passthrough: { data in
            FileHandle.standardOutput.write(data)
        }
    )
}
#endif
