#if os(macOS)
import Foundation
import Testing
import os

#if canImport(Darwin)
import Darwin
#endif

@testable import PrivateHeaderKitInstall
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling

@Suite
struct InstallOptionTests {
    @Test func layoutUsesVersionCohortDirectoriesAndStablePointers() async throws {
        let layout = try resolveInstallLayout(prefix: "/prefix", bindir: nil)
        #expect(layout.publicCommandURL.path == "/prefix/bin/privateheaderkit")
        #expect(layout.installRoot.path == "/prefix/libexec/privateheaderkit")
        #expect(layout.versionsDirectory.path == "/prefix/libexec/privateheaderkit/versions")
        #expect(layout.currentURL.path == "/prefix/libexec/privateheaderkit/current")
        #expect(layout.rawDumpHelperURL.path == "/prefix/libexec/privateheaderkit/privateheaderkit-raw-helper")

        let custom = try resolveInstallLayout(
            prefix: "/ignored",
            bindir: "/custom/bin"
        )
        #expect(custom.prefix.path == "/custom")
        #expect(custom.publicCommandURL.path == "/custom/bin/privateheaderkit")
        #expect(custom.installRoot.path == "/custom/libexec/privateheaderkit")
    }

}

@Suite
struct ReleaseManifestTests {
    @Test func manifestRequiresExactArtifactSetAndCanonicalCohort() async throws {
        let directories = try makeTemporaryTestDirectories()
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.2.3",
            commit: String(repeating: "a", count: 40),
            marker: "one"
        )

        #expect(
            cohort.manifest.cohort.range(
                of: #"^v1[.]2[.]3[+][0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil
        )
        #expect(cohort.manifest.artifacts.map(\.name) == InstallArtifactName.allCases.sorted())
        try cohort.manifest.validate()

        let sameArtifactsDifferentCommit = try ReleaseManifest(
            version: "v1.2.3",
            commit: String(repeating: "b", count: 40),
            artifacts: cohort.manifest.artifacts
        )
        #expect(sameArtifactsDifferentCommit.cohort == cohort.manifest.cohort)

        var changedArtifacts = cohort.manifest.artifacts
        let first = changedArtifacts.removeFirst()
        changedArtifacts.append(
            ReleaseArtifactRecord(
                name: first.name,
                sha256: String(repeating: "f", count: 64),
                architectures: first.architectures,
                platform: first.platform,
                codeSignaturePolicy: first.codeSignaturePolicy
            )
        )
        let changedContent = try ReleaseManifest(
            version: "v1.2.3",
            commit: cohort.manifest.commit,
            artifacts: changedArtifacts
        )
        #expect(changedContent.cohort != cohort.manifest.cohort)

        #expect(throws: InstallError.self) {
            _ = try ReleaseManifest(
                version: "v1.2.3",
                commit: String(repeating: "b", count: 40),
                artifacts: Array(cohort.manifest.artifacts.dropLast())
            )
        }
    }

    @Test func releaseDirectoryRejectsExtraOrMissingEntries() async throws {
        let directories = try makeTemporaryTestDirectories()
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "c", count: 40),
            marker: "exact"
        )
        let directory = try cohortDirectory(cohort)
        try Data("extra".utf8).write(
            to: directory.appendingPathComponent("unexpected")
        )
        #expect(throws: InstallError.self) {
            _ = try ReleaseCohort.read(from: directory)
        }
    }

    @Test func executablePermissionIsPartOfPreflight() async throws {
        let directories = try makeTemporaryTestDirectories()
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "d", count: 40),
            marker: "permission"
        )
        let rawURL = try #require(cohort.artifactURLs[.rawDumpHelper])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: rawURL.path
        )
        let layout = try resolveInstallLayout(
            prefix: directories.root.appendingPathComponent("prefix").path,
            bindir: nil
        )
        let installer = testInstaller(layout: layout)
        await #expect(throws: InstallError.self) {
            _ = try await installer.install(cohort)
        }
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
    }

    @Test func releaseDirectoryAndManifestMustNotBeSymbolicLinks() async throws {
        let directories = try makeTemporaryTestDirectories()
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "0", count: 40),
            marker: "links"
        )
        let directory = try cohortDirectory(cohort)
        let directoryLink = directories.root.appendingPathComponent("cohort-link")
        try FileManager.default.createSymbolicLink(
            at: directoryLink,
            withDestinationURL: directory
        )
        #expect(throws: InstallError.self) {
            _ = try ReleaseCohort.read(from: directoryLink)
        }

        let manifestURL = directory.appendingPathComponent(ReleaseManifest.fileName)
        let realManifestURL = directories.root.appendingPathComponent("real-release.json")
        try FileManager.default.moveItem(at: manifestURL, to: realManifestURL)
        try FileManager.default.createSymbolicLink(
            at: manifestURL,
            withDestinationURL: realManifestURL
        )
        #expect(throws: InstallError.self) {
            _ = try ReleaseCohort.read(from: directory)
        }
    }
}

