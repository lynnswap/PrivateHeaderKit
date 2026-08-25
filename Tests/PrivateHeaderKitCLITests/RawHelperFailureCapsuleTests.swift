import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitHelperProtocol
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling
import Testing

@testable import PrivateHeaderKitCLI

@Suite
struct RawHelperFailureCapsuleTests {
    @Test func longExceptionRetainsCauseFirstApplicationFrameTailAndHeadline() throws {
        var lines = [
            "*** Terminating app due to uncaught exception 'FixtureException', reason: 'fixture reason'",
            "*** First throw call stack:",
            "(",
            "0   CoreFoundation fixture",
            "1   libobjc fixture",
            "2   privateheaderkit-sim-helper frame-zero",
            "3   privateheaderkit-sim-helper frame-one",
            "4   privateheaderkit-sim-helper frame-two",
        ]
        lines += (5...24).map { "\($0)   filler frame \($0)" }
        lines += [
            ")",
            "libc++abi: terminating due to uncaught exception of type NSException",
            "final-diagnostic-tail",
        ]
        let capsule = RawHelperFailureCapsule(
            processResult: .init(
                status: 19,
                wasKilled: false,
                emittedOutput: BoundedProcessOutput(lines: lines),
                terminationObservedAtUnixEpochMicroseconds: 1_777_000_987_654_321
            ),
            handshake: .available(try Self.helperHandshake(executableName: "privateheaderkit-sim-helper")),
            recognizesSimulatorChildTermination: true
        )
        let renderedLines = capsule.text.split(separator: "\n").map(String.init)

        #expect(renderedLines.first == lines.first)
        #expect(renderedLines.contains("2   privateheaderkit-sim-helper frame-zero"))
        #expect(renderedLines.contains(where: { $0.hasPrefix("[omitted ") }))
        #expect(renderedLines[renderedLines.count - 3] == lines[lines.count - 2])
        #expect(renderedLines[renderedLines.count - 2] == "final-diagnostic-tail")
        let expectedHeadline = "privateheaderkit raw helper error: capsule=v1 "
            + "termination=exit(19) wrapper_status=19 wrapper_killed=false "
            + "handshake=available "
            + "helper=privateheaderkit-sim-helper "
            + "lc_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee pid=4242 "
            + "start_us=1700000000123456 "
            + "termination_observed_us=1777000987654321"
        #expect(renderedLines.last == expectedHeadline)
        #expect(renderedLines.count == RawHelperFailureCapsule.maximumLineCount)
    }

    @Test func exactSimulatorSignalLineBecomesTerminationWithoutDiagnosticOutput() throws {
        let capsule = RawHelperFailureCapsule(
            processResult: .init(
                status: 139,
                wasKilled: false,
                lastLines: ["Child process terminated with signal 11: Segmentation fault"],
                terminationObservedAtUnixEpochMicroseconds: 1_777_000_111_222_333
            ),
            handshake: .available(try Self.helperHandshake(executableName: "privateheaderkit-sim-helper")),
            recognizesSimulatorChildTermination: true
        )

        let expected = "helper diagnostic output: none emitted\n"
            + "privateheaderkit raw helper error: capsule=v1 "
            + "termination=child_signal(11) wrapper_status=139 wrapper_killed=false "
            + "handshake=available "
            + "helper=privateheaderkit-sim-helper "
            + "lc_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee pid=4242 "
            + "start_us=1700000000123456 "
            + "termination_observed_us=1777000111222333"
        #expect(capsule.text == expected)
    }

    @Test func similarOrHostSignalTextIsNotAuthoritative() throws {
        let similar = "Child process terminated with signal 11 - Segmentation fault"
        let simulatorCapsule = RawHelperFailureCapsule(
            processResult: .init(status: 19, wasKilled: false, lastLines: [similar]),
            handshake: .missing,
            recognizesSimulatorChildTermination: true
        )
        let hostCapsule = RawHelperFailureCapsule(
            processResult: .init(
                status: 19,
                wasKilled: false,
                lastLines: ["Child process terminated with signal 11: Segmentation fault"]
            ),
            handshake: .missing,
            recognizesSimulatorChildTermination: false
        )

        #expect(simulatorCapsule.text.hasPrefix(similar + "\n"))
        #expect(simulatorCapsule.text.contains("termination=exit(19)"))
        #expect(hostCapsule.text.contains("Child process terminated with signal 11"))
        #expect(hostCapsule.text.contains("termination=exit(19)"))
    }

