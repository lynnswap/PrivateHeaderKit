import Testing

@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitCLIParsingTests {
    @Test func helpFlagsResolveToHelp() throws {
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

    @Test func generationCommandIsReservedForRewriteExecutionIntegration() throws {
        #expect(
            try parsePrivateHeaderKitCommand([
                "privateheaderkit",
                "generate",
                "--source",
                "iOS27.0(24A5355q)",
            ])
            == .generationUnavailable([
                "--source",
                "iOS27.0(24A5355q)",
            ])
        )
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
}