@Suite
struct VersionCohortInstallerTests {
    @Test func installsCompleteCohortAndPublishesStablePointers() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "1", count: 40),
            marker: "first"
        )

        let result = try await testInstaller(layout: layout).install(cohort)

        #expect(result.cohort == cohort.manifest.cohort)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.currentURL.path
            ) == "versions/\(cohort.manifest.cohort)"
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.publicCommandURL.path
            ) == "../libexec/privateheaderkit/current/privateheaderkit"
        )
        #expect(try activePublicCommandContents(layout: layout) == "first-privateheaderkit")
        try assertInstalledCohortIsExact(cohort.manifest, layout: layout)
    }

    @Test func stagingFailureKeepsPreviousCohortActive() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "1", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let second = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "2", count: 40),
            marker: "second"
        )
        let failingInstaller = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .artifactStaged(.rawDumpHelper) {
                    throw TestInstallFailure.injected
                }
            }
        )

        await #expect(throws: TestInstallFailure.self) {
            _ = try await failingInstaller.install(second)
        }
        try assertActive(first.manifest, layout: layout, marker: "first")
    }

    @Test func activationFailureRestoresPreviousCurrentPointer() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "3", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let second = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "4", count: 40),
            marker: "second"
        )
        let failingInstaller = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .currentSwitched {
                    throw TestInstallFailure.injected
                }
            }
        )

        await #expect(throws: TestInstallFailure.self) {
            _ = try await failingInstaller.install(second)
        }
        try assertActive(first.manifest, layout: layout, marker: "first")
    }

    @Test func hashMismatchNeverSwitchesCurrent() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "5", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let tampered = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "6", count: 40),
            marker: "second"
        )
        let tamperedURL = try #require(tampered.artifactURLs[.simulatorHelper])
        let handle = try FileHandle(forWritingTo: tamperedURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(tampered)
        }
        try assertActive(first.manifest, layout: layout, marker: "first")
    }

    @Test func sameBinaryCohortWithDifferentProvenanceFailsFast() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "5", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let differentProvenanceManifest = try ReleaseManifest(
            version: first.manifest.version,
            commit: String(repeating: "6", count: 40),
            artifacts: first.manifest.artifacts
        )
        let differentProvenance = try ReleaseCohort(
            manifest: differentProvenanceManifest,
            artifactURLs: first.artifactURLs
        )

        do {
            _ = try await testInstaller(layout: layout).install(differentProvenance)
            Issue.record("expected provenance collision to fail")
        } catch let error as InstallError {
            #expect(
                error.description.contains(
                    "binary cohort collision with different provenance"
                )
            )
        }
        try assertActive(first.manifest, layout: layout, marker: "first")
    }

    @Test func bakedReleaseBindingMismatchNeverSwitchesCurrent() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "7", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let release = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "8", count: 40),
            marker: "release"
        )
        let options = InstallOptions(
            prefix: layout.prefix.path,
            bindir: nil,
            dryRun: false,
            buildConfiguration: nil,
            releaseDirectory: try cohortDirectory(release).path,
            expectedReleaseVersion: "v9.0.0",
            expectedReleaseCommit: release.manifest.commit
        )

        await #expect(throws: InstallError.self) {
            try await runInstall(
                options: options,
                currentExecutableURL: nil,
                currentDirectoryURL: directories.root,
                environment: [:],
                runner: RecordingCommandRunner(),
                fileManager: .default,
                inspectArtifact: testArtifactInspector,
                outputLogger: { _ in }
            )
        }
        try assertActive(first.manifest, layout: layout, marker: "first")
    }

    @Test func concurrentInstallIsRejected() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "7", count: 40),
            marker: "cohort"
        )
        let lock = try InstallLock(at: layout.lockURL)
        defer { lock.close() }

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
    }

    @Test func migratesKnownDirectLayoutOnlyAfterNewCohortIsActive() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try writeExecutable("legacy-main", to: layout.publicCommandURL)
        try writeExecutable("legacy-raw", to: layout.rawDumpHelperURL)
        try writeExecutable("legacy-sim", to: layout.simulatorHelperURL)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "8", count: 40),
            marker: "new"
        )

        _ = try await testInstaller(layout: layout).install(cohort)

        try assertActive(cohort.manifest, layout: layout, marker: "new")
        #expect(!FileManager.default.fileExists(atPath: layout.rawDumpHelperURL.path))
        #expect(!FileManager.default.fileExists(atPath: layout.simulatorHelperURL.path))
    }

    @Test func directLayoutActivationFaultRestoresLegacyPublicCommand() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try writeExecutable("legacy-main", to: layout.publicCommandURL)
        try writeExecutable("legacy-raw", to: layout.rawDumpHelperURL)
        try writeExecutable("legacy-sim", to: layout.simulatorHelperURL)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "9", count: 40),
            marker: "new"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .stableCommandSwitched {
                    throw TestInstallFailure.injected
                }
            }
        )

        await #expect(throws: TestInstallFailure.self) {
            _ = try await installer.install(cohort)
        }
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "legacy-main"
        )
        #expect(
            try String(contentsOf: layout.rawDumpHelperURL, encoding: .utf8)
                == "legacy-raw"
        )
        #expect(
            try String(contentsOf: layout.simulatorHelperURL, encoding: .utf8)
                == "legacy-sim"
        )
    }

    @Test func cleanupFailureKeepsActivatedCohortAndReturnsWarning() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try writeExecutable("legacy-main", to: layout.publicCommandURL)
        try writeExecutable("legacy-raw", to: layout.rawDumpHelperURL)
        try writeExecutable("legacy-sim", to: layout.simulatorHelperURL)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "0", count: 40),
            marker: "new"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .legacyCleanupStarted {
                    throw TestInstallFailure.injected
                }
            }
        )

        let result = try await installer.install(cohort)

        try assertActive(cohort.manifest, layout: layout, marker: "new")
        #expect(result.cleanupWarnings.count == 1)
        #expect(FileManager.default.fileExists(atPath: layout.rawDumpHelperURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.simulatorHelperURL.path))
    }

    @Test func refusesUnknownPublicCommandAndLeavesItUntouched() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )
        try writeExecutable("user-owned", to: layout.publicCommandURL)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "a", count: 40),
            marker: "new"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "user-owned"
        )
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
    }

    @Test func partialLegacyLayoutWithSymlinkHelperIsNotMigrationAuthority() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try writeExecutable("legacy-main", to: layout.publicCommandURL)
        try writeExecutable("legacy-sim", to: layout.simulatorHelperURL)
        let userOwned = directories.root.appendingPathComponent("user-owned-raw")
        try writeExecutable("user-owned", to: userOwned)
        try FileManager.default.createSymbolicLink(
            at: layout.rawDumpHelperURL,
            withDestinationURL: userOwned
        )
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "c", count: 40),
            marker: "new"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.rawDumpHelperURL.path
            ) == userOwned.path
        )
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "legacy-main"
        )
    }

    @Test func helperOnlyLegacyLayoutFailsBeforePointerMutation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try writeExecutable("orphan-helper", to: layout.rawDumpHelperURL)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "d", count: 40),
            marker: "new"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
        #expect(
            try String(contentsOf: layout.rawDumpHelperURL, encoding: .utf8)
                == "orphan-helper"
        )
    }

    @Test func managedCohortIgnoresRetiredRootHelperLeftovers() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "d", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let userOwned = directories.root.appendingPathComponent("user-owned-helper")
        try writeExecutable("user-owned", to: userOwned)
        try FileManager.default.createSymbolicLink(
            at: layout.rawDumpHelperURL,
            withDestinationURL: userOwned
        )
        let second = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "e", count: 40),
            marker: "second"
        )

        _ = try await testInstaller(layout: layout).install(second)

        try assertActive(second.manifest, layout: layout, marker: "second")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.rawDumpHelperURL.path
            ) == userOwned.path
        )
    }

    @Test func legacyPermissionDriftFailsBeforePointerMutation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try writeLegacyLayout(layout: layout)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "f", count: 40),
            marker: "new"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .cohortPublished {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o644],
                        ofItemAtPath: layout.publicCommandURL.path
                    )
                }
            }
        )

        await #expect(throws: InstallError.self) {
            _ = try await installer.install(cohort)
        }
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
        #expect(!FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "legacy-main"
        )
    }

    @Test func directLayoutAlongsideManagedCurrentIsRejectedAsAmbiguous() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "d", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        try FileManager.default.removeItem(at: layout.publicCommandURL)
        try writeExecutable("direct-main", to: layout.publicCommandURL)
        try writeExecutable("direct-raw", to: layout.rawDumpHelperURL)
        try writeExecutable("direct-sim", to: layout.simulatorHelperURL)
        let second = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "e", count: 40),
            marker: "second"
        )

        do {
            _ = try await testInstaller(layout: layout).install(second)
            Issue.record("expected ambiguous migration to fail")
        } catch let error as InstallError {
            #expect(error.description.contains("ambiguous migration"))
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.currentURL.path
            ) == "versions/\(first.manifest.cohort)"
        )
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "direct-main"
        )
        #expect(FileManager.default.fileExists(atPath: layout.rawDumpHelperURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.simulatorHelperURL.path))
    }

    @Test func refusesUnknownCurrentAndPublicSymlinkTargets() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: layout.currentURL.path,
            withDestinationPath: "../../outside"
        )
        try FileManager.default.createSymbolicLink(
            atPath: layout.publicCommandURL.path,
            withDestinationPath: "../user-command"
        )
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "f", count: 40),
            marker: "new"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.currentURL.path
            ) == "../../outside"
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.publicCommandURL.path
            ) == "../user-command"
        )
    }

    @Test func refusesBrokenManagedCurrentCohort() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        let missingCohort = "v1.0.0+\(String(repeating: "0", count: 64))"
        try FileManager.default.createSymbolicLink(
            atPath: layout.currentURL.path,
            withDestinationPath: "versions/\(missingCohort)"
        )
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "1", count: 40),
            marker: "new"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.currentURL.path
            ) == "versions/\(missingCohort)"
        )
    }

    @Test func installRootAndVersionsMustBeRealDirectories() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let external = directories.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: layout.installRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: layout.installRoot,
            withDestinationURL: external
        )
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "2", count: 40),
            marker: "new"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)

        try FileManager.default.removeItem(at: layout.installRoot)
        try FileManager.default.createDirectory(at: layout.installRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: layout.versionsDirectory,
            withDestinationURL: external
        )
        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func sourceBuildFailurePreservesExistingCohortWithoutFallback() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "b", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)

        let repoRoot = directories.root.appendingPathComponent("Repo", isDirectory: true)
        try makePrivateHeaderKitRepoMarkers(in: repoRoot)
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            String(repeating: "a", count: 40) + "\n",
            for: ["git", "rev-parse", "HEAD"]
        )
        await runner.setCaptureOutput(
            "",
            for: ["git", "tag", "--points-at", "HEAD"]
        )
        await runner.setCaptureOutput(
            "",
            for: ["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"]
        )
        await runner.setCaptureOutput(
            "",
            for: ["git", "ls-files", "--others", "--exclude-standard", "-z"]
        )
        await runner.setSimpleHandler { _, _, _ in
            throw TestInstallFailure.injected
        }
        let options = InstallOptions(
            prefix: layout.prefix.path,
            bindir: nil,
            dryRun: false,
            buildConfiguration: .release,
            releaseDirectory: nil,
            expectedReleaseVersion: nil,
            expectedReleaseCommit: nil
        )

        await #expect(throws: TestInstallFailure.self) {
            try await runInstall(
                options: options,
                currentExecutableURL: nil,
                currentDirectoryURL: repoRoot,
                environment: [:],
                runner: runner,
                fileManager: .default,
                inspectArtifact: testArtifactInspector,
                outputLogger: { _ in },
                simulatorHelperTriple: "arm64-apple-ios-simulator"
            )
        }
        try assertActive(first.manifest, layout: layout, marker: "first")
        #expect(await runner.simpleCommandSnapshot().count == 1)
    }

    @Test func installLockIsHeldForTheLexicalOperationScope() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let installer = testInstaller(layout: layout)

        _ = try await installer.withInstallLock {
            #expect(throws: InstallError.self) {
                _ = try InstallLock(at: layout.lockURL)
            }
        }

        let nextLock = try InstallLock(at: layout.lockURL)
        nextLock.close()
    }

    @Test func installLockRejectsNonRegularDescriptor() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
