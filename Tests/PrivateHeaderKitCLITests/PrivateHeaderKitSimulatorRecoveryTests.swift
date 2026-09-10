import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling
import Testing

@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitSimulatorRecoveryTests {
    @Test(arguments: [Int32(1), Int32(124)])
    func interruptedDumpRetriesTheSameTargetWithEmptyStaging(status: Int32) async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation()
        let runner = RecordingCommandRunner()
        let attempts = RecoveryAttemptCounter()
        await runner.setCaptureOutput(fixture.devicesJSON(state: "Shutdown"), for: fixture.listCommand)
        await runner.setStreamingHandler { command, _, _ in
            let attempt = await attempts.next()
            if attempt == 1 {
                try Data("interrupted header".utf8).write(
                    to: invocation.stagingOutputDirectory.appendingPathComponent("Stale.h")
                )
                if status != 124 {
                    try fixture.writeReports(for: command)
                }
                return .init(status: status, wasKilled: false, lastLines: ["device stopped"])
            }
            #expect(attempt == 2)
            #expect(try FileManager.default.contentsOfDirectory(atPath: invocation.stagingOutputDirectory.path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: invocation.processHandshakeReportURL.path))
            #expect(!FileManager.default.fileExists(atPath: invocation.diagnosticsReportURL.path))
            try fixture.writeReports(for: command)
            try Data("fresh header".utf8).write(
                to: invocation.stagingOutputDirectory.appendingPathComponent("Fresh.h")
            )
            return .init(status: 0, wasKilled: false, lastLines: [])
        }

        let result = try await runPrivateHeaderKitRawDump(
            invocation,
            processRunner: runner,
            recoveryReporter: { _ in }
        )

        #expect(result.terminationStatus == 0)
        #expect(result.failureSummary == nil)
        #expect(await runner.streamingCommandSnapshot().map(\.command) == [invocation.command, invocation.command])
        #expect(await runner.streamingCommandSnapshot().map(\.env) == [invocation.environment, invocation.environment])
        #expect(await runner.simpleCommandSnapshot().map(\.command) == [fixture.bootCommand])
        #expect(try FileManager.default.contentsOfDirectory(atPath: invocation.stagingOutputDirectory.path) == ["Fresh.h"])
    }

    @Test func aSecondDisruptionCanRecoverBeforeTheTargetCompletes() async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation()
        let runner = RecordingCommandRunner()
        let attempts = RecoveryAttemptCounter()
        await runner.setCaptureOutput(fixture.devicesJSON(state: "Shutdown"), for: fixture.listCommand)
        await runner.setStreamingHandler { command, _, _ in
            if await attempts.next() < 3 {
                return .init(status: 124, wasKilled: false, lastLines: [])
            }
            try fixture.writeReports(for: command)
            return .init(status: 0, wasKilled: false, lastLines: [])
        }

        let result = try await runPrivateHeaderKitRawDump(invocation, processRunner: runner, recoveryReporter: { _ in })

        #expect(result.terminationStatus == 0)
        #expect(await runner.streamingCommandSnapshot().map(\.command) == Array(repeating: invocation.command, count: 3))
        #expect(await runner.simpleCommandSnapshot().map(\.command) == Array(repeating: fixture.bootCommand, count: 2))
    }

    @Test(arguments: [false, true])
    func helperCrashDoesNotRetryWhenTheDeviceRemainsBooted(host: Bool) async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation(host: host)
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(fixture.devicesJSON(state: "Booted"), for: fixture.listCommand)
        await runner.setStreamingHandler { command, _, _ in
            try fixture.writeReports(for: command)
            return .init(
                status: 139,
                wasKilled: false,
                lastLines: ["Child process terminated with signal 11: Segmentation fault"]
            )
        }

        let result = try await runPrivateHeaderKitRawDump(
            invocation,
            processRunner: runner,
            recoveryReporter: { _ in }
        )

        #expect(result.terminationStatus == 139)
        #expect(result.failureSummary?.contains(host ? "termination=exit(139)" : "termination=child_signal(11)") == true)
        #expect(await runner.streamingCommandSnapshot().count == 1)
        #expect(await runner.simpleCommandSnapshot().isEmpty)
        #expect(await runner.captureCommandSnapshot().map(\.command) == (host ? [] : [fixture.listCommand]))
    }

    @Test func cancellingWhileBootIsPendingPropagatesCancellationWithoutRetry() async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation()
        let runner = RecordingCommandRunner()
        let bootGate = RecoveryBootGate()
        await runner.setCaptureOutput(fixture.devicesJSON(state: "Booting"), for: fixture.listCommand)
        await runner.setStreamingHandler { _, _, _ in
            .init(status: 124, wasKilled: false, lastLines: [])
        }
        await runner.setSimpleHandler { command, _, _ in
            #expect(command == fixture.bootCommand)
            try await bootGate.wait()
        }

        let operation = Task {
            try await bootGate.track {
                try await runPrivateHeaderKitRawDump(
                    invocation,
                    processRunner: runner,
                    recoveryReporter: { _ in }
                )
            }
        }
        try #require(await bootGate.waitUntilEntered())
        #expect(await runner.streamingCommandSnapshot().count == 1)
        operation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(await runner.streamingCommandSnapshot().count == 1)
    }

    @Test func aProcessLaunchErrorDoesNotAttemptToRestartTheSimulator() async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation()
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { command, _, _ in
            throw ToolingError.processLaunchFailed(command: command, underlying: "executable missing")
        }

        do {
            _ = try await runPrivateHeaderKitRawDump(invocation, processRunner: runner, recoveryReporter: { _ in })
            Issue.record("a missing executable unexpectedly completed")
        } catch let ToolingError.processLaunchFailed(command, underlying) {
            #expect(command == invocation.command)
            #expect(underlying == "executable missing")
        }
        #expect(await runner.captureCommandSnapshot().isEmpty)
        #expect(await runner.simpleCommandSnapshot().isEmpty)
        #expect(await runner.streamingCommandSnapshot().count == 1)
    }

    @Test(arguments: [false, true])
    func lostDeviceOrFailedBootStopsRecovery(bootFails: Bool) async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation()
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            bootFails ? fixture.devicesJSON(state: "Shutdown") : "{\"devices\":{}}",
            for: fixture.listCommand
        )
        await runner.setStreamingHandler { _, _, _ in
            .init(status: 124, wasKilled: false, lastLines: ["device unavailable"])
        }
        await runner.setSimpleHandler { command, _, _ in
            throw ToolingError.commandFailed(command: command, status: 1, stderr: "boot failed")
        }

        do {
            _ = try await runPrivateHeaderKitRawDump(invocation, processRunner: runner, recoveryReporter: { _ in })
            Issue.record("an unavailable simulator unexpectedly completed")
        } catch let PrivateHeaderGeneration.RawDumping.ExecutionError.environmentUnavailable(message) {
            #expect(message.contains(fixture.deviceUDID))
        }
        #expect(await runner.streamingCommandSnapshot().count == 1)
        #expect(await runner.simpleCommandSnapshot().count == (bootFails ? 1 : 0))
    }

    @Test func successfulHelperWithMissingDiagnosticsDoesNotTriggerSimulatorRecovery() async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.invocation()
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { command, _, _ in
            try fixture.writeReports(for: command)
            try FileManager.default.removeItem(at: invocation.diagnosticsReportURL)
            return .init(status: 0, wasKilled: false, lastLines: [])
        }

        await #expect(throws: PrivateHeaderGeneration.RawDumping.ContractError.missingDiagnosticsReport(invocation.diagnosticsReportURL.path)) {
            _ = try await runPrivateHeaderKitRawDump(invocation, processRunner: runner, recoveryReporter: { _ in })
        }
        #expect(await runner.captureCommandSnapshot().isEmpty)
        #expect(await runner.simpleCommandSnapshot().isEmpty)
        #expect(await runner.streamingCommandSnapshot().count == 1)
    }

    @Test func inventoryRecoveryPreservesTheCompleteStandardOutput() async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
            helperURLs: fixture.helperURLs,
            executionMode: fixture.executionMode
        )
        let inventory = try JSONEncoder().encode(PrivateHeaderKitSharedCacheInventory(
            cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            imagePaths: (0..<2_000).map { "/usr/lib/libFixture\($0).dylib" }
        ))
        let runner = RecordingCommandRunner()
        let attempts = RecoveryAttemptCounter()
        await runner.setCaptureHandler { command, _, _ in
            if command == fixture.listCommand { return fixture.devicesJSON(state: "Shutting Down") }
            #expect(command == invocation.command)
            if await attempts.next() == 1 {
                throw ToolingError.commandFailed(command: command, status: 124, stderr: "device unavailable")
            }
            return String(decoding: inventory, as: UTF8.self)
        }

        let captured = try await capturePrivateHeaderKitSharedCacheInventory(
            invocation,
            processRunner: runner,
            recoveryReporter: { _ in }
        )

        #expect(captured == inventory)
        #expect(await runner.captureCommandSnapshot().map(\.command) == [invocation.command, fixture.listCommand, invocation.command])
        #expect(await runner.simpleCommandSnapshot().map(\.command) == [fixture.bootCommand])
    }

    @Test func inventoryFailureOnABootedDevicePreservesTheOriginalFailure() async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
            helperURLs: fixture.helperURLs,
            executionMode: fixture.executionMode
        )
        let runner = RecordingCommandRunner()
        await runner.setCaptureHandler { command, _, _ in
            if command == fixture.listCommand { return fixture.devicesJSON(state: "Booted") }
            throw ToolingError.commandFailed(command: command, status: 19, stderr: "inventory failure")
        }

        do {
            _ = try await capturePrivateHeaderKitSharedCacheInventory(invocation, processRunner: runner, recoveryReporter: { _ in })
            Issue.record("a failed inventory unexpectedly completed")
        } catch let ToolingError.commandFailed(command, status, stderr) {
            #expect(command == invocation.command)
            #expect(status == 19)
            #expect(stderr == "inventory failure")
        }
        #expect(await runner.captureCommandSnapshot().count == 2)
        #expect(await runner.simpleCommandSnapshot().isEmpty)
    }

    @Test(arguments: [false, true])
    func generationWaitsBeforeTheNextTargetAndStopsIfBootFails(bootFails: Bool) async throws {
        let fixture = try SimulatorRecoveryFixture()
        defer { fixture.cleanup() }
        let request = try fixture.generationRequest()
        let runner = RecordingCommandRunner()
        let attempts = RecoveryAttemptCounter()
        let bootGate = RecoveryBootGate()
        await runner.setCaptureOutput(fixture.devicesJSON(state: "Shutdown"), for: fixture.listCommand)
        await runner.setStreamingHandler { command, _, _ in
            if await attempts.next() == 1 {
                return .init(status: 124, wasKilled: false, lastLines: ["device stopped"])
            }
            try fixture.writeReports(for: command)
            try fixture.writeGeneratedHeader(for: command)
            return .init(status: 0, wasKilled: false, lastLines: [])
        }
        await runner.setSimpleHandler { command, _, _ in
            #expect(command == fixture.bootCommand)
            try await bootGate.wait()
            if bootFails {
                throw ToolingError.commandFailed(command: command, status: 1, stderr: "boot failed")
            }
        }
        let prepared = try await PrivateHeaderKitGenerationClient.live(
            processRunner: runner,
            recoveryReporter: { _ in }
        ).prepare(request)
        let operation = Task {
            try await bootGate.track { try await prepared.run(.fresh, { _ in }) }
        }
        try #require(await bootGate.waitUntilEntered())
        let pendingCommands = await runner.streamingCommandSnapshot().map(\.command)
        #expect(pendingCommands.count == 1)
        #expect(pendingCommands.first?.last?.hasSuffix("/Foo.framework") == true)
        await bootGate.release()

        if bootFails {
            do {
                _ = try await operation.value
                Issue.record("a failed simulator boot unexpectedly completed generation")
            } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
                #expect(failure.summary.status == .failed)
                #expect(failure.summary.targetCounts.pending == 1)
                #expect(failure.summary.targetCounts.completed == 0)
                #expect(failure.message.contains("boot failed"))
            }
            #expect(await runner.streamingCommandSnapshot().count == 1)
        } else {
            let result = try await operation.value
            #expect(result.targetCounts.completed == 2)
            #expect(result.targetCounts.failed == 0)
            #expect(result.targetCounts.partial == 0)
            let commands = await runner.streamingCommandSnapshot().map(\.command)
            #expect(commands.count == 3)
            #expect(commands.prefix(2).allSatisfy { $0 == pendingCommands[0] })
            #expect(commands.last?.last?.hasSuffix("/Bar.framework") == true)
        }
    }
}

