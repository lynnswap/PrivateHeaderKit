import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import PrivateHeaderKitCore
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling
@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitCLIArgumentTests {
    @Test(arguments: [false, true], [false, true])
    func toolVersionExitsWithoutGenerationSideEffects(_ usesAlias: Bool, _ includesPartialInputs: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unusedOutput = root.appendingPathComponent("Unused")
        let arguments = ["privateheaderkit"] + (usesAlias ? ["generate"] : [])
            + ["--tool-version"]
            + (includesPartialInputs ? ["--version", "27.0", "--out", unusedOutput.path] : [])
        let output = ThreadSafeStrings()
        let errors = ThreadSafeStrings()
        let runner = RecordingCommandRunner()
        let status = await CommandLineTool(
            executableURL: nil,
            processRunner: runner,
            console: Console(output: output.append, error: errors.append),
            readLine: {
                Issue.record("version reporting prompted for input")
                return nil
            },
            defaultOutputBaseDirectory: {
                Issue.record("version reporting requested an output directory")
                return unusedOutput.path
            }
        ).run(arguments)
        #expect(status == 0)
        #expect(output.text.trimmingCharacters(in: .newlines) == PrivateHeaderKitBuildInfo.version)
        #expect(errors.text.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: unusedOutput.path))
        #expect(await runner.captureCommandSnapshot().isEmpty)
        #expect(await runner.simpleCommandSnapshot().isEmpty)
        #expect(await runner.streamingCommandSnapshot().isEmpty)
    }

    @Test func noArgumentsAndHiddenGenerateStartInteractiveMode() throws {
        #expect(try ParsedCommand(arguments: ["privateheaderkit"]) == .interactiveGenerate(outputBaseDirectory: nil))
        #expect(
            try ParsedCommand(arguments: ["privateheaderkit", "generate"])
                == .interactiveGenerate(outputBaseDirectory: nil)
        )
    }

    @Test func rootAcceptsDirectGenerationOptionsAndSourceVersion() throws {
        let parsed = try ParsedCommand(arguments: [
            "privateheaderkit",
            "--platform", "iOS",
            "--version", "27.0",
            "--build", "24A123",
            "--out", "/tmp/headers",
            "--target", "SwiftUI,UIKit",
            "--device", "SIM-001",
            "--sim-helper", "/tmp/sim-helper",
            "--resume",
        ])
        #expect(
            parsed == .generate(
                GenerateCommand.Options(
                    platform: .iOS,
                    version: "27.0",
                    build: "24A123",
                    systemRoot: nil,
                    outputBaseDirectory: "/tmp/headers",
                    targetQuery: "SwiftUI,UIKit",
                    continuationMode: .resume,
                    device: "SIM-001",
                    simulatorHelperPath: "/tmp/sim-helper"
                )
            )
        )
    }

    @Test(arguments: [false, true])
    func outputOnlyStartsTheSameWizard(_ usesAlias: Bool) throws {
        let prefix = ["privateheaderkit"] + (usesAlias ? ["generate"] : [])
        #expect(
            try ParsedCommand(arguments: prefix + ["--out", "~/Custom Headers"])
                == .interactiveGenerate(outputBaseDirectory: "~/Custom Headers")
        )
        #expect(
            try ParsedCommand(arguments: prefix + ["--out=relative/headers"])
                == .interactiveGenerate(outputBaseDirectory: "relative/headers")
        )
    }

    @Test(arguments: [false, true], [false, true])
    func runtimeMetadataIsOptIn(_ usesAlias: Bool, _ requestsRuntimeMetadata: Bool) throws {
        let arguments = ["privateheaderkit"] + (usesAlias ? ["generate"] : []) + [
            "--platform", "iOS",
            "--version", "27.0",
            "--out", "/tmp/headers",
            "--target", "SpringBoard",
        ] + (requestsRuntimeMetadata ? ["--runtime-metadata"] : [])
        guard case .generate(let command) = try ParsedCommand(arguments: arguments) else {
            Issue.record("expected generation command")
            return
        }

        #expect(command.preferRuntimeMetadata == requestsRuntimeMetadata)
        let request = try GenerateCommand.makeRequest(
            for: command,
            helperURLs: testPrivateHeaderKitHelperURLs,
            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )
        #expect(request.options.rawDumpingOptions.preferRuntimeMetadata == requestsRuntimeMetadata)
    }

    @Test func rootAcceptsWatchOSGenerationOptions() throws {
        let parsed = try ParsedCommand(arguments: [
            "privateheaderkit",
            "--platform", "watchOS",
            "--version", "27.0",
            "--build", "24R5325f",
            "--out", "/tmp/headers",
            "--target", "WatchKit",
            "--device", "WATCH-001",
        ])

        #expect(
            parsed == .generate(
                GenerateCommand.Options(
                    platform: .watchOS,
                    version: "27.0",
                    build: "24R5325f",
                    systemRoot: nil,
                    outputBaseDirectory: "/tmp/headers",
                    targetQuery: "WatchKit",
                    continuationMode: nil,
                    device: "WATCH-001",
                    simulatorHelperPath: nil
                )
            )
        )
    }

    @Test func hiddenGenerateUsesTheSameTypedMapping() throws {
        let root = try ParsedCommand(arguments: [
            "privateheaderkit",
            "--platform", "macOS",
            "--version", "16.0",
            "--system-root", "/",
            "--out", "/tmp/headers",
            "--target", "all",
            "--fresh",
        ])
        let alias = try ParsedCommand(arguments: [
            "privateheaderkit", "generate",
            "--platform", "macOS",
            "--version", "16.0",
            "--system-root", "/",
            "--out", "/tmp/headers",
            "--target", "all",
            "--fresh",
        ])
        #expect(root == alias)
    }

    @Test func rootHelpShowsGenerationSearchAndDecompilationWhileHidingGenerateAlias() async {
        let output = ThreadSafeStrings()
        let errors = ThreadSafeStrings()
        let status = await CommandLineTool(
            executableURL: nil,
            console: Console(output: output.append, error: errors.append)
        ).run(["privateheaderkit", "--help"])
        #expect(status == 0)
        #expect(output.text.contains("USAGE: privateheaderkit [<options>]"))
        #expect(output.text.contains("required when a simulator"))
        #expect(output.text.contains("version is ambiguous"))
        #expect(output.text.contains("is ambiguous"))
        #expect(output.text.contains("privateheaderkit <subcommand> [<options>]"))
        #expect(output.text.contains("SUBCOMMANDS:"))
        #expect(output.text.contains("decompile"))
        #expect(output.text.contains("search"))
        #expect(output.text.contains("--tool-version"))
        #expect(output.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .contains("Use alone to start the wizard."))
        #expect(!output.text.contains("\n  generate "))
        #expect(errors.text.isEmpty)
    }

    @Test func continuationFlagsAreMutuallyExclusive() async {
        let errors = ThreadSafeStrings()
        let status = await CommandLineTool(
            executableURL: nil,
            console: Console(output: { _ in }, error: errors.append)
        ).run(
            [
                "privateheaderkit",
                "--platform", "macOS",
                "--version", "16.0",
                "--system-root", "/",
                "--out", "/tmp/headers",
                "--target", "all",
                "--resume", "--fresh",
            ]
        )
        #expect(status != 0)
        #expect(errors.text.contains("--resume"))
        #expect(errors.text.contains("--fresh"))
        #expect(errors.text.contains("already been set"))
    }

    @Test(arguments: [
        ["--version", "27.0"],
        ["--out", "/tmp/headers", "--target", "Foo"],
        ["--out", "/tmp/headers", "--fresh"],
    ])
    func partialDirectOptionsFailInsteadOfFallingBackToInteractiveMode(_ arguments: [String]) async {
        let errors = ThreadSafeStrings()
        let status = await CommandLineTool(
            executableURL: nil,
            console: Console(output: { _ in }, error: errors.append)
        ).run(["privateheaderkit"] + arguments)
        #expect(status != 0)
        #expect(errors.text.contains("--platform"))
    }

    @Test func emptyInteractiveOutputIsRejectedBeforeSourceDiscovery() async {
        let errors = ThreadSafeStrings()
        let runner = RecordingCommandRunner()
        let status = await CommandLineTool(
            executableURL: nil,
            processRunner: runner,
            console: Console(output: { _ in }, error: errors.append)
        ).run(["privateheaderkit", "--out", ""])
        #expect(status != 0)
        #expect(errors.text.contains("Argument '--out <out>' must not be empty"))
        #expect(await runner.captureCommandSnapshot().isEmpty)
    }

    @Test func legacyExecutableNamesAsFirstArgumentKeepMigrationGuidance() async {
        for name in ["privateheaderkit-dump", "headerdump", "headerdump-sim"] {
            let errors = ThreadSafeStrings()
            let status = await CommandLineTool(
                executableURL: nil,
                console: Console(output: { _ in }, error: errors.append)
            ).run(["privateheaderkit", name])
            #expect(status == 1)
            #expect(errors.text.contains("\(name) is no longer a user-facing command"))
            #expect(errors.text.contains("use privateheaderkit instead"))
        }
    }

    @Test func emptyDeviceAndSimulatorHelperValuesFailFast() async {
        for option in ["--device", "--sim-helper"] {
            let errors = ThreadSafeStrings()
            let status = await CommandLineTool(
                executableURL: nil,
                console: Console(output: { _ in }, error: errors.append)
            ).run(
                [
                    "privateheaderkit",
                    "--platform", "iOS",
                    "--version", "27.0",
                    "--out", "/tmp/headers",
                    "--target", "all",
                    option, "",
                ]
            )
            #expect(status != 0)
            #expect(errors.text.contains("must not be empty"))
            #expect(errors.text.contains(option))
        }

        let errors = ThreadSafeStrings()
        let status = await CommandLineTool(
            executableURL: nil,
            console: Console(output: { _ in }, error: errors.append)
        ).run(
            [
                "privateheaderkit",
                "--platform", "iOS",
                "--version", "27.0",
                "--out", "/tmp/headers",
                "--target", "all",
                "--device", "   ",
            ]
        )
        #expect(status != 0)
        #expect(errors.text.contains("must not be empty"))
        #expect(errors.text.contains("--device"))
    }
}

@Suite
struct PrivateHeaderKitCLIExecutionTests {
    @Test func simulatorSessionCleansRunOwnedDeviceAfterCancellationButNeverBorrowedDevice() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        let deletionCount = ThreadSafeCounter()
        let operationStarted = EventCounter()
        let deletionWasCancelled = ThreadSafeBool()
        let deletionFails = ThreadSafeBool()
        await host.stub(deleteDevice: {
            if Task.isCancelled {
                deletionWasCancelled.setTrue()
            }
            deletionCount.increment()
            if deletionFails.value {
                throw CLIFixtureError.cleanupFailed
            }
        })
        let cancellationOutput = ThreadSafeStrings()

        let cancellationTask = Task<Int, Error> {
            // A session that fails before its operation starts fails the test instead of
            // leaving it waiting.
            defer { operationStarted.signal() }
            return try await SimulatorSession(
                processRunner: host.runner,
                console: Console(output: cancellationOutput.append, error: { _ in })
            ).run(
                for: iosGenerateCommand(build: nil, systemRoot: nil),
                operation: { _ in
                    operationStarted.signal()
                    while true {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                }
            )
        }
        await operationStarted.wait(until: 1)
        cancellationTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancellationTask.value
        }
        #expect(deletionCount.value == 1)
        #expect(!deletionWasCancelled.value)
        #expect(!cancellationOutput.text.contains(GenerationHost.createdDeviceNamePrefix))
        #expect(cancellationOutput.text.contains("UDID: \(GenerationHost.createdDeviceUDID)"))
        #expect(cancellationOutput.text.contains("Temporary device deleted"))

