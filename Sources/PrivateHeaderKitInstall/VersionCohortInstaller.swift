import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

struct ReleaseCohort: Sendable {
    let manifest: ReleaseManifest
    let artifactURLs: [InstallArtifactName: URL]

    init(
        manifest: ReleaseManifest,
        artifactURLs: [InstallArtifactName: URL]
    ) throws {
        try manifest.validate()
        let expected = Set(InstallArtifactName.allCases)
        guard Set(artifactURLs.keys) == expected,
              artifactURLs.count == expected.count
        else {
            throw InstallError.message(
                "release cohort must contain exactly: \(expected.map(\.rawValue).sorted().joined(separator: ", "))"
            )
        }
        self.manifest = manifest
        self.artifactURLs = artifactURLs
    }

    static func read(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> ReleaseCohort {
        guard case .directory = try fileSystemItemKind(
            at: directory,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "release cohort is not a real directory: \(directory.path)"
            )
        }
        let expectedEntries = Set(
            InstallArtifactName.allCases.map(\.rawValue) + [ReleaseManifest.fileName]
        )
        let actualEntries = Set(
            try fileManager.contentsOfDirectory(atPath: directory.path)
        )
        guard actualEntries == expectedEntries else {
            throw InstallError.message(
                "release cohort entries do not match the required set; expected \(expectedEntries.sorted()), got \(actualEntries.sorted())"
            )
        }

        let manifestURL = directory.appendingPathComponent(
            ReleaseManifest.fileName,
            isDirectory: false
        )
        guard case .regularFile = try fileSystemItemKind(
            at: manifestURL,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "release manifest is not a regular file: \(manifestURL.path)"
            )
        }
        let manifest = try ReleaseManifest.read(from: manifestURL)
        return try ReleaseCohort(
            manifest: manifest,
            artifactURLs: Dictionary(
                uniqueKeysWithValues: InstallArtifactName.allCases.map { artifact in
                    (
                        artifact,
                        directory.appendingPathComponent(artifact.rawValue, isDirectory: false)
                    )
                }
            )
        )
    }
}

enum InstallFaultPoint: Equatable, Sendable {
    case installRootCreated
    case lockAcquired
    case preflightComplete
    case artifactStaged(InstallArtifactName)
    case stagingValidated
    case beforeCohortPublish
    case cohortPublished
    case migrationIntentPersisted
    case currentSwitched
    case stableCommandSwitched
    case publicRestorationStarted
    case currentRestorationStarted
    case legacyCleanupStarted
    case obsoleteCommandCleanupStarted
}

typealias InstallFaultInjector = @Sendable (InstallFaultPoint) throws -> Void

struct InstallResult: Equatable, Sendable {
    let cohort: String
    let cohortDirectory: URL
    let publicCommandURL: URL
    let reusedExistingCohort: Bool
    let cleanupWarnings: [String]
}

struct VersionCohortInstaller {
    let layout: InstallLayout
    let fileManager: FileManager
    let inspectArtifact: ReleaseArtifactInspector
    let faultInjector: InstallFaultInjector
    let outputLogger: @Sendable (String) -> Void

    init(
        layout: InstallLayout,
        fileManager: FileManager = .default,
        inspectArtifact: @escaping ReleaseArtifactInspector,
        faultInjector: @escaping InstallFaultInjector = { _ in },
        outputLogger: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.inspectArtifact = inspectArtifact
        self.faultInjector = faultInjector
        self.outputLogger = outputLogger
    }

