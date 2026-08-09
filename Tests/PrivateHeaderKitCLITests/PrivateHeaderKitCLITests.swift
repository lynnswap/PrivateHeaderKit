import Foundation
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
    @Test func noArgumentsAndHiddenGenerateStartInteractiveMode() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit"]) == .interactiveGenerate)
        #expect(
            try parsePrivateHeaderKitCommand(["privateheaderkit", "generate"])
                == .interactiveGenerate
        )
    }

    @Test func rootAcceptsDirectGenerationOptionsAndSourceVersion() throws {
        let parsed = try parsePrivateHeaderKitCommand([
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
                PrivateHeaderKitGenerateCommand(
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

    @Test func hiddenGenerateUsesTheSameTypedMapping() throws {
        let root = try parsePrivateHeaderKitCommand([
            "privateheaderkit",
            "--platform", "macOS",
            "--version", "16.0",
            "--system-root", "/",
            "--out", "/tmp/headers",
            "--target", "all",
            "--fresh",
        ])
        let alias = try parsePrivateHeaderKitCommand([
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

    @Test func rootHelpHasNoSubcommandPlaceholderAndHidesGenerate() async {
        let output = ThreadSafeStrings()
        let errors = ThreadSafeStrings()
        let status = await runPrivateHeaderKitCommand(
            ["privateheaderkit", "--help"],
            currentExecutableURL: nil,
            outputLogger: output.append,
            errorLogger: errors.append
        )
        #expect(status == 0)
        #expect(output.text.contains("USAGE: privateheaderkit [<options>]"))
        #expect(!output.text.contains("<subcommand>"))
        #expect(!output.text.contains("SUBCOMMANDS:"))
        #expect(errors.text.isEmpty)
    }

    @Test func continuationFlagsAreMutuallyExclusive() async {
        let errors = ThreadSafeStrings()
        let status = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform", "macOS",
                "--version", "16.0",
                "--system-root", "/",
                "--out", "/tmp/headers",
                "--target", "all",
                "--resume", "--fresh",
            ],
            currentExecutableURL: nil,
            outputLogger: { _ in },
            errorLogger: errors.append
        )
        #expect(status != 0)
        #expect(errors.text.contains("--resume"))
        #expect(errors.text.contains("--fresh"))
        #expect(errors.text.contains("already been set"))
    }

    @Test func partialDirectOptionsFailInsteadOfFallingBackToInteractiveMode() async {
        let errors = ThreadSafeStrings()
        let status = await runPrivateHeaderKitCommand(
            ["privateheaderkit", "--version", "27.0"],
            currentExecutableURL: nil,
            outputLogger: { _ in },
            errorLogger: errors.append
        )
        #expect(status != 0)
        #expect(errors.text.contains("--platform"))
    }

    @Test func legacyExecutableNamesAsFirstArgumentKeepMigrationGuidance() async {
        for name in ["privateheaderkit-dump", "headerdump", "headerdump-sim"] {
            let errors = ThreadSafeStrings()
            let status = await runPrivateHeaderKitCommand(
                ["privateheaderkit", name],
                currentExecutableURL: nil,
                outputLogger: { _ in },
                errorLogger: errors.append
            )
            #expect(status == 1)
            #expect(errors.text.contains("\(name) is no longer a user-facing command"))
            #expect(errors.text.contains("use privateheaderkit instead"))
        }
    }

    @Test func emptyDeviceAndSimulatorHelperValuesFailFast() async {
        for option in ["--device", "--sim-helper"] {
            let errors = ThreadSafeStrings()
            let status = await runPrivateHeaderKitCommand(
                [
                    "privateheaderkit",
                    "--platform", "iOS",
                    "--version", "27.0",
                    "--out", "/tmp/headers",
                    "--target", "all",
                    option, "",
                ],
                currentExecutableURL: nil,
                outputLogger: { _ in },
                errorLogger: errors.append
            )
            #expect(status != 0)
            #expect(errors.text.contains("must not be empty"))
            #expect(errors.text.contains(option))
        }
    }
}

@Suite
struct PrivateHeaderKitCLIExecutionTests {
    @Test func directRunMapsFreshModeAndRendersTypedResultAndWarnings() async throws {
        let requestBox = ThreadSafeRequestBox()
        let output = ThreadSafeStrings()
        let status = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform", "macOS",
                "--version", "16.0",
                "--system-root", "/SystemRoot",
                "--out", "/tmp/PrivateHeaderKit",
                "--target", "AppKit,Foundation",
                "--fresh",
            ],
            currentExecutableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
            generationRunner: { request, progress in
                requestBox.set(request)
                progress(.runStarted(
                    runID: PrivateHeaderGeneration.RunID(rawValue: "run-typed"),
                    totalTargetCount: 3
                ))
                return resultFixture(
                    for: request,
                    counts: PrivateHeaderGeneration.TargetCounts(
                        total: 3,
                        skipped: 1,
                        completed: 2
                    ),
                    warnings: [
                        PrivateHeaderGeneration.GenerationWarning(
                            kind: "opaque-path",
                            relativePath: "Frameworks/AppKit/Headers/Generated.h",
                            message: "preserved unowned artifact"
                        ),
                    ]
                )
            },
            outputLogger: output.append,
            errorLogger: output.append
        )
        #expect(status == 0)
        let request = try #require(requestBox.value)
        #expect(request.options.resumeBehavior == .fresh)
        #expect(request.options.targetRequest == .query("AppKit,Foundation"))
        #expect(request.options.executionMode == .host)
        #expect(request.options.helperURLs?.host.path == "/cohort/privateheaderkit-raw-helper")
        #expect(output.text.contains("Generated  2"))
        #expect(output.text.contains("Skipped    1"))
        #expect(output.text.contains("opaque-path"))
        #expect(output.text.contains("generation.sqlite"))
        #expect(!output.text.contains("manifest.json"))
        #expect(!output.text.contains("run.json"))
    }

    @Test func runFailureUsesTypedSummaryWithoutReadingStateFiles() async {
        let output = ThreadSafeStrings()
        let status = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform", "macOS",
                "--version", "16.0",
                "--system-root", "/SystemRoot",
                "--out", "/does/not/exist",
                "--target", "AppKit",
            ],
            currentExecutableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
            generationRunner: { request, _ in
                let summary = summaryFixture(
                    for: request,
                    status: .failed,
                    counts: PrivateHeaderGeneration.TargetCounts(total: 2, completed: 1, failed: 1)
                )
                throw PrivateHeaderGeneration.GenerationError.runFailed(
                    PrivateHeaderGeneration.RunFailure(
                        summary: summary,
                        failedTargetIDs: ["framework:AppKit.framework"]
                    )
                )
            },
            outputLogger: output.append,
            errorLogger: output.append
        )
        #expect(status == 2)
        #expect(output.text.contains("Generation completed with failures"))
        #expect(output.text.contains("framework:AppKit.framework"))
        #expect(
            output.text.contains(
                "/does/not/exist/.state/macos-v1-16.0-b0/generation.sqlite"
            )
        )
    }

    @Test func interruptionAndInfrastructureErrorsRenderTheirTypedSummaries() async {
        for kind in [FailureKind.interrupted, .infrastructure] {
            let output = ThreadSafeStrings()
            let status = await runPrivateHeaderKitCommand(
                [
                    "privateheaderkit",
                    "--platform", "macOS",
                    "--version", "16.0",
                    "--system-root", "/SystemRoot",
                    "--out", "/tmp/typed-error",
                    "--target", "all",
                ],
                currentExecutableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
                generationRunner: { request, _ in
                    let summary = summaryFixture(
                        for: request,
                        status: kind == .interrupted ? .interrupted : .failed,
                        counts: PrivateHeaderGeneration.TargetCounts(
                            total: 1,
                            failed: kind == .infrastructure ? 1 : 0,
                            interrupted: kind == .interrupted ? 1 : 0
                        )
                    )
                    if kind == .interrupted {
                        throw PrivateHeaderGeneration.GenerationError.runInterrupted(
                            PrivateHeaderGeneration.RunInterruption(summary: summary)
                        )
                    }
                    throw PrivateHeaderGeneration.GenerationError.infrastructureFailed(
                        PrivateHeaderGeneration.RunInfrastructureFailure(
                            summary: summary,
                            message: "database transaction could not commit"
                        )
                    )
                },
                outputLogger: output.append,
                errorLogger: output.append
            )
            #expect(status == 2)
            if kind == .interrupted {
                #expect(output.text.contains("Generation interrupted"))
            } else {
                #expect(output.text.contains("database transaction could not commit"))
            }
        }
    }

    @Test func interactiveRunUsesOneScriptedActorAndFreshCoreDecision() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let framework = root.appendingPathComponent(
            "System/Library/Frameworks/Foo.framework",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: framework,
            withIntermediateDirectories: true
        )
        let outputBase = root.appendingPathComponent("Output", isDirectory: true)
        let input = ScriptedInput(["1", "1"])
        let requestBox = ThreadSafeRequestBox()
        let helperResolutionCount = ThreadSafeCounter()
        let helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
            host: URL(fileURLWithPath: "/resolved/privateheaderkit-raw-helper"),
            simulator: URL(fileURLWithPath: "/resolved/privateheaderkit-sim-helper")
        )
        let output = ThreadSafeStrings()

        let status = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
            generationRunner: { request, _ in
                requestBox.set(request)
                return resultFixture(
                    for: request,
                    counts: PrivateHeaderGeneration.TargetCounts(total: 1, completed: 1)
                )
            },
            helperResolver: { _, _, _ in
                helperResolutionCount.increment()
                return PrivateHeaderKitHelperPlan(helperURLs: helperURLs)
            },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .macOS,
                        version: "16.0",
                        build: nil,
                        systemRoot: root.path
                    ),
                ]
            },
            interactiveOutputBaseDirectoryProvider: { outputBase.path },
            interactiveScreenClearer: {},
            inputReader: { try await input.readLine() },
            outputLogger: output.append,
            errorLogger: output.append
        )
        #expect(status == 0)
        #expect(requestBox.value?.options.resumeBehavior == .fresh)
        #expect(requestBox.value?.options.helperURLs == helperURLs)
        #expect(helperResolutionCount.value == 1)
        #expect(output.text.contains("Step 1 of 3"))
        #expect(output.text.contains("Generation completed"))
    }

    @Test func interactiveConfirmsLegacyJSONStateMigration() async throws {
        try await assertInteractiveLegacyMigration(kind: .jsonState)
    }

    @Test func interactiveConfirmsLegacyArtifactTreeMigration() async throws {
        try await assertInteractiveLegacyMigration(kind: .artifactTree)
    }
}

