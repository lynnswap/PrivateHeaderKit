import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationRawDumpingTests {
    @Test func hostInvocationUsesPrivateHeaderKitHiddenRawDumpModeAndStableFlags() {
        let inputPath = "/System/Library/PrivateFrameworks/Foo.framework"
        let stageDirectory = URL(
            fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run",
            isDirectory: true
        )

        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            PrivateHeaderGeneration.RawDumping.Request(
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
                )
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
            "-D",
            "-R",
            "/System/Library/PrivateFrameworks/Foo.framework",
        ])
        #expect(invocation.environment == ["PH_PROFILE": "1"])
    }

    @Test func hostInvocationDefaultsToOnlyRequiredHelperFlags() {
        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            PrivateHeaderGeneration.RawDumping.Request(
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

    @Test func simulatorInvocationUsesSimctlSpawnAndChildRuntimeEnvironment() {
        let runtimeRoot = "/Library/Developer/CoreSimulator/Volumes/iOS_27A/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS.simruntime/Contents/Resources/RuntimeRoot"
        let inputPath = "/System/Library/Frameworks/UIKit.framework"
        let stageDirectory = URL(
            fileURLWithPath: "/tmp/PrivateHeaderKit/.tmp-run",
            isDirectory: true
        )

        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            PrivateHeaderGeneration.RawDumping.Request(
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
                )
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
            "-D",
            "/System/Library/Frameworks/UIKit.framework",
        ])
        #expect(invocation.environment == [
            "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot,
            "SIMCTL_CHILD_PH_PROFILE": "1",
            "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot,
        ])
    }

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

    private func helperURLs() -> PrivateHeaderGeneration.RawDumping.HelperURLs {
        PrivateHeaderGeneration.RawDumping.HelperURLs(
            host: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit"),
            simulator: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit-sim")
        )
    }
}