private struct SimulatorRecoveryFixture: Sendable {
    let root: URL
    let deviceUDID = "11111111-2222-3333-4444-555555555555"
    let runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrivateHeaderKitSimulatorRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var listCommand: [String] { ["xcrun", "simctl", "list", "devices", "available", "-j"] }
    var bootCommand: [String] { ["xcrun", "simctl", "bootstatus", deviceUDID, "-b"] }
    var runtimeRoot: URL { root.appendingPathComponent("RuntimeRoot", isDirectory: true) }
    var helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs {
        .init(
            host: root.appendingPathComponent("privateheaderkit-raw-helper"),
            simulator: root.appendingPathComponent("privateheaderkit-sim-helper")
        )
    }
    var executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode {
        .simulator(
            deviceUDID: deviceUDID,
            sourceRuntimeRoot: runtimeRoot.path,
            runtime: .init(version: "27.0", build: "24A1", identifier: runtimeIdentifier, runtimeRoot: runtimeRoot.path)
        )
    }

    func invocation(host: Bool = false) throws -> PrivateHeaderGeneration.RawDumping.Invocation {
        let staging = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return PrivateHeaderGeneration.RawDumping.makeInvocation(try .init(
            helperURLs: helperURLs,
            executionMode: host ? .host : executionMode,
            inputPath: "/System/Library/Frameworks/Foo.framework",
            stagingOutputDirectory: staging
        ))
    }

