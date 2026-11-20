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

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

private final class ToolingTestBundleMarker: NSObject {}

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

    let testProductsDirectory = Bundle(for: ToolingTestBundleMarker.self)
        .bundleURL
        .deletingLastPathComponent()
    let bundledHelper = testProductsDirectory
        .appendingPathComponent(helperName, isDirectory: false)
    if fileManager.isExecutableFile(atPath: bundledHelper.path) {
        return bundledHelper
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

private func writeExecutableScript(_ body: String, to url: URL) throws {
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path
    )
}

private func canAcquireExclusiveLock(at path: String) -> Bool {
    let descriptor = path.withCString { open($0, O_RDWR) }
    guard descriptor >= 0 else { return false }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
    _ = flock(descriptor, LOCK_UN)
    return true
}

private func processIdentifier(from output: String, prefix: String = "CHILD_PID=") throws -> pid_t {
    for line in output.split(whereSeparator: \.isNewline) {
        guard line.hasPrefix(prefix),
              let processIdentifier = pid_t(line.dropFirst(prefix.count)),
              processIdentifier > 0
        else {
            continue
        }
        return processIdentifier
    }
    throw ToolingError.message("process-group helper did not report its child PID")
}

private struct RecordedProcessIdentity: Equatable {
    let processIdentifier: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

private func recordedProcessIdentity(at path: String) throws -> RecordedProcessIdentity {
    let data = try Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false))
    let output = String(decoding: data, as: UTF8.self)
    let processIdentifier = try processIdentifier(from: output, prefix: "PID=")
    for line in output.split(whereSeparator: \.isNewline) {
        guard line.hasPrefix("START=") else { continue }
        let components = line
            .dropFirst("START=".count)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let startSeconds = UInt64(components[0]),
              let startMicroseconds = UInt64(components[1])
        else {
            break
        }
        return RecordedProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds
        )
    }
    throw ToolingError.message("process-group helper did not report its process start identity")
}

private func recordedProcessIdentifier(at path: String) throws -> pid_t {
    try recordedProcessIdentity(at: path).processIdentifier
}

private func liveProcessIdentity(_ processIdentifier: pid_t) throws -> RecordedProcessIdentity? {
    guard processIdentifier > 0 else { return nil }
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    errno = 0
    let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            pointer,
            expectedSize
        )
    }
    let errorCode = errno
    if actualSize == expectedSize {
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return RecordedProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }
    if actualSize <= 0, errorCode == 0 || errorCode == ESRCH {
        return nil
    }
    throw ToolingError.message(
        "inspect process \(processIdentifier) failed (errno \(errorCode == 0 ? EIO : errorCode))"
    )
}

private func processIsLive(_ processIdentifier: pid_t) throws -> Bool {
    try liveProcessIdentity(processIdentifier) != nil
}

private func fixtureStillHoldsExclusiveLock(at path: String) -> Bool {
    let descriptor = path.withCString { open($0, O_RDWR) }
    guard descriptor >= 0 else { return false }
    defer { _ = close(descriptor) }
    errno = 0
    guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
        _ = flock(descriptor, LOCK_UN)
        return false
    }
    return errno == EWOULDBLOCK || errno == EAGAIN
}

private func terminateRecordedProcessIfLive(at path: String) {
    guard let recordedIdentity = try? recordedProcessIdentity(at: path),
          fixtureStillHoldsExclusiveLock(at: path),
          (try? liveProcessIdentity(recordedIdentity.processIdentifier)) == recordedIdentity
    else {
        return
    }
    _ = kill(recordedIdentity.processIdentifier, SIGKILL)
}

private func waitForProcessGroupLocks(parent: String, child: String) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: parent),
           FileManager.default.fileExists(atPath: child),
           !canAcquireExclusiveLock(at: parent),
           !canAcquireExclusiveLock(at: child)
        {
            return
        }
        await Task.yield()
    }
    throw ToolingError.message("process group did not acquire both test locks")
}

private enum InjectedConsumerError: Error {
    case failure
}

