import Foundation
import Testing

import PrivateHeaderKitCore
@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitCLIParsingTests {
    @Test func helpFlagsResolveToHelp() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit"]) == .help)
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "--help"]) == .help)
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "help"]) == .help)
    }

    @Test func installSubcommandForwardsInstallerArguments() throws {
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
                "generate",
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
                    resume: false
                )
            )
        )
    }

    @Test func generateParsesMacOSInputWithoutBuildAndExplicitResume() throws {
        let command = try parsePrivateHeaderKitCommand([
            "privateheaderkit",
            "generate",
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
                    resume: true
                )
            )
        )
    }

    @Test func generateInputComputesUserFacingLabelsAndHiddenStateDirectory() throws {
        let command = try parsePrivateHeaderKitCommand([
            "privateheaderkit",
            "generate",
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

    @Test func generateHelpIsParsedAndDoesNotExposeInternalRawDump() throws {
        #expect(try parsePrivateHeaderKitCommand(["privateheaderkit", "generate", "--help"]) == .generateHelp)

        let usage = privateHeaderKitGenerateUsageText()
        #expect(usage.contains("--platform <iOS|macOS>"))
        #expect(usage.contains("--target <query>"))
        #expect(!usage.contains("__raw-dump"))
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
    }

    @Test func generateRejectsMissingRequiredTargetQuery() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "generate",
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

    @Test func generateRejectsQualityOption() throws {
        do {
            _ = try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "generate",
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
                "generate",
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
                "generate",
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
        let helperURL = URL(fileURLWithPath: "/tmp/privateheaderkit-test-helper", isDirectory: false)
        let recorder = GenerationRequestRecorder()
        var outputMessages: [String] = []
        var loggedMessages: [String] = []
        let exitCode = await runPrivateHeaderKitCommand([
            "privateheaderkit",
            "generate",
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
        ], currentExecutableURL: helperURL, generationRunner: { request in
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
        }, outputLogger: { outputMessages.append($0) }, errorLogger: { loggedMessages.append($0) })

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
        #expect(request.simulatorHelperURL == helperURL)
        #expect(request.usesHostExecution)
        #expect(request.usesSharedCache)
        #expect(request.prefersRuntimeMetadata)
        #expect(request.helperEnvironment == ["PH_RUNTIME_ROOT": "/tmp/RuntimeRoot"])
        #expect(outputMessages == [
            "private header generation completed",
            "source: iOS 27.0 (24A5355q)",
            "artifact directory: /tmp/PrivateHeaderKit/iOS27.0(24A5355q)",
            "manifest path: /tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)/manifest.json",
            "run record path: /tmp/PrivateHeaderKit/.state/iOS27.0(24A5355q)/runs/run-test/run.json",
            "run ID: run-test",
            "targets: generated 2, skipped 1",
        ])
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
            outputLogger: { outputMessages.append($0) },
            errorLogger: { loggedMessages.append($0) }
        )

        #expect(exitCode == 2)
        #expect(outputMessages.isEmpty)
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

private func validGenerateArguments() -> [String] {
    [
        "privateheaderkit",
        "generate",
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