#if canImport(Darwin)
        let result = layout.lockURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(0o600))
        }
        #expect(result == 0)
        #expect(throws: InstallError.self) {
            _ = try InstallLock(at: layout.lockURL)
        }
#endif
    }

    @Test func canonicalBindirAliasUsesOneLayoutAndLockIdentity() async throws {
        let directories = try makeTemporaryTestDirectories()
        let realPrefix = directories.root.appendingPathComponent("real-prefix", isDirectory: true)
        let realBin = realPrefix.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        let aliasBin = directories.root.appendingPathComponent("command-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasBin, withDestinationURL: realBin)

        let aliased = try resolveInstallLayout(prefix: nil, bindir: aliasBin.path)
        let canonical = try resolveInstallLayout(prefix: nil, bindir: realBin.path)
        #expect(aliased == canonical)
        #expect(aliased.lockURL == canonical.lockURL)

        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "a", count: 40),
            marker: "alias"
        )
        _ = try await testInstaller(layout: aliased).install(cohort)
        #expect(
            try String(
                contentsOf: aliasBin.appendingPathComponent("privateheaderkit"),
                encoding: .utf8
            ) == "alias-privateheaderkit"
        )
    }

    @Test func canonicalLayoutRejectsNonDirectoryAncestorBeforeMutation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let blocker = directories.root.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let requestedPrefix = blocker.appendingPathComponent("prefix", isDirectory: true)

        #expect(throws: InstallError.self) {
            _ = try resolveInstallLayout(prefix: requestedPrefix.path, bindir: nil)
        }
        #expect(try Data(contentsOf: blocker) == Data("not a directory".utf8))
    }

    @Test func defaultPrefixRejectsManagedLibexecSymlinkBeforeMutation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let prefix = directories.root.appendingPathComponent("prefix", isDirectory: true)
        let external = directories.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: prefix.appendingPathComponent("libexec", isDirectory: true),
            withDestinationURL: external
        )
        let layout = try resolveInstallLayout(prefix: prefix.path, bindir: nil)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "c", count: 40),
            marker: "managed-ancestor"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func defaultPrefixRejectsBinSymlinkBeforeInstallMutation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let prefix = directories.root.appendingPathComponent("prefix", isDirectory: true)
        let external = directories.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: prefix.appendingPathComponent("bin", isDirectory: true),
            withDestinationURL: external
        )
        let layout = try resolveInstallLayout(prefix: prefix.path, bindir: nil)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "d", count: 40),
            marker: "default-bin"
        )

        await #expect(throws: InstallError.self) {
            _ = try await testInstaller(layout: layout).install(cohort)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        if case .absent = try fileSystemItemKind(
            at: layout.installRoot,
            fileManager: .default
        ) {
            // Expected: the unsafe command directory is rejected before lock creation.
        } else {
            Issue.record("install root was mutated before rejecting the default bin symlink")
        }
    }

    @Test func managedAncestorsAreRevalidatedAfterInstallRootCreation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let external = directories.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let libexecDirectory = layout.prefix.appendingPathComponent(
            "libexec",
            isDirectory: true
        )
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "e", count: 40),
            marker: "post-create"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                guard point == .installRootCreated else {
                    return
                }
                try FileManager.default.removeItem(at: libexecDirectory)
                try FileManager.default.createSymbolicLink(
                    at: libexecDirectory,
                    withDestinationURL: external
                )
            }
        )

        await #expect(throws: InstallError.self) {
            _ = try await installer.install(cohort)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func exclusiveCohortPublishNeverReplacesRacedDestination() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "b", count: 40),
            marker: "exclusive"
        )
        let finalDirectory = layout.cohortDirectory(for: cohort.manifest)
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .beforeCohortPublish {
                    try FileManager.default.createDirectory(
                        at: finalDirectory,
                        withIntermediateDirectories: false
                    )
                }
            }
        )

        await #expect(throws: InstallError.self) {
            _ = try await installer.install(cohort)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: finalDirectory.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
    }

    @Test func changedLegacyHelperIsLeftUntouchedAfterCommit() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try writeLegacyLayout(layout: layout)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "c", count: 40),
            marker: "new"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .legacyCleanupStarted {
                    try FileManager.default.removeItem(at: layout.rawDumpHelperURL)
                    try writeExecutable("replacement-raw", to: layout.rawDumpHelperURL)
                }
            }
        )

        let result = try await installer.install(cohort)

        try assertActive(cohort.manifest, layout: layout, marker: "new")
        #expect(result.cleanupWarnings.count == 1)
        #expect(
            try String(contentsOf: layout.rawDumpHelperURL, encoding: .utf8)
                == "replacement-raw"
        )
        #expect(!FileManager.default.fileExists(atPath: layout.simulatorHelperURL.path))
        #expect(!FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))

        let nextCohort = try await makeTestCohort(
            under: directories.root,
            version: "v3.0.0",
            commit: String(repeating: "d", count: 40),
            marker: "next"
        )
        _ = try await testInstaller(layout: layout).install(nextCohort)

        try assertActive(nextCohort.manifest, layout: layout, marker: "next")
        #expect(
            try String(contentsOf: layout.rawDumpHelperURL, encoding: .utf8)
                == "replacement-raw"
        )
    }

    @Test func publicFirstRestorationPreservesAValidCommandAtEachFailure() async throws {
        for restorationFault in [
            InstallFaultPoint.publicRestorationStarted,
            InstallFaultPoint.currentRestorationStarted,
        ] {
            let directories = try makeTemporaryTestDirectories()
            let layout = try testLayout(in: directories.root)
            try writeLegacyLayout(layout: layout)
            let cohort = try await makeTestCohort(
                under: directories.root,
                version: "v2.0.0",
                commit: String(repeating: "d", count: 40),
                marker: "new"
            )
            let installer = testInstaller(
                layout: layout,
                faultInjector: { point in
                    if point == .stableCommandSwitched {
                        throw TestInstallFailure.activation
                    }
                    if point == restorationFault {
                        throw TestInstallFailure.restoration
                    }
                }
            )

            await #expect(throws: InstallError.self) {
                _ = try await installer.install(cohort)
            }
            let publicContents = try String(
                contentsOf: layout.publicCommandURL,
                encoding: .utf8
            )
            if restorationFault == .publicRestorationStarted {
                #expect(publicContents == "new-privateheaderkit")
            } else {
                #expect(publicContents == "legacy-main")
            }

            try await testInstaller(layout: layout).withInstallLock {}
            try assertActive(cohort.manifest, layout: layout, marker: "new")
            #expect(!FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
        }
    }

    @Test func recreatedLegacyBackupBeforeIntentUpdateIsRestartable() async throws {
        let directories = try makeTemporaryTestDirectories()
        let fixture = try await makeInterruptedLegacyRollbackFixture(
            under: directories.root,
            commit: String(repeating: "4", count: 40),
            marker: "copy-before-intent"
        )
        try FileManager.default.copyItem(
            at: fixture.layout.publicCommandURL,
            to: fixture.backupURL
        )

        #expect(
            try testInstaller(layout: fixture.layout).readLegacyMigrationIntent()
                == fixture.intent
        )
        try await testInstaller(layout: fixture.layout).withInstallLock {}

        try assertCompletedLegacyRecovery(fixture)
    }

    @Test func recreatedLegacyBackupIntentIsRestartableBeforePointerSwitch() async throws {
        let directories = try makeTemporaryTestDirectories()
        let fixture = try await makeInterruptedLegacyRollbackFixture(
            under: directories.root,
            commit: String(repeating: "5", count: 40),
            marker: "intent-before-pointer"
        )
        try FileManager.default.copyItem(
            at: fixture.layout.publicCommandURL,
            to: fixture.backupURL
        )
        let installer = testInstaller(layout: fixture.layout)

        let updatedIntent = try installer.ensureLegacyPublicBackup(
            fixture.intent,
            ownedPublicIdentity: fixture.intent.publicBackup
        )

        #expect(updatedIntent.legacyLayout.publicCommand == fixture.intent.publicBackup)
        #expect(updatedIntent.publicBackup != fixture.intent.publicBackup)
        #expect(try installer.readLegacyMigrationIntent() == updatedIntent)
        try await testInstaller(layout: fixture.layout).withInstallLock {}

        try assertCompletedLegacyRecovery(fixture)
    }

    @Test func recreatedLegacyBackupRejectsChangedContents() async throws {
        let directories = try makeTemporaryTestDirectories()
        let fixture = try await makeInterruptedLegacyRollbackFixture(
            under: directories.root,
            commit: String(repeating: "6", count: 40),
            marker: "changed-backup"
        )
        try writeExecutable("replacement-backup", to: fixture.backupURL)
        let persistedIntent = try Data(contentsOf: fixture.layout.legacyMigrationIntentURL)

        await #expect(throws: InstallError.self) {
            try await testInstaller(layout: fixture.layout).withInstallLock {}
        }

        #expect(
            try Data(contentsOf: fixture.layout.legacyMigrationIntentURL)
                == persistedIntent
        )
        #expect(
            try String(contentsOf: fixture.layout.publicCommandURL, encoding: .utf8)
                == "legacy-main"
        )
        #expect(
            try String(contentsOf: fixture.backupURL, encoding: .utf8)
                == "replacement-backup"
        )
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.layout.currentURL.path
            ) == "versions/\(fixture.cohort.manifest.cohort)"
        )
    }

    @Test func restorationNeverOverwritesAReplacedRegularFile() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "1", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let second = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "2", count: 40),
            marker: "second"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .stableCommandSwitched {
                    try FileManager.default.removeItem(at: layout.publicCommandURL)
                    try writeExecutable("replacement", to: layout.publicCommandURL)
                    throw TestInstallFailure.activation
                }
            }
        )

        await #expect(throws: InstallError.self) {
            _ = try await installer.install(second)
        }
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "replacement"
        )
    }

    @Test func restorationNeverPublishesANonExecutableLegacyBackup() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try writeLegacyLayout(layout: layout)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "3", count: 40),
            marker: "new"
        )
        let installer = testInstaller(
            layout: layout,
            faultInjector: { point in
                guard point == .stableCommandSwitched else {
                    return
                }
                let backupName = try #require(
                    FileManager.default.contentsOfDirectory(atPath: layout.binDir.path)
                        .first(where: { $0.hasPrefix(".legacy-public-") })
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: layout.binDir.appendingPathComponent(backupName).path
                )
                throw TestInstallFailure.activation
            }
        )

        await #expect(throws: InstallError.self) {
            _ = try await installer.install(cohort)
        }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: layout.publicCommandURL.path
            ) == "../libexec/privateheaderkit/current/privateheaderkit"
        )
        #expect(
            try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
                == "new-privateheaderkit"
        )
        #expect(FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
    }

    @Test func reopenRecoversEveryDurableLegacyMigrationPhase() async throws {
        enum Phase: CaseIterable {
            case intentPersisted
            case currentSwitched
            case publicSwitched
            case cleanupStarted
        }

        for phase in Phase.allCases {
            let directories = try makeTemporaryTestDirectories()
            let layout = try testLayout(in: directories.root)
            try writeLegacyLayout(layout: layout)
            let cohort = try await makeTestCohort(
                under: directories.root,
                version: "v2.0.0",
                commit: String(repeating: "e", count: 40),
                marker: "recovered"
            )
            let interrupted = testInstaller(
                layout: layout,
                faultInjector: { point in
                    if point == .migrationIntentPersisted {
                        throw TestInstallFailure.injected
                    }
                }
            )
            await #expect(throws: TestInstallFailure.self) {
                _ = try await interrupted.install(cohort)
            }
            #expect(FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
            let backupNames = try FileManager.default.contentsOfDirectory(
                atPath: layout.binDir.path
            ).filter { $0.hasPrefix(".legacy-public-") }
            #expect(backupNames.count == 1)

            if phase != .intentPersisted {
                try FileManager.default.createSymbolicLink(
                    atPath: layout.currentURL.path,
                    withDestinationPath: "versions/\(cohort.manifest.cohort)"
                )
            }
            if phase == .publicSwitched || phase == .cleanupStarted {
                try FileManager.default.removeItem(at: layout.publicCommandURL)
                try FileManager.default.createSymbolicLink(
                    atPath: layout.publicCommandURL.path,
                    withDestinationPath: "../libexec/privateheaderkit/current/privateheaderkit"
                )
            }
            if phase == .cleanupStarted {
                try FileManager.default.removeItem(at: layout.rawDumpHelperURL)
            }

            try await testInstaller(layout: layout).withInstallLock {}

            try assertActive(cohort.manifest, layout: layout, marker: "recovered")
            #expect(!FileManager.default.fileExists(atPath: layout.rawDumpHelperURL.path))
            #expect(!FileManager.default.fileExists(atPath: layout.simulatorHelperURL.path))
            #expect(!FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
            let binEntries = try FileManager.default.contentsOfDirectory(
                atPath: layout.binDir.path
            )
            #expect(binEntries == ["privateheaderkit"])
        }
    }

    @Test func corruptLegacyMigrationIntentFailsBeforePointerMutation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try FileManager.default.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: layout.legacyMigrationIntentURL)

        await #expect(throws: InstallError.self) {
            try await testInstaller(layout: layout).withInstallLock {}
        }
        #expect(!FileManager.default.fileExists(atPath: layout.currentURL.path))
        #expect(!FileManager.default.fileExists(atPath: layout.publicCommandURL.path))
    }
}