    @Test func onlyCorroboratedFinalSimulatorSignalLineIsAuthoritative() {
        let exactSignalLine = "Child process terminated with signal 11: Segmentation fault"
        let nonfinalCapsule = RawHelperFailureCapsule(
            processResult: .init(
                status: 139,
                wasKilled: false,
                lastLines: [exactSignalLine, "later helper diagnostic"]
            ),
            handshake: .missing,
            recognizesSimulatorChildTermination: true
        )
        let mismatchedStatusCapsule = RawHelperFailureCapsule(
            processResult: .init(status: 11, wasKilled: false, lastLines: [exactSignalLine]),
            handshake: .missing,
            recognizesSimulatorChildTermination: true
        )
        let killedWrapperCapsule = RawHelperFailureCapsule(
            processResult: .init(status: 11, wasKilled: true, lastLines: [exactSignalLine]),
            handshake: .missing,
            recognizesSimulatorChildTermination: true
        )

        #expect(nonfinalCapsule.text.hasPrefix(exactSignalLine + "\n"))
        #expect(nonfinalCapsule.text.contains("termination=exit(139)"))
        #expect(mismatchedStatusCapsule.text.hasPrefix(exactSignalLine + "\n"))
        #expect(mismatchedStatusCapsule.text.contains("termination=exit(11)"))
        #expect(killedWrapperCapsule.text.hasPrefix(exactSignalLine + "\n"))
        #expect(killedWrapperCapsule.text.contains("termination=wrapper_signal(11)"))
    }

    @Test func normalExitWithMissingIdentityIsExplicit() {
        let capsule = RawHelperFailureCapsule(
            processResult: .init(status: 19, wasKilled: false, lastLines: []),
            handshake: .missing,
            recognizesSimulatorChildTermination: false
        )

        #expect(capsule.text.hasPrefix("helper diagnostic output: none emitted\n"))
        #expect(capsule.text.contains("termination=exit(19)"))
        #expect(capsule.text.contains("identity=unavailable handshake=missing"))
        #expect(capsule.text.contains("termination_observed_us=unavailable"))
    }