@Suite
struct StreamingProcessRunnerTests {
    @Test func bufferedRunCombinesStandardOutputAndStandardError() async throws {
        let result = try await ProcessRunner().runBuffered(
            shellCommand(
                "print -r -- stdout-line; print -u2 -- stderr-line; print -r -- tail-line"
            ),
            env: nil,
            cwd: nil
        )

        #expect(result.status == 0)
        #expect(!result.wasKilled)
        #expect(result.lastLines.contains("stdout-line"))
        #expect(result.lastLines.contains("stderr-line"))
        #expect(result.lastLines.contains("tail-line"))
        #expect(result.terminationObservedAtUnixEpochMicroseconds != nil)
    }

    @Test func bufferedRunnerRetainsCombinedTailWithoutForwardingOutput() async throws {
        let helper = try testHelperExecutableURL()

        let output = try await ProcessRunner().runCapture(
            [helper.path, "buffered-output"],
            env: nil,
            cwd: nil
        )

        #expect(output == "buffered-ok\n")
    }

    @Test func simpleRunnerForwardsStandardOutputAndWithholdsStandardError() async throws {
        let helper = try testHelperExecutableURL()

        let output = try await ProcessRunner().runCapture(
            [helper.path, "simple-output"],
            env: nil,
            cwd: nil
        )

        #expect(output == "simple-stdout\n")
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

    @Test func bareExecutableUsesOnlyEffectivePATHWhileRelativePathUsesWorkingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let physicalRoot = root.appendingPathComponent("physical", isDirectory: true)
        let workingDirectory = physicalRoot.appendingPathComponent("cwd", isDirectory: true)
        let pathDirectory = physicalRoot.appendingPathComponent("path", isDirectory: true)
        let directoryCandidateRoot = root.appendingPathComponent(
            "directory-candidate",
            isDirectory: true
        )
        let brokenCandidateRoot = root.appendingPathComponent(
            "broken-candidate",
            isDirectory: true
        )
        let workingDirectoryAlias = root.appendingPathComponent("cwd-alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pathDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directoryCandidateRoot.appendingPathComponent(
                "phk-path-probe",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: brokenCandidateRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: workingDirectoryAlias,
            withDestinationURL: workingDirectory
        )

        let executableName = "phk-path-probe"
        try writeExecutableScript(
            "printf cwd-shadow",
            to: workingDirectory.appendingPathComponent(executableName)
        )
        try writeExecutableScript(
            "printf selected-path",
            to: pathDirectory.appendingPathComponent(executableName)
        )
        try writeExecutableScript(
            "printf relative-cwd",
            to: workingDirectory.appendingPathComponent("relative-tool")
        )
        let brokenCandidate = brokenCandidateRoot.appendingPathComponent(executableName)
        try Data("#!/privateheaderkit/missing-interpreter\n".utf8).write(
            to: brokenCandidate
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: brokenCandidate.path
        )

        let namedOutput = try await ProcessRunner().runCapture(
            [executableName],
            env: ["PATH": "../path"],
            cwd: workingDirectoryAlias
        )
        #expect(namedOutput == "selected-path")

        let directoryShadowOutput = try await ProcessRunner().runCapture(
            [executableName],
            env: ["PATH": "\(directoryCandidateRoot.path):\(pathDirectory.path)"],
            cwd: workingDirectoryAlias
        )
        #expect(directoryShadowOutput == "selected-path")

        let brokenCandidatePATH = "\(brokenCandidateRoot.path):\(pathDirectory.path)"
        let brokenCandidateCapture = try await ProcessRunner().runCapture(
            [executableName],
            env: ["PATH": brokenCandidatePATH],
            cwd: workingDirectoryAlias
        )
        #expect(brokenCandidateCapture == "selected-path")

        let brokenCandidateBuffered = try await ProcessRunner().runBuffered(
            [executableName],
            env: ["PATH": brokenCandidatePATH],
            cwd: workingDirectoryAlias
        )
        #expect(brokenCandidateBuffered.status == 0)
        #expect(brokenCandidateBuffered.lastLines == ["selected-path"])

        do {
            _ = try await ProcessRunner().runCapture(
                [executableName],
                env: ["PATH": brokenCandidateRoot.path],
                cwd: workingDirectoryAlias
            )
            Issue.record("expected all failed PATH candidates to preserve launch failure")
        } catch let error as ToolingError {
            guard case .processLaunchFailed(let command, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(command == [executableName])
        }

        let relativeOutput = try await ProcessRunner().runCapture(
            ["./relative-tool"],
            env: ["PATH": ""],
            cwd: workingDirectoryAlias
        )
        #expect(relativeOutput == "relative-cwd")

        do {
            _ = try await ProcessRunner().runCapture(
                [executableName],
                env: ["PATH": ""],
                cwd: workingDirectoryAlias
            )
            Issue.record("expected exact empty PATH to reject cwd executable")
        } catch let error as ToolingError {
            guard case .processLaunchFailed(let command, let underlying) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(command == [executableName])
            #expect(underlying.contains("executable not found in PATH"))
        }

        do {
            _ = try await ProcessRunner().runCapture(
                ["true"],
                env: ["PATH": ""],
                cwd: nil
            )
            Issue.record("expected exact empty PATH to reject system fallback executable")
        } catch let error as ToolingError {
            guard case .processLaunchFailed(let command, _) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(command == ["true"])
        }
    }

    @Test func fileInputReceiverCanExitWithoutReadingAndKeepsItsFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.bin")
        try Data(repeating: 0x63, count: 2 * 1024 * 1024).write(to: input)
        let command = ["/bin/sh", "-c", "printf 'receiver rejected input' >&2; exit 17"]
        do {
            try await ProcessRunner().runWithInputFile(command, inputFile: input, env: nil, cwd: nil)
            Issue.record("a rejecting input receiver unexpectedly succeeded")
        } catch ToolingError.commandFailed(let actualCommand, let status, let stderr) {
            #expect(actualCommand == command)
            #expect(status == 17)
            #expect(stderr == "receiver rejected input")
        }
        #expect(FileManager.default.fileExists(atPath: input.path))
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

    @Test func nonzeroExitKeepsBoundedOutputAndSimpleReportsStandardError() async throws {
        let command = [
            "/bin/sh", "-c",
            "printf 'stream-output\\n'; printf 'stream-error\\n' >&2; exit 24",
        ]
        let result = try await ProcessRunner().runBuffered(command, env: nil, cwd: nil)

        #expect(result.status == 24)
        #expect(!result.wasKilled)
        #expect(result.emittedOutput.lines == ["stream-output", "stream-error"])
        #expect(result.lastLines == ["stream-output", "stream-error"])
        #expect(result.diagnosticLines == [
            "stream-output",
            "stream-error",
            "Exited with status 24",
        ])

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
            #expect(standardError == "stream-error")
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