@Suite
struct PrivateHeaderKitHelperLookupTests {
    @Test func installedPublicSymlinkResolvesHelpersFromActiveCohort() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cohort = root.appendingPathComponent(
            "libexec/privateheaderkit/versions/cohort-a",
            isDirectory: true
        )
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: cohort, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for executable in [
            "privateheaderkit",
            "privateheaderkit-raw-helper",
            "privateheaderkit-sim-helper",
        ] {
            try Data().write(to: cohort.appendingPathComponent(executable))
        }
        let current = root.appendingPathComponent("libexec/privateheaderkit/current")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: cohort)
        let publicExecutable = bin.appendingPathComponent("privateheaderkit")
        try FileManager.default.createSymbolicLink(
            at: publicExecutable,
            withDestinationURL: current.appendingPathComponent("privateheaderkit")
        )

        let raw = defaultRawDumpHelperURL(publicExecutableURL: publicExecutable)
        let simulator = defaultSimulatorHelperURL(hostExecutableURL: raw)
        #expect(raw.standardizedFileURL == cohort.appendingPathComponent("privateheaderkit-raw-helper"))
        #expect(
            simulator.standardizedFileURL
                == cohort.appendingPathComponent("privateheaderkit-sim-helper")
        )
    }

    @Test func SwiftPMHelpersUseReportedBinPathsAndDedicatedSimulatorScratch() async throws {
        let runner = RecordingCommandRunner()
        let executable = URL(
            fileURLWithPath: "/repo/.build/out/Products/Debug/privateheaderkit"
        )
        let sdkPath = "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        let simulatorTriple = "arm64-apple-ios-simulator"
        let scratchPath = "/repo/.build/privateheaderkit-simulator/\(simulatorTriple)"
        let simulatorCommand = [
            "swift", "build", "-c", "debug",
            "--scratch-path", scratchPath,
            "--sdk", sdkPath,
            "--triple", simulatorTriple,
        ]
        runner.setCaptureOutput(
            "build log\n/repo/.build/out/Products/Debug\n",
            for: ["swift", "build", "-c", "debug", "--show-bin-path"]
        )
        runner.setCaptureOutput(
            "\n\(sdkPath)\n",
            for: ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]
        )
        runner.setCaptureOutput(
            "\n\(scratchPath)/out/Products/Debug-iphonesimulator\n",
            for: simulatorCommand + ["--show-bin-path"]
        )

        let plan = try await resolvePrivateHeaderKitHelperPlan(
            publicExecutableURL: executable,
            simulatorHelperPath: nil,
            requiresSimulatorHelper: true,
            runner: runner,
            simulatorTriple: simulatorTriple
        )

        #expect(
            plan.helperURLs.host.path
                == "/repo/.build/out/Products/Debug/privateheaderkit-raw-helper"
        )
        #expect(
            plan.helperURLs.simulator.path
                == "\(scratchPath)/out/Products/Debug-iphonesimulator/privateheaderkit-sim-helper"
        )
        #expect(runner.captureCommands.map(\.command) == [
            ["swift", "build", "-c", "debug", "--show-bin-path"],
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
            simulatorCommand + ["--show-bin-path"],
        ])
        #expect(runner.captureCommands.map(\.cwd) == [
            URL(fileURLWithPath: "/repo", isDirectory: true),
            nil,
            URL(fileURLWithPath: "/repo", isDirectory: true),
        ])

        let buildRunner = RecordingCommandRunner()
        let rawBuild = [
            "swift", "build", "-c", "debug", "--product", "privateheaderkit-raw-helper",
        ]
        let simulatorBuild = simulatorCommand + ["--product", "privateheaderkit-sim-helper"]
        buildRunner.setCaptureOutput("", for: rawBuild)
        buildRunner.setCaptureOutput("", for: simulatorBuild)
        try await executePrivateHeaderKitHelperBuilds(plan, runner: buildRunner)
        #expect(buildRunner.captureCommands.map(\.command) == [rawBuild, simulatorBuild])
        #expect(
            buildRunner.captureCommands.allSatisfy {
                $0.cwd == URL(fileURLWithPath: "/repo", isDirectory: true)
            }
        )
    }

    @Test func explicitSimulatorHelperSkipsSimulatorBuildAndResolution() async throws {
        let runner = RecordingCommandRunner()
        let rawBuild = [
            "swift", "build", "-c", "release", "--product", "privateheaderkit-raw-helper",
        ]
        let hostBinQuery = ["swift", "build", "-c", "release", "--show-bin-path"]
        runner.setCaptureOutput("/repo/.build/out/Products/Release\n", for: hostBinQuery)

        let plan = try await resolvePrivateHeaderKitHelperPlan(
            publicExecutableURL: URL(
                fileURLWithPath: "/repo/.build/out/Products/Release/privateheaderkit"
            ),
            simulatorHelperPath: "/custom/privateheaderkit-sim-helper",
            requiresSimulatorHelper: true,
            runner: runner
        )

        #expect(
            plan.helperURLs.host.path
                == "/repo/.build/out/Products/Release/privateheaderkit-raw-helper"
        )
        #expect(plan.helperURLs.simulator.path == "/custom/privateheaderkit-sim-helper")
        #expect(runner.captureCommands.map(\.command) == [hostBinQuery])

        let buildRunner = RecordingCommandRunner()
        buildRunner.setCaptureOutput("", for: rawBuild)
        try await executePrivateHeaderKitHelperBuilds(plan, runner: buildRunner)
        #expect(buildRunner.captureCommands.map(\.command) == [rawBuild])
    }

    @Test func emptySwiftPMBinPathFailsWithoutLayoutFallback() async {
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            " \n\t\n",
            for: ["swift", "build", "-c", "debug", "--show-bin-path"]
        )

        await #expect(throws: ToolingError.self) {
            _ = try await resolvePrivateHeaderKitHelperPlan(
                publicExecutableURL: URL(
                    fileURLWithPath: "/repo/.build/out/Products/Debug/privateheaderkit"
                ),
                simulatorHelperPath: nil,
                requiresSimulatorHelper: false,
                runner: runner
            )
        }
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
        let generationCalled = ThreadSafeBool()
        let probe = TerminalProbe()
        let promptInput = try PrivateHeaderKitAsyncInput(
            fileDescriptor: descriptors.read,
            isTerminal: { _ in true },
            terminalModeController: ProbeTerminalController(probe: probe),
            echoWriter: { _ in }
        )
        let commandTask = Task {
            await runPrivateHeaderKitCommand(
                ["privateheaderkit"],
                currentExecutableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
                generationRunner: { request, _ in
                    generationCalled.setTrue()
                    return resultFixture(
                        for: request,
                        counts: PrivateHeaderGeneration.TargetCounts(total: 1, completed: 1)
                    )
                },
                interactiveSourceProvider: {
                    [
                        PrivateHeaderKitInteractiveSource(
                            platform: .macOS,
                            version: "16.0",
                            build: nil,
                            systemRoot: "/"
                        ),
                    ]
                },
                interactiveScreenClearer: {},
                inputReader: { try await promptInput.readLine() },
                outputLogger: { _ in },
                errorLogger: { _ in }
            )
        }
        await probe.waitForEnter(1)
        try writeBytes(Array("1\n1\n".utf8) + [3], to: descriptors.write)
        let status = await commandTask.value
        #expect(status == 130)
        #expect(!generationCalled.value)
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

