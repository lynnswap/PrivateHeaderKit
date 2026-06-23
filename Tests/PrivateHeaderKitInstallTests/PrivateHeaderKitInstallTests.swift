import Foundation
import Testing

@testable import PrivateHeaderKitInstall
import PrivateHeaderKitTestSupport

@Suite
struct InstallOptionTests {
    @Test func parseOptionsUsesEnvironmentDefaultsAndCliOverrides() throws {
        let envOptions = try parseOptions(["privateheaderkit-install"], environment: [
            "PREFIX": "/env/prefix",
            "BINDIR": "/env/bin",
        ])
        #expect(envOptions.prefix == "/env/prefix")
        #expect(envOptions.bindir == "/env/bin")
        #expect(envOptions.dryRun == false)
        #expect(envOptions.buildConfiguration == nil)

        let cliOptions = try parseOptions(
            ["privateheaderkit-install", "--prefix", "/cli/prefix", "--dry-run", "--configuration", "debug"],
            environment: ["BINDIR": "/env/bin"]
        )
        #expect(cliOptions.prefix == "/cli/prefix")
        #expect(cliOptions.bindir == nil)
        #expect(cliOptions.dryRun == true)
        #expect(cliOptions.buildConfiguration == .debug)

        let bindirOptions = try parseOptions(
            ["privateheaderkit-install", "--prefix", "/cli/prefix", "--bindir", "/cli/bin"],
            environment: [:]
        )
        #expect(bindirOptions.prefix == "/cli/prefix")
        #expect(bindirOptions.bindir == "/cli/bin")
    }

