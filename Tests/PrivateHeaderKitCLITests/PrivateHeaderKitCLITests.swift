import Testing

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

    @Test func validGenerateRunReturnsTemporaryIntegrationError() async {
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
        ], errorLogger: { loggedMessages.append($0) })

        #expect(exitCode == 2)
        #expect(loggedMessages.first == "private header generation is parsed but not wired to the Core executor yet")
        #expect(loggedMessages.contains("source: iOS 27.0 (24A5355q)"))
        #expect(loggedMessages.contains("target query: SwiftUI,UIKit"))
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