    @Test func capsuleBoundsAndEnvelopePrivacyAreInvariant() throws {
        let output = BoundedProcessOutput(
            lines: (0..<100).map { index in
                "line-\(index)-" + String(repeating: "x", count: 4_000)
            }
        )
        let capsule = RawHelperFailureCapsule(
            processResult: .init(status: 19, wasKilled: false, emittedOutput: output),
            handshake: .available(try Self.helperHandshake()),
            recognizesSimulatorChildTermination: false
        )
        let lines = capsule.text.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count <= RawHelperFailureCapsule.maximumLineCount)
        #expect(capsule.text.utf8.count <= RawHelperFailureCapsule.maximumRenderedByteCount)
        #expect(!capsule.text.contains("/Users/private/RuntimeRoot"))
        #expect(!capsule.text.contains("00000000-1111-2222-3333-444444444444"))
        #expect(!capsule.text.contains("SIMCTL_CHILD_DYLD_ROOT_PATH"))
        #expect(!capsule.text.contains("xcrun simctl spawn"))
        #expect(!capsule.text.contains("producer="))
    }

    @Test func failedRunClassifiesMissingAndInvalidHandshakeAndCleansReports() async throws {
        for invalid in [false, true] {
            let fixture = try Self.rawDumpInvocationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let runner = RecordingCommandRunner()
            await runner.setStreamingHandler { _, _, _ in
                if invalid {
                    try Data("not-json".utf8).write(
                        to: fixture.invocation.processHandshakeReportURL,
                        options: .atomic
                    )
                }
                try JSONEncoder().encode(
                    PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: [])
                ).write(to: fixture.invocation.diagnosticsReportURL, options: .atomic)
                return StreamingCommandResult(
                    status: 19,
                    wasKilled: false,
                    lastLines: [],
                    terminationObservedAtUnixEpochMicroseconds: 1_777_000_222_333_444
                )
            }

            let result = try await runPrivateHeaderKitRawDump(
                fixture.invocation,
                processRunner: runner
            )

            #expect(result.failureSummary?.contains(invalid ? "handshake=invalid" : "handshake=missing") == true)
            #expect(result.failureSummary?.contains("identity=unavailable") == true)
            #expect(
                (result.failureSummary?.split(separator: "\n").count ?? 0)
                    <= RawHelperFailureCapsule.maximumLineCount
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.invocation.processHandshakeReportURL.path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.invocation.diagnosticsReportURL.path
                )
            )
        }
    }

    @Test func successfulRunRequiresBoundedRegularInvocationBoundHandshake() async throws {
        enum FixtureKind: CaseIterable, Sendable {
            case missing
            case malformed
            case oversized
            case directory
            case wrongInvocation
        }

        for kind in FixtureKind.allCases {
            let fixture = try Self.rawDumpInvocationFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let runner = RecordingCommandRunner()
            await runner.setStreamingHandler { _, _, _ in
                switch kind {
                case .missing:
                    break
                case .malformed:
                    try Data("not-json".utf8).write(
                        to: fixture.invocation.processHandshakeReportURL,
                        options: .atomic
                    )
                case .oversized:
                    try Data(
                        count: PrivateHeaderKitRawDumpProcessHandshake.maximumEncodedByteCount + 1
                    ).write(
                        to: fixture.invocation.processHandshakeReportURL,
                        options: .atomic
                    )
                case .directory:
                    try FileManager.default.createDirectory(
                        at: fixture.invocation.processHandshakeReportURL,
                        withIntermediateDirectories: false
                    )
                case .wrongInvocation:
                    try Self.helperHandshake(invocationID: UUID()).encoded().write(
                        to: fixture.invocation.processHandshakeReportURL,
                        options: .atomic
                    )
                }
                try JSONEncoder().encode(
                    PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: [])
                ).write(to: fixture.invocation.diagnosticsReportURL, options: .atomic)
                return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
            }

            switch kind {
            case .missing:
                await #expect(
                    throws: PrivateHeaderGeneration.RawDumping.ContractError
                        .missingProcessHandshake(
                            fixture.invocation.processHandshakeReportURL.path
                        )
                ) {
                    _ = try await runPrivateHeaderKitRawDump(
                        fixture.invocation,
                        processRunner: runner
                    )
                }
            case .oversized:
                await #expect(
                    throws: PrivateHeaderGeneration.RawDumping.ContractError
                        .processHandshakeTooLarge(
                            path: fixture.invocation.processHandshakeReportURL.path,
                            actual: PrivateHeaderKitRawDumpProcessHandshake
                                .maximumEncodedByteCount + 1,
                            maximum: PrivateHeaderKitRawDumpProcessHandshake
                                .maximumEncodedByteCount
                        )
                ) {
                    _ = try await runPrivateHeaderKitRawDump(
                        fixture.invocation,
                        processRunner: runner
                    )
                }
            case .directory:
                await #expect(
                    throws: PrivateHeaderGeneration.RawDumping.ContractError
                        .invalidProcessHandshake(
                            path: fixture.invocation.processHandshakeReportURL.path,
                            reason: "report is not a regular file"
                        )
                ) {
                    _ = try await runPrivateHeaderKitRawDump(
                        fixture.invocation,
                        processRunner: runner
                    )
                }
            case .malformed, .wrongInvocation:
                await #expect(throws: PrivateHeaderGeneration.RawDumping.ContractError.self) {
                    _ = try await runPrivateHeaderKitRawDump(
                        fixture.invocation,
                        processRunner: runner
                    )
                }
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.invocation.processHandshakeReportURL.path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.invocation.diagnosticsReportURL.path
                )
            )
        }
    }

    private static func helperHandshake(
        invocationID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        executableName: String = "privateheaderkit-raw-helper"
    ) throws -> PrivateHeaderKitRawDumpProcessHandshake {
        try PrivateHeaderKitRawDumpProcessHandshake(
            invocationID: invocationID,
            processIdentifier: 4_242,
            helperStartedAtUnixMicroseconds: 1_700_000_000_123_456,
            executableName: executableName,
            executableMachOUUID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!
        )
    }

    private static func rawDumpInvocationFixture() throws -> (
        root: URL,
        invocation: PrivateHeaderGeneration.RawDumping.Invocation
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawHelperFailureCapsuleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            try .init(
                helperURLs: .init(
                    host: root.appendingPathComponent("privateheaderkit-raw-helper"),
                    simulator: root.appendingPathComponent("privateheaderkit-sim-helper")
                ),
                executionMode: .host,
                inputPath: "/System/Library/Frameworks/AppKit.framework",
                stagingOutputDirectory: stage
            )
        )
        return (root, invocation)
    }
}