@Suite
struct SourceBuildResolutionTests {
    @Test func untaggedSourceVersionUsesCommitNamespace() async throws {
        let directories = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        let commit = "ABCDEF1234567890ABCDEF1234567890ABCDEF12"
        await runner.setCaptureOutput(
            "documentation-only\n",
            for: ["git", "tag", "--points-at", "HEAD"]
        )

        #expect(
            try await sourceVersion(
                repoRoot: directories.root,
                environment: [:],
                runner: runner,
                commit: commit
            ) == "0.0.0-dev.abcdef123456"
        )

        #expect(
            try await sourceVersion(
                repoRoot: directories.root,
                environment: ["PRIVATEHEADERKIT_BUILD_VERSION": "v1.2.3"],
                runner: runner,
                commit: commit
            ) == "v1.2.3"
        )

        await runner.setCaptureOutput(
            "documentation-only\nv2.3.4\n",
            for: ["git", "tag", "--points-at", "HEAD"]
        )
        #expect(
            try await sourceVersion(
                repoRoot: directories.root,
                environment: [:],
                runner: runner,
                commit: commit
            ) == "v2.3.4"
        )

        await runner.setCaptureOutput(
            "v2.3.4\nv2.3.5\n",
            for: ["git", "tag", "--points-at", "HEAD"]
        )
        await #expect(throws: InstallError.self) {
            _ = try await sourceVersion(
                repoRoot: directories.root,
                environment: [:],
                runner: runner,
                commit: commit
            )
        }

        do {
            _ = try await sourceVersion(
                repoRoot: directories.root,
                environment: [:],
                runner: RecordingCommandRunner(),
                commit: commit
            )
            Issue.record("expected Git tag lookup failure to propagate")
        } catch {
            // A Git inspection failure is not the same state as no release tag.
        }
    }

    @Test func buildCommandsResolveExactHostAndSimulatorProducts() async throws {
        let directories = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        let simulatorTriple = "arm64-apple-ios-simulator"
        let simulatorScratchPath = SwiftPMBuildPaths.simulatorScratchURL(
            repoRoot: directories.root,
            triple: simulatorTriple
        )
        await runner.setCaptureOutput(
            "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk\n",
            for: ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]
        )

        try await buildProducts(
            ["privateheaderkit", "privateheaderkit-raw-helper"],
            configuration: .debug,
            in: directories.root,
            runner: runner
        )
        try await buildSimulatorHelper(
            in: directories.root,
            configuration: .debug,
            scratchPath: simulatorScratchPath,
            sdkPath: try await resolveSimulatorSDKPath(runner: runner),
            runner: runner,
            simulatorHelperTriple: simulatorTriple
        )

        #expect(await runner.simpleCommandSnapshot().map(\.command) == [
            ["swift", "build", "-c", "debug", "--product", "privateheaderkit"],
            ["swift", "build", "-c", "debug", "--product", "privateheaderkit-raw-helper"],
            [
                "swift", "build", "-c", "debug",
                "--scratch-path", simulatorScratchPath.path,
                "--sdk", "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
                "--triple", simulatorTriple,
                "--product", "privateheaderkit-sim-helper",
            ],
        ])
        #expect(await runner.simpleCommandSnapshot().allSatisfy { $0.cwd == directories.root })
        #expect(
            simulatorScratchPath.path
                == directories.root.appendingPathComponent(
                    ".build/privateheaderkit-simulator/\(simulatorTriple)",
                    isDirectory: true
                ).path
        )
    }

    @Test func binPathResolutionHasNoSiblingFallback() async throws {
        let directories = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            "\n\(directories.root.appendingPathComponent(".build/release").path)\n",
            for: ["swift", "build", "-c", "release", "--show-bin-path"]
        )
        let result = try await resolveSwiftBinDir(
            repoRoot: directories.root,
            runner: runner,
            configuration: .release
        )
        #expect(result.path == directories.root.appendingPathComponent(".build/release").path)

        let failingRunner = RecordingCommandRunner()
        await failingRunner.setCaptureOutput(
            "\n",
            for: ["swift", "build", "-c", "release", "--show-bin-path"]
        )
        await #expect(throws: InstallError.self) {
            _ = try await resolveSwiftBinDir(
                repoRoot: directories.root,
                runner: failingRunner,
                configuration: .release
            )
        }
    }

    @Test func simulatorBinPathResolutionUsesTheBuildScratchPath() async throws {
        let directories = try makeTemporaryTestDirectories()
        let runner = RecordingCommandRunner()
        let sdkPath = "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        let simulatorTriple = "arm64-apple-ios-simulator"
        let simulatorScratchPath = SwiftPMBuildPaths.simulatorScratchURL(
            repoRoot: directories.root,
            triple: simulatorTriple
        )
        let command = [
            "swift", "build", "-c", "release",
            "--scratch-path", simulatorScratchPath.path,
            "--sdk", sdkPath,
            "--triple", simulatorTriple,
            "--show-bin-path",
        ]
        let simulatorBin = simulatorScratchPath.appendingPathComponent(
            "resolved-bin",
            isDirectory: true
        )
        await runner.setCaptureOutput("\n\(simulatorBin.path)\n", for: command)

        let result = try await resolveSwiftBinDir(
            repoRoot: directories.root,
            runner: runner,
            configuration: .release,
            scratchPath: simulatorScratchPath,
            triple: simulatorTriple,
            sdkPath: sdkPath
        )

        #expect(result == simulatorBin)
        #expect(await runner.captureCommandSnapshot().map(\.command) == [command])
        #expect(await runner.captureCommandSnapshot().allSatisfy { $0.cwd == directories.root })
    }

    @Test func sourceSnapshotIncludesTrackedUntrackedAndReleaseProvenance() async throws {
        let directories = try makeTemporaryTestDirectories()
        let repoRoot = directories.root.appendingPathComponent("Repo", isDirectory: true)
        try makePrivateHeaderKitRepoMarkers(in: repoRoot)
        let untrackedPath = "Sources/Untracked.swift"
        let untrackedURL = repoRoot.appendingPathComponent(untrackedPath)
        try writeExecutable("first", to: untrackedURL)
        let runner = RecordingCommandRunner()
        let head = String(repeating: "a", count: 40) + "\n"
        await runner.setCaptureOutputs([head, head], for: ["git", "rev-parse", "HEAD"])
        await runner.setCaptureOutputs(
            ["v1.0.0\n", "v1.0.1\n"],
            for: ["git", "tag", "--points-at", "HEAD"]
        )
        await runner.setCaptureOutputs(
            ["tracked-first", "tracked-second"],
            for: ["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"]
        )
        await runner.setCaptureOutputs(
            [untrackedPath + "\0", untrackedPath + "\0"],
            for: ["git", "ls-files", "--others", "--exclude-standard", "-z"]
        )

        let first = try await captureSourceSnapshot(
            repoRoot: repoRoot,
            environment: [:],
            runner: runner,
            fileManager: .default
        )
        try Data("second".utf8).write(to: untrackedURL)
        let second = try await captureSourceSnapshot(
            repoRoot: repoRoot,
            environment: [:],
            runner: runner,
            fileManager: .default
        )

        #expect(first.head == second.head)
        #expect(first.dirtyInputFingerprint != second.dirtyInputFingerprint)
        #expect(first.releaseTags == ["v1.0.0"])
        #expect(second.releaseTags == ["v1.0.1"])
        #expect(first.effectiveVersion == "v1.0.0")
        #expect(second.effectiveVersion == "v1.0.1")
    }

    @Test func sourceMutationDuringProductBuildFailsBeforeCohortCreation() async throws {
        let directories = try makeTemporaryTestDirectories()
        let repoRoot = directories.root.appendingPathComponent("Repo", isDirectory: true)
        try makePrivateHeaderKitRepoMarkers(in: repoRoot)
        let untrackedPath = "Sources/BuildInput.swift"
        let untrackedURL = repoRoot.appendingPathComponent(untrackedPath)
        try writeExecutable("before", to: untrackedURL)

        let hostBin = directories.root.appendingPathComponent("host-bin", isDirectory: true)
        let simulatorBin = directories.root.appendingPathComponent("sim-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: hostBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: simulatorBin, withIntermediateDirectories: true)
        try writeExecutable(
            "public",
            to: hostBin.appendingPathComponent("privateheaderkit")
        )
        try writeExecutable(
            "raw",
            to: hostBin.appendingPathComponent("privateheaderkit-raw-helper")
        )
        try writeExecutable(
            "sim",
            to: simulatorBin.appendingPathComponent("privateheaderkit-sim-helper")
        )

        let runner = RecordingCommandRunner()
        let head = String(repeating: "b", count: 40) + "\n"
        await runner.setCaptureOutputs([head, head], for: ["git", "rev-parse", "HEAD"])
        await runner.setCaptureOutputs(["", ""], for: ["git", "tag", "--points-at", "HEAD"])
        await runner.setCaptureOutputs(
            ["", ""],
            for: ["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"]
        )
        await runner.setCaptureOutputs(
            [untrackedPath + "\0", untrackedPath + "\0"],
            for: ["git", "ls-files", "--others", "--exclude-standard", "-z"]
        )
        let sdk = "/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        let triple = "arm64-apple-ios-simulator"
        let simulatorScratchPath = SwiftPMBuildPaths.simulatorScratchURL(
            repoRoot: repoRoot,
            triple: triple
        )
        await runner.setCaptureOutput(
            sdk + "\n",
            for: ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]
        )
        await runner.setCaptureOutput(
            hostBin.path + "\n",
            for: ["swift", "build", "-c", "release", "--show-bin-path"]
        )
        await runner.setCaptureOutput(
            simulatorBin.path + "\n",
            for: [
                "swift", "build", "-c", "release",
                "--scratch-path", simulatorScratchPath.path,
                "--sdk", sdk,
                "--triple", triple,
                "--show-bin-path",
            ]
        )
        let sourceMutation = SourceMutation(url: untrackedURL)
        await runner.setSimpleHandler { _, _, _ in
            try await sourceMutation.runOnce()
        }

        await #expect(throws: InstallError.self) {
            _ = try await buildSourceCohort(
                repoRoot: repoRoot,
                configuration: .release,
                environment: [:],
                runner: runner,
                fileManager: .default,
                inspectArtifact: testArtifactInspector,
                simulatorHelperTriple: triple
            )
        }
    }
}

