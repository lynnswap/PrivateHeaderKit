import Foundation
import Testing

import PrivateHeaderKitCore
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

    @Test func hiddenInstallSubcommandForwardsInstallerArguments() throws {
        let command = try parsePrivateHeaderKitCommand([
            "privateheaderkit",
            "install",
            "--bindir",
            "/tmp/bin",
            "--dry-run",
        ])

        #expect(command == .install([
            "privateheaderkit install",
            "--bindir",
            "/tmp/bin",
            "--dry-run",
        ]))
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

    @Test func hiddenRawDumpCommandForwardsRawDumpArguments() throws {
        #expect(
            try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "__raw-dump",
                "-o",
                "/tmp/out",
                "/tmp/input",
            ])
            == .rawDump([
                "-o",
                "/tmp/out",
                "/tmp/input",
            ])
        )
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
        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
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
            currentExecutableURL: helperURL,
            generationRunner: { request in
                recorder.request = request
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
        #expect(request.hostHelperURL == helperURL)
        #expect(request.simulatorHelperURL == simulatorHelperURL)
        #expect(!request.usesHostExecution)
        #expect(request.simulatorDeviceUDID == "SIM-001")
        #expect(request.simulatorRuntimeRoot == "/tmp/RuntimeRoot")
        #expect(request.usesSharedCache)
        #expect(request.prefersRuntimeMetadata)
        #expect(request.helperEnvironment == ["PH_RUNTIME_ROOT": "/tmp/RuntimeRoot"])
        #expect(outputMessages == [
            "selected simulator: iPhone 17 (SIM-001)",
            "private header generation completed",
            "source: iOS 27.0 (24A5355q)",
            "artifact directory: /tmp/PrivateHeaderKit/iOS27.0(24A5355q)",
            "manifest path: /tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)/manifest.json",
            "run record path: /tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)/runs/run-test/run.json",
            "run ID: run-test",
            "targets: generated 2, skipped 1",
        ])
    }

    @Test func noArgumentRunStartsInteractiveGenerationFlow() async throws {
        let helperURL = URL(fileURLWithPath: "/opt/privateheaderkit/bin/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var inputs = [
            "1",
            "SwiftUI,UIKit",
        ]
        let defaultOutputBaseDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("PrivateHeaderKit", isDirectory: true)
            .path
        var outputMessages: [String] = []
        var loggedMessages: [String] = []

        let exitCode = await runPrivateHeaderKitCommand(
            ["privateheaderkit"],
            currentExecutableURL: helperURL,
            generationRunner: { request in
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
        #expect(request.sourceDisplayName == "iOS 27.0 (24A5355q)")
        #expect(request.artifactBaseDirectory.path == defaultOutputBaseDirectory)
        #expect(request.targetQuery == "SwiftUI,UIKit")
        #expect(request.startsFresh)
        #expect(request.resumeRequested == nil)
        #expect(!outputMessages.contains("Continue previous run? (y/n):"))
        #expect(outputMessages.prefix(5) == [
            "Available sources:",
            "  [1] iOS 27.0 (24A5355q)",
            "Select source:",
            "Selected source: iOS 27.0 (24A5355q)",
            "Output directory: \(defaultOutputBaseDirectory)",
        ])
        #expect(outputMessages.contains("Targets (comma-separated, or all):"))
    }

    @Test func iOSGenerateDefaultsSimulatorHelperToInstallLayoutForCustomBindir() async throws {
        let helperURL = URL(fileURLWithPath: "/opt/phk/privateheaderkit", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        let exitCode = await runPrivateHeaderKitCommand(
            validGenerateArguments(),
            currentExecutableURL: helperURL,
            generationRunner: { request in
                recorder.request = request
                return summaryFixture(for: request)
            },
            simulatorResolver: { _ in simulatorResolution() },
            outputLogger: { _ in },
            errorLogger: { _ in }
        )

        let request = try #require(recorder.request)
        #expect(exitCode == 0)
        #expect(request.hostHelperURL == helperURL)
        #expect(request.simulatorHelperURL?.path == "/opt/libexec/privateheaderkit/privateheaderkit-sim-helper")
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
            generationRunner: { request in
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
        let helperURL = URL(fileURLWithPath: "/tmp/privateheaderkit", isDirectory: false)
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
            currentExecutableURL: helperURL,
            generationRunner: { request in
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
        #expect(request.hostHelperURL == helperURL)
        #expect(request.usesHostExecution)
        #expect(request.simulatorDeviceUDID == nil)
    }

    @Test func generateResumeRequiredErrorReturnsGuidance() async throws {
        var outputMessages: [String] = []
        var loggedMessages: [String] = []
        let exitCode = await runPrivateHeaderKitCommand(
            validGenerateArguments(),
            currentExecutableURL: URL(fileURLWithPath: "/tmp/privateheaderkit-test-helper", isDirectory: false),
            generationRunner: { _ in
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