private enum FailureKind {
    case interrupted
    case infrastructure
}

private enum LegacyInputKind {
    case jsonState
    case artifactTree
}

private func assertInteractiveLegacyMigration(kind: LegacyInputKind) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let systemRoot = root.appendingPathComponent("SystemRoot", isDirectory: true)
    try FileManager.default.createDirectory(
        at: systemRoot.appendingPathComponent(
            "System/Library/Frameworks/Foo.framework",
            isDirectory: true
        ),
        withIntermediateDirectories: true
    )
    let outputBase = root.appendingPathComponent("Output", isDirectory: true)
    let detectedURL: URL
    switch kind {
    case .jsonState:
        detectedURL = outputBase.appendingPathComponent(
            ".state/macos-v1-16.0-b0/manifest.json",
            isDirectory: false
        )
    case .artifactTree:
        detectedURL = outputBase.appendingPathComponent(
            "macos-v1-16.0-b0/Unknown.txt",
            isDirectory: false
        )
    }
    try FileManager.default.createDirectory(
        at: detectedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("legacy".utf8).write(to: detectedURL)

    let input = ScriptedInput(["1", "1", "1"])
    let output = ThreadSafeStrings()
    let requestBox = ThreadSafeRequestBox()
    let status = await runPrivateHeaderKitCommand(
        ["privateheaderkit"],
        currentExecutableURL: URL(fileURLWithPath: "/cohort/privateheaderkit"),
        generationRunner: { request, _ in
            requestBox.set(request)
            return resultFixture(
                for: request,
                counts: PrivateHeaderGeneration.TargetCounts(total: 1, completed: 1)
            )
        },
        interactiveSourceProvider: {
            [
                PrivateHeaderKitInteractiveSource(
                    platform: .macOS,
                    version: "16.0",
                    build: nil,
                    systemRoot: systemRoot.path
                ),
            ]
        },
        interactiveOutputBaseDirectoryProvider: { outputBase.path },
        interactiveScreenClearer: {},
        inputReader: { try await input.readLine() },
        outputLogger: output.append,
        errorLogger: output.append
    )

    #expect(status == 0)
    #expect(requestBox.value?.options.resumeBehavior == .fresh)
    #expect(output.text.contains("Migrate and start fresh"))
    #expect(output.text.contains("[2] Back"))
    #expect(output.text.contains(outputBase.path))
    switch kind {
    case .jsonState:
        #expect(output.text.contains("Legacy state files will remain in place"))
        #expect(output.text.contains("generation.sqlite"))
        #expect(output.text.contains("source of truth"))
        #expect(!output.text.contains("legacy-backups"))
    case .artifactTree:
        #expect(output.text.contains("artifact tree and unknown regular files will be preserved"))
        #expect(
            output.text.contains(
                outputBase.appendingPathComponent(
                    ".privateheaderkit/macos-v1-16.0-b0/legacy-backups",
                    isDirectory: true
                ).path + "/"
            )
        )
    }
    #expect(FileManager.default.fileExists(atPath: detectedURL.path))
}