@Suite
struct InstallCancellationTests {
    @Test func releaseManifestInspectionPreservesCancellation() async {
        let root = FileManager.default.temporaryDirectory
        let artifactURLs = Dictionary(
            uniqueKeysWithValues: InstallArtifactName.allCases.map { artifact in
                (artifact, root.appendingPathComponent(artifact.rawValue))
            }
        )
        let inspectionStarted = CancellationTestLatch()
        let releaseInspection = CancellationTestLatch()

        let manifest = Task {
            try await makeReleaseManifest(
                version: "v1.0.0",
                commit: String(repeating: "a", count: 40),
                artifactURLs: artifactURLs,
                inspectArtifact: { artifact, _ in
                    inspectionStarted.open()
                    await releaseInspection.wait()
                    return ReleaseArtifactInspection(
                        sha256: String(repeating: "a", count: 64),
                        architectures: ["arm64"],
                        platform: artifact.expectedPlatform
                    )
                }
            )
        }
        await inspectionStarted.wait()
        manifest.cancel()
        releaseInspection.open()
        await #expect(throws: CancellationError.self) {
            _ = try await manifest.value
        }
    }

    @Test func activationVerificationCancellationRestoresThePreviousCohort() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let first = try await makeTestCohort(
            under: directories.root,
            version: "v1.0.0",
            commit: String(repeating: "1", count: 40),
            marker: "first"
        )
        _ = try await testInstaller(layout: layout).install(first)
        let second = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "2", count: 40),
            marker: "second"
        )
        let secondDirectory = layout.cohortDirectory(for: second.manifest).path + "/"
        let installer = VersionCohortInstaller(
            layout: layout,
            inspectArtifact: { artifact, url in
                if url.path.hasPrefix(secondDirectory) {
                    throw CancellationError()
                }
                return try await testArtifactInspector(artifact: artifact, url: url)
            },
            outputLogger: { _ in }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await installer.install(second)
        }

        try assertActive(first.manifest, layout: layout, marker: "first")
        let lock = try InstallLock(at: layout.lockURL)
        lock.close()
    }

    @Test func recoveryCancellationPreservesDurableIntentAndReleasesTheLock() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        try writeLegacyLayout(layout: layout)
        let cohort = try await makeTestCohort(
            under: directories.root,
            version: "v2.0.0",
            commit: String(repeating: "3", count: 40),
            marker: "recovery"
        )
        let interrupted = testInstaller(
            layout: layout,
            faultInjector: { point in
                if point == .migrationIntentPersisted {
                    throw TestInstallFailure.injected
                }
            }
        )
        await #expect(throws: TestInstallFailure.self) {
            _ = try await interrupted.install(cohort)
        }
        #expect(FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))

        let cancellationInspector = RecoveryCancellationInspector()
        let recovery = VersionCohortInstaller(
            layout: layout,
            inspectArtifact: cancellationInspector.inspect,
            outputLogger: { _ in }
        )
        await #expect(throws: CancellationError.self) {
            try await recovery.withInstallLock {}
        }

        #expect(FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
        let lock = try InstallLock(at: layout.lockURL)
        lock.close()

        try await testInstaller(layout: layout).withInstallLock {}
        #expect(!FileManager.default.fileExists(atPath: layout.legacyMigrationIntentURL.path))
        try assertActive(cohort.manifest, layout: layout, marker: "recovery")
    }

    @Test func sourceBuildCancellationKeepsTheLockUntilChildCleanupFinishes() async throws {
        let directories = try makeTemporaryTestDirectories()
        let layout = try testLayout(in: directories.root)
        let repoRoot = directories.root.appendingPathComponent("Repo", isDirectory: true)
        try makePrivateHeaderKitRepoMarkers(in: repoRoot)
        let runner = RecordingCommandRunner()
        await runner.setCaptureOutput(
            String(repeating: "4", count: 40) + "\n",
            for: ["git", "rev-parse", "HEAD"]
        )
        await runner.setCaptureOutput(
            "",
            for: ["git", "tag", "--points-at", "HEAD"]
        )
        await runner.setCaptureOutput(
            "",
            for: ["git", "diff", "--no-ext-diff", "--binary", "HEAD", "--"]
        )
        await runner.setCaptureOutput(
            "",
            for: ["git", "ls-files", "--others", "--exclude-standard", "-z"]
        )
        let buildStarted = CancellationTestLatch()
        let cancellationObserved = CancellationTestLatch()
        let releaseCleanup = CancellationTestLatch()
        await runner.setSimpleHandler { _, _, _ in
            buildStarted.open()
            await withTaskCancellationHandler {
                await releaseCleanup.wait()
            } onCancel: {
                cancellationObserved.open()
            }
            throw CancellationError()
        }
        let options = InstallOptions(
            prefix: layout.prefix.path,
            bindir: nil,
            dryRun: false,
            buildConfiguration: .release,
            releaseDirectory: nil,
            expectedReleaseVersion: nil,
            expectedReleaseCommit: nil
        )

        let install = Task {
            try await runInstall(
                options: options,
                currentExecutableURL: nil,
                currentDirectoryURL: repoRoot,
                environment: [:],
                runner: runner,
                fileManager: .default,
                inspectArtifact: testArtifactInspector,
                outputLogger: { _ in },
                simulatorHelperTriple: "arm64-apple-ios-simulator"
            )
        }
        await buildStarted.wait()
        #expect(throws: InstallError.self) {
            _ = try InstallLock(at: layout.lockURL)
        }

        install.cancel()
        await cancellationObserved.wait()
        #expect(throws: InstallError.self) {
            _ = try InstallLock(at: layout.lockURL)
        }
        releaseCleanup.open()
        await #expect(throws: CancellationError.self) {
            try await install.value
        }

        let lock = try InstallLock(at: layout.lockURL)
        lock.close()
    }
}

