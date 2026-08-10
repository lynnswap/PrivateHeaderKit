import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationRawDumpingTests {
    @Test func hostInvocationUsesPrivateHeaderKitHiddenRawDumpModeAndStableFlags() throws {
        let inputPath = "/System/Library/PrivateFrameworks/Foo.framework"
        let stageDirectory = URL(
            fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run",
            isDirectory: true
        )

        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            try PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: helperURLs(),
                executionMode: .host,
                inputPath: inputPath,
                stagingOutputDirectory: stageDirectory,
                options: PrivateHeaderGeneration.RawDumping.Options(
                    skipExisting: true,
                    useSharedCache: true,
                    verbose: true,
                    preferRuntimeMetadata: true,
                    helperEnvironment: ["PH_PROFILE": "1"]
                ),
                expectedCacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")
            )
        )

        #expect(invocation.phaseLabel == "raw-header-dump")
        #expect(invocation.executionMode == .host)
        #expect(invocation.helperURL.path == "/opt/privateheaderkit/bin/privateheaderkit")
        #expect(invocation.inputPath == inputPath)
        #expect(invocation.stagingOutputDirectory == stageDirectory)
        #expect(invocation.command == [
            "/opt/privateheaderkit/bin/privateheaderkit",
            "__raw-dump",
            "-o",
            "/tmp/PrivateHeaderKit/.tmp-run",
            "-b",
            "-h",
            "-s",
            "-c",
            "--expected-cache-uuid",
            "11111111-2222-3333-4444-555555555555",
            "-D",
            "-R",
            "/System/Library/PrivateFrameworks/Foo.framework",
        ])
        #expect(invocation.environment == ["PH_PROFILE": "1"])
    }

    @Test func hostInvocationDefaultsToOnlyRequiredHelperFlags() throws {
        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            try PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: helperURLs(),
                executionMode: .host,
                inputPath: "/usr/lib/libobjc.A.dylib",
                stagingOutputDirectory: URL(
                    fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run",
                    isDirectory: true
                )
            )
        )

        #expect(invocation.command == [
            "/opt/privateheaderkit/bin/privateheaderkit",
            "__raw-dump",
            "-o",
            "/tmp/PrivateHeaderKit/.tmp-run",
            "-b",
            "-h",
            "/usr/lib/libobjc.A.dylib",
        ])
        #expect(invocation.environment.isEmpty)
    }

    @Test func simulatorInvocationUsesSimctlSpawnAndChildRuntimeEnvironment() throws {
        let runtimeRoot = "/Library/Developer/CoreSimulator/Volumes/iOS_27A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot"
        let inputPath = "/System/Library/Frameworks/UIKit.framework"
        let stageDirectory = URL(
            fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run",
            isDirectory: true
        )

        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            try PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: helperURLs(),
                executionMode: .simulator(
                    deviceUDID: "A1B2C3D4-E5F6-7890-ABCD-111111111111",
                    runtimeRoot: runtimeRoot
                ),
                inputPath: inputPath,
                stagingOutputDirectory: stageDirectory,
                options: PrivateHeaderGeneration.RawDumping.Options(
                    skipExisting: true,
                    useSharedCache: true,
                    verbose: true,
                    preferRuntimeMetadata: true,
                    helperEnvironment: [
                        "SIMCTL_CHILD_DYLD_ROOT_PATH": "/wrong/root",
                        "SIMCTL_CHILD_PH_PROFILE": "1",
                    ]
                ),
                expectedCacheUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            )
        )

        #expect(invocation.phaseLabel == "raw-header-dump")
        #expect(invocation.executionMode == .simulator(deviceUDID: "A1B2C3D4-E5F6-7890-ABCD-111111111111", runtimeRoot: runtimeRoot))
        #expect(invocation.helperURL.path == "/opt/privateheaderkit/bin/privateheaderkit-sim")
        #expect(invocation.inputPath == inputPath)
        #expect(invocation.command == [
            "xcrun",
            "simctl",
            "spawn",
            "A1B2C3D4-E5F6-7890-ABCD-111111111111",
            "/opt/privateheaderkit/bin/privateheaderkit-sim",
            "__raw-dump",
            "-o",
            "/tmp/PrivateHeaderKit/.tmp-run",
            "-b",
            "-h",
            "-s",
            "-c",
            "--expected-cache-uuid",
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "-D",
            "/System/Library/Frameworks/UIKit.framework",
        ])
        #expect(invocation.environment == [
            "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot,
            "SIMCTL_CHILD_PH_PROFILE": "1",
            "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot,
        ])
    }

    @Test func sharedCacheInventoryInvocationUsesHostHelper() {
        let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
            helperURLs: helperURLs(),
            executionMode: .host,
            helperEnvironment: ["PH_PROFILE": "1"]
        )

        #expect(invocation.phaseLabel == "shared-cache-inventory")
        #expect(invocation.command == [
            "/opt/privateheaderkit/bin/privateheaderkit",
            PrivateHeaderKitHelperCommand.sharedCacheInventory.rawValue,
        ])
        #expect(invocation.environment == ["PH_PROFILE": "1"])
    }

    @Test func sharedCacheInventoryInvocationUsesSimulatorHelperAndRuntimeEnvironment() {
        let runtimeRoot = "/Library/Developer/CoreSimulator/RuntimeRoot"
        let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
            helperURLs: helperURLs(),
            executionMode: .simulator(deviceUDID: "SIM-UDID", runtimeRoot: runtimeRoot),
            helperEnvironment: ["SIMCTL_CHILD_PH_PROFILE": "1"]
        )

        #expect(invocation.command == [
            "xcrun",
            "simctl",
            "spawn",
            "SIM-UDID",
            "/opt/privateheaderkit/bin/privateheaderkit-sim",
            PrivateHeaderKitHelperCommand.sharedCacheInventory.rawValue,
        ])
        #expect(invocation.environment == [
            "SIMCTL_CHILD_PH_PROFILE": "1",
            "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot,
            "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot,
        ])
    }

    #if os(macOS)
    @Test func liveRawDumpRunnerCapturesFailureOutput() async throws {
        let invocation = PrivateHeaderGeneration.RawDumping.Invocation(
            phaseLabel: "raw-header-dump",
            executionMode: .host,
            helperURL: URL(fileURLWithPath: "/bin/sh", isDirectory: false),
            inputPath: "/tmp/Foo.framework",
            stagingOutputDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run", isDirectory: true),
            command: [
                "/bin/sh",
                "-c",
                "printf 'before\\nMachOObjCSection/_FileIOProtocol+.swift:52: Fatal error: offsetOutOfBounds\\n' >&2; exit 7",
            ],
            environment: [:]
        )

        let result = try await PrivateHeaderGeneration.GenerationExecutor.liveRawDumpRunner(
            invocation: invocation
        )

        #expect(result.terminationStatus == 7)
        #expect(!result.wasKilled)
        #expect(result.failureSummary?.contains("raw dump exited with status 7") == true)
        #expect(result.failureSummary?.contains("offsetOutOfBounds") == true)
    }

    @Test func cancellingInFlightLiveRawDumpRunnerKillsAndReapsProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateHeaderKit-raw-dump-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let invocation = PrivateHeaderGeneration.RawDumping.Invocation(
            phaseLabel: "raw-header-dump",
            executionMode: .host,
            helperURL: URL(fileURLWithPath: "/bin/sh"),
            inputPath: "/tmp/Foo.framework",
            stagingOutputDirectory: URL(fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run", isDirectory: true),
            command: [
                "/bin/sh",
                "-c",
                "printf '%s' $$ > '\(marker.path)'; trap '' TERM; while :; do :; done",
            ],
            environment: [:]
        )
        let task = Task {
            try await PrivateHeaderGeneration.GenerationExecutor.liveRawDumpRunner(
                invocation: invocation
            )
        }
        for _ in 0..<100_000 where !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        let pidText = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(Int32(pidText))

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func liveSharedCacheInventoryRunnerCapturesOnlyStandardOutput() async throws {
        let invocation = PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation(
            phaseLabel: "shared-cache-inventory",
            executionMode: .host,
            helperURL: URL(fileURLWithPath: "/bin/sh"),
            command: [
                "/bin/sh",
                "-c",
                "printf '{\"schemaVersion\":1}' ; printf 'diagnostic' >&2",
            ],
            environment: [:]
        )

        let data = try await PrivateHeaderGeneration.GenerationExecutor.liveSharedCacheInventoryRunner(
            invocation: invocation
        )

        #expect(String(decoding: data, as: UTF8.self) == "{\"schemaVersion\":1}")
    }

    @Test func liveSharedCacheInventoryRunnerReportsTypedProcessFailureBeforeDecode() async throws {
        let invocation = PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation(
            phaseLabel: "shared-cache-inventory",
            executionMode: .host,
            helperURL: URL(fileURLWithPath: "/bin/sh"),
            command: [
                "/bin/sh",
                "-c",
                "printf 'broken cache' >&2; exit 9",
            ],
            environment: [:]
        )

        do {
            _ = try await PrivateHeaderGeneration.GenerationExecutor.liveSharedCacheInventoryRunner(
                invocation: invocation
            )
            Issue.record("expected inventory process failure")
        } catch let error as PrivateHeaderGeneration.RawDumping.SharedCacheInventoryRunnerError {
            #expect(error == .exited(status: 9, output: "broken cache"))
        }
    }

    @Test func cancellingInFlightLiveInventoryRunnerKillsAndReapsProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateHeaderKit-inventory-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let invocation = PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation(
            phaseLabel: "shared-cache-inventory",
            executionMode: .host,
            helperURL: URL(fileURLWithPath: "/bin/sh"),
            command: [
                "/bin/sh",
                "-c",
                "touch '\(marker.path)'; trap '' TERM; while :; do :; done",
            ],
            environment: [:]
        )
        let task = Task {
            return try await PrivateHeaderGeneration.GenerationExecutor.liveSharedCacheInventoryRunner(
                invocation: invocation
            )
        }
        for _ in 0..<100_000 where !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
    #endif

    @Test func rawDumpRequestRejectsMissingInventoryCohort() {
        #expect(throws: PrivateHeaderGeneration.RawDumping.Request.ValidationError.self) {
            _ = try PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: helperURLs(),
                executionMode: .host,
                inputPath: "/usr/lib/libobjc.A.dylib",
                stagingOutputDirectory: URL(fileURLWithPath: "/tmp/stage", isDirectory: true),
                options: .init(useSharedCache: true)
            )
        }

        #expect(throws: PrivateHeaderGeneration.RawDumping.Request.ValidationError.self) {
            _ = try PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: helperURLs(),
                executionMode: .host,
                inputPath: "/usr/lib/libobjc.A.dylib",
                stagingOutputDirectory: URL(fileURLWithPath: "/tmp/stage", isDirectory: true),
                expectedCacheUUID: UUID()
            )
        }
    }

    private func helperURLs() -> PrivateHeaderGeneration.RawDumping.HelperURLs {
        PrivateHeaderGeneration.RawDumping.HelperURLs(
            host: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit"),
            simulator: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit-sim")
        )
    }
}