    func withInstallLock<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        try validateManagedInstallRootPath(requireInstallRoot: false)
        try validateOwnedDirectoryIfPresent(layout.binDir, label: "command directory")
        try Task.checkCancellation()
        try fileManager.createDirectory(
            at: layout.installRoot,
            withIntermediateDirectories: true
        )
        try faultInjector(.installRootCreated)
        try validateManagedInstallRootPath(requireInstallRoot: true)
        try Task.checkCancellation()
        let lock = try InstallLock(at: layout.lockURL, fileManager: fileManager)
        defer { lock.close() }
        try validateManagedInstallRootPath(requireInstallRoot: true)
        try validateOwnedDirectoryIfPresent(layout.versionsDirectory, label: "versions path")
        try validateOwnedDirectoryIfPresent(layout.binDir, label: "command directory")
        try await recoverInterruptedLegacyMigration()
        try Task.checkCancellation()
        try faultInjector(.lockAcquired)
        return try await operation()
    }

    func install(_ cohort: ReleaseCohort) async throws -> InstallResult {
        try await withInstallLock {
            try await installLocked(cohort)
        }
    }

    func installLocked(_ cohort: ReleaseCohort) async throws -> InstallResult {
        try Task.checkCancellation()
        try await preflight(cohort)
        try validateObsoleteCommandCleanupTargets()
        try faultInjector(.preflightComplete)
        try validateOwnedDirectoryIfPresent(layout.installRoot, label: "install root")
        try validateOwnedDirectoryIfPresent(layout.versionsDirectory, label: "versions path")
        let currentBeforeInstall = try await currentPathSnapshot()
        let legacyLayout: LegacyLayoutSnapshot?
        switch try classifyLegacyDirectLayout(current: currentBeforeInstall) {
        case .absent:
            legacyLayout = nil
        case .complete(let snapshot):
            legacyLayout = snapshot
        case .malformed(let reason):
            throw InstallError.message(
                "\(reason); expected three executable regular legacy binaries or no legacy layout"
            )
        }
        let hadLegacyDirectLayout = legacyLayout != nil
        if legacyLayout != nil,
           case .symbolicLink = currentBeforeInstall
        {
            throw InstallError.message(
                "legacy direct binaries and a managed current cohort both exist; refusing ambiguous migration"
            )
        }
        try validateManagedDestinations(
            allowLegacyDirectLayout: hadLegacyDirectLayout,
            current: currentBeforeInstall
        )

        try fileManager.createDirectory(
            at: layout.versionsDirectory,
            withIntermediateDirectories: true
        )
        try validateOwnedDirectoryIfPresent(
            layout.versionsDirectory,
            label: "versions path"
        )
        try fileManager.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )
        try validateOwnedDirectoryIfPresent(
            layout.binDir,
            label: "command directory"
        )

        let stagingDirectory = layout.versionsDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                do {
                    try fileManager.removeItem(at: stagingDirectory)
                } catch {
                    outputLogger(
                        "warning: failed to remove install staging directory at \(stagingDirectory.path): \(error)"
                    )
                }
            }
        }

        for artifact in InstallArtifactName.allCases.sorted() {
            let sourceURL = try sourceURL(for: artifact, in: cohort)
            let destinationURL = stagingDirectory.appendingPathComponent(
                artifact.rawValue,
                isDirectory: false
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destinationURL.path
            )
            try faultInjector(.artifactStaged(artifact))
        }
        try cohort.manifest.encoded().write(
            to: stagingDirectory.appendingPathComponent(
                ReleaseManifest.fileName,
                isDirectory: false
            ),
            options: [.atomic]
        )
        try await validateDirectory(
            stagingDirectory,
            expectedManifest: cohort.manifest
        )
        try faultInjector(.stagingValidated)

        let finalDirectory = layout.cohortDirectory(for: cohort.manifest)
        var reusedExistingCohort = false
        if try pathExists(finalDirectory) {
            try await validateDirectory(
                finalDirectory,
                expectedManifest: cohort.manifest
            )
            reusedExistingCohort = true
        } else {
            try Task.checkCancellation()
            try faultInjector(.beforeCohortPublish)
            do {
                try publishCohortExclusively(
                    source: stagingDirectory,
                    destination: finalDirectory
                )
                shouldRemoveStaging = false
            } catch let error as POSIXRenameError where error.code == EEXIST {
                try await validateDirectory(
                    finalDirectory,
                    expectedManifest: cohort.manifest
                )
                reusedExistingCohort = true
            }
        }
        try faultInjector(.cohortPublished)

        let previousCurrent = try await currentPathSnapshot()
        let previousPublicCommand = try publicCommandPathSnapshot(
            allowLegacyDirectLayout: hadLegacyDirectLayout
        )
        let migrationIntent: LegacyMigrationIntent?
        if let legacyLayout {
            guard case .regularFile = previousPublicCommand else {
                throw InstallError.message(
                    "legacy migration lost ownership of the public command before activation"
                )
            }
            try Task.checkCancellation()
            migrationIntent = try prepareLegacyMigration(
                targetManifest: cohort.manifest,
                legacyLayout: legacyLayout
            )
            try faultInjector(.migrationIntentPersisted)
        } else {
            migrationIntent = nil
        }

        do {
            try Task.checkCancellation()
            try atomicReplaceSymlink(
                at: layout.currentURL,
                destination: "versions/\(cohort.manifest.cohort)"
            )
            try faultInjector(.currentSwitched)

            if let migrationIntent {
                try requireLegacyIdentity(
                    migrationIntent.legacyLayout.publicCommand,
                    at: layout.publicCommandURL,
                    label: "legacy public command"
                )
            }
            try Task.checkCancellation()
            try atomicReplaceSymlink(
                at: layout.publicCommandURL,
                destination: "../libexec/privateheaderkit/current/privateheaderkit"
            )
            try faultInjector(.stableCommandSwitched)
            try await verifyActiveCohort(cohort.manifest)
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            if let restorationError = restoreAfterActivationFailure(
                previousCurrent: previousCurrent,
                previousPublicCommand: previousPublicCommand,
                migrationIntent: migrationIntent
            ) {
                logInstallDiagnostic(
                    "warning: installation cancellation rollback failed: \(restorationError)"
                )
            }
            throw cancellation
        } catch {
            let restorationError = restoreAfterActivationFailure(
                previousCurrent: previousCurrent,
                previousPublicCommand: previousPublicCommand,
                migrationIntent: migrationIntent
            )
            if let restorationError {
                throw InstallError.message(
                    "installation failed: \(error); restoring the previous install also failed: \(restorationError)"
                )
            }
            throw error
        }

        var cleanupWarnings: [String] = []
        if let migrationIntent {
            do {
                try faultInjector(.legacyCleanupStarted)
                cleanupWarnings.append(
                    contentsOf: try finalizeLegacyMigration(migrationIntent)
                )
            } catch {
                cleanupWarnings.append(
                    "new cohort is active, but legacy cleanup did not finish: \(error)"
                )
            }
        }
        try faultInjector(.obsoleteCommandCleanupStarted)
        let removedObsoleteCommands = try removeObsoletePublicCommands()
        for warning in cleanupWarnings {
            outputLogger("warning: \(warning)")
        }
        for url in removedObsoleteCommands {
            outputLogger("Removed obsolete command: \(url.path)")
        }

        outputLogger(
            "Installed PrivateHeaderKit \(cohort.manifest.version) (\(cohort.manifest.commit))"
        )
        outputLogger("Active cohort: \(finalDirectory.path)")
        outputLogger("Command: \(layout.publicCommandURL.path)")
        return InstallResult(
            cohort: cohort.manifest.cohort,
            cohortDirectory: finalDirectory,
            publicCommandURL: layout.publicCommandURL,
            reusedExistingCohort: reusedExistingCohort,
            cleanupWarnings: cleanupWarnings
        )
    }
}

