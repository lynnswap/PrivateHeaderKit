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

    var value: Bool {
        lock.lock()
        let value = isSignaled
        lock.unlock()
        return value
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

private func spawnImmediateProcessGroupLeader() throws -> pid_t {
    var attributes: posix_spawnattr_t?
    let initializeStatus = posix_spawnattr_init(&attributes)
    guard initializeStatus == 0 else {
        throw ToolingError.message(
            "initialize process attributes failed (errno \(initializeStatus))"
        )
    }
    defer { posix_spawnattr_destroy(&attributes) }

    let processGroupStatus = posix_spawnattr_setpgroup(&attributes, 0)
    guard processGroupStatus == 0 else {
        throw ToolingError.message(
            "configure child process group failed (errno \(processGroupStatus))"
        )
    }
    let flagsStatus = posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETPGROUP)
    )
    guard flagsStatus == 0 else {
        throw ToolingError.message(
            "configure process attributes failed (errno \(flagsStatus))"
        )
    }

    let executable = "/usr/bin/true"
    guard let argument = strdup(executable) else {
        throw ToolingError.message("allocate process argument failed")
    }
    defer { free(argument) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
    var processIdentifier: pid_t = 0
    let spawnStatus = executable.withCString { executablePointer in
        arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &processIdentifier,
                executablePointer,
                nil,
                &attributes,
                buffer.baseAddress,
                environ
            )
        }
    }
    guard spawnStatus == 0 else {
        throw ToolingError.message("spawn process failed (errno \(spawnStatus))")
    }
    return processIdentifier
}

private func exitedChildRemainsWaitable(_ processIdentifier: pid_t) throws -> Bool {
    while true {
        var info = siginfo_t()
        errno = 0
        guard waitid(
            P_PID,
            id_t(processIdentifier),
            &info,
            WEXITED | WNOWAIT | WNOHANG
        ) == 0 else {
            let errorCode = errno
            if errorCode == EINTR {
                continue
            }
            throw ToolingError.message(
                "inspect waitable child failed (errno \(errorCode == 0 ? EIO : errorCode))"
            )
        }
        return info.si_pid == processIdentifier
    }
}