private func resultFixture(
    for request: PrivateHeaderKitGenerationRequest,
    counts: PrivateHeaderGeneration.TargetCounts,
    warnings: [PrivateHeaderGeneration.GenerationWarning] = []
) -> PrivateHeaderGeneration.Result {
    let plan = PrivateHeaderGeneration.makePlan(
        source: request.source,
        output: request.output,
        options: request.options
    )
    return PrivateHeaderGeneration.Result(
        plan: plan,
        artifactDirectory: plan.artifactDirectory,
        generatedTargets: (0..<counts.completed).map {
            PrivateHeaderGeneration.Target.generated(identifier: "target-\($0)")
        },
        runID: PrivateHeaderGeneration.RunID(rawValue: "run-typed"),
        stateDatabaseURL: plan.databaseURL,
        targetCounts: counts,
        warnings: warnings
    )
}

private func summaryFixture(
    for request: PrivateHeaderKitGenerationRequest,
    status: PrivateHeaderGeneration.RunStatus,
    counts: PrivateHeaderGeneration.TargetCounts
) -> PrivateHeaderGeneration.RunSummary {
    let plan = PrivateHeaderGeneration.makePlan(
        source: request.source,
        output: request.output,
        options: request.options
    )
    return PrivateHeaderGeneration.RunSummary(
        runID: PrivateHeaderGeneration.RunID(rawValue: "run-error"),
        status: status,
        targetCounts: counts,
        artifactDirectory: plan.artifactDirectory,
        stateDatabaseURL: plan.databaseURL
    )
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

private final class ThreadSafeRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PrivateHeaderKitGenerationRequest?

    func set(_ request: PrivateHeaderKitGenerationRequest) {
        lock.lock()
        storage = request
        lock.unlock()
    }

    var value: PrivateHeaderKitGenerationRequest? {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
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