private enum TestInstallFailure: Error {
    case injected
    case activation
    case restoration
}

private struct InterruptedLegacyRollbackFixture {
    let layout: InstallLayout
    let cohort: ReleaseCohort
    let marker: String
    let intent: LegacyMigrationIntent
    let backupURL: URL
}

private func makeInterruptedLegacyRollbackFixture(
    under root: URL,
    commit: String,
    marker: String
) async throws -> InterruptedLegacyRollbackFixture {
    let layout = try testLayout(in: root)
    try writeLegacyLayout(layout: layout)
    let cohort = try await makeTestCohort(
        under: root,
        version: "v2.0.0",
        commit: commit,
        marker: marker
    )
    let interrupted = testInstaller(
        layout: layout,
        faultInjector: { point in
            if point == .stableCommandSwitched {
                throw TestInstallFailure.activation
            }
            if point == .currentRestorationStarted {
                throw TestInstallFailure.restoration
            }
        }
    )
    await #expect(throws: InstallError.self) {
        _ = try await interrupted.install(cohort)
    }

    let inspector = testInstaller(layout: layout)
    let intent = try #require(try inspector.readLegacyMigrationIntent())
    let backupURL = inspector.migrationBackupURL(intent)
    try inspector.requireLegacyIdentity(
        intent.publicBackup,
        at: layout.publicCommandURL,
        label: "restored legacy public command"
    )
    #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: layout.currentURL.path
        ) == "versions/\(cohort.manifest.cohort)"
    )
    return InterruptedLegacyRollbackFixture(
        layout: layout,
        cohort: cohort,
        marker: marker,
        intent: intent,
        backupURL: backupURL
    )
}