    @Test func chunkedCaptureForwardsCompleteStandardOutput() async throws {
        let helper = try testHelperExecutableURL()
        let captured = LockedDataBox()

        try await ProcessRunner().runCaptureChunks(
            [helper.path, "large-capture"],
            env: nil,
            cwd: nil,
            consumeStandardOutput: { captured.append($0) }
        )

        let output = captured.snapshot()
        #expect(output.count == 256 * 1024)
        #expect(output.allSatisfy { $0 == UInt8(ascii: "x") })
    }

    @Test func chunkedCaptureFailureKeepsStatusAndStrictlyBoundedStandardError() async throws {
        let helper = try testHelperExecutableURL()
        let command = [
            helper.path,
            "large-stderr-failure",
            String(BoundedProcessOutput.maximumRenderedLineByteCount + 4_096),
        ]

        do {
            try await ProcessRunner().runCaptureChunks(
                command,
                env: nil,
                cwd: nil,
                consumeStandardOutput: { _ in }
            )
            Issue.record("expected command failure")
        } catch let error as ToolingError {
            guard case .commandFailed(let failedCommand, let status, let standardError) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(failedCommand == command)
            #expect(status == 19)
            let lines = standardError.split(separator: "\n").map(String.init)
            #expect(lines.first?.hasPrefix("x") == true)
            #expect(lines.first?.contains(" … ") == true)
            #expect(lines.first?.hasSuffix("x") == true)
            #expect(lines.first?.utf8.count == BoundedProcessOutput.maximumRenderedLineByteCount)
            #expect(lines.contains("final-diagnostic"))
            #expect(lines.contains { $0.hasPrefix("[omitted 0 lines and at least ") })
            #expect(
                standardError.utf8.count
                    <= BoundedProcessOutput.maximumRenderedByteCount
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func precancelledTasksNeverSpawnCaptureChunkedOrBufferedChildren() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureMarker = directory.appendingPathComponent("capture-started").path
        let chunkedMarker = directory.appendingPathComponent("chunked-started").path
        let bufferedMarker = directory.appendingPathComponent("buffered-started").path

        let captureTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().runCapture(
                ["/usr/bin/touch", captureMarker],
                env: nil,
                cwd: nil
            )
        }
        let chunkedTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().runCaptureChunks(
                ["/usr/bin/touch", chunkedMarker],
                env: nil,
                cwd: nil,
                consumeStandardOutput: { _ in }
            )
        }
        let bufferedTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner().runBuffered(
                ["/usr/bin/touch", bufferedMarker],
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
            try await chunkedTask.value
            Issue.record("expected chunked capture cancellation")
        } catch is CancellationError {
            // Cancellation wins before configuration or spawn.
        } catch {
            Issue.record("unexpected chunked capture error: \(error)")
        }
        do {
            _ = try await bufferedTask.value
            Issue.record("expected buffered cancellation")
        } catch is CancellationError {
            // Cancellation wins before configuration or spawn.
        } catch {
            Issue.record("unexpected buffered error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: captureMarker))
        #expect(!FileManager.default.fileExists(atPath: chunkedMarker))
        #expect(!FileManager.default.fileExists(atPath: bufferedMarker))
    }

    @Test func collectorPreservesUTF8AcrossChunksAndRetainsHeadAndTail() throws {
        let complete = Array(((1...19).map { "line-\($0)\n" }.joined() + "emoji:😀\n").utf8)
        let emojiStart = try #require(complete.firstIndex(of: 0xF0))
        var collector = BoundedProcessOutputCollector()
        collector.consume(Array(complete[..<(emojiStart + 2)]))
        collector.consume(Array(complete[(emojiStart + 2)...]))
        let output = collector.finish()

        #expect(output.lines == [
            "line-1", "line-2", "line-3", "line-4", "line-5", "line-6", "line-7",
            "line-8", "[omitted 4 lines and at least 27 bytes]", "line-13", "line-14",
            "line-15",
            "line-16", "line-17", "line-18", "line-19", "emoji:😀",
        ])
        #expect(output.omittedLineCount == 4)
        #expect(output.omittedSourceByteCountLowerBound == 27)
    }

    @Test func collectorRetainsBothEndsOfLongLineWithinOneKiB() throws {
        let line = "BEGIN-" + String(repeating: "x", count: 20_000) + "-END"
        let bytes = Array(line.utf8)
        var collector = BoundedProcessOutputCollector()
        for chunkStart in stride(from: 0, to: bytes.count, by: 997) {
            collector.consume(Array(bytes[chunkStart..<min(chunkStart + 997, bytes.count)]))
        }
        let output = collector.finish()

        let retained = try #require(output.lines.first)
        #expect(retained.hasPrefix("BEGIN-"))
        #expect(retained.contains(" … "))
        #expect(retained.hasSuffix("-END"))
        #expect(retained.utf8.count == BoundedProcessOutput.maximumRenderedLineByteCount)
        #expect(output.lines.last?.hasPrefix("[omitted 0 lines and at least ") == true)
        #expect(output.omittedLineCount == 0)
        #expect(
            output.omittedSourceByteCountLowerBound
                == UInt(
                    line.utf8.count
                        - (BoundedProcessOutput.maximumRenderedLineByteCount * 8 * 2)
                )
        )
        #expect(output.text.utf8.count <= BoundedProcessOutput.maximumRenderedByteCount)
    }

    @Test func omittedWholeLineCountsRawSourceBytesBeforeTerminalEscaping() {
        var lines = (1...8).map { "head-\($0)" }
        lines.append("\u{001B}")
        lines += (1...8).map { "tail-\($0)" }

        let output = BoundedProcessOutput(lines: lines)

        #expect(output.omittedLineCount == 1)
        #expect(output.omittedSourceByteCountLowerBound == 1)
        #expect(output.lines[8] == "[omitted 1 lines and at least 1 bytes]")
    }

    @Test func hugeASCIIWhitespaceLineIsNotClassifiedAsEmittedContent() {
        var collector = BoundedProcessOutputCollector()
        collector.consume(Array(repeating: UInt8(ascii: " "), count: 100_000))

        let output = collector.finish()

        #expect(output.isEmpty)
        #expect(output.lines.isEmpty)
        #expect(output.omittedLineCount == 0)
        #expect(output.omittedSourceByteCountLowerBound == 0)
    }

    @Test func collectorTerminalSafesControlsAndInvalidIncompleteUTF8() throws {
        var collector = BoundedProcessOutputCollector()
        collector.consume([
            UInt8(ascii: "a"), 0x1B, UInt8(ascii: "\t"), 0x80, 0xF0, 0x9F,
        ])
        let output = collector.finish()

        #expect(output.lines == [#"a\u{001b}\t��"#])
        let line = try #require(output.lines.first)
        #expect(
            line.unicodeScalars.allSatisfy {
                switch $0.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    false
                default:
                    true
                }
            }
        )
    }

    @Test func resultInitializerCannotBypassOutputBounds() {
        let lines = (1...10_000).map { index in
            index == 1
                ? "head\u{001B}" + String(repeating: "x", count: 5_000)
                : "line-\(index)"
        }
        let result = StreamingCommandResult(status: 19, wasKilled: false, lastLines: lines)
        let output = result.emittedOutput

        #expect(output.lines.count == BoundedProcessOutput.maximumRenderedLineCount)
        #expect(output.lines.first?.hasPrefix(#"head\u{001b}"#) == true)
        #expect(output.lines[8].hasPrefix("[omitted 9984 lines and at least "))
        #expect(output.lines.last == "line-10000")
        #expect(output.omittedLineCount == 9_984)
        #expect(output.omittedSourceByteCountLowerBound > 0)
        #expect(
            output.lines.allSatisfy {
                $0.utf8.count <= BoundedProcessOutput.maximumRenderedLineByteCount
            }
        )
        #expect(output.text.utf8.count <= BoundedProcessOutput.maximumRenderedByteCount)
        #expect(result.lastLines.last == "line-10000")
        #expect(result.diagnosticLines.last == "Exited with status 19")
    }

    @Test func bufferedOutputDecodesUTF8SplitAcrossWrites() async throws {
        let helper = try testHelperExecutableURL()

        let result = try await ProcessRunner().runBuffered(
            [helper.path, "chunked-output"],
            env: nil,
            cwd: nil
        )

        #expect(result.emittedOutput.lines == [
            "line-1", "line-2", "line-3", "line-4", "line-5", "line-6", "line-7",
            "line-8", "line-9", "emoji:😀", "line-10",
        ])
        #expect(result.lastLines == result.emittedOutput.lines)
    }

    @Test func signalOnlyTerminationKeepsEmittedOutputEmptyAndRecordsObservationTime()
        async throws
    {
        let before = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let result = try await ProcessRunner().runBuffered(
            ["/bin/sh", "-c", "kill -TERM $$"],
            env: nil,
            cwd: nil
        )
        let after = UInt64(Date().timeIntervalSince1970 * 1_000_000)

        #expect(result.status == SIGTERM)
        #expect(result.wasKilled)
        #expect(result.emittedOutput.isEmpty)
        #expect(result.emittedOutput.lines.isEmpty)
        #expect(result.lastLines == ["Terminated by signal \(SIGTERM)"])
        #expect(result.diagnosticLines == [
            "No process diagnostic was emitted.",
            "Terminated by signal \(SIGTERM)",
        ])
        let observedAt = try #require(result.terminationObservedAtUnixEpochMicroseconds)
        #expect((before...after).contains(observedAt))
    }

    @Test func longExceptionRetainsNameReasonFirstApplicationFrameAndTail() async throws {
        let helper = try testHelperExecutableURL()
        let result = try await ProcessRunner().runBuffered(
            [helper.path, "long-exception-failure"],
            env: nil,
            cwd: nil
        )

        #expect(result.status == 19)
        #expect(!result.wasKilled)
        #expect(
            result.emittedOutput.lines.first
                == "*** Terminating app due to uncaught exception 'FixtureException', reason: 'fixture reason'"
        )
        #expect(
            result.emittedOutput.lines.contains(
                "2   PrivateHeaderKitToolingTestHelper frame-zero"
            )
        )
        #expect(result.emittedOutput.lines[8].hasPrefix("[omitted "))
        #expect(
            result.emittedOutput.lines.suffix(2) == [
                "libc++abi: terminating due to uncaught exception of type NSException",
                "final-diagnostic-tail",
            ]
        )
        #expect(result.emittedOutput.lines.count == 17)
        #expect(
            result.emittedOutput.text.utf8.count
                <= BoundedProcessOutput.maximumRenderedByteCount
        )
        #expect(result.lastLines.last == "final-diagnostic-tail")
        #expect(result.diagnosticLines.last == "Exited with status 19")
    }

    @Test(arguments: ["CHILD_PID=0\n", "CHILD_PID=-1\n"])
    func processIdentifierRejectsNonpositiveValues(_ output: String) {
        #expect(throws: ToolingError.self) {
            try processIdentifier(from: output)
        }
    }

    @Test func captureNormalLeaderExitCompletesOwnedProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childLock = directory.appendingPathComponent("normal-capture-child.lock").path
        defer { terminateRecordedProcessIfLive(at: childLock) }
        let helper = try testHelperExecutableURL()

        let output = try await ProcessRunner().runCapture(
            [helper.path, "process-group-normal-leader-exit", childLock],
            env: nil,
            cwd: nil
        )
        let childPID = try processIdentifier(from: output)
        #expect(try recordedProcessIdentifier(at: childLock) == childPID)
        #expect(try processIsLive(childPID) == false)
    }

    @Test func chunkedCaptureNormalLeaderExitCompletesOwnedProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childLock = directory.appendingPathComponent("normal-chunked-child.lock").path
        defer { terminateRecordedProcessIfLive(at: childLock) }
        let helper = try testHelperExecutableURL()
        let captured = LockedDataBox()

        try await ProcessRunner().runCaptureChunks(
            [helper.path, "process-group-normal-leader-exit", childLock],
            env: nil,
            cwd: nil,
            consumeStandardOutput: { captured.append($0) }
        )

        let childPID = try processIdentifier(
            from: String(decoding: captured.snapshot(), as: UTF8.self)
        )
        #expect(try recordedProcessIdentifier(at: childLock) == childPID)
        #expect(try processIsLive(childPID) == false)
    }

    @Test func bufferedNormalLeaderExitCompletesOwnedProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childLock = directory.appendingPathComponent("normal-streaming-child.lock").path
        defer { terminateRecordedProcessIfLive(at: childLock) }
        let helper = try testHelperExecutableURL()

        let result = try await ProcessRunner().runBuffered(
            [helper.path, "process-group-normal-leader-exit", childLock],
            env: nil,
            cwd: nil
        )
        let childPID = try processIdentifier(from: result.lastLines.joined(separator: "\n"))

        #expect(result.status == 0)
        #expect(!result.wasKilled)
        #expect(try recordedProcessIdentifier(at: childLock) == childPID)
        #expect(try processIsLive(childPID) == false)
    }

    @Test func bufferedCancellationAfterSpawnWaitsForWholeProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("parent.lock").path
        let childLock = directory.appendingPathComponent("child.lock").path
        defer {
            terminateRecordedProcessIfLive(at: parentLock)
            terminateRecordedProcessIfLive(at: childLock)
        }
        let helper = try testHelperExecutableURL()

        let task = Task {
            try await ProcessRunner().runBuffered(
                [helper.path, "process-group", parentLock, childLock],
                env: nil,
                cwd: nil
            )
        }
        try await waitForProcessGroupLocks(parent: parentLock, child: childLock)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Cancellation is reported after the process group has no live member.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try processIsLive(recordedProcessIdentifier(at: parentLock)) == false)
        #expect(try processIsLive(recordedProcessIdentifier(at: childLock)) == false)
    }

    @Test func captureCancellationAfterSpawnWaitsForWholeProcessGroupAndDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("capture-parent.lock").path
        let childLock = directory.appendingPathComponent("capture-child.lock").path
        defer {
            terminateRecordedProcessIfLive(at: parentLock)
            terminateRecordedProcessIfLive(at: childLock)
        }
        let helper = try testHelperExecutableURL()

        let task = Task {
            try await ProcessRunner().runCapture(
                [helper.path, "process-group", parentLock, childLock],
                env: nil,
                cwd: nil
            )
        }
        try await waitForProcessGroupLocks(parent: parentLock, child: childLock)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected capture cancellation")
        } catch is CancellationError {
            // Cancellation is returned only after the group has no live member and pipes drain.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try processIsLive(recordedProcessIdentifier(at: parentLock)) == false)
        #expect(try processIsLive(recordedProcessIdentifier(at: childLock)) == false)
    }

    @Test func consumerFailureWaitsForWholeProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("error-parent.lock").path
        let childLock = directory.appendingPathComponent("error-child.lock").path
        defer {
            terminateRecordedProcessIfLive(at: parentLock)
            terminateRecordedProcessIfLive(at: childLock)
        }
        let helper = try testHelperExecutableURL()

        do {
            try await ProcessRunner().runCaptureChunks(
                [helper.path, "process-group", parentLock, childLock],
                env: nil,
                cwd: nil,
                consumeStandardOutput: { data in
                    guard data.range(of: Data("READY\n".utf8)) != nil else { return }
                    throw InjectedConsumerError.failure
                }
            )
            Issue.record("expected consumer failure")
        } catch InjectedConsumerError.failure {
            // The consumer's failure is rethrown after the process group is terminated.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try processIsLive(recordedProcessIdentifier(at: parentLock)) == false)
        #expect(try processIsLive(recordedProcessIdentifier(at: childLock)) == false)
    }

    @Test func cancellationUnblocksSuspendedConsumerAndWaitsForProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("blocked-parent.lock").path
        let childLock = directory.appendingPathComponent("blocked-child.lock").path
        defer {
            terminateRecordedProcessIfLive(at: parentLock)
            terminateRecordedProcessIfLive(at: childLock)
        }
        let helper = try testHelperExecutableURL()
        let consumerEntered = AsyncEvent()
        let consumerRelease = AsyncEvent()

        let task = Task {
            defer { consumerEntered.signal() }
            return try await ProcessRunner().runCaptureChunks(
                [helper.path, "process-group", parentLock, childLock],
                env: nil,
                cwd: nil,
                consumeStandardOutput: { data in
                    guard data.range(of: Data("READY\n".utf8)) != nil else { return }
                    consumerEntered.signal()
                    try await withTaskCancellationHandler {
                        await consumerRelease.wait()
                        try Task.checkCancellation()
                    } onCancel: {
                        consumerRelease.signal()
                    }
                }
            )
        }
        await consumerEntered.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected suspended consumer cancellation")
        } catch is CancellationError {
            // The consumer resumes before the runner finishes terminating the process group.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try processIsLive(recordedProcessIdentifier(at: parentLock)) == false)
        #expect(try processIsLive(recordedProcessIdentifier(at: childLock)) == false)
    }
}
#endif