extension VersionCohortInstaller {
    enum ManagedPathSnapshot {
        case absent
        case symbolicLink(String)
        case regularFile
    }

    func preflight(_ cohort: ReleaseCohort) async throws {
        try Task.checkCancellation()
        try cohort.manifest.validate()
        for artifact in InstallArtifactName.allCases {
            let sourceURL = try sourceURL(for: artifact, in: cohort)
            let expected = try cohort.manifest.artifact(named: artifact)
            let actual = try await inspectArtifact(artifact, sourceURL)
            try Task.checkCancellation()
            try validate(
                actual,
                expected: expected,
                path: sourceURL.path
            )
        }
    }

    func sourceURL(
        for artifact: InstallArtifactName,
        in cohort: ReleaseCohort
    ) throws -> URL {
        guard let url = cohort.artifactURLs[artifact] else {
            throw InstallError.message(
                "missing install artifact: \(artifact.rawValue)"
            )
        }
        return url
    }

    func validateDirectory(
        _ directory: URL,
        expectedManifest: ReleaseManifest
    ) async throws {
        let installed = try ReleaseCohort.read(
            from: directory,
            fileManager: fileManager
        )
        guard installed.manifest == expectedManifest else {
            if installed.manifest.cohort == expectedManifest.cohort,
               installed.manifest.commit != expectedManifest.commit
            {
                throw InstallError.message(
                    "binary cohort collision with different provenance at \(directory.path): existing commit \(installed.manifest.commit), requested commit \(expectedManifest.commit)"
                )
            }
            throw InstallError.message(
                "immutable cohort already exists with different contents: \(directory.path)"
            )
        }
        try await preflight(installed)
    }

    func validate(
        _ actual: ReleaseArtifactInspection,
        expected: ReleaseArtifactRecord,
        path: String
    ) throws {
        guard actual.sha256 == expected.sha256 else {
            throw InstallError.message(
                "SHA-256 mismatch for \(expected.name.rawValue) at \(path)"
            )
        }
        guard actual.architectures == expected.architectures.sorted() else {
            throw InstallError.message(
                "architecture mismatch for \(expected.name.rawValue): expected \(expected.architectures.sorted()), got \(actual.architectures)"
            )
        }
        guard actual.platform == expected.platform else {
            throw InstallError.message(
                "platform mismatch for \(expected.name.rawValue): expected \(expected.platform.rawValue), got \(actual.platform.rawValue)"
            )
        }
    }