private func assertCompletedLegacyRecovery(
    _ fixture: InterruptedLegacyRollbackFixture
) throws {
    try assertActive(
        fixture.cohort.manifest,
        layout: fixture.layout,
        marker: fixture.marker
    )
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.rawDumpHelperURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.simulatorHelperURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.layout.legacyMigrationIntentURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path))
    let binEntries = try FileManager.default.contentsOfDirectory(
        atPath: fixture.layout.binDir.path
    )
    #expect(binEntries == ["privateheaderkit"])
}

private func testLayout(in root: URL) throws -> InstallLayout {
    try resolveInstallLayout(
        prefix: root.appendingPathComponent("prefix", isDirectory: true).path,
        bindir: nil
    )
}

private func testInstaller(
    layout: InstallLayout,
    faultInjector: @escaping InstallFaultInjector = { _ in }
) -> VersionCohortInstaller {
    VersionCohortInstaller(
        layout: layout,
        inspectArtifact: testArtifactInspector,
        faultInjector: faultInjector,
        outputLogger: { _ in }
    )
}

private func testArtifactInspector(
    artifact: InstallArtifactName,
    url: URL
) async throws -> ReleaseArtifactInspection {
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw InstallError.message("artifact is not executable: \(url.path)")
    }
    return ReleaseArtifactInspection(
        sha256: try LiveReleaseArtifactInspector.sha256(of: url),
        architectures: ["arm64"],
        platform: artifact.expectedPlatform
    )
}

