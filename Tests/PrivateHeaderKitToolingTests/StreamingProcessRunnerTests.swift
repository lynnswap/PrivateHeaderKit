import Foundation
import Testing
@testable import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

#if os(macOS)
private enum StreamingProcessRunnerTestError: Error {
    case failedToDuplicateStdin
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

private func shellCommand(_ script: String) -> [String] {
    ["/bin/zsh", "-lc", script]
}

private func fileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
}

private func withClosedStdin<T>(_ body: () throws -> T) throws -> T {
    let saved = dup(STDIN_FILENO)
    guard saved != -1 else {
        throw StreamingProcessRunnerTestError.failedToDuplicateStdin
    }

    _ = close(STDIN_FILENO)
    defer {
        _ = dup2(saved, STDIN_FILENO)
        _ = close(saved)
    }

    return try body()
}

@Suite struct StreamingProcessRunnerTests {
    @Test func helperCapturesStdoutAndStderrAndForwardsPassthrough() throws {
        let passthrough = LockedDataBox()

        let result = try runStreamingSubprocess(
            shellCommand("print -r -- stdout-line; print -u2 -- stderr-line; print -r -- tail-line"),
            streamOutput: true,
            passthrough: { data in
                passthrough.append(data)
            }
        )

        let forwarded = String(data: passthrough.snapshot(), encoding: .utf8) ?? ""
        #expect(result.status == 0)
        #expect(result.wasKilled == false)
        #expect(result.lastLines.contains("stdout-line"))
        #expect(result.lastLines.contains("stderr-line"))
        #expect(result.lastLines.contains("tail-line"))
        #expect(forwarded.contains("stdout-line"))
        #expect(forwarded.contains("stderr-line"))
        #expect(forwarded.contains("tail-line"))
    }

    @Test func helperUsesNullDeviceWhenParentStdinIsClosed() throws {
        let result = try withClosedStdin {
            try runStreamingSubprocess(
                shellCommand("cat >/dev/null; print -r -- stdin-ok"),
                streamOutput: false,
                passthrough: { _ in }
            )
        }

        #expect(result.status == 0)
        #expect(result.wasKilled == false)
        #expect(result.lastLines.contains("stdin-ok"))
    }

    @Test func helperWrapsLaunchFailureWithCommandAndUnderlyingError() throws {
        let missingCWD = URL(fileURLWithPath: "/tmp/phk-missing-\(UUID().uuidString)", isDirectory: true)

        do {
            _ = try runStreamingSubprocess(
                ["/usr/bin/true"],
                cwd: missingCWD,
                streamOutput: false,
                passthrough: { _ in }
            )
            Issue.record("expected launch failure")
        } catch let error as ToolingError {
            guard case .processLaunchFailed(let command, let underlying) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(command == ["/usr/bin/true"])
            #expect(!underlying.isEmpty)
            #expect(error.description.contains("failed to launch process: /usr/bin/true"))
        }
    }

    @Test func runStreamingHandlesRepeatedShortLivedProcesses() throws {
        func runBatch(_ count: Int) throws {
            for _ in 0..<count {
                let result = try runStreamingSubprocess(
                    ["/usr/bin/true"],
                    streamOutput: false,
                    passthrough: { _ in }
                )
                #expect(result.status == 0)
                #expect(result.wasKilled == false)
            }
        }

        try runBatch(10)
        let baselineFDCount = fileDescriptorCount()
        try runBatch(200)
        let endFDCount = fileDescriptorCount()
        #expect(endFDCount <= baselineFDCount + 1)
    }
}
#endif