    func validateManagedDestinations(
        allowLegacyDirectLayout: Bool,
        current: ManagedPathSnapshot
    ) throws {
        if case .absent = try fileSystemItemKind(
            at: layout.publicCommandURL,
            fileManager: fileManager
        ) {
            return
        } else {
            let publicCommand = try publicCommandPathSnapshot(
                allowLegacyDirectLayout: allowLegacyDirectLayout
            )
            if case .symbolicLink = publicCommand,
               case .absent = current
            {
                throw InstallError.message(
                    "stable public command exists without a managed current cohort: \(layout.publicCommandURL.path)"
                )
            }
        }
    }

    func currentPathSnapshot() async throws -> ManagedPathSnapshot {
        let snapshot = try managedPathSnapshot(
            at: layout.currentURL,
            allowRegularFile: false,
            allowedSymbolicLink: isManagedCurrentDestination
        )
        if case .symbolicLink(let destination) = snapshot {
            try await validateManagedCurrentCohort(destination: destination)
        }
        return snapshot
    }

    func publicCommandPathSnapshot(
        allowLegacyDirectLayout: Bool
    ) throws -> ManagedPathSnapshot {
        try managedPathSnapshot(
            at: layout.publicCommandURL,
            allowRegularFile: allowLegacyDirectLayout,
            allowedSymbolicLink: {
                $0 == "../libexec/privateheaderkit/current/privateheaderkit"
            }
        )
    }

    func managedPathSnapshot(
        at url: URL,
        allowRegularFile: Bool,
        allowedSymbolicLink: (String) -> Bool
    ) throws -> ManagedPathSnapshot {
        switch try fileSystemItemKind(at: url, fileManager: fileManager) {
        case .absent:
            return .absent
        case .symbolicLink(let destination):
            guard allowedSymbolicLink(destination) else {
                throw InstallError.message(
                    "refusing to replace unmanaged symbolic link at \(url.path): \(destination)"
                )
            }
            return .symbolicLink(destination)
        case .regularFile:
            if allowRegularFile {
                return .regularFile
            }
            throw InstallError.message(
                "refusing to replace unmanaged install path: \(url.path)"
            )
        case .directory, .other:
            throw InstallError.message(
                "refusing to replace unmanaged install path: \(url.path)"
            )
        }
    }

    func isManagedCurrentDestination(_ destination: String) -> Bool {
        guard destination.hasPrefix("versions/") else {
            return false
        }
        let cohort = String(destination.dropFirst("versions/".count))
        guard !cohort.isEmpty, cohort != ".", cohort != "..",
              !cohort.contains("/")
        else {
            return false
        }
        return cohort.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "+"
                || scalar == "-"
        }
    }

    func validateManagedCurrentCohort(destination: String) async throws {
        let cohortIdentifier = String(destination.dropFirst("versions/".count))
        let cohortDirectory = layout.versionsDirectory.appendingPathComponent(
            cohortIdentifier,
            isDirectory: true
        )
        guard case .directory = try fileSystemItemKind(
            at: cohortDirectory,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "current pointer references a missing cohort: \(destination)"
            )
        }
        let cohort = try ReleaseCohort.read(
            from: cohortDirectory,
            fileManager: fileManager
        )
        guard cohort.manifest.cohort == cohortIdentifier else {
            throw InstallError.message(
                "current pointer cohort does not match its release manifest: \(destination)"
            )
        }
        try await preflight(cohort)
    }

    func verifyActiveCohort(_ manifest: ReleaseManifest) async throws {
        let expectedCurrent = "versions/\(manifest.cohort)"
        let currentDestination = try fileManager.destinationOfSymbolicLink(
            atPath: layout.currentURL.path
        )
        guard currentDestination == expectedCurrent else {
            throw InstallError.message(
                "current pointer verification failed: expected \(expectedCurrent), got \(currentDestination)"
            )
        }
        let expectedPublicDestination = "../libexec/privateheaderkit/current/privateheaderkit"
        let publicDestination = try fileManager.destinationOfSymbolicLink(
            atPath: layout.publicCommandURL.path
        )
        guard publicDestination == expectedPublicDestination else {
            throw InstallError.message(
                "public command pointer verification failed: expected \(expectedPublicDestination), got \(publicDestination)"
            )
        }

        let expectedPublic = layout.installedArtifactURL(
            .publicCommand,
            manifest: manifest
        )
        guard try pathsReferenceSameFile(layout.publicCommandURL, expectedPublic) else {
            throw InstallError.message(
                "public command does not resolve to the active cohort: \(layout.publicCommandURL.path)"
            )
        }
        try await validateDirectory(
            layout.cohortDirectory(for: manifest),
            expectedManifest: manifest
        )
    }
}

private func logInstallDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