private func makeTestCohort(
    under root: URL,
    version: String,
    commit: String,
    marker: String
) async throws -> ReleaseCohort {
    let directory = root.appendingPathComponent(
        "cohort-source-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let artifacts = Dictionary(
        uniqueKeysWithValues: try InstallArtifactName.allCases.map { artifact in
            let url = directory.appendingPathComponent(
                artifact.rawValue,
                isDirectory: false
            )
            try writeExecutable("\(marker)-\(artifact.rawValue)", to: url)
            return (artifact, url)
        }
    )
    let manifest = try await makeReleaseManifest(
        version: version,
        commit: commit,
        artifactURLs: artifacts,
        inspectArtifact: testArtifactInspector
    )
    try manifest.encoded().write(
        to: directory.appendingPathComponent(ReleaseManifest.fileName),
        options: [.atomic]
    )
    return try ReleaseCohort.read(from: directory)
}

private actor SourceMutation {
    private let url: URL
    private var hasRun = false

    init(url: URL) {
        self.url = url
    }

    func runOnce() throws {
        guard !hasRun else { return }
        hasRun = true
        try Data("after".utf8).write(to: url)
    }
}

private actor RecoveryCancellationInspector {
    private var inspectionCount = 0

    func inspect(
        artifact: InstallArtifactName,
        url: URL
    ) async throws -> ReleaseArtifactInspection {
        inspectionCount += 1
        if inspectionCount > InstallArtifactName.allCases.count {
            throw CancellationError()
        }
        return try await testArtifactInspector(artifact: artifact, url: url)
    }
}

private final class CancellationTestLatch: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private func cohortDirectory(_ cohort: ReleaseCohort) throws -> URL {
    try #require(cohort.artifactURLs[.publicCommand]).deletingLastPathComponent()
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func writeLegacyLayout(layout: InstallLayout) throws {
    try FileManager.default.createDirectory(
        at: layout.binDir,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: layout.installRoot,
        withIntermediateDirectories: true
    )
    try writeExecutable("legacy-main", to: layout.publicCommandURL)
    try writeExecutable("legacy-raw", to: layout.rawDumpHelperURL)
    try writeExecutable("legacy-sim", to: layout.simulatorHelperURL)
}

private func activePublicCommandContents(
    layout: InstallLayout
) throws -> String {
    try String(contentsOf: layout.publicCommandURL, encoding: .utf8)
}

private func assertActive(
    _ manifest: ReleaseManifest,
    layout: InstallLayout,
    marker: String
) throws {
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: layout.currentURL.path
        ) == "versions/\(manifest.cohort)"
    )
    #expect(
        try activePublicCommandContents(layout: layout)
            == "\(marker)-privateheaderkit"
    )
}

private func assertInstalledCohortIsExact(
    _ manifest: ReleaseManifest,
    layout: InstallLayout
) throws {
    let entries = try FileManager.default.contentsOfDirectory(
        atPath: layout.cohortDirectory(for: manifest).path
    ).sorted()
    #expect(
        entries
            == (InstallArtifactName.allCases.map(\.rawValue) + [ReleaseManifest.fileName]).sorted()
    )
}

private func makePrivateHeaderKitRepoMarkers(in repoRoot: URL) throws {
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try Data().write(to: repoRoot.appendingPathComponent("Package.swift"))
    for path in [
        "Sources/PrivateHeaderKitCore/PrivateHeaderGeneration.swift",
        "Sources/PrivateHeaderKitCLI/PrivateHeaderKitMain.swift",
    ] {
        let url = repoRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }
}
#endif