    func devicesJSON(state: String) -> String {
        """
        {"devices":{"\(runtimeIdentifier)":[{"name":"Dump Fixture","udid":"\(deviceUDID)","state":"\(state)","isAvailable":true}]}}
        """
    }

    func writeReports(for command: [String]) throws {
        let invocationID = try #require(UUID(uuidString: argument("--process-handshake-id", in: command)))
        let handshake = try PrivateHeaderKitRawDumpProcessHandshake(
            invocationID: invocationID,
            processIdentifier: 4_242,
            helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
            executableName: command.contains("simctl") ? "privateheaderkit-sim-helper" : "privateheaderkit-raw-helper",
            executableMachOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        try handshake.encoded().write(to: URL(fileURLWithPath: argument("--process-handshake-report", in: command)), options: .atomic)
        try JSONEncoder().encode(PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: [])).write(
            to: URL(fileURLWithPath: argument("--diagnostics-report", in: command)),
            options: .atomic
        )
    }

    func generationRequest() throws -> PrivateHeaderKitGenerationRequest {
        for name in ["Foo", "Bar"] {
            let framework = runtimeRoot.appendingPathComponent("System/Library/Frameworks/\(name).framework", isDirectory: true)
            try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
            try Data().write(to: framework.appendingPathComponent(name))
        }
        return PrivateHeaderKitGenerationRequest(
            source: try .init(platform: .iOS, version: "27.0", build: "24A1", metadataIsSeed: false),
            output: .init(baseDirectory: root.appendingPathComponent("Output", isDirectory: true)),
            options: .init(
                targetRequest: .identifiers(["framework:Foo.framework", "framework:Bar.framework"]),
                systemRoot: runtimeRoot,
                helperURLs: helperURLs,
                executionMode: executionMode,
                resumeBehavior: .fresh
            )
        )
    }