    @Test func parseOptionsRejectsUnknownOptions() {
        do {
            _ = try parseOptions(["privateheaderkit-install", "--wat"], environment: [:])
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

    @Test func resolveInstallLayoutPlacesHelperUnderLibexec() {
        let prefixLayout = resolveInstallLayout(prefix: "/prefix", bindir: nil)
        #expect(prefixLayout.publicCommandURL.path == "/prefix/bin/privateheaderkit")
        #expect(prefixLayout.rawDumpHelperURL.path == "/prefix/libexec/privateheaderkit/privateheaderkit-raw-helper")
        #expect(prefixLayout.simulatorHelperURL.path == "/prefix/libexec/privateheaderkit/privateheaderkit-sim-helper")

        let bindirLayout = resolveInstallLayout(prefix: "/ignored", bindir: "/custom/bin")
        #expect(bindirLayout.publicCommandURL.path == "/custom/bin/privateheaderkit")
        #expect(bindirLayout.rawDumpHelperURL.path == "/custom/libexec/privateheaderkit/privateheaderkit-raw-helper")
        #expect(bindirLayout.simulatorHelperURL.path == "/custom/libexec/privateheaderkit/privateheaderkit-sim-helper")

        let installedRawHelper = defaultInstalledRawDumpHelperURL(
            for: URL(fileURLWithPath: "/custom/phk/privateheaderkit", isDirectory: false)
        )
        #expect(installedRawHelper.path == "/custom/libexec/privateheaderkit/privateheaderkit-raw-helper")
        let installedHelper = defaultInstalledSimulatorHelperURL(
            for: URL(fileURLWithPath: "/custom/phk/privateheaderkit", isDirectory: false)
        )
        #expect(installedHelper.path == "/custom/libexec/privateheaderkit/privateheaderkit-sim-helper")
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

    @Test func defaultSimulatorHelperTripleUsesNativeHostArchitecture() throws {
        #expect(
            try defaultSimulatorHelperTriple(
                executableArchitecture: "x86_64",
                supportsNativeArm64: true
            ) == "arm64-apple-ios-simulator"
        )
        #expect(
            try defaultSimulatorHelperTriple(
                executableArchitecture: "x86_64",
                supportsNativeArm64: false
            ) == "x86_64-apple-ios-simulator"
        )
        #expect(
            try defaultSimulatorHelperTriple(
                executableArchitecture: "arm64",
                supportsNativeArm64: true
            ) == "arm64-apple-ios-simulator"
        )
        #expect(throws: InstallError.self) {
            _ = try defaultSimulatorHelperTriple(
                executableArchitecture: "ppc",
                supportsNativeArm64: false
            )
        }
    }

    @Test func buildProductsRecordsConfiguredBuildCommands() throws {
        let dirs = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput("/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk\n", for: [
            "xcrun",
            "--sdk",
            "iphonesimulator",
            "--show-sdk-path",
        ])

        try buildProducts(["privateheaderkit"], configuration: .debug, in: dirs.root, runner: runner)
        try buildSimulatorHelper(
            in: dirs.root,
            configuration: .debug,
            runner: runner,
            simulatorHelperTriple: "x86_64-apple-ios-simulator"
        )

        #expect(runner.simpleCommands.map(\.command) == [
            ["swift", "build", "-c", "debug", "--product", "privateheaderkit"],
            [
                "swift",
                "build",
                "-c",
                "debug",
                "--sdk",
                "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
                "--triple",
                "x86_64-apple-ios-simulator",
                "--product",
                "privateheaderkit-sim-helper",
            ],
        ])
        #expect(runner.simpleCommands.allSatisfy { $0.cwd == dirs.root })
        #expect(runner.simpleCommands[0].env == nil)
        #expect(runner.simpleCommands[1].env == nil)
    }

    @Test func currentReleaseExecutableCanBeInstalledWithoutRebuildingPublicCommand() throws {
        let repoRoot = URL(fileURLWithPath: "/repo", isDirectory: true)
        let executable = repoRoot.appendingPathComponent(".build/release/privateheaderkit", isDirectory: false)

        #expect(
            canInstallCurrentExecutableAsPublicCommand(
                selfURL: executable,
                repoRoot: repoRoot,
                configuration: .release
            )
        )
        #expect(
            canInstallCurrentExecutableAsPublicCommand(
                selfURL: repoRoot.appendingPathComponent(".build/debug/privateheaderkit", isDirectory: false),
                repoRoot: repoRoot,
                configuration: .debug
            )
        )
        #expect(
            !canInstallCurrentExecutableAsPublicCommand(
                selfURL: repoRoot.appendingPathComponent(".build/debug/privateheaderkit", isDirectory: false),
                repoRoot: repoRoot,
                configuration: .release
            )
        )
        #expect(
            !canInstallCurrentExecutableAsPublicCommand(
                selfURL: URL(fileURLWithPath: "/usr/local/bin/privateheaderkit", isDirectory: false),
                repoRoot: repoRoot,
                configuration: .release
            )
        )
    }

    @Test func resolveSwiftBinDirUsesLastNonEmptyOutputLine() throws {
        let dirs = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            "\nignored\n\(dirs.root.appendingPathComponent(".build/debug").path)\n",
            for: ["swift", "build", "-c", "debug", "--show-bin-path"]
        )

        let binDir = resolveSwiftBinDir(repoRoot: dirs.root, runner: runner, configuration: .debug)

        #expect(binDir?.path == dirs.root.appendingPathComponent(".build/debug").path)
    }

    @Test func resolveSwiftBinDirCanUseSimulatorTriple() throws {
        let dirs = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        runner.setCaptureOutput(
            "\(dirs.root.appendingPathComponent(".build/arm64-apple-ios-simulator/release").path)\n",
            for: [
                "swift",
                "build",
                "-c",
                "release",
                "--sdk",
                "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
                "--triple",
                "arm64-apple-ios-simulator",
                "--show-bin-path",
            ]
        )

        let binDir = resolveSwiftBinDir(
            repoRoot: dirs.root,
            runner: runner,
            configuration: .release,
            triple: "arm64-apple-ios-simulator",
            sdkPath: "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        )

        #expect(binDir?.path == dirs.root.appendingPathComponent(".build/arm64-apple-ios-simulator/release").path)
    }

    @Test func dryRunInstallMessagesIncludeInternalHelper() {
        let layout = resolveInstallLayout(prefix: "/prefix", bindir: nil)

        #expect(dryRunInstallMessages(layout: layout) == [
            "Would create: /prefix/bin",
            "Would create: /prefix/libexec/privateheaderkit",
            "Would install: /prefix/bin/privateheaderkit",
            "Would install internal helper: /prefix/libexec/privateheaderkit/privateheaderkit-raw-helper",
            "Would install internal helper: /prefix/libexec/privateheaderkit/privateheaderkit-sim-helper",
        ])
    }

    @Test func installFromSwiftRunReleaseCopiesCurrentPublicCommandAndBuildsSimulatorHelper() throws {
        let dirs = try makeTemporaryTestDirectories()
        let repoRoot = dirs.root.appendingPathComponent("Repo", isDirectory: true)
        let installPrefix = dirs.root.appendingPathComponent("Install", isDirectory: true)
        let hostBinDir = repoRoot.appendingPathComponent(".build/release", isDirectory: true)
        let simulatorBinDir = repoRoot.appendingPathComponent(
            ".build/x86_64-apple-ios-simulator/release",
            isDirectory: true
        )
        try makePrivateHeaderKitRepoMarkers(in: repoRoot)
        try FileManager.default.createDirectory(at: hostBinDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: simulatorBinDir, withIntermediateDirectories: true)
        try Data("host".utf8).write(to: hostBinDir.appendingPathComponent("privateheaderkit"))
        try Data("raw".utf8).write(to: hostBinDir.appendingPathComponent("privateheaderkit-raw-helper"))
        try Data("sim".utf8).write(to: simulatorBinDir.appendingPathComponent("privateheaderkit-sim-helper"))

        let runner = RecordingCommandRunner()
        runner.setCaptureOutput("/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk\n", for: [
            "xcrun",
            "--sdk",
            "iphonesimulator",
            "--show-sdk-path",
        ])
        runner.setCaptureOutput(
            "\(hostBinDir.path)\n",
            for: ["swift", "build", "-c", "release", "--show-bin-path"]
        )
        runner.setCaptureOutput(
            "\(simulatorBinDir.path)\n",
            for: [
                "swift",
                "build",
                "-c",
                "release",
                "--sdk",
                "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
                "--triple",
                "x86_64-apple-ios-simulator",
                "--show-bin-path",
            ]
        )
        var outputMessages: [String] = []
        var errorMessages: [String] = []

        try install(
            options: InstallOptions(prefix: installPrefix.path, bindir: nil, dryRun: false),
            selfURL: hostBinDir.appendingPathComponent("privateheaderkit"),
            currentDirectoryURL: repoRoot,
            runner: runner,
            fileManager: .default,
            outputLogger: { outputMessages.append($0) },
            errorLogger: { errorMessages.append($0) },
            simulatorHelperTriple: "x86_64-apple-ios-simulator"
        )

        let layout = resolveInstallLayout(prefix: installPrefix.path, bindir: nil)
        #expect(try String(contentsOf: layout.publicCommandURL, encoding: .utf8) == "host")
        #expect(try String(contentsOf: layout.rawDumpHelperURL, encoding: .utf8) == "raw")
        #expect(try String(contentsOf: layout.simulatorHelperURL, encoding: .utf8) == "sim")
        #expect(runner.simpleCommands.map(\.command) == [
            [
                "swift",
                "build",
                "-c",
                "release",
                "--product",
                "privateheaderkit-raw-helper",
            ],
            [
                "swift",
                "build",
                "-c",
                "release",
                "--sdk",
                "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
                "--triple",
                "x86_64-apple-ios-simulator",
                "--product",
                "privateheaderkit-sim-helper",
            ],
        ])
        #expect(runner.simpleCommands[0].env == nil)
        #expect(runner.simpleCommands[1].env == nil)
        #expect(runner.captureCommands.first(where: { $0.command.contains("--triple") })?.env == nil)
        #expect(outputMessages == [
            "Installed privateheaderkit to \(layout.publicCommandURL.path)",
            "Installed privateheaderkit-raw-helper to \(layout.rawDumpHelperURL.path)",
            "Installed privateheaderkit-sim-helper to \(layout.simulatorHelperURL.path)",
        ])
        #expect(errorMessages.isEmpty)
    }

    @Test func installFromInstalledBinaryStillBuildsPublicCommandFromCurrentRepo() throws {
        let dirs = try makeTemporaryTestDirectories()
        let repoRoot = dirs.root.appendingPathComponent("Repo", isDirectory: true)
        let installPrefix = dirs.root.appendingPathComponent("Install", isDirectory: true)
        let installedBinDir = dirs.root.appendingPathComponent("Existing/bin", isDirectory: true)
        let hostBinDir = repoRoot.appendingPathComponent(".build/release", isDirectory: true)
        let simulatorBinDir = repoRoot.appendingPathComponent(
            ".build/x86_64-apple-ios-simulator/release",
            isDirectory: true
        )
        try makePrivateHeaderKitRepoMarkers(in: repoRoot)
        try FileManager.default.createDirectory(at: installedBinDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostBinDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: simulatorBinDir, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: installedBinDir.appendingPathComponent("privateheaderkit"))
        try Data("rebuilt".utf8).write(to: hostBinDir.appendingPathComponent("privateheaderkit"))
        try Data("raw".utf8).write(to: hostBinDir.appendingPathComponent("privateheaderkit-raw-helper"))
        try Data("sim".utf8).write(to: simulatorBinDir.appendingPathComponent("privateheaderkit-sim-helper"))

        let runner = RecordingCommandRunner()
        runner.setCaptureOutput("/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk\n", for: [
            "xcrun",
            "--sdk",
            "iphonesimulator",
            "--show-sdk-path",
        ])
        runner.setCaptureOutput(
            "\(hostBinDir.path)\n",
            for: ["swift", "build", "-c", "release", "--show-bin-path"]
        )
        runner.setCaptureOutput(
            "\(simulatorBinDir.path)\n",
            for: [
                "swift",
                "build",
                "-c",
                "release",
                "--sdk",
                "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
                "--triple",
                "x86_64-apple-ios-simulator",
                "--show-bin-path",
            ]
        )

        try install(
            options: InstallOptions(prefix: installPrefix.path, bindir: nil, dryRun: false),
            selfURL: installedBinDir.appendingPathComponent("privateheaderkit"),
            currentDirectoryURL: repoRoot,
            runner: runner,
            fileManager: .default,
            outputLogger: { _ in },
            errorLogger: { _ in },
            simulatorHelperTriple: "x86_64-apple-ios-simulator"
        )

        let layout = resolveInstallLayout(prefix: installPrefix.path, bindir: nil)
        #expect(try String(contentsOf: layout.publicCommandURL, encoding: .utf8) == "rebuilt")
        #expect(runner.simpleCommands.map(\.command).first == [
            "swift",
            "build",
            "-c",
            "release",
            "--product",
            "privateheaderkit",
        ])
        #expect(runner.simpleCommands.map(\.command).contains([
            "swift",
            "build",
            "-c",
            "release",
            "--product",
            "privateheaderkit-raw-helper",
        ]))
    }
}

private func makePrivateHeaderKitRepoMarkers(in repoRoot: URL) throws {
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try Data().write(to: repoRoot.appendingPathComponent("Package.swift"))
    try FileManager.default.createDirectory(
        at: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCore", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data().write(to: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCore/PrivateHeaderGeneration.swift"))
    try FileManager.default.createDirectory(
        at: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCLI", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data().write(to: repoRoot.appendingPathComponent("Sources/PrivateHeaderKitCLI/PrivateHeaderKitMain.swift"))
}
