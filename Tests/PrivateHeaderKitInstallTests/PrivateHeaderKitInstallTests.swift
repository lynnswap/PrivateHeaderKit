import Foundation
import Testing

@testable import PrivateHeaderKitInstall
import PrivateHeaderKitTestSupport

@Suite
struct InstallOptionTests {
    @Test func parseOptionsUsesEnvironmentDefaultsAndCliOverrides() throws {
        let envOptions = try parseOptions(["privateheaderkit install"], environment: [
            "PREFIX": "/env/prefix",
            "BINDIR": "/env/bin",
        ])
        #expect(envOptions.prefix == "/env/prefix")
        #expect(envOptions.bindir == "/env/bin")
        #expect(envOptions.dryRun == false)

        let cliOptions = try parseOptions(
            ["privateheaderkit install", "--prefix", "/cli/prefix", "--dry-run"],
            environment: ["BINDIR": "/env/bin"]
        )
        #expect(cliOptions.prefix == "/cli/prefix")
        #expect(cliOptions.bindir == nil)
        #expect(cliOptions.dryRun == true)

        let bindirOptions = try parseOptions(
            ["privateheaderkit install", "--prefix", "/cli/prefix", "--bindir", "/cli/bin"],
            environment: [:]
        )
        #expect(bindirOptions.prefix == "/cli/prefix")
        #expect(bindirOptions.bindir == "/cli/bin")
    }

    @Test func parseOptionsRejectsUnknownOptions() {
        do {
            _ = try parseOptions(["privateheaderkit install", "--wat"], environment: [:])
            Issue.record("expected parse failure")
        } catch let error as InstallError {
            #expect(error.description == "unknown option: --wat")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func resolveBinDirPrefersBindirOverPrefix() {
        #expect(resolveBinDir(prefix: "/prefix", bindir: "/custom/bin").path == "/custom/bin")
        #expect(resolveBinDir(prefix: "/prefix", bindir: nil).path == "/prefix/bin")
    }
}

@Suite
struct InstallCommandResolutionTests {
    @Test func repositoryRootFindsBuildAncestor() {
        let executable = URL(fileURLWithPath: "/repo/.build/arm64-apple-macosx/release/privateheaderkit")
        #expect(repositoryRoot(from: executable)?.path == "/repo")
    }

    @Test func looksLikePrivateHeaderKitRepoRequiresBothMarkers() throws {
        let dirs = try makeTemporaryTestDirectories()
        let repoRoot = dirs.root.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCore", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCore/PrivateHeaderGeneration.swift"))
        #expect(looksLikePrivateHeaderKitRepo(repoRoot, fileManager: .default) == false)

        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCLI", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCLI/PrivateHeaderKitMain.swift"))
        #expect(looksLikePrivateHeaderKitRepo(repoRoot, fileManager: .default) == true)
    }

    @Test func buildProductsRecordsReleaseBuildCommands() throws {
        let dirs = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()

        try buildProducts(["privateheaderkit"], in: dirs.root, runner: runner)

        #expect(runner.simpleCommands.map(\.command) == [
            ["swift", "build", "-c", "release", "--product", "privateheaderkit"],
        ])
        #expect(runner.simpleCommands.allSatisfy { $0.cwd == dirs.root })
    }

    @Test func resolveSwiftBinDirUsesLastNonEmptyOutputLine() throws {
        let dirs = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            "\nignored\n\(dirs.root.appendingPathComponent(".build/release").path)\n",
            for: ["swift", "build", "-c", "release", "--show-bin-path"]
        )

        let binDir = resolveSwiftBinDir(repoRoot: dirs.root, runner: runner)

        #expect(binDir?.path == dirs.root.appendingPathComponent(".build/release").path)
    }
}