    func writeGeneratedHeader(for command: [String]) throws {
        let inputPath = try #require(command.last)
        let stage = URL(fileURLWithPath: try argument("-o", in: command), isDirectory: true)
        let headerDirectory = stage.appendingPathComponent(inputPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")), isDirectory: true)
            .appendingPathComponent("Headers", isDirectory: true)
        try FileManager.default.createDirectory(at: headerDirectory, withIntermediateDirectories: true)
        try Data("// generated\n".utf8).write(to: headerDirectory.appendingPathComponent("Generated.h"))
    }

    func argument(_ name: String, in command: [String]) throws -> String {
        let index = try #require(command.firstIndex(of: name))
        return try #require(command.dropFirst(index + 1).first)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor RecoveryAttemptCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

private actor RecoveryBootGate {
    private enum Outcome { case released, cancelled }
    private var outcome: Outcome?
    private var entered = false
    private var operationFinished = false
    private var entryWaiters: [CheckedContinuation<Bool, Never>] = []
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                switch outcome {
                case .released: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case nil: waiters.append(continuation)
                }
                entered = true
                let ready = entryWaiters
                entryWaiters.removeAll()
                for waiter in ready { waiter.resume(returning: true) }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func track<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async rethrows -> Value {
        defer {
            operationFinished = true
            let ready = entryWaiters
            entryWaiters.removeAll()
            for waiter in ready { waiter.resume(returning: entered) }
        }
        return try await operation()
    }

    func waitUntilEntered() async -> Bool {
        if entered { return true }
        if operationFinished { return false }
        return await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        outcome = .released
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }

    private func cancel() {
        outcome = .cancelled
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume(throwing: CancellationError()) }
    }
}