        let borrowedOutput = ThreadSafeStrings()
        let value: Int = try await SimulatorSession(
            processRunner: host.runner,
            console: Console(output: borrowedOutput.append, error: { _ in })
        ).run(
            for: iosGenerateCommand(
                build: nil,
                systemRoot: nil,
                device: GenerationHost.bootedDeviceName
            ),
            operation: { _ in 7 }
        )
        #expect(value == 7)
        #expect(deletionCount.value == 1)
        #expect(
            borrowedOutput.text.contains(
                "Simulator ready: \(GenerationHost.bootedDeviceName) "
                    + "(UDID: \(GenerationHost.bootedDeviceUDID))"
            )
        )
        #expect(!borrowedOutput.text.contains("Cleanup"))

        deletionFails.setTrue()
        let failedCleanupOutput = ThreadSafeStrings()
        do {
            let _: Int = try await SimulatorSession(
                processRunner: host.runner,
                console: Console(output: failedCleanupOutput.append, error: { _ in })
            ).run(
                for: iosGenerateCommand(build: nil, systemRoot: nil),
                operation: { _ in 9 }
            )
            Issue.record("successful operation unexpectedly hid simulator cleanup failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("simulator cleanup failed for"))
            #expect(message.contains(GenerationHost.createdDeviceNamePrefix))
            #expect(message.contains("UDID: \(GenerationHost.createdDeviceUDID)"))
            #expect(message.contains("cleanupFailed"))
        }
        #expect(deletionCount.value == 2)
        #expect(!failedCleanupOutput.text.contains("Temporary device deleted"))
    }

    @Test func simulatorCleanupFailureOverridesInteractiveBack() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        await host.stub(deleteDevice: { throw CLIFixtureError.cleanupFailed })

        do {
            let _: Int = try await SimulatorSession(
                processRunner: host.runner,
                console: Console(output: { _ in }, error: { _ in })
            ).run(
                for: iosGenerateCommand(build: nil, systemRoot: nil),
                operation: { _ in throw PrivateHeaderKitInteractiveNavigation.back }
            )
            Issue.record("interactive Back unexpectedly hid simulator cleanup failure")
        } catch is PrivateHeaderKitInteractiveNavigation {
            Issue.record("interactive Back unexpectedly won over simulator cleanup failure")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("simulator cleanup failed for"))
            #expect(message.contains("after"))
            #expect(message.contains(GenerationHost.createdDeviceNamePrefix))
            #expect(message.contains("UDID: \(GenerationHost.createdDeviceUDID)"))
            #expect(message.contains("cleanupFailed"))
        }
    }

    @Test func implicitWatchOSRuntimeUsesSimulatorFlowAndWatchStorageIdentity() throws {
        let request = try GenerateCommand.makeRequest(
            for: watchOSGenerateCommand(build: nil, systemRoot: nil),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitWatchSimulatorResolution
        )

        #expect(request.source.platform == .watchOS)
        #expect(request.source.build == "24R5325f")
        #expect(request.source.storageIdentifier == "watchos-v1-27.0-b1-24~525325~66")
        #expect(request.options.systemRoot?.path == "/ResolvedWatchRuntime")
        #expect(
            request.options.executionMode
                == testExecutionMode(
                    resolution: testPrivateHeaderKitWatchSimulatorResolution,
                    sourceRuntimeRoot: "/ResolvedWatchRuntime"
                )
        )
    }

    @Test func watchOSPreparationSelectsWatchRuntimeAndHelperPlatform() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }

        let request = try await GenerateCommand(
            options: watchOSGenerateCommand(build: nil, systemRoot: nil),
            executableURL: host.executable,
            processRunner: host.runner,
            console: Console(output: { _ in }, error: { _ in })
        ).makeRequest(simulatorResolution: testPrivateHeaderKitWatchSimulatorResolution)

        #expect(request.source.platform == .watchOS)
        #expect(
            request.options.helperURLs?.simulator.lastPathComponent
                == "privateheaderkit-watch-sim-helper"
        )
    }

    @Test func implicitIOSRuntimePersistsResolvedBuildIdentity() throws {
        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: nil, systemRoot: nil),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )

        #expect(request.source.build == "24A123")
        #expect(request.source.storageIdentifier == "ios-v1-27.0-b1-24~41123")
        #expect(request.options.systemRoot?.path == "/ResolvedRuntime")
        #expect(request.options.rawDumpingOptions.useSharedCache)
        #expect(request.options.producerVersion == PrivateHeaderKitBuildInfo.version)
        #expect(
            request.options.executionMode
                == testExecutionMode(
                    resolution: testPrivateHeaderKitSimulatorResolution,
                    sourceRuntimeRoot: "/ResolvedRuntime"
                )
        )
    }

    @Test func betaRuntimeProducesHumanReadableArtifactPath() throws {
        let resolution = SimulatorResolution(
            runtimeVersion: "27.0",
            runtimeBuild: "24A5390f",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            resolvedRuntimeRoot: "/ResolvedBetaRuntime",
            metadataIsSeed: true,
            deviceName: "iPhone 17 Pro",
            deviceUDID: "SIM-BETA"
        )
        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: nil, systemRoot: nil),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: resolution
        )

        #expect(request.source.label.displayName == "iOS 27.0 beta (24A5390f)")
        #expect(
            request.output.artifactDirectory(for: request.source).path
                == "/tmp/PrivateHeaderKit/generated-headers/iOS/27.0_beta_24A5390f"
        )
        #expect(request.source.storageIdentifier == "ios-v1-27.0-b1-24~415390~66")
    }

    @Test func simulatorWithoutReleaseMetadataResolvesAsARelease() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {"runtimes":[{"name":"iOS 27.0","platform":"iOS","version":"27.0","buildversion":"24A5390f","identifier":"ios-27","runtimeRoot":"\(runtimeRoot.path)","isAvailable":true,"supportedDeviceTypes":[{"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","productFamily":"iPhone"}]}]}
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )
        let deviceUDID = "11111111-2222-3333-4444-555555555555"
        let createCommand = [
            "xcrun", "simctl", "create", "PrivateHeaderKit Dump (iOS 27.0)",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "ios-27",
        ]
        await runner.setCaptureOutput(deviceUDID + "\n", for: createCommand)

        let resolution = try await SimulatorSession.resolve(
            for: iosGenerateCommand(build: nil, systemRoot: nil),
            processRunner: runner,
            dedicatedDeviceName: "PrivateHeaderKit Dump (iOS 27.0)"
        )

        #expect(!resolution.metadataIsSeed)
        #expect(resolution.resolvedRuntimeRoot == runtimeRoot.path)
        #expect(resolution.deviceUDID == deviceUDID)
        #expect(resolution.deviceOwnership == .runOwned)
        #expect(await runner.captureCommandSnapshot().map(\.command) == [
            ["xcrun", "simctl", "list", "runtimes", "-j"],
            createCommand,
        ])
        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
            ["xcrun", "simctl", "bootstatus", deviceUDID, "-b"],
        ])
    }

    @Test func malformedSimulatorReleaseMetadataFailsBeforeResolvingADevice() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(
            to: runtimeRoot.appendingPathComponent("RestoreVersion.plist")
        )
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            """
            {"runtimes":[{"name":"iOS 27.0","platform":"iOS","version":"27.0","buildversion":"24A5390f","identifier":"ios-27","runtimeRoot":"\(runtimeRoot.path)","isAvailable":true}]}
            """,
            for: ["xcrun", "simctl", "list", "runtimes", "-j"]
        )

        await #expect(throws: ToolingError.self) {
            _ = try await SimulatorSession.resolve(
                for: iosGenerateCommand(build: nil, systemRoot: nil),
                processRunner: runner
            )
        }
        #expect(await runner.captureCommandSnapshot().map(\.command) == [
            ["xcrun", "simctl", "list", "runtimes", "-j"],
        ])
        #expect(await runner.simpleCommandSnapshot().isEmpty)
    }

    @Test func explicitIOSSystemRootDoesNotBorrowResolvedRuntimeBuild() throws {
        let overrideRoot = try temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: overrideRoot) }
        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: nil, systemRoot: overrideRoot.path),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )

        #expect(request.source.build == nil)
        #expect(request.source.storageIdentifier == "ios-v1-27.0-b0")
        #expect(request.options.systemRoot?.path == overrideRoot.path)
        #expect(!request.options.rawDumpingOptions.useSharedCache)
        #expect(
            request.options.executionMode
                == testExecutionMode(
                    resolution: testPrivateHeaderKitSimulatorResolution,
                    sourceRuntimeRoot: overrideRoot.path
                )
        )
    }

    @Test func explicitIOSSeedRootRequiresBuildButNotALowercaseSuffix() throws {
        let seedRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: seedRoot) }
        try writeReleaseMetadata(isSeed: true, in: seedRoot, layout: .simulator)
        #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
            _ = try GenerateCommand.makeRequest(
                for: iosGenerateCommand(build: nil, systemRoot: seedRoot.path),
                helperURLs: testPrivateHeaderKitHelperURLs,

                simulatorResolution: testPrivateHeaderKitSimulatorResolution
            )
        }

        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: "24A123", systemRoot: seedRoot.path),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )
        #expect(request.source.releaseChannel == .beta)
        #expect(request.source.artifactDirectoryName == "27.0_beta_24A123")
    }

    @Test func explicitPublicRootKeepsLowercaseBuildSuffixOutOfBetaNamespace() throws {
        let publicRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: publicRoot) }
        let command = GenerateCommand.Options(
            platform: .iOS,
            version: "16.4.1",
            build: "20E772520a",
            systemRoot: publicRoot.path,
            outputBaseDirectory: "/tmp/PrivateHeaderKit",
            targetQuery: "all",
            continuationMode: .fresh,
            device: nil,
            simulatorHelperPath: nil
        )
        let request = try GenerateCommand.makeRequest(
            for: command,
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )

        #expect(request.source.releaseChannel == .release)
        #expect(request.source.artifactDirectoryName == "16.4.1_20E772520a")
    }

    @Test func explicitIOSBuildOverridesResolvedRuntimeBuild() throws {
        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: "24A999", systemRoot: nil),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )

        #expect(request.source.build == "24A999")
        #expect(request.source.storageIdentifier == "ios-v1-27.0-b1-24~41999")
        #expect(request.options.rawDumpingOptions.useSharedCache)
    }

    @Test func explicitIOSRuntimeAliasUsesTheSelectedRuntimeIdentityAndLoadedCache() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let runtimeAlias = root.appendingPathComponent("RuntimeAlias", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runtimeAlias,
            withDestinationURL: runtimeRoot
        )
        let resolution = SimulatorResolution(
            runtimeVersion: "27.0",
            runtimeBuild: "24A123",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            resolvedRuntimeRoot: runtimeRoot.path,
            metadataIsSeed: false,
            deviceName: "iPhone 17 Pro",
            deviceUDID: "SIM-001"
        )

        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: nil, systemRoot: runtimeAlias.path),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: resolution
        )
        let canonicalRuntimeRoot = runtimeRoot.resolvingSymlinksInPath().standardizedFileURL

        #expect(request.source.build == "24A123")
        #expect(request.source.storageIdentifier == "ios-v1-27.0-b1-24~41123")
        #expect(request.options.systemRoot == canonicalRuntimeRoot)
        #expect(request.options.rawDumpingOptions.useSharedCache)
        #expect(
            request.options.executionMode
                == testExecutionMode(
                    resolution: resolution,
                    sourceRuntimeRoot: canonicalRuntimeRoot.path
                )
        )
        #expect(
            request.options.rawDumpingOptions.helperEnvironment["PH_RUNTIME_ROOT"]
                == canonicalRuntimeRoot.path
        )
    }

    @Test func explicitIOSBuildOverridesSelectedRuntimeBuildForExplicitRuntimeRoot() throws {
        let request = try GenerateCommand.makeRequest(
            for: iosGenerateCommand(build: "24A999", systemRoot: "/ResolvedRuntime"),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: testPrivateHeaderKitSimulatorResolution
        )

        #expect(request.source.build == "24A999")
        #expect(request.source.storageIdentifier == "ios-v1-27.0-b1-24~41999")
        #expect(request.options.systemRoot?.path == "/ResolvedRuntime")
        #expect(request.options.rawDumpingOptions.useSharedCache)
    }

    @Test func macOSUsesLoadedCacheOnlyForTheCurrentRoot() throws {
        // The build keeps the request valid when the Mac running the tests is a seed build.
        let currentRootRequest = try GenerateCommand.makeRequest(
            for: macOSGenerateCommand(build: "24A1", systemRoot: "/"),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: nil
        )
        #expect(currentRootRequest.options.systemRoot?.path == "/")
        #expect(currentRootRequest.options.rawDumpingOptions.useSharedCache)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let customRoot = root.appendingPathComponent("MountedSystem", isDirectory: true)
        try writeReleaseMetadata(isSeed: false, in: customRoot, layout: .macOS)
        let customRootRequest = try GenerateCommand.makeRequest(
            for: macOSGenerateCommand(systemRoot: customRoot.path),
            helperURLs: testPrivateHeaderKitHelperURLs,

            simulatorResolution: nil
        )
        #expect(
            customRootRequest.options.systemRoot
                == customRoot.resolvingSymlinksInPath().standardizedFileURL
        )
        #expect(!customRootRequest.options.rawDumpingOptions.useSharedCache)
    }

    @Test func invalidSourceMetadataFailsBeforeHelperResolution() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seedRoot = root.appendingPathComponent("SeedSystemRoot", isDirectory: true)
        try writeReleaseMetadata(isSeed: true, in: seedRoot, layout: .macOS)
        // From a package checkout, helper resolution starts by asking SwiftPM for the bin path.
        let runner = RecordingCommandRunner()

        await #expect(throws: PrivateHeaderGeneration.Source.ValidationError.self) {
            _ = try await GenerateCommand(
                options: macOSGenerateCommand(systemRoot: seedRoot.path),
                executableURL: root.appendingPathComponent(".build/debug/privateheaderkit"),
                processRunner: runner,
                console: Console(output: { _ in }, error: { _ in })
            ).makeRequest(simulatorResolution: nil)
        }

        #expect(await runner.captureCommandSnapshot().isEmpty)
    }

    @Test func directRunPublishesTargetsAndRendersResultAndWarnings() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        for name in ["AppKit", "Foundation"] {
            try host.addFramework(name, to: host.systemRoot)
        }
        await host.stub(helper: { invocation in
            try invocation.succeed(
                diagnostics: invocation.target.hasSuffix("AppKit.framework")
                    ? [.init(owner: "Objective-C class NSView", degradation: "method list was truncated")]
                    : []
            )
        })
        let output = ThreadSafeStrings()

        let status = await host.run(
            host.macOSArguments + [
                "--out", host.output.path, "--target", "AppKit,Foundation", "--fresh",
            ],
            output: output
        )

        #expect(status == 0)
        let helperCommands = await host.runner.streamingCommandSnapshot().map(\.command)
        #expect(helperCommands.count == 2)
        #expect(helperCommands.allSatisfy { $0.first == host.hostHelper.path })
        #expect(await host.createdDeviceCount() == 0)
        let headersPath = host.output.appendingPathComponent("generated-headers/macOS/16.0").path
        #expect(
            try String(
                contentsOfFile: headersPath + "/Frameworks/AppKit/Headers/Generated.h",
                encoding: .utf8
            ) == "generated"
        )
        #expect(output.text.contains("Generated  2"))
        #expect(output.text.contains("Skipped    0"))
        #expect(output.text.contains("objc-metadata-warning"))
        #expect(output.text.contains("Objective-C class NSView: method list was truncated"))
        #expect(output.text.contains("generation.sqlite"))
        #expect(output.text.components(separatedBy: headersPath).count == 3)
        #expect(output.text.contains(": 2 targets → \(headersPath)"))
        #expect(output.text.contains("Output\n  Headers"))
        #expect(output.text.contains("Diagnostics\n  State"))
        #expect(output.text.contains("  Run        run-"))
        #expect(!output.text.contains("…"))
        #expect(output.text.hasSuffix("Finished\n  Status     completed"))
    }

    @Test func macOSAcceptsASimulatorHelperPathWithoutResolvingSimulator() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("AppKit", to: host.systemRoot)
        await host.stub()
        let output = ThreadSafeStrings()

        let status = await host.run(
            host.macOSArguments + [
                "--out", host.output.path, "--target", "AppKit",
                "--sim-helper", "/custom/privateheaderkit-sim-helper",
            ],
            output: output
        )

        #expect(status == 0)
        #expect(await host.runner.captureCommandSnapshot().isEmpty)
        #expect(
            await host.runner.streamingCommandSnapshot().map(\.command.first)
                == [host.hostHelper.path]
        )
    }

    @Test func runOwnedSuccessCleansBeforeCompletedFinalStatus() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("AppKit", to: host.runtimeRoot)
        let output = ThreadSafeStrings()
        let errors = ThreadSafeStrings()
        await host.stub(deleteDevice: { output.append("cleanup command completed") })

        let status = await host.run(
            GenerationHost.iOSArguments + ["--out", host.output.path, "--target", "AppKit"],
            output: output,
            errors: errors
        )

        #expect(status == 0)
        #expect(errors.text.isEmpty)
        #expect(!output.text.contains(GenerationHost.createdDeviceNamePrefix))
        let rendered = output.text
        let summary = try #require(rendered.range(of: "Generation completed"))
        let cleanupCommand = try #require(rendered.range(of: "cleanup command completed"))
        let cleanupResult = try #require(rendered.range(of: "Cleanup"))
        let finished = try #require(rendered.range(of: "Finished"))
        #expect(summary.lowerBound < cleanupCommand.lowerBound)
        #expect(cleanupCommand.lowerBound < cleanupResult.lowerBound)
        #expect(cleanupResult.lowerBound < finished.lowerBound)
        #expect(rendered.hasSuffix("Finished\n  Status     completed"))
    }

    @Test func runFailureRendersFailedTargetsBeforeRunOwnedCleanup() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        for name in ["AppKit", "Foundation"] {
            try host.addFramework(name, to: host.runtimeRoot)
        }
        let output = ThreadSafeStrings()
        await host.stub(
            deleteDevice: { output.append("cleanup command completed") },
            helper: { invocation in
                invocation.target.hasSuffix("AppKit.framework")
                    ? try invocation.fail("fixture failure")
                    : try invocation.succeed()
            }
        )

        let status = await host.run(
            GenerationHost.iOSArguments + [
                "--out", host.output.path, "--target", "AppKit,Foundation",
            ],
            output: output
        )

        #expect(status == 2)
        #expect(output.text.contains("Generation completed with failures"))
        #expect(output.text.contains("Failed targets\n  AppKit (failed)"))
        #expect(
            output.text.contains(
                host.output.path + "/.state/ios-v1-27.0-b1-24~41123/generation.sqlite"
            )
        )
        #expect(!output.text.contains(GenerationHost.createdDeviceNamePrefix))
        #expect(output.text.contains("UDID: \(GenerationHost.createdDeviceUDID)"))
        let rendered = output.text
        let summaryRange = try #require(
            rendered.range(of: "Generation completed with failures")
        )
        let cleanupCommand = try #require(rendered.range(of: "cleanup command completed"))
        let cleanupResult = try #require(rendered.range(of: "Cleanup"))
        let finished = try #require(rendered.range(of: "Finished"))
        #expect(summaryRange.lowerBound < cleanupCommand.lowerBound)
        #expect(cleanupCommand.lowerBound < cleanupResult.lowerBound)
        #expect(cleanupResult.lowerBound < finished.lowerBound)
        #expect(rendered.hasSuffix("Finished\n  Status     partial"))
    }

    @Test func unfinishedAllTargetRunRequiresResumeOrFresh() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        for name in ["Bar", "Foo"] {
            try host.addFramework(name, to: host.systemRoot)
        }
        let arguments = host.macOSArguments + ["--out", host.output.path, "--target", "all"]
        await host.stub(helper: { invocation in
            invocation.target.hasSuffix("Bar.framework")
                ? try invocation.fail("fixture failure")
                : try invocation.succeed()
        })
        #expect(await host.run(arguments, output: ThreadSafeStrings()) == 2)

        let undecided = ThreadSafeStrings()
        #expect(await host.run(arguments, output: undecided) == 2)
        #expect(undecided.text.contains("explicit resume is required"))
        #expect(undecided.text.contains("rerun with `--resume`"))
        #expect(!undecided.text.contains("Finished"))
        #expect(!undecided.text.contains("Status     failed"))
        #expect(await host.helperRunCount() == 2)

        let resumed = ThreadSafeStrings()
        #expect(await host.run(arguments + ["--resume"], output: resumed) == 2)
        #expect(resumed.text.contains("Skipped    1"))
        #expect(await host.helperRunCount() == 3)

        await host.stub()
        let restarted = ThreadSafeStrings()
        #expect(await host.run(arguments + ["--fresh"], output: restarted) == 0)
        #expect(restarted.text.contains("Generated  2"))
        #expect(restarted.text.contains("Skipped    0"))
        #expect(await host.helperRunCount() == 5)
    }

    @Test func interruptionAndInfrastructureErrorsRenderTheirTypedSummaries() async throws {
        for kind in [FailureKind.interrupted, .infrastructure] {
            let host = try GenerationHost()
            defer { host.cleanup() }
            try host.addFramework("Foo", to: host.systemRoot)
            await host.stub(helper: { invocation in
                if kind == .interrupted {
                    throw CancellationError()
                }
                throw ToolingError.processLaunchFailed(
                    command: invocation.command,
                    underlying: "helper could not be started"
                )
            })
            let output = ThreadSafeStrings()

            let status = await host.run(
                host.macOSArguments + ["--out", host.output.path, "--target", "all"],
                output: output
            )

            #expect(status == 2)
            if kind == .interrupted {
                #expect(output.text.contains("Generation interrupted"))
            } else {
                #expect(output.text.contains("Generation stopped"))
                #expect(output.text.contains("helper could not be started"))
            }
        }
    }

    @Test func cancelledCoreInterruptionReturns130AfterRunOwnedCleanup() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("Foo", to: host.runtimeRoot)
        let generationStarted = EventCounter()
        let cancellationObserved = EventCounter()
        let output = ThreadSafeStrings()
        await host.stub(
            deleteDevice: { output.append("cleanup command completed") },
            helper: { _ in
                generationStarted.signal()
                await withTaskCancellationHandler {
                    await cancellationObserved.wait(until: 1)
                } onCancel: {
                    cancellationObserved.signal()
                }
                throw CancellationError()
            }
        )
        let task = Task {
            // A run that ends before it reaches the helper fails the test instead of leaving
            // it waiting.
            defer { generationStarted.signal() }
            return await host.run(
                GenerationHost.iOSArguments + ["--out", host.output.path, "--target", "all"],
                output: output
            )
        }

        await generationStarted.wait(until: 1)
        task.cancel()
        #expect(await task.value == 130)
        #expect(output.text.contains("Generation interrupted"))
        let rendered = output.text
        let summary = try #require(rendered.range(of: "Generation interrupted"))
        let cleanupCommand = try #require(rendered.range(of: "cleanup command completed"))
        let cleanupResult = try #require(rendered.range(of: "Cleanup"))
        let finished = try #require(rendered.range(of: "Finished"))
        #expect(summary.lowerBound < cleanupCommand.lowerBound)
        #expect(cleanupCommand.lowerBound < cleanupResult.lowerBound)
        #expect(cleanupResult.lowerBound < finished.lowerBound)
        #expect(rendered.hasSuffix("Finished\n  Status     interrupted"))
        #expect(!output.text.contains("error:"))
    }

    @Test func sourceDiscoveryIncludesSimulatorRuntimeWithoutReleaseMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseRuntimeRoot = root.appendingPathComponent("iOS 17.5", isDirectory: true)
        let seedRuntimeRoot = root.appendingPathComponent("watchOS 27.0", isDirectory: true)
        try FileManager.default.createDirectory(
            at: releaseRuntimeRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: seedRuntimeRoot,
            withIntermediateDirectories: true
        )
        let seedMetadata = try PropertyListSerialization.data(
            fromPropertyList: ["IsSeed": true],
            format: .binary,
            options: 0
        )
        try seedMetadata.write(
            to: seedRuntimeRoot.appendingPathComponent("RestoreVersion.plist")
        )
        let runner = CaptureOnlyCommandRunner { command, _, _ in
            switch command {
            case ["xcrun", "--find", "simctl"]:
                return "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl\n"
            case ["xcrun", "simctl", "list", "runtimes", "-j"]:
                return """
                {"runtimes":[{"name":"watchOS 27.0","platform":"watchOS","version":"27.0","buildversion":"24R5325f","identifier":"watch-27","runtimeRoot":"\(seedRuntimeRoot.path)","isAvailable":true},{"name":"iOS 17.5","platform":"iOS","version":"17.5","buildversion":"21F79","identifier":"ios-17-5","runtimeRoot":"\(releaseRuntimeRoot.path)","isAvailable":true}]}
                """
            case ["/usr/bin/sw_vers", "-productVersion"]:
                return "16.0\n"
            case ["/usr/bin/sw_vers", "-buildVersion"]:
                return "24A1\n"
            default:
                throw ToolingError.message("unexpected command: \(command)")
            }
        }

        let sources = try await SourceDiscovery.discover(using: runner)

        #expect(sources.failures.isEmpty)
        #expect(sources.sources == [
            SourceDiscovery.Source(
                platform: .iOS,
                version: "17.5",
                build: "21F79",
                systemRoot: nil
            ),
            SourceDiscovery.Source(
                platform: .watchOS,
                version: "27.0",
                build: "24R5325f",
                metadataIsSeed: true,
                systemRoot: nil
            ),
            SourceDiscovery.Source(
                platform: .macOS,
                version: "16.0",
                build: "24A1",
                metadataIsSeed: try hostIsSeed(),
                systemRoot: "/"
            ),
        ])
    }

    @Test func sourceDiscoveryReportsListingFailuresAndPropagatesCancellation() async throws {
        let unavailableRunner = CaptureOnlyCommandRunner { command, _, _ in
            switch command {
            case ["xcrun", "simctl", "list", "runtimes", "-j"]:
                throw DiscoveryProbeError.commandFailed
            case ["/usr/bin/sw_vers", "-productVersion"]:
                return "16.0\n"
            case ["/usr/bin/sw_vers", "-buildVersion"]:
                return "24A1\n"
            default:
                throw ToolingError.message("unexpected command: \(command)")
            }
        }
        #expect(
            try await SourceDiscovery.discover(
                using: unavailableRunner
            ).sources == [
                SourceDiscovery.Source(
                    platform: .macOS,
                    version: "16.0",
                    build: "24A1",
                    metadataIsSeed: try hostIsSeed(),
                    systemRoot: "/"
                )
            ]
        )

        let failingRunner = CaptureOnlyCommandRunner { _, _, _ in
            throw DiscoveryProbeError.commandFailed
        }
        let failed = try await SourceDiscovery.discover(using: failingRunner)
        #expect(failed.sources.isEmpty)
        #expect(failed.failures.map(\.source) == ["Simulator runtimes", "macOS"])
        #expect(failed.failures.allSatisfy { $0.message.contains("commandFailed") })

        let cancellingRunner = CaptureOnlyCommandRunner { command, _, _ in
            #expect(command == ["xcrun", "simctl", "list", "runtimes", "-j"])
            throw CancellationError()
        }
        do {
            _ = try await SourceDiscovery.discover(using: cancellingRunner)
            Issue.record("expected discovery cancellation")
        } catch is CancellationError {
            // Cancellation remains distinct from source unavailability.
        } catch {
            Issue.record("unexpected cancellation error: \(error)")
        }
    }

    @Test(arguments: ["simulator", "host", "both"])
    func sourceDiscoveryKeepsIndependentSourcesAndDisplaysFailures(_ failedSource: String) async throws {
        let runtimeRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        let runner = CaptureOnlyCommandRunner { command, _, _ in
            switch command {
            case ["xcrun", "simctl", "list", "runtimes", "-j"]:
                if failedSource != "host" { throw ToolingError.message("simulator-list-failed") }
                return """
                    {"runtimes":[{"platform":"iOS","version":"27.0","buildversion":"24A123","identifier":"ios-27","runtimeRoot":"\(runtimeRoot.path)","isAvailable":true}]}
                    """
            case ["/usr/bin/sw_vers", "-productVersion"]:
                if failedSource != "simulator" { throw ToolingError.message("host-version-failed") }
                return "27.0"
            case ["/usr/bin/sw_vers", "-buildVersion"]:
                return "26A123"
            default:
                throw ToolingError.message("unexpected command: \(command)")
            }
        }
        let discovery = try await SourceDiscovery.discover(using: runner)
        let expectedPlatforms: [GenerateCommand.Platform] = switch failedSource {
        case "simulator": [.macOS]
        case "host": [.iOS]
        default: []
        }
        #expect(discovery.sources.map(\.platform) == expectedPlatforms)
        #expect(discovery.failures.count == (failedSource == "both" ? 2 : 1))
        let output = ThreadSafeStrings()
        let status = await CommandLineTool(
            processRunner: runner,
            console: Console(output: output.append, error: output.append),
            readLine: {
                #expect(!discovery.sources.isEmpty)
                return "\u{001B}"
            },
            clearScreen: {}
        ).run(["privateheaderkit"])
        #expect(status == (failedSource == "both" ? 2 : 1))
        for failure in discovery.failures {
            #expect(output.text.contains(failure.description))
        }
        if failedSource == "both" {
            #expect(output.text.contains("no available generation sources found"))
        } else {
            #expect(output.text.contains("Unavailable sources"))
            #expect(output.text.contains("Select source:"))
        }
    }

    @Test func malformedRuntimeMetadataDoesNotHideOtherSourcesOrAllowExplicitGeneration() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("Broken")
        let usable = root.appendingPathComponent("Usable")
        for directory in [broken, usable] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("not a plist".utf8).write(to: broken.appendingPathComponent("RestoreVersion.plist"))
        try PropertyListSerialization.data(
            fromPropertyList: ["IsSeed": true], format: .binary, options: 0
        ).write(to: usable.appendingPathComponent("RestoreVersion.plist"))
        let listing = """
        {"runtimes":[
          {"platform":"iOS","version":"27.0","buildversion":"24A123","identifier":"ios-27","runtimeRoot":"\(broken.path)","isAvailable":true},
          {"platform":"iOS","version":"27.1","buildversion":"24A234","identifier":"ios-27-1","runtimeRoot":"\(usable.path)","isAvailable":true}
        ]}
        """
        let runner = CaptureOnlyCommandRunner { command, _, _ in
            switch command {
            case ["xcrun", "simctl", "list", "runtimes", "-j"]: return listing
            case ["/usr/bin/sw_vers", "-productVersion"]: return "27.0"
            case ["/usr/bin/sw_vers", "-buildVersion"]: return "26A123"
            default: throw ToolingError.message("unexpected command: \(command)")
            }
        }
        let discovery = try await SourceDiscovery.discover(using: runner)
        #expect(discovery.sources.map(\.platform) == [.iOS, .macOS])
        #expect(discovery.sources.first?.version == "27.1")
        #expect(discovery.sources.first?.metadataIsSeed == true)
        #expect(discovery.failures.map(\.source) == ["iOS 27.0 (24A123)"])
        #expect(discovery.failures.first?.message.contains(broken.path) == true)
        let command = GenerateCommand.Options(
            platform: .iOS, version: "27.0", build: "24A123", systemRoot: nil,
            outputBaseDirectory: root.appendingPathComponent("Output").path,
            targetQuery: "Foo", continuationMode: nil, device: nil, simulatorHelperPath: nil
        )
        do {
            _ = try await SimulatorSession.resolve(for: command, processRunner: runner)
            Issue.record("malformed metadata was accepted for generation")
        } catch let error as ToolingError {
            #expect(error.description.contains("failed to decode runtime release metadata"))
            #expect(error.description.contains(broken.path))
        }
    }

    @Test(arguments: ["listing", "host"])
    func sourceDiscoveryPropagatesCancellationFromEachCommand(_ phase: String) async throws {
        let calls = ThreadSafeStrings()
        let runner = CaptureOnlyCommandRunner { command, _, _ in
            calls.append(command.joined(separator: " "))
            switch command {
            case ["xcrun", "simctl", "list", "runtimes", "-j"]:
                if phase == "listing" { throw CancellationError() }
                return #"{"runtimes":[{"platform":"iOS","version":"27.0","buildversion":"24A123","identifier":"ios-27","runtimeRoot":"/runtimes/iOS","isAvailable":true}]}"#
            case ["/usr/bin/sw_vers", "-productVersion"]:
                throw CancellationError()
            default:
                throw ToolingError.message("unexpected command: \(command)")
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await SourceDiscovery.discover(using: runner)
        }
        #expect(calls.text.contains("sw_vers") == (phase == "host"))
        #expect(!calls.text.contains("-buildVersion"))
    }

    @Test func preparedGenerationUsesOneRunnerForInventoryAndRawDump() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let systemRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
        let helperURL = root.appendingPathComponent("privateheaderkit-raw-helper")
        let inventoryCommand = [helperURL.path, "__shared-cache-inventory"]
        let runner = RecordingCommandRunner()
        let inventoryData = try JSONEncoder().encode(
            PrivateHeaderKitSharedCacheInventory(
                cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                imagePaths: ["/usr/lib/libCacheOnly.dylib"]
            )
        )
        await runner.setCaptureOutput(
            String(decoding: inventoryData, as: UTF8.self),
            for: inventoryCommand
        )
        await runner.setStreamingHandler { command, _, _ in
            try writeRawDumpProcessHandshake(for: command)
            guard let outputIndex = command.firstIndex(of: "-o"), outputIndex + 1 < command.count else {
                throw ToolingError.message("raw dump command is missing its output directory")
            }
            let stagingDirectory = URL(
                fileURLWithPath: command[outputIndex + 1],
                isDirectory: true
            )
            let headerDirectory = stagingDirectory
                .appendingPathComponent("usr/lib/libCacheOnly.dylib/Headers", isDirectory: true)
            try FileManager.default.createDirectory(
                at: headerDirectory,
                withIntermediateDirectories: true
            )
            try Data("// generated\n".utf8).write(
                to: headerDirectory.appendingPathComponent("Generated.h")
            )
            guard let reportIndex = command.firstIndex(of: "--diagnostics-report"),
                  reportIndex + 1 < command.count
            else {
                throw ToolingError.message("raw dump command is missing its diagnostics report")
            }
            try JSONEncoder().encode(
                PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: [])
            ).write(to: URL(fileURLWithPath: command[reportIndex + 1]), options: .atomic)
            return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
        }

        let helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
            host: helperURL,
            simulator: root.appendingPathComponent("privateheaderkit-sim-helper")
        )
        let request = GenerationRequest(
            source: try PrivateHeaderGeneration.Source(
                platform: .macOS,
                version: "16.0",
                metadataIsSeed: false
            ),
            output: PrivateHeaderGeneration.Output(
                baseDirectory: root.appendingPathComponent("Output", isDirectory: true)
            ),
            options: PrivateHeaderGeneration.Options(
                targetRequest: .query("/usr/lib/libCacheOnly.dylib"),
                systemRoot: systemRoot,
                helperURLs: helperURLs,
                executionMode: .host,
                rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
                    useSharedCache: true
                ),
                continuation: .restart
            )
        )
        let prepared = try await PreparedGeneration(
            request: request,
            processRunner: runner,
            recoveryReporter: { _ in }
        )

        #expect(try await prepared.summary() == .noUnfinishedRun)
        #expect(await runner.captureCommandSnapshot().count == 1)

        let result = try await prepared.run(.restart, progressReporter: { _ in })
        #expect(result.targetCounts.completed == 1)
        #expect(await runner.captureCommandSnapshot().map(\.command) == [inventoryCommand])
        #expect(await runner.streamingCommandSnapshot().count == 1)
    }

    @Test func rawDumpUsesBufferedRunnerAndRetainsFailureTail() async throws {
        let helperURL = URL(fileURLWithPath: "/tmp/privateheaderkit-raw-helper")
        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            try PrivateHeaderGeneration.RawDumping.Request(
                helperURLs: .init(host: helperURL, simulator: helperURL),
                executionMode: .host,
                inputPath: "/System/Library/Frameworks/AppKit.framework",
                stagingOutputDirectory: URL(fileURLWithPath: "/tmp/privateheaderkit-stage")
            )
        )

        let result = try await runPrivateHeaderKitRawDump(
            invocation,
            processRunner: BufferedRawDumpProbeRunner()
        )

        #expect(result.terminationStatus == 19)
        #expect(!result.wasKilled)
        #expect(
            result.failureSummary
                == "helper-warning\nfatal-tail\n"
                    + "privateheaderkit raw helper error: capsule=v1 termination=exit(19) "
                    + "wrapper_status=19 wrapper_killed=false "
                    + "handshake=available helper=privateheaderkit-raw-helper "
                    + "lc_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee pid=4242 "
                    + "start_us=1700000000123456 termination_observed_us=unavailable"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: invocation.processHandshakeReportURL.path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: invocation.diagnosticsReportURL.path))
    }

    @Test func successfulRawDumpRequiresConsumesAndReturnsDiagnosticsReport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
            try .init(
                helperURLs: .init(host: root.appendingPathComponent("helper"), simulator: root),
                executionMode: .host,
                inputPath: "/System/Library/Frameworks/AppKit.framework",
                stagingOutputDirectory: stage
            )
        )
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { command, _, _ in
            try writeRawDumpProcessHandshake(for: command)
            guard let reportIndex = command.firstIndex(of: "--diagnostics-report") else {
                throw ToolingError.message("missing diagnostics report argument")
            }
            try JSONEncoder().encode(
                PrivateHeaderKitRawDumpDiagnosticsReport(
                    diagnostics: [
                        PrivateHeaderKitRawDumpDiagnostic(
                            owner: "Objective-C protocol P",
                            degradation: "list was truncated"
                        ),
                    ],
                    omittedDiagnosticCount: 2
                )
            ).write(to: URL(fileURLWithPath: command[reportIndex + 1]), options: .atomic)
            return StreamingCommandResult(
                status: 0,
                wasKilled: false,
                lastLines: ["successful helper stderr is not a persisted failure"]
            )
        }

        let result = try await runPrivateHeaderKitRawDump(invocation, processRunner: runner)

        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.owner == "Objective-C protocol P")
        #expect(result.omittedDiagnosticCount == 2)
        #expect(result.failureSummary == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: invocation.processHandshakeReportURL.path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: invocation.diagnosticsReportURL.path))
    }

    @Test func successfulRawDumpRejectsMissingOrUnreadableDiagnosticsReport() async throws {
        enum FixtureKind: CaseIterable, Sendable {
            case missing
            case malformed
            case directory
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        for kind in FixtureKind.allCases {
            let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
                try .init(
                    helperURLs: .init(
                        host: root.appendingPathComponent("helper"),
                        simulator: root
                    ),
                    executionMode: .host,
                    inputPath: "/System/Library/Frameworks/AppKit.framework",
                    stagingOutputDirectory: stage
                )
            )
            let runner = RecordingCommandRunner()
            await runner.setStreamingHandler { command, _, _ in
                try writeRawDumpProcessHandshake(for: command)
                switch kind {
                case .missing:
                    break
                case .malformed:
                    try Data("not-json".utf8).write(to: invocation.diagnosticsReportURL)
                case .directory:
                    try FileManager.default.createDirectory(
                        at: invocation.diagnosticsReportURL,
                        withIntermediateDirectories: false
                    )
                }
                return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
            }

            switch kind {
            case .missing:
                await #expect(
                    throws: PrivateHeaderGeneration.RawDumping.ContractError
                        .missingDiagnosticsReport(invocation.diagnosticsReportURL.path)
                ) {
                    _ = try await runPrivateHeaderKitRawDump(
                        invocation,
                        processRunner: runner
                    )
                }
            case .directory, .malformed:
                await #expect(throws: PrivateHeaderGeneration.RawDumping.ContractError.self) {
                    _ = try await runPrivateHeaderKitRawDump(
                        invocation,
                        processRunner: runner
                    )
                }
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: invocation.processHandshakeReportURL.path
                )
            )
            #expect(!FileManager.default.fileExists(atPath: invocation.diagnosticsReportURL.path))
        }
    }

    @Test func signalCoordinatorWaitsForOperationCleanupBeforeReturningSignalStatus() async {
        let cases: [(PrivateHeaderKitTerminationSignal, Int32)] = [
            (.interrupt, 130),
            (.terminate, 143),
        ]
        for (signal, expectedStatus) in cases {
            let source = ControlledSignalSource()
            let operationStarted = EventCounter()
            let cancellationObserved = EventCounter()
            let cleanupGate = EventCounter()
            let completion = ThreadSafeBool()
            let task = Task {
                let status = await coordinatePrivateHeaderKitOperation(
                    signalSource: source,
                    operation: {
                        operationStarted.signal()
                        return await withTaskCancellationHandler {
                            await cleanupGate.wait(until: 1)
                            return 0
                        } onCancel: {
                            cancellationObserved.signal()
                        }
                    }
                )
                completion.setTrue()
                return status
            }

            await operationStarted.wait(until: 1)
            source.send(signal)
            await cancellationObserved.wait(until: 1)
            #expect(!completion.value)
            cleanupGate.signal()
            #expect(await task.value == expectedStatus)
            #expect(completion.value)
        }
    }

    @Test func signalCoordinatorCancelsItsSignalWaiterAfterNormalCompletion() async {
        let source = ControlledSignalSource()
        let status = await coordinatePrivateHeaderKitOperation(
            signalSource: source,
            operation: { 7 }
        )
        #expect(status == 7)
        #expect(source.isFinished)
    }

    @Test func signalCoordinatorPrefersEarlyBufferedSignalOverFastOperation() async {
        let source = ControlledSignalSource()
        source.send(.interrupt)

        let status = await coordinatePrivateHeaderKitOperation(
            signalSource: source,
            operation: { 0 }
        )

        #expect(status == 130)
    }

    @Test func interactiveSourceScreenGroupsSourcesByPlatform() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var runtimes: [String] = []
        for (platform, version, build, isSeed) in [
            ("iOS", "16.4.1", "20E772520a", false),
            ("iOS", "27.0", "24A5390f", true),
            ("watchOS", "27.0", "24R5325f", true),
        ] {
            let runtimeRoot = root.appendingPathComponent("\(platform) \(version)")
            try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
            if isSeed {
                try writeReleaseMetadata(isSeed: true, in: runtimeRoot, layout: .simulator)
            }
            runtimes.append(
                """
                {"platform":"\(platform)","version":"\(version)","buildversion":"\(build)","identifier":"\(platform)-\(version)","runtimeRoot":"\(runtimeRoot.path)","isAvailable":true}
                """
            )
        }
        let listing = "{\"runtimes\":[\(runtimes.joined(separator: ","))]}"
        let runner = CaptureOnlyCommandRunner { command, _, _ in
            switch command {
            case ["xcrun", "simctl", "list", "runtimes", "-j"]: return listing
            case ["/usr/bin/sw_vers", "-productVersion"]: return "26.6.1\n"
            case ["/usr/bin/sw_vers", "-buildVersion"]: return "25G76\n"
            default: throw ToolingError.message("unexpected command: \(command)")
            }
        }
        let input = ScriptedInput(["\u{001B}"])
        let output = ThreadSafeStrings()

        let status = await CommandLineTool(
            executableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
            processRunner: runner,
            console: Console(output: output.append, error: output.append),
            readLine: { try await input.readLine() },
            clearScreen: {}
        ).run(["privateheaderkit"])

        #expect(status == 1)
        #expect(output.text == """
            PrivateHeaderKit
            Generate private headers from an installed runtime or this Mac.

            Step 1 of 3: Source

            iOS
              [1] 16.4.1 (20E772520a)
              [2] 27.0 beta (24A5390f)

            watchOS
              [3] 27.0 beta (24R5325f)

            macOS
              [4] 26.6.1\(try hostIsSeed() ? " beta" : "") (25G76)

            Press Escape to cancel.
            Select source:
            Cancelled.
            """)
    }

    @Test(arguments: ["correct", "back", "cancel", "automation"])
    func targetSelectionUsesOneOwnedSimulatorSession(_ action: String) async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        for name in ["FooOne", "FooTwo"] {
            try host.addFramework(name, to: host.runtimeRoot)
        }
        await host.stub(helper: { invocation in
            #expect(invocation.target == "System/Library/Frameworks/FooOne.framework")
            return try invocation.succeed()
        })
        let lastInputs: [String] = switch action {
        case "correct": ["/System/Library/Frameworks/FooOne.framework"]
        case "back": ["\u{001B}", "\u{001B}", "\u{001B}"]
        default: ["cancel"]
        }
        let input = ScriptedInput(["1", "2", "FooOne,", "all,FooOne", "Missing", "Foo"] + lastInputs)
        let output = ThreadSafeStrings()
        let arguments = action == "automation" ? [
            "privateheaderkit", "--platform", "iOS", "--version", "27.0",
            "--build", "24A123", "--out", host.output.path, "--target", "Foo,Missing",
        ] : ["privateheaderkit"]
        let status = await CommandLineTool(
            executableURL: host.executable,
            processRunner: host.runner,
            console: Console(output: output.append, error: output.append),
            readLine: {
                #expect(action != "automation")
                let line = try await input.readLine()
                if line == "Missing" { #expect(await host.createdDeviceCount() == 0) }
                if line == "cancel" { throw CancellationError() }
                return line
            },
            clearScreen: {},
            defaultOutputBaseDirectory: { host.output.path }
        ).run(arguments)
        let expectedStatus: Int32 = switch action {
        case "correct": 0
        case "back": 1
        case "automation": 2
        default: 130
        }
        #expect(status == expectedStatus)
        let discoveryCount = await host.runner.captureCommandSnapshot()
            .count { $0.command == ["/usr/bin/sw_vers", "-productVersion"] }
        #expect(discoveryCount == (action == "automation" ? 0 : 1))
        #expect(await host.createdDeviceCount() == 1)
        #expect(await host.deletedDeviceCount() == 1)
        #expect(await host.helperRunCount() == (action == "correct" ? 1 : 0))
        if action != "automation" {
            #expect(output.text.contains("target name must not be empty"))
            #expect(output.text.contains("all available targets cannot be combined"))
        }
        #expect(output.text.contains("no target matches \"Missing\""))
        #expect(output.text.contains("matches multiple candidates"))
        #expect(output.text.contains("/System/Library/Frameworks/FooTwo.framework"))
        if action == "correct" {
            let header = host.output.appendingPathComponent(
                "generated-headers/iOS/27.0_24A123/Frameworks/FooOne/Headers/Generated.h"
            )
            #expect(try String(contentsOf: header, encoding: .utf8) == "generated")
        }
    }

    @Test(arguments: ["all", "named"])
    func interactiveRunWithoutAnUnfinishedRunDoesNotPromptForContinuation(
        _ selection: String
    ) async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("Foo", to: host.runtimeRoot)
        await host.stub()
        let output = ThreadSafeStrings()

        let status = await host.run(
            [],
            input: selection == "all" ? ["1", "1"] : ["1", "2", "Foo"],
            output: output
        )

        #expect(status == 0)
        #expect(await host.helperRunCount() == 1)
        #expect(output.text.contains("Step 1 of 3"))
        #expect(output.text.contains("Generation completed"))
        #expect(!output.text.contains("Select action:"))
    }

    @Test(arguments: ["default", "custom", "alias", "automation"])
    func outputSelectionReachesPublishedFiles(_ mode: String) async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("Foo", to: host.runtimeRoot)
        await host.stub()
        let defaultOutput = host.root.appendingPathComponent("Default Output")
        let customOutput = host.root.appendingPathComponent("Custom Output")
        let expectedOutput = mode == "default" ? defaultOutput : customOutput
        let arguments: [String] = switch mode {
        case "custom": ["privateheaderkit", "--out", customOutput.path]
        case "alias": ["privateheaderkit", "generate", "--out", customOutput.path]
        case "automation":
            ["privateheaderkit"] + GenerationHost.iOSArguments
                + ["--target", "Foo", "--out", customOutput.path]
        default: ["privateheaderkit"]
        }
        let input = ScriptedInput(["1", "2", "Foo"])
        let output = ThreadSafeStrings()
        let defaultOutputCalls = ThreadSafeCounter()
        let status = await CommandLineTool(
            executableURL: host.executable,
            processRunner: host.runner,
            console: Console(output: output.append, error: output.append),
            readLine: {
                #expect(mode != "automation")
                return try await input.readLine()
            },
            clearScreen: {},
            defaultOutputBaseDirectory: {
                defaultOutputCalls.increment()
                return defaultOutput.path
            }
        ).run(arguments)
        #expect(status == 0)
        #expect(defaultOutputCalls.value == (mode == "default" ? 1 : 0))
        #expect(await host.helperRunCount() == 1)
        let source = try PrivateHeaderGeneration.Source(
            platform: .iOS, version: "27.0", build: "24A123", metadataIsSeed: false
        )
        let layout = PrivateHeaderGeneration.Output(baseDirectory: expectedOutput)
        let artifacts = layout.artifactDirectory(for: source)
        #expect(try String(contentsOf: artifacts.appendingPathComponent("Frameworks/Foo/Headers/Generated.h"), encoding: .utf8) == "generated")
        #expect(FileManager.default.fileExists(atPath: layout.stateDirectory(for: source).appendingPathComponent("generation.sqlite").path))
        #expect(output.text.contains(artifacts.path))
        #expect(!FileManager.default.fileExists(atPath: (mode == "default" ? customOutput : defaultOutput).path))
    }

    @Test func interactiveResumeContinuesTheUnfinishedRunAndDisplaysResolvedSource() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        for name in ["Bar", "Foo"] {
            try host.addFramework(name, to: host.runtimeRoot)
        }
        await host.stub(helper: { invocation in
            invocation.target.hasSuffix("Bar.framework")
                ? try invocation.fail("fixture failure")
                : try invocation.succeed()
        })
        let unfinishedStatus = await host.run(
            GenerationHost.iOSArguments + ["--out", host.output.path, "--target", "all"],
            output: ThreadSafeStrings()
        )
        #expect(unfinishedStatus == 2)
        await host.stub()
        let output = ThreadSafeStrings()

        let status = await host.run([], input: ["1", "1", "1"], output: output)

        #expect(status == 0)
        #expect(output.text.contains("Step 3 of 3: Continue or restart"))
        #expect(output.text.contains("Source: iOS 27.0 (24A123)"))
        #expect(output.text.contains("Remaining: 1 of 2"))
        #expect(output.text.contains("Previous run: run-"))
        #expect(output.text.contains("Skipped    1"))
        #expect(await host.createdDeviceCount() == 2)
        #expect(await host.inventoryCount() == 2)
        #expect(await host.helperRunCount() == 3)
    }

    @Test func interactiveSimulatorCleanupFailureReturnsOperationalFailure() async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("Foo", to: host.runtimeRoot)
        await host.stub(deleteDevice: { throw CLIFixtureError.cleanupFailed })
        let output = ThreadSafeStrings()

        let status = await host.run([], input: ["1", "1"], output: output)

        #expect(status == 2)
        #expect(output.text.contains("Generation completed"))
        #expect(output.text.contains("simulator cleanup failed for"))
        #expect(output.text.contains(GenerationHost.createdDeviceNamePrefix))
        #expect(output.text.contains("UDID: \(GenerationHost.createdDeviceUDID)"))
        #expect(!output.text.contains("Temporary device deleted"))
        #expect(!output.text.contains("Finished"))
    }

    @Test(arguments: ["restart", "back"])
    func interactiveIncompatibleResumeOffersRestartOrBack(_ choice: String) async throws {
        let host = try GenerationHost()
        defer { host.cleanup() }
        for name in ["Bar", "Foo"] {
            try host.addFramework(name, to: host.runtimeRoot)
        }
        // The wizard never requests runtime metadata, so it cannot continue this run.
        await host.stub(helper: { try $0.fail("fixture failure") })
        let unfinishedStatus = await host.run(
            GenerationHost.iOSArguments + [
                "--out", host.output.path, "--target", "all", "--runtime-metadata",
            ],
            output: ThreadSafeStrings()
        )
        #expect(unfinishedStatus == 2)
        await host.stub()
        let output = ThreadSafeStrings()

        let status = await host.run(
            [],
            input: choice == "restart" ? ["1", "1", "1"] : ["1", "1", "2", "\u{001B}", "\u{001B}"],
            output: output
        )

        #expect(output.text.contains("Restart required"))
        #expect(output.text.contains("plan fingerprint changed"))
        #expect(output.text.contains("[2] Back"))
        #expect(await host.createdDeviceCount() == 2)
        #expect(await host.deletedDeviceCount() == 2)
        #expect(await host.inventoryCount() == 2)
        if choice == "restart" {
            #expect(status == 0)
            #expect(output.text.contains("Generated  2"))
            #expect(await host.helperRunCount() == 4)
        } else {
            #expect(status == 1)
            #expect(await host.helperRunCount() == 2)
        }
    }

}

/// A machine the CLI can generate from: installed helpers, a macOS system root, one iOS
/// Simulator runtime, and a process runner that answers `simctl`, `sw_vers`, and the helpers.
private struct GenerationHost: Sendable {
    static let createdDeviceUDID = "11111111-2222-3333-4444-555555555555"
    static let createdDeviceNamePrefix = "PrivateHeaderKit Dump (iOS 27.0)"
    static let bootedDeviceName = "iPhone 17 Pro"
    static let bootedDeviceUDID = "SIM-001"
    static let runtimeIdentifier = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    static let iOSArguments = ["--platform", "iOS", "--version", "27.0"]

    let root: URL
    let runner = RecordingCommandRunner()

    var executable: URL { root.appendingPathComponent("Cohort/privateheaderkit") }
    var hostHelper: URL { root.appendingPathComponent("Cohort/privateheaderkit-raw-helper") }
    var simulatorHelper: URL { root.appendingPathComponent("Cohort/privateheaderkit-sim-helper") }
    var systemRoot: URL { root.appendingPathComponent("SystemRoot", isDirectory: true) }
    var runtimeRoot: URL { root.appendingPathComponent("RuntimeRoot", isDirectory: true) }
    var output: URL { root.appendingPathComponent("Output", isDirectory: true) }
    var macOSArguments: [String] {
        ["--platform", "macOS", "--version", "16.0", "--system-root", systemRoot.path]
    }

    init() throws {
        root = try temporaryDirectory()
        let cohort = executable.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cohort, withIntermediateDirectories: true)
        for name in ["privateheaderkit-sim-helper", "privateheaderkit-watch-sim-helper"] {
            try writeCLIExecutable("", to: cohort.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try writeReleaseMetadata(isSeed: false, in: systemRoot, layout: .macOS)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func addFramework(_ name: String, to systemRoot: URL) throws {
        let bundle = systemRoot.appendingPathComponent("System/Library/Frameworks/\(name).framework")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent(name))
    }

    /// Installs the runner's answers. Without `--device` the CLI creates a Simulator device,
    /// which gets `createdDeviceUDID`; `deleteDevice` runs when the CLI deletes it. `helper`
    /// stands in for every raw-dump helper process.
    func stub(
        deleteDevice: @escaping @Sendable () async throws -> Void = {},
        helper: @escaping @Sendable (HelperInvocation) async throws -> StreamingCommandResult = {
            try $0.succeed()
        }
    ) async {
        let runtimeRoot = runtimeRoot
        let inventoryCommand = [
            "xcrun", "simctl", "spawn", Self.createdDeviceUDID,
            simulatorHelper.path, "__shared-cache-inventory",
        ]
        await runner.setCaptureHandler { command, _, _ in
            switch command {
            case ["xcrun", "simctl", "list", "runtimes", "-j"]:
                return """
                    {"runtimes":[{"name":"iOS 27.0","platform":"iOS","version":"27.0","buildversion":"24A123","identifier":"\(Self.runtimeIdentifier)","runtimeRoot":"\(runtimeRoot.path)","isAvailable":true,"supportedDeviceTypes":[{"name":"iPhone 17","identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17","productFamily":"iPhone"}]}]}
                    """
            case ["xcrun", "simctl", "list", "devices", "-j"],
                ["xcrun", "simctl", "list", "devices", "available", "-j"]:
                return """
                    {"devices":{"\(Self.runtimeIdentifier)":[{"name":"\(Self.bootedDeviceName)","udid":"\(Self.bootedDeviceUDID)","state":"Booted"},{"name":"\(Self.createdDeviceNamePrefix)","udid":"\(Self.createdDeviceUDID)","state":"Booted"}]}}
                    """
            case ["/usr/bin/sw_vers", "-productVersion"]:
                return "16.0\n"
            case ["/usr/bin/sw_vers", "-buildVersion"]:
                return "24A1\n"
            default:
                break
            }
            if command.starts(with: ["xcrun", "simctl", "create"]) {
                return Self.createdDeviceUDID + "\n"
            }
            if command == inventoryCommand {
                let frameworks = runtimeRoot.appendingPathComponent("System/Library/Frameworks")
                let names = try FileManager.default.contentsOfDirectory(atPath: frameworks.path)
                    .map { ($0 as NSString).deletingPathExtension }
                    .sorted()
                let inventory = PrivateHeaderKitSharedCacheInventory(
                    cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    imagePaths: names.map { "/System/Library/Frameworks/\($0).framework/\($0)" }
                )
                return String(decoding: try JSONEncoder().encode(inventory), as: UTF8.self)
            }
            throw ToolingError.message("unexpected runCapture command: \(command)")
        }
        await runner.setSimpleHandler { command, _, _ in
            if command == ["xcrun", "simctl", "delete", Self.createdDeviceUDID] {
                try await deleteDevice()
            }
        }
        await runner.setStreamingHandler { command, _, _ in
            try await helper(HelperInvocation(command: command))
        }
    }

    /// Runs the CLI as installed on this host. `input` answers the wizard's prompts.
    func run(
        _ arguments: [String],
        input: [String] = [],
        output: ThreadSafeStrings,
        errors: ThreadSafeStrings? = nil
    ) async -> Int32 {
        let input = ScriptedInput(input)
        let outputPath = self.output.path
        return await CommandLineTool(
            executableURL: executable,
            processRunner: runner,
            console: Console(output: output.append, error: (errors ?? output).append),
            readLine: { try await input.readLine() },
            clearScreen: {},
            defaultOutputBaseDirectory: { outputPath }
        ).run(["privateheaderkit"] + arguments)
    }

    func createdDeviceCount() async -> Int {
        await runner.captureCommandSnapshot()
            .count { $0.command.starts(with: ["xcrun", "simctl", "create"]) }
    }

    func deletedDeviceCount() async -> Int {
        await runner.simpleCommandSnapshot()
            .count { $0.command == ["xcrun", "simctl", "delete", Self.createdDeviceUDID] }
    }

    /// How many times the CLI read a Simulator's shared-cache inventory, which it does once
    /// for each generation it prepares.
    func inventoryCount() async -> Int {
        await runner.captureCommandSnapshot()
            .count { $0.command.last == "__shared-cache-inventory" }
    }

    func helperRunCount() async -> Int {
        await runner.streamingCommandSnapshot().count
    }
}

/// One raw-dump helper process the CLI started.
private struct HelperInvocation: Sendable {
    let command: [String]

    /// The dumped bundle relative to its system root, such as
    /// `System/Library/Frameworks/Foo.framework`.
    var target: String {
        let path = command.last ?? ""
        guard let range = path.range(of: "System/Library/") else { return path }
        return String(path[range.lowerBound...])
    }

    /// Writes the reports and one header, as a helper that dumped the target does.
    func succeed(
        diagnostics: [PrivateHeaderKitRawDumpDiagnostic] = []
    ) throws -> StreamingCommandResult {
        try writeRawDumpProcessHandshake(for: command)
        let headers = URL(fileURLWithPath: try value(after: "-o"))
            .appendingPathComponent(target)
            .appendingPathComponent("Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        try Data("generated".utf8).write(to: headers.appendingPathComponent("Generated.h"))
        try JSONEncoder().encode(PrivateHeaderKitRawDumpDiagnosticsReport(diagnostics: diagnostics))
            .write(to: URL(fileURLWithPath: try value(after: "--diagnostics-report")), options: .atomic)
        return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
    }

    func fail(_ message: String) throws -> StreamingCommandResult {
        try writeRawDumpProcessHandshake(for: command)
        return StreamingCommandResult(status: 1, wasKilled: false, lastLines: [message])
    }

    private func value(after option: String) throws -> String {
        guard let index = command.firstIndex(of: option), index + 1 < command.count else {
            throw ToolingError.message("raw dump command is missing \(option)")
        }
        return command[index + 1]
    }
}

/// Writes the `RestoreVersion.plist` that marks `systemRoot` as a seed or a release.
private func writeReleaseMetadata(
    isSeed: Bool,
    in systemRoot: URL,
    layout: RuntimeRootLayout
) throws {
    let directory: URL
    switch layout {
    case .simulator: directory = systemRoot
    case .macOS: directory = systemRoot.appendingPathComponent("System/Library/CoreServices")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
        fromPropertyList: ["IsSeed": isSeed],
        format: .binary,
        options: 0
    ).write(to: directory.appendingPathComponent("RestoreVersion.plist"))
}

/// Whether the Mac running the tests is a seed build, which source discovery reports for
/// the macOS source.
private func hostIsSeed() throws -> Bool {
    try RuntimeReleaseMetadata.isSeed(in: URL(fileURLWithPath: "/", isDirectory: true), layout: .macOS)
}

private let testPrivateHeaderKitHelperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
    host: URL(fileURLWithPath: "/cohort/privateheaderkit-raw-helper"),
    simulator: URL(fileURLWithPath: "/cohort/privateheaderkit-sim-helper")
)

private let testPrivateHeaderKitSimulatorResolution = SimulatorResolution(
    runtimeVersion: "27.0",
    runtimeBuild: "24A123",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    resolvedRuntimeRoot: "/ResolvedRuntime",
    metadataIsSeed: false,
    deviceName: "iPhone 17 Pro",
    deviceUDID: "SIM-001"
)

private let testPrivateHeaderKitWatchSimulatorResolution = SimulatorResolution(
    runtimeVersion: "27.0",
    runtimeBuild: "24R5325f",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-27-0",
    resolvedRuntimeRoot: "/ResolvedWatchRuntime",
    metadataIsSeed: true,
    deviceName: "Apple Watch Series 11 (46mm)",
    deviceUDID: "WATCH-001"
)

private func testExecutionMode(
    resolution: SimulatorResolution,
    sourceRuntimeRoot: String
) -> PrivateHeaderGeneration.RawDumping.ExecutionMode {
    .simulator(
        deviceUDID: resolution.deviceUDID,
        sourceRuntimeRoot: sourceRuntimeRoot,
        runtime: .init(
            version: resolution.runtimeVersion,
            build: resolution.runtimeBuild,
            identifier: resolution.runtimeIdentifier,
            runtimeRoot: URL(
                fileURLWithPath: resolution.resolvedRuntimeRoot,
                isDirectory: true
            ).resolvingSymlinksInPath().standardizedFileURL.path
        )
    )
}

private func iosGenerateCommand(
    build: String?,
    systemRoot: String?,
    device: String? = nil
) -> GenerateCommand.Options {
    GenerateCommand.Options(
        platform: .iOS,
        version: "27.0",
        build: build,
        systemRoot: systemRoot,
        outputBaseDirectory: "/tmp/PrivateHeaderKit",
        targetQuery: "all",
        continuationMode: .fresh,
        device: device,
        simulatorHelperPath: nil
    )
}

private func watchOSGenerateCommand(
    build: String?,
    systemRoot: String?
) -> GenerateCommand.Options {
    GenerateCommand.Options(
        platform: .watchOS,
        version: "27.0",
        build: build,
        systemRoot: systemRoot,
        outputBaseDirectory: "/tmp/PrivateHeaderKit",
        targetQuery: "all",
        continuationMode: .fresh,
        device: nil,
        simulatorHelperPath: nil
    )
}

private func macOSGenerateCommand(
    build: String? = nil,
    systemRoot: String
) -> GenerateCommand.Options {
    GenerateCommand.Options(
        platform: .macOS,
        version: "16.0",
        build: build,
        systemRoot: systemRoot,
        outputBaseDirectory: "/tmp/PrivateHeaderKit",
        targetQuery: "all",
        continuationMode: .fresh,
        device: nil,
        simulatorHelperPath: nil
    )
}

@Suite
struct PrivateHeaderKitHelperLookupTests {
    @Test(arguments: [nil, SimulatorPlatform.iOS, .watchOS])
    func installedHelpersAreUsedBesideTheExecutable(_ platform: SimulatorPlatform?) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let simulatorHelperName =
            platform == .watchOS ? "privateheaderkit-watch-sim-helper" : "privateheaderkit-sim-helper"
        let runner = RecordingCommandRunner()
        if platform != nil {
            await #expect(throws: ToolingError.self) {
                _ = try await HelperPlan.resolve(
                    executableURL: directory.appendingPathComponent("privateheaderkit"),
                    simulatorHelperPath: nil,
                    simulatorPlatform: platform,
                    processRunner: runner
                )
            }
            try writeCLIExecutable(
                "simulator", to: directory.appendingPathComponent(simulatorHelperName)
            )
        }

        let plan = try await HelperPlan.resolve(
            executableURL: directory.appendingPathComponent("privateheaderkit"),
            simulatorHelperPath: nil,
            simulatorPlatform: platform,
            processRunner: runner
        )
        try await plan.buildHelpers(using: runner)

        #expect(
            plan.helperURLs.host == directory.appendingPathComponent("privateheaderkit-raw-helper")
        )
        #expect(plan.helperURLs.simulator == directory.appendingPathComponent(simulatorHelperName))
        #expect(await runner.captureCommandSnapshot().isEmpty)
    }

    @Test func installedPublicSymlinkResolvesHelpersFromActiveCohort() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cohort = root.appendingPathComponent(
            "libexec/privateheaderkit/versions/cohort-a",
            isDirectory: true
        )
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: cohort, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["privateheaderkit", "privateheaderkit-watch-sim-helper"] {
            try writeCLIExecutable(name, to: cohort.appendingPathComponent(name))
        }
        let current = root.appendingPathComponent("libexec/privateheaderkit/current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: cohort)
        let publicExecutable = bin.appendingPathComponent("privateheaderkit")
        try FileManager.default.createSymbolicLink(
            at: publicExecutable,
            withDestinationURL: current.appendingPathComponent("privateheaderkit")
        )

        let plan = try await HelperPlan.resolve(
            executableURL: publicExecutable,
            simulatorHelperPath: nil,
            simulatorPlatform: .watchOS,
            processRunner: RecordingCommandRunner()
        )

        #expect(
            plan.helperURLs.host.standardizedFileURL
                == cohort.appendingPathComponent("privateheaderkit-raw-helper").standardizedFileURL
        )
        #expect(
            plan.helperURLs.simulator.standardizedFileURL
                == cohort.appendingPathComponent("privateheaderkit-watch-sim-helper")
                    .standardizedFileURL
        )
    }

    @Test func SwiftPMHelpersUseReportedBinPathsAndDedicatedSimulatorScratch() async throws {
        let runner = RecordingCommandRunner()
        let sdkPath = "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        let simulatorTriple = "arm64-apple-ios-simulator"
        let simulatorCommand = [
            "swift", "build", "--force-resolved-versions", "-c", "debug",
            "--scratch-path", "/repo/.build/privateheaderkit-simulator/\(simulatorTriple)",
            "--sdk", sdkPath,
            "--triple", simulatorTriple,
        ]
        let rawBuild = swiftPMHostCommand(configuration: "debug")
            + ["--product", "privateheaderkit-raw-helper"]
        let simulatorBuild = simulatorCommand + ["--product", "privateheaderkit-sim-helper"]
        await runner.setCaptureOutput(
            "build log\n/repo/.build/out/Products/Debug\n",
            for: swiftPMHostCommand(configuration: "debug") + ["--show-bin-path"]
        )
        await runner.setCaptureOutput(
            "\n\(sdkPath)\n",
            for: ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]
        )
        await runner.setCaptureOutput(
            "\n/repo/.build/privateheaderkit-simulator/bin\n",
            for: simulatorCommand + ["--show-bin-path"]
        )
        await runner.setCaptureOutput("", for: rawBuild)
        await runner.setCaptureOutput("", for: simulatorBuild)

        let plan = try await HelperPlan.resolve(
            executableURL: URL(
                fileURLWithPath: "/repo/.build/out/Products/Debug/privateheaderkit"
            ),
            simulatorHelperPath: nil,
            simulatorPlatform: .iOS,
            processRunner: runner,
            simulatorArchitecture: "arm64"
        )

        #expect(
            plan.helperURLs.host.path == "/repo/.build/out/Products/Debug/privateheaderkit-raw-helper"
        )
        #expect(
            plan.helperURLs.simulator.path
                == "/repo/.build/privateheaderkit-simulator/bin/privateheaderkit-sim-helper"
        )
        #expect(!(await runner.captureCommandSnapshot()).contains {
            $0.command.contains("--product")
        })

        try await plan.buildHelpers(using: runner)

        #expect(
            await runner.captureCommandSnapshot().map(\.command).filter { $0.contains("--product") }
                == [rawBuild, simulatorBuild]
        )
    }

    @Test func SwiftPMWatchHelperUsesWatchSDKTripleAndGenericProduct() async throws {
        let runner = RecordingCommandRunner()
        let sdkPath = "/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk"
        let simulatorTriple = "arm64-apple-watchos-simulator"
        let simulatorCommand = [
            "swift", "build", "--force-resolved-versions", "-c", "debug",
            "--scratch-path", "/repo/.build/privateheaderkit-simulator/\(simulatorTriple)",
            "--sdk", sdkPath,
            "--triple", simulatorTriple,
        ]
        let simulatorBuild = simulatorCommand + ["--product", "privateheaderkit-sim-helper"]
        await runner.setCaptureOutput(
            "/repo/.build/out/Products/Debug\n",
            for: swiftPMHostCommand(configuration: "debug") + ["--show-bin-path"]
        )
        await runner.setCaptureOutput(
            "\(sdkPath)\n",
            for: ["xcrun", "--sdk", "watchsimulator", "--show-sdk-path"]
        )
        await runner.setCaptureOutput(
            "/repo/.build/privateheaderkit-simulator/watch-bin\n",
            for: simulatorCommand + ["--show-bin-path"]
        )
        await runner.setCaptureOutput(
            "",
            for: swiftPMHostCommand(configuration: "debug")
                + ["--product", "privateheaderkit-raw-helper"]
        )
        await runner.setCaptureOutput("", for: simulatorBuild)

        let plan = try await HelperPlan.resolve(
            executableURL: URL(
                fileURLWithPath: "/repo/.build/out/Products/Debug/privateheaderkit"
            ),
            simulatorHelperPath: nil,
            simulatorPlatform: .watchOS,
            processRunner: runner,
            simulatorArchitecture: "arm64"
        )
        try await plan.buildHelpers(using: runner)

        #expect(
            plan.helperURLs.simulator.path
                == "/repo/.build/privateheaderkit-simulator/watch-bin/privateheaderkit-sim-helper"
        )
        #expect((await runner.captureCommandSnapshot()).contains { $0.command == simulatorBuild })
    }

    @Test(arguments: [SimulatorPlatform.iOS, nil])
    func SwiftPMPlanBuildsOnlyTheHostHelperWithoutASimulatorBuild(
        _ platform: SimulatorPlatform?
    ) async throws {
        // With a platform, the simulator helper is given explicitly. Without one, none is used.
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let explicitHelper = root.appendingPathComponent("custom-sim-helper")
        try writeCLIExecutable("custom", to: explicitHelper)
        let explicitPath = platform == nil ? nil : explicitHelper.path
        let runner = RecordingCommandRunner()
        let rawBuild = swiftPMHostCommand(configuration: "release")
            + ["--product", "privateheaderkit-raw-helper"]
        await runner.setCaptureOutput(
            "/repo/.build/release\n",
            for: swiftPMHostCommand(configuration: "release") + ["--show-bin-path"]
        )
        await runner.setCaptureOutput("", for: rawBuild)

        let plan = try await HelperPlan.resolve(
            executableURL: URL(fileURLWithPath: "/repo/.build/release/privateheaderkit"),
            simulatorHelperPath: explicitPath,
            simulatorPlatform: platform,
            processRunner: runner
        )
        try await plan.buildHelpers(using: runner)

        #expect(plan.helperURLs.host.path == "/repo/.build/release/privateheaderkit-raw-helper")
        if let explicitPath {
            #expect(plan.helperURLs.simulator.path == explicitPath)
            await #expect(throws: ToolingError.self) {
                _ = try await HelperPlan.resolve(
                    executableURL: URL(
                        fileURLWithPath: "/repo/.build/release/privateheaderkit"
                    ),
                    simulatorHelperPath: root.appendingPathComponent("missing").path,
                    simulatorPlatform: platform,
                    processRunner: runner
                )
            }
        }
        #expect(
            await runner.captureCommandSnapshot().map(\.command) == [
                swiftPMHostCommand(configuration: "release") + ["--show-bin-path"],
                rawBuild,
            ]
        )
    }

    @Test func emptySwiftPMBinPathFailsWithoutLayoutFallback() async {
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            " \n\t\n",
            for: swiftPMHostCommand(configuration: "debug") + ["--show-bin-path"]
        )

        await #expect(throws: ToolingError.self) {
            _ = try await HelperPlan.resolve(
                executableURL: URL(
                    fileURLWithPath: "/repo/.build/out/Products/Debug/privateheaderkit"
                ),
                simulatorHelperPath: nil,
                simulatorPlatform: nil,
                processRunner: runner
            )
        }
    }
}

private func swiftPMHostCommand(configuration: String) -> [String] {
    ["swift", "build", "--force-resolved-versions", "-c", configuration]
}

private func writeCLIExecutable(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: UInt16(0o755))],
        ofItemAtPath: url.path
    )
}

private func writeRawDumpProcessHandshake(
    for command: [String],
    processIdentifier: Int32 = 4_242,
    helperStartedAtUnixMicroseconds: Int64 = 1_700_000_000_123_456,
    executableName: String = "privateheaderkit-raw-helper",
    executableMachOUUID: UUID = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
) throws {
    guard let identifierIndex = command.firstIndex(of: "--process-handshake-id"),
          identifierIndex + 1 < command.count,
          let invocationID = UUID(uuidString: command[identifierIndex + 1]),
          let reportIndex = command.firstIndex(of: "--process-handshake-report"),
          reportIndex + 1 < command.count
    else {
        throw ToolingError.message("raw dump command is missing its process handshake")
    }
    let handshake = PrivateHeaderKitRawDumpProcessHandshake(
        invocationID: invocationID,
        processIdentifier: processIdentifier,
        helperStartedAtUnixMicroseconds: helperStartedAtUnixMicroseconds,
        executableName: executableName,
        executableMachOUUID: executableMachOUUID
    )
    try handshake.encoded().write(
        to: URL(fileURLWithPath: command[reportIndex + 1]),
        options: .atomic
    )
}

private struct BufferedRawDumpProbeRunner: CommandRunning {
    func runCapture(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> String {
        throw ToolingError.message("unexpected runCapture command: \(command)")
    }

    func runCaptureChunks(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws {
        throw ToolingError.message("unexpected runCaptureChunks command: \(command)")
    }

    func runSimple(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws {
        throw ToolingError.message("unexpected runSimple command: \(command)")
    }

    func runBuffered(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> StreamingCommandResult {
        try writeRawDumpProcessHandshake(for: command)
        if let reportIndex = command.firstIndex(of: "--diagnostics-report") {
            try Data("not-json".utf8).write(
                to: URL(fileURLWithPath: command[reportIndex + 1]),
                options: .atomic
            )
        }
        return StreamingCommandResult(
            status: 19,
            wasKilled: false,
            lastLines: ["helper-warning", "fatal-tail"]
        )
    }
}

@Suite
struct PrivateHeaderKitAsyncInputTests {
    @Test func systemRawModeRoutesControlCThroughTheInputLifecycle() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PrivateHeaderKitInputError.terminalReadFailed(code: errno)
        }
        defer {
            _ = close(master)
            _ = close(slave)
        }
        var original = termios()
        #expect(tcgetattr(slave, &original) == 0)
        let restore = try PrivateHeaderKitSystemTerminalModeController()
            .enterRawMode(fileDescriptor: slave)
        var raw = termios()
        #expect(tcgetattr(slave, &raw) == 0)
        #expect(raw.c_lflag & tcflag_t(ISIG) == 0)
        #expect(raw.c_lflag & tcflag_t(ICANON) == 0)
        #expect(raw.c_lflag & tcflag_t(ECHO) == 0)
        try restore()
        var restored = termios()
        #expect(tcgetattr(slave, &restored) == 0)
        let managedFlags = tcflag_t(ISIG | ICANON | ECHO)
        #expect(restored.c_lflag & managedFlags == original.c_lflag & managedFlags)
    }

    @Test func rawModeTransitionDiscardsPrePromptPartialInput() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PrivateHeaderKitInputError.terminalReadFailed(code: errno)
        }
        defer {
            _ = close(master)
            _ = close(slave)
        }
        try writeAll("preflight", to: master)
        #expect(tcflush(slave, TCOFLUSH) == 0)
        let restore = try PrivateHeaderKitSystemTerminalModeController()
            .enterRawMode(fileDescriptor: slave)
        var descriptor = pollfd(fd: slave, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 0) == 0)
        try restore()
    }

    @Test func onePersistentSourceReadsMultiplePipedLinesAndEOF() async throws {
        let descriptors = try makePipe()
        let originalStatusFlags = fcntl(descriptors.read, F_GETFL)
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in false }
        )
        #expect(fcntl(descriptors.read, F_GETFL) & O_NONBLOCK != 0)
        try writeAll("first\nsecond\n", to: descriptors.write)
        _ = close(descriptors.write)

        #expect(try await input.readLine() == "first")
        #expect(try await input.readLine() == "second")
        #expect(try await input.readLine() == nil)
        try input.cancel()
        #expect(fcntl(descriptors.read, F_GETFL) == originalStatusFlags)
        _ = close(descriptors.read)
    }

    @Test func controlDTerminatesAfterDeliveringBufferedInput() async throws {
        let descriptors = try makePipe()
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in false }
        )
        _ = close(descriptors.read)
        try writeBytes(Array("partial".utf8) + [4] + Array("ignored".utf8), to: descriptors.write)
        _ = close(descriptors.write)

        #expect(try await input.readLine() == "partial")
        #expect(try await input.readLine() == nil)
        try input.finish()
    }

    @Test func controlCOverridesEveryBufferedLineInTheSameChunk() async throws {
        let descriptors = try makePipe()
        let host = try GenerationHost()
        defer { host.cleanup() }
        try host.addFramework("Foo", to: host.runtimeRoot)
        await host.stub()
        let probe = TerminalProbe()
        let promptInput = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: ProbeTerminalController(probe: probe),
            echoWriter: { _ in }
        )
        let commandTask = Task {
            // A command that ends before it prompts fails the test instead of leaving it
            // waiting.
            defer { probe.stopWaiting() }
            return await CommandLineTool(
                executableURL: host.executable,
                processRunner: host.runner,
                console: Console(output: { _ in }, error: { _ in }),
                readLine: { try await promptInput.readLine() },
                clearScreen: {},
                defaultOutputBaseDirectory: { host.output.path }
            ).run(["privateheaderkit"])
        }
        await probe.waitForEnter(1)
        try writeBytes(Array("1\n1\n".utf8) + [3], to: descriptors.write)
        let status = await commandTask.value
        #expect(status == 130)
        #expect(await host.createdDeviceCount() == 0)
        #expect(await host.helperRunCount() == 0)
        try promptInput.finish()
        _ = close(descriptors.read)
        _ = close(descriptors.write)
    }

    @Test func cancellationRestoresTerminalExactlyOnce() async throws {
        let descriptors = try makePipe()
        let probe = TerminalProbe()
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: ProbeTerminalController(probe: probe)
        )
        _ = close(descriptors.read)
        let task = Task { try await input.readLine() }
        await probe.waitForEnter(1)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(probe.restoreCount == 1)
        _ = close(descriptors.write)
    }

    @Test func rawModeAndManualEchoAreScopedToEachPromptRead() async throws {
        let descriptors = try makePipe()
        let probe = TerminalProbe()
        let echo = ThreadSafeData()
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: ProbeTerminalController(probe: probe),
            echoWriter: echo.append
        )

        let firstRead = Task { try await input.readLine() }
        await probe.waitForEnter(1)
        try writeAll("1\n", to: descriptors.write)
        #expect(try await firstRead.value == "1")
        #expect(probe.enterCount == 1)
        #expect(probe.restoreCount == 1)
        #expect(echo.text == "1\n")

        try input.finish()
        _ = close(descriptors.read)
        _ = close(descriptors.write)
    }

    @Test func oneRawReadSnapshotAppliesToEveryLineInItsChunk() async throws {
        let descriptors = try makePipe()
        let probe = TerminalProbe()
        let echo = ThreadSafeData()
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: ProbeTerminalController(probe: probe),
            echoWriter: echo.append
        )
        _ = close(descriptors.read)

        let firstRead = Task { try await input.readLine() }
        await probe.waitForEnter(1)
        try writeAll("1\n2\n", to: descriptors.write)
        #expect(try await firstRead.value == "1")
        await echo.wait(until: "1\n2\n")
        #expect(echo.text == "1\n2\n")

        let secondRead = Task { try await input.readLine() }
        await probe.waitForEnter(2)
        try writeAll("3\n", to: descriptors.write)
        #expect(try await secondRead.value == "3")
        #expect(echo.text == "1\n2\n3\n")
        try input.finish()
        _ = close(descriptors.write)
    }

    @Test func terminalPromptDiscardsInputCompletedBeforePromptStart() async throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PrivateHeaderKitInputError.terminalReadFailed(code: errno)
        }
        defer {
            _ = close(master)
            _ = close(slave)
        }
        let controller = SignalingSystemTerminalController()
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: slave,
            terminalModeController: controller,
            echoWriter: { _ in }
        )
        try writeAll("stale\n", to: master)
        #expect(tcflush(slave, TCOFLUSH) == 0)

        let readTask = Task { try await input.readLine() }
        await controller.waitForEnter()
        try writeAll("fresh\n", to: master)
        #expect(try await readTask.value == "fresh")
        try input.finish()
    }

    @Test func canonicalChunkNeverUsesManualEcho() throws {
        let descriptors = try makePipe()
        defer {
            _ = close(descriptors.read)
            _ = close(descriptors.write)
        }
        let ownedRead = dup(descriptors.read)
        let originalStatusFlags = fcntl(ownedRead, F_GETFL)
        #expect(fcntl(ownedRead, F_SETFL, originalStatusFlags | O_NONBLOCK) == 0)
        let coordinator = PrivateHeaderKitInputCoordinator()
        let lifecycle = PrivateHeaderKitInputLifecycle(
            coordinator: coordinator,
            readFileDescriptor: ownedRead,
            originalStatusFlags: originalStatusFlags,
            usesTerminalMode: true,
            terminalModeController: ProbeTerminalController(probe: TerminalProbe())
        )
        let echo = ThreadSafeData()
        let buffer = PrivateHeaderKitInputBuffer(
            coordinator: coordinator,
            echoWriter: echo.append
        )
        buffer.consume(
            Array("preflight\n".utf8)[...],
            wasReadInRawMode: false,
            lifecycle: lifecycle
        )
        #expect(echo.text.isEmpty)
        try lifecycle.finishEOF()
    }

    @Test func escapeDiscardsTheRestOfItsInputChunk() async throws {
        let descriptors = try makePipe()
        defer {
            _ = close(descriptors.read)
            _ = close(descriptors.write)
        }
        let ownedRead = dup(descriptors.read)
        let originalStatusFlags = fcntl(ownedRead, F_GETFL)
        #expect(fcntl(ownedRead, F_SETFL, originalStatusFlags | O_NONBLOCK) == 0)
        let coordinator = PrivateHeaderKitInputCoordinator()
        let lifecycle = PrivateHeaderKitInputLifecycle(
            coordinator: coordinator,
            readFileDescriptor: ownedRead,
            originalStatusFlags: originalStatusFlags,
            usesTerminalMode: false,
            terminalModeController: ProbeTerminalController(probe: TerminalProbe())
        )
        let buffer = PrivateHeaderKitInputBuffer(
            coordinator: coordinator,
            echoWriter: { _ in }
        )

        buffer.consume(
            ([UInt8(27)] + Array("1\n".utf8))[...],
            wasReadInRawMode: false,
            lifecycle: lifecycle
        )
        #expect(try await coordinator.next() == "\u{001B}")
        buffer.consume(
            Array("2\n".utf8)[...],
            wasReadInRawMode: false,
            lifecycle: lifecycle
        )
        #expect(try await coordinator.next() == "2")
        try lifecycle.finishEOF()
    }

    @Test func EOFWaitsForInFlightTerminalRestorationBeforeClosingFD() async throws {
        let descriptors = try makePipe()
        defer {
            _ = close(descriptors.read)
            _ = close(descriptors.write)
        }
        let ownedRead = dup(descriptors.read)
        let originalStatusFlags = fcntl(ownedRead, F_GETFL)
        #expect(fcntl(ownedRead, F_SETFL, originalStatusFlags | O_NONBLOCK) == 0)
        let controller = BlockingTerminalController()
        let lifecycle = PrivateHeaderKitInputLifecycle(
            coordinator: PrivateHeaderKitInputCoordinator(),
            readFileDescriptor: ownedRead,
            originalStatusFlags: originalStatusFlags,
            usesTerminalMode: true,
            terminalModeController: controller
        )
        try lifecycle.beginReading()
        let restoreTask = Task.detached { try lifecycle.endReading() }
        await controller.waitForRestoreStart()
        let stopProbe = CompletionProbe()
        let stopTask = Task.detached {
            stopProbe.markStarted()
            try lifecycle.finishEOF()
            stopProbe.markCompleted()
        }
        await stopProbe.waitForStart()
        controller.allowRestore()

        try await restoreTask.value
        try await stopTask.value
        #expect(stopProbe.completed)
        #expect(controller.restoredWhileFileDescriptorWasOpen)
    }

    @Test func EOFRestoresTerminalAndRestoreFailureIsSurfaced() async throws {
        let descriptors = try makePipe()
        let probe = TerminalProbe(restoreError: .terminalRestoreFailed(code: EIO))
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: ProbeTerminalController(probe: probe)
        )
        _ = close(descriptors.read)
        let readTask = Task { try await input.readLine() }
        await probe.waitForEnter(1)
        _ = close(descriptors.write)
        do {
            _ = try await readTask.value
            Issue.record("expected restore failure")
        } catch let error as PrivateHeaderKitInputError {
            #expect(error == .terminalRestoreFailed(code: EIO))
        }
        #expect(probe.restoreCount == 1)
        do {
            try input.cancel()
            Issue.record("expected retained restore failure")
        } catch let error as PrivateHeaderKitInputError {
            #expect(error == .terminalRestoreFailed(code: EIO))
        }
    }

    @Test func rawModeSetupFailureIsNotSilentlyTreatedAsEOF() async throws {
        let descriptors = try makePipe()
        defer {
            _ = close(descriptors.read)
            _ = close(descriptors.write)
        }
        let input = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: FailingTerminalController()
        )
        do {
            _ = try await input.readLine()
            Issue.record("expected setup failure")
        } catch let error as PrivateHeaderKitInputError {
            #expect(error == .terminalRawModeFailed(code: EIO))
        }
    }
}

private enum DiscoveryProbeError: Error, Equatable {
    case commandFailed
}

private struct CaptureOnlyCommandRunner: CommandRunning {
    let capture: @Sendable ([String], [String: String]?, URL?) async throws -> String

    init(
        capture: @escaping @Sendable ([String], [String: String]?, URL?) async throws -> String
    ) {
        self.capture = capture
    }

    func runCapture(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> String {
        try await capture(command, env, cwd)
    }

    func runCaptureChunks(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?,
        consumeStandardOutput: @escaping CommandStandardOutputConsumer
    ) async throws {
        let output = try await capture(command, env, cwd)
        try Task.checkCancellation()
        try await consumeStandardOutput(Data(output.utf8))
        try Task.checkCancellation()
    }

    func runSimple(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws {
        throw ToolingError.message("unexpected runSimple command: \(command)")
    }

    func runBuffered(
        _ command: [String],
        env: [String: String]?,
        cwd: URL?
    ) async throws -> StreamingCommandResult {
        throw ToolingError.message("unexpected runBuffered command: \(command)")
    }
}

private final class ControlledSignalSource: PrivateHeaderKitSignalSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bufferedSignal: PrivateHeaderKitTerminationSignal?
    private var waiter:
        CheckedContinuation<PrivateHeaderKitTerminationSignal?, Never>?
    private var finished = false

    func next() async -> PrivateHeaderKitTerminationSignal? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let bufferedSignal {
                    self.bufferedSignal = nil
                    lock.unlock()
                    continuation.resume(returning: bufferedSignal)
                } else if finished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    precondition(waiter == nil, "signal source supports one waiter")
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish()
        }
    }

    func send(_ signal: PrivateHeaderKitTerminationSignal) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: signal)
        } else {
            precondition(bufferedSignal == nil, "only one signal is expected")
            bufferedSignal = signal
            lock.unlock()
        }
    }

    var isFinished: Bool {
        lock.lock()
        let value = finished
        lock.unlock()
        return value
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }
}

private enum FailureKind {
    case interrupted
    case infrastructure
}

private enum CLIFixtureError: Error {
    case cleanupFailed
}

private final class ThreadSafeStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let text = values.joined(separator: "\n")
        lock.unlock()
        return text
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

private actor ScriptedInput {
    private var lines: ArraySlice<String>

    init(_ lines: [String]) {
        self.lines = lines[...]
    }

    func readLine() throws -> String? {
        guard let line = lines.first else { return nil }
        lines = lines.dropFirst()
        return line
    }
}

private final class TerminalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let enterEvents = EventCounter()
    private var enters = 0
    private var restores = 0
    private let restoreError: PrivateHeaderKitInputError?

    init(restoreError: PrivateHeaderKitInputError? = nil) {
        self.restoreError = restoreError
    }

    func enter() {
        lock.lock()
        enters += 1
        lock.unlock()
        enterEvents.signal()
    }

    func restore() throws {
        lock.lock()
        restores += 1
        let error = restoreError
        lock.unlock()
        if let error { throw error }
    }

    var restoreCount: Int {
        lock.lock()
        let value = restores
        lock.unlock()
        return value
    }

    var enterCount: Int {
        lock.lock()
        let value = enters
        lock.unlock()
        return value
    }

    func waitForEnter(_ count: Int) async {
        await enterEvents.wait(until: count)
    }

    /// Releases `waitForEnter` for a command that ended without reading input.
    func stopWaiting() {
        enterEvents.signal()
    }
}

private struct ProbeTerminalController: PrivateHeaderKitTerminalModeControlling {
    let probe: TerminalProbe

    func enterRawMode(fileDescriptor _: Int32) throws -> PrivateHeaderKitTerminalRestoration {
        probe.enter()
        return { try probe.restore() }
    }
}

private final class SignalingSystemTerminalController: PrivateHeaderKitTerminalModeControlling,
    @unchecked Sendable
{
    private let enterEvents = EventCounter()

    func enterRawMode(fileDescriptor: Int32) throws -> PrivateHeaderKitTerminalRestoration {
        let restoration = try PrivateHeaderKitSystemTerminalModeController().enterRawMode(
            fileDescriptor: fileDescriptor
        )
        enterEvents.signal()
        return restoration
    }

    func waitForEnter() async {
        await enterEvents.wait(until: 1)
    }
}

private final class ThreadSafeData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        let text = String(decoding: storage, as: UTF8.self)
        let ready = waiters.filter { $0.0 == text }
        waiters.removeAll { $0.0 == text }
        lock.unlock()
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    var text: String {
        lock.lock()
        let value = String(decoding: storage, as: UTF8.self)
        lock.unlock()
        return value
    }

    func wait(until expected: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if String(decoding: storage, as: UTF8.self) == expected {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((expected, continuation))
                lock.unlock()
            }
        }
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let startEvents = EventCounter()
    private var didComplete = false

    func markStarted() {
        startEvents.signal()
    }

    func markCompleted() {
        lock.lock()
        didComplete = true
        lock.unlock()
    }

    var completed: Bool {
        lock.lock()
        let value = didComplete
        lock.unlock()
        return value
    }

    func waitForStart() async {
        await startEvents.wait(until: 1)
    }
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        lock.lock()
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        lock.unlock()
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count >= expectedCount {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((expectedCount, continuation))
                lock.unlock()
            }
        }
    }
}

private final class ThreadSafeBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func setTrue() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

private struct FailingTerminalController: PrivateHeaderKitTerminalModeControlling {
    func enterRawMode(fileDescriptor _: Int32) throws -> PrivateHeaderKitTerminalRestoration {
        throw PrivateHeaderKitInputError.terminalRawModeFailed(code: EIO)
    }
}

private final class BlockingTerminalController: PrivateHeaderKitTerminalModeControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let restoreGate = DispatchSemaphore(value: 0)
    private let restoreStartEvents = EventCounter()
    private var enters = 0
    private var restoredWithOpenFD = false

    func enterRawMode(fileDescriptor: Int32) throws -> PrivateHeaderKitTerminalRestoration {
        lock.lock()
        enters += 1
        let shouldBlock = enters == 1
        lock.unlock()
        return { [self] in
            restoreStartEvents.signal()
            if shouldBlock {
                restoreGate.wait()
            }
            let wasOpen = fcntl(fileDescriptor, F_GETFD) >= 0
            lock.lock()
            restoredWithOpenFD = wasOpen
            lock.unlock()
            if !wasOpen {
                throw PrivateHeaderKitInputError.terminalRestoreFailed(code: EBADF)
            }
        }
    }

    func allowRestore() {
        restoreGate.signal()
    }

    var restoredWhileFileDescriptorWasOpen: Bool {
        lock.lock()
        let value = restoredWithOpenFD
        lock.unlock()
        return value
    }

    func waitForRestoreStart() async {
        await restoreStartEvents.wait(until: 1)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderKitCLI-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors = [Int32](repeating: 0, count: 2)
    guard pipe(&descriptors) == 0 else {
        throw PrivateHeaderKitInputError.readFailed(code: errno)
    }
    return (descriptors[0], descriptors[1])
}

private func writeAll(_ string: String, to fileDescriptor: Int32) throws {
    try writeBytes(Array(string.utf8), to: fileDescriptor)
}

private func writeBytes(_ bytes: [UInt8], to fileDescriptor: Int32) throws {
    let data = Data(bytes)
    let written = data.withUnsafeBytes { buffer in
        write(fileDescriptor, buffer.baseAddress, buffer.count)
    }
    guard written == data.count else {
        throw PrivateHeaderKitInputError.readFailed(code: errno)
    }
}
