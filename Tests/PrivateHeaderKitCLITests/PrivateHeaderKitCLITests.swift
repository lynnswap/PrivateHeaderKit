import Foundation
import Testing

import PrivateHeaderKitCore
import PrivateHeaderKitTooling
@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitCLIParsingTests {
    @Test func noArgumentsStartInteractiveGeneration() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit"]) == .interactiveGenerate)
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "generate"]) == .interactiveGenerate)
    }

    @Test func helpFlagsResolveToPublicHelp() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "--help"]) == .help)
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "help"]) == .help)
    }

    @Test func installSubcommandIsNotPartOfPublicCLI() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "install",
                "--bindir",
                "/tmp/bin",
                "--dry-run",
            ])
            Issue.record("expected install to be rejected by the public CLI")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .unknownCommand("install"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func generateParsesExplicitIOSInputContract() throws {
        #expect(
            try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "SwiftUI,UIKit",
            ])
            == .generate(
                PrivateHeaderKitGenerateCommand(
                    platform: .iOS,
                    version: "27.0",
                    build: "24A5355q",
                    systemRoot: "/tmp/RuntimeRoot",
                    outputBaseDirectory: "/tmp/PrivateHeaderKit",
                    targetQuery: "SwiftUI,UIKit",
                    resume: false,
                    device: nil,
                    simulatorHelperPath: nil
                )
            )
        )
    }

    @Test func generateParsesMacOSInputWithoutBuildAndExplicitResume() throws {
        let command = try parsePrivateHeaderKitCommand([
            "privateheaderkit",
            "--platform=macOS",
            "--version=16.0",
            "--system-root",
            "/",
            "--out",
            "/tmp/PrivateHeaderKit",
            "--target",
            "AppKit,Foundation",
            "--resume",
        ])

        #expect(
            command == .generate(
                PrivateHeaderKitGenerateCommand(
                    platform: .macOS,
                    version: "16.0",
                    build: nil,
                    systemRoot: "/",
                    outputBaseDirectory: "/tmp/PrivateHeaderKit",
                    targetQuery: "AppKit,Foundation",
                    resume: true,
                    device: nil,
                    simulatorHelperPath: nil
                )
            )
        )
    }

    @Test func generateParsesIOSInputWithoutSystemRootAndOptionalSimulatorFlags() throws {
        #expect(
            try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "SwiftUI,UIKit",
                "--device",
                "SIM-001",
                "--sim-helper",
                "/opt/privateheaderkit/libexec/privateheaderkit/privateheaderkit-sim-helper",
            ])
            == .generate(
                PrivateHeaderKitGenerateCommand(
                    platform: .iOS,
                    version: "27.0",
                    build: "24A5355q",
                    systemRoot: nil,
                    outputBaseDirectory: "/tmp/PrivateHeaderKit",
                    targetQuery: "SwiftUI,UIKit",
                    resume: false,
                    device: "SIM-001",
                    simulatorHelperPath: "/opt/privateheaderkit/libexec/privateheaderkit/privateheaderkit-sim-helper"
                )
            )
        )
    }

    @Test func generateInputComputesUserFacingLabelsAndHiddenStateDirectory() throws {
        let command = try parsePrivateHeaderKitCommand([
            "privateheaderkit",
            "--platform",
            "iOS",
            "--version",
            "27.0",
            "--build",
            "24A5355q",
            "--system-root",
            "/tmp/RuntimeRoot",
            "--out",
            "/tmp/PrivateHeaderKit",
            "--target",
            "SwiftUI,UIKit",
        ])

        guard case .generate(let generateCommand) = command else {
            Issue.record("expected generate command")
            return
        }

        #expect(generateCommand.sourceDisplayName == "iOS 27.0 (24A5355q)")
        #expect(generateCommand.sourceDirectoryName == "iOS27.0(24A5355q)")
        #expect(generateCommand.artifactDirectory.path == "/tmp/PrivateHeaderKit/iOS27.0(24A5355q)")
        #expect(generateCommand.stateDirectory.path == "/tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)")
    }

    @Test func publicHelpDoesNotExposeHiddenCommands() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "--help"]) == .help)

        let usage = privateHeaderKitUsageText()
        #expect(usage.contains("--platform <iOS|macOS>"))
        #expect(usage.contains("--target <query>"))
        #expect(!usage.contains("__raw-dump"))
        #expect(!usage.contains("install"))
        #expect(!usage.contains("generate "))
    }

    @Test func hiddenGenerateHelpIsParsedAndDoesNotExposeInternalRawDump() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "generate", "--help"]) == .generateHelp)

        let usage = privateHeaderKitGenerateUsageText()
        #expect(usage.contains("--platform <iOS|macOS>"))
        #expect(usage.contains("--target <query>"))
        #expect(usage.contains("--device <name-or-udid>"))
        #expect(usage.contains("--sim-helper <path>"))
        #expect(!usage.contains("__raw-dump"))
        #expect(!usage.contains("privateheaderkit generate"))
    }

    @Test func rawDumpHelperSubcommandIsNotPublicCLI() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "__raw-dump",
                "-o",
                "/tmp/out",
                "/tmp/input",
            ])
            Issue.record("expected hidden raw dump helper entrypoint to be rejected by public CLI")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .unknownCommand("__raw-dump"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func publicHelpDoesNotListHiddenRawDumpCommand() {
        let usage = privateHeaderKitUsageText()
        #expect(!usage.contains("__raw-dump"))
        #expect(!usage.contains("install"))
    }

    @Test func generateRejectsMissingRequiredTargetQuery() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                "/tmp/PrivateHeaderKit",
            ])
            Issue.record("expected missing target query to be rejected")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .missingRequiredOption("--target"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func generateRejectsMissingMacOSSystemRoot() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "macOS",
                "--version",
                "16.0",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "AppKit",
            ])
            Issue.record("expected missing macOS system root to be rejected")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .missingRequiredOption("--system-root"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func generateRejectsQualityOption() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "SwiftUI,UIKit",
                "--quality",
                "fast",
            ])
            Issue.record("expected quality option to be rejected")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .unknownOption("--quality"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func generateRejectsEmptyCommaSeparatedTargetEntries() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "SwiftUI,",
            ])
            Issue.record("expected empty target query entry to be rejected")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .invalidTargetQuery("SwiftUI,"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func generateRejectsValuedOptionFollowedByAnotherFlag() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "--resume",
            ])
            Issue.record("expected target missing value to be rejected")
        } catch let error as PrivateHeaderKitCLIError {
            #expect(error == .missingValue("--target"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validGenerateRunInvokesGenerationRunnerWithCoreRequestAndPrintsSuccessOutput() async throws {
        let publicCommandURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let rawDumpHelperURL = URL(
            fileURLWithPath: "/opt/privateheaderkit/libexec/privateheaderkit/privateheaderkit-raw-helper",
            isDirectory: false
        )
        let simulatorHelperURL = URL(
            fileURLWithPath: "/opt/privateheaderkit/libexec/privateheaderkit/privateheaderkit-sim-helper",
            isDirectory: false
        )
        let recorder = GenerationRequestRecorder()
        var outputMessages: [String] = []
        var loggedMessages: [String] = []
        let exitCode = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "SwiftUI,UIKit",
                "--resume",
            ],
            currentExecutableURL: publicCommandURL,
            generationRunner: { request, progress in
                recorder.request = request
                progress(.runStarted(runID: "run-test", totalTargetCount: 2))
                progress(.targetStarted(index: 1, total: 2, displayName: "SwiftUI.framework"))
                progress(.targetFinished(
                    index: 1,
                    total: 2,
                    displayName: "SwiftUI.framework",
                    status: .completed
                ))
                progress(.targetStarted(index: 2, total: 2, displayName: "UIKit.framework"))
                progress(.targetFinished(
                    index: 2,
                    total: 2,
                    displayName: "UIKit.framework",
                    status: .completed
                ))
                progress(.runFinished(runID: "run-test", status: .completed))
                return PrivateHeaderKitGenerationSummary(
                    sourceDisplayName: request.sourceDisplayName,
                    artifactDirectory: URL(
                        fileURLWithPath: "/tmp/PrivateHeaderKit/iOS27.0(24A5355q)",
                        isDirectory: true
                    ),
                    manifestURL: URL(
                        fileURLWithPath: "/tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)/manifest.json",
                        isDirectory: false
                    ),
                    runRecordURL: URL(
                        fileURLWithPath: "/tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)/runs/run-test/run.json",
                        isDirectory: false
                    ),
                    runID: "run-test",
                    generatedTargetCount: 2,
                    skippedTargetCount: 1
                )
            },
            simulatorResolver: { command in
                #expect(command.device == nil)
                return simulatorResolution()
            },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { loggedMessages.append($0) }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(loggedMessages.isEmpty)
        #expect(request.sourceDisplayName == "iOS 27.0 (24A5355q)")
        #expect(request.sourceDirectoryName == "iOS27.0(24A5355q)")
        #expect(request.artifactBaseDirectory.path == "/tmp/PrivateHeaderKit")
        #expect(request.stateBaseDirectory.path == "/tmp/PrivateHeaderKit/.state")
        #expect(request.systemRoot?.path == "/tmp/RuntimeRoot")
        #expect(request.targetQuery == "SwiftUI,UIKit")
        #expect(request.resumeRequested == true)
        #expect(request.hostHelperURL == rawDumpHelperURL)
        #expect(request.simulatorHelperURL == simulatorHelperURL)
        #expect(!request.usesHostExecution)
        #expect(request.simulatorDeviceUDID == "SIM-001")
        #expect(request.simulatorRuntimeRoot == "/tmp/RuntimeRoot")
        #expect(request.usesSharedCache)
        #expect(request.prefersRuntimeMetadata)
        #expect(request.helperEnvironment == ["PH_RUNTIME_ROOT": "/tmp/RuntimeRoot"])
        #expect(outputMessages == [
            "selected simulator: iPhone 17 (SIM-001)",
            "",
            "Generation started",
            "  Run       run-test",
            "  Targets   2",
            "",
            "[1/2] SwiftUI.framework",
            "  completed",
            "[2/2] UIKit.framework",
            "  completed",
            "",
            "Generation finished: completed",
            "PrivateHeaderKit",
            "",
            "Generation completed",
            "",
            "Source",
            "  iOS 27.0 (24A5355q)",
            "",
            "Targets",
            "  SwiftUI, UIKit",
            "",
            "Result",
            "  Generated 2",
            "  Failed    0",
            "  Skipped   1",
            "",
            "Output",
            "  Headers   /tmp/PrivateHeaderKit/iOS27.0(24A5355q)",
            "  State     /tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)",
            "",
            "Run",
            "  ID        run-test",
            "  Manifest  .state/iOS27.0(24A5355q)/manifest.json",
            "  Record    .state/iOS27.0(24A5355q)/runs/run-test/run.json",
        ])
    }

    @Test func noArgumentRunStartsInteractiveGenerationFlow() async throws {
        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var inputs = [
            "1",
            "2",
            "SwiftUI,UIKit",
        ]
        let defaultOutputBaseDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("PrivateHeaderKit", isDirectory: true)
            .path
        var outputMessages: [String] = []
        var loggedMessages: [String] = []
        var screenClearCount = 0

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: helperURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { command in
                #expect(command.platform == .iOS)
                #expect(command.version == "27.0")
                #expect(command.build == "24A5355q")
                return simulatorResolution()
            },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .iOS,
                        version: "27.0",
                        build: "24A5355q",
                        systemRoot: nil
                    ),
                    PrivateHeaderKitInteractiveSource(
                        platform: .macOS,
                        version: "26.5.1",
                        build: "25F80",
                        systemRoot: "/"
                    ),
                ]
            },
            interactiveScreenClearer: { screenClearCount += 1 },
            inputReader: {
                inputs.isEmpty ? nil : inputs.removeFirst()
            },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { loggedMessages.append($0) }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(loggedMessages.isEmpty)
        #expect(request.sourceDisplayName == "iOS 27.0 (24A5355q)")
        #expect(request.artifactBaseDirectory.path == defaultOutputBaseDirectory)
        #expect(request.targetQuery == "SwiftUI,UIKit")
        #expect(request.startsFresh)
        #expect(request.resumeRequested == nil)
        #expect(screenClearCount == 4)
        #expect(!outputMessages.contains("Continue previous run? (y/n):"))
        #expect(!outputMessages.contains("Output directory: \(defaultOutputBaseDirectory)"))
        #expect(outputMessages.prefix(25) == [
            "PrivateHeaderKit",
            "Generate private headers from an installed runtime or this Mac.",
            "",
            "Step 1 of 3: Source",
            "Choose where PrivateHeaderKit reads system binaries from.",
            "iOS sources are Simulator runtimes. macOS is this Mac's system.",
            "",
            "Available sources:",
            "  iOS Simulator Runtimes",
            "    [1] iOS 27.0 (24A5355q)",
            "",
            "  macOS",
            "    [2] macOS 26.5.1 (25F80)",
            "",
            "Select source:",
            "PrivateHeaderKit",
            "",
            "Step 2 of 3: Targets",
            "Source: iOS 27.0 (24A5355q)",
            "",
            "  [1] All targets",
            "      Generate every discoverable target.",
            "  [2] Specific targets",
            "      Enter target names separated by commas.",
            "Select targets:",
        ])
        #expect(outputMessages.contains("Enter targets separated by commas."))
        #expect(outputMessages.contains("  SwiftUI,UIKit"))
        #expect(outputMessages.contains("  SpringBoardServices"))
        #expect(outputMessages.contains("Targets:"))
    }

    @Test func noArgumentRunCanSelectAllTargetsWithoutTargetInput() async throws {
        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var inputs = [
            "1",
            "1",
        ]
        var outputMessages: [String] = []
        var loggedMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: helperURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in simulatorResolution() },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .iOS,
                        version: "27.0",
                        build: "24A5355q",
                        systemRoot: nil
                    ),
                ]
            },
            interactiveScreenClearer: {},
            inputReader: {
                inputs.isEmpty ? nil : inputs.removeFirst()
            },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { loggedMessages.append($0) }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(loggedMessages.isEmpty)
        #expect(request.targetQuery == "all")
        #expect(request.startsFresh)
        #expect(outputMessages.contains("      Generate every discoverable target."))
        #expect(!outputMessages.contains("Enter targets separated by commas."))
    }

    @Test func noArgumentRunOffersContinueWhenAllExpandsPreviousSpecificTargetState() async throws {
        let root = try makeCLITestTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let runtimeRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("System/Library/Frameworks/Foo.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("System/Library/Frameworks/Bar.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeCompletedSubsetGenerationState(
            outputBaseDirectory: outputDirectory,
            runtimeRoot: runtimeRoot
        )

        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var inputs = [
            "1",
            "1",
            "1",
        ]
        var outputMessages: [String] = []
        var loggedMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: helperURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in simulatorResolution(resolvedRuntimeRoot: runtimeRoot.path) },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .iOS,
                        version: "27.0",
                        build: "24A5355q",
                        systemRoot: nil
                    ),
                ]
            },
            interactiveOutputBaseDirectoryProvider: { outputDirectory.path },
            interactiveScreenClearer: {},
            inputReader: {
                inputs.isEmpty ? nil : inputs.removeFirst()
            },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { loggedMessages.append($0) }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(loggedMessages.isEmpty)
        #expect(request.targetQuery == "all")
        #expect(!request.startsFresh)
        #expect(outputMessages.contains("Step 3 of 3: Continue or restart"))
        #expect(outputMessages.contains("Existing generation state was found."))
        #expect(outputMessages.contains("Targets: all"))
        #expect(outputMessages.contains("Remaining: 1 of 2"))
        #expect(outputMessages.contains("  [1] Continue"))
        #expect(outputMessages.contains("  [2] Restart"))
    }

    @Test func interactiveEscapeReturnsFromTargetModeToSourceSelection() async throws {
        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var inputs = [
            "1",
            "\u{001B}",
            "1",
            "1",
        ]
        var outputMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: helperURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in simulatorResolution() },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .iOS,
                        version: "27.0",
                        build: "24A5355q",
                        systemRoot: nil
                    ),
                ]
            },
            interactiveScreenClearer: {},
            inputReader: {
                inputs.isEmpty ? nil : inputs.removeFirst()
            },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { _ in }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(request.targetQuery == "all")
        #expect(outputMessages.filter { $0 == "Available sources:" }.count == 2)
    }

    @Test func interactiveEscapeReturnsFromSpecificTargetsToTargetMode() async throws {
        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var inputs = [
            "1",
            "2",
            "\u{001B}",
            "1",
        ]
        var outputMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: helperURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in simulatorResolution() },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .iOS,
                        version: "27.0",
                        build: "24A5355q",
                        systemRoot: nil
                    ),
                ]
            },
            interactiveScreenClearer: {},
            inputReader: {
                inputs.isEmpty ? nil : inputs.removeFirst()
            },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { _ in }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(request.targetQuery == "all")
        #expect(outputMessages.contains("Step 2 of 3: Specific targets"))
        #expect(outputMessages.filter { $0 == "Step 2 of 3: Targets" }.count == 2)
    }

    @Test func iOSGenerateDefaultsSimulatorHelperToInstallLayoutForCustomBindir() async throws {
        let publicCommandURL = URL(fileURLWithPath: "/opt/phk/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        let exitCode = await runPrivateHeaderKitCommand(
            validGenerateArguments(),
            currentExecutableURL: publicCommandURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in simulatorResolution() },
            outputLogger: { _ in },
            errorLogger: { _ in }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(request.hostHelperURL?.path == "/opt/libexec/privateheaderkit/privateheaderkit-raw-helper")
        #expect(request.simulatorHelperURL?.path == "/opt/libexec/privateheaderkit/privateheaderkit-sim-helper")
    }

    @Test func helperDefaultsSupportSwiftPMBuildProducts() {
        let publicCommandURL = URL(
            fileURLWithPath: "/repo/.build/arm64-apple-macosx/debug/privateheaderkit",
            isDirectory: false
        )
        let rawHelperURL = defaultRawDumpHelperURL(publicExecutableURL: publicCommandURL)

        #expect(rawHelperURL.path == "/repo/.build/arm64-apple-macosx/debug/privateheaderkit-raw-helper")
        #expect(
            swiftPMBuildSimulatorHelperURL(
                hostBuildExecutableURL: rawHelperURL,
                simulatorTriple: "arm64-apple-ios-simulator"
            )?.path == "/repo/.build/arm64-apple-ios-simulator/debug/privateheaderkit-sim-helper"
        )
    }

    @Test func swiftPMBuildHelpersBuildMissingSourceTreeProducts() throws {
        let publicCommandURL = URL(
            fileURLWithPath: "/repo/.build/arm64-apple-macosx/debug/privateheaderkit",
            isDirectory: false
        )
        let runner = RecordingCommandRunner()

        try ensureSwiftPMBuildHelpersIfNeeded(
            publicExecutableURL: publicCommandURL,
            includeSimulatorHelper: true,
            runner: runner,
            simulatorTriple: "arm64-apple-ios-simulator"
        )

        #expect(runner.commands == [
            RecordedCommand(
                command: [
                    "swift",
                    "build",
                    "-c",
                    "debug",
                    "--product",
                    "privateheaderkit-raw-helper",
                ],
                cwd: "/repo"
            ),
            RecordedCommand(
                command: ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                cwd: nil
            ),
            RecordedCommand(
                command: [
                    "swift",
                    "build",
                    "-c",
                    "debug",
                    "--sdk",
                    "/SDK/iPhoneSimulator",
                    "--triple",
                    "arm64-apple-ios-simulator",
                    "--product",
                    "privateheaderkit-sim-helper",
                ],
                cwd: "/repo"
            ),
        ])
    }

    @Test func iOSGenerateWithoutSystemRootUsesResolvedRuntimeRootAndExplicitSimulatorHelper() async throws {
        let recorder = GenerationRequestRecorder()
        let simulatorHelper = "/tmp/privateheaderkit-sim-helper"
        let exitCode = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "SwiftUI",
                "--device",
                "iPhone 17",
                "--sim-helper",
                simulatorHelper,
            ],
            currentExecutableURL: URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false),
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { command in
                #expect(command.device == "iPhone 17")
                return simulatorResolution(resolvedRuntimeRoot: "/Resolved/RuntimeRoot")
            },
            outputLogger: { _ in },
            errorLogger: { _ in }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(request.systemRoot?.path == "/Resolved/RuntimeRoot")
        #expect(request.simulatorRuntimeRoot == "/Resolved/RuntimeRoot")
        #expect(request.simulatorHelperURL?.path == simulatorHelper)
    }

    @Test func macOSGenerateUsesHostExecutionAndDoesNotResolveSimulator() async throws {
        let publicCommandURL = URL(fileURLWithPath: "/tmp/phk/bin/privateheaderkit", isDirectory: false)
        let rawDumpHelperURL = URL(
            fileURLWithPath: "/tmp/phk/libexec/privateheaderkit/privateheaderkit-raw-helper",
            isDirectory: false
        )
        let recorder = GenerationRequestRecorder()
        let exitCode = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform",
                "macOS",
                "--version",
                "16.0",
                "--system-root",
                "/",
                "--out",
                "/tmp/PrivateHeaderKit",
                "--target",
                "AppKit",
            ],
            currentExecutableURL: publicCommandURL,
            generationRunner: { request, _ in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in
                Issue.record("macOS generation should not resolve a simulator")
                return simulatorResolution()
            },
            outputLogger: { _ in },
            errorLogger: { _ in }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(request.systemRoot?.path == "/")
        #expect(request.hostHelperURL == rawDumpHelperURL)
        #expect(request.usesHostExecution)
        #expect(request.simulatorDeviceUDID == nil)
    }

    @Test func generateResumeRequiredErrorReturnsGuidance() async throws {
        var outputMessages: [String] = []
        var loggedMessages: [String] = []
        let exitCode = await runPrivateHeaderKitCommand(
            validGenerateArguments(),
            currentExecutableURL: URL(fileURLWithPath: "/tmp/privateheaderkit-test-helper", isDirectory: false),
            generationRunner: { _, _ in
                throw PrivateHeaderGeneration.GenerationError.resumeRequired(
                    try resumeSummaryFixture(latestRunID: "run-previous")
                )
            },
            simulatorResolver: { _ in simulatorResolution() },
            outputLogger: { outputMessages.append($0) },
            errorLogger: { loggedMessages.append($0) }
        )

        #expect(exitCode == 2)
        #expect(outputMessages == [
            "selected simulator: iPhone 17 (SIM-001)",
        ])
        #expect(loggedMessages == [
            "error: existing generation state is unfinished; explicit resume is required for run-previous",
            "rerun with `--resume` to continue the unfinished generation state",
        ])
    }

    @Test func generateRunFailedPrintsFailedTargetDetailsFromManifest() async throws {
        let outputDirectory = try makeCLITestTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        var loggedMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            [
                "privateheaderkit",
                "--platform",
                "iOS",
                "--version",
                "27.0",
                "--build",
                "24A5355q",
                "--system-root",
                "/tmp/RuntimeRoot",
                "--out",
                outputDirectory.path,
                "--target",
                "SwiftUI,UIKit",
            ],
            currentExecutableURL: URL(fileURLWithPath: "/tmp/privateheaderkit", isDirectory: false),
            generationRunner: { request, _ in
                try writeFailedGenerationManifest(
                    for: request,
                    runID: "run-failed"
                )
                throw PrivateHeaderGeneration.GenerationError.runFailed(
                    runID: "run-failed",
                    failedTargetIDs: [
                        "framework:SwiftUI.framework",
                        "framework:UIKit.framework",
                    ]
                )
            },
            simulatorResolver: { _ in simulatorResolution() },
            outputLogger: { _ in },
            errorLogger: { loggedMessages.append($0) }
        )

        #expect(exitCode == 2)
        #expect(loggedMessages == [
            "PrivateHeaderKit",
            "",
            "Generation completed with failures",
            "",
            "Source",
            "  iOS 27.0 (24A5355q)",
            "",
            "Targets",
            "  SwiftUI, UIKit",
            "",
            "Result",
            "  Generated 0",
            "  Failed    2",
            "  Skipped   0",
            "",
            "Failed targets",
            "  [1] SwiftUI.framework",
            "      raw dump exited with status 10",
            "      Child process terminated with signal 10: Bus error",
            "      MachOObjCSection/_FileIOProtocol+.swift:52: Fatal error: offsetOutOfBounds",
            "",
            "  [2] UIKit.framework",
            "      no failure summary recorded",
            "",
            "Output",
            "  Headers   \(outputDirectory.path)/iOS27.0(24A5355q)",
            "  State     \(outputDirectory.path)/.state/iOS27.0(24A5355q)",
            "",
            "Run",
            "  ID        run-failed",
            "  Manifest  .state/iOS27.0(24A5355q)/manifest.json",
            "  Record    .state/iOS27.0(24A5355q)/runs/run-failed/run.json",
        ])
    }

    @Test func interruptedInteractiveRunDoesNotClearProgressBeforeResult() async throws {
        let outputDirectory = try makeCLITestTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        var inputs = [
            "1",
            "1",
        ]
        var screenClearCount = 0
        var loggedMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: URL(fileURLWithPath: "/tmp/privateheaderkit", isDirectory: false),
            generationRunner: { request, _ in
                try writeFailedGenerationManifest(
                    for: request,
                    runID: "run-interrupted",
                    targetStatus: .interrupted
                )
                throw PrivateHeaderGeneration.GenerationError.runFailed(
                    runID: "run-interrupted",
                    failedTargetIDs: [
                        "framework:SwiftUI.framework",
                        "framework:UIKit.framework",
                    ]
                )
            },
            simulatorResolver: { _ in simulatorResolution() },
            interactiveSourceProvider: {
                [
                    PrivateHeaderKitInteractiveSource(
                        platform: .iOS,
                        version: "27.0",
                        build: "24A5355q",
                        systemRoot: nil
                    ),
                ]
            },
            interactiveOutputBaseDirectoryProvider: { outputDirectory.path },
            interactiveScreenClearer: { screenClearCount += 1 },
            inputReader: {
                inputs.isEmpty ? nil : inputs.removeFirst()
            },
            outputLogger: { _ in },
            errorLogger: { loggedMessages.append($0) }
        )

        #expect(exitCode == 2)
        #expect(screenClearCount == 2)
        #expect(loggedMessages.contains("Generation interrupted"))
        #expect(loggedMessages.contains("  Failed    0"))
        #expect(loggedMessages.contains("  Interrupted 2"))
    }

    @Test func legacyExecutableNamesAreRejectedAsPublicSubcommands() {
        for legacyCommand in ["privateheaderkit-dump", "headerdump", "headerdump-sim"] {
            do {
                _ = try parsePrivateHeaderKitCommand(["privateheaderkit", legacyCommand])
                Issue.record("expected \(legacyCommand) to be rejected")
            } catch let error as PrivateHeaderKitCLIError {
                #expect(error == .legacyCommand(legacyCommand))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func legacyExecutableNamesAreRejectedWhenInvokedDirectly() {
        for legacyCommand in ["privateheaderkit-dump", "headerdump", "headerdump-sim"] {
            do {
                _ = try parsePrivateHeaderKitCommand(["/usr/local/bin/\(legacyCommand)"])
                Issue.record("expected \(legacyCommand) invocation to be rejected")
            } catch let error as PrivateHeaderKitCLIError {
                #expect(error == .legacyCommand(legacyCommand))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}

private final class GenerationRequestRecorder {
    var request: PrivateHeaderKitGenerationRequest?
}

private struct RecordedCommand: Equatable {
    let command: [String]
    let cwd: String?
}

private final class RecordingCommandRunner: CommandRunning {
    var commands: [RecordedCommand] = []

    func runCapture(_ command: [String], env _: [String: String]?, cwd: URL?) throws -> String {
        commands.append(RecordedCommand(command: command, cwd: cwd?.path))
        if command == ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"] {
            return "/SDK/iPhoneSimulator\n"
        }
        return ""
    }

    func runSimple(_ command: [String], env _: [String: String]?, cwd: URL?) throws {
        commands.append(RecordedCommand(command: command, cwd: cwd?.path))
    }

    func runStreaming(_ command: [String], env _: [String: String]?, cwd: URL?) throws -> StreamingCommandResult {
        commands.append(RecordedCommand(command: command, cwd: cwd?.path))
        return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
    }

    func runStreaming(
        _ command: [String],
        env _: [String: String]?,
        cwd: URL?,
        streamOutput _: Bool,
        onLaunch _: ((Int32) -> Void)?,
        onCleanup _: ((Int32) -> Void)?
    ) throws -> StreamingCommandResult {
        commands.append(RecordedCommand(command: command, cwd: cwd?.path))
        return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
    }
}

private func simulatorResolution(
    resolvedRuntimeRoot: String = "/tmp/RuntimeRoot"
) -> PrivateHeaderKitSimulatorResolution {
    PrivateHeaderKitSimulatorResolution(
        runtimeVersion: "27.0",
        runtimeBuild: "24A5355q",
        runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        resolvedRuntimeRoot: resolvedRuntimeRoot,
        deviceName: "iPhone 17",
        deviceUDID: "SIM-001"
    )
}

private func summaryFixture(
    for request: PrivateHeaderKitGenerationRequest
) -> PrivateHeaderKitGenerationSummary {
    PrivateHeaderKitGenerationSummary(
        sourceDisplayName: request.sourceDisplayName,
        artifactDirectory: request.artifactBaseDirectory.appendingPathComponent(
            request.sourceDirectoryName,
            isDirectory: true
        ),
        manifestURL: request.stateBaseDirectory
            .appendingPathComponent(request.sourceDirectoryName, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false),
        runRecordURL: request.stateBaseDirectory
            .appendingPathComponent(request.sourceDirectoryName, isDirectory: true)
            .appendingPathComponent("runs/run-test/run.json", isDirectory: false),
        runID: "run-test",
        generatedTargetCount: 1,
        skippedTargetCount: nil
    )
}

private func validGenerateArguments() -> [String] {
    [
        "privateheaderkit",
        "--platform",
        "iOS",
        "--version",
        "27.0",
        "--build",
        "24A5355q",
        "--system-root",
        "/tmp/RuntimeRoot",
        "--out",
        "/tmp/PrivateHeaderKit",
        "--target",
        "SwiftUI,UIKit",
    ]
}

private func resumeSummaryFixture(
    latestRunID: String
) throws -> PrivateHeaderGeneration.ResumeSummary {
    let source = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: "24A5355q"
    )
    let outputBaseDirectory = URL(
        fileURLWithPath: "/tmp/PrivateHeaderKit",
        isDirectory: true
    )
    let directoryName = source.label.directoryName
    return PrivateHeaderGeneration.ResumeSummary(
        source: PrivateHeaderGeneration.SourceRecord(source: source),
        output: PrivateHeaderGeneration.OutputRecord(
            baseDirectory: outputBaseDirectory.path,
            artifactDirectory: outputBaseDirectory.appendingPathComponent(
                directoryName,
                isDirectory: true
            ).path,
            stateDirectory: outputBaseDirectory.appendingPathComponent(
                ".state/\(directoryName)",
                isDirectory: true
            ).path
        ),
        layout: .headers,
        latestRunID: latestRunID,
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200),
        counts: PrivateHeaderGeneration.ResumeTargetCounts(
            total: 1,
            completed: 0,
            partial: 1,
            failed: 0,
            interrupted: 0,
            commitFailed: 0,
            stale: 0,
            pending: 0
        ),
        targets: [
            PrivateHeaderGeneration.ResumeTargetDecision(
                targetID: "SwiftUI.framework",
                status: .partial
            ),
        ]
    )
}

private func makeCLITestTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderKitCLITests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeCompletedSubsetGenerationState(
    outputBaseDirectory: URL,
    runtimeRoot: URL
) throws {
    let source = try PrivateHeaderGeneration.Source(
        platform: .iOS,
        version: "27.0",
        build: "24A5355q"
    )
    let sourceDirectoryName = source.label.directoryName
    let artifactDirectory = outputBaseDirectory.appendingPathComponent(
        sourceDirectoryName,
        isDirectory: true
    )
    let stateDirectory = outputBaseDirectory
        .appendingPathComponent(".state", isDirectory: true)
        .appendingPathComponent(sourceDirectoryName, isDirectory: true)
    let artifact = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h")
    try FileManager.default.createDirectory(
        at: artifactDirectory.appendingPathComponent("Frameworks/Foo", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("foo".utf8).write(
        to: artifactDirectory.appendingPathComponent(artifact.rawValue, isDirectory: false)
    )

    let sourceRecord = PrivateHeaderGeneration.SourceRecord(source: source)
    let outputRecord = PrivateHeaderGeneration.OutputRecord(
        baseDirectory: outputBaseDirectory.path,
        artifactDirectory: artifactDirectory.path,
        stateDirectory: stateDirectory.path
    )
    let executionRecord = PrivateHeaderGeneration.ExecutionRecord(
        mode: "simulator",
        runtimeIdentifier: nil,
        deviceName: nil,
        deviceUDID: "SIM-001",
        clonePolicy: nil,
        helperEnvironment: [
            "PH_RUNTIME_ROOT": runtimeRoot.path,
            "SIMCTL_CHILD_PH_RUNTIME_ROOT": runtimeRoot.path,
            "SIMCTL_CHILD_DYLD_ROOT_PATH": runtimeRoot.path,
        ]
    )
    let runPlan = PrivateHeaderGeneration.RunPlanRecord(
        source: sourceRecord,
        output: outputRecord,
        layout: .headers,
        targetIDs: ["framework:Foo.framework"],
        execution: executionRecord
    )
    let runID = "run-prev"
    let updatedAt = Date(timeIntervalSince1970: 1_000)
    let target = PrivateHeaderGeneration.TargetRecord(
        id: "framework:Foo.framework",
        displayName: "Foo",
        kind: "framework",
        status: .completed,
        phases: [
            PrivateHeaderGeneration.PhaseRecord(name: "raw-header-dump", status: .completed),
        ],
        artifacts: [artifact],
        lastRunID: runID,
        updatedAt: updatedAt,
        failureSummary: nil
    )
    let manifest = PrivateHeaderGeneration.Manifest(
        schemaVersion: 1,
        toolVersion: "0.1.0",
        source: sourceRecord,
        output: outputRecord,
        layout: .headers,
        latestRunID: runID,
        targets: [target],
        updatedAt: updatedAt
    )
    let run = PrivateHeaderGeneration.RunRecord(
        runID: runID,
        schemaVersion: 1,
        toolVersion: "0.1.0",
        plan: runPlan,
        startedAt: updatedAt,
        endedAt: updatedAt,
        status: .completed,
        targetResults: [
            PrivateHeaderGeneration.RunTargetRecord(
                targetID: target.id,
                status: .completed,
                phases: target.phases,
                artifacts: target.artifacts,
                attemptedArtifacts: target.artifacts,
                failureSummary: nil
            ),
        ],
        attemptedArtifacts: target.artifacts,
        logs: []
    )

    let repository = PrivateHeaderGeneration.RunRepository(stateDirectory: stateDirectory)
    try repository.writeManifest(manifest)
    try repository.writeRun(run)
}

private func writeFailedGenerationManifest(
    for request: PrivateHeaderKitGenerationRequest,
    runID: String,
    targetStatus: PrivateHeaderGeneration.TargetStatus = .failed
) throws {
    let manifestDirectory = request.stateBaseDirectory
        .appendingPathComponent(request.sourceDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)

    let manifest = PrivateHeaderGeneration.Manifest(
        schemaVersion: 1,
        toolVersion: "0.1.0",
        source: PrivateHeaderGeneration.SourceRecord(source: request.source),
        output: PrivateHeaderGeneration.OutputRecord(
            baseDirectory: request.artifactBaseDirectory.path,
            artifactDirectory: request.artifactBaseDirectory
                .appendingPathComponent(request.sourceDirectoryName, isDirectory: true)
                .path,
            stateDirectory: manifestDirectory.path
        ),
        layout: .headers,
        latestRunID: runID,
        targets: [
            PrivateHeaderGeneration.TargetRecord(
                id: "framework:SwiftUI.framework",
                displayName: "SwiftUI.framework",
                kind: "framework",
                status: targetStatus,
                phases: [
                    PrivateHeaderGeneration.PhaseRecord(
                        name: "raw-header-dump",
                        status: .failed,
                        failureSummary: """
                        raw dump exited with status 10
                        Child process terminated with signal 10: Bus error
                        MachOObjCSection/_FileIOProtocol+.swift:52: Fatal error: offsetOutOfBounds
                        """
                    ),
                ],
                artifacts: [],
                lastRunID: runID,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                failureSummary: """
                raw dump exited with status 10
                Child process terminated with signal 10: Bus error
                MachOObjCSection/_FileIOProtocol+.swift:52: Fatal error: offsetOutOfBounds
                """
            ),
            PrivateHeaderGeneration.TargetRecord(
                id: "framework:UIKit.framework",
                displayName: "UIKit.framework",
                kind: "framework",
                status: targetStatus,
                phases: [
                    PrivateHeaderGeneration.PhaseRecord(
                        name: "raw-header-dump",
                        status: .failed
                    ),
                ],
                artifacts: [],
                lastRunID: runID,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                failureSummary: nil
            ),
        ],
        updatedAt: Date(timeIntervalSince1970: 1_000)
    )
    let data = try PrivateHeaderGeneration.StateJSON.encode(manifest)
    try data.write(
        to: manifestDirectory.appendingPathComponent("manifest.json", isDirectory: false),
        options: [.atomic]
    )
}
