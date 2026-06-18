import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationRawDumpingTests {
    @Test func hostInvocationUsesHostHelperAndStableHeaderdumpFlags() {
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
        #expect(invocation.helperURL.path == "/opt/privateheaderkit/bin/headerdump")
        #expect(invocation.inputPath == inputPath)
        #expect(invocation.stagingOutputDirectory == stageDirectory)
        #expect(invocation.command == [
            "/opt/privateheaderkit/bin/headerdump",
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
            "/opt/privateheaderkit/bin/headerdump",
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

        #expect(invocation.helperURL.path == "/opt/privateheaderkit/bin/headerdump-sim")
        #expect(invocation.inputPath == inputPath)
        #expect(invocation.command == [
            "xcrun",
            "simctl",
            "spawn",
            "A1B2C3D4-E5F6-7890-ABCD-111111111111",
            "/opt/privateheaderkit/bin/headerdump-sim",
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

    private func helperURLs() -> PrivateHeaderGeneration.RawDumping.HelperURLs {
        PrivateHeaderGeneration.RawDumping.HelperURLs(
            host: URL(fileURLWithPath: "/opt/privateheaderkit/bin/headerdump"),
            simulator: URL(fileURLWithPath: "/opt/privateheaderkit/bin/headerdump-sim")
        )
    }
}
