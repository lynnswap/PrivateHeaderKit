import Foundation
import Testing
@testable import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

#if os(macOS)
private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func append(_ newData: Data, contains marker: Data) -> Bool {
        lock.lock()
        data.append(newData)
        let contains = data.range(of: marker) != nil
        lock.unlock()
        return contains
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

private final class AsyncEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        guard !isSignaled else {
            lock.unlock()
            return
        }
        isSignaled = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private func shellCommand(_ script: String) -> [String] {
    ["/bin/zsh", "-lc", script]
}

private func testHelperExecutableURL() throws -> URL {
    let fileManager = FileManager.default
    let helperName = "PrivateHeaderKitToolingTestHelper"
    let configurations = ["debug", "release", "Debug", "Release"]
    let environment = ProcessInfo.processInfo.environment

    func helperURL(in buildDir: URL) -> URL? {
        let entries = (try? fileManager.contentsOfDirectory(
            at: buildDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for configuration in configurations {
            let fallback = buildDir
                .appendingPathComponent(configuration, isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.isExecutableFile(atPath: fallback.path) {
                return fallback
            }
        }

        for entry in entries {
            for configuration in configurations {
                let candidate = entry
                    .appendingPathComponent(configuration, isDirectory: true)
                    .appendingPathComponent(helperName, isDirectory: false)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    let configuredBuildPaths = [
        environment["SWIFTPM_BUILD_DIR"],
        environment["SWIFT_BUILD_PATH"],
        environment["BUILD_DIR"],
        environment["SYMROOT"],
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }

    for buildPath in configuredBuildPaths {
        if let helperURL = helperURL(in: URL(fileURLWithPath: buildPath, isDirectory: true)) {
            return helperURL
        }
    }

    var current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    for _ in 0..<8 {
        if let helperURL = helperURL(
            in: current.appendingPathComponent(".build", isDirectory: true)
        ) {
            return helperURL
        }
        current.deleteLastPathComponent()
    }
    throw ToolingError.message("PrivateHeaderKitToolingTestHelper executable not found")
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderKitTooling-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func canAcquireExclusiveLock(at path: String) -> Bool {
    let descriptor = path.withCString { open($0, O_RDWR) }
    guard descriptor >= 0 else { return false }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
    _ = flock(descriptor, LOCK_UN)
    return true
}

@Suite
struct StreamingProcessRunnerTests {
    @Test func streamingCombinesOutputAndForwardsExactBytes() async throws {
        let passthrough = LockedDataBox()

        let result = try await ProcessRunner().runStreaming(
            shellCommand(
                "print -r -- stdout-line; print -u2 -- stderr-line; print -r -- tail-line"
            ),
            streamOutput: true,
            passthrough: { passthrough.append($0) }
        )

        let forwarded = String(decoding: passthrough.snapshot(), as: UTF8.self)
        #expect(result.status == 0)
        #expect(!result.wasKilled)
        #expect(result.lastLines.contains("stdout-line"))
        #expect(result.lastLines.contains("stderr-line"))
        #expect(result.lastLines.contains("tail-line"))
        #expect(forwarded.contains("stdout-line"))
        #expect(forwarded.contains("stderr-line"))
        #expect(forwarded.contains("tail-line"))
    }

    @Test func helperUsesNullDeviceWhenParentStdinIsClosed() async throws {
        let helper = try testHelperExecutableURL()
        let output = try await ProcessRunner().runCapture(
            [helper.path, "stdin-closed"],
            env: nil,
            cwd: nil
        )
        #expect(output.contains("stdin-ok"))
    }

    @Test func launchFailureKeepsCommandAndUnderlyingError() async throws {
        let missingCWD = URL(
            fileURLWithPath: "/tmp/phk-missing-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            _ = try await ProcessRunner().runCapture(
                ["/usr/bin/true"],
                env: nil,
                cwd: missingCWD
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

    @Test func configurationRejectsInvalidProcessValues() async throws {
        let nonFileWorkingDirectory = try #require(URL(string: "https://example.com/work"))
        let invalidConfigurations: [([String], [String: String]?, URL?)] = [
            ([], nil, nil),
            ([""], nil, nil),
            (["bad\0name"], nil, nil),
            (["/usr/bin/true", "bad\0argument"], nil, nil),
            (["/usr/bin/true"], ["": "value"], nil),
            (["/usr/bin/true"], ["A=B": "value"], nil),
            (["/usr/bin/true"], ["A\0B": "value"], nil),
            (["/usr/bin/true"], ["A": "value\0tail"], nil),
            (["/usr/bin/true"], nil, nonFileWorkingDirectory),
        ]

        for (command, environment, workingDirectory) in invalidConfigurations {
            do {
                _ = try await ProcessRunner().runCapture(
                    command,
                    env: environment,
                    cwd: workingDirectory
                )
                Issue.record("expected invalid process configuration: \(command)")
            } catch let error as ToolingError {
                guard case .invalidArgument = error else {
                    Issue.record("unexpected error: \(error)")
                    continue
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func nameEnvironmentAndWorkingDirectoryUseTypedConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("working-directory".utf8).write(
            to: directory.appendingPathComponent("typed-marker")
        )

        let output = try await ProcessRunner().runCapture(
            ["/bin/zsh", "-c", "print -nr -- \"$PHK_TYPED_CONFIG:$(< typed-marker)\""],
            env: ["PHK_TYPED_CONFIG": "updated"],
            cwd: directory
        )
        #expect(output == "updated:working-directory")

        let namedOutput = try await ProcessRunner().runCapture(
            ["env"],
            env: ["PHK_NAMED_EXECUTABLE": "present"],
            cwd: nil
        )
        #expect(namedOutput.contains("PHK_NAMED_EXECUTABLE=present"))
    }

    @Test func nonzeroCaptureExitMapsToTypedCommandFailure() async throws {
        let command = ["/bin/sh", "-c", "printf capture-error >&2; exit 23"]

        do {
            _ = try await ProcessRunner().runCapture(command, env: nil, cwd: nil)
            Issue.record("expected command failure")
        } catch let error as ToolingError {
            guard case .commandFailed(let failedCommand, let status, let standardError) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(failedCommand == command)
            #expect(status == 23)
            #expect(standardError == "capture-error")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func nonzeroStreamingExitKeepsCombinedTailAndSimpleMapsItToFailure() async throws {
        let command = [
            "/bin/sh", "-c",
            "printf 'stream-output\\n'; printf 'stream-error\\n' >&2; exit 24",
        ]
        let result = try await ProcessRunner().runStreaming(
            command,
            env: nil,
            cwd: nil,
            streamOutput: false,
            passthrough: { _ in }
        )

        #expect(result.status == 24)
        #expect(!result.wasKilled)
        #expect(result.lastLines == ["stream-output", "stream-error"])

        do {
            try await ProcessRunner().runSimple(command, env: nil, cwd: nil)
            Issue.record("expected command failure")
        } catch let error as ToolingError {
            guard case .commandFailed(let failedCommand, let status, let standardError) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(failedCommand == command)
            #expect(status == 24)
            #expect(standardError == "stream-output\nstream-error")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func captureCollectsCompleteOutputBeyondTheLibraryDefaultLimit() async throws {
        let helper = try testHelperExecutableURL()
        let output = try await ProcessRunner().runCapture(
            [helper.path, "large-capture"],
            env: nil,
            cwd: nil
        )
        #expect(output.utf8.count == 256 * 1024)
        #expect(output.allSatisfy { $0 == "x" })
    }

    @Test func precancelledTasksNeverSpawnCaptureOrStreamingChildren() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureMarker = directory.appendingPathComponent("capture-started").path
        let streamingMarker = directory.appendingPathComponent("streaming-started").path

        let captureTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().runCapture(
                ["/usr/bin/touch", captureMarker],
                env: nil,
                cwd: nil
            )
        }
        let streamingTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().runStreaming(
                ["/usr/bin/touch", streamingMarker],
                env: nil,
                cwd: nil
            )
        }

        do {
            _ = try await captureTask.value
            Issue.record("expected capture cancellation")
        } catch is CancellationError {
            // Cancellation wins before configuration or spawn.
        } catch {
            Issue.record("unexpected capture error: \(error)")
        }
        do {
            _ = try await streamingTask.value
            Issue.record("expected streaming cancellation")
        } catch is CancellationError {
            // Cancellation wins before configuration or spawn.
        } catch {
            Issue.record("unexpected streaming error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: captureMarker))
        #expect(!FileManager.default.fileExists(atPath: streamingMarker))
    }

    @Test func collectorPreservesUTF8AcrossInjectedChunkBoundariesAndKeepsEightLines() throws {
        let complete = Array(
            ("ignored-1\nignored-2\n" + (1...7).map { "line-\($0)\n" }.joined()
                + "emoji:😀\n").utf8
        )
        let emojiStart = try #require(complete.firstIndex(of: 0xF0))
        var collector = StreamingOutputCollector()
        collector.consume(Array(complete[..<(emojiStart + 2)]))
        collector.consume(Array(complete[(emojiStart + 2)...]))
        collector.finish()

        #expect(collector.lastLines == [
            "line-1", "line-2", "line-3", "line-4",
            "line-5", "line-6", "line-7", "emoji:😀",
        ])
    }

    @Test func helperOutputPreservesExactBytesAndTailLines() async throws {
        let helper = try testHelperExecutableURL()
        let passthrough = LockedDataBox()
        let expected = (1...9).map { "line-\($0)\n" }.joined() + "emoji:😀\nline-10\n"

        let result = try await ProcessRunner().runStreaming(
            [helper.path, "chunked-output"],
            streamOutput: true,
            passthrough: { passthrough.append($0) }
        )

        #expect(passthrough.snapshot() == Data(expected.utf8))
        #expect(result.lastLines == [
            "line-4", "line-5", "line-6", "line-7",
            "line-8", "line-9", "emoji:😀", "line-10",
        ])
    }

    @Test func signalTerminationUsesSignalStatusAndKilledFlag() async throws {
        let result = try await ProcessRunner().runStreaming(
            ["/bin/sh", "-c", "kill -TERM $$"],
            streamOutput: false,
            passthrough: { _ in }
        )

        #expect(result.status == SIGTERM)
        #expect(result.wasKilled)
        #expect(result.lastLines == ["Terminated by signal \(SIGTERM)"])
    }

    @Test func cancellationWaitsForWholeProcessGroupAndOutputDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("parent.lock").path
        let childLock = directory.appendingPathComponent("child.lock").path
        let helper = try testHelperExecutableURL()
        let readiness = AsyncEvent()
        let output = LockedDataBox()
        let readyMarker = Data("READY\n".utf8)

        let task = Task {
            defer { readiness.signal() }
            return try await ProcessRunner().runStreaming(
                [helper.path, "process-group", parentLock, childLock],
                streamOutput: true,
                passthrough: { data in
                    if output.append(data, contains: readyMarker) {
                        readiness.signal()
                    }
                }
            )
        }
        await readiness.wait()
        guard output.snapshot().range(of: readyMarker) != nil else {
            do {
                _ = try await task.value
                Issue.record("process group helper completed before readiness")
            } catch {
                Issue.record("process group helper failed before readiness: \(error)")
            }
            return
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Cancellation is preserved after graceful process-group teardown.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(output.snapshot().range(of: readyMarker) != nil)
        #expect(canAcquireExclusiveLock(at: parentLock))
        #expect(canAcquireExclusiveLock(at: childLock))
    }
}
#endif