private func reapChild(_ processIdentifier: pid_t) {
    var status: Int32 = 0
    while waitpid(processIdentifier, &status, 0) < 0, errno == EINTR {}
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

private func makePipeDescriptors() throws -> (read: Int32, write: Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard pipe(&descriptors) == 0 else {
        throw ToolingError.message("pipe failed (errno \(errno))")
    }
    return (read: descriptors[0], write: descriptors[1])
}

private func fillPipeLeavingGap(
    readDescriptor: Int32,
    writeDescriptor: Int32,
    gapByteCount: Int
) throws -> Int {
    let originalFlags = fcntl(writeDescriptor, F_GETFL)
    guard originalFlags >= 0,
          fcntl(writeDescriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0
    else {
        throw ToolingError.message("fcntl pipe failed (errno \(errno))")
    }
    defer { _ = fcntl(writeDescriptor, F_SETFL, originalFlags) }

    let buffer = [UInt8](repeating: UInt8(ascii: "f"), count: 4 * 1024)
    var filledByteCount = 0
    while true {
        let written = buffer.withUnsafeBytes { bytes in
            Darwin.write(writeDescriptor, bytes.baseAddress, bytes.count)
        }
        if written > 0 {
            filledByteCount += written
            continue
        }
        if written < 0, errno == EINTR {
            continue
        }
        guard written < 0, errno == EAGAIN else {
            throw ToolingError.message("fill pipe failed (errno \(errno))")
        }
        break
    }
    guard filledByteCount > gapByteCount else {
        throw ToolingError.message("pipe capacity is too small for cancellation test")
    }

    var remainingGap = gapByteCount
    var drainBuffer = [UInt8](repeating: 0, count: gapByteCount)
    while remainingGap > 0 {
        let drained = drainBuffer.withUnsafeMutableBytes { bytes in
            Darwin.read(
                readDescriptor,
                bytes.baseAddress,
                min(bytes.count, remainingGap)
            )
        }
        if drained > 0 {
            remainingGap -= drained
        } else if drained < 0, errno == EINTR {
            continue
        } else {
            throw ToolingError.message("drain pipe gap failed (errno \(errno))")
        }
    }
    return filledByteCount
}

private final class PipeReadableByteProbe {
    private let queueDescriptor: Int32

    init(readDescriptor: Int32) throws {
        queueDescriptor = kqueue()
        guard queueDescriptor >= 0 else {
            throw ToolingError.message("kqueue failed (errno \(errno))")
        }
        var event = kevent(
            ident: UInt(readDescriptor),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
            data: 0,
            udata: nil
        )
        guard kevent(queueDescriptor, &event, 1, nil, 0, nil) == 0 else {
            let code = errno
            _ = close(queueDescriptor)
            throw ToolingError.message("register pipe kqueue failed (errno \(code))")
        }
    }

    deinit {
        _ = close(queueDescriptor)
    }

    func readableByteCount() throws -> Int {
        var event = kevent()
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        let eventCount = kevent(
            queueDescriptor,
            nil,
            0,
            &event,
            1,
            &timeout
        )
        guard eventCount >= 0 else {
            throw ToolingError.message("read pipe kqueue failed (errno \(errno))")
        }
        return eventCount == 0 ? 0 : Int(event.data)
    }
}

private func drainPipeToEOF(_ descriptor: Int32) throws -> Int {
    var totalByteCount = 0
    var buffer = [UInt8](repeating: 0, count: 4 * 1024)
    while true {
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if readCount > 0 {
            totalByteCount += readCount
        } else if readCount == 0 {
            return totalByteCount
        } else if errno != EINTR {
            throw ToolingError.message("drain pipe failed (errno \(errno))")
        }
    }
}

private enum InjectedPassthroughError: Error {
    case failure
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

        let brokenCandidateStreaming = try await ProcessRunner().runStreaming(
            [executableName],
            env: ["PATH": brokenCandidatePATH],
            cwd: workingDirectoryAlias,
            streamOutput: false,
            passthrough: { _ in }
        )
        #expect(brokenCandidateStreaming.status == 0)
        #expect(brokenCandidateStreaming.lastLines == ["selected-path"])

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

    @Test func chunkedCaptureFailureKeepsStatusAndBoundedStandardErrorTail() async throws {
        let helper = try testHelperExecutableURL()
        let command = [
            helper.path,
            "large-stderr-failure",
            String(StreamingOutputCollector.maximumLineByteCount + 4_096),
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
            #expect(standardError.hasPrefix("[truncated 4096 bytes] "))
            #expect(standardError.hasSuffix("\nfinal-diagnostic"))
            #expect(
                standardError.utf8.count
                    == StreamingOutputCollector.maximumLineByteCount
                        + "[truncated 4096 bytes] \nfinal-diagnostic".utf8.count
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func precancelledTasksNeverSpawnCaptureChunkedOrStreamingChildren() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureMarker = directory.appendingPathComponent("capture-started").path
        let chunkedMarker = directory.appendingPathComponent("chunked-started").path
        let streamingMarker = directory.appendingPathComponent("streaming-started").path

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
            try await chunkedTask.value
            Issue.record("expected chunked capture cancellation")
        } catch is CancellationError {
            // Cancellation wins before configuration or spawn.
        } catch {
            Issue.record("unexpected chunked capture error: \(error)")
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
        #expect(!FileManager.default.fileExists(atPath: chunkedMarker))
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

    @Test func collectorBoundsUnterminatedLineAndMarksDiscardedPrefix() throws {
        let discardedByteCount = 37
        let bytes = Array(
            repeating: UInt8(ascii: "x"),
            count: StreamingOutputCollector.maximumLineByteCount + discardedByteCount
        )
        var collector = StreamingOutputCollector()
        for chunkStart in stride(from: 0, to: bytes.count, by: 997) {
            collector.consume(Array(bytes[chunkStart..<min(chunkStart + 997, bytes.count)]))
        }
        collector.finish()

        #expect(collector.lastLines.count == 1)
        let line = try #require(collector.lastLines.first)
        let marker = "[truncated \(discardedByteCount) bytes] "
        #expect(line.hasPrefix(marker))
        let retained = line.dropFirst(marker.count)
        #expect(retained.utf8.count == StreamingOutputCollector.maximumLineByteCount)
        #expect(retained.allSatisfy { $0 == "x" })
    }

    @Test func collectorReplacesInvalidAndIncompleteUTF8AtEOF() {
        var collector = StreamingOutputCollector()
        collector.consume([UInt8(ascii: "a"), 0x80, 0xF0, 0x9F])
        collector.finish()

        #expect(collector.lastLines == ["a��"])
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

    @Test func waitableLeaderAnchorsIdentityThroughProcessGroupCompletion() async throws {
        let processIdentifier = try spawnImmediateProcessGroupLeader()
        defer { reapChild(processIdentifier) }

        let leader = try await waitForOwnedProcessGroupLeaderExit(processIdentifier)
        #expect(leader.processIdentifier == processIdentifier)
        #expect(try exitedChildRemainsWaitable(processIdentifier))

        try await completeOwnedProcessGroup(leader)
        #expect(try exitedChildRemainsWaitable(processIdentifier))
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

    @Test func streamingNormalLeaderExitCompletesOwnedProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childLock = directory.appendingPathComponent("normal-streaming-child.lock").path
        defer { terminateRecordedProcessIfLive(at: childLock) }
        let helper = try testHelperExecutableURL()

        let result = try await ProcessRunner().runStreaming(
            [helper.path, "process-group-normal-leader-exit", childLock],
            streamOutput: false,
            passthrough: { _ in }
        )
        let childPID = try processIdentifier(from: result.lastLines.joined(separator: "\n"))

        #expect(result.status == 0)
        #expect(!result.wasKilled)
        #expect(try recordedProcessIdentifier(at: childLock) == childPID)
        #expect(try processIsLive(childPID) == false)
    }

    @Test func cancellationWaitsForWholeProcessGroupAndOutputDrain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("parent.lock").path
        let childLock = directory.appendingPathComponent("child.lock").path
        defer {
            terminateRecordedProcessIfLive(at: parentLock)
            terminateRecordedProcessIfLive(at: childLock)
        }
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
            // Cancellation is preserved after the owned process group has no live member.
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(output.snapshot().range(of: readyMarker) != nil)
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

    @Test func passthroughFailureWaitsForWholeProcessGroup() async throws {
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
            _ = try await ProcessRunner().runStreaming(
                [helper.path, "process-group", parentLock, childLock],
                streamOutput: true,
                passthrough: { data in
                    guard data.range(of: Data("READY\n".utf8)) != nil else { return }
                    throw InjectedPassthroughError.failure
                }
            )
            Issue.record("expected passthrough failure")
        } catch InjectedPassthroughError.failure {
            // The original downstream failure is preserved after group teardown.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try processIsLive(recordedProcessIdentifier(at: parentLock)) == false)
        #expect(try processIsLive(recordedProcessIdentifier(at: childLock)) == false)
    }

    @Test func cancellationUnblocksStoppedPassthroughAndWaitsForProcessGroup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentLock = directory.appendingPathComponent("blocked-parent.lock").path
        let childLock = directory.appendingPathComponent("blocked-child.lock").path
        defer {
            terminateRecordedProcessIfLive(at: parentLock)
            terminateRecordedProcessIfLive(at: childLock)
        }
        let helper = try testHelperExecutableURL()
        let passthroughEntered = AsyncEvent()
        let passthroughRelease = AsyncEvent()

        let task = Task {
            defer { passthroughEntered.signal() }
            return try await ProcessRunner().runStreaming(
                [helper.path, "process-group", parentLock, childLock],
                streamOutput: true,
                passthrough: { data in
                    guard data.range(of: Data("READY\n".utf8)) != nil else { return }
                    passthroughEntered.signal()
                    try await withTaskCancellationHandler {
                        await passthroughRelease.wait()
                        try Task.checkCancellation()
                    } onCancel: {
                        passthroughRelease.signal()
                    }
                }
            )
        }
        await passthroughEntered.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected blocked passthrough cancellation")
        } catch is CancellationError {
            // The async sink releases before the runner completes process-group teardown.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(try processIsLive(recordedProcessIdentifier(at: parentLock)) == false)
        #expect(try processIsLive(recordedProcessIdentifier(at: childLock)) == false)
    }

    @Test func dispatchWriterCancellationStopsBlockedPipeAndClosesOwnedDescriptor() async throws {
        var descriptors = try makePipeDescriptors()
        defer {
            if descriptors.read >= 0 { _ = close(descriptors.read) }
            if descriptors.write >= 0 { _ = close(descriptors.write) }
        }
        let gapByteCount = 4 * 1024
        let pipeCapacity = try fillPipeLeavingGap(
            readDescriptor: descriptors.read,
            writeDescriptor: descriptors.write,
            gapByteCount: gapByteCount
        )
        let writer = try CancellableStandardOutputWriter(
            fileDescriptor: descriptors.write
        )
        let pipeProbe = try PipeReadableByteProbe(readDescriptor: descriptors.read)
        let writeFinished = AsyncEvent()
        let writeTask = Task {
            defer { writeFinished.signal() }
            try await writer.write(
                Data(repeating: UInt8(ascii: "w"), count: gapByteCount * 2)
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while try pipeProbe.readableByteCount() < pipeCapacity,
              !writeFinished.value,
              clock.now < deadline
        {
            await Task.yield()
        }
        #expect(try pipeProbe.readableByteCount() == pipeCapacity)
        #expect(!writeFinished.value)

        writeTask.cancel()
        async let cleanup: Void = writer.finish()
        do {
            try await writeTask.value
            Issue.record("expected blocked DispatchIO write cancellation")
        } catch is CancellationError {
            // close(.stop) resumes the one pending write continuation exactly once.
        } catch {
            Issue.record("unexpected writer error: \(error)")
        }
        await cleanup

        _ = close(descriptors.write)
        descriptors.write = -1
        let drainedByteCount = try drainPipeToEOF(descriptors.read)
        #expect(drainedByteCount == pipeCapacity)
    }
}
#endif
